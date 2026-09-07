unit MCPClient.Tests.Legacy;

// The client against a real server. TMCPClientLegacyTests drives a TMCPServerHost on an ephemeral
// port over loopback and compares every request body it builds with the recorded request of the
// matching file under tests\golden\legacy, so the client and the server are pinned to the same wire.
// TMCPClientStatusTests drives a canned HTTP server instead, because a status table needs answers a
// correct server never gives.

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
  MCPClient;

type
  { A tool whose result is a JSON object, which the server publishes as structuredContent. }
  TStructuredTool = class(TMCPToolBase)
  protected
    function BuildSchema: TJSONObject; override;
    function DoExecute(const Arguments: TJSONObject): TValue; override;
  public
    constructor Create; override;
  end;

  [TestFixture]
  TMCPClientLegacyTests = class
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
    function ToolNamed(const Name: string): TMCPRemoteTool;
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    [Test]
    procedure Connect_LegacyEra_NegotiatesTheLatestLegacyVersion;

    [Test]
    procedure Connect_InitializeRequest_MatchesTheGoldenRequest;

    [Test]
    procedure Connect_InitializedNotification_MatchesTheGoldenRequest;

    [Test]
    procedure Connect_Twice_HandshakesOnce;

    [Test]
    procedure Connect_ServerInfo_NamesTheServer;

    [Test]
    procedure Connect_WithAnInputResponder_DeclaresTheThreeCapabilities;

    [Test]
    procedure Close_ThenCallTool_HandshakesAgain;

    [Test]
    procedure ListTools_Request_MatchesTheGoldenRequest;

    [Test]
    procedure ListTools_ListsTheHostToolsInRegistrationOrder;

    [Test]
    procedure ListTools_ReadOnlyTool_CarriesTheAnnotations;

    [Test]
    procedure ListTools_ToolWithoutAnnotations_ReportsNone;

    [Test]
    procedure ListTools_InputSchema_IsKeptAsText;

    [Test]
    procedure ListTools_SecondCall_IsAnsweredFromTheCache;

    [Test]
    procedure RefreshTools_AfterTheHostGainedATool_SeesIt;

    [Test]
    procedure CallTool_Echo_ReturnsTheEchoedText;

    [Test]
    procedure CallTool_EchoUnicode_RoundTripsTheText;

    [Test]
    procedure CallTool_Calculate_ReturnsTheSum;

    [Test]
    procedure CallTool_DivideByZero_IsAFailedToolResult;

    [Test]
    procedure CallTool_InvalidArgumentType_IsAFailedToolResult;

    [Test]
    procedure CallTool_WithoutArguments_WritesAnEmptyArgumentsObject;

    [Test]
    procedure CallTool_UnknownTool_IsAnErrorOutcomeAndNotAnException;

    [Test]
    procedure CallTool_StructuredResult_KeepsTheStructuredJson;

    [Test]
    procedure CallTool_MixedContent_SummarisesEveryNonTextBlock;

    [Test]
    procedure CallTool_ImageOnly_HasNoTextAndOneSummary;

    [Test]
    procedure CallTool_BeforeConnect_ConnectsFirst;

    [Test]
    procedure CallTool_WithoutTheEventStream_ReadsThePlainJsonAnswer;

  end;

  TStubExchange = record
    Body: string;
    SessionId: string;
    ProtocolVersion: string;
  end;

  TStubReply = record
    Status: Integer;
    ContentType: string;
    Body: string;
    SessionId: string;
    Challenge: string;
    class function Json(const Body: string): TStubReply; static;
    class function Accepted: TStubReply; static;
    class function Failure(const Status: Integer; const Body: string): TStubReply; static;
  end;

  { Answers a scripted sequence of replies and records what it was sent. The token %ID% in a reply
    body becomes the id of the request being answered, so a script never has to count requests. }
  TStubServer = class
  strict private
    FServer: TIdHTTPServer;
    FLock: TCriticalSection;
    FReplies: TList<TStubReply>;
    FExchanges: TList<TStubExchange>;
    FIndex: Integer;
    procedure HandleCommand(Context: TIdContext; RequestInfo: TIdHTTPRequestInfo;
      ResponseInfo: TIdHTTPResponseInfo);
    function TakeReply: TStubReply;
    class function ReadBody(RequestInfo: TIdHTTPRequestInfo): string; static;
    class function RequestId(const Body: string): string; static;
  public
    constructor Create;
    destructor Destroy; override;

    procedure Add(const Reply: TStubReply);
    procedure AddHandshake(const SessionId: string = '');
    function Url: string;
    function Exchange(const Index: Integer): TStubExchange;
  end;

  [TestFixture]
  TMCPClientStatusTests = class
  private
    FStub: TStubServer;
    FClient: IMCPClient;
    procedure NewClient;
    function Connected: IMCPClient;
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    [Test]
    procedure Connect_SessionHeader_IsEchoedOnEveryLaterRequest;

    [Test]
    procedure Connect_WithoutASessionHeader_SendsNone;

    [Test]
    procedure ListTools_PagedAnswer_FollowsTheCursor;

    [Test]
    procedure ListTools_RepeatedCursor_RaisesAProtocolError;

    [Test]
    procedure ListTools_ResponseForAnotherRequest_RaisesAProtocolError;

    [Test]
    procedure CallTool_StructuredContentWithoutATextBlock_BecomesTheText;

    [Test]
    procedure CallTool_Forbidden_ReportsTheScopeFromTheChallenge;

    [Test]
    procedure CallTool_Forbidden_PrefersTheScopeInTheErrorData;

    [Test]
    procedure ListTools_Forbidden_RaisesAScopeError;

    [Test]
    procedure Connect_Unauthorized_RaisesAnAuthError;

    [Test]
    procedure Connect_MethodNotAllowed_RaisesAConfigurationMessage;

    [Test]
    procedure Connect_PayloadTooLarge_RaisesRequestTooLarge;

    [Test]
    procedure Connect_ServerFailure_RaisesWithTheStatus;

    [Test]
    procedure Connect_BadRequestWithAJsonRpcBody_RaisesTheServerMessage;
  end;

