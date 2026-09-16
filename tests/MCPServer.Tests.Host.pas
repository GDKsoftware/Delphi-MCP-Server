unit MCPServer.Tests.Host;

interface

uses
  DUnitX.TestFramework,
  System.Rtti,
  System.JSON,
  MCPServer.Tool.Base,
  MCPServer.Resource.Base,
  MCPServer.Prompt.Base,
  MCPServer.Host;

type
  TNamedTool = class(TMCPToolBase)
  protected
    function BuildSchema: TJSONObject; override;
    function DoExecute(const Arguments: TJSONObject): TValue; override;
  public
    constructor CreateNamed(const AName: string);
  end;

  TNamedResourceData = class
  private
    FValue: string;
  public
    property Value: string read FValue write FValue;
  end;

  TNamedResource = class(TMCPResourceBase<TNamedResourceData>)
  protected
    function GetResourceData: TNamedResourceData; override;
  public
    constructor CreateNamed(const AUri: string);
  end;

  TNamedPromptParams = class
  private
    FText: string;
  public
    property Text: string read FText write FText;
  end;

  TNamedPrompt = class(TMCPPromptBase<TNamedPromptParams>)
  protected
    function ExecuteWithParams(const Params: TNamedPromptParams; Messages: TMCPPromptMessages): string; override;
  public
    constructor CreateNamed(const AName: string);
  end;

  [TestFixture]
  TServerHostTests = class
  private
    FHost: TMCPServerHost;
    FOther: TMCPServerHost;
    function PostTo(const Url: string): string;
    function ToolNamesOverHttp: TArray<string>;
    function NamesOverStdio(const Host: TMCPServerHost;
      const Method, ListKey, NameKey: string): TArray<string>;
    function ToolNamesOverStdio(const Host: TMCPServerHost): TArray<string>;
    function ResourceUrisOverStdio(const Host: TMCPServerHost): TArray<string>;
    function TemplateUrisOverStdio(const Host: TMCPServerHost): TArray<string>;
    function PromptNamesOverStdio(const Host: TMCPServerHost): TArray<string>;
    function ToolNamesOf(const Response: string): TArray<string>;
    procedure StartOnAnyPort;
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    [Test]
    procedure Default_PublishesNoToolAtAll;

    [Test]
    procedure Default_PublishesNoResourceTemplateOrPrompt;

    [Test]
    procedure TwoHostsInOneProcess_HaveDisjointToolSets;

    [Test]
    procedure TwoHostsInOneProcess_HaveDisjointResourceAndPromptSets;

    [Test]
    procedure SeedFromGlobalRegistry_TakesTheGlobalTools;

    [Test]
    procedure SeedFromGlobalRegistry_TakesTheGlobalResourcesTemplatesAndPrompts;

    [Test]
    procedure DiagnosticsResourcesOff_DropsThemFromASeededHost;

    [Test]
    procedure DiagnosticsResourcesOn_KeepsThemOnASeededHost;

    [Test]
    procedure SeedFromGlobalRegistry_AfterTheManagersExist_IsAConfigurationError;

    [Test]
    procedure RemoveTool_TakesTheToolBackOut;

    [Test]
    procedure Create_WithoutSettings_ReadsNoSettingsFile;

    [Test]
    procedure Create_WithASettingsFile_ReadsThatFile;

    [Test]
    procedure Create_WithSettings_UsesThemAndLeavesThemToTheCaller;

    [Test]
    procedure StartHttp_OnPortZero_ReportsTheBoundPort;

    [Test]
    procedure StartHttp_OnPortZero_AnswersTheHostNameOnEveryLoopbackFamily;

    [Test]
    procedure StartHttp_IsIdempotent;

    [Test]
    procedure Stop_IsIdempotent_BeforeAndAfterStart;

    [Test]
    procedure ToolsList_OverHttp_ListsOnlyTheAddedTools;

    [Test]
    procedure ToolsList_OverStdioStreams_ListsTheSameTools;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  IdHTTP,
  IdStack,
  MCPServer.Errors,
  MCPServer.Registration,
  MCPServer.Settings,
  MCPServer.Tests.Support;

const
  TOOLS_LIST = '{"jsonrpc":"2.0","id":1,"method":"tools/list"}';
  URI_SERVER_STATUS = 'server://status';
  URI_LOGS_RECENT = 'logs://recent';
  URI_TEMPLATE_LOGS_BY_LEVEL = 'logs://{level}';
  SETTINGS_WITH_ANOTHER_PORT = '[Server]'#13#10'Port=4242'#13#10;
  ANOTHER_PORT = 4242;
  DEFAULT_PORT = 3000;

