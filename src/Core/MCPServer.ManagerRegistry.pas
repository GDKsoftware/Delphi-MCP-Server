unit MCPServer.ManagerRegistry;

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  MCPServer.Types;

type
  TMCPManagerRegistry = class(TInterfacedObject, IMCPManagerRegistry)
  private
    FManagers: TList<IMCPCapabilityManager>;
  public
    constructor Create;
    destructor Destroy; override;
    
    procedure RegisterManager(const Manager: IMCPCapabilityManager);
    function GetManagerForMethod(const Method: string): IMCPCapabilityManager;
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
begin
  if not FManagers.Contains(Manager) then
    FManagers.Add(Manager);
end;

function TMCPManagerRegistry.GetManagerForMethod(const Method: string): IMCPCapabilityManager;
begin
  Result := nil;
  for var Manager in FManagers do
  begin
    if Manager.HandlesMethod(Method) then
    begin
      Result := Manager;
      Break;
    end;
  end;
end;

end.