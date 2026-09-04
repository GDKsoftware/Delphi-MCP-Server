unit MCPServer.Tests.Processor;

interface

uses
  DUnitX.TestFramework,
  System.Generics.Collections,
  System.JSON,
  System.Rtti,
  MCPServer.Types,
  MCPServer.Settings,
  MCPServer.RequestContext,
  MCPServer.JsonRpcProcessor,
  MCPServer.Tests.Harness;

type
  TProbeManager = class(TInterfacedObject, IMCPCapabilityManager, IMCPCapabilityManagerEx)
  public
    SeenContext: IMCPRequestContext;
    SeenCurrent: IMCPRequestContext;
    function GetCapabilityName: string;
    function HandlesMethod(const Method: string): Boolean;
    function ExecuteMethod(const Method: string; const Params: TJSONObject): TValue;
    function ExecuteMethodWithContext(const Method: string; const Params: TJSONObject;
      const Context: IMCPRequestContext): TValue;
  end;

  [TestFixture]
  TProcessorTests = class
  private
    FHarness: TMCPTestHarness;
    FSettings: TMCPSettings;
    FProcessor: TMCPJsonRpcProcessor;
    function Run(const RequestJson: string; const Hints: TMCPTransportHints): TMCPProcessResult;
    function Parse(const Body: string): TJSONObject;
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    [Test] procedure Modern_UnknownMethod_Is404;
    [Test] procedure Legacy_UnknownMethod_Is200;
    [Test] procedure ParseError_ModernHeader_Is400_LegacyIs200;
    [Test] procedure Modern_MetaValidationError_Is400;
    [Test] procedure Modern_ApplicationInvalidParams_Is200;
    [Test] procedure Modern_ToolsList_HasEnvelopeAndCacheHints;
    [Test] procedure Modern_ToolsCall_HasResultTypeButNoCacheHints;
    [Test] procedure Modern_Discover_ListsModernVersionsAndCapabilities;
    [Test] procedure Modern_Discover_ListsLegacyVersions_WhenConfigured;
    [Test] procedure Modern_ServerInfo_UsesSettings;
    [Test] procedure Legacy_Initialize_NegotiatesAndDeclaresCapabilities;
    [Test] procedure Legacy_Result_IsUntouched;
    [Test] procedure Notification_Returns202WithoutBody;
    [Test] procedure ClientResponse_Legacy_IsIgnored_Modern_IsRejected;
    [Test] procedure ErrorData_IsEmitted;
    [Test] procedure Current_IsSetDuringDispatch_AndClearedAfter;
    [Test] procedure Concurrent_Initialize_AllSucceed;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.Threading,
  MCPServer.ManagerRegistry,
  MCPServer.Errors;

const
  META = '"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}';

{ TProbeManager }

function TProbeManager.GetCapabilityName: string;
begin
  Result := 'probe';
end;

function TProbeManager.HandlesMethod(const Method: string): Boolean;
begin
  Result := Method = 'probe/run';
end;

function TProbeManager.ExecuteMethod(const Method: string; const Params: TJSONObject): TValue;
begin
  Result := ExecuteMethodWithContext(Method, Params, nil);
end;

function TProbeManager.ExecuteMethodWithContext(const Method: string; const Params: TJSONObject;
  const Context: IMCPRequestContext): TValue;
begin
  SeenContext := Context;
  SeenCurrent := TMCPRequestContext.Current;
  Result := TValue.From<TJSONObject>(TJSONObject.Create);
end;

{ TProcessorTests }

procedure TProcessorTests.Setup;
begin
  FHarness := TMCPTestHarness.Create;
  FSettings := FHarness.Settings;
  FProcessor := TMCPJsonRpcProcessor.Create(FHarness.ManagerRegistry, FSettings);
end;

procedure TProcessorTests.TearDown;
begin
  FProcessor.Free;
  FHarness.Free;
end;

function TProcessorTests.Run(const RequestJson: string; const Hints: TMCPTransportHints): TMCPProcessResult;
begin
  Result := FProcessor.ProcessRequestEx(RequestJson, Hints);
