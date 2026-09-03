unit MCPServer.StdioTransport;

interface

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
  MCPServer.Types,
  MCPServer.Settings,
  MCPServer.RequestContext,
  MCPServer.JsonRpcProcessor,
  MCPServer.Logger;

type
  TMCPStdioTransport = class
  private
    FManagerRegistry: IMCPManagerRegistry;
    FCoreManager: IMCPCapabilityManager;
    FJsonRpcProcessor: TMCPJsonRpcProcessor;
    FLegacySession: TMCPLegacySession;
    function GetSettings: TMCPSettings;
    procedure SetSettings(const Value: TMCPSettings);
  public
    constructor Create(ManagerRegistry: IMCPManagerRegistry; CoreManager: IMCPCapabilityManager);
    destructor Destroy; override;
    procedure Run;
    /// Server identity and protocol options; assign before Run. Without it the
    /// processor uses the defaults (settings.ini next to the executable).
    property Settings: TMCPSettings read GetSettings write SetSettings;
  end;

implementation

{ TMCPStdioTransport }

constructor TMCPStdioTransport.Create(ManagerRegistry: IMCPManagerRegistry; CoreManager: IMCPCapabilityManager);
begin
  inherited Create;
  FManagerRegistry := ManagerRegistry;
  FCoreManager := CoreManager;
  FJsonRpcProcessor := TMCPJsonRpcProcessor.Create(ManagerRegistry);
  FLegacySession := TMCPLegacySession.Create;

  // stdout carries MCP messages only; every log line must go to stderr,
  // also for library consumers that never set UseStdErr themselves.
  TLogger.UseStdErr := True;
  TLogger.StdoutReserved := True;
end;

destructor TMCPStdioTransport.Destroy;
begin
  FJsonRpcProcessor.Free;
  FLegacySession.Free;
  inherited;
end;

function TMCPStdioTransport.GetSettings: TMCPSettings;
begin
  Result := FJsonRpcProcessor.Settings;
end;

procedure TMCPStdioTransport.SetSettings(const Value: TMCPSettings);
begin
  FJsonRpcProcessor.Settings := Value;
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

      Response := FJsonRpcProcessor.ProcessRequestEx(InputLine, TMCPTransportHints.ForStdio(FLegacySession)).Body;

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
