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
// The modern era has no handshake. One server/discover request reports what the server speaks, and
// every later request repeats the protocol version, the client capabilities and the client
// identity in params._meta, mirrored by the MCP-Protocol-Version, Mcp-Method and Mcp-Name headers.
//
// Auto sends the modern probe first and falls back to the legacy handshake on the three answers a
// legacy server gives it, and only on those: an unknown method, the -32602 that names the missing
// params._meta protocol version, and the -32600 that refuses the modern version header. Any other
// error, a -32602 that means the parameters really were wrong included, is the server saying
// something the caller must hear, so it raises instead of quietly dropping an era.
//
// Nothing a tool can cause unwinds the caller: a JSON-RPC error from tools/call, an isError result
// and a call for a tool that does not exist all become a TMCPToolCallOutcome. A broken transport, a
// failed handshake, a refused scope on another method and a response carrying a different request id
// raise, because the caller cannot carry on.
//
// Three things happen while a call is in flight. Notifications the server streams beside the answer
// reach IMCPClientSink, so a host can show progress and log lines as they arrive rather than after
// the fact. A server that answers input_required is answered again, up to MaxInputRounds times,
// with the responder's answers and its own requestState echoed back untouched. And a cancellation
// check that turns True aborts the read, tells the server on a second connection and gives the
// caller a cancelled outcome instead of half an answer.

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Types,
  MCPClient.Types,
  MCPClient.Interfaces,
  MCPClient.Http;

const
  { The path prefix the server prints in front of a _meta member it missed. The server builds its
    own copy in MCPServer.JsonRpcProcessor, which keeps it private, so the two are pinned to each
    other by a test rather than by a shared constant. }
  MCP_CLIENT_META_PATH_PREFIX = 'params._meta.';
  { The two messages the era probe matches on. Matching the message and not the bare code matters:
    -32602 is also the ordinary invalid-params code of the modern era. }
  MCP_CLIENT_DISCOVER_REQUIRES_META =
    MCP_METHOD_SERVER_DISCOVER + ' requires ' + MCP_CLIENT_META_PATH_PREFIX + MCP_META_PROTOCOL_VERSION;
  MCP_CLIENT_UNSUPPORTED_VERSION_HEADER = 'Unsupported ' + MCP_HEADER_PROTOCOL_VERSION + ' header';

