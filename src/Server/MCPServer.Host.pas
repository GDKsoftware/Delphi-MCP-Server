unit MCPServer.Host;

interface

uses
  System.Classes,
  MCPServer.Types,
  MCPServer.Settings,
  MCPServer.Authorization,
  MCPServer.Tool.Base,
  MCPServer.Resource.Base,
  MCPServer.Prompt.Base,
  MCPServer.ToolsManager,
  MCPServer.ResourcesManager,
  MCPServer.PromptsManager,
  MCPServer.SubscriptionsManager,
  MCPServer.IdHTTPServer;

type
  TMCPServerHost = class
  strict private
    FSettings: TMCPSettings;
    FOwnsSettings: Boolean;
    FManagerRegistry: IMCPManagerRegistry;
    FCoreManager: IMCPCapabilityManager;
    FToolsManager: TMCPToolsManager;
    FResourcesManager: TMCPResourcesManager;
    FPromptsManager: TMCPPromptsManager;
    FSubscriptionsManager: TMCPSubscriptionsManager;
    FServer: TMCPIdHTTPServer;
    FAuthorizer: IMCPAuthorizer;
    FSeedFromGlobalRegistry: Boolean;
    FActive: Boolean;
    procedure BuildManagers;
    procedure HideDiagnosticsResources;
    procedure EnsureManagers;
    function GetManagerRegistry: IMCPManagerRegistry;
    function GetCoreManager: IMCPCapabilityManager;
    procedure SetSeedFromGlobalRegistry(const Value: Boolean);
  public
    constructor Create; overload;
    constructor Create(const SettingsFile: string); overload;
    constructor Create(const Settings: TMCPSettings); overload;
    destructor Destroy; override;

    procedure AddTool(const Tool: IMCPTool);
    procedure RemoveTool(const Name: string);
    function HasTool(const Name: string): Boolean;
    procedure AddResource(const Resource: IMCPResource);
    procedure AddPrompt(const Prompt: IMCPPrompt);

    procedure StartHttp;
    procedure Stop;
    function BoundPort: Word;

    procedure RunStdio;
    procedure RunStdioWith(const Input, Output: TStream);

    property Settings: TMCPSettings read FSettings;
    property Authorizer: IMCPAuthorizer read FAuthorizer write FAuthorizer;
    property Active: Boolean read FActive;
    property ManagerRegistry: IMCPManagerRegistry read GetManagerRegistry;
    property CoreManager: IMCPCapabilityManager read GetCoreManager;
    property SeedFromGlobalRegistry: Boolean read FSeedFromGlobalRegistry write SetSeedFromGlobalRegistry;
  end;

implementation

uses
  System.SysUtils,
  MCPServer.Errors,
  MCPServer.ManagerRegistry,
  MCPServer.CoreManager,
  MCPServer.CompletionManager,
  MCPServer.StdioTransport;

const
  URI_LOGS_RECENT = 'logs://recent';
  URI_SERVER_STATUS = 'server://status';
  URI_TEMPLATE_LOGS_BY_LEVEL = 'logs://{level}';

{ TMCPServerHost }

constructor TMCPServerHost.Create;
begin
  Create('');
end;

constructor TMCPServerHost.Create(const SettingsFile: string);
begin
  inherited Create;

  const ReadsAFile = (SettingsFile <> '');
  if ReadsAFile then
    FSettings := TMCPSettings.Create(SettingsFile, False)
  else
    FSettings := TMCPSettings.CreateDefaults;

  FOwnsSettings := True;
  FSeedFromGlobalRegistry := False;
end;

constructor TMCPServerHost.Create(const Settings: TMCPSettings);
begin
  inherited Create;

  if not Assigned(Settings) then
    raise EArgumentNilException.Create('A host built on settings needs a settings instance');

  FSettings := Settings;
  FOwnsSettings := False;
  FSeedFromGlobalRegistry := False;
end;

destructor TMCPServerHost.Destroy;
begin
  Stop;
  FServer.Free;
  FCoreManager := nil;
  FManagerRegistry := nil;
  if FOwnsSettings then
    FSettings.Free;
  inherited;
end;

procedure TMCPServerHost.BuildManagers;
begin
  FManagerRegistry := TMCPManagerRegistry.Create;
  FCoreManager := TMCPCoreManager.Create(FSettings);
  FToolsManager := TMCPToolsManager.Create(FSeedFromGlobalRegistry);
  FResourcesManager := TMCPResourcesManager.Create(FSeedFromGlobalRegistry);
  FPromptsManager := TMCPPromptsManager.Create(FSeedFromGlobalRegistry);
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

procedure TMCPServerHost.HideDiagnosticsResources;
begin
  FResourcesManager.RemoveResource(URI_LOGS_RECENT);
  FResourcesManager.RemoveResource(URI_SERVER_STATUS);
  FResourcesManager.RemoveResourceTemplate(URI_TEMPLATE_LOGS_BY_LEVEL);
end;

procedure TMCPServerHost.EnsureManagers;
begin
  if not Assigned(FManagerRegistry) then
    BuildManagers;
end;

function TMCPServerHost.GetManagerRegistry: IMCPManagerRegistry;
begin
  EnsureManagers;
  Result := FManagerRegistry;
end;

function TMCPServerHost.GetCoreManager: IMCPCapabilityManager;
begin
  EnsureManagers;
  Result := FCoreManager;
end;

procedure TMCPServerHost.SetSeedFromGlobalRegistry(const Value: Boolean);
begin
  if Value = FSeedFromGlobalRegistry then
    Exit;

  if Assigned(FManagerRegistry) then
    raise EMCPConfigurationError.Create('SeedFromGlobalRegistry must be set before the host builds its managers');

  FSeedFromGlobalRegistry := Value;
end;

procedure TMCPServerHost.AddTool(const Tool: IMCPTool);
begin
  EnsureManagers;
  FToolsManager.AddTool(Tool);
end;

procedure TMCPServerHost.RemoveTool(const Name: string);
begin
  EnsureManagers;
  FToolsManager.RemoveTool(Name);
end;

function TMCPServerHost.HasTool(const Name: string): Boolean;
begin
  EnsureManagers;
  Result := FToolsManager.HasTool(Name);
end;

procedure TMCPServerHost.AddResource(const Resource: IMCPResource);
begin
  EnsureManagers;
  FResourcesManager.AddResource(Resource);
end;

procedure TMCPServerHost.AddPrompt(const Prompt: IMCPPrompt);
begin
  EnsureManagers;
  FPromptsManager.AddPrompt(Prompt);
end;

procedure TMCPServerHost.StartHttp;
begin
  if FActive then
    Exit;

  EnsureManagers;

  if not Assigned(FServer) then
    FServer := TMCPIdHTTPServer.Create(nil);

  FServer.Settings := FSettings;
  FServer.ManagerRegistry := FManagerRegistry;
  FServer.CoreManager := FCoreManager;
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
    Result := Word(FSettings.Port);
end;

procedure TMCPServerHost.RunStdio;
begin
  EnsureManagers;

  const Transport = TMCPStdioTransport.Create(FManagerRegistry, FCoreManager);
  try
    Transport.Settings := FSettings;
    Transport.Run;
  finally
    Transport.Free;
  end;
end;

procedure TMCPServerHost.RunStdioWith(const Input, Output: TStream);
begin
  EnsureManagers;

  const Transport = TMCPStdioTransport.Create(FManagerRegistry, FCoreManager);
  try
    Transport.Settings := FSettings;
    Transport.RunWith(Input, Output);
  finally
    Transport.Free;
  end;
end;

end.