end;

function TProcessorTests.Parse(const Body: string): TJSONObject;
begin
  Result := TJSONObject.ParseJSONValue(Body) as TJSONObject;
  Assert.IsNotNull(Result, 'response is not a JSON object: ' + Body);
end;

procedure TProcessorTests.Modern_UnknownMethod_Is404;
begin
  var Outcome := Run('{"jsonrpc":"2.0","id":1,"method":"totally/bogus/method","params":{' + META + '}}', TMCPTransportHints.None);
  Assert.AreEqual(404, Outcome.HttpStatus);
  Assert.AreEqual(TMCPProtocolEra.Modern, Outcome.Era);
  var Response := Parse(Outcome.Body);
  try
    Assert.AreEqual(JSONRPC_METHOD_NOT_FOUND, Response.GetValue<Integer>('error.code'));
  finally
    Response.Free;
  end;
end;

procedure TProcessorTests.Legacy_UnknownMethod_Is200;
begin
  var Outcome := Run('{"jsonrpc":"2.0","id":1,"method":"totally/bogus/method"}', TMCPTransportHints.ForHttp(True, '2025-06-18'));
  Assert.AreEqual(200, Outcome.HttpStatus);
  Assert.AreEqual(TMCPProtocolEra.Legacy, Outcome.Era);
end;

procedure TProcessorTests.ParseError_ModernHeader_Is400_LegacyIs200;
begin
  Assert.AreEqual(400, Run('{not json', TMCPTransportHints.ForHttp(True, '2026-07-28')).HttpStatus);
  Assert.AreEqual(200, Run('{not json', TMCPTransportHints.ForHttp(True, '2025-06-18')).HttpStatus);
  Assert.AreEqual(200, Run('{not json', TMCPTransportHints.None).HttpStatus);
end;

procedure TProcessorTests.Modern_MetaValidationError_Is400;
begin
  var Outcome := Run('{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}', TMCPTransportHints.None);
  Assert.AreEqual(400, Outcome.HttpStatus);
  var Response := Parse(Outcome.Body);
  try
    Assert.AreEqual(JSONRPC_INVALID_PARAMS, Response.GetValue<Integer>('error.code'));
  finally
    Response.Free;
  end;
end;

procedure TProcessorTests.Modern_ApplicationInvalidParams_Is200;
begin
  var Probe := TProbeManager.Create;
  var Registry: IMCPManagerRegistry := TMCPManagerRegistry.Create;
  Registry.RegisterManager(Probe);
  var Processor := TMCPJsonRpcProcessor.Create(Registry, FSettings);
  try
    Probe.SeenContext := nil;
    var Outcome := Processor.ProcessRequestEx('{"jsonrpc":"2.0","id":1,"method":"probe/run","params":{' + META + '}}', TMCPTransportHints.None);
    Assert.AreEqual(200, Outcome.HttpStatus);
  finally
    Processor.Free;
  end;
end;

procedure TProcessorTests.Modern_ToolsList_HasEnvelopeAndCacheHints;
begin
  var Outcome := Run('{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{' + META + '}}', TMCPTransportHints.None);
  Assert.AreEqual(200, Outcome.HttpStatus);
  var Response := Parse(Outcome.Body);
  try
    Assert.AreEqual('complete', Response.GetValue<string>('result.resultType'));
    Assert.AreEqual('delphi-mcp-server', Response.GetValue<string>('result._meta["io.modelcontextprotocol/serverInfo"].name'));
    Assert.AreEqual(0, Response.GetValue<Integer>('result.ttlMs'));
    Assert.AreEqual('private', Response.GetValue<string>('result.cacheScope'));
    Assert.IsNotNull(Response.FindValue('result.tools'));
  finally
    Response.Free;
  end;
end;

