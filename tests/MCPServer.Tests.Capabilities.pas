unit MCPServer.Tests.Capabilities;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TCapabilityBuilderTests = class
  public
    [Test] procedure Registry_YieldsToolsAndResourcesInRegistrationOrder;
    [Test] procedure Registry_NeverEmitsLogging;
    [Test] procedure RegistryWithoutEnumeration_YieldsDefaults;
  end;

implementation

uses
  System.SysUtils,
  System.Generics.Collections,
  System.JSON,
  MCPServer.Types,
  MCPServer.Capabilities,
  MCPServer.Tests.Harness;

type
  /// A registry that cannot list its managers (a consumer's own implementation).
  TOpaqueRegistry = class(TInterfacedObject, IMCPManagerRegistry)
  public
    procedure RegisterManager(const Manager: IMCPCapabilityManager);
    function GetManagerForMethod(const Method: string): IMCPCapabilityManager;
  end;

procedure TOpaqueRegistry.RegisterManager(const Manager: IMCPCapabilityManager);
begin
end;

function TOpaqueRegistry.GetManagerForMethod(const Method: string): IMCPCapabilityManager;
begin
  Result := nil;
end;

{ TCapabilityBuilderTests }

procedure TCapabilityBuilderTests.Registry_YieldsToolsAndResourcesInRegistrationOrder;
begin
  var Harness := TMCPTestHarness.Create;
  try
    var Capabilities := TMCPCapabilityBuilder.Build(Harness.ManagerRegistry, TMCPProtocolEra.Modern);
    try
      Assert.AreEqual(2, Capabilities.Count);
      Assert.AreEqual('tools', Capabilities.Pairs[0].JsonString.Value);
      Assert.AreEqual('resources', Capabilities.Pairs[1].JsonString.Value);
      Assert.IsFalse(Capabilities.GetValue<Boolean>('tools.listChanged'));
      Assert.IsFalse(Capabilities.GetValue<Boolean>('resources.subscribe'));
      Assert.IsFalse(Capabilities.GetValue<Boolean>('resources.listChanged'));
    finally
      Capabilities.Free;
    end;
  finally
    Harness.Free;
  end;
end;

procedure TCapabilityBuilderTests.Registry_NeverEmitsLogging;
begin
  var Harness := TMCPTestHarness.Create;
  try
    for var Era in [TMCPProtocolEra.Legacy, TMCPProtocolEra.Modern] do
    begin
      var Capabilities := TMCPCapabilityBuilder.Build(Harness.ManagerRegistry, Era);
      try
        Assert.IsNull(Capabilities.GetValue('logging'));
        Assert.IsNull(Capabilities.GetValue('extensions'));
      finally
        Capabilities.Free;
      end;
    end;
  finally
    Harness.Free;
  end;
end;

procedure TCapabilityBuilderTests.RegistryWithoutEnumeration_YieldsDefaults;
begin
  var Registry: IMCPManagerRegistry := TOpaqueRegistry.Create;
  var Capabilities := TMCPCapabilityBuilder.Build(Registry, TMCPProtocolEra.Legacy);
  try
    Assert.IsNotNull(Capabilities.GetValue('tools'));
    Assert.IsNotNull(Capabilities.GetValue('resources'));
  finally
    Capabilities.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TCapabilityBuilderTests);

end.
