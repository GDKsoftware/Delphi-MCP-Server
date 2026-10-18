unit MCPServer.StdioHost;

interface

uses
  System.Classes,
  MCPServer.Types,
  MCPServer.Settings,
  MCPServer.Tool.Base,
  MCPServer.Resource.Base,
  MCPServer.Prompt.Base,
  MCPServer.ToolsManager,
  MCPServer.ResourcesManager,
  MCPServer.PromptsManager,
  MCPServer.SubscriptionsManager,
  MCPServer.Task.Types,
  MCPServer.TasksManager;

type
  TMCPStdioHost = class
  strict private
    FSettings: TMCPSettings;
    FOwnsSettings: Boolean;
    FManagerRegistry: IMCPManagerRegistry;
    FCoreManager: IMCPCapabilityManager;
    FToolsManager: TMCPToolsManager;
    FResourcesManager: TMCPResourcesManager;
    FPromptsManager: TMCPPromptsManager;
    FSubscriptionsManager: TMCPSubscriptionsManager;
    FTasksManager: TMCPTasksManager;
    FTaskStore: IMCPTaskStore;
    FSeedFromGlobalRegistry: Boolean;
    procedure BuildManagers;
    procedure BuildTasksManager;
    procedure HideDiagnosticsResources;
    function GetManagerRegistry: IMCPManagerRegistry;
    function GetCoreManager: IMCPCapabilityManager;
    procedure SetSeedFromGlobalRegistry(const Value: Boolean);
    procedure SetTaskStore(const Value: IMCPTaskStore);
    function GetTasks: TMCPTasksManager;
  protected
    procedure EnsureManagers;
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

    procedure RunStdio;
    procedure RunStdioWith(const Input, Output: TStream);

    property Settings: TMCPSettings read FSettings;
    property ManagerRegistry: IMCPManagerRegistry read GetManagerRegistry;
    property CoreManager: IMCPCapabilityManager read GetCoreManager;
    property SeedFromGlobalRegistry: Boolean read FSeedFromGlobalRegistry write SetSeedFromGlobalRegistry;
    property TaskStore: IMCPTaskStore read FTaskStore write SetTaskStore;
    property Tasks: TMCPTasksManager read GetTasks;
  end;

implementation

uses
  System.SysUtils,
  MCPServer.Errors,
  MCPServer.ManagerRegistry,
  MCPServer.CoreManager,
  MCPServer.CompletionManager,
  MCPServer.TaskStore.Memory,
  MCPServer.StdioTransport;

const
  URI_LOGS_RECENT = 'logs://recent';
  URI_SERVER_STATUS = 'server://status';
  URI_TEMPLATE_LOGS_BY_LEVEL = 'logs://{level}';

{ TMCPStdioHost }

constructor TMCPStdioHost.Create;
begin
  Create('');
end;

constructor TMCPStdioHost.Create(const SettingsFile: string);
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

constructor TMCPStdioHost.Create(const Settings: TMCPSettings);
begin
  inherited Create;

  if not Assigned(Settings) then
    raise EArgumentNilException.Create('A host built on settings needs a settings instance');

  FSettings := Settings;
  FOwnsSettings := False;
  FSeedFromGlobalRegistry := False;
end;

destructor TMCPStdioHost.Destroy;
begin
  if Assigned(FTasksManager) then
    FTasksManager.Shutdown;
  FCoreManager := nil;
  FManagerRegistry := nil;
  if FOwnsSettings then
    FSettings.Free;
  inherited;
end;

procedure TMCPStdioHost.BuildManagers;
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

  if FSettings.TasksEnabled then
    BuildTasksManager;
end;

procedure TMCPStdioHost.BuildTasksManager;
begin
  if not Assigned(FTaskStore) then
    FTaskStore := TMCPInMemoryTaskStore.Create;

  FTasksManager := TMCPTasksManager.Create(FTaskStore, FSettings.TaskTtlMs, FSettings.TaskPollIntervalMs,
                                           FSettings.MaxRunningTasks);
  FToolsManager.TaskService := FTasksManager;
  FManagerRegistry.RegisterManager(FTasksManager);
end;

procedure TMCPStdioHost.HideDiagnosticsResources;
begin
  FResourcesManager.RemoveResource(URI_LOGS_RECENT);
  FResourcesManager.RemoveResource(URI_SERVER_STATUS);
  FResourcesManager.RemoveResourceTemplate(URI_TEMPLATE_LOGS_BY_LEVEL);
end;

procedure TMCPStdioHost.EnsureManagers;
begin
  if not Assigned(FManagerRegistry) then
    BuildManagers;
end;

function TMCPStdioHost.GetManagerRegistry: IMCPManagerRegistry;
begin
  EnsureManagers;
  Result := FManagerRegistry;
end;

function TMCPStdioHost.GetCoreManager: IMCPCapabilityManager;
begin
  EnsureManagers;
  Result := FCoreManager;
end;

procedure TMCPStdioHost.SetSeedFromGlobalRegistry(const Value: Boolean);
begin
  if Value = FSeedFromGlobalRegistry then
    Exit;

  if Assigned(FManagerRegistry) then
    raise EMCPConfigurationError.Create('SeedFromGlobalRegistry must be set before the host builds its managers');

  FSeedFromGlobalRegistry := Value;
end;

procedure TMCPStdioHost.SetTaskStore(const Value: IMCPTaskStore);
begin
  if Assigned(FManagerRegistry) then
    raise EMCPConfigurationError.Create('TaskStore must be set before the host builds its managers');

  FTaskStore := Value;
end;

function TMCPStdioHost.GetTasks: TMCPTasksManager;
begin
  EnsureManagers;
  Result := FTasksManager;
end;

procedure TMCPStdioHost.AddTool(const Tool: IMCPTool);
begin
  EnsureManagers;
  FToolsManager.AddTool(Tool);
end;

procedure TMCPStdioHost.RemoveTool(const Name: string);
begin
  EnsureManagers;
  FToolsManager.RemoveTool(Name);
end;

function TMCPStdioHost.HasTool(const Name: string): Boolean;
begin
  EnsureManagers;
  Result := FToolsManager.HasTool(Name);
end;

procedure TMCPStdioHost.AddResource(const Resource: IMCPResource);
begin
  EnsureManagers;
  FResourcesManager.AddResource(Resource);
end;

procedure TMCPStdioHost.AddPrompt(const Prompt: IMCPPrompt);
begin
  EnsureManagers;
  FPromptsManager.AddPrompt(Prompt);
end;

procedure TMCPStdioHost.RunStdio;
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

procedure TMCPStdioHost.RunStdioWith(const Input, Output: TStream);
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
