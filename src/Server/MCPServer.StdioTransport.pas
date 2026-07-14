unit MCPServer.StdioTransport;

interface

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
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
var
  ErrorJson: TJSONObject;
  ErrorObj: TJSONObject;
  InputLine: string;
  Response: string;
begin
  TLogger.Info('STDIO transport started - reading from stdin, writing to stdout');
  TLogger.Info('Logging to stderr');

  InputLine := '';
  while not Eof(Input) do
  begin
    try
      Readln(Input, InputLine);

      if InputLine.Trim = '' then
        Continue;

      TLogger.Info('Received: ' + InputLine);

      Response := FJsonRpcProcessor.ProcessRequest(InputLine, '');

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

        // Build the error response with the JSON writer: hand-concatenated
        // JSON with only '"' replaced emits invalid JSON whenever the message
        // contains a backslash (e.g. a Windows path) or a control character.
        ErrorJson := TJSONObject.Create;
        try
          ErrorJson.AddPair('jsonrpc', '2.0');
          ErrorJson.AddPair('id', TJSONNull.Create);
          ErrorObj := TJSONObject.Create;
          ErrorJson.AddPair('error', ErrorObj);
          ErrorObj.AddPair('code', TJSONNumber.Create(JSONRPC_INTERNAL_ERROR));
          ErrorObj.AddPair('message', E.Message);
          Writeln(Output, ErrorJson.ToJSON);
        finally
          ErrorJson.Free;
        end;
        Flush(Output);
      end;
    end;
  end;

  TLogger.Info('STDIO transport stopped - EOF reached');
end;

end.
