unit MCPClient.Tests.Modern;

// The client in the modern era, and how it decides which era it is in.
//
// TMCPClientModernTests drives a real TMCPServerHost on an ephemeral port, so every request it
// sends is validated by the same header and _meta rules a live server applies: a wrong mirrored
// header, a missing params._meta or a version the header and the body disagree on would come back
// as an error rather than as a passing test. The request bodies are compared with the recorded
// request of the matching file under tests\golden\modern, which pins the client and the server to
// the same wire.
//
// TMCPClientEraTests drives a scripted stub instead, because era detection needs the answers a
// correct modern server never gives: an unknown method, a legacy server's refusal of the modern
// probe, and the -32022 that names the versions the server does speak.

interface

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
  System.Generics.Collections,
  System.Rtti,
  System.SyncObjs,
  IdContext,
  IdCustomHTTPServer,
  IdHTTPServer,
  DUnitX.TestFramework,
  MCPServer.Tool.Base,
  MCPServer.Host,
  MCPClient.Types,
  MCPClient.Interfaces,
  MCPClient.Http,
  MCPClient;

type
  { A tool whose name is not representable in an HTTP header, so Mcp-Name can only carry it through
    the base64 sentinel. }
  TAccentedTool = class(TMCPToolBase)
  protected
    function BuildSchema: TJSONObject; override;
    function DoExecute(const Arguments: TJSONObject): TValue; override;
  public
    constructor Create; override;
  end;

  [TestFixture]
  TMCPClientModernTests = class
  private
    FHost: TMCPServerHost;
    FClient: IMCPClient;
    FTrace: TMCPClient;
    FBodies: TArray<string>;
    function Url: string;
    function Options: TMCPClientOptions;
    procedure NewClient(const AOptions: TMCPClientOptions);
    function LastBody: string;
    function BodyCount: Integer;
    function GoldenRequest(const CaseName: string): string;
    function Normalised(const Body: string): string;
    procedure AssertRequestMatches(const CaseName, Body: string);
    function CallGolden(const CaseName: string): TMCPToolCallOutcome;
    function Meta(const Body: string): TJSONObject;
    { The _meta member names carry dots, which TJSONObject.GetValue<T> reads as a path separator. }
    class function Member(const Owner: TJSONObject; const Name: string): TJSONValue; static;
    function Post(const Method, MirroredName, Body: string): string;
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    [Test]
    procedure Connect_ModernEra_KeepsTheModernProtocolVersion;

    [Test]
    procedure Connect_AutoEra_SelectsModern;

    [Test]
    procedure Connect_DiscoverRequest_MatchesTheGoldenRequest;

    [Test]
    procedure Connect_Discover_StoresWhatTheServerReported;

    [Test]
    procedure Connect_Twice_ProbesOnce;

    [Test]
    procedure Connect_WithAnInputResponder_DeclaresTheThreeCapabilities;

    [Test]
    procedure Connect_WithALogLevel_AsksForItInTheMeta;

    [Test]
    procedure Close_ThenListTools_ProbesAgain;

    [Test]
    procedure ListTools_Request_MatchesTheGoldenRequest;

    [Test]
    procedure ListTools_ListsTheHostToolsInRegistrationOrder;

    [Test]
    procedure CallTool_Echo_MatchesTheGoldenRequestAndReturnsTheText;

    [Test]
    procedure CallTool_UnknownTool_IsAnErrorOutcomeAndNotAnException;

    [Test]
    procedure CallTool_NonAsciiToolName_TravelsThroughTheSentinelHeader;

    [Test]
    procedure EveryRequest_CarriesTheProtocolVersionAndCapabilities;

    [Test]
    procedure MirroredName_ThatDiffersFromTheBody_IsAHeaderMismatch;

    [Test]
    procedure MirroredMethod_ThatDiffersFromTheBody_IsAHeaderMismatch;

    [Test]
    procedure DiscoverWithoutMeta_ProducesTheMessageTheFallbackRuleMatches;
  end;

  TModernExchange = record
    Body: string;
    MethodHeader: string;
    NameHeader: string;
    ProtocolVersion: string;
    function BodyMethod: string;
  end;

  TModernReply = record
    Status: Integer;
    Body: string;
    class function Json(const Body: string): TModernReply; static;
    class function Accepted: TModernReply; static;
    class function Failure(const Status: Integer; const Body: string): TModernReply; static;
  end;

  { Answers a scripted sequence and records what it was sent, headers included. The token %ID% in a
    reply body becomes the id of the request being answered, so a script never has to count. }
  TModernStub = class
  strict private
    FServer: TIdHTTPServer;
    FLock: TCriticalSection;
    FReplies: TList<TModernReply>;
    FExchanges: TList<TModernExchange>;
    FIndex: Integer;
    procedure HandleCommand(Context: TIdContext; RequestInfo: TIdHTTPRequestInfo;
      ResponseInfo: TIdHTTPResponseInfo);
    function TakeReply: TModernReply;
    class function ReadBody(RequestInfo: TIdHTTPRequestInfo): string; static;
    class function RequestId(const Body: string): string; static;
  public
    constructor Create;
    destructor Destroy; override;

    procedure Add(const Reply: TModernReply);
    procedure AddDiscovery;
    procedure AddHandshake;
    function Url: string;
    function Exchange(const Index: Integer): TModernExchange;
    function ExchangeCount: Integer;
  end;

  [TestFixture]
  TMCPClientEraTests = class
  private
    FStub: TModernStub;
    FClient: IMCPClient;
    procedure NewClient(const Era: TMCPClientEra);
    function Refused: string;
    function RefusedCode: Integer;
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    [Test]
    procedure Auto_MethodNotFound_FallsBackToLegacy;

    [Test]
    procedure Auto_DiscoverRequiresMeta_FallsBackToLegacy;

    [Test]
    procedure Auto_UnsupportedVersionHeader_FallsBackToLegacy;

    [Test]
    procedure Auto_AfterTheFallback_SendsNoModernHeaderAndNoMeta;

    [Test]
    procedure Auto_InvalidParams_RaisesInsteadOfFallingBack;

    [Test]
    procedure Auto_TransportFailure_RaisesInsteadOfFallingBack;

    [Test]
    procedure Auto_UnsupportedProtocolVersion_RetriesWithTheHighestOffered;

    [Test]
    procedure Auto_UnsupportedProtocolVersionTwice_RetriesOnceAndRaises;

    [Test]
    procedure Auto_UnsupportedProtocolVersionOfferingOnlyLegacy_DoesNotRetry;

    [Test]
    procedure Modern_AgainstALegacyServer_RaisesWithTheServerText;

    [Test]
    procedure Modern_ToolsCall_MirrorsTheMethodAndTheNameInHeaders;

    [Test]
    procedure Modern_NonAsciiToolName_IsEncodedWithTheSentinel;
  end;

