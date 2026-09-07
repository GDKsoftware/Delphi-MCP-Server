unit MCPClient.Http;

// One THTTPClient behind the whole MCP client: the header table of the specification, the
// POST, and one reader that copes with the three response shapes a server produces, namely
// a plain JSON object, a batched text/event-stream body carrying a Content-Length, and a
// chunked text/event-stream.
//
// Which shape arrived is decided from the first non-blank byte, because the response
// headers only become readable once the body has been read and a chunked stream has to be
// parsed while it is still arriving. A JSON-RPC response always starts with '{'; an event
// stream always starts with a field name or a comment.
//
// A transport instance belongs to one thread. The client that owns it serialises its calls.

interface

uses
  System.Classes,
  System.SysUtils,
  System.JSON,
  System.Net.HttpClient,
  System.Net.URLClient,
  MCPClient.Interfaces,
  MCPClient.Types;

type
  TMCPSseEvent = record
    EventName: string;
    Data: string;
  end;

  // Accepts input split at any boundary, including inside a UTF-8 sequence, inside a line
  // and inside a frame, and hands back complete frames only. Lines end with LF or CRLF; a
  // line opening with a colon is the fifteen-second keep-alive comment and is dropped.
  TMCPSseParser = class
  private
    FPending: TBytes;
    FBuffer: string;
    FEventName: string;
    FData: string;
    FHasData: Boolean;
    FHasFrame: Boolean;
    FFinished: Boolean;
    class function SequenceLength(const Lead: Byte): Integer; static;
    class function CompleteByteCount(const Bytes: TBytes): Integer; static;
    function TryTakeLine(out Line: string): Boolean;
    procedure TakeField(const Line: string);
    function TakeFrame: TMCPSseEvent;
  public
    procedure Append(const Chunk: string);
    procedure AppendBytes(const Bytes: TBytes);
    procedure Finish;
    procedure Reset;
    function TryNext(out Event: TMCPSseEvent): Boolean;
  end;

  // Reads one parameter out of a WWW-Authenticate bearer challenge, which is what carries
  // the scope a human must grant after a 403.
  TMCPChallengeReader = record
  private
    class function SplitParameters(const Challenge: string): TArray<string>; static;
    class function StripScheme(const Value: string): string; static;
    class function Unquote(const Value: string): string; static;
  public
    class function Parameter(const Challenge, Name: string): string; static;
  end;

  TMCPHttpRequest = record
    Method: string;
    MirroredName: string;
    Body: string;
    ExpectedId: Int64;
    IsNotification: Boolean;
    class function Call(const Method, Body: string; const ExpectedId: Int64;
      const MirroredName: string = ''): TMCPHttpRequest; static;
    class function Notify(const Method, Body: string): TMCPHttpRequest; static;
  end;

  TMCPHttpResponse = record
    StatusCode: Integer;
    ContentType: string;
    SessionId: string;
    Challenge: string;
    RequiredScope: string;
    Body: string;
    Cancelled: Boolean;
    function HasBody: Boolean;
  end;

  TMCPNotificationEvent = reference to procedure(const Notification: TJSONObject);

  {$SCOPEDENUMS ON}
  TMCPBodyShape = (Undecided, Json, EventStream);
  {$SCOPEDENUMS OFF}

  TMCPHttpTransport = class
  private
    FClient: THTTPClient;
    FParser: TMCPSseParser;
    FServerUrl: string;
    FOptions: TMCPClientOptions;
    FAuth: IMCPClientAuth;
    FEra: TMCPClientEra;
    FProtocolVersion: string;
    FSessionId: string;
    FCancellationCheck: TFunc<Boolean>;
    FOnNotification: TMCPNotificationEvent;
    FShape: TMCPBodyShape;
    FCapturedBody: string;
    FExpectedId: Int64;
    FStop: Boolean;
    FCancelled: Boolean;
    class function ShapeOf(const Bytes: TBytes): TMCPBodyShape; static;
    class function IsNotificationMessage(const Frame: TJSONObject): Boolean; static;
    class function IsJsonRpc(const Body: string): Boolean; static;
    function Execute(const Request: TMCPHttpRequest; const Token: string): TMCPHttpResponse;
    function BuildHeaders(const Request: TMCPHttpRequest; const Token: string): TNetHeaders;
    function ModernProtocolVersion: string;
    function AcceptValue: string;
    procedure ConsumeChunk(const Chunk: Pointer; const ChunkLength: Cardinal);
    procedure HandleFrame(const Event: TMCPSseEvent);
    function MatchesExpectedId(const Frame: TJSONObject): Boolean;
    procedure DispatchNotification(const Notification: TJSONObject);
    function ReadResponse(const Response: IHTTPResponse; const Sink: TBytesStream): TMCPHttpResponse;
    function IsCancelled: Boolean;
    procedure CheckStatus(const Request: TMCPHttpRequest; const Response: TMCPHttpResponse);
  public
    constructor Create(const ServerUrl: string; const Options: TMCPClientOptions;
      const Auth: IMCPClientAuth = nil);
    destructor Destroy; override;

    function Send(const Request: TMCPHttpRequest): TMCPHttpResponse;

    property ServerUrl: string read FServerUrl;
    property Era: TMCPClientEra read FEra write FEra;
    property ProtocolVersion: string read FProtocolVersion write FProtocolVersion;
    property SessionId: string read FSessionId write FSessionId;
    property CancellationCheck: TFunc<Boolean> read FCancellationCheck write FCancellationCheck;
    property OnNotification: TMCPNotificationEvent read FOnNotification write FOnNotification;
  end;

