unit MCPServer.Types;

interface

uses
  System.SysUtils,
  System.JSON,
  System.Rtti;

const
  /// Protocol version answered by the initialize handshake. Kept under its
  /// historic name for library consumers.
  MCP_PROTOCOL_VERSION = '2025-06-18';

  // Protocol revisions
  MCP_PROTOCOL_VERSION_2025_03_26 = '2025-03-26';
  MCP_PROTOCOL_VERSION_2025_06_18 = '2025-06-18';
  MCP_PROTOCOL_VERSION_2025_11_25 = '2025-11-25';
  MCP_PROTOCOL_VERSION_2026_07_28 = '2026-07-28';

  /// Newest revision this server targets (stateless, per-request _meta).
  MCP_LATEST_PROTOCOL_VERSION = MCP_PROTOCOL_VERSION_2026_07_28;
  /// Newest revision served through the initialize handshake.
  MCP_LATEST_LEGACY_PROTOCOL_VERSION = MCP_PROTOCOL_VERSION_2025_11_25;

  MCP_LEGACY_PROTOCOL_VERSIONS: array[0..1] of string = (
    MCP_PROTOCOL_VERSION_2025_06_18,
    MCP_PROTOCOL_VERSION_2025_11_25
  );
  MCP_MODERN_PROTOCOL_VERSIONS: array[0..0] of string = (
    MCP_PROTOCOL_VERSION_2026_07_28
  );

  // JSON-RPC 2.0 error codes
  JSONRPC_PARSE_ERROR = -32700;
  JSONRPC_INVALID_REQUEST = -32600;
  JSONRPC_METHOD_NOT_FOUND = -32601;
  JSONRPC_INVALID_PARAMS = -32602;
  JSONRPC_INTERNAL_ERROR = -32603;

  // MCP error codes reserved by the specification (basic/index.mdx, "Error Codes")
  MCP_ERROR_HEADER_MISMATCH = -32020;
  MCP_ERROR_MISSING_REQUIRED_CLIENT_CAPABILITY = -32021;
  MCP_ERROR_UNSUPPORTED_PROTOCOL_VERSION = -32022;
  /// Resource not found in 2025-11-25 and earlier; 2026-07-28 uses JSONRPC_INVALID_PARAMS.
  MCP_ERROR_RESOURCE_NOT_FOUND_LEGACY = -32002;

  // Reserved _meta keys (2026-07-28)
  MCP_META_PROTOCOL_VERSION = 'io.modelcontextprotocol/protocolVersion';
  MCP_META_CLIENT_CAPABILITIES = 'io.modelcontextprotocol/clientCapabilities';
  MCP_META_CLIENT_INFO = 'io.modelcontextprotocol/clientInfo';
  MCP_META_LOG_LEVEL = 'io.modelcontextprotocol/logLevel';
  MCP_META_SERVER_INFO = 'io.modelcontextprotocol/serverInfo';
  MCP_META_SUBSCRIPTION_ID = 'io.modelcontextprotocol/subscriptionId';
  MCP_META_PROGRESS_TOKEN = 'progressToken';

  // Cache scopes (server/utilities/caching.mdx)
  MCP_CACHE_SCOPE_PUBLIC = 'public';
  MCP_CACHE_SCOPE_PRIVATE = 'private';

  /// Methods whose complete results must carry ttlMs and cacheScope
  /// (server/utilities/caching.mdx, "Cacheable Results").
  MCP_CACHEABLE_METHODS: array[0..5] of string = (
    'server/discover',
    'tools/list',
    'prompts/list',
    'resources/list',
    'resources/templates/list',
    'resources/read'
  );

function IsLegacyProtocolVersion(const Version: string): Boolean;
function IsModernProtocolVersion(const Version: string): Boolean;
/// The revision answered to an initialize request: the requested one when it
/// is served, otherwise the newest legacy revision.
function NegotiateLegacyProtocolVersion(const Requested: string): string;