procedure TProcessorTests.Modern_ToolsCall_HasResultTypeButNoCacheHints;
begin
  var Outcome := Run('{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":{"message":"hi"},' + META + '}}', TMCPTransportHints.None);
  var Response := Parse(Outcome.Body);
  try
    Assert.AreEqual('complete', Response.GetValue<string>('result.resultType'));
    Assert.IsNull(Response.FindValue('result.ttlMs'));
    Assert.IsNull(Response.FindValue('result.cacheScope'));
    Assert.AreEqual('Echo: hi', Response.GetValue<string>('result.content[0].text'));
  finally
    Response.Free;
  end;
end;

procedure TProcessorTests.Modern_Discover_ListsModernVersionsAndCapabilities;
begin
  var Outcome := Run('{"jsonrpc":"2.0","id":"d","method":"server/discover","params":{' + META + '}}', TMCPTransportHints.None);
  Assert.AreEqual(200, Outcome.HttpStatus);
  var Response := Parse(Outcome.Body);
  try
    var Versions := Response.FindValue('result.supportedVersions') as TJSONArray;
    Assert.AreEqual(1, Versions.Count);
    Assert.AreEqual('2026-07-28', Versions.Items[0].Value);
    Assert.IsFalse(Response.GetValue<Boolean>('result.capabilities.tools.listChanged'));
    Assert.IsFalse(Response.GetValue<Boolean>('result.capabilities.resources.subscribe'));
    Assert.IsNull(Response.FindValue('result.capabilities.logging'));
    Assert.AreEqual('public', Response.GetValue<string>('result.cacheScope'));
    Assert.AreEqual(0, Response.GetValue<Integer>('result.ttlMs'));
  finally
    Response.Free;
  end;
end;

procedure TProcessorTests.Modern_Discover_ListsLegacyVersions_WhenConfigured;
begin
  FSettings.DiscoverListsLegacyVersions := True;
  var Outcome := Run('{"jsonrpc":"2.0","id":"d","method":"server/discover","params":{' + META + '}}', TMCPTransportHints.None);
  var Response := Parse(Outcome.Body);
  try
    var Versions := Response.FindValue('result.supportedVersions') as TJSONArray;
    Assert.AreEqual(3, Versions.Count);
  finally
    Response.Free;
  end;
end;

procedure TProcessorTests.Modern_ServerInfo_UsesSettings;
begin
  FSettings.ServerTitle := 'Test Server';
  FSettings.ServerWebsiteUrl := 'https://example.com';
  FSettings.Instructions := 'Use the echo tool.';
  var Outcome := Run('{"jsonrpc":"2.0","id":"d","method":"server/discover","params":{' + META + '}}', TMCPTransportHints.None);
  var Response := Parse(Outcome.Body);
  try
    Assert.AreEqual('Test Server', Response.GetValue<string>('result._meta["io.modelcontextprotocol/serverInfo"].title'));
    Assert.AreEqual('https://example.com', Response.GetValue<string>('result._meta["io.modelcontextprotocol/serverInfo"].websiteUrl'));
    Assert.AreEqual('Use the echo tool.', Response.GetValue<string>('result.instructions'));
  finally
    Response.Free;
  end;
end;

procedure TProcessorTests.Legacy_Initialize_NegotiatesAndDeclaresCapabilities;
begin
  var Outcome := Run('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"roots":{}},"clientInfo":{"name":"c","version":"1"}}}', TMCPTransportHints.None);
  Assert.AreEqual(200, Outcome.HttpStatus);
  var Response := Parse(Outcome.Body);
  try
    Assert.AreEqual('2025-11-25', Response.GetValue<string>('result.protocolVersion'));
    Assert.IsFalse(Response.GetValue<Boolean>('result.capabilities.tools.listChanged'));
    Assert.IsNull(Response.FindValue('result.sessionId'));
    Assert.IsNull(Response.FindValue('result.capabilities.tools.supportsProgress'));
    Assert.IsNull(Response.FindValue('result.resultType'));
  finally
    Response.Free;
  end;
end;

