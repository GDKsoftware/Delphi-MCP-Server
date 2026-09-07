unit MCPServer.Tests.Registration;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TRegistryTests = class
  public
    [Test] procedure BuiltInTools_AreRegisteredFromInitialization;
    [Test] procedure BuiltInResources_AreRegisteredFromInitialization;
    [Test] procedure BuiltInPrompts_AreRegisteredFromInitialization;
    [Test] procedure BuiltInResourceTemplates_AreRegisteredFromInitialization;
    [Test] procedure ServerStatus_IsRegisteredByDefault;
    [Test] procedure CreateTool_UnknownName_Raises;
    [Test] procedure CreateResource_UnknownUri_Raises;
    [Test] procedure CreateTool_ReturnsFreshInstances;
  end;

implementation

uses
  System.SysUtils,
  MCPServer.Registration,
  MCPServer.Tool.Base;

{ TRegistryTests }

procedure TRegistryTests.BuiltInTools_AreRegisteredFromInitialization;
begin
  Assert.IsTrue(TMCPRegistry.HasTool('echo'));
  Assert.IsTrue(TMCPRegistry.HasTool('get_time'));
  Assert.IsTrue(TMCPRegistry.HasTool('list_files'));
  Assert.IsTrue(TMCPRegistry.HasTool('calculate'));
  Assert.AreEqual(26, Integer(Length(TMCPRegistry.GetToolNames)));
end;

procedure TRegistryTests.BuiltInResources_AreRegisteredFromInitialization;
begin
  Assert.IsTrue(TMCPRegistry.HasResource('project://info'));
  Assert.IsTrue(TMCPRegistry.HasResource('project://readme'));
  Assert.IsTrue(TMCPRegistry.HasResource('logs://recent'));
  Assert.IsTrue(TMCPRegistry.HasResource('server://status'));
  Assert.AreEqual(6, Integer(Length(TMCPRegistry.GetResourceURIs)));
end;

procedure TRegistryTests.BuiltInPrompts_AreRegisteredFromInitialization;
begin
  Assert.IsTrue(TMCPRegistry.HasPrompt('summarize_logs'));
  Assert.IsTrue(TMCPRegistry.HasPrompt('test_simple_prompt'));
  Assert.IsTrue(TMCPRegistry.HasPrompt('test_prompt_with_arguments'));
  Assert.IsTrue(TMCPRegistry.HasPrompt('test_prompt_with_embedded_resource'));
  Assert.IsTrue(TMCPRegistry.HasPrompt('test_prompt_with_image'));
  Assert.AreEqual(6, Integer(Length(TMCPRegistry.GetPromptNames)));
end;

procedure TRegistryTests.BuiltInResourceTemplates_AreRegisteredFromInitialization;
begin
  Assert.AreEqual(2, Integer(Length(TMCPRegistry.GetResourceTemplateURIs)));
  Assert.AreEqual('logs://{level}', TMCPRegistry.GetResourceTemplateURIs[0]);
  Assert.AreEqual('test://template/{id}/data', TMCPRegistry.GetResourceTemplateURIs[1]);
end;

procedure TRegistryTests.ServerStatus_IsRegisteredByDefault;
begin
  var Status := TMCPRegistry.CreateResource('server://status');
  Assert.AreEqual('server://status', Status.URI);
  Assert.AreEqual('server_status', Status.Name);
end;

procedure TRegistryTests.CreateTool_UnknownName_Raises;
begin
  var Probe: TProc :=
    procedure
    begin
      TMCPRegistry.CreateTool('no_such_tool');
    end;
  Assert.WillRaise(Probe, EMCPRegistryNotFound);
end;

procedure TRegistryTests.CreateResource_UnknownUri_Raises;
begin
  var Probe: TProc :=
    procedure
    begin
      TMCPRegistry.CreateResource('nope://missing');
    end;
  Assert.WillRaise(Probe, EMCPRegistryNotFound);
end;

procedure TRegistryTests.CreateTool_ReturnsFreshInstances;
begin
  var First: IMCPTool := TMCPRegistry.CreateTool('echo');
  var Second: IMCPTool := TMCPRegistry.CreateTool('echo');

  Assert.AreEqual('echo', First.Name);
  Assert.AreNotSame(First, Second);
end;

end.
