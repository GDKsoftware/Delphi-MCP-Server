program MCPServer;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.SyncObjs,
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  {$ENDIF}
  {$IFDEF POSIX}
  Posix.Signal,
  {$ENDIF}
  MCPServer.Types in 'Protocol\MCPServer.Types.pas',
  MCPServer.Errors in 'Protocol\MCPServer.Errors.pas',
  MCPServer.RequestContext in 'Protocol\MCPServer.RequestContext.pas',
  MCPServer.Capabilities in 'Protocol\MCPServer.Capabilities.pas',
  MCPServer.HttpHeaders in 'Server\MCPServer.HttpHeaders.pas',
  MCPServer.HttpStream in 'Server\MCPServer.HttpStream.pas',
  MCPServer.Serializer in 'Protocol\MCPServer.Serializer.pas',
  MCPServer.Schema.Generator in 'Protocol\MCPServer.Schema.Generator.pas',
  MCPServer.Schema.Validator in 'Protocol\MCPServer.Schema.Validator.pas',
  MCPServer.ContentBlocks in 'Protocol\MCPServer.ContentBlocks.pas',
  MCPServer.Logger in 'Core\MCPServer.Logger.pas',
  MCPServer.Settings in 'Core\MCPServer.Settings.pas',
  MCPServer.Authorization in 'Core\MCPServer.Authorization.pas',
  MCPServer.Registration in 'Core\MCPServer.Registration.pas',
  MCPServer.ManagerRegistry in 'Core\MCPServer.ManagerRegistry.pas',
  MCPServer.Tool.Base in 'Tools\MCPServer.Tool.Base.pas',
  MCPServer.Tool.Result in 'Tools\MCPServer.Tool.Result.pas',
  MCPServer.Resource.Base in 'Resources\MCPServer.Resource.Base.pas',
  MCPServer.Prompt.Base in 'Prompts\MCPServer.Prompt.Base.pas',
  MCPServer.IdHTTPServer in 'Server\MCPServer.IdHTTPServer.pas',
  MCPServer.StdioTransport in 'Server\MCPServer.StdioTransport.pas',
  MCPServer.StdioChannel in 'Server\MCPServer.StdioChannel.pas',
  MCPServer.JsonRpcProcessor in 'Protocol\MCPServer.JsonRpcProcessor.pas',
  MCPServer.CoreManager in 'Managers\MCPServer.CoreManager.pas',
  MCPServer.ToolsManager in 'Managers\MCPServer.ToolsManager.pas',
  MCPServer.ResourcesManager in 'Managers\MCPServer.ResourcesManager.pas',
  MCPServer.PromptsManager in 'Managers\MCPServer.PromptsManager.pas',
  MCPServer.CompletionManager in 'Managers\MCPServer.CompletionManager.pas',
  MCPServer.SubscriptionsManager in 'Managers\MCPServer.SubscriptionsManager.pas',
  MCPServer.Resource.Server in 'Resources\MCPServer.Resource.Server.pas',
  MCPServer.Tool.Echo in 'Tools\MCPServer.Tool.Echo.pas',
  MCPServer.Tool.GetTime in 'Tools\MCPServer.Tool.GetTime.pas',
  MCPServer.Tool.ListFiles in 'Tools\MCPServer.Tool.ListFiles.pas',
  MCPServer.Tool.Calculate in 'Tools\MCPServer.Tool.Calculate.pas',
  MCPServer.Resource.Logs in 'Resources\MCPServer.Resource.Logs.pas',
  MCPServer.Resource.Project in 'Resources\MCPServer.Resource.Project.pas',
  MCPServer.Tool.ContentSamples in 'Tools\MCPServer.Tool.ContentSamples.pas',
  MCPServer.Tool.InputRequiredSamples in 'Tools\MCPServer.Tool.InputRequiredSamples.pas',
  MCPServer.Tool.SubscriptionSamples in 'Tools\MCPServer.Tool.SubscriptionSamples.pas',
  MCPServer.Resource.Samples in 'Resources\MCPServer.Resource.Samples.pas',
  MCPServer.Prompt.SummarizeLogs in 'Prompts\MCPServer.Prompt.SummarizeLogs.pas',
  MCPServer.Prompt.ContentSamples in 'Prompts\MCPServer.Prompt.ContentSamples.pas';

