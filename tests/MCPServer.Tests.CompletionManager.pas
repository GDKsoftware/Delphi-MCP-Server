unit MCPServer.Tests.CompletionManager;

interface

uses
  DUnitX.TestFramework,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tests.Harness;

type
  [TestFixture]
  TCompletionManagerTests = class
  private
    FHarness: TMCPTestHarness;
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    [Test] procedure RefPrompt_KnownArgument_ReturnsFilteredValues;
    [Test] procedure RefPrompt_UnknownPrompt_IsInvalidParams;
    [Test] procedure RefPrompt_MissingRefName_IsInvalidParams;
    [Test] procedure RefResource_Template_Completes;
    [Test] procedure RefResource_UnknownUri_IsNotFound;
    [Test] procedure RefResource_UnknownUri_Legacy_IsLegacyNotFound;
    [Test] procedure MissingArgument_IsInvalidParams;
    [Test] procedure UnknownRefType_IsInvalidParams;
    [Test] procedure CapabilitiesInclude_Completions;
  end;

implementation

uses
  System.SysUtils,
  MCPServer.Errors,
  MCPServer.CompletionManager;

{ TCompletionManagerTests }

procedure TCompletionManagerTests.Setup;
begin
  FHarness := TMCPTestHarness.Create;
end;

procedure TCompletionManagerTests.TearDown;
begin
  FHarness.Free;
end;

procedure TCompletionManagerTests.RefPrompt_KnownArgument_ReturnsFilteredValues;
begin
  var Manager := TMCPCompletionManager.Create(FHarness.PromptsManager, FHarness.ResourcesManager);
  var Params := TJSONObject.ParseJSONValue(
    '{"ref":{"type":"ref/prompt","name":"summarize_logs"},"argument":{"name":"level","value":"IN"}}') as TJSONObject;
  try
    var Json := Manager.Complete(Params, TMCPProtocolEra.Modern).AsType<TJSONObject>;
    try
      var Values := Json.FindValue('completion.values') as TJSONArray;
      for var Value in Values do
        Assert.IsTrue(Value.Value.ToUpper.StartsWith('IN'), 'every suggestion starts with the typed prefix');
      Assert.IsFalse(Json.GetValue<Boolean>('completion.hasMore'));
    finally
      Json.Free;
    end;
  finally
    Params.Free;
    Manager.Free;
  end;
end;

procedure TCompletionManagerTests.RefPrompt_UnknownPrompt_IsInvalidParams;
begin
  var Manager := TMCPCompletionManager.Create(FHarness.PromptsManager, FHarness.ResourcesManager);
  var Params := TJSONObject.ParseJSONValue(
    '{"ref":{"type":"ref/prompt","name":"nope"},"argument":{"name":"x","value":""}}') as TJSONObject;
  try
    try
      Manager.Complete(Params, TMCPProtocolEra.Modern).AsType<TJSONObject>.Free;
      Assert.Fail('expected -32602');
    except
      on E: EMCPError do
        Assert.AreEqual(JSONRPC_INVALID_PARAMS, E.Code);
    end;
  finally
    Params.Free;
    Manager.Free;
  end;
end;

procedure TCompletionManagerTests.RefPrompt_MissingRefName_IsInvalidParams;
begin
  var Manager := TMCPCompletionManager.Create(FHarness.PromptsManager, FHarness.ResourcesManager);
  var Params := TJSONObject.ParseJSONValue(
    '{"ref":{"type":"ref/prompt"},"argument":{"name":"x","value":""}}') as TJSONObject;
  try
    try
      Manager.Complete(Params, TMCPProtocolEra.Modern).AsType<TJSONObject>.Free;
      Assert.Fail('expected -32602');
    except
      on E: EMCPError do
        Assert.AreEqual(JSONRPC_INVALID_PARAMS, E.Code);
    end;
  finally
    Params.Free;
    Manager.Free;
  end;
end;

