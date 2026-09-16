unit MCPServer.Tests.Harness;

interface

uses
  System.SysUtils,
  MCPServer.Types,
  MCPServer.Settings,
  MCPServer.ToolsManager,
  MCPServer.ResourcesManager,
  MCPServer.PromptsManager,
  MCPServer.SubscriptionsManager,
  MCPServer.JsonRpcProcessor;

type
  TMCPTestHarness = class
  private
    FSettings: TMCPSettings;
    FManagerRegistry: IMCPManagerRegistry;
    FCoreManager: IMCPCapabilityManager;
    FToolsManager: TMCPToolsManager;
    FResourcesManager: TMCPResourcesManager;
    FPromptsManager: TMCPPromptsManager;
    FSubscriptionsManager: TMCPSubscriptionsManager;
    FProcessor: TMCPJsonRpcProcessor;
  public
    constructor Create;
    destructor Destroy; override;

    function Process(const RequestBody: string): string;

    property Settings: TMCPSettings read FSettings;
    property ManagerRegistry: IMCPManagerRegistry read FManagerRegistry;
    property CoreManager: IMCPCapabilityManager read FCoreManager;
    property ToolsManager: TMCPToolsManager read FToolsManager;
    property ResourcesManager: TMCPResourcesManager read FResourcesManager;
    property PromptsManager: TMCPPromptsManager read FPromptsManager;
    property SubscriptionsManager: TMCPSubscriptionsManager read FSubscriptionsManager;
  end;

implementation

uses
  MCPServer.ManagerRegistry,
  MCPServer.CoreManager,
  MCPServer.CompletionManager;

{ TMCPTestHarness }

constructor TMCPTestHarness.Create;
begin
  inherited Create;

  FSettings := TMCPSettings.Create('', False);

  FManagerRegistry := TMCPManagerRegistry.Create;
  FCoreManager := TMCPCoreManager.Create(FSettings);
  FToolsManager := TMCPToolsManager.Create;
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

  FProcessor := TMCPJsonRpcProcessor.Create(FManagerRegistry);
end;

destructor TMCPTestHarness.Destroy;
begin
  FProcessor.Free;
  FCoreManager := nil;
  FManagerRegistry := nil;
  FSettings.Free;
  inherited;
end;

function TMCPTestHarness.Process(const RequestBody: string): string;
begin
  Result := FProcessor.ProcessRequest(RequestBody, '');
end;

end.
