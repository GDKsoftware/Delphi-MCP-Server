unit MCPServer.Tests.ToolsManager;

interface

uses
  DUnitX.TestFramework,
  System.Rtti,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Base,
  MCPServer.ToolsManager;

type
  TStructuredParams = class
  private
    FValue: Integer;
  public
    property Value: Integer read FValue write FValue;
  end;

  TStructuredOutput = class
  private
    FDoubled: Integer;
  public
    property Doubled: Integer read FDoubled write FDoubled;
  end;

  TDoublingTool = class(TMCPToolBase<TStructuredParams, TStructuredOutput>)
  protected
    function ExecuteWithParams(const Params: TStructuredParams): TStructuredOutput; override;
  public
    constructor Create; override;
  end;

  THandWrittenTool = class(TMCPToolBase)
  protected
    function BuildSchema: TJSONObject; override;
    function DoExecute(const Arguments: TJSONObject): TValue; override;
  public
    constructor Create; override;
  end;

  TReadOnlyTool = class(THandWrittenTool)
  public
    constructor Create; override;
  end;

  TProbeTool = class(TMCPToolBase)
  protected
    function BuildSchema: TJSONObject; override;
    function DoExecute(const Arguments: TJSONObject): TValue; override;
  public
    constructor CreateNamed(const AName: string);
  end;

  [TestFixture]
  TToolsManagerTests = class
  private
    FManager: TMCPToolsManager;
    function Call(const ParamsJson: string; Era: TMCPProtocolEra): TJSONObject;
    procedure ExpectError(const ParamsJson: string; Era: TMCPProtocolEra; ExpectedCode: Integer);
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    [Test]
    procedure UnknownTool_IsInvalidParams_WithName;

    [Test]
    procedure MissingName_IsInvalidParams;

    [Test]
    procedure ArgumentsNotObject_IsInvalidParams;

    [Test]
    procedure MissingRequiredArgument_IsErrorResult;

    [Test]
    procedure WrongArgumentType_IsErrorResult;

    [Test]
    procedure UnknownArgument_IsErrorResult;

    [Test]
    procedure ToolError_IsErrorResult;

    [Test]
    procedure ContentBlocks_FromToolResult;

    [Test]
    procedure StructuredResult_HasTextFallback;

    [Test]
    procedure List_IsInRegistrationOrder_WithAnnotations;

    [Test]
    procedure MarkReadOnly_SetsBothHints_Once;

    [Test]
    procedure List_CacheHints_ModernOnly;

    [Test]
    procedure List_Cursor_IsInvalidParams;

    [Test]
    procedure HandWrittenTool_ValidArguments_Runs;

    [Test]
    procedure HandWrittenTool_MissingRequired_IsErrorResult;

    [Test]
    procedure HandWrittenTool_WrongType_IsErrorResult;
  end;

  [TestFixture]
  TToolsManagerIsolationTests = class
  private
    function ToolNames(const Manager: TMCPToolsManager): TArray<string>;
    function NewManagerWith(const SeedFromRegistry: Boolean; const ToolName: string): TMCPToolsManager;
    function FirstRegisteredToolName: string;
  public
    [Test]
    procedure Registry_HasAtLeastOneTool;

    [Test]
    procedure NoSeed_PublishesNoRegistryTool;

    [Test]
    procedure NoSeed_ListsOnlyItsOwnTool;

    [Test]
    procedure NoSeed_TwoManagersDoNotShareTools;

    [Test]
    procedure NoSeed_CallingARegistryTool_IsInvalidParams;

    [Test]
    procedure NoSeed_RunsItsOwnTool;

    [Test]
    procedure Parameterless_SeedsFromRegistry;

    [Test]
    procedure SeedTrue_MatchesTheParameterlessConstructor;
  end;

implementation

uses
  System.SysUtils,
  MCPServer.Errors,
  MCPServer.Registration,
  System.Generics.Collections;

const
  PROBE_FIRST = 'probe_first';
  PROBE_SECOND = 'probe_second';

{ TDoublingTool }

constructor TDoublingTool.Create;
begin
  inherited;
  FName := 'doubling';
  FDescription := 'Doubles a number';
end;

function TDoublingTool.ExecuteWithParams(const Params: TStructuredParams): TStructuredOutput;
begin
  Result := TStructuredOutput.Create;
  Result.Doubled := Params.Value * 2;