implementation

uses
  MCPServer.Types,
  MCPServer.Errors,
  MCPServer.Registration,
  MCPServer.Tests.Golden,
  MCPServer.Tests.Support,
  MCPClient.Errors;

const
  GOLDEN_CLIENT_NAME = 'golden-client';
  LOOPBACK = '127.0.0.1';
  ENDPOINT = '/mcp';
  URL_TEMPLATE = 'http://%s:%d%s';

  CASE_INITIALIZE = 'initialize-2025-11-25';
  CASE_INITIALIZED = 'notifications-initialized';
  CASE_TOOLS_LIST = 'tools-list';
  CASE_ECHO = 'tools-call-echo';
  CASE_ECHO_UNICODE = 'tools-call-echo-unicode';
  CASE_CALCULATE = 'tools-call-calculate';
  CASE_DIVIDE_BY_ZERO = 'tools-call-calculate-divide-by-zero';
  CASE_INVALID_ARGUMENT = 'tools-call-invalid-argument-type';
  CASE_GET_TIME = 'tools-call-get-time';
  CASE_UNKNOWN_TOOL = 'tools-call-unknown-tool';

  TOOL_ECHO = 'echo';
  TOOL_CALCULATE = 'calculate';
  TOOL_GET_TIME = 'get_time';
  TOOL_SIMPLE_TEXT = 'test_simple_text';
  TOOL_IMAGE = 'test_image_content';
  TOOL_MIXED = 'test_multiple_content_types';
  TOOL_STRUCTURED = 'test_structured_result';
  TOOL_LATE = 'test_error_handling';

  HOST_TOOLS: array[0..5] of string = (TOOL_ECHO, TOOL_CALCULATE, TOOL_GET_TIME, TOOL_SIMPLE_TEXT,
    TOOL_IMAGE, TOOL_MIXED);

  STRUCTURED_JSON = '{"ok":true,"rows":2}';
  SUMMARY_IMAGE = 'image image/png 70 bytes';
  SUMMARY_RESOURCE = 'resource text/plain 48 bytes';

  ID_TOKEN = '%ID%';
  INITIALIZE_RESULT =
    '{"jsonrpc":"2.0","id":' + ID_TOKEN + ',"result":{"protocolVersion":"2025-11-25",' +
    '"capabilities":{},"serverInfo":{"name":"stub","version":"1.0.0"}}}';
  TOOLS_PAGE_ONE =
    '{"jsonrpc":"2.0","id":' + ID_TOKEN + ',"result":{"tools":[{"name":"first",' +
    '"description":"The first page"}],"nextCursor":"page-2"}}';
  TOOLS_PAGE_TWO =
    '{"jsonrpc":"2.0","id":' + ID_TOKEN + ',"result":{"tools":[{"name":"second",' +
    '"description":"The second page"}]}}';
  TOOLS_SAME_CURSOR =
    '{"jsonrpc":"2.0","id":' + ID_TOKEN + ',"result":{"tools":[],"nextCursor":"page-2"}}';
  TOOLS_WRONG_ID = '{"jsonrpc":"2.0","id":9999,"result":{"tools":[]}}';
  STRUCTURED_ONLY =
    '{"jsonrpc":"2.0","id":' + ID_TOKEN + ',"result":{"structuredContent":' + STRUCTURED_JSON + '}}';
  FORBIDDEN_ERROR =
    '{"jsonrpc":"2.0","id":' + ID_TOKEN + ',"error":{"code":-32600,"message":"The admin scope is required"}}';
  FORBIDDEN_ERROR_WITH_DATA =
    '{"jsonrpc":"2.0","id":' + ID_TOKEN + ',"error":{"code":-32600,"message":"The admin scope is required",' +
    '"data":{"requiredScope":"orders.write"}}}';
  BAD_REQUEST_ERROR =
    '{"jsonrpc":"2.0","id":' + ID_TOKEN + ',"error":{"code":-32600,"message":"Unsupported MCP-Protocol-Version header: x"}}';

  SCOPE_CHALLENGE = 'Bearer error="insufficient_scope", scope="admin"';
  STUB_SESSION = 'stub-session-42';

  MEDIA_TYPE_TEXT = 'text/plain';
  SERVER_FAILURE_STATUS = 500;
  SERVER_FAILURE_BODY = '{"message":"the server is on fire"}';