type
  TMCPClient = class(TInterfacedObject, IMCPClient)
  strict private
  type
    { What the server answered the server/discover probe with, and whether that answer means the
      server speaks the legacy era rather than that the probe itself was wrong. }
    TProbeFailure = record
      Code: Integer;
      Text: string;
      Retry: string;
      function IsLegacyServer: Boolean;
    end;
  strict private
    FTransport: TMCPHttpTransport;
    FOptions: TMCPClientOptions;
    FServerUrl: string;
    FEra: TMCPClientEra;
    FProtocolVersion: string;
    FServerInfoJson: string;
    FSupportedVersions: TArray<string>;
    FCapabilitiesJson: string;
    FDiscoverTtlMs: Integer;
    FCacheScope: string;
    FConnected: Boolean;
    FNextId: Int64;
    FTools: TArray<TMCPRemoteTool>;
    FHasTools: Boolean;
    FInputResponder: TMCPInputResponder;
    FSink: IMCPClientSink;
    FAuth: IMCPClientAuth;
    FInFlightId: Int64;
    FCancellationSent: Boolean;
    FNamePrefix: string;
    FOnRequestBody: TProc<string>;
    FOnResponseBody: TProc<string>;

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

    function TryConnectModern(const AllowFallback: Boolean): Boolean;
    procedure BeginModern(const Version: string);
    function TryDiscover(out Failure: TProbeFailure): Boolean;
    procedure ReadDiscovery(const Outcome: TJSONObject);
    function IsModernEra: Boolean;
    function RequestParams(const Params: TJSONObject; const Id: Int64): TJSONObject;
    function ModernMeta(const Id: Int64): TJSONObject;
    class function HighestOfferedVersion(const Data: TJSONObject): string; static;

    procedure LoadTools;
    function ReadTool(const Value: TJSONValue): TMCPRemoteTool;
    function CallParams(const Name: string; const Arguments, Responses: TJSONObject;
      const RequestState: string): TJSONObject;
    function PostCall(const Name: string; const Params: TJSONObject): TMCPToolCallOutcome;
    function ReadOutcome(const Response: TJSONObject; const Http: TMCPHttpResponse): TMCPToolCallOutcome;
    function ErrorOutcome(const Error: TJSONObject; const Http: TMCPHttpResponse): TMCPToolCallOutcome;
    procedure ReadContent(const Content: TJSONArray; var Outcome: TMCPToolCallOutcome);

    function AnswerInputRequests(const Name: string; const Arguments: TJSONObject;
      const First: TMCPToolCallOutcome): TMCPToolCallOutcome;
    function TryBuildInputResponses(const RequestsJson: string; out Responses: TJSONObject;
      out Failure: string): Boolean;

    procedure DispatchNotification(const Notification: TJSONObject);
    procedure ReportProgress(const Params: TJSONObject);
    procedure ReportLogMessage(const Params: TJSONObject);
    procedure CancelInFlight;

    class function SummariseBlock(const Block: TJSONObject): string; static;
    class function ResourceByteCount(const Resource: TJSONObject): Integer; static;
    class function Base64ByteCount(const Data: string): Integer; static;
    class function TextOf(const Owner: TJSONObject; const Name: string): string; static;
    class function TokenText(const Value: TJSONValue): string; static;
    class function NumberOf(const Owner: TJSONObject; const Name: string;
      const Missing: Double): Double; static;
    class function JsonOf(const Owner: TJSONObject; const Name: string): string; static;
    class function IntOf(const Owner: TJSONObject; const Name: string): Integer; static;
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
    { What server/discover reported, empty until a modern connection is made. }
    property SupportedVersions: TArray<string> read FSupportedVersions;
    property CapabilitiesJson: string read FCapabilitiesJson;
    property DiscoverTtlMs: Integer read FDiscoverTtlMs;
    property CacheScope: string read FCacheScope;
    { Every request body just before it goes on the wire, and every response body as it comes
      back, which is what a host traces. }
    property OnRequestBody: TProc<string> read FOnRequestBody write FOnRequestBody;
    property OnResponseBody: TProc<string> read FOnResponseBody write FOnResponseBody;
  end;

implementation

uses
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
  KEY_SUPPORTED = 'supported';
  KEY_SUPPORTED_VERSIONS = 'supportedVersions';

  BLOCK_TYPE_TEXT = 'text';
  BLOCK_TYPE_RESOURCE = 'resource';
  BLOCK_TYPE_RESOURCE_LINK = 'resource_link';

  CAPABILITY_ELICITATION = 'elicitation';
  CAPABILITY_SAMPLING = 'sampling';
  CAPABILITY_ROOTS = 'roots';

  KEY_REQUEST_ID = 'requestId';
  KEY_REASON = 'reason';
  KEY_PROGRESS = 'progress';
  KEY_TOTAL = 'total';
  KEY_LEVEL = 'level';
  KEY_LOGGER = 'logger';

  RESULT_TYPE_COMPLETE = 'complete';

  { What the server is told when a call is abandoned, and what the caller is told in return. }
  CANCELLATION_REASON = 'client cancelled';
  { A progress notification without a total says nothing about how much work is left. }
  PROGRESS_TOTAL_UNKNOWN = -1;

  BASE64_GROUP = 4;
  BASE64_GROUP_BYTES = 3;
  BASE64_PADDING = '=';

  SUMMARY_SIZED = '%s %s %d bytes';
  SUMMARY_LINK = '%s %s';

  MESSAGE_NO_RESULT = 'The MCP server answered %s with neither a result nor an error.';
  MESSAGE_SERVER_ERROR = 'The MCP server refused %s: %s';
  MESSAGE_ID_MISMATCH = 'The MCP server answered request %d with a response for a different request.';
  MESSAGE_REPEATED_CURSOR = 'The MCP server repeated the tools/list cursor "%s".';
  MESSAGE_NO_RESPONDER = 'The server asked for client input and no input responder is configured.';
  MESSAGE_TOO_MANY_ROUNDS = 'The server asked for input more than %d times.';
  MESSAGE_NO_ANSWER = 'The input responder produced no answer for %s.';
  MESSAGE_CANCELLED = 'The tool call was cancelled.';