procedure TCompletionManagerTests.RefResource_Template_Completes;
begin
  var Manager := TMCPCompletionManager.Create(FHarness.PromptsManager, FHarness.ResourcesManager);
  var Params := TJSONObject.ParseJSONValue(
    '{"ref":{"type":"ref/resource","uri":"logs://{level}"},"argument":{"name":"level","value":""}}') as TJSONObject;
  try
    var Json := Manager.Complete(Params, TMCPProtocolEra.Modern).AsType<TJSONObject>;
    try
      Assert.IsNotNull(Json.FindValue('completion.values'));
    finally
      Json.Free;
    end;
  finally
    Params.Free;
    Manager.Free;
  end;
end;

procedure TCompletionManagerTests.RefResource_UnknownUri_IsNotFound;
begin
  var Manager := TMCPCompletionManager.Create(FHarness.PromptsManager, FHarness.ResourcesManager);
  var Params := TJSONObject.ParseJSONValue(
    '{"ref":{"type":"ref/resource","uri":"nope://missing"},"argument":{"name":"x","value":""}}') as TJSONObject;
  try
    try
      Manager.Complete(Params, TMCPProtocolEra.Modern).AsType<TJSONObject>.Free;
      Assert.Fail('expected an error');
    except
      on E: EMCPError do
        Assert.AreEqual(JSONRPC_INVALID_PARAMS, E.Code);
    end;
  finally
    Params.Free;
    Manager.Free;
  end;
end;

procedure TCompletionManagerTests.RefResource_UnknownUri_Legacy_IsLegacyNotFound;
begin
  var Manager := TMCPCompletionManager.Create(FHarness.PromptsManager, FHarness.ResourcesManager);
  var Params := TJSONObject.ParseJSONValue(
    '{"ref":{"type":"ref/resource","uri":"nope://missing"},"argument":{"name":"x","value":""}}') as TJSONObject;
  try
    try
      Manager.Complete(Params, TMCPProtocolEra.Legacy).AsType<TJSONObject>.Free;
      Assert.Fail('expected an error');
    except
      on E: EMCPError do
        Assert.AreEqual(MCP_ERROR_RESOURCE_NOT_FOUND_LEGACY, E.Code);
    end;
  finally
    Params.Free;
    Manager.Free;
  end;
end;

procedure TCompletionManagerTests.MissingArgument_IsInvalidParams;
begin
  var Manager := TMCPCompletionManager.Create(FHarness.PromptsManager, FHarness.ResourcesManager);
  var Params := TJSONObject.ParseJSONValue('{"ref":{"type":"ref/prompt","name":"summarize_logs"}}') as TJSONObject;
  try
    try
      Manager.Complete(Params, TMCPProtocolEra.Modern).AsType<TJSONObject>.Free;
      Assert.Fail('expected -32602');
    except
      on E: EMCPError do
        Assert.AreEqual(JSONRPC_INVALID_PARAMS, E.Code);
    end;
  finally
    Params.Free;
    Manager.Free;
  end;
end;

procedure TCompletionManagerTests.UnknownRefType_IsInvalidParams;
begin
  var Manager := TMCPCompletionManager.Create(FHarness.PromptsManager, FHarness.ResourcesManager);
  var Params := TJSONObject.ParseJSONValue(
    '{"ref":{"type":"ref/bogus"},"argument":{"name":"x","value":""}}') as TJSONObject;
  try
    try
      Manager.Complete(Params, TMCPProtocolEra.Modern).AsType<TJSONObject>.Free;
      Assert.Fail('expected -32602');
    except
      on E: EMCPError do
        Assert.AreEqual(JSONRPC_INVALID_PARAMS, E.Code);
    end;
  finally
    Params.Free;
    Manager.Free;
  end;
end;

procedure TCompletionManagerTests.CapabilitiesInclude_Completions;
begin
  var Manager := TMCPCompletionManager.Create(FHarness.PromptsManager, FHarness.ResourcesManager);
  var Capabilities := TJSONObject.Create;
  try
    Manager.DescribeCapabilities(Capabilities, TMCPProtocolEra.Modern);
    Assert.IsTrue(Capabilities.GetValue('completions') is TJSONObject);
  finally
    Capabilities.Free;
    Manager.Free;
  end;
end;

end.