implementation

uses
  MCPServer.Types,
  MCPServer.Errors,
  MCPServer.HttpHeaders,
  MCPClient.Errors;

const
  LINE_FEED = #10;
  CARRIAGE_RETURN = #13;
  FIELD_SEPARATOR = ':';
  COMMENT_PREFIX = ':';
  VALUE_SPACE = ' ';
  FIELD_EVENT = 'event';
  FIELD_DATA = 'data';

  QUOTE = '"';
  BACKSLASH = '\';
  COMMA = ',';
  ASSIGNMENT = '=';
  BEARER_SCHEME = 'Bearer ';
  CHALLENGE_SCOPE = 'scope';

  BLANK_TAB = 9;
  BLANK_LINE_FEED = 10;
  BLANK_CARRIAGE_RETURN = 13;
  BLANK_SPACE = 32;
  JSON_OBJECT_START = Ord('{');
  JSON_ARRAY_START = Ord('[');

  HEADER_CONTENT_TYPE = 'Content-Type';
  HEADER_ACCEPT = 'Accept';
  HEADER_AUTHORIZATION = 'Authorization';
  HEADER_WWW_AUTHENTICATE = 'WWW-Authenticate';
  ACCEPT_SEPARATOR = ', ';

  MESSAGE_TRANSPORT = 'The MCP server at %s could not be reached: %s';
  MESSAGE_UNAUTHORIZED = 'The MCP server rejected the bearer token.';
  MESSAGE_FORBIDDEN = 'The MCP server refused the request for lack of an authorisation scope.';
  MESSAGE_FORBIDDEN_SCOPE = 'The MCP server requires the %s scope.';
  MESSAGE_METHOD_NOT_ALLOWED =
    'The MCP endpoint answered 405 Method Not Allowed. The configured URL must accept POST.';
  MESSAGE_TOO_LARGE =
    'The request body is larger than the server accepts. The cap is 4 MB and 64 levels of JSON nesting.';
  MESSAGE_STREAM_ENDED = 'The MCP server closed the event stream without answering request %d.';

{ TMCPSseParser }

class function TMCPSseParser.SequenceLength(const Lead: Byte): Integer;
begin
  if (Lead and $80) = 0 then
    Result := 1
  else if (Lead and $E0) = $C0 then
    Result := 2
  else if (Lead and $F0) = $E0 then
    Result := 3
  else if (Lead and $F8) = $F0 then
    Result := 4
  else
    Result := 1;
end;

class function TMCPSseParser.CompleteByteCount(const Bytes: TBytes): Integer;
begin
  Result := Integer(Length(Bytes));
  if Result = 0 then
    Exit;

  const Lowest = Result - 4;
  var Index := Result - 1;
  while (Index >= 0) and (Index > Lowest) do
  begin
    const IsContinuation = ((Bytes[Index] and $C0) = $80);
    if not IsContinuation then
    begin
      const Needed = SequenceLength(Bytes[Index]);
      if (Result - Index) < Needed then
        Result := Index;
      Exit;
    end;
    Dec(Index);
  end;
end;

procedure TMCPSseParser.Append(const Chunk: string);
begin
  FBuffer := FBuffer + Chunk;
end;