type
  OptionalAttribute = class(TCustomAttribute)
  end;

  SchemaDescriptionAttribute = class(TCustomAttribute)
  private
    FDescription: string;
  public
    constructor Create(const ADescription: string);
    property Description: string read FDescription;
  end;

  /// Human-readable title of a parameter (JSON Schema "title").
  SchemaTitleAttribute = class(TCustomAttribute)
  private
    FTitle: string;
  public
    constructor Create(const ATitle: string);
    property Title: string read FTitle;
  end;

  /// JSON Schema "format" of a string parameter, for example 'date-time' or 'uri'.
  SchemaFormatAttribute = class(TCustomAttribute)
  private
    FFormat: string;
  public
    constructor Create(const AFormat: string);
    property Format: string read FFormat;
  end;

  /// JSON Schema "minimum" of a numeric parameter.
  SchemaMinimumAttribute = class(TCustomAttribute)
  private
    FMinimum: Double;
  public
    constructor Create(const AMinimum: Double);
    property Minimum: Double read FMinimum;
  end;

  /// JSON Schema "maximum" of a numeric parameter.
  SchemaMaximumAttribute = class(TCustomAttribute)
  private
    FMaximum: Double;
  public
    constructor Create(const AMaximum: Double);
    property Maximum: Double read FMaximum;
  end;

  SchemaEnumAttribute = class(TCustomAttribute)
  private
    FValues: TArray<string>;
  public
    constructor Create(const AValues: array of string); overload;
    constructor Create(const AValue1: string); overload;
    constructor Create(const AValue1, AValue2: string); overload;
    constructor Create(const AValue1, AValue2, AValue3: string); overload;
    constructor Create(const AValue1, AValue2, AValue3, AValue4: string); overload;
    property Values: TArray<string> read FValues;
  end;

  TMCPToolsCapability = class;
  
  IMCPCapabilityManager = interface
    ['{E5F7C3A1-8B4D-4F6E-9C2A-1D3E5F7A9B8C}']
    function GetCapabilityName: string;
    function HandlesMethod(const Method: string): Boolean;
    function ExecuteMethod(const Method: string; const Params: TJSONObject): TValue;
  end;
  
  IMCPManagerRegistry = interface
    ['{A2B4C6D8-1E3F-5A7B-9C8D-2F4E6A8C0B2D}']
    procedure RegisterManager(const Manager: IMCPCapabilityManager);
    function GetManagerForMethod(const Method: string): IMCPCapabilityManager;
  end;

  /// Optional view on a manager registry that can list its managers, used to
  /// derive the server capabilities. Probed with Supports().
  IMCPManagerEnumerator = interface
    ['{6D1F0B2C-3A4E-4F5B-8C7D-9E0F1A2B3C4D}']
    function GetManagers: TArray<IMCPCapabilityManager>;
  end;

  /// Implemented by managers that want a reference to the registry they are
  /// registered in (TMCPManagerRegistry injects it). Keep the reference weak.
  IMCPRegistryAware = interface
    ['{2B7C9D1E-4F6A-4B8C-9D0E-1F2A3B4C5D6E}']
    procedure SetManagerRegistry(const Registry: IMCPManagerRegistry);
  end;

  {$SCOPEDENUMS ON}
  /// Legacy: initialize-based revisions (2025-11-25 and earlier).
  /// Modern: per-request _meta revisions (2026-07-28 and later).
  TMCPProtocolEra = (Legacy, Modern);

  TMCPRequestIdKind = (None, Null, Text, Number, Invalid);
  {$SCOPEDENUMS OFF}

  /// The JSON-RPC id of a message. None means the member is absent
  /// (notification); Invalid covers booleans, objects, arrays and fractions.
  TMCPRequestId = record
    Kind: TMCPRequestIdKind;
    Text: string;
    Number: Int64;
    class function FromJson(const Value: TJSONValue): TMCPRequestId; static;
    class function FromNumber(const Value: Int64): TMCPRequestId; static;
    class function FromText(const Value: string): TMCPRequestId; static;
    /// True for a string or integer id (a request that must be answered).
    function IsPresent: Boolean;
    /// JSON value for the response; null when the id is absent or invalid.
    function ToJson: TJSONValue;
    function AsText: string;
  end;

  /// Per-process legacy state for stdio: the protocol version negotiated by
  /// the last initialize. Empty until an initialize has been answered.
  TMCPLegacySession = class
  private
    FProtocolVersion: string;
  public
    property ProtocolVersion: string read FProtocolVersion write FProtocolVersion;
  end;

  /// What a handler may know about the request it is serving. Built once
  /// per request by the JSON-RPC processor and reachable through
  /// TMCPRequestContext.Current while the handler runs.
  IMCPRequestContext = interface
    ['{7E3A9C1B-5D2F-4A6E-8B0C-3D4E5F6A7B8C}']
    function GetEra: TMCPProtocolEra;
    function GetProtocolVersion: string;
    function GetMethod: string;
    function GetRequestId: TMCPRequestId;
    function GetMeta: TJSONObject;
    function GetClientCapabilities: TJSONObject;
    function GetClientInfo: TJSONObject;
    function GetLogLevel: string;
    function GetProgressToken: TJSONValue;
    function GetLegacySession: TMCPLegacySession;
    function GetManagerRegistry: IMCPManagerRegistry;

    /// True when the client declared the capability, given as a dotted path
    /// such as 'elicitation' or 'elicitation.form'. Always False for legacy
    /// requests (their capabilities are not carried per request).
    function HasClientCapability(const Path: string): Boolean;
    /// Raises EMCPError -32021 when the capability was not declared.
    procedure RequireClientCapability(const Path: string);
    function IsCancelled: Boolean;
    procedure CheckCancelled;

    property Era: TMCPProtocolEra read GetEra;
    property ProtocolVersion: string read GetProtocolVersion;
    property Method: string read GetMethod;
    property RequestId: TMCPRequestId read GetRequestId;
    /// The request's _meta object (nil when absent). Owned by the context.
    property Meta: TJSONObject read GetMeta;
    /// io.modelcontextprotocol/clientCapabilities (never nil for modern
    /// requests, nil for legacy requests).
    property ClientCapabilities: TJSONObject read GetClientCapabilities;
    property ClientInfo: TJSONObject read GetClientInfo;
    property LogLevel: string read GetLogLevel;
    property ProgressToken: TJSONValue read GetProgressToken;
    property LegacySession: TMCPLegacySession read GetLegacySession;
    property ManagerRegistry: IMCPManagerRegistry read GetManagerRegistry;
  end;

  /// Managers that want the request context receive it through this
  /// interface; the processor falls back to IMCPCapabilityManager.ExecuteMethod.
  IMCPCapabilityManagerEx = interface
    ['{9F4B2D6A-1C3E-4E5F-A7B8-C9D0E1F2A3B4}']
    function ExecuteMethodWithContext(const Method: string; const Params: TJSONObject;
      const Context: IMCPRequestContext): TValue;
  end;

  /// Managers that contribute an entry to the server capabilities
  /// (for example "tools": {"listChanged": false}).
  IMCPCapabilityProvider = interface
    ['{C5D7E9F1-2A4B-4C6D-8E0F-1A2B3C4D5E6F}']
    procedure DescribeCapabilities(const Capabilities: TJSONObject; Era: TMCPProtocolEra);
  end;

  /// Optional tool metadata for tools/list: annotations (readOnlyHint and
  /// friends) and icons. Both may be nil. The tool keeps ownership.
  IMCPToolMetadata = interface
    ['{D2E4F6A8-1B3C-4D5E-9F0A-2B3C4D5E6F70}']
    function GetAnnotations: TJSONObject;
    function GetIcons: TJSONArray;
    property Annotations: TJSONObject read GetAnnotations;
    property Icons: TJSONArray read GetIcons;
  end;

  /// Resources whose contents are bytes rather than text; resources/read
  /// answers with a Base64 "blob" instead of "text".
  IMCPBinaryResource = interface
    ['{E3F5A7B9-2C4D-4E6F-A0B1-3C4D5E6F7081}']
    function ReadBinary: TBytes;
  end;

  /// Optional resource metadata for resources/list: title, size in bytes
  /// (-1 when unknown) and annotations (may be nil, the resource keeps ownership).
  IMCPResourceMetadata = interface
    ['{F4A6B8CA-3D5E-4F70-B1C2-4D5E6F708192}']
    function GetTitle: string;
    function GetSize: Int64;
    function GetAnnotations: TJSONObject;
    property Title: string read GetTitle;
    property Size: Int64 read GetSize;
    property Annotations: TJSONObject read GetAnnotations;
  end;

  /// Cache hints a resource attaches to its resources/read result in the
  /// modern era: ttlMs (milliseconds, 0 = immediately stale) and cacheScope
  /// ('public' or 'private').
  IMCPCacheableResource = interface
    ['{05B7C9DB-4E6F-4081-C2D3-5E6F708192A3}']
    function GetTtlMs: Integer;
    function GetCacheScope: string;
    property TtlMs: Integer read GetTtlMs;
    property CacheScope: string read GetCacheScope;
  end;

  TMCPCapabilities = class
  private
    FTools: TMCPToolsCapability;
    FLogging: TJSONObject;
  public
    constructor Create;
    destructor Destroy; override;
    property Tools: TMCPToolsCapability read FTools write FTools;
    property Logging: TJSONObject read FLogging write FLogging;
  end;

  TMCPToolsCapability = class
  private
    FSupportsProgress: Boolean;
    FSupportsCancellation: Boolean;
  public
    constructor Create;
    property SupportsProgress: Boolean read FSupportsProgress write FSupportsProgress;
    property SupportsCancellation: Boolean read FSupportsCancellation write FSupportsCancellation;
  end;

  TMCPInitializeResponse = class
  private
    FProtocolVersion: string;
    FCapabilities: TMCPCapabilities;
  public
    constructor Create;
    destructor Destroy; override;
    property ProtocolVersion: string read FProtocolVersion write FProtocolVersion;
    property Capabilities: TMCPCapabilities read FCapabilities write FCapabilities;
  end;

  TMCPPingResponse = class
  private
    FStatus: string;
    FTimestamp: string;
  public
    property Status: string read FStatus write FStatus;
    property Timestamp: string read FTimestamp write FTimestamp;
  end;

  TMCPTool = class
  private
    FName: string;
    FTitle: string;
    FDescription: string;
    FInputSchema: string;
  public
    property Name: string read FName write FName;
    property Title: string read FTitle write FTitle;
    property Description: string read FDescription write FDescription;
    property InputSchema: string read FInputSchema write FInputSchema;
  end;

  TMCPToolsResponse = class
  private
    FTools: TArray<TMCPTool>;
  public
    property Tools: TArray<TMCPTool> read FTools write FTools;
  end;