var
  Server: TMCPIdHTTPServer;
  Settings: TMCPSettings;
  ManagerRegistry: IMCPManagerRegistry;
  CoreManager: IMCPCapabilityManager;
  ToolsManager: TMCPToolsManager;
  ResourcesManager: TMCPResourcesManager;
  PromptsManager: TMCPPromptsManager;
  CompletionManager: IMCPCapabilityManager;
  SubscriptionsManager: TMCPSubscriptionsManager;
  ShutdownEvent: TEvent;

{$IFDEF MSWINDOWS}
function ConsoleCtrlHandler(dwCtrlType: DWORD): BOOL; stdcall;
begin
  Result := True;
  case dwCtrlType of
    CTRL_C_EVENT,
    CTRL_BREAK_EVENT,
    CTRL_CLOSE_EVENT,
    CTRL_LOGOFF_EVENT,
    CTRL_SHUTDOWN_EVENT:
    begin
      TLogger.Info('Shutdown signal received');
      if Assigned(ShutdownEvent) then
        ShutdownEvent.SetEvent;
    end;
  end;
end;
{$ENDIF}

{$IFDEF POSIX}
procedure SignalHandler(SigNum: Integer); cdecl;
begin
  TLogger.Info('Signal ' + IntToStr(SigNum) + ' received');
  if Assigned(ShutdownEvent) then
    ShutdownEvent.SetEvent;
end;
{$ENDIF}
  
procedure RunHTTPServer;
begin
  Settings := TMCPSettings.Create;

  TLogger.Info('Delphi MCP Server v' + Settings.ServerVersion);
  TLogger.Info('================================');
  TLogger.Info('Model Context Protocol Server');
  TLogger.Info('Transport: HTTP');
  TLogger.Info('Listening on port ' + Settings.Port.ToString);

  ManagerRegistry := TMCPManagerRegistry.Create;
  CoreManager := TMCPCoreManager.Create(Settings);
  ToolsManager := TMCPToolsManager.Create;
  ResourcesManager := TMCPResourcesManager.Create;
  PromptsManager := TMCPPromptsManager.Create;
  CompletionManager := TMCPCompletionManager.Create(PromptsManager, ResourcesManager);
  SubscriptionsManager := TMCPSubscriptionsManager.Create;
  ToolsManager.ChangeNotifier := SubscriptionsManager;
  ResourcesManager.ChangeNotifier := SubscriptionsManager;
  PromptsManager.ChangeNotifier := SubscriptionsManager;

  ManagerRegistry.RegisterManager(CoreManager);
  ManagerRegistry.RegisterManager(ToolsManager);
  ManagerRegistry.RegisterManager(ResourcesManager);
  ManagerRegistry.RegisterManager(PromptsManager);
  ManagerRegistry.RegisterManager(CompletionManager);
  ManagerRegistry.RegisterManager(SubscriptionsManager);

  Server := TMCPIdHTTPServer.Create(nil);
  try
    Server.Settings := Settings;
    Server.ManagerRegistry := ManagerRegistry;
    Server.CoreManager := CoreManager;
    if Length(Settings.BearerTokenList) > 0 then
      Server.Authorizer := TMCPStaticBearerAuthorizer.Create(Settings.BearerTokenList);

    Server.Start;

    TLogger.Info('Server started. Press CTRL+C to stop...');

    ShutdownEvent.WaitFor(INFINITE);

    TLogger.Info('Shutting down server...');
    Server.Stop;
    TLogger.Info('Server stopped successfully');
  finally
    Server.Free;
    Settings.Free;
  end;
