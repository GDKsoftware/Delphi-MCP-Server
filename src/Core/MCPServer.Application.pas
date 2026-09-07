unit MCPServer.Application;

interface

uses
  System.SysUtils,
  System.SyncObjs,
  MCPServer.Types,
  MCPServer.Settings,
  MCPServer.ToolsManager,
  MCPServer.ResourcesManager,
  MCPServer.PromptsManager,
  MCPServer.SubscriptionsManager;

type
  TMCPServerApplication = class
  strict private
    FSettings: TMCPSettings;
    FManagerRegistry: IMCPManagerRegistry;
    FCoreManager: IMCPCapabilityManager;
    FToolsManager: TMCPToolsManager;
    FResourcesManager: TMCPResourcesManager;
    FPromptsManager: TMCPPromptsManager;
    FSubscriptionsManager: TMCPSubscriptionsManager;
    procedure BuildManagers;
    procedure HideDiagnosticsResources;
    procedure LogBanner(const Transport: string);
  public
    constructor Create(const WriteSettingsFile: Boolean);
    destructor Destroy; override;

    procedure RunHttp(const Shutdown: TEvent);
    procedure RunStdio;

    property Settings: TMCPSettings read FSettings;
    property ManagerRegistry: IMCPManagerRegistry read FManagerRegistry;
    property CoreManager: IMCPCapabilityManager read FCoreManager;
  end;

implementation

uses
  MCPServer.Logger,
  MCPServer.Authorization,
  MCPServer.ManagerRegistry,
  MCPServer.CoreManager,
  MCPServer.CompletionManager,
  MCPServer.IdHTTPServer,
  MCPServer.StdioTransport;

const
  BANNER_RULE = '================================';
  BANNER_TITLE = 'Model Context Protocol Server';
  URI_LOGS_RECENT = 'logs://recent';
  URI_SERVER_STATUS = 'server://status';
  URI_TEMPLATE_LOGS_BY_LEVEL = 'logs://{level}';

{ TMCPServerApplication }

constructor TMCPServerApplication.Create(const WriteSettingsFile: Boolean);
begin
  inherited Create;
  FSettings := TMCPSettings.Create('', WriteSettingsFile);
  BuildManagers;
end;

destructor TMCPServerApplication.Destroy;
begin
  FCoreManager := nil;
  FManagerRegistry := nil;
  FSettings.Free;
  inherited;
end;

procedure TMCPServerApplication.BuildManagers;
begin
  FManagerRegistry := TMCPManagerRegistry.Create;
  FCoreManager := TMCPCoreManager.Create(FSettings);
  FToolsManager := TMCPToolsManager.Create;
  FResourcesManager := TMCPResourcesManager.Create;
  FPromptsManager := TMCPPromptsManager.Create;
  FSubscriptionsManager := TMCPSubscriptionsManager.Create;

  if not FSettings.ExposeDiagnosticsResources then
    HideDiagnosticsResources;

  FToolsManager.ChangeNotifier := FSubscriptionsManager;
  FResourcesManager.ChangeNotifier := FSubscriptionsManager;
  FPromptsManager.ChangeNotifier := FSubscriptionsManager;

  FManagerRegistry.RegisterManager(FCoreManager);
  FManagerRegistry.RegisterManager(FToolsManager);
  FManagerRegistry.RegisterManager(FResourcesManager);
  FManagerRegistry.RegisterManager(FPromptsManager);
  FManagerRegistry.RegisterManager(TMCPCompletionManager.Create(FPromptsManager, FResourcesManager));
  FManagerRegistry.RegisterManager(FSubscriptionsManager);
end;

procedure TMCPServerApplication.HideDiagnosticsResources;
begin
  FResourcesManager.RemoveResource(URI_LOGS_RECENT);
  FResourcesManager.RemoveResource(URI_SERVER_STATUS);
  FResourcesManager.RemoveResourceTemplate(URI_TEMPLATE_LOGS_BY_LEVEL);
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

  const Server = TMCPIdHTTPServer.Create(nil);
  try
    Server.Settings := FSettings;
    Server.ManagerRegistry := FManagerRegistry;
    Server.CoreManager := FCoreManager;

    const RequiresToken = (Length(FSettings.BearerTokenList) > 0);
    if RequiresToken then
      Server.Authorizer := TMCPStaticBearerAuthorizer.Create(FSettings.BearerTokenList);

    Server.Start;
    TLogger.Info('Server started. Press CTRL+C to stop...');
    Shutdown.WaitFor(INFINITE);

    TLogger.Info('Shutting down server...');
    Server.Stop;
    TLogger.Info('Server stopped successfully');
  finally
    Server.Free;
  end;
end;

procedure TMCPServerApplication.RunStdio;
begin
  LogBanner('STDIO');

  const Transport = TMCPStdioTransport.Create(FManagerRegistry, FCoreManager);
  try
    Transport.Settings := FSettings;
    Transport.Run;
  finally
    Transport.Free;
  end;
end;

end.
