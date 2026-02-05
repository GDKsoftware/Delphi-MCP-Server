unit MCPServer.StdioTransport;

interface

uses
  System.SysUtils,
  System.Classes,
  MCPServer.Types,
  MCPServer.JsonRpcProcessor,
  MCPServer.Logger;

type
  TMCPStdioTransport = class
  private
    FManagerRegistry: IMCPManagerRegistry;
    FCoreManager: IMCPCapabilityManager;
    FJsonRpcProcessor: TMCPJsonRpcProcessor;
  public
    constructor Create(ManagerRegistry: IMCPManagerRegistry; CoreManager: IMCPCapabilityManager);
    destructor Destroy; override;
    procedure Run;
  end;

implementation

{ TMCPStdioTransport }

constructor TMCPStdioTransport.Create(ManagerRegistry: IMCPManagerRegistry; CoreManager: IMCPCapabilityManager);
begin
  inherited Create;
  FManagerRegistry := ManagerRegistry;
  FCoreManager := CoreManager;
  FJsonRpcProcessor := TMCPJsonRpcProcessor.Create(ManagerRegistry);
end;

destructor TMCPStdioTransport.Destroy;
begin
  FJsonRpcProcessor.Free;
  inherited;
end;

procedure TMCPStdioTransport.Run;
begin
  TLogger.Info('STDIO transport started - reading from stdin, writing to stdout');
  TLogger.Info('Logging to stderr');

  var InputLine := '';
  while not Eof(Input) do
  begin
    try
      Readln(Input, InputLine);

      if InputLine.Trim = '' then
        Continue;

      TLogger.Info('Received: ' + InputLine);

      var Response := FJsonRpcProcessor.ProcessRequest(InputLine, '');

      if Response <> '' then
      begin
        Writeln(Output, Response);
        Flush(Output);
        TLogger.Info('Sent: ' + Response);
      end;

    except
      on E: Exception do
      begin
        TLogger.Error('Error processing STDIO request: ' + E.Message);

        var ErrorResponse := '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"' +
                             E.Message.Replace('"', '\"') + '"}}';
        Writeln(Output, ErrorResponse);
        Flush(Output);
      end;
    end;
  end;

  TLogger.Info('STDIO transport stopped - EOF reached');
end;

end.
