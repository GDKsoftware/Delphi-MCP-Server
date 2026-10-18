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
    function AnswerOverStdio(const Request: string): string;
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
    procedure ServerHost_IsAStdioHost_SoExistingHostsKeepServingStdio;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
  MCPServer.Host,
  MCPServer.Tool.Echo;

const
  TOOLS_LIST = '{"jsonrpc":"2.0","id":1,"method":"tools/list"}';
  ECHO_CALL = '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"message":"over stdio"}}}';

{ TStdioHostTests }

procedure TStdioHostTests.Setup;
begin
  FHost := TMCPStdioHost.Create;
  FHost.AddTool(TEchoTool.Create);
end;

procedure TStdioHostTests.TearDown;
begin
  FHost.Free;
end;

function TStdioHostTests.AnswerOverStdio(const Request: string): string;
begin
  const RequestBytes = TEncoding.UTF8.GetBytes(Request + #10);
  const Input = TBytesStream.Create(RequestBytes);
  const Output = TBytesStream.Create;
  try
    FHost.RunStdioWith(Input, Output);

    const Written = Copy(Output.Bytes, 0, Output.Size);
    const Text = TEncoding.UTF8.GetString(Written);
    Result := Text.Trim;
  finally
    Output.Free;
    Input.Free;
  end;
end;

procedure TStdioHostTests.RunStdioWith_ToolItWasHanded_IsListed;
begin
  const Answer = AnswerOverStdio(TOOLS_LIST);

  const Json = TJSONObject.ParseJSONValue(Answer) as TJSONObject;
  try
    Assert.IsNotNull(Json, Answer);
    Assert.AreEqual(1, Json.GetValue<TJSONArray>('result.tools').Count, 'a stdio host publishes what it was handed');
    Assert.AreEqual('echo', Json.GetValue<string>('result.tools[0].name'));
  finally
    Json.Free;
  end;
end;

procedure TStdioHostTests.RunStdioWith_ToolItWasHanded_IsCalled;
begin
  const Answer = AnswerOverStdio(ECHO_CALL);

  const Json = TJSONObject.ParseJSONValue(Answer) as TJSONObject;
  try
    Assert.IsNotNull(Json, Answer);
    Assert.AreEqual('Echo: over stdio', Json.GetValue<string>('result.content[0].text'));
  finally
    Json.Free;
  end;
end;

procedure TStdioHostTests.ServerHost_IsAStdioHost_SoExistingHostsKeepServingStdio;
begin
  const IsAStdioHost = TMCPServerHost.InheritsFrom(TMCPStdioHost);

  Assert.IsTrue(IsAStdioHost, 'TMCPServerHost adds the HTTP transport to the stdio host');
end;

end.
