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
  MCPServer.Serializer in 'Protocol\MCPServer.Serializer.pas',
  MCPServer.Schema.Generator in 'Protocol\MCPServer.Schema.Generator.pas',
  MCPServer.Logger in 'Core\MCPServer.Logger.pas',
  MCPServer.Settings in 'Core\MCPServer.Settings.pas',
  MCPServer.Registration in 'Core\MCPServer.Registration.pas',
  MCPServer.ManagerRegistry in 'Core\MCPServer.ManagerRegistry.pas',
  MCPServer.Tool.Base in 'Tools\MCPServer.Tool.Base.pas',
  MCPServer.Resource.Base in 'Resources\MCPServer.Resource.Base.pas',
  MCPServer.IdHTTPServer in 'Server\MCPServer.IdHTTPServer.pas',
  MCPServer.CoreManager in 'Managers\MCPServer.CoreManager.pas',
  MCPServer.ToolsManager in 'Managers\MCPServer.ToolsManager.pas',
  MCPServer.ResourcesManager in 'Managers\MCPServer.ResourcesManager.pas',
  MCPServer.Resource.Server in 'Resources\MCPServer.Resource.Server.pas',
  MCPServer.Tool.Echo in 'Tools\MCPServer.Tool.Echo.pas',
  MCPServer.Tool.GetTime in 'Tools\MCPServer.Tool.GetTime.pas',
  MCPServer.Tool.ListFiles in 'Tools\MCPServer.Tool.ListFiles.pas',
  MCPServer.Tool.Calculate in 'Tools\MCPServer.Tool.Calculate.pas',
  MCPServer.Resource.Logs in 'Resources\MCPServer.Resource.Logs.pas',
  MCPServer.Resource.Project in 'Resources\MCPServer.Resource.Project.pas';

var
  Server: TMCPIdHTTPServer;
  Settings: TMCPSettings;
  ManagerRegistry: IMCPManagerRegistry;
  CoreManager: IMCPCapabilityManager;
  ToolsManager: IMCPCapabilityManager;
  ResourcesManager: IMCPCapabilityManager;
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
  
procedure RunServer;
begin
  // Load settings
  Settings := TMCPSettings.Create;
  
  TLogger.Info('Delphi MCP Server v' + Settings.ServerVersion);
  TLogger.Info('================================');
  TLogger.Info('Model Context Protocol Server');
  
  TLogger.Info('Listening on port ' + Settings.Port.ToString);
  
  // Create managers
  ManagerRegistry := TMCPManagerRegistry.Create;
  CoreManager := TMCPCoreManager.Create(Settings);
  ToolsManager := TMCPToolsManager.Create;
  ResourcesManager := TMCPResourcesManager.Create;
  
  // Register managers
  ManagerRegistry.RegisterManager(CoreManager);
  ManagerRegistry.RegisterManager(ToolsManager);
  ManagerRegistry.RegisterManager(ResourcesManager);
  
  // Create and configure server
  Server := TMCPIdHTTPServer.Create(nil);
  try
    Server.Settings := Settings;
    Server.ManagerRegistry := ManagerRegistry;
    Server.CoreManager := CoreManager;
    
    // Start server
    Server.Start;
    
    TLogger.Info('Server started. Press CTRL+C to stop...');
    
    // Wait for shutdown signal
    ShutdownEvent.WaitFor(INFINITE);
    
    // Graceful shutdown
    TLogger.Info('Shutting down server...');
    Server.Stop;
    TLogger.Info('Server stopped successfully');
  finally
    Server.Free;
    Settings.Free;
  end;
end;

begin
  // Configure logger
  TLogger.LogToConsole := True;
  TLogger.MinLogLevel := TLogLevel.Info;
  
  ReportMemoryLeaksOnShutdown := True;
  IsMultiThread := True;
  
  // Create shutdown event
  ShutdownEvent := TEvent.Create(nil, True, False, '');
  try
    // Set up signal handlers
    {$IFDEF MSWINDOWS}
    SetConsoleCtrlHandler(@ConsoleCtrlHandler, True);
    {$ENDIF}
    
    {$IFDEF POSIX}
    signal(SIGINT, @SignalHandler);
    signal(SIGTERM, @SignalHandler);
    {$ENDIF}
    
    try
      TServerStatusResource.Initialize;
      RunServer;
    except
      on E: Exception do
        TLogger.Error(E);
    end;
    
    {$IFDEF MSWINDOWS}
    SetConsoleCtrlHandler(@ConsoleCtrlHandler, False);
    {$ENDIF}
  finally
    ShutdownEvent.Free;
  end;
end.