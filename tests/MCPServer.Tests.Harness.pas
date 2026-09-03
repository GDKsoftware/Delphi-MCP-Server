unit MCPServer.Tests.Harness;

interface

uses
  System.SysUtils,
  MCPServer.Types,
  MCPServer.Settings,
  MCPServer.JsonRpcProcessor;

type
  /// Builds the same manager registry as MCPServer.dpr (core, tools and
  /// resources managers on top of the built-in registrations) and drives the
  /// transport-independent JSON-RPC processor directly.
  TMCPTestHarness = class
  private
    FSettings: TMCPSettings;
    FManagerRegistry: IMCPManagerRegistry;
    FCoreManager: IMCPCapabilityManager;
    FProcessor: TMCPJsonRpcProcessor;
  public
    constructor Create;
    destructor Destroy; override;

    /// Sends one JSON-RPC message through the processor and returns the raw
    /// response body; an empty string means "no response" (notification).
    function Process(const RequestBody: string): string;

    property Settings: TMCPSettings read FSettings;
    property ManagerRegistry: IMCPManagerRegistry read FManagerRegistry;
    property CoreManager: IMCPCapabilityManager read FCoreManager;
  end;

implementation

uses
  MCPServer.ManagerRegistry,
  MCPServer.CoreManager,
  MCPServer.ToolsManager,
  MCPServer.ResourcesManager;

{ TMCPTestHarness }

constructor TMCPTestHarness.Create;
begin
  inherited Create;

  // Never create a settings.ini next to the test executable; the defaults are
  // the same values the server writes into a fresh settings.ini.
  FSettings := TMCPSettings.Create('', False);

  FManagerRegistry := TMCPManagerRegistry.Create;
  FCoreManager := TMCPCoreManager.Create(FSettings);

  FManagerRegistry.RegisterManager(FCoreManager);
  FManagerRegistry.RegisterManager(TMCPToolsManager.Create);
  FManagerRegistry.RegisterManager(TMCPResourcesManager.Create);

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
