unit MCPServer.Tests.RequestContext;

interface

uses
  DUnitX.TestFramework,
  System.Generics.Collections,
  System.JSON,
  MCPServer.Types,
  MCPServer.Settings,
  MCPServer.RequestContext,
  MCPServer.JsonRpcProcessor,
  MCPServer.Tests.Harness;

type
  /// Era detection, one branch per test, straight against BuildRequestContext.
  [TestFixture]
  TRequestContextTests = class
  private
    FHarness: TMCPTestHarness;
    FSettings: TMCPSettings;
    FProcessor: TMCPJsonRpcProcessor;
    FSession: TMCPLegacySession;
    function Build(const RequestJson: string; const Hints: TMCPTransportHints): IMCPRequestContext;
    procedure ExpectError(const RequestJson: string; const Hints: TMCPTransportHints;
      ExpectedCode, ExpectedStatus: Integer; const Because: string);
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    [Test] procedure Initialize_IsLegacy_EvenWithModernMeta;
    [Test] procedure Initialize_EchoesServedRevision;
    [Test] procedure Initialize_UnknownRevision_AnswersLatestLegacy;
    [Test] procedure ModernMeta_IsModern;
    [Test] procedure ModernMeta_Http_HeaderMissing_IsHeaderMismatch;
    [Test] procedure ModernMeta_Http_HeaderDiffers_IsHeaderMismatch;
    [Test] procedure ModernMeta_Http_HeaderMatches_IsModern;
    [Test] procedure ModernMeta_UnknownVersion_ListsSupported;
    [Test] procedure ModernMeta_MissingClientCapabilities_IsInvalidParams;
    [Test] procedure ModernMeta_ClientInfoNotObject_IsInvalidParams;
    [Test] procedure ModernMeta_InvalidLogLevel_IsInvalidParams;
    [Test] procedure ModernMeta_Ping_IsMethodNotFound;
    [Test] procedure ModernMeta_Ping_LenientSetting_Allows;
    [Test] procedure ModernMeta_LegacyOnlyMethods_AreNotFound;
    [Test] procedure ModernOnlyMethod_WithoutMeta_IsInvalidParams;
    [Test] procedure Http_ModernHeader_WithoutMeta_IsInvalidParams;
    [Test] procedure Http_UnknownHeaderVersion_IsInvalidRequest;
    [Test] procedure Http_LegacyHeader_IsLegacyWithHeaderVersion;
    [Test] procedure Http_NoHeader_NoMeta_IsLegacy;
    [Test] procedure Stdio_SessionVersion_IsUsedForLegacyRequests;
    [Test] procedure Stdio_NoSessionVersion_IsLatestLegacy;
    [Test] procedure LegacyMeta_WithProgressTokenOnly_IsLegacy;
    [Test] procedure Meta_NotAnObject_IsInvalidParams;
    [Test] procedure ClientCapabilities_AreReadable;
    [Test] procedure RequireClientCapability_RaisesMissingCapability;
  end;

implementation

uses
  System.SysUtils,
  MCPServer.Errors;

const
  META_MODERN = '"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",'
    + '"io.modelcontextprotocol/clientCapabilities":{"elicitation":{"form":{}}},'
    + '"io.modelcontextprotocol/clientInfo":{"name":"ctx-client","version":"2.0"},'
    + '"io.modelcontextprotocol/logLevel":"info"}';

function Request(const Method: string; const ParamsJson: string = ''): string;
begin
  if ParamsJson = '' then
    Result := Format('{"jsonrpc":"2.0","id":1,"method":"%s"}', [Method])
  else
    Result := Format('{"jsonrpc":"2.0","id":1,"method":"%s","params":%s}', [Method, ParamsJson]);
end;

{ TRequestContextTests }

procedure TRequestContextTests.Setup;
begin
  FHarness := TMCPTestHarness.Create;
  FSettings := FHarness.Settings;
  FProcessor := TMCPJsonRpcProcessor.Create(FHarness.ManagerRegistry, FSettings);
  FSession := TMCPLegacySession.Create;
end;

procedure TRequestContextTests.TearDown;
begin
  FSession.Free;
  FProcessor.Free;
  FHarness.Free;