{ TStructuredTool }

constructor TStructuredTool.Create;
begin
  inherited;
  FName := TOOL_STRUCTURED;
  FDescription := 'Returns a JSON object, which the server publishes as structured content';
end;

function TStructuredTool.BuildSchema: TJSONObject;
begin
  Result := TJSONObject.ParseJSONValue(MCP_CLIENT_EMPTY_INPUT_SCHEMA) as TJSONObject;
end;

function TStructuredTool.DoExecute(const Arguments: TJSONObject): TValue;
begin
  Result := TValue.From<TJSONObject>(TJSONObject.ParseJSONValue(STRUCTURED_JSON) as TJSONObject);
end;

{ TMCPClientLegacyTests }

procedure TMCPClientLegacyTests.Setup;
begin
  FHost := TMCPServerHost.Create;
  FHost.Settings.Port := 0;
  FHost.Settings.CorsEnabled := False;
  for var Name in HOST_TOOLS do
    FHost.AddTool(TMCPRegistry.CreateTool(Name));
  FHost.AddTool(TStructuredTool.Create);
  FHost.StartHttp;

  NewClient(Options);
end;

procedure TMCPClientLegacyTests.TearDown;
begin
  FTrace := nil;
  FClient := nil;
  FHost.Free;
end;

function TMCPClientLegacyTests.Url: string;
begin
  Result := Format(URL_TEMPLATE, [LOOPBACK, FHost.BoundPort, ENDPOINT]);
end;

function TMCPClientLegacyTests.Options: TMCPClientOptions;
begin
  Result := TMCPClientOptions.Default;
  Result.Era := TMCPClientEra.Legacy;
  Result.ClientName := GOLDEN_CLIENT_NAME;
end;

procedure TMCPClientLegacyTests.NewClient(const AOptions: TMCPClientOptions);
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

function TMCPClientLegacyTests.LastBody: string;
begin
  Assert.IsTrue(Length(FBodies) > 0, 'the client sent nothing');
  Result := FBodies[High(FBodies)];
end;

function TMCPClientLegacyTests.BodyCount: Integer;
begin
  Result := Integer(Length(FBodies));
end;

function TMCPClientLegacyTests.GoldenRequest(const CaseName: string): string;
begin
  const GoldenCase = TGoldenCase.Create(TGoldenFiles.CaseFile(TGoldenFiles.LEGACY_SUITE, CaseName));
  try
    Result := GoldenCase.RequestBody;
  finally
    GoldenCase.Free;
  end;
end;

function TMCPClientLegacyTests.Normalised(const Body: string): string;
begin
  const Request = TMCPTestJson.ParseObject(Body);
  try
    for var Pair in Request do
    begin
      const IsId = (Pair.JsonString.Value = 'id');
      if IsId then
        Pair.JsonValue := TJSONNumber.Create(0);
    end;
    Result := Request.Format(2);
  finally
    Request.Free;
  end;
end;

procedure TMCPClientLegacyTests.AssertRequestMatches(const CaseName, Body: string);
begin
  Assert.AreEqual(Normalised(GoldenRequest(CaseName)), Normalised(Body),
    'the request does not match golden case ' + CaseName);
end;

function TMCPClientLegacyTests.CallGolden(const CaseName: string): TMCPToolCallOutcome;
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

function TMCPClientLegacyTests.ToolNamed(const Name: string): TMCPRemoteTool;
begin
  for var Tool in FClient.ListTools do
    if Tool.Name = Name then
      Exit(Tool);

  Assert.Fail('the server did not publish ' + Name);
  Result := Default(TMCPRemoteTool);
end;

