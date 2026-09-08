unit MCPServer.Application;

interface

uses
  System.SysUtils,
  System.SyncObjs,
  MCPServer.Types,
  MCPServer.Settings,
  MCPServer.Host;

type
  TMCPServerApplication = class
  strict private
    FSettings: TMCPSettings;
    FHost: TMCPServerHost;
    function GetManagerRegistry: IMCPManagerRegistry;
    function GetCoreManager: IMCPCapabilityManager;
    procedure LogBanner(const Transport: string);
  public
    constructor Create(const WriteSettingsFile: Boolean);
    destructor Destroy; override;

    procedure RunHttp(const Shutdown: TEvent);
    procedure RunStdio;

    property Settings: TMCPSettings read FSettings;
    property ManagerRegistry: IMCPManagerRegistry read GetManagerRegistry;
    property CoreManager: IMCPCapabilityManager read GetCoreManager;
  end;

implementation

uses
  MCPServer.Logger,
  MCPServer.Authorization;

const
  BANNER_RULE = '================================';
  BANNER_TITLE = 'Model Context Protocol Server';

{ TMCPServerApplication }

constructor TMCPServerApplication.Create(const WriteSettingsFile: Boolean);
begin
  inherited Create;
  FSettings := TMCPSettings.Create('', WriteSettingsFile);
  FHost := TMCPServerHost.Create(FSettings);
  FHost.SeedFromGlobalRegistry := True;
end;

destructor TMCPServerApplication.Destroy;
begin
  FHost.Free;
  FSettings.Free;
  inherited;
end;

function TMCPServerApplication.GetManagerRegistry: IMCPManagerRegistry;
begin
  Result := FHost.ManagerRegistry;
end;

function TMCPServerApplication.GetCoreManager: IMCPCapabilityManager;
begin
  Result := FHost.CoreManager;
end;

procedure TMCPServerApplication.LogBanner(const Transport: string);
begin
  TLogger.Info(Format('Delphi MCP Server v%s', [FSettings.ServerVersion]));
  TLogger.Info(BANNER_RULE);
  TLogger.Info(BANNER_TITLE);
  TLogger.Info(Format('Transport: %s', [Transport]));
end;

procedure TMCPServerApplication.RunHttp(const Shutdown: TEvent);
begin
  LogBanner('HTTP');
  TLogger.Info(Format('Listening on port %d', [FSettings.Port]));

  const RequiresToken = (Length(FSettings.BearerTokenList) > 0);
  if RequiresToken then
    FHost.Authorizer := TMCPStaticBearerAuthorizer.Create(FSettings.BearerTokenList);

  FHost.StartHttp;
  TLogger.Info('Server started. Press CTRL+C to stop...');
  Shutdown.WaitFor(INFINITE);

  TLogger.Info('Shutting down server...');
  FHost.Stop;
  TLogger.Info('Server stopped successfully');
end;

procedure TMCPServerApplication.RunStdio;
begin
  LogBanner('STDIO');
  FHost.RunStdio;
end;

end.