{ TMCPClient }

constructor TMCPClient.Create(const AServerUrl: string; const AOptions: TMCPClientOptions;
  const AAuth: IMCPClientAuth);
begin
  inherited Create;
  FServerUrl := AServerUrl;
  FOptions := AOptions;
  FEra := AOptions.Era;
  FAuth := AAuth;
  FTransport := TMCPHttpTransport.Create(AServerUrl, AOptions, AAuth);
  FTransport.OnNotification :=
    procedure(const Notification: TJSONObject)
    begin
      DispatchNotification(Notification);
    end;
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
  const Body = BuildBody(Method, RequestParams(Params, Id), Id);

  // The id is what a cancellation names, and it is only nameable while the request is in flight.
  FInFlightId := Id;
  FCancellationSent := False;
  try
    Http := FTransport.Send(TMCPHttpRequest.Call(Method, Body, Id, MirroredName));
  finally
    FInFlightId := 0;
  end;

  if not Http.HasBody then
    Exit(nil);

  if Assigned(FOnResponseBody) then
    FOnResponseBody(Http.Body);

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

  raise EMCPClientError.Create(
    Format(MESSAGE_SERVER_ERROR, [Method, TextOf(Error, KEY_MESSAGE)]), 0, IntOf(Error, KEY_CODE));
end;

procedure TMCPClient.Connect;
begin
  if FConnected then
    Exit;

  case FOptions.Era of
    TMCPClientEra.Legacy:
      ConnectLegacy;
    TMCPClientEra.Modern:
      TryConnectModern(False);
  else
    if not TryConnectModern(True) then
      ConnectLegacy;
  end;
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

{ TMCPClient.TProbeFailure }

function TMCPClient.TProbeFailure.IsLegacyServer: Boolean;
begin
  case Code of
    JSONRPC_METHOD_NOT_FOUND:
      Result := True;
    JSONRPC_INVALID_PARAMS:
      Result := (Text = MCP_CLIENT_DISCOVER_REQUIRES_META);
    JSONRPC_INVALID_REQUEST:
      Result := Text.StartsWith(MCP_CLIENT_UNSUPPORTED_VERSION_HEADER);
  else
    Result := False;
  end;
end;

function TMCPClient.TryConnectModern(const AllowFallback: Boolean): Boolean;
begin
  BeginModern(MCP_LATEST_PROTOCOL_VERSION);

  var Failure: TProbeFailure;
  if TryDiscover(Failure) then
    Exit(True);

  // -32022 names the versions the server does speak. One retry with the highest of them, and only
  // when it is a version this attempt did not already use, so a stubborn server cannot loop us.
  const CanRetry = ((Failure.Code = MCP_ERROR_UNSUPPORTED_PROTOCOL_VERSION) and
    (Failure.Retry <> '') and (Failure.Retry <> FProtocolVersion));
  if CanRetry then
  begin
    BeginModern(Failure.Retry);
    if TryDiscover(Failure) then
      Exit(True);
  end;

  const FallsBack = (AllowFallback and Failure.IsLegacyServer);
  if not FallsBack then
    raise EMCPClientError.Create(
      Format(MESSAGE_SERVER_ERROR, [MCP_METHOD_SERVER_DISCOVER, Failure.Text]), 0, Failure.Code);

  Result := False;
end;

procedure TMCPClient.BeginModern(const Version: string);
begin
  FEra := TMCPClientEra.Modern;
  FProtocolVersion := Version;
  FTransport.Era := FEra;
  FTransport.ProtocolVersion := Version;
  FTransport.SessionId := '';
end;