procedure TMCPClientLegacyTests.Connect_LegacyEra_NegotiatesTheLatestLegacyVersion;
begin
  FClient.Connect;

  Assert.IsTrue(FClient.IsConnected);
  Assert.AreEqual(MCP_LATEST_LEGACY_PROTOCOL_VERSION, FClient.ProtocolVersion);
  Assert.AreEqual(Ord(TMCPClientEra.Legacy), Ord(FClient.Era));
  Assert.AreEqual(Url, FClient.ServerUrl);
end;

procedure TMCPClientLegacyTests.Connect_InitializeRequest_MatchesTheGoldenRequest;
begin
  FClient.Connect;

  Assert.AreEqual(2, BodyCount, 'the handshake is one request and one notification');
  AssertRequestMatches(CASE_INITIALIZE, FBodies[0]);
end;

procedure TMCPClientLegacyTests.Connect_InitializedNotification_MatchesTheGoldenRequest;
begin
  FClient.Connect;

  AssertRequestMatches(CASE_INITIALIZED, FBodies[1]);
end;

procedure TMCPClientLegacyTests.Connect_Twice_HandshakesOnce;
begin
  FClient.Connect;
  FClient.Connect;

  Assert.AreEqual(2, BodyCount, 'the second Connect handshook again');
end;

procedure TMCPClientLegacyTests.Connect_ServerInfo_NamesTheServer;
begin
  FClient.Connect;

  const Info = TMCPTestJson.ParseObject(FClient.ServerInfoJson);
  try
    Assert.AreEqual('delphi-mcp-server', Info.GetValue<string>(MCP_KEY_NAME));
  finally
    Info.Free;
  end;
end;

procedure TMCPClientLegacyTests.Connect_WithAnInputResponder_DeclaresTheThreeCapabilities;
begin
  FClient.SetInputResponder(
    function(const Key, Method: string; const Params: TJSONObject): TJSONObject
    begin
      Result := TJSONObject.Create;
    end);

  FClient.Connect;

  const Request = TMCPTestJson.ParseObject(FBodies[0]);
  try
    const Capabilities = Request.GetValue<TJSONObject>(MCP_KEY_PARAMS).GetValue<TJSONObject>(MCP_KEY_CAPABILITIES);
    Assert.AreEqual(3, Capabilities.Count, 'the declared capabilities do not follow the responder');
    Assert.IsNotNull(Capabilities.GetValue('elicitation'));
    Assert.IsNotNull(Capabilities.GetValue('sampling'));
    Assert.IsNotNull(Capabilities.GetValue('roots'));
  finally
    Request.Free;
  end;
end;

procedure TMCPClientLegacyTests.Close_ThenCallTool_HandshakesAgain;
begin
  FClient.Connect;
  FClient.Close;

  Assert.IsFalse(FClient.IsConnected);
  Assert.AreEqual('', FClient.ProtocolVersion);

  FClient.ListTools;

  Assert.IsTrue(FClient.IsConnected);
  Assert.AreEqual(5, BodyCount, 'the client did not handshake again after Close');
end;

procedure TMCPClientLegacyTests.ListTools_Request_MatchesTheGoldenRequest;
begin
  FClient.ListTools;

  AssertRequestMatches(CASE_TOOLS_LIST, LastBody);
end;

procedure TMCPClientLegacyTests.ListTools_ListsTheHostToolsInRegistrationOrder;
begin
  var Names: TArray<string> := nil;
  for var Tool in FClient.ListTools do
    Names := Names + [Tool.Name];

  Assert.AreEqual('echo,calculate,get_time,test_simple_text,test_image_content,' +
    'test_multiple_content_types,test_structured_result', string.Join(',', Names));
end;

procedure TMCPClientLegacyTests.ListTools_ReadOnlyTool_CarriesTheAnnotations;
begin
  const Tool = ToolNamed(TOOL_SIMPLE_TEXT);

  Assert.IsTrue(Tool.HasAnnotations, 'the read-only hint did not reach the record');
  Assert.IsTrue(Tool.ReadOnlyHint);
  Assert.IsFalse(Tool.OpenWorldHint);
end;

procedure TMCPClientLegacyTests.ListTools_ToolWithoutAnnotations_ReportsNone;
begin
  const Tool = ToolNamed(TOOL_ECHO);

  Assert.IsFalse(Tool.HasAnnotations, 'a tool without annotations claims to have them');
  Assert.IsFalse(Tool.ReadOnlyHint);
end;

procedure TMCPClientLegacyTests.ListTools_InputSchema_IsKeptAsText;
begin
  const Tool = ToolNamed(TOOL_ECHO);

  const Schema = TMCPTestJson.ParseObject(Tool.InputSchemaJson);
  try
    Assert.AreEqual('object', Schema.GetValue<string>('type'));
    Assert.IsNotNull(Schema.GetValue<TJSONObject>('properties').GetValue('message'));
  finally
    Schema.Free;
  end;

  Assert.AreEqual('', Tool.OutputSchemaJson, 'a tool without an output schema reports one');
