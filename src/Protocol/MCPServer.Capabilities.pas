unit MCPServer.Capabilities;

interface

uses
  System.JSON,
  MCPServer.Types;

type
  TMCPCapabilityBuilder = class
  private
    class procedure AddExtensions(const Capabilities: TJSONObject; const Registry: IMCPManagerRegistry); static;
  public
    class function Build(const Registry: IMCPManagerRegistry; Era: TMCPProtocolEra): TJSONObject;
    class procedure AddDefaultCapabilities(const Capabilities: TJSONObject);
  end;

implementation

uses
  System.SysUtils,
  MCPServer.Extensions;

{ TMCPCapabilityBuilder }

class procedure TMCPCapabilityBuilder.AddDefaultCapabilities(const Capabilities: TJSONObject);
begin
  var Tools := TJSONObject.Create;
  Tools.AddPair(MCP_KEY_LIST_CHANGED, TJSONBool.Create(False));
  Capabilities.AddPair('tools', Tools);

  var Resources := TJSONObject.Create;
  Resources.AddPair(MCP_KEY_SUBSCRIBE, TJSONBool.Create(False));
  Resources.AddPair(MCP_KEY_LIST_CHANGED, TJSONBool.Create(False));
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

    const IsModern = (Era = TMCPProtocolEra.Modern);
    if IsModern then
      AddExtensions(Result, Registry);
  except
    Result.Free;
    raise;
  end;
end;

class procedure TMCPCapabilityBuilder.AddExtensions(const Capabilities: TJSONObject;
  const Registry: IMCPManagerRegistry);
begin
  const Extensions = TMCPExtensions.Describe(Registry);
  if Assigned(Extensions) then
    Capabilities.AddPair(MCP_KEY_EXTENSIONS, Extensions);
end;

end.