end;

function TRequestContextTests.Build(const RequestJson: string; const Hints: TMCPTransportHints): IMCPRequestContext;
begin
  var Message := TJSONObject.ParseJSONValue(RequestJson) as TJSONObject;
  try
    var Method := Message.GetValue('method').Value;
    var Params := Message.GetValue('params') as TJSONObject;
    var RequestId := TMCPRequestId.FromJson(Message.GetValue('id'));
    Result := FProcessor.BuildRequestContext(Method, Params, RequestId, Hints);
  finally
    Message.Free;
  end;
end;

procedure TRequestContextTests.ExpectError(const RequestJson: string; const Hints: TMCPTransportHints;
  ExpectedCode, ExpectedStatus: Integer; const Because: string);
begin
  try
    Build(RequestJson, Hints);
    Assert.Fail('expected EMCPError ' + ExpectedCode.ToString + ': ' + Because);
  except
    on E: EMCPError do
    begin
      Assert.AreEqual(ExpectedCode, E.Code, Because + ' (code)');
      Assert.AreEqual(ExpectedStatus, E.HttpStatus, Because + ' (http status)');
    end;
  end;
end;

procedure TRequestContextTests.Initialize_IsLegacy_EvenWithModernMeta;
begin
  var Context := Build(Request('initialize', '{"protocolVersion":"2025-11-25",' + META_MODERN + '}'), TMCPTransportHints.None);

  Assert.AreEqual(TMCPProtocolEra.Legacy, Context.Era);
  Assert.AreEqual('2025-11-25', Context.ProtocolVersion);
end;

procedure TRequestContextTests.Initialize_EchoesServedRevision;
begin
  Assert.AreEqual('2025-06-18', Build(Request('initialize', '{"protocolVersion":"2025-06-18"}'), TMCPTransportHints.None).ProtocolVersion);
  Assert.AreEqual('2025-11-25', Build(Request('initialize', '{"protocolVersion":"2025-11-25"}'), TMCPTransportHints.None).ProtocolVersion);
end;

procedure TRequestContextTests.Initialize_UnknownRevision_AnswersLatestLegacy;
begin
  Assert.AreEqual('2025-11-25', Build(Request('initialize', '{"protocolVersion":"2025-03-26"}'), TMCPTransportHints.None).ProtocolVersion);
  Assert.AreEqual('2025-11-25', Build(Request('initialize', '{"protocolVersion":"1900-01-01"}'), TMCPTransportHints.None).ProtocolVersion);
  Assert.AreEqual('2025-11-25', Build(Request('initialize'), TMCPTransportHints.None).ProtocolVersion);
end;

procedure TRequestContextTests.ModernMeta_IsModern;
begin
  var Context := Build(Request('tools/list', '{' + META_MODERN + '}'), TMCPTransportHints.None);

  Assert.AreEqual(TMCPProtocolEra.Modern, Context.Era);
  Assert.AreEqual('2026-07-28', Context.ProtocolVersion);
  Assert.AreEqual('tools/list', Context.Method);
  Assert.IsNotNull(Context.ClientCapabilities);
  Assert.AreEqual('ctx-client', Context.ClientInfo.GetValue('name').Value);
  Assert.AreEqual('info', Context.LogLevel);
end;

procedure TRequestContextTests.ModernMeta_Http_HeaderMissing_IsHeaderMismatch;
begin
  ExpectError(Request('tools/list', '{' + META_MODERN + '}'), TMCPTransportHints.ForHttp(False, ''),
    MCP_ERROR_HEADER_MISMATCH, 400, 'modern body without MCP-Protocol-Version header');
end;

procedure TRequestContextTests.ModernMeta_Http_HeaderDiffers_IsHeaderMismatch;
begin
  ExpectError(Request('tools/list', '{' + META_MODERN + '}'), TMCPTransportHints.ForHttp(True, '2025-11-25'),
    MCP_ERROR_HEADER_MISMATCH, 400, 'header differs from _meta');
end;