end;

{ THandWrittenTool }

constructor THandWrittenTool.Create;
begin
  inherited;
  FName := 'hand_written';
  FDescription := 'A tool with a hand-written schema';
end;

{ TReadOnlyTool }

constructor TReadOnlyTool.Create;
begin
  inherited;
  FName := 'read_only';
  MarkReadOnly(True);
  MarkReadOnly(True);
end;

function THandWrittenTool.BuildSchema: TJSONObject;
begin
  Result := TJSONObject.ParseJSONValue(
    '{"type":"object","required":["count"],"properties":{"count":{"type":"integer"}}}') as TJSONObject;
end;

function THandWrittenTool.DoExecute(const Arguments: TJSONObject): TValue;
begin
  Result := TValue.From<string>('count was ' + Arguments.GetValue<Integer>('count').ToString);
end;

{ TToolsManagerTests }

procedure TToolsManagerTests.Setup;
begin
  FManager := TMCPToolsManager.Create;
  FManager.AddTool(TDoublingTool.Create);
  FManager.AddTool(THandWrittenTool.Create);
end;

procedure TToolsManagerTests.TearDown;
begin
  FManager.Free;
end;

function TToolsManagerTests.Call(const ParamsJson: string; Era: TMCPProtocolEra): TJSONObject;
begin
  var Params := TJSONObject.ParseJSONValue(ParamsJson) as TJSONObject;
  try
    Result := FManager.CallTool(Params, Era).AsType<TJSONObject>;
  finally
    Params.Free;
  end;
end;

procedure TToolsManagerTests.ExpectError(const ParamsJson: string; Era: TMCPProtocolEra; ExpectedCode: Integer);
begin
  try
    Call(ParamsJson, Era).Free;
    Assert.Fail('expected EMCPError ' + ExpectedCode.ToString + ' for ' + ParamsJson);
  except
    on E: EMCPError do
      Assert.AreEqual(ExpectedCode, E.Code, E.Message);
  end;
end;

procedure TToolsManagerTests.UnknownTool_IsInvalidParams_WithName;
begin
  for var Era in [TMCPProtocolEra.Legacy, TMCPProtocolEra.Modern] do
    try
      Call('{"name":"nope","arguments":{}}', Era).Free;
      Assert.Fail('expected -32602');
    except
      on E: EMCPError do
      begin
        Assert.AreEqual(JSONRPC_INVALID_PARAMS, E.Code);
        Assert.AreEqual('nope', (E.Data as TJSONObject).GetValue<string>('name'));
      end;
    end;
end;

procedure TToolsManagerTests.MissingName_IsInvalidParams;
begin
  ExpectError('{}', TMCPProtocolEra.Legacy, JSONRPC_INVALID_PARAMS);
  ExpectError('{"name":""}', TMCPProtocolEra.Modern, JSONRPC_INVALID_PARAMS);
  ExpectError('{"name":5}', TMCPProtocolEra.Modern, JSONRPC_INVALID_PARAMS);
end;

procedure TToolsManagerTests.ArgumentsNotObject_IsInvalidParams;
begin
  ExpectError('{"name":"echo","arguments":[1]}', TMCPProtocolEra.Modern, JSONRPC_INVALID_PARAMS);
end;

procedure TToolsManagerTests.MissingRequiredArgument_IsErrorResult;
begin
  var Json := Call('{"name":"echo"}', TMCPProtocolEra.Modern);
  try
    Assert.IsTrue(Json.GetValue<Boolean>('isError'));
    Assert.IsTrue(Json.GetValue<string>('content[0].text').Contains('Missing required parameter "message"'));
  finally
    Json.Free;
  end;
end;

procedure TToolsManagerTests.WrongArgumentType_IsErrorResult;
begin
  var Json := Call('{"name":"calculate","arguments":{"operation":"add","a":"two","b":3}}', TMCPProtocolEra.Legacy);
  try
    Assert.IsTrue(Json.GetValue<Boolean>('isError'));
    Assert.IsTrue(Json.GetValue<string>('content[0].text').Contains('Parameter "a": expected a number'));
  finally
    Json.Free;
  end;
end;