end;

procedure RunStdioServer;
var
  StdioTransport: TMCPStdioTransport;
begin
  // A stdio server is spawned by its client; it reads settings.ini when
  // present but never writes one next to the executable.
  Settings := TMCPSettings.Create('', False);

  TLogger.Info('Delphi MCP Server v' + Settings.ServerVersion);
  TLogger.Info('================================');
  TLogger.Info('Model Context Protocol Server');
  TLogger.Info('Transport: STDIO');

  ManagerRegistry := TMCPManagerRegistry.Create;
  CoreManager := TMCPCoreManager.Create(Settings);
  ToolsManager := TMCPToolsManager.Create;
  ResourcesManager := TMCPResourcesManager.Create;
  PromptsManager := TMCPPromptsManager.Create;
  CompletionManager := TMCPCompletionManager.Create(PromptsManager, ResourcesManager);
  SubscriptionsManager := TMCPSubscriptionsManager.Create;
  ToolsManager.ChangeNotifier := SubscriptionsManager;
  ResourcesManager.ChangeNotifier := SubscriptionsManager;
  PromptsManager.ChangeNotifier := SubscriptionsManager;

  ManagerRegistry.RegisterManager(CoreManager);
  ManagerRegistry.RegisterManager(ToolsManager);
  ManagerRegistry.RegisterManager(ResourcesManager);
  ManagerRegistry.RegisterManager(PromptsManager);
  ManagerRegistry.RegisterManager(CompletionManager);
  ManagerRegistry.RegisterManager(SubscriptionsManager);

  StdioTransport := TMCPStdioTransport.Create(ManagerRegistry, CoreManager);
  try
    StdioTransport.Settings := Settings;
    StdioTransport.Run;
  finally
    StdioTransport.Free;
    Settings.Free;
  end;
end;

function HasStdioFlag: Boolean;
var
  I: Integer;
  Param: string;
begin
  Result := False;
  for I := 1 to ParamCount do
  begin
    Param := ParamStr(I).ToLower;
    if (Param = '--stdio') or (Param = '-stdio') or (Param = '/stdio') then
    begin
      Result := True;
      Break;
    end;
  end;
end;

begin
  // Check if running in STDIO mode before any logging
  if HasStdioFlag then
    TLogger.UseStdErr := True;

  // Configure logger
  TLogger.LogToConsole := True;
  TLogger.MinLogLevel := TLogLevel.Info;

  {$IFDEF DEBUG}
  // The leak report is a dialog on Windows; a stdio server has no place for it.
  ReportMemoryLeaksOnShutdown := not HasStdioFlag;
  {$ENDIF}
  IsMultiThread := True;
  
  // Create shutdown event
  ShutdownEvent := TEvent.Create(nil, True, False, '');
  try
    // Set up signal handlers. Over stdio the client ends the server by
    // closing stdin; a signal keeps its default meaning (terminate) instead
    // of setting an event nobody waits on.
    {$IFDEF MSWINDOWS}
    if not HasStdioFlag then
      SetConsoleCtrlHandler(@ConsoleCtrlHandler, True);
    {$ENDIF}
    
    {$IFDEF POSIX}
    if not HasStdioFlag then
    begin
      signal(SIGINT, @SignalHandler);
      signal(SIGTERM, @SignalHandler);
    end;
    {$ENDIF}
    
    try
      TServerStatusResource.Initialize;

      if HasStdioFlag then
        RunStdioServer
      else
        RunHTTPServer;

    except
      on E: Exception do
        TLogger.Error(E);
    end;
    
    {$IFDEF MSWINDOWS}
    if not HasStdioFlag then
      SetConsoleCtrlHandler(@ConsoleCtrlHandler, False);
    {$ENDIF}
  finally
    ShutdownEvent.Free;
  end;
end.