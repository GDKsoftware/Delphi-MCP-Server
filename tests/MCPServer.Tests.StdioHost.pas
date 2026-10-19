unit MCPServer.Tests.StdioHost;

interface

uses
  DUnitX.TestFramework,
  MCPServer.StdioHost;

type
  [TestFixture]
  TStdioHostTests = class
  private
    FHost: TMCPStdioHost;
    function AnswerOverStdio(const Host: TMCPStdioHost; const Request: string): string;

  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    [Test]
    procedure RunStdioWith_ToolItWasHanded_IsListed;

    [Test]
    procedure RunStdioWith_ToolItWasHanded_IsCalled;

    [Test]
    procedure RunStdioWith_HandlerThatOutlivesTheTransport_DropsItsLateResult;

    [Test]
    procedure ServerHost_RunStdioWith_AnswersOverStdio;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Base,
  MCPServer.Host,
  MCPServer.Tool.Echo,
  MCPServer.Tests.Support,
  MCPServer.Tests.StdioDoubles;

const
  TOOLS_LIST     = '{"jsonrpc":"2.0","id":1,"method":"tools/list"}';
  ECHO_CALL      = '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"message":"over stdio"}}}';
  STUBBORN_CALL  = '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"' + STUBBORN_TOOL_NAME + '","arguments":{}}}';
  ECHO_ANSWER    = 'Echo: over stdio';
  FIRST_TEXT     = 'result.content[0].text';
  SHORT_DRAIN_MS = 100;

{ TStdioHostTests }

procedure TStdioHostTests.Setup;
begin
  FHost := TMCPStdioHost.Create;
  const EchoTool: IMCPTool = TEchoTool.Create;
  FHost.AddTool(EchoTool);
end;

procedure TStdioHostTests.TearDown;
begin
  FHost.Free;
end;

function TStdioHostTests.AnswerOverStdio(const Host: TMCPStdioHost; const Request: string): string;
begin
  const RequestBytes = TEncoding.UTF8.GetBytes(Request);
  const Input = TBytesStream.Create(RequestBytes);
  try
    const Output = TBytesStream.Create;
    try
      Host.RunStdioWith(Input, Output);

      const Written = Copy(Output.Bytes, 0, Output.Size);
      const Text = TEncoding.UTF8.GetString(Written);
      Result := Text.Trim;
    finally
      Output.Free;
    end;
  finally
    Input.Free;
  end;
end;

procedure TStdioHostTests.RunStdioWith_ToolItWasHanded_IsListed;
begin
  const Answer = AnswerOverStdio(FHost, TOOLS_LIST);

  const Json = TMCPTestJson.ParseObject(Answer);
  try
    const Tools = Json.GetValue<TJSONArray>('result.tools');
    const ToolName = Json.GetValue<string>('result.tools[0].name');
    Assert.AreEqual(1, Tools.Count, 'a stdio host publishes what it was handed');
    Assert.AreEqual('echo', ToolName);
  finally
    Json.Free;
  end;
end;

procedure TStdioHostTests.RunStdioWith_ToolItWasHanded_IsCalled;
begin
  const Answer = AnswerOverStdio(FHost, ECHO_CALL);

  const Json = TMCPTestJson.ParseObject(Answer);
  try
    const Text = Json.GetValue<string>(FIRST_TEXT);
    Assert.AreEqual(ECHO_ANSWER, Text);
  finally
    Json.Free;
  end;
end;

procedure TStdioHostTests.RunStdioWith_HandlerThatOutlivesTheTransport_DropsItsLateResult;
begin
  FHost.Settings.StdioShutdownDrainMs := SHORT_DRAIN_MS;
  const Gate: IStubbornGate = TStubbornGate.Create;
  const StubbornTool: IMCPTool = TStubbornTool.Create(Gate);
  FHost.AddTool(StubbornTool);
  const LateAnswers = TMCPTestLogWatch.Create(LATE_ANSWER_LOG_FRAGMENT);
  try
    const Answer = AnswerOverStdio(FHost, STUBBORN_CALL);
    Gate.Release;
    const HasReturned = Gate.WaitUntilReturned;
    const IsDropped = LateAnswers.WaitForMatch;

    const Json = TMCPTestJson.ParseObject(Answer);
    try
      const Code = Json.GetValue<Integer>('error.code');
      Assert.IsTrue(HasReturned, 'the stubborn tool returned once it was released');
      Assert.IsTrue(IsDropped, 'the host had freed its transport, and the late result was still dropped safely');
      Assert.AreEqual(JSONRPC_INTERNAL_ERROR, Code, Answer);
    finally
      Json.Free;
    end;
  finally
    LateAnswers.Free;
  end;
end;

procedure TStdioHostTests.ServerHost_RunStdioWith_AnswersOverStdio;
begin
  const ServerHost = TMCPServerHost.Create;
  try
    const EchoTool: IMCPTool = TEchoTool.Create;
    ServerHost.AddTool(EchoTool);

    const Answer = AnswerOverStdio(ServerHost, ECHO_CALL);

    const Json = TMCPTestJson.ParseObject(Answer);
    try
      const Text = Json.GetValue<string>(FIRST_TEXT);
      Assert.AreEqual(ECHO_ANSWER, Text, 'the HTTP host keeps serving stdio');
    finally
      Json.Free;
    end;
  finally
    ServerHost.Free;
  end;
end;

end.