procedure TToolsManagerTests.UnknownArgument_IsErrorResult;
begin
  var Json := Call('{"name":"echo","arguments":{"message":"hi","extra":1}}', TMCPProtocolEra.Legacy);
  try
    Assert.IsTrue(Json.GetValue<Boolean>('isError'));
    Assert.IsTrue(Json.GetValue<string>('content[0].text').Contains('Unknown parameter "extra"'));
  finally
    Json.Free;
  end;
end;

procedure TToolsManagerTests.ToolError_IsErrorResult;
begin
  var Json := Call('{"name":"test_error_handling","arguments":{}}', TMCPProtocolEra.Modern);
  try
    Assert.IsTrue(Json.GetValue<Boolean>('isError'));
    Assert.IsTrue(Json.GetValue<string>('content[0].text').Contains('always fails'));
  finally
    Json.Free;
  end;
end;

procedure TToolsManagerTests.ContentBlocks_FromToolResult;
begin
  var Json := Call('{"name":"test_multiple_content_types","arguments":{}}', TMCPProtocolEra.Modern);
  try
    Assert.AreEqual(3, (Json.GetValue('content') as TJSONArray).Count);
    Assert.AreEqual('text', Json.GetValue<string>('content[0].type'));
    Assert.AreEqual('image', Json.GetValue<string>('content[1].type'));
    Assert.AreEqual('resource', Json.GetValue<string>('content[2].type'));
    Assert.IsNull(Json.GetValue('isError'));
  finally
    Json.Free;
  end;
end;

procedure TToolsManagerTests.StructuredResult_HasTextFallback;
begin
  var Json := Call('{"name":"doubling","arguments":{"value":21}}', TMCPProtocolEra.Legacy);
  try
    Assert.AreEqual(42, Json.GetValue<Integer>('structuredContent.doubled'));
    Assert.AreEqual('{"doubled":42}', Json.GetValue<string>('content[0].text'));
  finally
    Json.Free;
  end;
end;

procedure TToolsManagerTests.List_IsInRegistrationOrder_WithAnnotations;
begin
  var Json := FManager.ListTools(nil, TMCPProtocolEra.Legacy).AsType<TJSONObject>;
  try
    var Tools := Json.GetValue('tools') as TJSONArray;
    Assert.AreEqual('echo', Json.GetValue<string>('tools[0].name'), 'registration order starts with echo');
    Assert.AreEqual('hand_written', Tools.Items[Tools.Count - 1].GetValue<string>('name'),
      'the last-added tool comes last');
    Assert.AreEqual('doubling', Tools.Items[Tools.Count - 2].GetValue<string>('name'));
    var ReadOnly := False;
    for var Tool in Tools do
      if Tool.GetValue<string>('name') = 'test_simple_text' then
        ReadOnly := Tool.GetValue<Boolean>('annotations.readOnlyHint');
    Assert.IsTrue(ReadOnly);
    Assert.AreEqual('integer',
      Json.GetValue<string>('tools[' + (Tools.Count - 2).ToString + '].inputSchema.properties.value.type'));
  finally
    Json.Free;
  end;
end;

procedure TToolsManagerTests.MarkReadOnly_SetsBothHints_Once;
begin
  FManager.AddTool(TReadOnlyTool.Create);
  var Json := FManager.ListTools(nil, TMCPProtocolEra.Legacy).AsType<TJSONObject>;
  try
    const Tools = Json.GetValue('tools') as TJSONArray;
    var Annotations: TJSONObject := nil;
    for var Tool in Tools do
    begin
      const IsReadOnlyTool = (Tool.GetValue<string>('name') = 'read_only');
      if IsReadOnlyTool then
        Annotations := (Tool as TJSONObject).GetValue('annotations') as TJSONObject;
    end;

    Assert.IsNotNull(Annotations, 'the tool is listed with its annotations');
    Assert.IsTrue(Annotations.GetValue<Boolean>('readOnlyHint'), 'the tool reads only');
    Assert.IsTrue(Annotations.GetValue<Boolean>('openWorldHint'), 'the tool reaches outside the server');
    Assert.AreEqual(2, Annotations.Count, 'marking twice leaves one pair per hint');
  finally
    Json.Free;
  end;
end;

