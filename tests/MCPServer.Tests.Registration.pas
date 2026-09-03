unit MCPServer.Tests.Registration;

interface

uses
  DUnitX.TestFramework;

type
  /// TMCPRegistry is filled from unit initialization sections; these tests
  /// only read it so the golden tests keep seeing the shipped registry.
  [TestFixture]
  TRegistryTests = class
  public
    [Test] procedure BuiltInTools_AreRegisteredFromInitialization;
    [Test] procedure BuiltInResources_AreRegisteredFromInitialization;
    [Test] procedure ServerStatus_IsNotRegisteredByDefault;
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
  Assert.AreEqual(4, Integer(Length(TMCPRegistry.GetToolNames)));
end;

procedure TRegistryTests.BuiltInResources_AreRegisteredFromInitialization;
begin
  Assert.IsTrue(TMCPRegistry.HasResource('project://info'));
  Assert.IsTrue(TMCPRegistry.HasResource('project://readme'));
  Assert.IsTrue(TMCPRegistry.HasResource('logs://recent'));
  Assert.AreEqual(3, Integer(Length(TMCPRegistry.GetResourceURIs)));
end;

procedure TRegistryTests.ServerStatus_IsNotRegisteredByDefault;
begin
  // Documented in tests\golden\README.md: only SetNamePrefix registers it.
  Assert.IsFalse(TMCPRegistry.HasResource('server://status'));
end;

procedure TRegistryTests.CreateTool_UnknownName_Raises;
begin
  var Probe: TProc :=
    procedure
    begin
      TMCPRegistry.CreateTool('no_such_tool');
    end;
  Assert.WillRaise(Probe, Exception);
end;

procedure TRegistryTests.CreateResource_UnknownUri_Raises;
begin
  var Probe: TProc :=
    procedure
    begin
      TMCPRegistry.CreateResource('nope://missing');
    end;
  Assert.WillRaise(Probe, Exception);
end;

procedure TRegistryTests.CreateTool_ReturnsFreshInstances;
begin
  var First: IMCPTool := TMCPRegistry.CreateTool('echo');
  var Second: IMCPTool := TMCPRegistry.CreateTool('echo');

  Assert.AreEqual('echo', First.Name);
  Assert.AreNotSame(First, Second);
end;

initialization
  TDUnitX.RegisterTestFixture(TRegistryTests);

end.