end;

procedure TMCPClientLegacyTests.ListTools_SecondCall_IsAnsweredFromTheCache;
begin
  FClient.ListTools;
  const AfterFirst = BodyCount;

  FClient.ListTools;

  Assert.AreEqual(AfterFirst, BodyCount, 'the second ListTools went to the server');
end;

procedure TMCPClientLegacyTests.RefreshTools_AfterTheHostGainedATool_SeesIt;
begin
  const Before = Integer(Length(FClient.ListTools));
  FHost.AddTool(TMCPRegistry.CreateTool(TOOL_LATE));

  FClient.RefreshTools;

  Assert.AreEqual(Before + 1, Integer(Length(FClient.ListTools)));
  Assert.AreEqual(TOOL_LATE, ToolNamed(TOOL_LATE).Name);
end;

procedure TMCPClientLegacyTests.CallTool_Echo_ReturnsTheEchoedText;
begin
  const Outcome = CallGolden(CASE_ECHO);

  Assert.IsFalse(Outcome.IsError);
  Assert.AreEqual('Echo: hello golden', Outcome.Text);
  Assert.AreEqual('complete', Outcome.ResultType);
  Assert.AreEqual(0, Outcome.ErrorCode);
  Assert.AreEqual(0, Integer(Length(Outcome.NonTextBlocks)));
end;

procedure TMCPClientLegacyTests.CallTool_EchoUnicode_RoundTripsTheText;
begin
  const Request = TMCPTestJson.ParseObject(GoldenRequest(CASE_ECHO_UNICODE));
  var Sent := '';
  try
    Sent := Request.GetValue<TJSONObject>(MCP_KEY_PARAMS)
      .GetValue<TJSONObject>(MCP_KEY_ARGUMENTS).GetValue<string>('message');
  finally
    Request.Free;
  end;

  const Outcome = CallGolden(CASE_ECHO_UNICODE);

  Assert.AreEqual('Echo: ' + Sent, Outcome.Text);
end;

procedure TMCPClientLegacyTests.CallTool_Calculate_ReturnsTheSum;
begin
  const Outcome = CallGolden(CASE_CALCULATE);

  Assert.IsFalse(Outcome.IsError);
  Assert.IsTrue(Outcome.Text.StartsWith('2 add'), 'the calculation is missing from ' + Outcome.Text);
end;

procedure TMCPClientLegacyTests.CallTool_DivideByZero_IsAFailedToolResult;
begin
  const Outcome = CallGolden(CASE_DIVIDE_BY_ZERO);

  Assert.IsTrue(Outcome.IsError, 'a failing tool reported success');
  Assert.AreEqual('Error: Division by zero', Outcome.Text);
  Assert.AreEqual(0, Outcome.ErrorCode, 'a tool failure is not a JSON-RPC error');
end;

procedure TMCPClientLegacyTests.CallTool_InvalidArgumentType_IsAFailedToolResult;
begin
  const Outcome = CallGolden(CASE_INVALID_ARGUMENT);

  Assert.IsTrue(Outcome.IsError);
  Assert.AreEqual('Invalid arguments: Parameter "a": expected a number', Outcome.Text);
end;

procedure TMCPClientLegacyTests.CallTool_WithoutArguments_WritesAnEmptyArgumentsObject;
begin
  const Outcome = FClient.CallTool(TOOL_GET_TIME, nil);

  AssertRequestMatches(CASE_GET_TIME, LastBody);
  Assert.IsFalse(Outcome.IsError);
  Assert.IsTrue(Outcome.Text <> '', 'the server answered no time at all');
end;

procedure TMCPClientLegacyTests.CallTool_UnknownTool_IsAnErrorOutcomeAndNotAnException;
begin
  const Outcome = CallGolden(CASE_UNKNOWN_TOOL);

  Assert.IsTrue(Outcome.IsError);
  Assert.AreEqual(Integer(JSONRPC_INVALID_PARAMS), Outcome.ErrorCode);
  Assert.AreEqual('Unknown tool: no_such_tool', Outcome.ErrorMessage);
  Assert.AreEqual('Unknown tool: no_such_tool', Outcome.Text);
end;

procedure TMCPClientLegacyTests.CallTool_StructuredResult_KeepsTheStructuredJson;
begin
  const Outcome = FClient.CallTool(TOOL_STRUCTURED, nil);

  Assert.IsFalse(Outcome.IsError);
  Assert.AreEqual(STRUCTURED_JSON, Outcome.StructuredJson);
  Assert.AreEqual(STRUCTURED_JSON, Outcome.Text, 'the server wrote the structured result as text too');
