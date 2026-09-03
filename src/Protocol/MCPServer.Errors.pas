unit MCPServer.Errors;

interface

uses
  System.SysUtils,
  System.JSON;

type
  /// A JSON-RPC error a handler or the processor wants to send back.
  ///
  /// Code and Message become the error object; Data (owned, optional) becomes
  /// error.data. HttpStatus is the status a modern HTTP response must carry;
  /// 0 leaves the decision to the processor's status policy.
  EMCPError = class(Exception)
  private
    FCode: Integer;
    FData: TJSONValue;
    FHttpStatus: Integer;
  public
    constructor Create(ACode: Integer; const AMessage: string; AData: TJSONValue = nil;
      AHttpStatus: Integer = 0); reintroduce;
    destructor Destroy; override;

    /// Hands the data object to the caller; the exception no longer owns it.
    function DetachData: TJSONValue;

    class function ParseError(const AMessage: string): EMCPError;
    class function InvalidRequest(const AMessage: string): EMCPError;
    class function MethodNotFound(const Method: string): EMCPError;
    class function InvalidParams(const AMessage: string; AData: TJSONValue = nil): EMCPError;
    class function InternalError(const AMessage: string): EMCPError;
    /// -32020 (HTTP 400): headers missing or different from the body.
    class function HeaderMismatch(const AMessage: string): EMCPError;
    /// -32021 (HTTP 400): the client did not declare a capability the request needs.
    class function MissingRequiredClientCapability(const RequiredCapabilities: TJSONObject): EMCPError;
    /// -32022 (HTTP 400): the requested revision is not served.
    class function UnsupportedProtocolVersion(const Requested: string; const Supported: TArray<string>): EMCPError;

    property Code: Integer read FCode;
    property Data: TJSONValue read FData;
    property HttpStatus: Integer read FHttpStatus write FHttpStatus;
  end;

const
  HTTP_STATUS_OK = 200;
  HTTP_STATUS_ACCEPTED = 202;
  HTTP_STATUS_BAD_REQUEST = 400;
  HTTP_STATUS_NOT_FOUND = 404;

implementation

uses
  MCPServer.Types;

{ EMCPError }

constructor EMCPError.Create(ACode: Integer; const AMessage: string; AData: TJSONValue; AHttpStatus: Integer);
begin
  inherited Create(AMessage);
  FCode := ACode;
  FData := AData;
  FHttpStatus := AHttpStatus;
end;

destructor EMCPError.Destroy;
begin
  FData.Free;
  inherited;
end;

function EMCPError.DetachData: TJSONValue;
begin
  Result := FData;
  FData := nil;
end;

class function EMCPError.ParseError(const AMessage: string): EMCPError;
begin
  Result := EMCPError.Create(JSONRPC_PARSE_ERROR, AMessage);
end;

class function EMCPError.InvalidRequest(const AMessage: string): EMCPError;
begin
  Result := EMCPError.Create(JSONRPC_INVALID_REQUEST, AMessage);
end;

class function EMCPError.MethodNotFound(const Method: string): EMCPError;
begin
  Result := EMCPError.Create(JSONRPC_METHOD_NOT_FOUND,
    Format('Method [%s] not found. The method does not exist or is not available.', [Method]));
end;

class function EMCPError.InvalidParams(const AMessage: string; AData: TJSONValue): EMCPError;
begin
  Result := EMCPError.Create(JSONRPC_INVALID_PARAMS, AMessage, AData);
end;

class function EMCPError.InternalError(const AMessage: string): EMCPError;
begin
  Result := EMCPError.Create(JSONRPC_INTERNAL_ERROR, AMessage);
end;

class function EMCPError.HeaderMismatch(const AMessage: string): EMCPError;
begin
  Result := EMCPError.Create(MCP_ERROR_HEADER_MISMATCH, AMessage, nil, HTTP_STATUS_BAD_REQUEST);
end;

class function EMCPError.MissingRequiredClientCapability(const RequiredCapabilities: TJSONObject): EMCPError;
begin
  var Data := TJSONObject.Create;
  Data.AddPair('requiredCapabilities', RequiredCapabilities);
  Result := EMCPError.Create(MCP_ERROR_MISSING_REQUIRED_CLIENT_CAPABILITY,
    'Missing required client capability', Data, HTTP_STATUS_BAD_REQUEST);
end;

class function EMCPError.UnsupportedProtocolVersion(const Requested: string; const Supported: TArray<string>): EMCPError;
begin
  var SupportedArray := TJSONArray.Create;
  for var Version in Supported do
    SupportedArray.Add(Version);

  var Data := TJSONObject.Create;
  Data.AddPair('supported', SupportedArray);
  Data.AddPair('requested', Requested);

  Result := EMCPError.Create(MCP_ERROR_UNSUPPORTED_PROTOCOL_VERSION,
    'Unsupported protocol version', Data, HTTP_STATUS_BAD_REQUEST);
end;

end.
