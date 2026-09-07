unit MCPClient;

// TMCPClient, the call flow over MCPClient.Http. This unit owns the handshake, the JSON-RPC
// envelope, the tool cache and the outcome parsing; the transport owns the wire.
//
// The legacy era is the handshake every MCP server has spoken since 2025: one initialize request,
// one notifications/initialized notification, then plain requests that carry the negotiated version
// in MCP-Protocol-Version and the session id the server handed out, when it handed one out. An
// unknown protocol version is not an error in this era, so the client stores whatever
// result.protocolVersion says and never retries the handshake.
//
// Auto resolves to the legacy era in this build. The modern era and its server/discover probe are a
// separate change, and until it lands a caller that asks for TMCPClientEra.Modern is told so rather
// than being given a legacy connection under a modern name.
//
// Nothing a tool can cause unwinds the caller: a JSON-RPC error from tools/call, an isError result
// and a call for a tool that does not exist all become a TMCPToolCallOutcome. A broken transport, a
// failed handshake, a refused scope on another method and a response carrying a different request id
// raise, because the caller cannot carry on.

interface

uses
  System.SysUtils,
  System.JSON,
  MCPClient.Types,
  MCPClient.Interfaces,
  MCPClient.Http;

type
  TMCPClient = class(TInterfacedObject, IMCPClient)
  strict private
    FTransport: TMCPHttpTransport;
    FOptions: TMCPClientOptions;
    FServerUrl: string;
    FEra: TMCPClientEra;
    FProtocolVersion: string;
    FServerInfoJson: string;
    FConnected: Boolean;
    FNextId: Int64;
    FTools: TArray<TMCPRemoteTool>;
    FHasTools: Boolean;
    FInputResponder: TMCPInputResponder;
    FSink: IMCPClientSink;
    FNamePrefix: string;
    FOnRequestBody: TProc<string>;

    function TakeId: Int64;
    function BuildBody(const Method: string; const Params: TJSONObject; const Id: Int64): string;
    function Post(const Method, MirroredName: string; const Params: TJSONObject;
      out Http: TMCPHttpResponse): TJSONObject;
    procedure PostNotification(const Method: string);
    procedure CheckResponseId(const Response: TJSONObject; const Expected: Int64);
    function ResultOf(const Method: string; const Response: TJSONObject): TJSONObject;
    procedure RaiseServerError(const Method: string; const Response: TJSONObject);

    procedure ConnectLegacy;
    function InitializeParams: TJSONObject;
    function ClientCapabilities: TJSONObject;
    function ClientInfo: TJSONObject;

    procedure LoadTools;
    function ReadTool(const Value: TJSONValue): TMCPRemoteTool;
    function ReadOutcome(const Response: TJSONObject; const Http: TMCPHttpResponse): TMCPToolCallOutcome;
    function ErrorOutcome(const Error: TJSONObject; const Http: TMCPHttpResponse): TMCPToolCallOutcome;
    procedure ReadContent(const Content: TJSONArray; var Outcome: TMCPToolCallOutcome);

    class function SummariseBlock(const Block: TJSONObject): string; static;
    class function ResourceByteCount(const Resource: TJSONObject): Integer; static;
    class function Base64ByteCount(const Data: string): Integer; static;
    class function TextOf(const Owner: TJSONObject; const Name: string): string; static;
    class function JsonOf(const Owner: TJSONObject; const Name: string): string; static;
    class function BoolOf(const Owner: TJSONObject; const Name: string): Boolean; static;
    class function ObjectOf(const Owner: TJSONObject; const Name: string): TJSONObject; static;
  public
    constructor Create(const AServerUrl: string; const AOptions: TMCPClientOptions;
      const AAuth: IMCPClientAuth = nil);
    destructor Destroy; override;

    procedure Connect;
    procedure Close;
    function IsConnected: Boolean;
    function Era: TMCPClientEra;
    function ProtocolVersion: string;
    function ServerUrl: string;
    function ServerInfoJson: string;
    function ListTools: TArray<TMCPRemoteTool>;
    procedure RefreshTools;
    { The arguments stay the caller's: they are copied into the request. }
    function CallTool(const Name: string; const Arguments: TJSONObject): TMCPToolCallOutcome;
    procedure SetInputResponder(const Responder: TMCPInputResponder);
    procedure SetSink(const Sink: IMCPClientSink);
    procedure SetCancellationCheck(const Check: TFunc<Boolean>);

    { Read by a host that presents remote tools beside its own, never by the protocol. }
    property NamePrefix: string read FNamePrefix write FNamePrefix;
    { Every request body just before it goes on the wire, which is what a host traces. }
    property OnRequestBody: TProc<string> read FOnRequestBody write FOnRequestBody;
  end;

implementation

uses
  MCPServer.Types,
  MCPServer.Mrtr,
  MCPClient.Errors;

const
  KEY_CLIENT_INFO = 'clientInfo';
  KEY_SERVER_INFO = 'serverInfo';
  KEY_TOOLS = 'tools';
  KEY_NEXT_CURSOR = 'nextCursor';
  KEY_INPUT_SCHEMA = 'inputSchema';
  KEY_OUTPUT_SCHEMA = 'outputSchema';
  KEY_STRUCTURED_CONTENT = 'structuredContent';
  KEY_IS_ERROR = 'isError';
  KEY_INPUT_REQUESTS = 'inputRequests';
  KEY_CODE = 'code';
  KEY_MESSAGE = 'message';
  KEY_DATA = 'data';
  KEY_REQUIRED_SCOPE = 'requiredScope';
  KEY_BLOB = 'blob';

  BLOCK_TYPE_TEXT = 'text';
  BLOCK_TYPE_RESOURCE = 'resource';
  BLOCK_TYPE_RESOURCE_LINK = 'resource_link';

  CAPABILITY_ELICITATION = 'elicitation';
  CAPABILITY_SAMPLING = 'sampling';
  CAPABILITY_ROOTS = 'roots';

  RESULT_TYPE_COMPLETE = 'complete';

  BASE64_GROUP = 4;
  BASE64_GROUP_BYTES = 3;
  BASE64_PADDING = '=';

  SUMMARY_SIZED = '%s %s %d bytes';
  SUMMARY_LINK = '%s %s';

  MESSAGE_MODERN_UNAVAILABLE =
    'This client speaks the legacy MCP era only. Construct it with TMCPClientEra.Legacy or Auto.';
  MESSAGE_NO_RESULT = 'The MCP server answered %s with neither a result nor an error.';
  MESSAGE_SERVER_ERROR = 'The MCP server refused %s: %s';
  MESSAGE_ID_MISMATCH = 'The MCP server answered request %d with a response for a different request.';
  MESSAGE_REPEATED_CURSOR = 'The MCP server repeated the tools/list cursor "%s".';

{ TMCPClient }

constructor TMCPClient.Create(const AServerUrl: string; const AOptions: TMCPClientOptions;
  const AAuth: IMCPClientAuth);
begin
  inherited Create;
  FServerUrl := AServerUrl;
  FOptions := AOptions;
  FEra := AOptions.Era;
  FTransport := TMCPHttpTransport.Create(AServerUrl, AOptions, AAuth);
end;

destructor TMCPClient.Destroy;
begin
  FTransport.Free;
  inherited;
end;

function TMCPClient.TakeId: Int64;
begin
  Inc(FNextId);
  Result := FNextId;
end;

function TMCPClient.BuildBody(const Method: string; const Params: TJSONObject; const Id: Int64): string;
begin
  const Request = TJSONObject.Create;
  try
    Request.AddPair(MCP_KEY_JSONRPC, JSONRPC_VERSION);
    const IsNotification = (Id = 0);
    if not IsNotification then
      Request.AddPair(MCP_KEY_ID, TJSONNumber.Create(Id));
    Request.AddPair(MCP_KEY_METHOD, Method);
    if Assigned(Params) then
      Request.AddPair(MCP_KEY_PARAMS, Params);
    Result := Request.ToJSON;
  finally
    Request.Free;
  end;

  if Assigned(FOnRequestBody) then
    FOnRequestBody(Result);
end;

function TMCPClient.Post(const Method, MirroredName: string; const Params: TJSONObject;
  out Http: TMCPHttpResponse): TJSONObject;
begin
  const Id = TakeId;
  const Body = BuildBody(Method, Params, Id);

  Http := FTransport.Send(TMCPHttpRequest.Call(Method, Body, Id, MirroredName));
  if not Http.HasBody then
    Exit(nil);

  const Value = TJSONObject.ParseJSONValue(Http.Body);
  if not (Value is TJSONObject) then
  begin
    Value.Free;
    raise EMCPClientProtocolError.Create(Format(MESSAGE_NO_RESULT, [Method]));
  end;

  Result := TJSONObject(Value);
  try
    CheckResponseId(Result, Id);
  except
    Result.Free;
    raise;
  end;
end;

procedure TMCPClient.PostNotification(const Method: string);
begin
  FTransport.Send(TMCPHttpRequest.Notify(Method, BuildBody(Method, nil, 0)));
end;

procedure TMCPClient.CheckResponseId(const Response: TJSONObject; const Expected: Int64);
begin
  const Id = TMCPRequestId.FromJson(Response.GetValue(MCP_KEY_ID));

  // A response that names no request at all is the server reporting on the message it could not
  // read, and its own message says more than an id mismatch would.
  const NamesNoRequest = (Id.Kind in [TMCPRequestIdKind.None, TMCPRequestIdKind.Null]);
  if NamesNoRequest then
    Exit;

  var Matches := False;
  case Id.Kind of
    TMCPRequestIdKind.Number:
      Matches := Id.Number = Expected;
    TMCPRequestIdKind.Text:
      Matches := Id.Text = Expected.ToString;
  end;

  if not Matches then
    raise EMCPClientProtocolError.Create(Format(MESSAGE_ID_MISMATCH, [Expected]));
end;

function TMCPClient.ResultOf(const Method: string; const Response: TJSONObject): TJSONObject;
begin
  RaiseServerError(Method, Response);

  Result := ObjectOf(Response, MCP_KEY_RESULT);
  if not Assigned(Result) then
    raise EMCPClientProtocolError.Create(Format(MESSAGE_NO_RESULT, [Method]));
end;

procedure TMCPClient.RaiseServerError(const Method: string; const Response: TJSONObject);
begin
  const Error = ObjectOf(Response, MCP_KEY_ERROR);
  if not Assigned(Error) then
    Exit;

  const Message = TextOf(Error, KEY_MESSAGE);
  var Code := 0;
  const CodeValue = Error.GetValue(KEY_CODE);
  if CodeValue is TJSONNumber then
    Code := TJSONNumber(CodeValue).AsInt;

  raise EMCPClientError.Create(Format(MESSAGE_SERVER_ERROR, [Method, Message]), 0, Code);
end;

procedure TMCPClient.Connect;
begin
  if FConnected then
    Exit;

  const WantsModern = (FOptions.Era = TMCPClientEra.Modern);
  if WantsModern then
    raise EMCPClientError.Create(MESSAGE_MODERN_UNAVAILABLE);

  ConnectLegacy;
end;

procedure TMCPClient.ConnectLegacy;
begin
  FEra := TMCPClientEra.Legacy;
  FTransport.Era := FEra;
  FTransport.ProtocolVersion := '';

  var Http: TMCPHttpResponse;
  const Response = Post(MCP_METHOD_INITIALIZE, '', InitializeParams, Http);
  try
    const Outcome = ResultOf(MCP_METHOD_INITIALIZE, Response);

    FProtocolVersion := TextOf(Outcome, MCP_KEY_PROTOCOL_VERSION);
    if FProtocolVersion = '' then
      FProtocolVersion := MCP_LATEST_LEGACY_PROTOCOL_VERSION;
    FServerInfoJson := JsonOf(Outcome, KEY_SERVER_INFO);
  finally
    Response.Free;
  end;

  FTransport.ProtocolVersion := FProtocolVersion;
  PostNotification(MCP_METHOD_NOTIFICATIONS_INITIALIZED);
  FConnected := True;
end;

function TMCPClient.InitializeParams: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair(MCP_KEY_PROTOCOL_VERSION, MCP_LATEST_LEGACY_PROTOCOL_VERSION);
  Result.AddPair(MCP_KEY_CAPABILITIES, ClientCapabilities);
  Result.AddPair(KEY_CLIENT_INFO, ClientInfo);
end;

function TMCPClient.ClientCapabilities: TJSONObject;
begin
  Result := TJSONObject.Create;

  // A capability the client cannot honour earns a server request it cannot answer, so the set
  // follows the input responder rather than being declared once and for all.
  if not Assigned(FInputResponder) then
    Exit;

  Result.AddPair(CAPABILITY_ELICITATION, TJSONObject.Create);
  Result.AddPair(CAPABILITY_SAMPLING, TJSONObject.Create);
  Result.AddPair(CAPABILITY_ROOTS, TJSONObject.Create);
end;

function TMCPClient.ClientInfo: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair(MCP_KEY_NAME, FOptions.ClientName);
  Result.AddPair(MCP_KEY_VERSION, FOptions.ClientVersion);
end;

procedure TMCPClient.Close;
begin
  FConnected := False;
  FHasTools := False;
  FTools := nil;
  FProtocolVersion := '';
  FServerInfoJson := '';
  FTransport.SessionId := '';
  FTransport.ProtocolVersion := '';
end;

function TMCPClient.IsConnected: Boolean;
begin
  Result := FConnected;
end;

function TMCPClient.Era: TMCPClientEra;
begin
  Result := FEra;
end;

function TMCPClient.ProtocolVersion: string;
begin
  Result := FProtocolVersion;
end;

function TMCPClient.ServerUrl: string;
begin
  Result := FServerUrl;
end;

function TMCPClient.ServerInfoJson: string;
begin
  Result := FServerInfoJson;
end;

function TMCPClient.ListTools: TArray<TMCPRemoteTool>;
begin
  Connect;

  if not FHasTools then
    LoadTools;
  Result := FTools;
end;

procedure TMCPClient.RefreshTools;
begin
  Connect;
  LoadTools;
end;

procedure TMCPClient.LoadTools;
begin
  var Tools: TArray<TMCPRemoteTool> := nil;
  var Cursor := '';

  repeat
    var Params: TJSONObject := nil;
    if Cursor <> '' then
    begin
      Params := TJSONObject.Create;
      Params.AddPair(MCP_KEY_CURSOR, Cursor);
    end;

    var Http: TMCPHttpResponse;
    const Response = Post(MCP_METHOD_TOOLS_LIST, '', Params, Http);
    try
      const Outcome = ResultOf(MCP_METHOD_TOOLS_LIST, Response);

      const Listed = Outcome.GetValue(KEY_TOOLS);
      if Listed is TJSONArray then
        for var Value in TJSONArray(Listed) do
          Tools := Tools + [ReadTool(Value)];

      const NextCursor = TextOf(Outcome, KEY_NEXT_CURSOR);
      const IsRepeat = ((NextCursor <> '') and (NextCursor = Cursor));
      if IsRepeat then
        raise EMCPClientProtocolError.Create(Format(MESSAGE_REPEATED_CURSOR, [NextCursor]));
      Cursor := NextCursor;
    finally
      Response.Free;
    end;
  until Cursor = '';

  FTools := Tools;
  FHasTools := True;
end;

function TMCPClient.ReadTool(const Value: TJSONValue): TMCPRemoteTool;
begin
  Result := Default(TMCPRemoteTool);
  if not (Value is TJSONObject) then
    Exit;

  const Tool = TJSONObject(Value);
  Result.Name := TextOf(Tool, MCP_KEY_NAME);
  Result.Title := TextOf(Tool, MCP_KEY_TITLE);
  Result.Description := TextOf(Tool, MCP_KEY_DESCRIPTION);

  Result.InputSchemaJson := JsonOf(Tool, KEY_INPUT_SCHEMA);
  if Result.InputSchemaJson = '' then
    Result.InputSchemaJson := MCP_CLIENT_EMPTY_INPUT_SCHEMA;
  Result.OutputSchemaJson := JsonOf(Tool, KEY_OUTPUT_SCHEMA);

  const Annotations = ObjectOf(Tool, MCP_KEY_ANNOTATIONS);
  Result.HasAnnotations := Assigned(Annotations);
  if not Result.HasAnnotations then
    Exit;

  Result.ReadOnlyHint := BoolOf(Annotations, MCP_ANNOTATION_READ_ONLY_HINT);
  Result.OpenWorldHint := BoolOf(Annotations, MCP_ANNOTATION_OPEN_WORLD_HINT);
end;

function TMCPClient.CallTool(const Name: string; const Arguments: TJSONObject): TMCPToolCallOutcome;
begin
  Connect;

  const Params = TJSONObject.Create;
  Params.AddPair(MCP_KEY_NAME, Name);
  if Assigned(Arguments) then
    Params.AddPair(MCP_KEY_ARGUMENTS, TJSONObject(Arguments.Clone))
  else
    Params.AddPair(MCP_KEY_ARGUMENTS, TJSONObject.Create);

  var Http: TMCPHttpResponse;
  const Response = Post(MCP_METHOD_TOOLS_CALL, Name, Params, Http);
  try
    Result := ReadOutcome(Response, Http);
  finally
    Response.Free;
  end;
end;

function TMCPClient.ReadOutcome(const Response: TJSONObject; const Http: TMCPHttpResponse): TMCPToolCallOutcome;
begin
  Result := Default(TMCPToolCallOutcome);

  if not Assigned(Response) then
    Exit(TMCPToolCallOutcome.CreateError(Format(MESSAGE_NO_RESULT, [MCP_METHOD_TOOLS_CALL])));

  const Error = ObjectOf(Response, MCP_KEY_ERROR);
  if Assigned(Error) then
    Exit(ErrorOutcome(Error, Http));

  const Outcome = ObjectOf(Response, MCP_KEY_RESULT);
  if not Assigned(Outcome) then
    Exit(TMCPToolCallOutcome.CreateError(Format(MESSAGE_NO_RESULT, [MCP_METHOD_TOOLS_CALL])));

  Result.IsError := BoolOf(Outcome, KEY_IS_ERROR);
  Result.StructuredJson := JsonOf(Outcome, KEY_STRUCTURED_CONTENT);

  const Content = Outcome.GetValue(MCP_KEY_CONTENT);
  if Content is TJSONArray then
    ReadContent(TJSONArray(Content), Result);

  const HasNoText = (Result.Text = '');
  if HasNoText and (Result.StructuredJson <> '') then
    Result.Text := Result.StructuredJson;

  Result.ResultType := TextOf(Outcome, MCP_KEY_RESULT_TYPE);
  if Result.ResultType = '' then
    Result.ResultType := RESULT_TYPE_COMPLETE;

  const IsInputRequired = (Result.ResultType = RESULT_TYPE_INPUT_REQUIRED);
  if not IsInputRequired then
    Exit;

  Result.InputRequestsJson := JsonOf(Outcome, KEY_INPUT_REQUESTS);
  Result.RequestState := JsonOf(Outcome, MCP_KEY_REQUEST_STATE);
end;

function TMCPClient.ErrorOutcome(const Error: TJSONObject; const Http: TMCPHttpResponse): TMCPToolCallOutcome;
begin
  var Code := 0;
  const CodeValue = Error.GetValue(KEY_CODE);
  if CodeValue is TJSONNumber then
    Code := TJSONNumber(CodeValue).AsInt;

  Result := TMCPToolCallOutcome.CreateError(TextOf(Error, KEY_MESSAGE), Code);

  Result.RequiredScope := Http.RequiredScope;
  const Data = ObjectOf(Error, KEY_DATA);
  if Assigned(Data) and (TextOf(Data, KEY_REQUIRED_SCOPE) <> '') then
    Result.RequiredScope := TextOf(Data, KEY_REQUIRED_SCOPE);
end;

procedure TMCPClient.ReadContent(const Content: TJSONArray; var Outcome: TMCPToolCallOutcome);
begin
  Outcome.ContentJson := Content.ToJSON;

  var Text := '';
  var HasText := False;
  for var Value in Content do
  begin
    if not (Value is TJSONObject) then
      Continue;

    const Block = TJSONObject(Value);
    const IsText = (TextOf(Block, MCP_KEY_TYPE) = BLOCK_TYPE_TEXT);
    if not IsText then
    begin
      Outcome.NonTextBlocks := Outcome.NonTextBlocks + [SummariseBlock(Block)];
      Continue;
    end;

    if HasText then
      Text := Text + sLineBreak;
    Text := Text + TextOf(Block, MCP_KEY_TEXT);
    HasText := True;
  end;

  Outcome.Text := Text;
end;

class function TMCPClient.SummariseBlock(const Block: TJSONObject): string;
begin
  const Kind = TextOf(Block, MCP_KEY_TYPE);

  const IsLink = (Kind = BLOCK_TYPE_RESOURCE_LINK);
  if IsLink then
    Exit(Format(SUMMARY_LINK, [Kind, TextOf(Block, MCP_KEY_URI)]));

  const Resource = ObjectOf(Block, BLOCK_TYPE_RESOURCE);
  if Assigned(Resource) then
    Exit(Format(SUMMARY_SIZED,
      [Kind, TextOf(Resource, MCP_KEY_MIME_TYPE), ResourceByteCount(Resource)]));

  const Data = TextOf(Block, KEY_DATA);
  if Data <> '' then
    Exit(Format(SUMMARY_SIZED, [Kind, TextOf(Block, MCP_KEY_MIME_TYPE), Base64ByteCount(Data)]));

  Result := Kind;
end;

class function TMCPClient.ResourceByteCount(const Resource: TJSONObject): Integer;
begin
  const Blob = TextOf(Resource, KEY_BLOB);
  if Blob <> '' then
    Exit(Base64ByteCount(Blob));

  Result := TEncoding.UTF8.GetByteCount(TextOf(Resource, MCP_KEY_TEXT));
end;

class function TMCPClient.Base64ByteCount(const Data: string): Integer;
begin
  var Characters := 0;
  var Padding := 0;
  for var Character in Data do
  begin
    const IsBlank = CharInSet(Character, [#9, #10, #13, ' ']);
    if IsBlank then
      Continue;

    Inc(Characters);
    if Character = BASE64_PADDING then
      Inc(Padding);
  end;

  Result := (Characters div BASE64_GROUP) * BASE64_GROUP_BYTES - Padding;
  if Result < 0 then
    Result := 0;
end;

class function TMCPClient.TextOf(const Owner: TJSONObject; const Name: string): string;
begin
  Result := '';
  if not Assigned(Owner) then
    Exit;

  const Value = Owner.GetValue(Name);
  if Value is TJSONString then
    Result := TJSONString(Value).Value;
end;

class function TMCPClient.JsonOf(const Owner: TJSONObject; const Name: string): string;
begin
  Result := '';
  if not Assigned(Owner) then
    Exit;

  const Value = Owner.GetValue(Name);
  const IsWritable = ((Value is TJSONObject) or (Value is TJSONArray));
  if IsWritable then
    Result := Value.ToJSON
  else if Value is TJSONString then
    Result := TJSONString(Value).Value;
end;

class function TMCPClient.BoolOf(const Owner: TJSONObject; const Name: string): Boolean;
begin
  Result := False;
  if not Assigned(Owner) then
    Exit;

  const Value = Owner.GetValue(Name);
  if Value is TJSONBool then
    Result := TJSONBool(Value).AsBoolean;
end;

class function TMCPClient.ObjectOf(const Owner: TJSONObject; const Name: string): TJSONObject;
begin
  Result := nil;
  if not Assigned(Owner) then
    Exit;

  const Value = Owner.GetValue(Name);
  if Value is TJSONObject then
    Result := TJSONObject(Value);
end;

procedure TMCPClient.SetInputResponder(const Responder: TMCPInputResponder);
begin
  FInputResponder := Responder;
end;

procedure TMCPClient.SetSink(const Sink: IMCPClientSink);
begin
  FSink := Sink;
end;

procedure TMCPClient.SetCancellationCheck(const Check: TFunc<Boolean>);
begin
  FTransport.CancellationCheck := Check;
end;

end.