implementation

uses
  MCPServer.Types,
  MCPServer.Errors,
  MCPServer.HttpHeaders,
  MCPServer.Registration,
  MCPServer.Tests.Golden,
  MCPServer.Tests.Support,
  MCPClient.Errors;

const
  GOLDEN_CLIENT_NAME = 'golden-client';
  LOOPBACK = '127.0.0.1';
  ENDPOINT = '/mcp';
  URL_TEMPLATE = 'http://%s:%d%s';

  CASE_DISCOVER = 'server-discover';
  CASE_TOOLS_LIST = 'tools-list';
  CASE_ECHO = 'tools-call-echo';
  CASE_UNKNOWN_TOOL = 'tools-call-unknown-tool';

  TOOL_ECHO = 'echo';
  TOOL_CALCULATE = 'calculate';
  TOOL_GET_TIME = 'get_time';
  TOOL_SIMPLE_TEXT = 'test_simple_text';
  TOOL_ACCENTED = 'echo_caf'#$00E9;

  HOST_TOOLS: array[0..3] of string = (TOOL_ECHO, TOOL_CALCULATE, TOOL_GET_TIME, TOOL_SIMPLE_TEXT);

  ACCENTED_ANSWER = 'the accented tool ran';
  LOG_LEVEL_INFO = 'info';

  ID_TOKEN = '%ID%';
  DISCOVER_RESULT =
    '{"jsonrpc":"2.0","id":' + ID_TOKEN + ',"result":{"resultType":"complete",' +
    '"supportedVersions":["2026-07-28"],"capabilities":{"tools":{"listChanged":true}},' +
    '"_meta":{"io.modelcontextprotocol/serverInfo":{"name":"stub","version":"1.0.0"}},' +
    '"ttlMs":0,"cacheScope":"public"}}';
  INITIALIZE_RESULT =
    '{"jsonrpc":"2.0","id":' + ID_TOKEN + ',"result":{"protocolVersion":"2025-11-25",' +
    '"capabilities":{},"serverInfo":{"name":"stub","version":"1.0.0"}}}';
  TOOLS_RESULT =
    '{"jsonrpc":"2.0","id":' + ID_TOKEN + ',"result":{"tools":[{"name":"first",' +
    '"description":"The only tool"}]}}';
  CALL_RESULT =
    '{"jsonrpc":"2.0","id":' + ID_TOKEN + ',"result":{"content":[{"type":"text","text":"done"}]}}';

  METHOD_NOT_FOUND_ERROR =
    '{"jsonrpc":"2.0","id":' + ID_TOKEN + ',"error":{"code":-32601,' +
    '"message":"Method [server/discover] not found. The method does not exist or is not available."}}';
  REQUIRES_META_ERROR =
    '{"jsonrpc":"2.0","id":' + ID_TOKEN + ',"error":{"code":-32602,"message":"' +
    MCP_CLIENT_DISCOVER_REQUIRES_META + '"}}';
  UNSUPPORTED_HEADER_ERROR =
    '{"jsonrpc":"2.0","id":' + ID_TOKEN + ',"error":{"code":-32600,' +
    '"message":"Unsupported MCP-Protocol-Version header: 2026-07-28"}}';
  INVALID_PARAMS_ERROR =
    '{"jsonrpc":"2.0","id":' + ID_TOKEN + ',"error":{"code":-32602,' +
    '"message":"params.cursor must be a string"}}';
  NEWER_VERSION = '2026-11-01';
  UNSUPPORTED_VERSION_ERROR =
    '{"jsonrpc":"2.0","id":' + ID_TOKEN + ',"error":{"code":-32022,"message":"Unsupported protocol version",' +
    '"data":{"supported":["' + NEWER_VERSION + '","2025-11-25"],"requested":"2026-07-28"}}}';
  LEGACY_ONLY_VERSION_ERROR =
    '{"jsonrpc":"2.0","id":' + ID_TOKEN + ',"error":{"code":-32022,"message":"Unsupported protocol version",' +
    '"data":{"supported":["2025-11-25"],"requested":"2026-07-28"}}}';

  DISCOVER_WITHOUT_META = '{"jsonrpc":"2.0","id":1,"method":"server/discover"}';
  CALL_WITH_ANOTHER_NAME =
    '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":{"message":"x"},' +
    '"' + MCP_KEY_META + '":' + TMCPTestMeta.MODERN_FIELDS + '}}';
  LIST_WITH_ANOTHER_METHOD =
    '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"' + MCP_KEY_META + '":' +
    TMCPTestMeta.MODERN_FIELDS + '}}';

  UNREACHABLE_URL = 'http://127.0.0.1:1/mcp';