{ TNamedTool }

constructor TNamedTool.CreateNamed(const AName: string);
begin
  inherited Create;
  FName := AName;
  FDescription := 'A tool handed to a single host';
end;

function TNamedTool.BuildSchema: TJSONObject;
begin
  Result := TJSONObject.ParseJSONValue(
    '{"type":"object","properties":{},"additionalProperties":false}') as TJSONObject;
end;

function TNamedTool.DoExecute(const Arguments: TJSONObject): TValue;
begin
  Result := TValue.From<string>(FName + ' ran');
end;

{ TNamedResource }

constructor TNamedResource.CreateNamed(const AUri: string);
begin
  inherited Create;
  FURI := AUri;
  FName := 'A resource handed to a single host';
  FMimeType := 'application/json';
end;

function TNamedResource.GetResourceData: TNamedResourceData;
begin
  Result := TNamedResourceData.Create;
  Result.Value := FURI;
end;

{ TNamedPrompt }

constructor TNamedPrompt.CreateNamed(const AName: string);
begin
  inherited Create;
  FName := AName;
  FDescription := 'A prompt handed to a single host';
end;

function TNamedPrompt.ExecuteWithParams(const Params: TNamedPromptParams;
  Messages: TMCPPromptMessages): string;
begin
  Messages.AddText('user', FName);
  Result := FName;
end;

{ TServerHostTests }

procedure TServerHostTests.Setup;
begin
  FHost := TMCPServerHost.Create;
  FHost.Settings.Port := 0;
  FHost.Settings.CorsEnabled := False;
  FOther := nil;
end;

procedure TServerHostTests.TearDown;
begin
  FOther.Free;
  FHost.Free;
end;

procedure TServerHostTests.StartOnAnyPort;
begin
  FHost.StartHttp;
end;

function TServerHostTests.ToolNamesOf(const Response: string): TArray<string>;
begin
  Result := nil;
  const Json = TMCPTestJson.ParseObject(Response);
  try
    const Outcome = Json.GetValue('result') as TJSONObject;
    Assert.IsNotNull(Outcome, 'the response carries no result: ' + Response);
    for var Tool in Outcome.GetValue('tools') as TJSONArray do
    begin
      Result := Result + [(Tool as TJSONObject).GetValue<string>('name')];
    end;
  finally
    Json.Free;
  end;
end;

function TServerHostTests.PostTo(const Url: string): string;
begin
  const Http = TIdHTTP.Create(nil);
  const Request = TStringStream.Create(TOOLS_LIST, TEncoding.UTF8);
  try
    Http.Request.ContentType := 'application/json';
    Http.Request.Accept := 'application/json';
    Result := Http.Post(Url, Request);
  finally
    Request.Free;
    Http.Free;
  end;
end;

function TServerHostTests.ToolNamesOverHttp: TArray<string>;
begin
  if not FHost.Active then
    StartOnAnyPort;

  Result := ToolNamesOf(PostTo(Format('http://127.0.0.1:%d/mcp', [FHost.BoundPort])));
end;

function TServerHostTests.NamesOverStdio(const Host: TMCPServerHost;
  const Method, ListKey, NameKey: string): TArray<string>;
