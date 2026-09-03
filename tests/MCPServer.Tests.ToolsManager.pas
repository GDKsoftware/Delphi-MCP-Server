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

  /// A typed tool: structured content plus the text fallback.
  TDoublingTool = class(TMCPToolBase<TStructuredParams, TStructuredOutput>)
  protected
    function ExecuteWithParams(const Params: TStructuredParams): TStructuredOutput; override;
  public
    constructor Create; override;
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

    [Test] procedure UnknownTool_IsInvalidParams_WithName;
    [Test] procedure MissingName_IsInvalidParams;
    [Test] procedure ArgumentsNotObject_IsInvalidParams;
    [Test] procedure MissingRequiredArgument_IsErrorResult;
    [Test] procedure WrongArgumentType_IsErrorResult;
    [Test] procedure UnknownArgument_IsErrorResult;
    [Test] procedure ToolError_IsErrorResult;
    [Test] procedure ContentBlocks_FromToolResult;
    [Test] procedure StructuredResult_HasTextFallback;
    [Test] procedure List_IsInRegistrationOrder_WithAnnotations;
    [Test] procedure List_CacheHints_ModernOnly;
    [Test] procedure List_Cursor_IsInvalidParams;
  end;

implementation

uses
  System.SysUtils,
  MCPServer.Errors;

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

{ TToolsManagerTests }

procedure TToolsManagerTests.Setup;
begin
  FManager := TMCPToolsManager.Create;
  FManager.AddTool(TDoublingTool.Create);
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
    Assert.AreEqual('doubling', Tools.Items[Tools.Count - 1].GetValue<string>('name'), 'the added tool comes last');
    var ReadOnly := False;
    for var Tool in Tools do
      if Tool.GetValue<string>('name') = 'test_simple_text' then
        ReadOnly := Tool.GetValue<Boolean>('annotations.readOnlyHint');
    Assert.IsTrue(ReadOnly);
    Assert.AreEqual('integer', Json.GetValue<string>('tools[' + (Tools.Count - 1).ToString + '].inputSchema.properties.value.type'));
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

initialization
  TDUnitX.RegisterTestFixture(TToolsManagerTests);

end.