function TMCPClient.TryDiscover(out Failure: TProbeFailure): Boolean;
begin
  Failure := Default(TProbeFailure);

  var Http: TMCPHttpResponse;
  const Response = Post(MCP_METHOD_SERVER_DISCOVER, '', nil, Http);
  if not Assigned(Response) then
    raise EMCPClientProtocolError.Create(Format(MESSAGE_NO_RESULT, [MCP_METHOD_SERVER_DISCOVER]));

  try
    const Error = ObjectOf(Response, MCP_KEY_ERROR);
    if Assigned(Error) then
    begin
      Failure.Code := IntOf(Error, KEY_CODE);
      Failure.Text := TextOf(Error, KEY_MESSAGE);
      Failure.Retry := HighestOfferedVersion(ObjectOf(Error, KEY_DATA));
      Exit(False);
    end;

    const Outcome = ObjectOf(Response, MCP_KEY_RESULT);
    if not Assigned(Outcome) then
      raise EMCPClientProtocolError.Create(Format(MESSAGE_NO_RESULT, [MCP_METHOD_SERVER_DISCOVER]));

    ReadDiscovery(Outcome);
  finally
    Response.Free;
  end;

  FConnected := True;
  Result := True;
end;

procedure TMCPClient.ReadDiscovery(const Outcome: TJSONObject);
begin
  FSupportedVersions := nil;
  const Supported = Outcome.GetValue(KEY_SUPPORTED_VERSIONS);
  if Supported is TJSONArray then
    for var Value in TJSONArray(Supported) do
      if Value is TJSONString then
        FSupportedVersions := FSupportedVersions + [TJSONString(Value).Value];

  FCapabilitiesJson := JsonOf(Outcome, MCP_KEY_CAPABILITIES);
  FServerInfoJson := JsonOf(ObjectOf(Outcome, MCP_KEY_META), MCP_META_SERVER_INFO);
  FDiscoverTtlMs := IntOf(Outcome, MCP_KEY_TTL_MS);
  FCacheScope := TextOf(Outcome, MCP_KEY_CACHE_SCOPE);
end;

class function TMCPClient.HighestOfferedVersion(const Data: TJSONObject): string;
begin
  Result := '';
  if not Assigned(Data) then
    Exit;

  const Supported = Data.GetValue(KEY_SUPPORTED);
  if not (Supported is TJSONArray) then
    Exit;

  // A legacy version in the list is an invitation to handshake, not to retry the probe, so it is
  // skipped here and left to the fallback rule. Versions sort by date, so text order is age order.
  for var Value in TJSONArray(Supported) do
  begin
    if not (Value is TJSONString) then
      Continue;

    const Version = TJSONString(Value).Value;
    const IsOlderEra = ((Version = '') or TMCPProtocolVersion.IsLegacy(Version));
    if IsOlderEra then
      Continue;

    if Version > Result then
      Result := Version;
  end;
end;

function TMCPClient.IsModernEra: Boolean;
begin
  Result := (FEra = TMCPClientEra.Modern);
end;

function TMCPClient.RequestParams(const Params: TJSONObject; const Id: Int64): TJSONObject;
begin
  Result := Params;
  if not IsModernEra then
    Exit;

  if not Assigned(Result) then
    Result := TJSONObject.Create;
  Result.AddPair(MCP_KEY_META, ModernMeta(Id));
end;

function TMCPClient.ModernMeta(const Id: Int64): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair(MCP_META_PROTOCOL_VERSION, FProtocolVersion);
  Result.AddPair(MCP_META_CLIENT_CAPABILITIES, ClientCapabilities);
  Result.AddPair(MCP_META_CLIENT_INFO, ClientInfo);

  if FOptions.LogLevel <> '' then
    Result.AddPair(MCP_META_LOG_LEVEL, FOptions.LogLevel);

  // The token is the request id, so a progress notification names the call it belongs to. Without a
  // sink there is nowhere to report progress, so nothing is asked for.
  if Assigned(FSink) then
    Result.AddPair(MCP_META_PROGRESS_TOKEN, TJSONNumber.Create(Id));
end;

procedure TMCPClient.Close;
begin
  FConnected := False;
  FHasTools := False;
  FTools := nil;
  FProtocolVersion := '';
  FServerInfoJson := '';
  FSupportedVersions := nil;
  FCapabilitiesJson := '';
  FDiscoverTtlMs := 0;
  FCacheScope := '';
  FEra := FOptions.Era;
  FTransport.Era := FEra;
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

  Result := PostCall(Name, CallParams(Name, Arguments, nil, ''));

  const AsksForInput = (Result.ResultType = RESULT_TYPE_INPUT_REQUIRED);
  if AsksForInput then
    Result := AnswerInputRequests(Name, Arguments, Result);
