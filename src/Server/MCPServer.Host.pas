{
  MCPServer.Host

  A library facade over the manager composition. TMCPServerApplication builds the same managers but
  blocks in RunHttp, has no Stop and always seeds its tools manager from the global registry, so it
  cannot be driven from a library or from a test. TMCPServerHost adds a non-blocking StartHttp, an
  idempotent Stop and, by default, an empty tool set: two hosts in one process publish exactly the
  tools each of them was given.

  RunStdio is a console entry point and nothing else. TMCPStdioTransport.Create sets
  TLogger.UseStdErr and TLogger.StdoutReserved for the whole process and the transport has no Stop,
  so a GUI host must never call it. TMCPServerHost.Create constructs no transport; RunStdio and
  RunStdioWith each build one, use it and free it again.
}
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
    procedure EnsureManagers;
    function GetManagerRegistry: IMCPManagerRegistry;
    function GetCoreManager: IMCPCapabilityManager;
    procedure SetSeedFromGlobalRegistry(const Value: Boolean);
  public
    constructor Create;
    destructor Destroy; override;

    procedure AddTool(const Tool: IMCPTool);
    procedure RemoveTool(const Name: string);
    function HasTool(const Name: string): Boolean;
    procedure AddResource(const Resource: IMCPResource);
    procedure AddPrompt(const Prompt: IMCPPrompt);

    procedure StartHttp;
    procedure Stop;
    function BoundPort: Word;

    { Blocking, and only ever from a console entry point: the stdio transport claims stdout and
      redirects the logger to stderr for the whole process. }
    procedure RunStdio;
    { The same dispatch over two streams, so a caller can drive one line in and read one line out. }
    procedure RunStdioWith(const Input, Output: TStream);

    property Settings: TMCPSettings read FSettings;
    property Authorizer: IMCPAuthorizer read FAuthorizer write FAuthorizer;
    property Active: Boolean read FActive;
    property ManagerRegistry: IMCPManagerRegistry read GetManagerRegistry;
    property CoreManager: IMCPCapabilityManager read GetCoreManager;
    { False by default, which is what keeps two hosts in one process apart. It is read when the
      managers are built, which is on the first call that needs them, so it can still be set on a
      freshly created host. }
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

{ TMCPServerHost }

constructor TMCPServerHost.Create;
begin
  inherited Create;
  FSettings := TMCPSettings.Create('', False);
  FSeedFromGlobalRegistry := False;
end;

destructor TMCPServerHost.Destroy;
begin
  Stop;
  FServer.Free;
  FCoreManager := nil;
  FManagerRegistry := nil;
  FSettings.Free;
  inherited;
end;

procedure TMCPServerHost.BuildManagers;
begin
  FManagerRegistry := TMCPManagerRegistry.Create;
  FCoreManager := TMCPCoreManager.Create(FSettings);
  FToolsManager := TMCPToolsManager.Create(FSeedFromGlobalRegistry);
  FResourcesManager := TMCPResourcesManager.Create;
  FPromptsManager := TMCPPromptsManager.Create;
  FSubscriptionsManager := TMCPSubscriptionsManager.Create;

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