procedure TMCPSseParser.AppendBytes(const Bytes: TBytes);
begin
  if Length(Bytes) = 0 then
    Exit;

  FPending := FPending + Bytes;

  const Complete = CompleteByteCount(FPending);
  if Complete = 0 then
    Exit;

  Append(TEncoding.UTF8.GetString(FPending, 0, Complete));
  FPending := Copy(FPending, Complete, Length(FPending) - Complete);
end;

procedure TMCPSseParser.Finish;
begin
  if Length(FPending) > 0 then
  begin
    Append(TEncoding.UTF8.GetString(FPending));
    FPending := nil;
  end;
  FFinished := True;
end;

procedure TMCPSseParser.Reset;
begin
  FPending := nil;
  FBuffer := '';
  FEventName := '';
  FData := '';
  FHasData := False;
  FHasFrame := False;
  FFinished := False;
end;

function TMCPSseParser.TryNext(out Event: TMCPSseEvent): Boolean;
begin
  Event := Default(TMCPSseEvent);

  var Line: string;
  while TryTakeLine(Line) do
  begin
    const IsFrameTerminator = (Line = '');
    if IsFrameTerminator then
    begin
      if FHasFrame then
      begin
        Event := TakeFrame;
        Exit(True);
      end;
      Continue;
    end;

    const IsComment = Line.StartsWith(COMMENT_PREFIX);
    if not IsComment then
      TakeField(Line);
  end;

  const HasTrailingFrame = (FFinished and FHasFrame);
  if HasTrailingFrame then
  begin
    Event := TakeFrame;
    Exit(True);
  end;

  Result := False;
end;

function TMCPSseParser.TryTakeLine(out Line: string): Boolean;
begin
  Line := '';

  const BreakAt = FBuffer.IndexOf(LINE_FEED);
  if BreakAt < 0 then
  begin
    const HasTail = (FFinished and (FBuffer <> ''));
    if not HasTail then
      Exit(False);

    Line := FBuffer;
    FBuffer := '';
  end
  else
  begin
    Line := FBuffer.Substring(0, BreakAt);
    FBuffer := FBuffer.Substring(BreakAt + 1);
  end;

  if Line.EndsWith(CARRIAGE_RETURN) then
    Line := Line.Substring(0, Length(Line) - 1);

  Result := True;
end;

procedure TMCPSseParser.TakeField(const Line: string);
begin
  var FieldName := Line;
  var Value := '';

  const Colon = Line.IndexOf(FIELD_SEPARATOR);
  if Colon >= 0 then
  begin
    FieldName := Line.Substring(0, Colon);
    Value := Line.Substring(Colon + 1);
    if Value.StartsWith(VALUE_SPACE) then
      Value := Value.Substring(1);
  end;

  if FieldName = FIELD_EVENT then
  begin
    FEventName := Value;
    FHasFrame := True;
  end
  else if FieldName = FIELD_DATA then
  begin
    if FHasData then
      FData := FData + LINE_FEED + Value
    else
      FData := Value;
    FHasData := True;
    FHasFrame := True;
  end;
end;

function TMCPSseParser.TakeFrame: TMCPSseEvent;
begin
  Result.EventName := FEventName;
  Result.Data := FData;

  FEventName := '';
  FData := '';
  FHasData := False;
  FHasFrame := False;
end;

{ TMCPChallengeReader }

class function TMCPChallengeReader.Parameter(const Challenge, Name: string): string;
begin
  Result := '';
  for var Part in SplitParameters(Challenge) do
  begin
    const Text = StripScheme(Part.Trim);
    const Assignment = Text.IndexOf(ASSIGNMENT);
    if Assignment < 0 then
      Continue;

    const Key = Text.Substring(0, Assignment).Trim;
    if SameText(Key, Name) then
      Exit(Unquote(Text.Substring(Assignment + 1).Trim));
  end;
end;

class function TMCPChallengeReader.SplitParameters(const Challenge: string): TArray<string>;
begin
  Result := nil;

  var Start := 1;
  var InQuotes := False;
  var Escaped := False;
  for var Index := 1 to Length(Challenge) do
  begin
    const Character = Challenge[Index];
    if InQuotes then
    begin
      if Escaped then
        Escaped := False
      else if Character = BACKSLASH then
        Escaped := True
      else if Character = QUOTE then
        InQuotes := False;
      Continue;
    end;

    if Character = QUOTE then
      InQuotes := True
    else if Character = COMMA then
    begin
      Result := Result + [Copy(Challenge, Start, Index - Start)];
      Start := Index + 1;
    end;
  end;

  Result := Result + [Copy(Challenge, Start, Length(Challenge) - Start + 1)];