end;

function TMCPClient.CallParams(const Name: string; const Arguments, Responses: TJSONObject;
  const RequestState: string): TJSONObject;
begin
  // The name and the arguments are repeated unchanged in every round, because the server signs
  // them into the requestState and checks that signature again on the way back.
  Result := TJSONObject.Create;
  Result.AddPair(MCP_KEY_NAME, Name);
  if Assigned(Arguments) then
    Result.AddPair(MCP_KEY_ARGUMENTS, TJSONObject(Arguments.Clone))
  else
    Result.AddPair(MCP_KEY_ARGUMENTS, TJSONObject.Create);

  if Assigned(Responses) then
    Result.AddPair(MCP_KEY_INPUT_RESPONSES, Responses);
  if RequestState <> '' then
    Result.AddPair(MCP_KEY_REQUEST_STATE, RequestState);
end;

function TMCPClient.PostCall(const Name: string; const Params: TJSONObject): TMCPToolCallOutcome;
begin
  var Http: TMCPHttpResponse;
  const Response = Post(MCP_METHOD_TOOLS_CALL, Name, Params, Http);
  try
    Result := ReadOutcome(Response, Http);
  finally
    Response.Free;
  end;
end;

function TMCPClient.AnswerInputRequests(const Name: string; const Arguments: TJSONObject;
  const First: TMCPToolCallOutcome): TMCPToolCallOutcome;
begin
  Result := First;

  for var Round := 1 to FOptions.MaxInputRounds do
  begin
    // A server only asks a client that declared it can answer, so this is a host that set a
    // responder, called, and cleared it again rather than a server overstepping.
    if not Assigned(FInputResponder) then
      Exit(TMCPToolCallOutcome.CreateError(MESSAGE_NO_RESPONDER));

    var Responses: TJSONObject := nil;
    var Failure := '';
    if not TryBuildInputResponses(Result.InputRequestsJson, Responses, Failure) then
      Exit(TMCPToolCallOutcome.CreateError(Failure));

    Result := PostCall(Name, CallParams(Name, Arguments, Responses, Result.RequestState));

    const IsAnswered = (Result.ResultType <> RESULT_TYPE_INPUT_REQUIRED);
    if IsAnswered then
      Exit;
  end;

  Result := TMCPToolCallOutcome.CreateError(Format(MESSAGE_TOO_MANY_ROUNDS, [FOptions.MaxInputRounds]));
end;

function TMCPClient.TryBuildInputResponses(const RequestsJson: string; out Responses: TJSONObject;
  out Failure: string): Boolean;
begin
  Responses := TJSONObject.Create;
  Failure := '';
  Result := False;

  const Requests = TJSONObject.ParseJSONValue(RequestsJson);
  try
    if Requests is TJSONObject then
      for var Pair in TJSONObject(Requests) do
      begin
        const Key = Pair.JsonString.Value;

        var Request: TJSONObject := nil;
        if Pair.JsonValue is TJSONObject then
          Request := TJSONObject(Pair.JsonValue);

        // The responder owns nothing afterwards: the answer becomes part of the request body.
        const Answer = FInputResponder(Key, TextOf(Request, MCP_KEY_METHOD),
          ObjectOf(Request, MCP_KEY_PARAMS));
        if not Assigned(Answer) then
        begin
          Failure := Format(MESSAGE_NO_ANSWER, [Key]);
          Break;
        end;

        Responses.AddPair(Key, Answer);
      end;

    Result := (Failure = '');
  finally
    Requests.Free;
    if not Result then
      FreeAndNil(Responses);
  end;
end;

function TMCPClient.ReadOutcome(const Response: TJSONObject; const Http: TMCPHttpResponse): TMCPToolCallOutcome;
begin
  Result := Default(TMCPToolCallOutcome);

  // A cancelled read leaves a truncated stream behind. The caller asked for this, so it hears the
  // reason rather than a parse failure.
  if Http.Cancelled then
    Exit(TMCPToolCallOutcome.CreateError(MESSAGE_CANCELLED));

  if not Assigned(Response) then
  begin
    Result := TMCPToolCallOutcome.CreateError(Format(MESSAGE_NO_RESULT, [MCP_METHOD_TOOLS_CALL]));
    // A 403 with no body still names the scope in its challenge, which is the one thing a human
    // has to hear to grant it.
    Result.RequiredScope := Http.RequiredScope;
    Exit;
  end;

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
  Result := TMCPToolCallOutcome.CreateError(TextOf(Error, KEY_MESSAGE), IntOf(Error, KEY_CODE));

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

