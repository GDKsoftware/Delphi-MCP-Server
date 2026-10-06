unit MCPServer.Tests.Extensions;

interface

uses
  DUnitX.TestFramework,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tests.Harness;

type
  [TestFixture]
  TExtensionsTests = class
  private
    FHarness: TMCPTestHarness;
    procedure RegisterExtension(const ExtensionId: string);
    function Call(const Method, ClientCapabilities: string): TJSONObject;
    function DiscoveredExtensions(const Response: TJSONObject): TJSONObject;

  public
    [Setup]
    procedure Setup;

    [TearDown]
    procedure TearDown;

    [Test]
    [TestCase('Official', 'io.modelcontextprotocol/tasks,True')]
    [TestCase('ThirdParty', 'com.example/my-extension,True')]
    [TestCase('DottedName', 'com.example/v2.tasks_x,True')]
    [TestCase('NoPrefix', 'tasks,False')]
    [TestCase('EmptyName', 'com.example/,False')]
    [TestCase('LabelStartsWithDigit', '1example/tasks,False')]
    [TestCase('LabelEndsWithHyphen', 'com.example-/tasks,False')]
    [TestCase('NameEndsWithUnderscore', 'com.example/tasks_,False')]
    procedure IsValidId_Various_ReturnsExpected(const ExtensionId: string; const Expected: Boolean);

    [Test]
    procedure Discover_WithExtensionProvider_AdvertisesExtension;

    [Test]
    procedure Discover_WithoutExtensionProvider_OmitsExtensions;

    [Test]
    procedure Build_LegacyEra_OmitsExtensions;

    [Test]
    procedure Build_InvalidExtensionId_RaisesConfigurationError;

    [Test]
    procedure Build_DuplicateExtensionId_RaisesConfigurationError;

    [Test]
    procedure ExtensionResultType_ClientDeclaresExtension_IsReturned;

    [Test]
    procedure ExtensionResultType_ClientOmitsExtension_IsInternalError;

    [Test]
    procedure UnownedResultType_IsInternalError;

    [Test]
    procedure RequireClientExtension_ClientOmitsExtension_IsMissingCapability;

    [Test]
    procedure RequireClientExtension_ClientDeclaresExtension_Succeeds;
  end;

implementation

uses
  System.SysUtils,
  System.Rtti,
  MCPServer.Errors,
  MCPServer.Capabilities,
  MCPServer.Extensions,
  MCPServer.Tests.Support;

const
  TEST_EXTENSION_ID = 'com.example/test';
  TEST_RESULT_TYPE = 'test_result';
  UNOWNED_RESULT_TYPE = 'unowned_result';
  METHOD_EXTENSION_RESULT = 'test/extension-result';
  METHOD_UNOWNED_RESULT = 'test/unowned-result';
  METHOD_REQUIRE_EXTENSION = 'test/require-extension';
  CAPABILITIES_NONE = '{}';
  CAPABILITIES_WITH_EXTENSION = '{"extensions":{"com.example/test":{}}}';
  TEST_CAPABILITY_NAME = 'test';
  TEST_SETTING_NAME = 'mode';
  TEST_SETTING_VALUE = 'fake';
  PATH_RESULT_TYPE = 'result.resultType';
  PATH_ERROR_CODE = 'error.code';

type
  TFakeExtensionManager = class(TInterfacedObject, IMCPCapabilityManager, IMCPCapabilityManagerEx,
    IMCPExtensionProvider)
  private
    FExtensionId: string;
    function ResultOfType(const ResultType: string): TValue;

  public
    constructor Create(const ExtensionId: string);

    function GetCapabilityName: string;
    function HandlesMethod(const Method: string): Boolean;
    function ExecuteMethod(const Method: string; const Params: TJSONObject): TValue;
    function ExecuteMethodWithContext(const Method: string; const Params: TJSONObject;
      const Context: IMCPRequestContext): TValue;
    function GetExtensionId: string;
    function GetExtensionSettings: TJSONObject;
    function GetResultTypes: TArray<string>;
  end;

{ TFakeExtensionManager }

constructor TFakeExtensionManager.Create(const ExtensionId: string);
begin
  inherited Create;
  FExtensionId := ExtensionId;
end;

function TFakeExtensionManager.GetCapabilityName: string;
begin
  Result := TEST_CAPABILITY_NAME;
