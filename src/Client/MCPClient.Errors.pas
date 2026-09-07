unit MCPClient.Errors;

// The exceptions the MCP client raises. Nothing a tool can cause ever unwinds a caller's
// loop: a JSON-RPC error from tools/call becomes a TMCPToolCallOutcome instead. These
// exceptions are for the cases where the transport, the handshake or the server
// configuration is wrong, so the caller cannot carry on.
//
// The HTTP status constants that MCPServer.Errors already publishes are reused rather
// than restated; only the three the server unit keeps private are added here.

interface

uses
  System.SysUtils,
  MCPServer.Errors;

const
  HTTP_STATUS_UNAUTHORIZED = 401;
  HTTP_STATUS_METHOD_NOT_ALLOWED = 405;
  HTTP_STATUS_PAYLOAD_TOO_LARGE = 413;

  MCP_CLIENT_BODY_EXCERPT_LENGTH = 200;

type
  EMCPClientError = class(Exception)
  private
    FStatusCode: Integer;
    FErrorCode: Integer;
  public
    constructor Create(const Text: string; const StatusCode: Integer = 0;
      const ErrorCode: Integer = 0); reintroduce;

    class function FromStatus(const StatusCode: Integer; const Body: string): EMCPClientError;
    class function Excerpt(const Body: string): string;

    property StatusCode: Integer read FStatusCode;
    property ErrorCode: Integer read FErrorCode;
  end;

  EMCPClientTransportError = class(EMCPClientError);

  EMCPClientProtocolError = class(EMCPClientError);

  EMCPClientRequestTooLarge = class(EMCPClientError);

  EMCPClientAuthError = class(EMCPClientError)
  private
    FChallenge: string;
  public
    constructor Create(const Text, Challenge: string); reintroduce;
    property Challenge: string read FChallenge;
  end;

  EMCPClientScopeError = class(EMCPClientError)
  private
    FRequiredScope: string;
  public
    constructor Create(const Text, RequiredScope: string); reintroduce;
    property RequiredScope: string read FRequiredScope;
  end;

implementation

const
  MESSAGE_STATUS = 'The server answered HTTP %d: %s';
  ELLIPSIS = '...';

{ EMCPClientError }

constructor EMCPClientError.Create(const Text: string; const StatusCode: Integer;
  const ErrorCode: Integer);
begin
  inherited Create(Text);
  FStatusCode := StatusCode;
  FErrorCode := ErrorCode;
end;

class function EMCPClientError.FromStatus(const StatusCode: Integer; const Body: string): EMCPClientError;
begin
  Result := EMCPClientError.Create(Format(MESSAGE_STATUS, [StatusCode, Excerpt(Body)]), StatusCode);
end;

class function EMCPClientError.Excerpt(const Body: string): string;
begin
  if Length(Body) <= MCP_CLIENT_BODY_EXCERPT_LENGTH then
    Exit(Body);
  Result := Copy(Body, 1, MCP_CLIENT_BODY_EXCERPT_LENGTH) + ELLIPSIS;
end;

{ EMCPClientAuthError }

constructor EMCPClientAuthError.Create(const Text, Challenge: string);
begin
  inherited Create(Text, HTTP_STATUS_UNAUTHORIZED);
  FChallenge := Challenge;
end;

{ EMCPClientScopeError }

constructor EMCPClientScopeError.Create(const Text, RequiredScope: string);
begin
  inherited Create(Text, HTTP_STATUS_FORBIDDEN);
  FRequiredScope := RequiredScope;
end;

end.