procedure TRequestContextTests.ModernMeta_Http_HeaderMatches_IsModern;
begin
  var Context := Build(Request('tools/list', '{' + META_MODERN + '}'), TMCPTransportHints.ForHttp(True, '2026-07-28'));
  Assert.AreEqual(TMCPProtocolEra.Modern, Context.Era);
end;

procedure TRequestContextTests.ModernMeta_UnknownVersion_ListsSupported;
begin
  var Body := Request('tools/list', '{"_meta":{"io.modelcontextprotocol/protocolVersion":"1900-01-01","io.modelcontextprotocol/clientCapabilities":{}}}');
  try
    Build(Body, TMCPTransportHints.None);
    Assert.Fail('expected unsupported version');
  except
    on E: EMCPError do
    begin
      Assert.AreEqual(MCP_ERROR_UNSUPPORTED_PROTOCOL_VERSION, E.Code);
      Assert.AreEqual(400, E.HttpStatus);
      var Data := E.Data as TJSONObject;
      Assert.AreEqual('1900-01-01', Data.GetValue('requested').Value);
      var Supported := Data.GetValue('supported') as TJSONArray;
      Assert.AreEqual(1, Supported.Count);
      Assert.AreEqual('2026-07-28', Supported.Items[0].Value);
    end;
  end;
end;

procedure TRequestContextTests.ModernMeta_MissingClientCapabilities_IsInvalidParams;
begin
  ExpectError(Request('tools/list', '{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}'),
    TMCPTransportHints.None, JSONRPC_INVALID_PARAMS, 400, 'clientCapabilities is required');
  ExpectError(Request('tools/list', '{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":"yes"}}'),
    TMCPTransportHints.None, JSONRPC_INVALID_PARAMS, 400, 'clientCapabilities must be an object');
end;

procedure TRequestContextTests.ModernMeta_ClientInfoNotObject_IsInvalidParams;
begin
  ExpectError(Request('tools/list', '{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{},"io.modelcontextprotocol/clientInfo":"me"}}'),
    TMCPTransportHints.None, JSONRPC_INVALID_PARAMS, 400, 'clientInfo must be an object');
end;

procedure TRequestContextTests.ModernMeta_InvalidLogLevel_IsInvalidParams;
begin
  ExpectError(Request('tools/list', '{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{},"io.modelcontextprotocol/logLevel":"loud"}}'),
    TMCPTransportHints.None, JSONRPC_INVALID_PARAMS, 400, 'logLevel outside the LoggingLevel set');
end;

procedure TRequestContextTests.ModernMeta_Ping_IsMethodNotFound;
begin
  ExpectError(Request('ping', '{' + META_MODERN + '}'), TMCPTransportHints.None,
    JSONRPC_METHOD_NOT_FOUND, 404, 'ping was removed in 2026-07-28');
end;

procedure TRequestContextTests.ModernMeta_Ping_LenientSetting_Allows;
begin
  FSettings.LenientModernPing := True;
  var Context := Build(Request('ping', '{' + META_MODERN + '}'), TMCPTransportHints.None);
  Assert.AreEqual(TMCPProtocolEra.Modern, Context.Era);
end;

procedure TRequestContextTests.ModernMeta_LegacyOnlyMethods_AreNotFound;
begin
  for var Method in ['logging/setLevel', 'resources/subscribe', 'resources/unsubscribe'] do
    ExpectError(Request(Method, '{' + META_MODERN + '}'), TMCPTransportHints.None,
      JSONRPC_METHOD_NOT_FOUND, 404, Method + ' is legacy-only');
end;

procedure TRequestContextTests.ModernOnlyMethod_WithoutMeta_IsInvalidParams;
begin
  ExpectError(Request('server/discover'), TMCPTransportHints.None,
    JSONRPC_INVALID_PARAMS, 400, 'server/discover needs _meta');
  ExpectError(Request('subscriptions/listen', '{"subscriptions":[]}'), TMCPTransportHints.None,
    JSONRPC_INVALID_PARAMS, 400, 'subscriptions/listen needs _meta');
end;

procedure TRequestContextTests.Http_ModernHeader_WithoutMeta_IsInvalidParams;
begin
  ExpectError(Request('tools/list'), TMCPTransportHints.ForHttp(True, '2026-07-28'),
    JSONRPC_INVALID_PARAMS, 400, 'modern header names a revision the body does not carry');