{ TAccentedTool }

constructor TAccentedTool.Create;
begin
  inherited;
  FName := TOOL_ACCENTED;
  FDescription := 'A tool whose name needs the header sentinel';
end;

function TAccentedTool.BuildSchema: TJSONObject;
begin
  Result := TJSONObject.ParseJSONValue(MCP_CLIENT_EMPTY_INPUT_SCHEMA) as TJSONObject;
end;

function TAccentedTool.DoExecute(const Arguments: TJSONObject): TValue;
begin
  Result := ACCENTED_ANSWER;
end;

{ TMCPClientModernTests }

procedure TMCPClientModernTests.Setup;
begin
  FHost := TMCPServerHost.Create;
  FHost.Settings.Port := 0;
  FHost.Settings.CorsEnabled := False;
  for var Name in HOST_TOOLS do
    FHost.AddTool(TMCPRegistry.CreateTool(Name));
  FHost.AddTool(TAccentedTool.Create);
  FHost.StartHttp;

  NewClient(Options);
end;

procedure TMCPClientModernTests.TearDown;
begin
  FTrace := nil;
  FClient := nil;
  FHost.Free;
end;

function TMCPClientModernTests.Url: string;
begin
  Result := Format(URL_TEMPLATE, [LOOPBACK, FHost.BoundPort, ENDPOINT]);
end;

function TMCPClientModernTests.Options: TMCPClientOptions;
begin
  Result := TMCPClientOptions.Default;
  Result.Era := TMCPClientEra.Modern;
  Result.ClientName := GOLDEN_CLIENT_NAME;
end;

procedure TMCPClientModernTests.NewClient(const AOptions: TMCPClientOptions);
begin
  FBodies := nil;
  FTrace := TMCPClient.Create(Url, AOptions);
  FClient := FTrace;
  FTrace.OnRequestBody :=
    procedure(Body: string)
    begin
      FBodies := FBodies + [Body];
    end;
end;

function TMCPClientModernTests.LastBody: string;
begin
  Assert.IsTrue(Length(FBodies) > 0, 'the client sent nothing');
  Result := FBodies[High(FBodies)];
end;

function TMCPClientModernTests.BodyCount: Integer;
begin
  Result := Integer(Length(FBodies));
end;

function TMCPClientModernTests.GoldenRequest(const CaseName: string): string;
begin
  const GoldenCase = TGoldenCase.Create(TGoldenFiles.CaseFile(TGoldenFiles.MODERN_SUITE, CaseName));
  try
    Result := GoldenCase.RequestBody;
  finally
    GoldenCase.Free;
  end;
end;

function TMCPClientModernTests.Normalised(const Body: string): string;
begin
  const Request = TMCPTestJson.ParseObject(Body);
  try
    for var Pair in Request do
    begin
      const IsId = (Pair.JsonString.Value = MCP_KEY_ID);
      if IsId then
        Pair.JsonValue := TJSONNumber.Create(0);
    end;
    Result := Request.Format(2);
  finally
    Request.Free;
  end;
end;

procedure TMCPClientModernTests.AssertRequestMatches(const CaseName, Body: string);
begin
  Assert.AreEqual(Normalised(GoldenRequest(CaseName)), Normalised(Body),
    'the request does not match golden case ' + CaseName);
end;

function TMCPClientModernTests.CallGolden(const CaseName: string): TMCPToolCallOutcome;
begin
  const Request = TMCPTestJson.ParseObject(GoldenRequest(CaseName));
  try
    const Params = Request.GetValue(MCP_KEY_PARAMS) as TJSONObject;
    Result := FClient.CallTool(Params.GetValue<string>(MCP_KEY_NAME),
      Params.GetValue(MCP_KEY_ARGUMENTS) as TJSONObject);
  finally
    Request.Free;
  end;

  AssertRequestMatches(CaseName, LastBody);
end;