class function TMCPClient.TokenText(const Value: TJSONValue): string;
begin
  if Value is TJSONString then
    Result := TJSONString(Value).Value
  else if Assigned(Value) then
    Result := Value.ToJSON
  else
    Result := '';
end;

class function TMCPClient.NumberOf(const Owner: TJSONObject; const Name: string;
  const Missing: Double): Double;
begin
  Result := Missing;
  if not Assigned(Owner) then
    Exit;

  const Value = Owner.GetValue(Name);
  if Value is TJSONNumber then
    Result := TJSONNumber(Value).AsDouble;
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

class function TMCPClient.IntOf(const Owner: TJSONObject; const Name: string): Integer;
begin
  Result := 0;
  if not Assigned(Owner) then
    Exit;

  const Value = Owner.GetValue(Name);
  if Value is TJSONNumber then
    Result := TJSONNumber(Value).AsInt;
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
  if not Assigned(Check) then
  begin
    FTransport.CancellationCheck := nil;
    Exit;
  end;

  // The transport asks this on every chunk it receives, which is the last moment at which the
  // server can still be told that the answer it is writing is no longer wanted.
  FTransport.CancellationCheck :=
    function: Boolean
    begin
      Result := Check();
      if Result then
        CancelInFlight;
    end;
end;

procedure TMCPClient.DispatchNotification(const Notification: TJSONObject);
begin
  if not Assigned(FSink) then
    Exit;

  const Params = ObjectOf(Notification, MCP_KEY_PARAMS);
  if not Assigned(Params) then
    Exit;

  const Method = TextOf(Notification, MCP_KEY_METHOD);
  if Method = MCP_METHOD_NOTIFICATIONS_PROGRESS then
    ReportProgress(Params)
  else if Method = MCP_METHOD_NOTIFICATIONS_MESSAGE then
    ReportLogMessage(Params);
end;

procedure TMCPClient.ReportProgress(const Params: TJSONObject);
begin
  FSink.Progress(TokenText(Params.GetValue(MCP_META_PROGRESS_TOKEN)),
    NumberOf(Params, KEY_PROGRESS, 0),
    NumberOf(Params, KEY_TOTAL, PROGRESS_TOTAL_UNKNOWN),
    TextOf(Params, KEY_MESSAGE));
end;

procedure TMCPClient.ReportLogMessage(const Params: TJSONObject);
begin
  FSink.LogMessage(TextOf(Params, KEY_LEVEL), TextOf(Params, KEY_LOGGER), JsonOf(Params, KEY_DATA));
end;

procedure TMCPClient.CancelInFlight;
begin
  const HasRequest = ((FInFlightId <> 0) and not FCancellationSent);
  if not HasRequest then
    Exit;

  FCancellationSent := True;

  const Params = TJSONObject.Create;
  Params.AddPair(KEY_REQUEST_ID, TJSONNumber.Create(FInFlightId));
  Params.AddPair(KEY_REASON, CANCELLATION_REASON);
  const Body = BuildBody(MCP_METHOD_NOTIFICATIONS_CANCELLED, Params, 0);

  // The connection carrying the call is about to be torn down, so the notification needs one of
  // its own. Telling the server is a courtesy: the call is cancelled whether it arrives or not.
  const Aside = TMCPHttpTransport.Create(FServerUrl, FOptions, FAuth);
  try
    Aside.Era := FEra;
    Aside.ProtocolVersion := FProtocolVersion;
    Aside.SessionId := FTransport.SessionId;
    try
      Aside.Send(TMCPHttpRequest.Notify(MCP_METHOD_NOTIFICATIONS_CANCELLED, Body));
    except
      on EMCPClientError do ;
    end;
  finally
    Aside.Free;
  end;
end;

end.
