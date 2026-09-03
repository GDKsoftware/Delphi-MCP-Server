unit MCPServer.Capabilities;

interface

uses
  System.JSON,
  MCPServer.Types;

type
  /// Derives the server capabilities from the registered managers.
  ///
  /// Every manager that implements IMCPCapabilityProvider adds its own entry.
  /// A registry that cannot enumerate its managers yields the built-in
  /// defaults (tools and resources). The logging capability is never emitted.
  TMCPCapabilityBuilder = class
  public
    class function Build(const Registry: IMCPManagerRegistry; Era: TMCPProtocolEra): TJSONObject;
    class procedure AddDefaultCapabilities(const Capabilities: TJSONObject);
  end;

implementation

uses
  System.SysUtils;

{ TMCPCapabilityBuilder }

class procedure TMCPCapabilityBuilder.AddDefaultCapabilities(const Capabilities: TJSONObject);
begin
  var Tools := TJSONObject.Create;
  Tools.AddPair('listChanged', TJSONBool.Create(False));
  Capabilities.AddPair('tools', Tools);

  var Resources := TJSONObject.Create;
  Resources.AddPair('subscribe', TJSONBool.Create(False));
  Resources.AddPair('listChanged', TJSONBool.Create(False));
  Capabilities.AddPair('resources', Resources);
end;

class function TMCPCapabilityBuilder.Build(const Registry: IMCPManagerRegistry; Era: TMCPProtocolEra): TJSONObject;
var
  Enumerator: IMCPManagerEnumerator;
  Provider: IMCPCapabilityProvider;
begin
  Result := TJSONObject.Create;
  try
    if not Supports(Registry, IMCPManagerEnumerator, Enumerator) then
    begin
      AddDefaultCapabilities(Result);
      Exit;
    end;

    for var Manager in Enumerator.GetManagers do
      if Supports(Manager, IMCPCapabilityProvider, Provider) then
        Provider.DescribeCapabilities(Result, Era);
  except
    Result.Free;
    raise;
  end;
end;

end.