end;

class function TMCPChallengeReader.StripScheme(const Value: string): string;
begin
  Result := Value;
  if not Result.StartsWith(BEARER_SCHEME, True) then
    Exit;
  Result := Result.Substring(Length(BEARER_SCHEME)).Trim;
end;

class function TMCPChallengeReader.Unquote(const Value: string): string;
begin
  const IsQuoted = ((Length(Value) >= 2) and Value.StartsWith(QUOTE) and Value.EndsWith(QUOTE));
  if not IsQuoted then
    Exit(Value);

  Result := '';
  var Escaped := False;
  for var Character in Value.Substring(1, Length(Value) - 2) do
  begin
    const IsEscape = ((Character = BACKSLASH) and not Escaped);
    if IsEscape then
    begin
      Escaped := True;
      Continue;
    end;
    Result := Result + Character;
    Escaped := False;
  end;
end;

{ TMCPHttpRequest }

class function TMCPHttpRequest.Call(const Method, Body: string; const ExpectedId: Int64;
  const MirroredName: string): TMCPHttpRequest;
begin
  Result.Method := Method;
  Result.MirroredName := MirroredName;
  Result.Body := Body;
  Result.ExpectedId := ExpectedId;
  Result.IsNotification := False;
end;

class function TMCPHttpRequest.Notify(const Method, Body: string): TMCPHttpRequest;
begin
  Result.Method := Method;
  Result.MirroredName := '';
  Result.Body := Body;
  Result.ExpectedId := 0;
  Result.IsNotification := True;
end;

{ TMCPHttpResponse }

function TMCPHttpResponse.HasBody: Boolean;
begin
  Result := Body <> '';
end;

{ TMCPHttpTransport }

class function TMCPHttpTransport.ShapeOf(const Bytes: TBytes): TMCPBodyShape;
begin
  for var Value in Bytes do
  begin
    const IsBlank = ((Value = BLANK_TAB) or (Value = BLANK_LINE_FEED) or
      (Value = BLANK_CARRIAGE_RETURN) or (Value = BLANK_SPACE));
    if IsBlank then
      Continue;

    const IsJsonStart = ((Value = JSON_OBJECT_START) or (Value = JSON_ARRAY_START));
    if IsJsonStart then
      Exit(TMCPBodyShape.Json);
    Exit(TMCPBodyShape.EventStream);
  end;
  Result := TMCPBodyShape.Undecided;
end;

class function TMCPHttpTransport.IsNotificationMessage(const Frame: TJSONObject): Boolean;
begin
  const HasMethod = Assigned(Frame.GetValue(MCP_KEY_METHOD));
  const HasId = Assigned(Frame.GetValue(MCP_KEY_ID));
  Result := HasMethod and not HasId;
end;

class function TMCPHttpTransport.IsJsonRpc(const Body: string): Boolean;
begin
  if Body = '' then
    Exit(False);

  var Value := TJSONObject.ParseJSONValue(Body);
  try
    Result := (Value is TJSONObject) and Assigned(TJSONObject(Value).GetValue(MCP_KEY_JSONRPC));
  finally
    Value.Free;
  end;
end;

constructor TMCPHttpTransport.Create(const ServerUrl: string; const Options: TMCPClientOptions;
  const Auth: IMCPClientAuth);
begin
  inherited Create;
  FServerUrl := ServerUrl;
  FOptions := Options;
  FAuth := Auth;
  FEra := Options.Era;
  FParser := TMCPSseParser.Create;

  FClient := THTTPClient.Create;
  FClient.HandleRedirects := False;
  FClient.AllowCookies := False;
  FClient.AutomaticDecompression := [];
  FClient.ConnectionTimeout := Options.ConnectTimeoutMs;
  FClient.SendTimeout := Options.ConnectTimeoutMs;
  FClient.ResponseTimeout := Options.ResponseTimeoutMs;
  FClient.ReceiveDataExCallback :=
    procedure(const Sender: TObject; ContentLength, ReadCount: Int64; Chunk: Pointer;
      ChunkLength: Cardinal; var AbortRead: Boolean)
    begin
      ConsumeChunk(Chunk, ChunkLength);
      AbortRead := FStop or IsCancelled;
    end;
end;

destructor TMCPHttpTransport.Destroy;
begin
  FClient.Free;
  FParser.Free;
  inherited;