end;

procedure TMCPClientLegacyTests.CallTool_MixedContent_SummarisesEveryNonTextBlock;
begin
  const Outcome = FClient.CallTool(TOOL_MIXED, nil);

  Assert.AreEqual('Multiple content types example', Outcome.Text);
  Assert.AreEqual(SUMMARY_IMAGE + '|' + SUMMARY_RESOURCE, string.Join('|', Outcome.NonTextBlocks));
  Assert.IsTrue(Outcome.ContentJson.Contains(MEDIA_TYPE_TEXT), 'the raw content array was dropped');
end;

procedure TMCPClientLegacyTests.CallTool_ImageOnly_HasNoTextAndOneSummary;
begin
  const Outcome = FClient.CallTool(TOOL_IMAGE, nil);

  Assert.AreEqual('', Outcome.Text);
  Assert.AreEqual(SUMMARY_IMAGE, string.Join('|', Outcome.NonTextBlocks));
end;

procedure TMCPClientLegacyTests.CallTool_BeforeConnect_ConnectsFirst;
begin
  const Outcome = FClient.CallTool(TOOL_ECHO, nil);

  Assert.IsTrue(FClient.IsConnected, 'CallTool did not connect');
  Assert.IsTrue(Outcome.Text.StartsWith('Invalid arguments'), 'the server answered ' + Outcome.Text);
  Assert.AreEqual(3, BodyCount, 'the handshake did not run before the call');
end;

procedure TMCPClientLegacyTests.CallTool_WithoutTheEventStream_ReadsThePlainJsonAnswer;
begin
  var PlainJson := Options;
  PlainJson.AcceptEventStream := False;
  NewClient(PlainJson);

  const Outcome = CallGolden(CASE_ECHO);

  Assert.AreEqual('Echo: hello golden', Outcome.Text);
end;

{ TStubReply }

class function TStubReply.Json(const Body: string): TStubReply;
begin
  Result := Default(TStubReply);
  Result.Status := HTTP_STATUS_OK;
  Result.ContentType := MEDIA_TYPE_JSON;
  Result.Body := Body;
end;

class function TStubReply.Accepted: TStubReply;
begin
  Result := Default(TStubReply);
  Result.Status := HTTP_STATUS_ACCEPTED;
  Result.ContentType := MEDIA_TYPE_JSON;
end;

class function TStubReply.Failure(const Status: Integer; const Body: string): TStubReply;
begin
  Result := Default(TStubReply);
  Result.Status := Status;
  Result.ContentType := MEDIA_TYPE_JSON;
  Result.Body := Body;
end;

{ TStubServer }

constructor TStubServer.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FReplies := TList<TStubReply>.Create;
  FExchanges := TList<TStubExchange>.Create;

  FServer := TIdHTTPServer.Create(nil);
  FServer.OnCommandGet := HandleCommand;
  FServer.OnCommandOther := HandleCommand;
  FServer.DefaultPort := 0;
  FServer.Bindings.Add.IP := LOOPBACK;
  FServer.Active := True;
end;

destructor TStubServer.Destroy;
begin
  FServer.Active := False;
  FServer.Free;
  FExchanges.Free;
  FReplies.Free;
  FLock.Free;
  inherited;
end;

procedure TStubServer.Add(const Reply: TStubReply);
begin
  FLock.Enter;
  try
    FReplies.Add(Reply);
  finally
    FLock.Leave;
  end;
end;

procedure TStubServer.AddHandshake(const SessionId: string);
begin
  var Reply := TStubReply.Json(INITIALIZE_RESULT);
  Reply.SessionId := SessionId;
  Add(Reply);
  Add(TStubReply.Accepted);
end;

function TStubServer.Url: string;
begin
  Result := Format(URL_TEMPLATE, [LOOPBACK, FServer.Bindings[0].Port, ENDPOINT]);
end;

function TStubServer.Exchange(const Index: Integer): TStubExchange;
begin
  FLock.Enter;
  try
    Result := FExchanges[Index];
  finally
    FLock.Leave;
  end;
end;

function TStubServer.TakeReply: TStubReply;
begin
  FLock.Enter;
  try
    if FReplies.Count = 0 then
      Exit(TStubReply.Json(''));

    const At = FIndex;
    if At < FReplies.Count - 1 then
      Inc(FIndex);
    Result := FReplies[At];
  finally
    FLock.Leave;
  end;
end;

class function TStubServer.ReadBody(RequestInfo: TIdHTTPRequestInfo): string;
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

class function TStubServer.RequestId(const Body: string): string;
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