procedure TProcessorTests.Legacy_Result_IsUntouched;
begin
  var Outcome := Run('{"jsonrpc":"2.0","id":1,"method":"tools/list"}', TMCPTransportHints.None);
  var Response := Parse(Outcome.Body);
  try
    Assert.IsNull(Response.FindValue('result.resultType'));
    Assert.IsNull(Response.FindValue('result._meta'));
    Assert.IsNull(Response.FindValue('result.ttlMs'));
  finally
    Response.Free;
  end;
end;

procedure TProcessorTests.Notification_Returns202WithoutBody;
begin
  var Outcome := Run('{"jsonrpc":"2.0","method":"notifications/initialized"}', TMCPTransportHints.None);
  Assert.AreEqual('', Outcome.Body);
  Assert.AreEqual(202, Outcome.HttpStatus);
  Assert.IsTrue(Outcome.IsNotification);
end;

procedure TProcessorTests.ClientResponse_Legacy_IsIgnored_Modern_IsRejected;
begin
  var Legacy := Run('{"jsonrpc":"2.0","id":1,"result":{}}', TMCPTransportHints.None);
  Assert.AreEqual('', Legacy.Body);
  Assert.AreEqual(202, Legacy.HttpStatus);

  var Modern := Run('{"jsonrpc":"2.0","id":1,"result":{}}', TMCPTransportHints.ForHttp(True, '2026-07-28'));
  Assert.AreEqual(400, Modern.HttpStatus);
  Assert.IsTrue(Modern.Body.Contains('-32600'));
end;

procedure TProcessorTests.ErrorData_IsEmitted;
begin
  var Outcome := Run('{"jsonrpc":"2.0","id":7,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2030-01-01","io.modelcontextprotocol/clientCapabilities":{}}}}', TMCPTransportHints.None);
  Assert.AreEqual(400, Outcome.HttpStatus);
  var Response := Parse(Outcome.Body);
  try
    Assert.AreEqual(7, Response.GetValue<Integer>('id'));
    Assert.AreEqual(MCP_ERROR_UNSUPPORTED_PROTOCOL_VERSION, Response.GetValue<Integer>('error.code'));
    Assert.AreEqual('2030-01-01', Response.GetValue<string>('error.data.requested'));
    Assert.AreEqual('2026-07-28', Response.GetValue<string>('error.data.supported[0]'));
  finally
    Response.Free;
  end;
end;

procedure TProcessorTests.Current_IsSetDuringDispatch_AndClearedAfter;
begin
  var Probe := TProbeManager.Create;
  var Registry: IMCPManagerRegistry := TMCPManagerRegistry.Create;
  Registry.RegisterManager(Probe);
  var Processor := TMCPJsonRpcProcessor.Create(Registry, FSettings);
  try
    Processor.ProcessRequestEx('{"jsonrpc":"2.0","id":"x","method":"probe/run","params":{' + META + '}}', TMCPTransportHints.None);

    Assert.IsNotNull(Probe.SeenContext);
    Assert.AreSame(Probe.SeenContext, Probe.SeenCurrent);
    Assert.AreEqual('x', Probe.SeenContext.RequestId.AsText);
    Assert.AreEqual(TMCPProtocolEra.Modern, Probe.SeenContext.Era);
    Assert.IsNull(TMCPRequestContext.Current);
  finally
    Probe.SeenContext := nil;
    Probe.SeenCurrent := nil;
    Processor.Free;
  end;
end;

procedure TProcessorTests.Concurrent_Initialize_AllSucceed;
const
  REQUESTS = 50;
begin
  var Failures := 0;
  var Tasks: TArray<ITask>;
  SetLength(Tasks, REQUESTS);
  for var I := 0 to High(Tasks) do
    Tasks[I] := TTask.Run(
      procedure
      begin
        var Outcome := FProcessor.ProcessRequestEx(
          '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"c","version":"1"}}}',
          TMCPTransportHints.None);
        if not Outcome.Body.Contains('"protocolVersion":"2025-06-18"') or Outcome.Body.Contains('"error"') then
          AtomicIncrement(Failures);
      end);
  TTask.WaitForAll(Tasks);

  Assert.AreEqual(0, Failures);
end;

end.