implementation

function IsLegacyProtocolVersion(const Version: string): Boolean;
begin
  for var Known in MCP_LEGACY_PROTOCOL_VERSIONS do
    if Known = Version then
      Exit(True);
  Result := False;
end;

function IsModernProtocolVersion(const Version: string): Boolean;
begin
  for var Known in MCP_MODERN_PROTOCOL_VERSIONS do
    if Known = Version then
      Exit(True);
  Result := False;
end;

function NegotiateLegacyProtocolVersion(const Requested: string): string;
begin
  if IsLegacyProtocolVersion(Requested) then
    Result := Requested
  else
    Result := MCP_LATEST_LEGACY_PROTOCOL_VERSION;
end;

{ TMCPRequestId }

class function TMCPRequestId.FromJson(const Value: TJSONValue): TMCPRequestId;
begin
  Result.Text := '';
  Result.Number := 0;

  if not Assigned(Value) then
    Result.Kind := TMCPRequestIdKind.None
  else if Value is TJSONNull then
    Result.Kind := TMCPRequestIdKind.Null
  else if Value is TJSONNumber then
  begin
    // Only integers are valid ids; a fraction is not.
    var Number := TJSONNumber(Value);
    if Frac(Number.AsDouble) = 0 then
    begin
      Result.Kind := TMCPRequestIdKind.Number;
      Result.Number := Number.AsInt64;
    end
    else
      Result.Kind := TMCPRequestIdKind.Invalid;
  end
  else if Value is TJSONString then
  begin
    Result.Kind := TMCPRequestIdKind.Text;
    Result.Text := TJSONString(Value).Value;
  end
  else
    Result.Kind := TMCPRequestIdKind.Invalid;