end;

function TFakeExtensionManager.HandlesMethod(const Method: string): Boolean;
begin
  Result := ((Method = METHOD_EXTENSION_RESULT) or
             (Method = METHOD_UNOWNED_RESULT) or
             (Method = METHOD_REQUIRE_EXTENSION));
end;

function TFakeExtensionManager.ExecuteMethod(const Method: string; const Params: TJSONObject): TValue;
begin
  raise EMCPError.InternalError('The fake extension manager needs a request context');
end;

function TFakeExtensionManager.ExecuteMethodWithContext(const Method: string; const Params: TJSONObject;
  const Context: IMCPRequestContext): TValue;
begin
  const AnswersExtensionResult = (Method = METHOD_EXTENSION_RESULT);
  const AnswersUnownedResult = (Method = METHOD_UNOWNED_RESULT);
  if AnswersExtensionResult then
  begin
    Result := ResultOfType(TEST_RESULT_TYPE);
  end
  else if AnswersUnownedResult then
  begin
    Result := ResultOfType(UNOWNED_RESULT_TYPE);
  end
  else
  begin
    Context.RequireClientExtension(FExtensionId);
    const EmptyResult = TJSONObject.Create;
    Result := TValue.From<TJSONObject>(EmptyResult);
  end;
end;

function TFakeExtensionManager.ResultOfType(const ResultType: string): TValue;
begin
  const ResultObject = TJSONObject.Create;
  ResultObject.AddPair(MCP_KEY_RESULT_TYPE, ResultType);
  Result := TValue.From<TJSONObject>(ResultObject);
end;

function TFakeExtensionManager.GetExtensionId: string;
begin
  Result := FExtensionId;
end;

function TFakeExtensionManager.GetExtensionSettings: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair(TEST_SETTING_NAME, TEST_SETTING_VALUE);
end;

function TFakeExtensionManager.GetResultTypes: TArray<string>;
begin
  Result := [TEST_RESULT_TYPE];
end;

{ TExtensionsTests }

procedure TExtensionsTests.Setup;
begin
  FHarness := TMCPTestHarness.Create;
end;

procedure TExtensionsTests.TearDown;
begin
  FHarness.Free;
end;

procedure TExtensionsTests.RegisterExtension(const ExtensionId: string);
begin
  FHarness.ManagerRegistry.RegisterManager(TFakeExtensionManager.Create(ExtensionId));
end;

function TExtensionsTests.Call(const Method, ClientCapabilities: string): TJSONObject;
begin
  const Body = Format('{"jsonrpc":"2.0","id":1,"method":"%s","params":{"_meta":{' +
    '"io.modelcontextprotocol/protocolVersion":"2026-07-28",' +
    '"io.modelcontextprotocol/clientCapabilities":%s}}}', [Method, ClientCapabilities]);
  Result := TMCPTestJson.ParseObject(FHarness.Process(Body));
end;

function TExtensionsTests.DiscoveredExtensions(const Response: TJSONObject): TJSONObject;
begin
  const Capabilities = Response.GetValue<TJSONObject>('result.capabilities');
  Result := Capabilities.GetValue(MCP_KEY_EXTENSIONS) as TJSONObject;
end;

procedure TExtensionsTests.IsValidId_Various_ReturnsExpected(const ExtensionId: string; const Expected: Boolean);
begin
  const Actual = TMCPExtensions.IsValidId(ExtensionId);

  Assert.AreEqual(Expected, Actual);
end;

procedure TExtensionsTests.Discover_WithExtensionProvider_AdvertisesExtension;
begin
  RegisterExtension(TEST_EXTENSION_ID);

  const Response = Call(MCP_METHOD_SERVER_DISCOVER, CAPABILITIES_NONE);
  try
    const Extensions = DiscoveredExtensions(Response);

    Assert.IsNotNull(Extensions);
    Assert.AreEqual(1, Extensions.Count);
    const Settings = Extensions.GetValue(TEST_EXTENSION_ID) as TJSONObject;
    Assert.IsNotNull(Settings);
    Assert.AreEqual(TEST_SETTING_VALUE, Settings.GetValue<string>(TEST_SETTING_NAME));
  finally
    Response.Free;
  end;
end;

