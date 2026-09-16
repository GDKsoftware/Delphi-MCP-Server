unit MCPServer.ManagerRegistry;

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  MCPServer.Types;

type
  TMCPManagerRegistry = class(TInterfacedObject, IMCPManagerRegistry, IMCPManagerEnumerator)
  private
    FManagers: TList<IMCPCapabilityManager>;
  public
    constructor Create;
    destructor Destroy; override;

    procedure RegisterManager(const Manager: IMCPCapabilityManager);
    function GetManagerForMethod(const Method: string): IMCPCapabilityManager;
    function GetManagers: TArray<IMCPCapabilityManager>;
  end;

implementation

{ TMCPManagerRegistry }

constructor TMCPManagerRegistry.Create;
begin
  inherited;
  FManagers := TList<IMCPCapabilityManager>.Create;
end;

destructor TMCPManagerRegistry.Destroy;
begin
  FManagers.Clear;
  FManagers.Free;
  inherited;
end;

procedure TMCPManagerRegistry.RegisterManager(const Manager: IMCPCapabilityManager);
var
  Aware: IMCPRegistryAware;
begin
  if FManagers.Contains(Manager) then
    Exit;

  FManagers.Add(Manager);
  if Supports(Manager, IMCPRegistryAware, Aware) then
    Aware.SetManagerRegistry(Self);
end;

function TMCPManagerRegistry.GetManagerForMethod(const Method: string): IMCPCapabilityManager;
var
  Manager: IMCPCapabilityManager;
begin
  Result := nil;
  for Manager in FManagers do
  begin
    if Manager.HandlesMethod(Method) then
    begin
      Result := Manager;
      Break;
    end;
  end;
end;

function TMCPManagerRegistry.GetManagers: TArray<IMCPCapabilityManager>;
begin
  Result := FManagers.ToArray;
end;

end.