procedure TToolsManagerTests.List_CacheHints_ModernOnly;
begin
  FManager.ListTtlMs := 300000;
  FManager.ListCacheScope := MCP_CACHE_SCOPE_PUBLIC;

  var Legacy := FManager.ListTools(nil, TMCPProtocolEra.Legacy).AsType<TJSONObject>;
  var Modern := FManager.ListTools(nil, TMCPProtocolEra.Modern).AsType<TJSONObject>;
  try
    Assert.IsNull(Legacy.GetValue('ttlMs'));
    Assert.AreEqual(300000, Modern.GetValue<Integer>('ttlMs'));
    Assert.AreEqual('public', Modern.GetValue<string>('cacheScope'));
  finally
    Legacy.Free;
    Modern.Free;
  end;
end;

procedure TToolsManagerTests.List_Cursor_IsInvalidParams;
begin
  var Params := TJSONObject.ParseJSONValue('{"cursor":"abc"}') as TJSONObject;
  try
    try
      FManager.ListTools(Params, TMCPProtocolEra.Modern).AsType<TJSONObject>.Free;
      Assert.Fail('expected -32602');
    except
      on E: EMCPError do
        Assert.AreEqual(JSONRPC_INVALID_PARAMS, E.Code);
    end;
  finally
    Params.Free;
  end;
end;

procedure TToolsManagerTests.HandWrittenTool_ValidArguments_Runs;
begin
  var Json := Call('{"name":"hand_written","arguments":{"count":3}}', TMCPProtocolEra.Modern);
  try
    Assert.IsNull(Json.GetValue('isError'));
    Assert.AreEqual('count was 3', Json.GetValue<string>('content[0].text'));
  finally
    Json.Free;
  end;
end;

procedure TToolsManagerTests.HandWrittenTool_MissingRequired_IsErrorResult;
begin
  var Json := Call('{"name":"hand_written","arguments":{}}', TMCPProtocolEra.Modern);
  try
    Assert.IsTrue(Json.GetValue<Boolean>('isError'));
    Assert.IsTrue(Json.GetValue<string>('content[0].text').Contains('missing required property "count"'));
  finally
    Json.Free;
  end;
end;

procedure TToolsManagerTests.HandWrittenTool_WrongType_IsErrorResult;
begin
  var Json := Call('{"name":"hand_written","arguments":{"count":"three"}}', TMCPProtocolEra.Modern);
  try
    Assert.IsTrue(Json.GetValue<Boolean>('isError'));
    Assert.IsTrue(Json.GetValue<string>('content[0].text').Contains('expected integer'));
  finally
    Json.Free;
  end;
end;

{ TProbeTool }

constructor TProbeTool.CreateNamed(const AName: string);
begin
  inherited Create;
  FName := AName;
  FDescription := 'A probe tool handed to a single manager';
end;

function TProbeTool.BuildSchema: TJSONObject;
begin
  Result := TJSONObject.ParseJSONValue(
    '{"type":"object","properties":{},"additionalProperties":false}') as TJSONObject;
end;

function TProbeTool.DoExecute(const Arguments: TJSONObject): TValue;
begin
  Result := TValue.From<string>(FName + ' ran');
end;

{ TToolsManagerIsolationTests }

function TToolsManagerIsolationTests.ToolNames(const Manager: TMCPToolsManager): TArray<string>;
begin
  Result := nil;
  var Json := Manager.ListTools(nil, TMCPProtocolEra.Modern).AsType<TJSONObject>;
  try
    for var Tool in Json.GetValue('tools') as TJSONArray do
      Result := Result + [Tool.GetValue<string>('name')];
  finally
    Json.Free;
  end;
end;

function TToolsManagerIsolationTests.NewManagerWith(const SeedFromRegistry: Boolean;
  const ToolName: string): TMCPToolsManager;
begin
  Result := TMCPToolsManager.Create(SeedFromRegistry);
  Result.AddTool(TProbeTool.CreateNamed(ToolName));
end;

function TToolsManagerIsolationTests.FirstRegisteredToolName: string;
begin
  var Names := TMCPRegistry.GetToolNames;
  Assert.IsTrue(Length(Names) > 0, 'no tool is registered globally');
  Result := Names[0];
end;