end;

class function TMCPRequestId.FromNumber(const Value: Int64): TMCPRequestId;
begin
  Result.Kind := TMCPRequestIdKind.Number;
  Result.Number := Value;
  Result.Text := '';
end;

class function TMCPRequestId.FromText(const Value: string): TMCPRequestId;
begin
  Result.Kind := TMCPRequestIdKind.Text;
  Result.Number := 0;
  Result.Text := Value;
end;

function TMCPRequestId.IsPresent: Boolean;
begin
  Result := Kind in [TMCPRequestIdKind.Text, TMCPRequestIdKind.Number];
end;

function TMCPRequestId.ToJson: TJSONValue;
begin
  case Kind of
    TMCPRequestIdKind.Text:
      Result := TJSONString.Create(Text);
    TMCPRequestIdKind.Number:
      Result := TJSONNumber.Create(Number);
  else
    Result := TJSONNull.Create;
  end;
end;

function TMCPRequestId.AsText: string;
begin
  case Kind of
    TMCPRequestIdKind.Text:
      Result := Text;
    TMCPRequestIdKind.Number:
      Result := Number.ToString;
  else
    Result := '';
  end;
end;

{ SchemaDescriptionAttribute }

constructor SchemaDescriptionAttribute.Create(const ADescription: string);
begin
  inherited Create;
  FDescription := ADescription;
