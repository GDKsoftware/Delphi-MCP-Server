unit StdioOnlyHost.Check;

interface

uses
  MCPServer.StdioHost;

type
  TStdioOnlyHostCheck = class
  strict private
    const ECHO_CALL = '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":{"message":"stdio only"}}}';
    const EXPECTED_ANSWER = 'Echo: stdio only';
    class function AnswerOverStdio: string; static;
    class function AnswerFrom(const Host: TMCPStdioHost): string; static;
    class procedure Report(const Answer: string; const IsAnswered: Boolean); static;

  public
    const EXIT_ANSWERED = 0;
    const EXIT_NOT_ANSWERED = 1;
    class function Run: Integer; static;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  MCPServer.Tool.Base,
  MCPServer.Tool.Echo;

{ TStdioOnlyHostCheck }

class function TStdioOnlyHostCheck.Run: Integer;
begin
  const Answer = AnswerOverStdio;
  const IsAnswered = Answer.Contains(EXPECTED_ANSWER);
  Report(Answer, IsAnswered);

  if IsAnswered then
    Result := EXIT_ANSWERED
  else
    Result := EXIT_NOT_ANSWERED;
end;

class function TStdioOnlyHostCheck.AnswerOverStdio: string;
begin
  const Host = TMCPStdioHost.Create;
  try
    const EchoTool: IMCPTool = TEchoTool.Create;
    Host.AddTool(EchoTool);
    Result := AnswerFrom(Host);
  finally
    Host.Free;
  end;
end;

class function TStdioOnlyHostCheck.AnswerFrom(const Host: TMCPStdioHost): string;
begin
  const RequestBytes = TEncoding.UTF8.GetBytes(ECHO_CALL);
  const Input = TBytesStream.Create(RequestBytes);
  try
    const Output = TBytesStream.Create;
    try
      Host.RunStdioWith(Input, Output);

      const Written = Copy(Output.Bytes, 0, Output.Size);
      Result := TEncoding.UTF8.GetString(Written);
    finally
      Output.Free;
    end;
  finally
    Input.Free;
  end;
end;

class procedure TStdioOnlyHostCheck.Report(const Answer: string; const IsAnswered: Boolean);
begin
  if IsAnswered then
  begin
    Writeln('stdio-only host: answered over stdio without the HTTP transport');
    Exit;
  end;

  const Unexpected = Format('stdio-only host: unexpected answer %s', [Answer]);
  Writeln(Unexpected);
end;

end.