function TMCPClientModernTests.Meta(const Body: string): TJSONObject;
begin
  const Request = TMCPTestJson.ParseObject(Body);
  try
    const Params = Request.GetValue(MCP_KEY_PARAMS);
    Assert.IsTrue(Params is TJSONObject, 'the request carries no params: ' + Body);

    const Value = TJSONObject(Params).GetValue(MCP_KEY_META);
    Assert.IsTrue(Value is TJSONObject, 'the request carries no params._meta: ' + Body);
    Result := TJSONObject(Value.Clone);
  finally
    Request.Free;
  end;
end;

class function TMCPClientModernTests.Member(const Owner: TJSONObject; const Name: string): TJSONValue;
begin
  Result := Owner.GetValue(Name);
  Assert.IsNotNull(Result, 'the request carries no ' + Name);
end;

function TMCPClientModernTests.Post(const Method, MirroredName, Body: string): string;
begin
  const Transport = TMCPHttpTransport.Create(Url, Options);
  try
    Transport.Era := TMCPClientEra.Modern;
    Transport.ProtocolVersion := MCP_LATEST_PROTOCOL_VERSION;
    Result := Transport.Send(TMCPHttpRequest.Call(Method, Body, 1, MirroredName)).Body;
  finally
    Transport.Free;
  end;
end;

procedure TMCPClientModernTests.Connect_ModernEra_KeepsTheModernProtocolVersion;
begin
  FClient.Connect;

  Assert.IsTrue(FClient.IsConnected);
  Assert.AreEqual(Ord(TMCPClientEra.Modern), Ord(FClient.Era));
  Assert.AreEqual(MCP_LATEST_PROTOCOL_VERSION, FClient.ProtocolVersion);
  Assert.AreEqual(1, BodyCount, 'the modern era has no handshake beyond the probe');
end;

procedure TMCPClientModernTests.Connect_AutoEra_SelectsModern;
begin
  var Auto := Options;
  Auto.Era := TMCPClientEra.Auto;
  NewClient(Auto);

  FClient.Connect;

  Assert.AreEqual(Ord(TMCPClientEra.Modern), Ord(FClient.Era), 'Auto did not select the modern era');
  Assert.AreEqual(MCP_LATEST_PROTOCOL_VERSION, FClient.ProtocolVersion);
  Assert.AreEqual(1, BodyCount, 'Auto handshook after a successful probe');
end;

procedure TMCPClientModernTests.Connect_DiscoverRequest_MatchesTheGoldenRequest;
begin
  FClient.Connect;

  AssertRequestMatches(CASE_DISCOVER, FBodies[0]);
end;

procedure TMCPClientModernTests.Connect_Discover_StoresWhatTheServerReported;
begin
  FClient.Connect;

  Assert.AreEqual(1, Integer(Length(FTrace.SupportedVersions)));
  Assert.AreEqual(MCP_LATEST_PROTOCOL_VERSION, FTrace.SupportedVersions[0]);
  Assert.AreEqual(MCP_CACHE_SCOPE_PUBLIC, FTrace.CacheScope);
  Assert.AreEqual(0, FTrace.DiscoverTtlMs);
  Assert.IsTrue(FTrace.CapabilitiesJson.Contains('"tools"'),
    'the capabilities were dropped: ' + FTrace.CapabilitiesJson);

  const Info = TMCPTestJson.ParseObject(FClient.ServerInfoJson);
  try
    Assert.AreEqual('delphi-mcp-server', Info.GetValue<string>(MCP_KEY_NAME));
  finally
    Info.Free;
  end;
end;

procedure TMCPClientModernTests.Connect_Twice_ProbesOnce;
begin
  FClient.Connect;
  FClient.Connect;

  Assert.AreEqual(1, BodyCount, 'the second Connect probed again');
end;

procedure TMCPClientModernTests.Connect_WithAnInputResponder_DeclaresTheThreeCapabilities;
begin
  FClient.SetInputResponder(
    function(const Key, Method: string; const Params: TJSONObject): TJSONObject
    begin
      Result := TJSONObject.Create;
    end);

  FClient.Connect;

  const Fields = Meta(FBodies[0]);
  try
    const Capabilities = Member(Fields, MCP_META_CLIENT_CAPABILITIES) as TJSONObject;
    Assert.AreEqual(3, Capabilities.Count, 'the declared capabilities do not follow the responder');
    Assert.IsNotNull(Capabilities.GetValue('elicitation'));
    Assert.IsNotNull(Capabilities.GetValue('sampling'));
    Assert.IsNotNull(Capabilities.GetValue('roots'));
  finally
    Fields.Free;
  end;
end;

procedure TMCPClientModernTests.Connect_WithALogLevel_AsksForItInTheMeta;
begin
  var Verbose := Options;
  Verbose.LogLevel := LOG_LEVEL_INFO;
  NewClient(Verbose);

  FClient.ListTools;

  const Fields = Meta(LastBody);
  try
    Assert.AreEqual(LOG_LEVEL_INFO, (Member(Fields, MCP_META_LOG_LEVEL) as TJSONString).Value);
  finally
    Fields.Free;
  end;
end;

