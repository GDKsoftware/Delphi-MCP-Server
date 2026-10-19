unit MCPServer.Host;

interface

uses
  MCPServer.Authorization,
  MCPServer.StdioHost,
  MCPServer.IdHTTPServer;

type
  TMCPServerHost = class(TMCPStdioHost)
  strict private
    FServer: TMCPIdHTTPServer;
    FAuthorizer: IMCPAuthorizer;
    FActive: Boolean;

  public
    destructor Destroy; override;

    procedure StartHttp;
    procedure Stop;
    function BoundPort: Word;

    property Authorizer: IMCPAuthorizer read FAuthorizer write FAuthorizer;
    property Active: Boolean read FActive;
  end;

implementation

{ TMCPServerHost }

destructor TMCPServerHost.Destroy;
begin
  Stop;
  ShutdownTasks;
  FServer.Free;
  inherited;
end;

procedure TMCPServerHost.StartHttp;
begin
  if FActive then
    Exit;

  EnsureManagers;

  if not Assigned(FServer) then
    FServer := TMCPIdHTTPServer.Create(nil);

  FServer.Settings := Settings;
  FServer.ManagerRegistry := ManagerRegistry;
  FServer.CoreManager := CoreManager;
  FServer.Authorizer := FAuthorizer;
  FServer.Start;
  FActive := True;
end;

procedure TMCPServerHost.Stop;
begin
  if not FActive then
    Exit;

  FActive := False;
  FServer.Stop;
end;

function TMCPServerHost.BoundPort: Word;
begin
  if Assigned(FServer) then
    Result := FServer.BoundPort
  else
    Result := Word(Settings.Port);
end;

end.
