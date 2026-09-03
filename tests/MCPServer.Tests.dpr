program MCPServer.Tests;

{$APPTYPE CONSOLE}
{$STRONGLINKTYPES ON}

uses
  System.SysUtils,
  DUnitX.Loggers.Console,
  DUnitX.Loggers.Xml.NUnit,
  DUnitX.TestFramework,
  MCPServer.Types in '..\src\Protocol\MCPServer.Types.pas',
  MCPServer.Serializer in '..\src\Protocol\MCPServer.Serializer.pas',
  MCPServer.Schema.Generator in '..\src\Protocol\MCPServer.Schema.Generator.pas',
  MCPServer.Logger in '..\src\Core\MCPServer.Logger.pas',
  MCPServer.Settings in '..\src\Core\MCPServer.Settings.pas',
  MCPServer.Registration in '..\src\Core\MCPServer.Registration.pas',
  MCPServer.ManagerRegistry in '..\src\Core\MCPServer.ManagerRegistry.pas',
  MCPServer.Tool.Base in '..\src\Tools\MCPServer.Tool.Base.pas',
  MCPServer.Resource.Base in '..\src\Resources\MCPServer.Resource.Base.pas',
  MCPServer.JsonRpcProcessor in '..\src\Protocol\MCPServer.JsonRpcProcessor.pas',
  MCPServer.CoreManager in '..\src\Managers\MCPServer.CoreManager.pas',
  MCPServer.ToolsManager in '..\src\Managers\MCPServer.ToolsManager.pas',
  MCPServer.ResourcesManager in '..\src\Managers\MCPServer.ResourcesManager.pas',
  // The built-in tools and resources register themselves in their
  // initialization sections. Keep the order identical to MCPServer.dpr so the
  // registry (and therefore tools/list and resources/list) matches the server.
  MCPServer.Resource.Server in '..\src\Resources\MCPServer.Resource.Server.pas',
  MCPServer.Tool.Echo in '..\src\Tools\MCPServer.Tool.Echo.pas',
  MCPServer.Tool.GetTime in '..\src\Tools\MCPServer.Tool.GetTime.pas',
  MCPServer.Tool.ListFiles in '..\src\Tools\MCPServer.Tool.ListFiles.pas',
  MCPServer.Tool.Calculate in '..\src\Tools\MCPServer.Tool.Calculate.pas',
  MCPServer.Resource.Logs in '..\src\Resources\MCPServer.Resource.Logs.pas',
  MCPServer.Resource.Project in '..\src\Resources\MCPServer.Resource.Project.pas',
  MCPServer.Tests.Harness in 'MCPServer.Tests.Harness.pas',
  MCPServer.Tests.Golden in 'MCPServer.Tests.Golden.pas',
  MCPServer.Tests.Golden.Legacy in 'MCPServer.Tests.Golden.Legacy.pas',
  MCPServer.Tests.Constants in 'MCPServer.Tests.Constants.pas',
  MCPServer.Tests.ServerStatus in 'MCPServer.Tests.ServerStatus.pas',
  MCPServer.Tests.Registration in 'MCPServer.Tests.Registration.pas';

procedure RunTests;
begin
  TDUnitX.CheckCommandLine;

  var Runner := TDUnitX.CreateRunner;
  Runner.UseRTTI := True;
  Runner.FailsOnNoAsserts := False;

  if TDUnitX.Options.ConsoleMode <> TDunitXConsoleMode.Off then
    Runner.AddLogger(TDUnitXConsoleLogger.Create(TDUnitX.Options.ConsoleMode = TDunitXConsoleMode.Quiet));

  Runner.AddLogger(TDUnitXXMLNUnitFileLogger.Create(TDUnitX.Options.XMLOutputFile));

  var Results := Runner.Execute;
  if not Results.AllPassed then
    System.ExitCode := EXIT_ERRORS;

  if TDUnitX.Options.ExitBehavior = TDUnitXExitBehavior.Pause then
  begin
    System.Write('Done. Press <Enter> to quit.');
    System.Readln;
  end;
end;

begin
  try
    RunTests;
  except
    on E: Exception do
    begin
      System.Writeln(E.ClassName, ': ', E.Message);
      System.ExitCode := EXIT_ERRORS;
    end;
  end;
end.