end;

procedure TRequestContextTests.Http_UnknownHeaderVersion_IsInvalidRequest;
begin
  ExpectError(Request('tools/list'), TMCPTransportHints.ForHttp(True, '1900-01-01'),
    JSONRPC_INVALID_REQUEST, 400, 'header version in neither set');
end;

procedure TRequestContextTests.Http_LegacyHeader_IsLegacyWithHeaderVersion;
begin
  var Context := Build(Request('tools/list'), TMCPTransportHints.ForHttp(True, '2025-06-18'));
  Assert.AreEqual(TMCPProtocolEra.Legacy, Context.Era);
  Assert.AreEqual('2025-06-18', Context.ProtocolVersion);

  Context := Build(Request('tools/list'), TMCPTransportHints.ForHttp(True, '2025-03-26'));
  Assert.AreEqual(TMCPProtocolEra.Legacy, Context.Era);
end;

procedure TRequestContextTests.Http_NoHeader_NoMeta_IsLegacy;
begin
  var Context := Build(Request('tools/list'), TMCPTransportHints.ForHttp(False, ''));
  Assert.AreEqual(TMCPProtocolEra.Legacy, Context.Era);
  Assert.AreEqual('2025-11-25', Context.ProtocolVersion);
end;

procedure TRequestContextTests.Stdio_SessionVersion_IsUsedForLegacyRequests;
begin
  FSession.ProtocolVersion := '2025-06-18';
  var Context := Build(Request('tools/list'), TMCPTransportHints.ForStdio(FSession));
  Assert.AreEqual(TMCPProtocolEra.Legacy, Context.Era);
  Assert.AreEqual('2025-06-18', Context.ProtocolVersion);
  Assert.AreSame(FSession, Context.LegacySession);
end;

procedure TRequestContextTests.Stdio_NoSessionVersion_IsLatestLegacy;
begin
  var Context := Build(Request('tools/list'), TMCPTransportHints.ForStdio(FSession));
  Assert.AreEqual('2025-11-25', Context.ProtocolVersion);
end;

procedure TRequestContextTests.LegacyMeta_WithProgressTokenOnly_IsLegacy;
begin
  var Context := Build(Request('tools/call', '{"name":"echo","arguments":{},"_meta":{"progressToken":"p1"}}'), TMCPTransportHints.None);
  Assert.AreEqual(TMCPProtocolEra.Legacy, Context.Era);
  Assert.AreEqual('p1', Context.ProgressToken.Value);
  Assert.IsNull(Context.ClientCapabilities);
end;

procedure TRequestContextTests.Meta_NotAnObject_IsInvalidParams;
begin
  ExpectError(Request('tools/list', '{"_meta":5}'), TMCPTransportHints.None,
    JSONRPC_INVALID_PARAMS, 400, '_meta must be an object');
end;

procedure TRequestContextTests.ClientCapabilities_AreReadable;
begin
  var Context := Build(Request('tools/list', '{' + META_MODERN + '}'), TMCPTransportHints.None);

  Assert.IsTrue(Context.HasClientCapability('elicitation'));
  Assert.IsTrue(Context.HasClientCapability('elicitation.form'));
  Assert.IsFalse(Context.HasClientCapability('elicitation.url'));
  Assert.IsFalse(Context.HasClientCapability('sampling'));
end;

procedure TRequestContextTests.RequireClientCapability_RaisesMissingCapability;
begin
  var Context := Build(Request('tools/list', '{' + META_MODERN + '}'), TMCPTransportHints.None);
  try
    Context.RequireClientCapability('sampling.tools');
    Assert.Fail('expected -32021');
  except
    on E: EMCPError do
    begin
      Assert.AreEqual(MCP_ERROR_MISSING_REQUIRED_CLIENT_CAPABILITY, E.Code);
      Assert.AreEqual(400, E.HttpStatus);
      var Required := (E.Data as TJSONObject).GetValue('requiredCapabilities') as TJSONObject;
      Assert.IsNotNull((Required.GetValue('sampling') as TJSONObject).GetValue('tools'));
    end;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TRequestContextTests);

end.