procedure TStubServer.HandleCommand(Context: TIdContext; RequestInfo: TIdHTTPRequestInfo;
  ResponseInfo: TIdHTTPResponseInfo);
begin
  var Exchange := Default(TStubExchange);
  Exchange.Body := ReadBody(RequestInfo);
  Exchange.SessionId := RequestInfo.RawHeaders.Values[MCP_HEADER_SESSION_ID];
  Exchange.ProtocolVersion := RequestInfo.RawHeaders.Values[MCP_HEADER_PROTOCOL_VERSION];

  FLock.Enter;
  try
    FExchanges.Add(Exchange);
  finally
    FLock.Leave;
  end;

  const Reply = TakeReply;
  ResponseInfo.ResponseNo := Reply.Status;
  ResponseInfo.ContentType := Reply.ContentType;
  if Reply.SessionId <> '' then
    ResponseInfo.CustomHeaders.Values[MCP_HEADER_SESSION_ID] := Reply.SessionId;
  if Reply.Challenge <> '' then
    ResponseInfo.CustomHeaders.Values['WWW-Authenticate'] := Reply.Challenge;

  const Body = StringReplace(Reply.Body, ID_TOKEN, RequestId(Exchange.Body), [rfReplaceAll]);
  ResponseInfo.ContentStream := TStringStream.Create(Body, TEncoding.UTF8);
  ResponseInfo.FreeContentStream := True;
end;

{ TMCPClientStatusTests }

procedure TMCPClientStatusTests.Setup;
begin
  FStub := TStubServer.Create;
  NewClient;
end;

procedure TMCPClientStatusTests.TearDown;
begin
  FClient := nil;
  FStub.Free;
end;

procedure TMCPClientStatusTests.NewClient;
begin
  var ClientOptions := TMCPClientOptions.Default;
  ClientOptions.Era := TMCPClientEra.Legacy;
  FClient := TMCPClient.Create(FStub.Url, ClientOptions);
end;

function TMCPClientStatusTests.Connected: IMCPClient;
begin
  FClient.Connect;
  Result := FClient;
end;

procedure TMCPClientStatusTests.Connect_SessionHeader_IsEchoedOnEveryLaterRequest;
begin
  FStub.AddHandshake(STUB_SESSION);
  FStub.Add(TStubReply.Json(TOOLS_PAGE_TWO));

  Connected.ListTools;

  Assert.AreEqual('', FStub.Exchange(0).SessionId, 'the client invented a session id');
  Assert.AreEqual(STUB_SESSION, FStub.Exchange(1).SessionId, 'the notification did not echo the session');
  Assert.AreEqual(STUB_SESSION, FStub.Exchange(2).SessionId, 'tools/list did not echo the session');
  Assert.AreEqual(MCP_LATEST_LEGACY_PROTOCOL_VERSION, FStub.Exchange(2).ProtocolVersion);
end;

procedure TMCPClientStatusTests.Connect_WithoutASessionHeader_SendsNone;
begin
  FStub.AddHandshake;
  FStub.Add(TStubReply.Json(TOOLS_PAGE_TWO));

  Connected.ListTools;

  Assert.AreEqual('', FStub.Exchange(2).SessionId, 'the client sent a session id the server never gave');
end;

procedure TMCPClientStatusTests.ListTools_PagedAnswer_FollowsTheCursor;
begin
  FStub.AddHandshake;
  FStub.Add(TStubReply.Json(TOOLS_PAGE_ONE));
  FStub.Add(TStubReply.Json(TOOLS_PAGE_TWO));

  const Tools = Connected.ListTools;

  Assert.AreEqual(2, Integer(Length(Tools)), 'the client stopped at the first page');
  Assert.AreEqual('first', Tools[0].Name);
  Assert.AreEqual('second', Tools[1].Name);
  Assert.AreEqual(MCP_CLIENT_EMPTY_INPUT_SCHEMA, Tools[0].InputSchemaJson);
  Assert.IsTrue(FStub.Exchange(3).Body.Contains('"cursor":"page-2"'),
    'the second page was requested without the cursor: ' + FStub.Exchange(3).Body);
end;

procedure TMCPClientStatusTests.ListTools_RepeatedCursor_RaisesAProtocolError;
begin
  FStub.AddHandshake;
  FStub.Add(TStubReply.Json(TOOLS_PAGE_ONE));
  FStub.Add(TStubReply.Json(TOOLS_SAME_CURSOR));

  const Client = Connected;
  Assert.WillRaise(
    procedure
    begin
      Client.ListTools;
    end, EMCPClientProtocolError);
end;

