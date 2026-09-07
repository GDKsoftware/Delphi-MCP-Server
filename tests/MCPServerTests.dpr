program MCPServerTests;

{$APPTYPE CONSOLE}
{$STRONGLINKTYPES ON}

uses
  System.SysUtils,
  DUnitX.Loggers.Console,
  DUnitX.Loggers.Xml.NUnit,
  DUnitX.TestFramework,
  MCPServer.Types in '..\src\Protocol\MCPServer.Types.pas',
  MCPServer.Errors in '..\src\Protocol\MCPServer.Errors.pas',
  MCPServer.RequestContext in '..\src\Protocol\MCPServer.RequestContext.pas',
  MCPServer.Capabilities in '..\src\Protocol\MCPServer.Capabilities.pas',
  MCPServer.HttpHeaders in '..\src\Server\MCPServer.HttpHeaders.pas',
  MCPServer.HttpStream in '..\src\Server\MCPServer.HttpStream.pas',
  MCPServer.IdHTTPServer in '..\src\Server\MCPServer.IdHTTPServer.pas',
  MCPServer.Serializer in '..\src\Protocol\MCPServer.Serializer.pas',
  MCPServer.Schema.Generator in '..\src\Protocol\MCPServer.Schema.Generator.pas',
  MCPServer.Schema.Validator in '..\src\Protocol\MCPServer.Schema.Validator.pas',
  MCPServer.ContentBlocks in '..\src\Protocol\MCPServer.ContentBlocks.pas',
  MCPServer.Logger in '..\src\Core\MCPServer.Logger.pas',
  MCPServer.PathBoundary in '..\src\Core\MCPServer.PathBoundary.pas',
  MCPServer.Settings in '..\src\Core\MCPServer.Settings.pas',
  MCPServer.Authorization in '..\src\Core\MCPServer.Authorization.pas',
  MCPServer.Registration in '..\src\Core\MCPServer.Registration.pas',
  MCPServer.ManagerRegistry in '..\src\Core\MCPServer.ManagerRegistry.pas',
  MCPServer.Tool.Base in '..\src\Tools\MCPServer.Tool.Base.pas',
  MCPServer.Resource.Base in '..\src\Resources\MCPServer.Resource.Base.pas',
  MCPServer.Prompt.Base in '..\src\Prompts\MCPServer.Prompt.Base.pas',
  MCPServer.JsonRpcProcessor in '..\src\Protocol\MCPServer.JsonRpcProcessor.pas',
  MCPServer.CoreManager in '..\src\Managers\MCPServer.CoreManager.pas',
  MCPServer.ToolsManager in '..\src\Managers\MCPServer.ToolsManager.pas',
  MCPServer.ResourcesManager in '..\src\Managers\MCPServer.ResourcesManager.pas',
  MCPServer.PromptsManager in '..\src\Managers\MCPServer.PromptsManager.pas',
  MCPServer.CompletionManager in '..\src\Managers\MCPServer.CompletionManager.pas',
  MCPServer.SubscriptionsManager in '..\src\Managers\MCPServer.SubscriptionsManager.pas',
  MCPServer.StdioTransport in '..\src\Server\MCPServer.StdioTransport.pas',
  MCPServer.StdioChannel in '..\src\Server\MCPServer.StdioChannel.pas',
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
  MCPServer.Tool.ContentSamples in '..\src\Tools\MCPServer.Tool.ContentSamples.pas',
  MCPServer.Tool.InputRequiredSamples in '..\src\Tools\MCPServer.Tool.InputRequiredSamples.pas',
  MCPServer.Tool.SubscriptionSamples in '..\src\Tools\MCPServer.Tool.SubscriptionSamples.pas',
  MCPServer.Resource.Samples in '..\src\Resources\MCPServer.Resource.Samples.pas',
  MCPServer.Prompt.SummarizeLogs in '..\src\Prompts\MCPServer.Prompt.SummarizeLogs.pas',
  MCPServer.Prompt.ContentSamples in '..\src\Prompts\MCPServer.Prompt.ContentSamples.pas',
  MCPServer.Tool.Result in '..\src\Tools\MCPServer.Tool.Result.pas',
  MCPServer.Tests.Support in 'MCPServer.Tests.Support.pas',
  MCPServer.Tests.Harness in 'MCPServer.Tests.Harness.pas',
  MCPServer.Tests.Golden in 'MCPServer.Tests.Golden.pas',
  MCPServer.Tests.Golden.Legacy in 'MCPServer.Tests.Golden.Legacy.pas',
  MCPServer.Tests.Constants in 'MCPServer.Tests.Constants.pas',
  MCPServer.Tests.ServerStatus in 'MCPServer.Tests.ServerStatus.pas',
  MCPServer.Tests.Registration in 'MCPServer.Tests.Registration.pas',
  MCPServer.Tests.Logger in 'MCPServer.Tests.Logger.pas',
  MCPServer.Tests.PathBoundary in 'MCPServer.Tests.PathBoundary.pas',
  MCPServer.Tests.RequestContext in 'MCPServer.Tests.RequestContext.pas',
  MCPServer.Tests.Processor in 'MCPServer.Tests.Processor.pas',
  MCPServer.Tests.Capabilities in 'MCPServer.Tests.Capabilities.pas',
  MCPServer.Tests.Golden.Modern in 'MCPServer.Tests.Golden.Modern.pas',
  MCPServer.Tests.HttpHeaders in 'MCPServer.Tests.HttpHeaders.pas',
  MCPServer.Tests.HeaderEncoding in 'MCPServer.Tests.HeaderEncoding.pas',
  MCPServer.Tests.Http in 'MCPServer.Tests.Http.pas',
  MCPServer.Tests.ToolResult in 'MCPServer.Tests.ToolResult.pas',
  MCPServer.Tests.Serializer in 'MCPServer.Tests.Serializer.pas',
  MCPServer.Tests.Marshal in 'MCPServer.Tests.Marshal.pas',
  MCPServer.Tests.Schema in 'MCPServer.Tests.Schema.pas',
  MCPServer.Tests.ToolsManager in 'MCPServer.Tests.ToolsManager.pas',
  MCPServer.Tests.ResourcesManager in 'MCPServer.Tests.ResourcesManager.pas',
  MCPServer.Tests.StdioChannel in 'MCPServer.Tests.StdioChannel.pas',
  MCPServer.Tests.Cancellation in 'MCPServer.Tests.Cancellation.pas',
  MCPServer.Tests.Stdio in 'MCPServer.Tests.Stdio.pas',
  MCPServer.Tests.SchemaValidator in 'MCPServer.Tests.SchemaValidator.pas',
  MCPServer.Tests.Prompt in 'MCPServer.Tests.Prompt.pas',
  MCPServer.Tests.Mrtr in 'MCPServer.Tests.Mrtr.pas',
  MCPServer.Tests.Subscriptions in 'MCPServer.Tests.Subscriptions.pas',
  MCPServer.Tests.Authorization in 'MCPServer.Tests.Authorization.pas',
  MCPServer.Tests.PromptsManager in 'MCPServer.Tests.PromptsManager.pas',
  MCPServer.Tests.CompletionManager in 'MCPServer.Tests.CompletionManager.pas';

procedure RunTests;
begin
  TDUnitX.CheckCommandLine;

  var Runner := TDUnitX.CreateRunner;
  Runner.UseRTTI := True;
  Runner.FailsOnNoAsserts := True;

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