begin
  Result := nil;
  const Request = Format('{"jsonrpc":"2.0","id":1,"method":"%s"}', [Method]);
  const Input = TStringStream.Create(Request + #10, TEncoding.UTF8);
  const Output = TStringStream.Create('', TEncoding.UTF8);
  try
    Host.RunStdioWith(Input, Output);
    const Lines = Output.DataString.Split([#10], TStringSplitOptions.ExcludeEmpty);
    Assert.AreEqual(1, Integer(Length(Lines)), 'stdio answered with more than one line: ' + Output.DataString);

    const Json = TMCPTestJson.ParseObject(Lines[0]);
    try
      const Outcome = Json.GetValue('result') as TJSONObject;
      Assert.IsNotNull(Outcome, 'the response carries no result: ' + Lines[0]);
      for var Entry in Outcome.GetValue(ListKey) as TJSONArray do
      begin
        Result := Result + [(Entry as TJSONObject).GetValue<string>(NameKey)];
      end;
    finally
      Json.Free;
    end;
  finally
    Output.Free;
    Input.Free;
  end;
end;

function TServerHostTests.ToolNamesOverStdio(const Host: TMCPServerHost): TArray<string>;
begin
  Result := NamesOverStdio(Host, 'tools/list', 'tools', 'name');
end;

function TServerHostTests.ResourceUrisOverStdio(const Host: TMCPServerHost): TArray<string>;
begin
  Result := NamesOverStdio(Host, 'resources/list', 'resources', 'uri');
end;

function TServerHostTests.TemplateUrisOverStdio(const Host: TMCPServerHost): TArray<string>;
begin
  Result := NamesOverStdio(Host, 'resources/templates/list', 'resourceTemplates', 'uriTemplate');
end;

function TServerHostTests.PromptNamesOverStdio(const Host: TMCPServerHost): TArray<string>;
begin
  Result := NamesOverStdio(Host, 'prompts/list', 'prompts', 'name');
end;

procedure TServerHostTests.Default_PublishesNoToolAtAll;
begin
  Assert.IsTrue(Length(TMCPRegistry.GetToolNames) > 0, 'no tool is registered globally, so the test proves nothing');
  Assert.AreEqual(0, Integer(Length(ToolNamesOverStdio(FHost))), 'a fresh host publishes a tool it was never given');
end;

procedure TServerHostTests.Default_PublishesNoResourceTemplateOrPrompt;
begin
  Assert.IsTrue(Length(TMCPRegistry.GetResourceURIs) > 0, 'no resource is registered globally, so the test proves nothing');
  Assert.IsTrue(Length(TMCPRegistry.GetResourceTemplateURIs) > 0, 'no resource template is registered globally');
  Assert.IsTrue(Length(TMCPRegistry.GetPromptNames) > 0, 'no prompt is registered globally');

  Assert.AreEqual(0, Integer(Length(ResourceUrisOverStdio(FHost))),
    'a fresh host publishes a resource it was never given');
  Assert.AreEqual(0, Integer(Length(TemplateUrisOverStdio(FHost))),
    'a fresh host publishes a resource template it was never given');
  Assert.AreEqual(0, Integer(Length(PromptNamesOverStdio(FHost))),
    'a fresh host publishes a prompt it was never given');
end;

procedure TServerHostTests.TwoHostsInOneProcess_HaveDisjointToolSets;
begin
  FOther := TMCPServerHost.Create;

  FHost.AddTool(TNamedTool.CreateNamed('first_tool'));
  FOther.AddTool(TNamedTool.CreateNamed('second_tool'));

  Assert.IsTrue(FHost.HasTool('first_tool'));
  Assert.IsFalse(FHost.HasTool('second_tool'), 'the first host sees the second host tool');
  Assert.IsTrue(FOther.HasTool('second_tool'));
  Assert.IsFalse(FOther.HasTool('first_tool'), 'the second host sees the first host tool');

  Assert.AreEqual('first_tool', string.Join(',', ToolNamesOverStdio(FHost)));
  Assert.AreEqual('second_tool', string.Join(',', ToolNamesOverStdio(FOther)));
end;

procedure TServerHostTests.TwoHostsInOneProcess_HaveDisjointResourceAndPromptSets;
begin
  FOther := TMCPServerHost.Create;

  FHost.AddResource(TNamedResource.CreateNamed('first://resource'));
  FHost.AddPrompt(TNamedPrompt.CreateNamed('first_prompt'));
  FOther.AddResource(TNamedResource.CreateNamed('second://resource'));
  FOther.AddPrompt(TNamedPrompt.CreateNamed('second_prompt'));

  Assert.AreEqual('first://resource', string.Join(',', ResourceUrisOverStdio(FHost)));
  Assert.AreEqual('first_prompt', string.Join(',', PromptNamesOverStdio(FHost)));
  Assert.AreEqual('second://resource', string.Join(',', ResourceUrisOverStdio(FOther)));
  Assert.AreEqual('second_prompt', string.Join(',', PromptNamesOverStdio(FOther)));
end;

procedure TServerHostTests.SeedFromGlobalRegistry_TakesTheGlobalTools;
begin
  FHost.SeedFromGlobalRegistry := True;
  Assert.AreEqual(Integer(Length(TMCPRegistry.GetToolNames)), Integer(Length(ToolNamesOverStdio(FHost))));
end;

procedure TServerHostTests.SeedFromGlobalRegistry_TakesTheGlobalResourcesTemplatesAndPrompts;
begin
  FHost.SeedFromGlobalRegistry := True;

  Assert.AreEqual(Integer(Length(TMCPRegistry.GetResourceURIs)),
    Integer(Length(ResourceUrisOverStdio(FHost))));
  Assert.AreEqual(Integer(Length(TMCPRegistry.GetResourceTemplateURIs)),
    Integer(Length(TemplateUrisOverStdio(FHost))));
  Assert.AreEqual(Integer(Length(TMCPRegistry.GetPromptNames)),
    Integer(Length(PromptNamesOverStdio(FHost))));
end;

procedure TServerHostTests.DiagnosticsResourcesOff_DropsThemFromASeededHost;
begin
  FHost.Settings.ExposeDiagnosticsResources := False;
  FHost.SeedFromGlobalRegistry := True;

  const Uris = string.Join(',', ResourceUrisOverStdio(FHost));
  const Templates = string.Join(',', TemplateUrisOverStdio(FHost));

  Assert.IsFalse(Uris.Contains(URI_SERVER_STATUS), URI_SERVER_STATUS + ' survived ExposeDiagnosticsResources=False');
  Assert.IsFalse(Uris.Contains(URI_LOGS_RECENT), URI_LOGS_RECENT + ' survived ExposeDiagnosticsResources=False');
  Assert.IsFalse(Templates.Contains(URI_TEMPLATE_LOGS_BY_LEVEL),
    URI_TEMPLATE_LOGS_BY_LEVEL + ' survived ExposeDiagnosticsResources=False');
  Assert.IsTrue(Uris <> '', 'the setting emptied the resource list instead of hiding the diagnostics');
end;

procedure TServerHostTests.DiagnosticsResourcesOn_KeepsThemOnASeededHost;
begin
  FHost.SeedFromGlobalRegistry := True;

  const Uris = string.Join(',', ResourceUrisOverStdio(FHost));
  const Templates = string.Join(',', TemplateUrisOverStdio(FHost));

  Assert.IsTrue(FHost.Settings.ExposeDiagnosticsResources, 'the diagnostics resources are exposed by default');
  Assert.IsTrue(Uris.Contains(URI_SERVER_STATUS), URI_SERVER_STATUS + ' is missing from a seeded host');
  Assert.IsTrue(Uris.Contains(URI_LOGS_RECENT), URI_LOGS_RECENT + ' is missing from a seeded host');
  Assert.IsTrue(Templates.Contains(URI_TEMPLATE_LOGS_BY_LEVEL),
    URI_TEMPLATE_LOGS_BY_LEVEL + ' is missing from a seeded host');
end;

procedure TServerHostTests.SeedFromGlobalRegistry_AfterTheManagersExist_IsAConfigurationError;
begin
  FHost.AddTool(TNamedTool.CreateNamed('first_tool'));
  Assert.WillRaise(
    procedure
    begin
      FHost.SeedFromGlobalRegistry := True;
    end, EMCPConfigurationError);
end;

procedure TServerHostTests.RemoveTool_TakesTheToolBackOut;
begin
  FHost.AddTool(TNamedTool.CreateNamed('first_tool'));
  FHost.RemoveTool('first_tool');
  Assert.IsFalse(FHost.HasTool('first_tool'));
  Assert.AreEqual(0, Integer(Length(ToolNamesOverStdio(FHost))));
end;

procedure TServerHostTests.Create_WithoutSettings_ReadsNoSettingsFile;
begin
  const NextToTheExecutable = TPath.Combine(TPath.GetDirectoryName(ParamStr(0)), 'settings.ini');
  const AlreadyThere = TFile.Exists(NextToTheExecutable);
  var Saved := '';
  if AlreadyThere then
    Saved := TFile.ReadAllText(NextToTheExecutable);

  TFile.WriteAllText(NextToTheExecutable, SETTINGS_WITH_ANOTHER_PORT);
  try
    const Host = TMCPServerHost.Create;
    try
      Assert.AreEqual('', Host.Settings.SettingsFile, 'a host given no settings named a settings file');
      Assert.AreEqual<Integer>(DEFAULT_PORT, Host.Settings.Port,
        'a host given no settings read settings.ini from the executable directory');
    finally
      Host.Free;
    end;
  finally
    if AlreadyThere then
      TFile.WriteAllText(NextToTheExecutable, Saved)
    else
      TFile.Delete(NextToTheExecutable);
  end;
end;

procedure TServerHostTests.Create_WithASettingsFile_ReadsThatFile;
begin
  const Directory = TPath.Combine(TPath.GetTempPath, 'mcp-host-' + TGuid.NewGuid.ToString);
  TDirectory.CreateDirectory(Directory);
  try
    const Path = TPath.Combine(Directory, 'settings.ini');
    TFile.WriteAllText(Path, SETTINGS_WITH_ANOTHER_PORT);

    const Host = TMCPServerHost.Create(Path);
    try
      Assert.AreEqual(Path, Host.Settings.SettingsFile);
      Assert.AreEqual<Integer>(ANOTHER_PORT, Host.Settings.Port, 'the host ignored the settings file it was given');
    finally
      Host.Free;
    end;
  finally
    TDirectory.Delete(Directory, True);
  end;
end;

procedure TServerHostTests.Create_WithSettings_UsesThemAndLeavesThemToTheCaller;
begin
  const Settings = TMCPSettings.CreateDefaults;
  try
    Settings.Port := ANOTHER_PORT;

    const Host = TMCPServerHost.Create(Settings);
    try
      Assert.AreEqual<Integer>(ANOTHER_PORT, Host.Settings.Port, 'the host ignored the settings it was given');
    finally
      Host.Free;
    end;

    Assert.AreEqual<Integer>(ANOTHER_PORT, Settings.Port, 'the settings did not survive the host');
  finally
    Settings.Free;
  end;
end;

procedure TServerHostTests.StartHttp_OnPortZero_ReportsTheBoundPort;
begin
  Assert.AreEqual(0, Integer(FHost.BoundPort), 'a host that never started reports a port');
  StartOnAnyPort;
  Assert.IsTrue(FHost.BoundPort > 0, 'StartHttp on port 0 reports no bound port');
  Assert.IsTrue(FHost.Active);
end;

procedure TServerHostTests.StartHttp_OnPortZero_AnswersTheHostNameOnEveryLoopbackFamily;
begin
  FHost.AddTool(TNamedTool.CreateNamed('first_tool'));
  StartOnAnyPort;

  Assert.AreEqual('first_tool',
    string.Join(',', ToolNamesOf(PostTo(Format('http://localhost:%d/mcp', [FHost.BoundPort])))),
    'the host name does not answer on the port the host reports');

  if not GStack.SupportsIPv6 then
    Exit;

  Assert.AreEqual('first_tool',
    string.Join(',', ToolNamesOf(PostTo(Format('http://[::1]:%d/mcp', [FHost.BoundPort])))),
    'the IPv6 loopback, which localhost resolves to first on Windows, listens on another port');
end;

procedure TServerHostTests.StartHttp_IsIdempotent;
begin
  StartOnAnyPort;
  const FirstPort = FHost.BoundPort;
  FHost.StartHttp;
  Assert.AreEqual(Integer(FirstPort), Integer(FHost.BoundPort), 'the second StartHttp rebound the server');
  Assert.IsTrue(FHost.Active);
  Assert.AreEqual(0, Integer(Length(ToolNamesOverHttp)), 'the server stopped answering after the second StartHttp');
end;

procedure TServerHostTests.Stop_IsIdempotent_BeforeAndAfterStart;
begin
  FHost.Stop;
  Assert.IsFalse(FHost.Active);

  StartOnAnyPort;
  FHost.Stop;
  FHost.Stop;
  Assert.IsFalse(FHost.Active);
end;

procedure TServerHostTests.ToolsList_OverHttp_ListsOnlyTheAddedTools;
begin
  FHost.AddTool(TNamedTool.CreateNamed('first_tool'));
  FHost.AddTool(TNamedTool.CreateNamed('second_tool'));
  Assert.AreEqual('first_tool,second_tool', string.Join(',', ToolNamesOverHttp));
end;

procedure TServerHostTests.ToolsList_OverStdioStreams_ListsTheSameTools;
begin
  FHost.AddTool(TNamedTool.CreateNamed('first_tool'));
  FHost.AddTool(TNamedTool.CreateNamed('second_tool'));

  const OverHttp = string.Join(',', ToolNamesOverHttp);
  const OverStdio = string.Join(',', ToolNamesOverStdio(FHost));
  Assert.AreEqual('first_tool,second_tool', OverStdio);
  Assert.AreEqual(OverHttp, OverStdio, 'HTTP and stdio disagree about the tool set');
end;

end.