end;

{ SchemaTitleAttribute }

constructor SchemaTitleAttribute.Create(const ATitle: string);
begin
  inherited Create;
  FTitle := ATitle;
end;

{ SchemaFormatAttribute }

constructor SchemaFormatAttribute.Create(const AFormat: string);
begin
  inherited Create;
  FFormat := AFormat;
end;

{ SchemaMinimumAttribute }

constructor SchemaMinimumAttribute.Create(const AMinimum: Double);
begin
  inherited Create;
  FMinimum := AMinimum;
end;

{ SchemaMaximumAttribute }

constructor SchemaMaximumAttribute.Create(const AMaximum: Double);
begin
  inherited Create;
  FMaximum := AMaximum;
end;

{ SchemaEnumAttribute }

constructor SchemaEnumAttribute.Create(const AValues: array of string);
var
  I: NativeInt;
begin
  inherited Create;
  SetLength(FValues, Length(AValues));
  for I := 0 to High(AValues) do
    FValues[I] := AValues[I];
end;

constructor SchemaEnumAttribute.Create(const AValue1: string);
begin
  inherited Create;
  SetLength(FValues, 1);
  FValues[0] := AValue1;
end;

constructor SchemaEnumAttribute.Create(const AValue1, AValue2: string);
begin
  inherited Create;
  SetLength(FValues, 2);
  FValues[0] := AValue1;
  FValues[1] := AValue2;
end;

constructor SchemaEnumAttribute.Create(const AValue1, AValue2, AValue3: string);
begin
  inherited Create;
  SetLength(FValues, 3);
  FValues[0] := AValue1;
  FValues[1] := AValue2;
  FValues[2] := AValue3;
end;

constructor SchemaEnumAttribute.Create(const AValue1, AValue2, AValue3, AValue4: string);
begin
  inherited Create;
  SetLength(FValues, 4);
  FValues[0] := AValue1;
  FValues[1] := AValue2;
  FValues[2] := AValue3;
  FValues[3] := AValue4;
end;

{ TMCPInitializeResponse }

constructor TMCPInitializeResponse.Create;
begin
  inherited;
  FCapabilities := TMCPCapabilities.Create;
end;

destructor TMCPInitializeResponse.Destroy;
begin
  FCapabilities.Free;
  inherited;
end;

{ TMCPCapabilities }

constructor TMCPCapabilities.Create;
begin
  inherited;
  FTools := TMCPToolsCapability.Create;
  FLogging := TJSONObject.Create;
end;

destructor TMCPCapabilities.Destroy;
begin
  FTools.Free;
  FLogging.Free;
  inherited;
end;

{ TMCPToolsCapability }

constructor TMCPToolsCapability.Create;
begin
  inherited;
  FSupportsProgress := False;
  FSupportsCancellation := False;
end;

end.