procedure TMCPClientModernTests.Close_ThenListTools_ProbesAgain;
begin
  FClient.Connect;
  FClient.Close;

  Assert.IsFalse(FClient.IsConnected);
  Assert.AreEqual('', FClient.ProtocolVersion);
  Assert.AreEqual(0, Integer(Length(FTrace.SupportedVersions)));

  FClient.ListTools;

  Assert.IsTrue(FClient.IsConnected);
  Assert.AreEqual(3, BodyCount, 'the client did not probe again after Close');
end;

procedure TMCPClientModernTests.ListTools_Request_MatchesTheGoldenRequest;
begin
  FClient.ListTools;

  AssertRequestMatches(CASE_TOOLS_LIST, LastBody);
end;

procedure TMCPClientModernTests.ListTools_ListsTheHostToolsInRegistrationOrder;
begin
  var Names: TArray<string> := nil;
  for var Tool in FClient.ListTools do
    Names := Names + [Tool.Name];

  Assert.AreEqual(string.Join(',', [TOOL_ECHO, TOOL_CALCULATE, TOOL_GET_TIME, TOOL_SIMPLE_TEXT,
    TOOL_ACCENTED]), string.Join(',', Names));
end;

procedure TMCPClientModernTests.CallTool_Echo_MatchesTheGoldenRequestAndReturnsTheText;
begin
  const Outcome = CallGolden(CASE_ECHO);

  Assert.IsFalse(Outcome.IsError);
  Assert.AreEqual('Echo: hello modern', Outcome.Text);
  Assert.AreEqual('complete', Outcome.ResultType);
end;

procedure TMCPClientModernTests.CallTool_UnknownTool_IsAnErrorOutcomeAndNotAnException;
begin
  const Outcome = CallGolden(CASE_UNKNOWN_TOOL);

  Assert.IsTrue(Outcome.IsError);
  Assert.AreEqual(Integer(JSONRPC_INVALID_PARAMS), Outcome.ErrorCode);
  Assert.AreEqual('Unknown tool: no_such_tool', Outcome.ErrorMessage);
  Assert.IsTrue(FClient.IsConnected, 'an unknown tool dropped the connection');
end;

procedure TMCPClientModernTests.CallTool_NonAsciiToolName_TravelsThroughTheSentinelHeader;
begin
  const Outcome = FClient.CallTool(TOOL_ACCENTED, nil);

  Assert.IsFalse(Outcome.IsError, 'the server refused the mirrored name: ' + Outcome.Text);
  Assert.AreEqual(ACCENTED_ANSWER, Outcome.Text);
end;

procedure TMCPClientModernTests.EveryRequest_CarriesTheProtocolVersionAndCapabilities;
begin
  FClient.ListTools;
  FClient.CallTool(TOOL_GET_TIME, nil);

  Assert.AreEqual(3, BodyCount, 'the probe, the listing and the call are three requests');
  for var Body in FBodies do
  begin
    const Fields = Meta(Body);
    try
      Assert.AreEqual(MCP_LATEST_PROTOCOL_VERSION,
        (Member(Fields, MCP_META_PROTOCOL_VERSION) as TJSONString).Value);
      Assert.IsNotNull(Member(Fields, MCP_META_CLIENT_CAPABILITIES) as TJSONObject);
      Assert.AreEqual(GOLDEN_CLIENT_NAME,
        (Member(Fields, MCP_META_CLIENT_INFO) as TJSONObject).GetValue<string>(MCP_KEY_NAME));
      Assert.IsFalse(Assigned(Fields.GetValue(MCP_META_PROGRESS_TOKEN)),
        'progress was asked for without a sink');
    finally
      Fields.Free;
    end;
  end;
end;

procedure TMCPClientModernTests.MirroredName_ThatDiffersFromTheBody_IsAHeaderMismatch;
begin
  const Answer = TMCPTestJson.ParseObject(
    Post(MCP_METHOD_TOOLS_CALL, TOOL_GET_TIME, CALL_WITH_ANOTHER_NAME));
  try
    Assert.AreEqual(Integer(MCP_ERROR_HEADER_MISMATCH),
      Answer.GetValue<TJSONObject>(MCP_KEY_ERROR).GetValue<Integer>('code'));
  finally
    Answer.Free;
  end;
end;

procedure TMCPClientModernTests.MirroredMethod_ThatDiffersFromTheBody_IsAHeaderMismatch;
begin
  const Answer = TMCPTestJson.ParseObject(
    Post(MCP_METHOD_TOOLS_CALL, '', LIST_WITH_ANOTHER_METHOD));
  try
    Assert.AreEqual(Integer(MCP_ERROR_HEADER_MISMATCH),
      Answer.GetValue<TJSONObject>(MCP_KEY_ERROR).GetValue<Integer>('code'));
  finally
    Answer.Free;
  end;
end;