procedure TExtensionsTests.Discover_WithoutExtensionProvider_OmitsExtensions;
begin
  const Response = Call(MCP_METHOD_SERVER_DISCOVER, CAPABILITIES_NONE);
  try
    const Extensions = DiscoveredExtensions(Response);

    Assert.IsNull(Extensions);
  finally
    Response.Free;
  end;
end;

procedure TExtensionsTests.Build_LegacyEra_OmitsExtensions;
begin
  RegisterExtension(TEST_EXTENSION_ID);

  const Capabilities = TMCPCapabilityBuilder.Build(FHarness.ManagerRegistry, TMCPProtocolEra.Legacy);
  try
    const Extensions = Capabilities.GetValue(MCP_KEY_EXTENSIONS);

    Assert.IsNull(Extensions);
  finally
    Capabilities.Free;
  end;
end;

procedure TExtensionsTests.Build_InvalidExtensionId_RaisesConfigurationError;
begin
  RegisterExtension('tasks');

  Assert.WillRaise(
    procedure
    begin
      const Capabilities = TMCPCapabilityBuilder.Build(FHarness.ManagerRegistry, TMCPProtocolEra.Modern);
      Capabilities.Free;
    end,
    EMCPConfigurationError);
end;

procedure TExtensionsTests.Build_DuplicateExtensionId_RaisesConfigurationError;
begin
  RegisterExtension(TEST_EXTENSION_ID);
  RegisterExtension(TEST_EXTENSION_ID);

  Assert.WillRaise(
    procedure
    begin
      const Capabilities = TMCPCapabilityBuilder.Build(FHarness.ManagerRegistry, TMCPProtocolEra.Modern);
      Capabilities.Free;
    end,
    EMCPConfigurationError);
end;

procedure TExtensionsTests.ExtensionResultType_ClientDeclaresExtension_IsReturned;
begin
  RegisterExtension(TEST_EXTENSION_ID);

  const Response = Call(METHOD_EXTENSION_RESULT, CAPABILITIES_WITH_EXTENSION);
  try
    const ResultType = Response.GetValue<string>(PATH_RESULT_TYPE);

    Assert.AreEqual(TEST_RESULT_TYPE, ResultType);
  finally
    Response.Free;
  end;
end;

procedure TExtensionsTests.ExtensionResultType_ClientOmitsExtension_IsInternalError;
begin
  RegisterExtension(TEST_EXTENSION_ID);

  const Response = Call(METHOD_EXTENSION_RESULT, CAPABILITIES_NONE);
  try
    const Code = Response.GetValue<Integer>(PATH_ERROR_CODE);

    Assert.AreEqual(JSONRPC_INTERNAL_ERROR, Code);
  finally
    Response.Free;
  end;
end;

procedure TExtensionsTests.UnownedResultType_IsInternalError;
begin
  RegisterExtension(TEST_EXTENSION_ID);

  const Response = Call(METHOD_UNOWNED_RESULT, CAPABILITIES_WITH_EXTENSION);
  try
    const Code = Response.GetValue<Integer>(PATH_ERROR_CODE);

    Assert.AreEqual(JSONRPC_INTERNAL_ERROR, Code);
  finally
    Response.Free;
  end;
end;

procedure TExtensionsTests.RequireClientExtension_ClientOmitsExtension_IsMissingCapability;
begin
  RegisterExtension(TEST_EXTENSION_ID);

  const Response = Call(METHOD_REQUIRE_EXTENSION, CAPABILITIES_NONE);
  try
    const Code = Response.GetValue<Integer>(PATH_ERROR_CODE);
    const Required = Response.GetValue<TJSONObject>('error.data.requiredCapabilities.extensions');

    const Settings = Required.GetValue(TEST_EXTENSION_ID);
    Assert.AreEqual(MCP_ERROR_MISSING_REQUIRED_CLIENT_CAPABILITY, Code);
    Assert.IsTrue(Settings is TJSONObject);
  finally
    Response.Free;
  end;
end;

procedure TExtensionsTests.RequireClientExtension_ClientDeclaresExtension_Succeeds;
begin
  RegisterExtension(TEST_EXTENSION_ID);

  const Response = Call(METHOD_REQUIRE_EXTENSION, CAPABILITIES_WITH_EXTENSION);
  try
    const ResultType = Response.GetValue<string>(PATH_RESULT_TYPE);

    Assert.AreEqual('complete', ResultType);
  finally
    Response.Free;
  end;
end;

end.
