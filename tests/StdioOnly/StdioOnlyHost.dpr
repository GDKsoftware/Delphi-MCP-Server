program StdioOnlyHost;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  MCPServer.StdioHost,
  MCPServer.Tool.Echo;

const
  ECHO_CALL = '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":{"message":"stdio only"}}}';
  EXPECTED_ANSWER = 'Echo: stdio only';
  EXIT_NOT_ANSWERED = 1;

begin
  const Host = TMCPStdioHost.Create;
  const Input = TBytesStream.Create(TEncoding.UTF8.GetBytes(ECHO_CALL + #10));
  const Output = TBytesStream.Create;
  try
    Host.AddTool(TEchoTool.Create);
    Host.RunStdioWith(Input, Output);

    const Written = Copy(Output.Bytes, 0, Output.Size);
    const Answer = TEncoding.UTF8.GetString(Written);
    const IsAnswered = Answer.Contains(EXPECTED_ANSWER);
    if IsAnswered then
      Writeln('stdio-only host: answered over stdio without the HTTP transport')
    else
    begin
      Writeln(Format('stdio-only host: unexpected answer %s', [Answer]));
      ExitCode := EXIT_NOT_ANSWERED;
    end;
  finally
    Output.Free;
    Input.Free;
    Host.Free;
  end;
end.