procedure TMCPClientModernTests.DiscoverWithoutMeta_ProducesTheMessageTheFallbackRuleMatches;
begin
  const Transport = TMCPHttpTransport.Create(Url, Options);
  var Body := '';
  try
    Transport.Era := TMCPClientEra.Legacy;
    Body := Transport.Send(TMCPHttpRequest.Call(MCP_METHOD_SERVER_DISCOVER,
      DISCOVER_WITHOUT_META, 1)).Body;
  finally
    Transport.Free;
  end;

  const Answer = TMCPTestJson.ParseObject(Body);
  try
    const Error = Answer.GetValue<TJSONObject>(MCP_KEY_ERROR);
    Assert.AreEqual(Integer(JSONRPC_INVALID_PARAMS), Error.GetValue<Integer>('code'));
    Assert.AreEqual(MCP_CLIENT_DISCOVER_REQUIRES_META, Error.GetValue<string>('message'),
      'the client matches on a message the server no longer produces');
  finally
    Answer.Free;
  end;
end;

{ TModernExchange }

function TModernExchange.BodyMethod: string;
begin
  Result := '';
  const Value = TJSONObject.ParseJSONValue(Body);
  try
    if not (Value is TJSONObject) then
      Exit;

    const Method = TJSONObject(Value).GetValue(MCP_KEY_METHOD);
    if Method is TJSONString then
      Result := TJSONString(Method).Value;
  finally
    Value.Free;
  end;
end;

{ TModernReply }

class function TModernReply.Json(const Body: string): TModernReply;
begin
  Result := Default(TModernReply);
  Result.Status := HTTP_STATUS_OK;
  Result.Body := Body;
end;

class function TModernReply.Accepted: TModernReply;
begin
  Result := Default(TModernReply);
  Result.Status := HTTP_STATUS_ACCEPTED;
end;

class function TModernReply.Failure(const Status: Integer; const Body: string): TModernReply;
begin
  Result := Default(TModernReply);
  Result.Status := Status;
  Result.Body := Body;
end;

{ TModernStub }

constructor TModernStub.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FReplies := TList<TModernReply>.Create;
  FExchanges := TList<TModernExchange>.Create;

  FServer := TIdHTTPServer.Create(nil);
  FServer.OnCommandGet := HandleCommand;
  FServer.OnCommandOther := HandleCommand;
  FServer.DefaultPort := 0;
  FServer.Bindings.Add.IP := LOOPBACK;
  FServer.Active := True;
end;

destructor TModernStub.Destroy;
begin
  FServer.Active := False;
  FServer.Free;
  FExchanges.Free;
  FReplies.Free;
  FLock.Free;
  inherited;
end;

procedure TModernStub.Add(const Reply: TModernReply);
begin
  FLock.Enter;
  try
    FReplies.Add(Reply);
  finally
    FLock.Leave;
  end;
end;

procedure TModernStub.AddDiscovery;
begin
  Add(TModernReply.Json(DISCOVER_RESULT));
end;

procedure TModernStub.AddHandshake;
begin
  Add(TModernReply.Json(INITIALIZE_RESULT));
  Add(TModernReply.Accepted);
end;

function TModernStub.Url: string;
begin
  Result := Format(URL_TEMPLATE, [LOOPBACK, FServer.Bindings[0].Port, ENDPOINT]);
end;

function TModernStub.Exchange(const Index: Integer): TModernExchange;
begin
  FLock.Enter;
  try
    Assert.IsTrue(Index < FExchanges.Count,
      Format('the client sent %d requests, not %d', [FExchanges.Count, Index + 1]));
    Result := FExchanges[Index];
  finally
    FLock.Leave;
  end;
end;

function TModernStub.ExchangeCount: Integer;
begin
  FLock.Enter;
  try
    Result := Integer(FExchanges.Count);
  finally
    FLock.Leave;
  end;
end;

function TModernStub.TakeReply: TModernReply;
begin
  FLock.Enter;
  try
    if FReplies.Count = 0 then
      Exit(TModernReply.Json(''));

    const At = FIndex;
    if At < FReplies.Count - 1 then
      Inc(FIndex);
    Result := FReplies[At];
  finally
    FLock.Leave;
  end;
end;

class function TModernStub.ReadBody(RequestInfo: TIdHTTPRequestInfo): string;
begin
  Result := '';
  const HasBody = (Assigned(RequestInfo.PostStream) and (RequestInfo.PostStream.Size > 0));
  if not HasBody then
    Exit;

  RequestInfo.PostStream.Position := 0;
  const Reader = TStringStream.Create('', TEncoding.UTF8);
  try
    Reader.CopyFrom(RequestInfo.PostStream, 0);
    Result := Reader.DataString;
  finally
    Reader.Free;
  end;
end;

class function TModernStub.RequestId(const Body: string): string;
begin
  Result := 'null';
  const Value = TJSONObject.ParseJSONValue(Body);
  try
    if not (Value is TJSONObject) then
      Exit;

    const Id = TJSONObject(Value).GetValue(MCP_KEY_ID);
    if Id is TJSONNumber then
      Result := Id.Value;
  finally
    Value.Free;
  end;
end;

procedure TModernStub.HandleCommand(Context: TIdContext; RequestInfo: TIdHTTPRequestInfo;
  ResponseInfo: TIdHTTPResponseInfo);