procedure TToolsManagerIsolationTests.Registry_HasAtLeastOneTool;
begin
  Assert.IsTrue(Length(TMCPRegistry.GetToolNames) > 0,
    'the seeding tests only mean something while the registry holds a tool');
end;

procedure TToolsManagerIsolationTests.NoSeed_PublishesNoRegistryTool;
begin
  var Manager := TMCPToolsManager.Create(False);
  try
    for var ToolName in TMCPRegistry.GetToolNames do
      Assert.IsFalse(Manager.HasTool(ToolName), 'an unseeded manager must not publish ' + ToolName);
    Assert.AreEqual<NativeInt>(0, Length(ToolNames(Manager)), 'an unseeded manager starts empty');
  finally
    Manager.Free;
  end;
end;

procedure TToolsManagerIsolationTests.NoSeed_ListsOnlyItsOwnTool;
begin
  var Manager := NewManagerWith(False, PROBE_FIRST);
  try
    var Names := ToolNames(Manager);
    Assert.AreEqual<NativeInt>(1, Length(Names), 'only the added tool is listed');
    Assert.AreEqual(PROBE_FIRST, Names[0]);
  finally
    Manager.Free;
  end;
end;

procedure TToolsManagerIsolationTests.NoSeed_TwoManagersDoNotShareTools;
begin
  var First := NewManagerWith(False, PROBE_FIRST);
  try
    var Second := NewManagerWith(False, PROBE_SECOND);
    try
      Assert.IsTrue(First.HasTool(PROBE_FIRST));
      Assert.IsFalse(First.HasTool(PROBE_SECOND), 'the first manager sees only what it was given');
      Assert.IsTrue(Second.HasTool(PROBE_SECOND));
      Assert.IsFalse(Second.HasTool(PROBE_FIRST), 'the second manager sees only what it was given');
    finally
      Second.Free;
    end;
  finally
    First.Free;
  end;
end;

procedure TToolsManagerIsolationTests.NoSeed_CallingARegistryTool_IsInvalidParams;
begin
  var Manager := NewManagerWith(False, PROBE_FIRST);
  try
    var Params := TJSONObject.ParseJSONValue(
      '{"name":"' + FirstRegisteredToolName + '","arguments":{}}') as TJSONObject;
    try
      try
        Manager.CallTool(Params, TMCPProtocolEra.Modern).AsType<TJSONObject>.Free;
        Assert.Fail('a globally registered tool must not be callable on an unseeded manager');
      except
        on E: EMCPError do
          Assert.AreEqual(JSONRPC_INVALID_PARAMS, E.Code, E.Message);
      end;
    finally
      Params.Free;
    end;
  finally
    Manager.Free;
  end;
end;

procedure TToolsManagerIsolationTests.NoSeed_RunsItsOwnTool;
begin
  var Manager := NewManagerWith(False, PROBE_FIRST);
  try
    var Params := TJSONObject.ParseJSONValue(
      '{"name":"' + PROBE_FIRST + '","arguments":{}}') as TJSONObject;
    try
      var Json := Manager.CallTool(Params, TMCPProtocolEra.Modern).AsType<TJSONObject>;
      try
        Assert.IsNull(Json.GetValue('isError'));
        Assert.AreEqual(PROBE_FIRST + ' ran', Json.GetValue<string>('content[0].text'));
      finally
        Json.Free;
      end;
    finally
      Params.Free;
    end;
  finally
    Manager.Free;
  end;
end;

procedure TToolsManagerIsolationTests.Parameterless_SeedsFromRegistry;
begin
  var Manager := TMCPToolsManager.Create;
  try
    for var ToolName in TMCPRegistry.GetToolNames do
      Assert.IsTrue(Manager.HasTool(ToolName), 'the parameterless constructor still seeds ' + ToolName);
  finally
    Manager.Free;
  end;
end;

procedure TToolsManagerIsolationTests.SeedTrue_MatchesTheParameterlessConstructor;
begin
  var Seeded := TMCPToolsManager.Create(True);
  try
    var Parameterless := TMCPToolsManager.Create;
    try
      Assert.AreEqual(string.Join(',', ToolNames(Parameterless)), string.Join(',', ToolNames(Seeded)),
        'Create(True) and Create publish the same tools in the same order');
    finally
      Parameterless.Free;
    end;
  finally
    Seeded.Free;
  end;
end;

end.