end;

function TMCPHttpTransport.Send(const Request: TMCPHttpRequest): TMCPHttpResponse;
begin
  var Token := '';
  if Assigned(FAuth) then
    Token := FAuth.GetToken;

  Result := Execute(Request, Token);

  const NeedsRefresh = ((Result.StatusCode = HTTP_STATUS_UNAUTHORIZED) and Assigned(FAuth) and
    (FOptions.MaxAuthRetries > 0));
  if NeedsRefresh then
  begin
    const Refreshed = FAuth.Refresh;
    if Refreshed <> '' then
      Result := Execute(Request, Refreshed);
  end;

  if Result.SessionId <> '' then
    FSessionId := Result.SessionId;

  CheckStatus(Request, Result);
end;

function TMCPHttpTransport.Execute(const Request: TMCPHttpRequest; const Token: string): TMCPHttpResponse;
begin
  FParser.Reset;
  FShape := TMCPBodyShape.Undecided;
  FCapturedBody := '';
  FExpectedId := Request.ExpectedId;
  FStop := False;
  FCancelled := False;

  var Source := TStringStream.Create(Request.Body, TEncoding.UTF8);
  try
    var Sink := TBytesStream.Create;
    try
      var Response: IHTTPResponse := nil;
      try
        Response := FClient.Post(FServerUrl, Source, Sink, BuildHeaders(Request, Token));
      except
        on E: ENetException do
          raise EMCPClientTransportError.Create(Format(MESSAGE_TRANSPORT, [FServerUrl, E.Message]));
      end;
      Result := ReadResponse(Response, Sink);
    finally
      Sink.Free;
    end;
  finally
    Source.Free;
  end;
end;

function TMCPHttpTransport.BuildHeaders(const Request: TMCPHttpRequest; const Token: string): TNetHeaders;
begin
  Result := [TNetHeader.Create(HEADER_CONTENT_TYPE, MEDIA_TYPE_JSON),
             TNetHeader.Create(HEADER_ACCEPT, AcceptValue)];

  const IsLegacy = (FEra = TMCPClientEra.Legacy);
  if IsLegacy then
  begin
    if FProtocolVersion <> '' then
      Result := Result + [TNetHeader.Create(MCP_HEADER_PROTOCOL_VERSION, FProtocolVersion)];
    if FSessionId <> '' then
      Result := Result + [TNetHeader.Create(MCP_HEADER_SESSION_ID, FSessionId)];
  end
  else
  begin
    Result := Result + [TNetHeader.Create(MCP_HEADER_PROTOCOL_VERSION, ModernProtocolVersion),
                        TNetHeader.Create(MCP_HEADER_METHOD, Request.Method)];
    if Request.MirroredName <> '' then
      Result := Result + [TNetHeader.Create(MCP_HEADER_NAME, TMCPHeaderValue.Encode(Request.MirroredName))];
  end;

  if Token <> '' then
    Result := Result + [TNetHeader.Create(HEADER_AUTHORIZATION, BEARER_SCHEME + Token)];
end;

function TMCPHttpTransport.ModernProtocolVersion: string;
begin
  if FProtocolVersion <> '' then
    Result := FProtocolVersion
  else
    Result := MCP_LATEST_PROTOCOL_VERSION;
end;

function TMCPHttpTransport.AcceptValue: string;
begin
  if FOptions.AcceptEventStream then
    Result := MEDIA_TYPE_JSON + ACCEPT_SEPARATOR + MEDIA_TYPE_EVENT_STREAM
  else
    Result := MEDIA_TYPE_JSON;
end;

procedure TMCPHttpTransport.ConsumeChunk(const Chunk: Pointer; const ChunkLength: Cardinal);
begin
  const HasData = ((Chunk <> nil) and (ChunkLength > 0));
  if not HasData then
    Exit;

  var Bytes: TBytes;
  SetLength(Bytes, ChunkLength);
  Move(PByte(Chunk)^, Bytes[0], ChunkLength);

  if FShape = TMCPBodyShape.Undecided then
    FShape := ShapeOf(Bytes);
  if FShape <> TMCPBodyShape.EventStream then
    Exit;

  FParser.AppendBytes(Bytes);

  var Event: TMCPSseEvent;
  while (not FStop) and FParser.TryNext(Event) do
    HandleFrame(Event);
end;