begin
  var Exchange := Default(TModernExchange);
  Exchange.Body := ReadBody(RequestInfo);
  Exchange.MethodHeader := RequestInfo.RawHeaders.Values[MCP_HEADER_METHOD];
  Exchange.NameHeader := RequestInfo.RawHeaders.Values[MCP_HEADER_NAME];
  Exchange.ProtocolVersion := RequestInfo.RawHeaders.Values[MCP_HEADER_PROTOCOL_VERSION];

  FLock.Enter;
  try
    FExchanges.Add(Exchange);
  finally
    FLock.Leave;
  end;

  const Reply = TakeReply;
  ResponseInfo.ResponseNo := Reply.Status;
  ResponseInfo.ContentType := MEDIA_TYPE_JSON;

  const Body = StringReplace(Reply.Body, ID_TOKEN, RequestId(Exchange.Body), [rfReplaceAll]);
  ResponseInfo.ContentStream := TStringStream.Create(Body, TEncoding.UTF8);
  ResponseInfo.FreeContentStream := True;
end;

{ TMCPClientEraTests }

procedure TMCPClientEraTests.Setup;
begin
  FStub := TModernStub.Create;
  NewClient(TMCPClientEra.Auto);
end;

procedure TMCPClientEraTests.TearDown;
begin
  FClient := nil;
  FStub.Free;
end;

procedure TMCPClientEraTests.NewClient(const Era: TMCPClientEra);
begin
  var ClientOptions := TMCPClientOptions.Default;
  ClientOptions.Era := Era;
  ClientOptions.ClientName := GOLDEN_CLIENT_NAME;
  FClient := TMCPClient.Create(FStub.Url, ClientOptions);
end;

function TMCPClientEraTests.Refused: string;
begin
  Result := '';
  try
    FClient.Connect;
  except
    on E: EMCPClientError do
      Exit(E.Message);
  end;
  Assert.Fail('the client accepted an answer it cannot follow');
end;

function TMCPClientEraTests.RefusedCode: Integer;
begin
  Result := 0;
  try
    FClient.Connect;
  except
    on E: EMCPClientError do
      Exit(E.ErrorCode);
  end;
  Assert.Fail('the client accepted an answer it cannot follow');
end;

procedure TMCPClientEraTests.Auto_MethodNotFound_FallsBackToLegacy;
begin
  FStub.Add(TModernReply.Failure(HTTP_STATUS_NOT_FOUND, METHOD_NOT_FOUND_ERROR));
  FStub.AddHandshake;

  FClient.Connect;

  Assert.AreEqual(Ord(TMCPClientEra.Legacy), Ord(FClient.Era));
  Assert.AreEqual(MCP_LATEST_LEGACY_PROTOCOL_VERSION, FClient.ProtocolVersion);
  Assert.AreEqual(MCP_METHOD_SERVER_DISCOVER, FStub.Exchange(0).BodyMethod);
  Assert.AreEqual(MCP_METHOD_INITIALIZE, FStub.Exchange(1).BodyMethod);
  Assert.AreEqual(MCP_METHOD_NOTIFICATIONS_INITIALIZED, FStub.Exchange(2).BodyMethod);
end;

procedure TMCPClientEraTests.Auto_DiscoverRequiresMeta_FallsBackToLegacy;
begin
  FStub.Add(TModernReply.Failure(HTTP_STATUS_BAD_REQUEST, REQUIRES_META_ERROR));
  FStub.AddHandshake;

  FClient.Connect;

  Assert.AreEqual(Ord(TMCPClientEra.Legacy), Ord(FClient.Era));
  Assert.AreEqual(MCP_METHOD_INITIALIZE, FStub.Exchange(1).BodyMethod);
end;

procedure TMCPClientEraTests.Auto_UnsupportedVersionHeader_FallsBackToLegacy;
begin
  FStub.Add(TModernReply.Failure(HTTP_STATUS_BAD_REQUEST, UNSUPPORTED_HEADER_ERROR));
  FStub.AddHandshake;

  FClient.Connect;

  Assert.AreEqual(Ord(TMCPClientEra.Legacy), Ord(FClient.Era));
  Assert.AreEqual(MCP_METHOD_INITIALIZE, FStub.Exchange(1).BodyMethod);
end;

procedure TMCPClientEraTests.Auto_AfterTheFallback_SendsNoModernHeaderAndNoMeta;
begin
  FStub.Add(TModernReply.Failure(HTTP_STATUS_BAD_REQUEST, REQUIRES_META_ERROR));
  FStub.AddHandshake;
  FStub.Add(TModernReply.Json(TOOLS_RESULT));

  FClient.ListTools;

  const Listing = FStub.Exchange(3);
  Assert.AreEqual(MCP_METHOD_TOOLS_LIST, Listing.BodyMethod);
  Assert.AreEqual('', Listing.MethodHeader, 'the legacy era sent ' + MCP_HEADER_METHOD);
  Assert.AreEqual(MCP_LATEST_LEGACY_PROTOCOL_VERSION, Listing.ProtocolVersion);
  Assert.IsFalse(Listing.Body.Contains(MCP_KEY_META), 'the legacy era sent params._meta');
end;

