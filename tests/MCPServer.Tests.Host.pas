unit MCPServer.Tests.Host;

interface

uses
  DUnitX.TestFramework,
  System.Rtti,
  System.JSON,
  MCPServer.Tool.Base,
  MCPServer.Host;

type
  TNamedTool = class(TMCPToolBase)
  protected
    function BuildSchema: TJSONObject; override;
    function DoExecute(const Arguments: TJSONObject): TValue; override;
  public
    constructor CreateNamed(const AName: string);
  end;

  [TestFixture]
  TServerHostTests = class
  private
    FHost: TMCPServerHost;
    FOther: TMCPServerHost;
    function ToolNamesOverHttp: TArray<string>;
    function ToolNamesOverStdio(const Host: TMCPServerHost): TArray<string>;
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
    procedure TwoHostsInOneProcess_HaveDisjointToolSets;

    [Test]
    procedure SeedFromGlobalRegistry_TakesTheGlobalTools;

    [Test]
    procedure SeedFromGlobalRegistry_AfterTheManagersExist_IsAConfigurationError;

    [Test]
    procedure RemoveTool_TakesTheToolBackOut;

    [Test]
    procedure StartHttp_OnPortZero_ReportsTheBoundPort;

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
  IdHTTP,
  MCPServer.Errors,
  MCPServer.Registration,
  MCPServer.Tests.Support;

const
  TOOLS_LIST = '{"jsonrpc":"2.0","id":1,"method":"tools/list"}';

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

function TServerHostTests.ToolNamesOverHttp: TArray<string>;
begin
  if not FHost.Active then
    StartOnAnyPort;

  const Http = TIdHTTP.Create(nil);
  const Request = TStringStream.Create(TOOLS_LIST, TEncoding.UTF8);
  try
    Http.Request.ContentType := 'application/json';
    Http.Request.Accept := 'application/json';
    const Url = Format('http://127.0.0.1:%d/mcp', [FHost.BoundPort]);
    Result := ToolNamesOf(Http.Post(Url, Request));
  finally
    Request.Free;
    Http.Free;
  end;
end;

function TServerHostTests.ToolNamesOverStdio(const Host: TMCPServerHost): TArray<string>;
begin
  const Input = TStringStream.Create(TOOLS_LIST + #10, TEncoding.UTF8);
  const Output = TStringStream.Create('', TEncoding.UTF8);
  try
    Host.RunStdioWith(Input, Output);
    const Lines = Output.DataString.Split([#10], TStringSplitOptions.ExcludeEmpty);
    Assert.AreEqual(1, Integer(Length(Lines)), 'stdio answered with more than one line: ' + Output.DataString);
    Result := ToolNamesOf(Lines[0]);
  finally
    Output.Free;
    Input.Free;
  end;
end;

procedure TServerHostTests.Default_PublishesNoToolAtAll;
begin
  Assert.IsTrue(Length(TMCPRegistry.GetToolNames) > 0, 'no tool is registered globally, so the test proves nothing');
  Assert.AreEqual(0, Integer(Length(ToolNamesOverStdio(FHost))), 'a fresh host publishes a tool it was never given');
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

procedure TServerHostTests.SeedFromGlobalRegistry_TakesTheGlobalTools;
begin
  FHost.SeedFromGlobalRegistry := True;
  Assert.AreEqual(Integer(Length(TMCPRegistry.GetToolNames)), Integer(Length(ToolNamesOverStdio(FHost))));
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

procedure TServerHostTests.StartHttp_OnPortZero_ReportsTheBoundPort;
begin
  Assert.AreEqual(0, Integer(FHost.BoundPort), 'a host that never started reports a port');
  StartOnAnyPort;
  Assert.IsTrue(FHost.BoundPort > 0, 'StartHttp on port 0 reports no bound port');
  Assert.IsTrue(FHost.Active);
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