procedure TMCPClientStatusTests.ListTools_ResponseForAnotherRequest_RaisesAProtocolError;
begin
  FStub.AddHandshake;
  FStub.Add(TStubReply.Json(TOOLS_WRONG_ID));

  const Client = Connected;
  Assert.WillRaise(
    procedure
    begin
      Client.ListTools;
    end, EMCPClientProtocolError);
end;

procedure TMCPClientStatusTests.CallTool_StructuredContentWithoutATextBlock_BecomesTheText;
begin
  FStub.AddHandshake;
  FStub.Add(TStubReply.Json(STRUCTURED_ONLY));

  const Outcome = Connected.CallTool('anything', nil);

  Assert.AreEqual(STRUCTURED_JSON, Outcome.StructuredJson);
  Assert.AreEqual(STRUCTURED_JSON, Outcome.Text);
  Assert.AreEqual('', Outcome.ContentJson);
end;

procedure TMCPClientStatusTests.CallTool_Forbidden_ReportsTheScopeFromTheChallenge;
begin
  FStub.AddHandshake;
  var Forbidden := TStubReply.Failure(HTTP_STATUS_FORBIDDEN, FORBIDDEN_ERROR);
  Forbidden.Challenge := SCOPE_CHALLENGE;
  FStub.Add(Forbidden);

  const Outcome = Connected.CallTool('anything', nil);

  Assert.IsTrue(Outcome.IsError);
  Assert.AreEqual('admin', Outcome.RequiredScope);
  Assert.AreEqual('The admin scope is required', Outcome.ErrorMessage);
end;

procedure TMCPClientStatusTests.CallTool_Forbidden_PrefersTheScopeInTheErrorData;
begin
  FStub.AddHandshake;
  var Forbidden := TStubReply.Failure(HTTP_STATUS_FORBIDDEN, FORBIDDEN_ERROR_WITH_DATA);
  Forbidden.Challenge := SCOPE_CHALLENGE;
  FStub.Add(Forbidden);

  const Outcome = Connected.CallTool('anything', nil);

  Assert.AreEqual('orders.write', Outcome.RequiredScope);
end;

procedure TMCPClientStatusTests.ListTools_Forbidden_RaisesAScopeError;
begin
  FStub.AddHandshake;
  var Forbidden := TStubReply.Failure(HTTP_STATUS_FORBIDDEN, FORBIDDEN_ERROR);
  Forbidden.Challenge := SCOPE_CHALLENGE;
  FStub.Add(Forbidden);

  const Client = Connected;
  Assert.WillRaise(
    procedure
    begin
      Client.ListTools;
    end, EMCPClientScopeError);
end;

procedure TMCPClientStatusTests.Connect_Unauthorized_RaisesAnAuthError;
begin
  FStub.Add(TStubReply.Failure(HTTP_STATUS_UNAUTHORIZED, ''));

  Assert.WillRaise(
    procedure
    begin
      FClient.Connect;
    end, EMCPClientAuthError);
end;

procedure TMCPClientStatusTests.Connect_MethodNotAllowed_RaisesAConfigurationMessage;
begin
  FStub.Add(TStubReply.Failure(HTTP_STATUS_METHOD_NOT_ALLOWED, ''));

  Assert.WillRaise(
    procedure
    begin
      FClient.Connect;
    end, EMCPClientError);
end;

procedure TMCPClientStatusTests.Connect_PayloadTooLarge_RaisesRequestTooLarge;
begin
  FStub.Add(TStubReply.Failure(HTTP_STATUS_PAYLOAD_TOO_LARGE, ''));

  Assert.WillRaise(
    procedure
    begin
      FClient.Connect;
    end, EMCPClientRequestTooLarge);
end;

procedure TMCPClientStatusTests.Connect_ServerFailure_RaisesWithTheStatus;
begin
  FStub.Add(TStubReply.Failure(SERVER_FAILURE_STATUS, SERVER_FAILURE_BODY));

  var Reported := '';
  try
    FClient.Connect;
  except
    on E: EMCPClientError do
      Reported := E.Message;
  end;

  Assert.IsTrue(Reported.Contains('500'), 'the status is missing from ' + Reported);
  Assert.IsTrue(Reported.Contains('on fire'), 'the body is missing from ' + Reported);
end;

procedure TMCPClientStatusTests.Connect_BadRequestWithAJsonRpcBody_RaisesTheServerMessage;
begin
  FStub.Add(TStubReply.Failure(HTTP_STATUS_BAD_REQUEST, BAD_REQUEST_ERROR));

  var Reported := '';
  try
    FClient.Connect;
  except
    on E: EMCPClientError do
      Reported := E.Message;
  end;

  Assert.IsTrue(Reported.Contains('Unsupported MCP-Protocol-Version header'),
    'the server message is missing from ' + Reported);
end;

end.