procedure TMCPHttpTransport.HandleFrame(const Event: TMCPSseEvent);
begin
  if Event.Data = '' then
    Exit;

  var Value := TJSONObject.ParseJSONValue(Event.Data);
  if not (Value is TJSONObject) then
  begin
    Value.Free;
    Exit;
  end;

  try
    const Frame = TJSONObject(Value);
    if IsNotificationMessage(Frame) then
    begin
      DispatchNotification(Frame);
      Exit;
    end;

    if MatchesExpectedId(Frame) then
    begin
      FCapturedBody := Event.Data;
      FStop := True;
    end;
  finally
    Value.Free;
  end;
end;

function TMCPHttpTransport.MatchesExpectedId(const Frame: TJSONObject): Boolean;
begin
  const Id = TMCPRequestId.FromJson(Frame.GetValue(MCP_KEY_ID));
  case Id.Kind of
    TMCPRequestIdKind.Number:
      Result := Id.Number = FExpectedId;
    TMCPRequestIdKind.Text:
      Result := Id.Text = FExpectedId.ToString;
  else
    Result := False;
  end;
end;

procedure TMCPHttpTransport.DispatchNotification(const Notification: TJSONObject);
begin
  if Assigned(FOnNotification) then
    FOnNotification(Notification);
end;

function TMCPHttpTransport.ReadResponse(const Response: IHTTPResponse; const Sink: TBytesStream): TMCPHttpResponse;
begin
  FParser.Finish;

  var Event: TMCPSseEvent;
  while (not FStop) and FParser.TryNext(Event) do
    HandleFrame(Event);

  Result.StatusCode := Response.StatusCode;
  Result.ContentType := Response.MimeType;
  Result.SessionId := Response.HeaderValue[MCP_HEADER_SESSION_ID];
  Result.Challenge := Response.HeaderValue[HEADER_WWW_AUTHENTICATE];
  Result.RequiredScope := TMCPChallengeReader.Parameter(Result.Challenge, CHALLENGE_SCOPE);
  Result.Cancelled := FCancelled;
  Result.Body := '';

  if FCapturedBody <> '' then
  begin
    Result.Body := FCapturedBody;
    Exit;
  end;

  if FShape <> TMCPBodyShape.EventStream then
  begin
    Result.Body := TEncoding.UTF8.GetString(Sink.Bytes, 0, Integer(Sink.Size));
    Exit;
  end;

  const IsSilent = ((Result.StatusCode = HTTP_STATUS_OK) and not FCancelled and (FExpectedId <> 0));
  if IsSilent then
    raise EMCPClientProtocolError.Create(Format(MESSAGE_STREAM_ENDED, [FExpectedId]));
end;

function TMCPHttpTransport.IsCancelled: Boolean;
begin
  if FCancelled then
    Exit(True);
  if not Assigned(FCancellationCheck) then
    Exit(False);

  FCancelled := FCancellationCheck();
  Result := FCancelled;
end;

procedure TMCPHttpTransport.CheckStatus(const Request: TMCPHttpRequest; const Response: TMCPHttpResponse);
begin
  case Response.StatusCode of
    HTTP_STATUS_OK, HTTP_STATUS_ACCEPTED:
      Exit;
    HTTP_STATUS_UNAUTHORIZED:
      raise EMCPClientAuthError.Create(MESSAGE_UNAUTHORIZED, Response.Challenge);
    HTTP_STATUS_FORBIDDEN:
      begin
        if Request.Method = MCP_METHOD_TOOLS_CALL then
          Exit;

        var Text := MESSAGE_FORBIDDEN;
        if Response.RequiredScope <> '' then
          Text := Format(MESSAGE_FORBIDDEN_SCOPE, [Response.RequiredScope]);
        raise EMCPClientScopeError.Create(Text, Response.RequiredScope);
      end;
    HTTP_STATUS_BAD_REQUEST, HTTP_STATUS_NOT_FOUND:
      begin
        if IsJsonRpc(Response.Body) then
          Exit;
        raise EMCPClientError.FromStatus(Response.StatusCode, Response.Body);
      end;
    HTTP_STATUS_METHOD_NOT_ALLOWED:
      raise EMCPClientError.Create(MESSAGE_METHOD_NOT_ALLOWED, Response.StatusCode);
    HTTP_STATUS_PAYLOAD_TOO_LARGE:
      raise EMCPClientRequestTooLarge.Create(MESSAGE_TOO_LARGE, Response.StatusCode);
  else
    raise EMCPClientError.FromStatus(Response.StatusCode, Response.Body);
  end;
end;

end.