procedure TMCPClientEraTests.Auto_InvalidParams_RaisesInsteadOfFallingBack;
begin
  FStub.Add(TModernReply.Json(INVALID_PARAMS_ERROR));

  Assert.AreEqual(Integer(JSONRPC_INVALID_PARAMS), RefusedCode);
  Assert.AreEqual(1, FStub.ExchangeCount, 'an ordinary invalid-params error dropped the era');
  Assert.IsFalse(FClient.IsConnected);
end;

procedure TMCPClientEraTests.Auto_TransportFailure_RaisesInsteadOfFallingBack;
begin
  var ClientOptions := TMCPClientOptions.Default;
  ClientOptions.ConnectTimeoutMs := 1000;
  FClient := TMCPClient.Create(UNREACHABLE_URL, ClientOptions);

  Assert.WillRaise(
    procedure
    begin
      FClient.Connect;
    end, EMCPClientTransportError);
end;

procedure TMCPClientEraTests.Auto_UnsupportedProtocolVersion_RetriesWithTheHighestOffered;
begin
  FStub.Add(TModernReply.Failure(HTTP_STATUS_BAD_REQUEST, UNSUPPORTED_VERSION_ERROR));
  FStub.AddDiscovery;

  FClient.Connect;

  Assert.AreEqual(Ord(TMCPClientEra.Modern), Ord(FClient.Era));
  Assert.AreEqual(NEWER_VERSION, FClient.ProtocolVersion);
  Assert.AreEqual(2, FStub.ExchangeCount, 'the retry is a second probe and nothing more');
  Assert.AreEqual(NEWER_VERSION, FStub.Exchange(1).ProtocolVersion,
    'the retry did not carry the version the server offered');
  Assert.IsTrue(FStub.Exchange(1).Body.Contains('"' + NEWER_VERSION + '"'),
    'the retry body kept the refused version: ' + FStub.Exchange(1).Body);
end;

procedure TMCPClientEraTests.Auto_UnsupportedProtocolVersionTwice_RetriesOnceAndRaises;
begin
  FStub.Add(TModernReply.Failure(HTTP_STATUS_BAD_REQUEST, UNSUPPORTED_VERSION_ERROR));

  Assert.AreEqual(Integer(MCP_ERROR_UNSUPPORTED_PROTOCOL_VERSION), RefusedCode);
  Assert.AreEqual(2, FStub.ExchangeCount, 'the client retried more than once');
end;

procedure TMCPClientEraTests.Auto_UnsupportedProtocolVersionOfferingOnlyLegacy_DoesNotRetry;
begin
  FStub.Add(TModernReply.Failure(HTTP_STATUS_BAD_REQUEST, LEGACY_ONLY_VERSION_ERROR));

  Assert.IsTrue(Refused.Contains('Unsupported protocol version'));
  Assert.AreEqual(1, FStub.ExchangeCount, 'a legacy version is not something to probe with');
end;

procedure TMCPClientEraTests.Modern_AgainstALegacyServer_RaisesWithTheServerText;
begin
  NewClient(TMCPClientEra.Modern);
  FStub.Add(TModernReply.Failure(HTTP_STATUS_NOT_FOUND, METHOD_NOT_FOUND_ERROR));
  FStub.AddHandshake;

  const Reported = Refused;

  Assert.IsTrue(Reported.Contains('Method [server/discover] not found'),
    'the server message is missing from ' + Reported);
  Assert.AreEqual(1, FStub.ExchangeCount, 'the named modern era handshook as a legacy client');
end;

procedure TMCPClientEraTests.Modern_ToolsCall_MirrorsTheMethodAndTheNameInHeaders;
begin
  NewClient(TMCPClientEra.Modern);
  FStub.AddDiscovery;
  FStub.Add(TModernReply.Json(CALL_RESULT));

  FClient.CallTool(TOOL_ECHO, nil);

  Assert.AreEqual(MCP_METHOD_SERVER_DISCOVER, FStub.Exchange(0).MethodHeader);
  Assert.AreEqual('', FStub.Exchange(0).NameHeader, 'server/discover mirrors no name');

  const Call = FStub.Exchange(1);
  Assert.AreEqual(MCP_METHOD_TOOLS_CALL, Call.MethodHeader);
  Assert.AreEqual(TOOL_ECHO, Call.NameHeader);
  Assert.AreEqual(MCP_LATEST_PROTOCOL_VERSION, Call.ProtocolVersion);
end;

procedure TMCPClientEraTests.Modern_NonAsciiToolName_IsEncodedWithTheSentinel;
var
  Decoded: string;
begin
  NewClient(TMCPClientEra.Modern);
  FStub.AddDiscovery;
  FStub.Add(TModernReply.Json(CALL_RESULT));

  FClient.CallTool(TOOL_ACCENTED, nil);

  const Sent = FStub.Exchange(1).NameHeader;
  Assert.IsTrue(TMCPHeaderValue.IsSentinel(Sent), 'the name went on the wire unencoded: ' + Sent);
  Assert.IsTrue(TMCPHeaderValue.TryDecode(Sent, Decoded), 'the sentinel does not decode: ' + Sent);
  Assert.AreEqual(TOOL_ACCENTED, Decoded);
end;

end.
