unit MCPClient.Types;

// Records and enumerations shared by every unit of the MCP client. This unit knows
// nothing about HTTP or JSON-RPC framing; it only describes what a caller hands in and
// what a caller gets back. Protocol constants live in MCPServer.Types so that the client
// and the server can never drift apart on a wire value.

interface

uses
  System.JSON;

const
  MCP_CLIENT_DEFAULT_NAME = 'delphi-mcp-client';
  MCP_CLIENT_DEFAULT_VERSION = '1.0.0';
  MCP_CLIENT_DEFAULT_CONNECT_TIMEOUT_MS = 15000;
  MCP_CLIENT_DEFAULT_RESPONSE_TIMEOUT_MS = 120000;
  MCP_CLIENT_DEFAULT_MAX_INPUT_ROUNDS = 3;
  MCP_CLIENT_DEFAULT_MAX_AUTH_RETRIES = 1;

  MCP_CLIENT_EMPTY_INPUT_SCHEMA = '{"type":"object"}';

type
  {$SCOPEDENUMS ON}
  TMCPClientEra = (Auto, Legacy, Modern);
  {$SCOPEDENUMS OFF}

  TMCPRemoteTool = record
    Name: string;
    Title: string;
    Description: string;
    InputSchemaJson: string;
    OutputSchemaJson: string;
    HasAnnotations: Boolean;
    ReadOnlyHint: Boolean;
    OpenWorldHint: Boolean;
  end;

  TMCPToolCallOutcome = record
    IsError: Boolean;
    Text: string;
    StructuredJson: string;
    ContentJson: string;
    NonTextBlocks: TArray<string>;
    ResultType: string;
    InputRequestsJson: string;
    RequestState: string;
    ErrorCode: Integer;
    ErrorMessage: string;
    RequiredScope: string;
    class function CreateError(const Message: string; const Code: Integer = 0): TMCPToolCallOutcome; static;
  end;

  TMCPClientOptions = record
    Era: TMCPClientEra;
    ClientName: string;
    ClientVersion: string;
    LogLevel: string;
    AcceptEventStream: Boolean;
    ConnectTimeoutMs: Integer;
    ResponseTimeoutMs: Integer;
    MaxInputRounds: Integer;
    MaxAuthRetries: Integer;
    class function Default: TMCPClientOptions; static;
  end;

  TMCPInputResponder = reference to function(const Key, Method: string;
    const Params: TJSONObject): TJSONObject;

implementation

{ TMCPToolCallOutcome }

class function TMCPToolCallOutcome.CreateError(const Message: string; const Code: Integer): TMCPToolCallOutcome;
begin
  Result.IsError := True;
  Result.Text := Message;
  Result.StructuredJson := '';
  Result.ContentJson := '';
  Result.NonTextBlocks := nil;
  Result.ResultType := '';
  Result.InputRequestsJson := '';
  Result.RequestState := '';
  Result.ErrorCode := Code;
  Result.ErrorMessage := Message;
  Result.RequiredScope := '';
end;

{ TMCPClientOptions }

class function TMCPClientOptions.Default: TMCPClientOptions;
begin
  Result.Era := TMCPClientEra.Auto;
  Result.ClientName := MCP_CLIENT_DEFAULT_NAME;
  Result.ClientVersion := MCP_CLIENT_DEFAULT_VERSION;
  Result.LogLevel := '';
  Result.AcceptEventStream := True;
  Result.ConnectTimeoutMs := MCP_CLIENT_DEFAULT_CONNECT_TIMEOUT_MS;
  Result.ResponseTimeoutMs := MCP_CLIENT_DEFAULT_RESPONSE_TIMEOUT_MS;
  Result.MaxInputRounds := MCP_CLIENT_DEFAULT_MAX_INPUT_ROUNDS;
  Result.MaxAuthRetries := MCP_CLIENT_DEFAULT_MAX_AUTH_RETRIES;
end;

end.
