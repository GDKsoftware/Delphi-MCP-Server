unit MCPServer.Types;

interface

uses
  System.SysUtils,
  System.JSON,
  System.Rtti,
  System.Generics.Collections;

const
  MCP_PROTOCOL_VERSION = '2025-06-18';

  MCP_PROTOCOL_VERSION_2025_03_26 = '2025-03-26';
  MCP_PROTOCOL_VERSION_2025_06_18 = '2025-06-18';
  MCP_PROTOCOL_VERSION_2025_11_25 = '2025-11-25';
  MCP_PROTOCOL_VERSION_2026_07_28 = '2026-07-28';

  MCP_LATEST_PROTOCOL_VERSION = MCP_PROTOCOL_VERSION_2026_07_28;
  MCP_LATEST_LEGACY_PROTOCOL_VERSION = MCP_PROTOCOL_VERSION_2025_11_25;

  MCP_LEGACY_PROTOCOL_VERSIONS: array[0..1] of string = (
    MCP_PROTOCOL_VERSION_2025_11_25,
    MCP_PROTOCOL_VERSION_2025_06_18
  );
  MCP_MODERN_PROTOCOL_VERSIONS: array[0..0] of string = (
    MCP_PROTOCOL_VERSION_2026_07_28
  );

  JSONRPC_PARSE_ERROR = -32700;
  JSONRPC_INVALID_REQUEST = -32600;
  JSONRPC_METHOD_NOT_FOUND = -32601;
  JSONRPC_INVALID_PARAMS = -32602;
  JSONRPC_INTERNAL_ERROR = -32603;

  MCP_ERROR_HEADER_MISMATCH = -32020;
  MCP_ERROR_MISSING_REQUIRED_CLIENT_CAPABILITY = -32021;
  MCP_ERROR_UNSUPPORTED_PROTOCOL_VERSION = -32022;
  MCP_ERROR_RESOURCE_NOT_FOUND_LEGACY = -32002;

  MCP_META_PROTOCOL_VERSION = 'io.modelcontextprotocol/protocolVersion';
  MCP_META_CLIENT_CAPABILITIES = 'io.modelcontextprotocol/clientCapabilities';
  MCP_META_CLIENT_INFO = 'io.modelcontextprotocol/clientInfo';
  MCP_META_LOG_LEVEL = 'io.modelcontextprotocol/logLevel';
  MCP_META_SERVER_INFO = 'io.modelcontextprotocol/serverInfo';
  MCP_META_SUBSCRIPTION_ID = 'io.modelcontextprotocol/subscriptionId';
  MCP_META_PROGRESS_TOKEN = 'progressToken';

  MCP_METHOD_NOTIFICATIONS_CANCELLED = 'notifications/cancelled';
  MCP_METHOD_NOTIFICATIONS_PROGRESS = 'notifications/progress';

  MCP_CACHE_SCOPE_PUBLIC = 'public';
  MCP_CACHE_SCOPE_PRIVATE = 'private';

  MCP_CACHEABLE_METHODS: array[0..5] of string = (
    'server/discover',
    'tools/list',
    'prompts/list',
    'resources/list',
    'resources/templates/list',
    'resources/read'
  );

  MCP_METHOD_NOTIFICATIONS_MESSAGE = 'notifications/message';
  MCP_SCOPE_ANY = '*';
  MCP_METHOD_SUBSCRIPTIONS_LISTEN = 'subscriptions/listen';
  MCP_METHOD_NOTIFICATIONS_SUBSCRIPTIONS_ACKNOWLEDGED = 'notifications/subscriptions/acknowledged';
  MCP_METHOD_NOTIFICATIONS_TOOLS_LIST_CHANGED = 'notifications/tools/list_changed';
  MCP_METHOD_NOTIFICATIONS_PROMPTS_LIST_CHANGED = 'notifications/prompts/list_changed';
  MCP_METHOD_NOTIFICATIONS_RESOURCES_LIST_CHANGED = 'notifications/resources/list_changed';
  MCP_METHOD_NOTIFICATIONS_RESOURCES_UPDATED = 'notifications/resources/updated';
  MCP_LOG_LEVELS: array[0..7] of string = (
    'debug', 'info', 'notice', 'warning', 'error', 'critical', 'alert', 'emergency');

type
  TMCPProtocolVersion = record
    class function IsLegacy(const Version: string): Boolean; static;
    class function IsModern(const Version: string): Boolean; static;
    class function NegotiateLegacy(const Requested: string): string; static;
  end;

  TMCPLogLevel = record
    class function Rank(const Level: string): Integer; static;
    class function IsKnown(const Level: string): Boolean; static;
  end;

  TMCPStrings = record
    class function Contains(const Value: string; const Values: array of string): Boolean; static;
  end;

  TMCPConstantTime = record
    class function SameBytes(const A, B: TBytes): Boolean; static;
  end;

  OptionalAttribute = class(TCustomAttribute)
  end;

  SchemaDescriptionAttribute = class(TCustomAttribute)
  private
    FDescription: string;
  public
    constructor Create(const ADescription: string);
    property Description: string read FDescription;
  end;

  SchemaTitleAttribute = class(TCustomAttribute)
  private
    FTitle: string;
  public
    constructor Create(const ATitle: string);
    property Title: string read FTitle;
  end;

  SchemaFormatAttribute = class(TCustomAttribute)
  private
    FFormat: string;
  public
    constructor Create(const AFormat: string);
    property Format: string read FFormat;
  end;

  SchemaMinimumAttribute = class(TCustomAttribute)
  private
    FMinimum: Double;
  public
    constructor Create(const AMinimum: Double);
    property Minimum: Double read FMinimum;
  end;

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

  SchemaMinLengthAttribute = class(TCustomAttribute)
  private
    FMinLength: Integer;
  public
    constructor Create(const AMinLength: Integer);
    property MinLength: Integer read FMinLength;
  end;

  SchemaMaxLengthAttribute = class(TCustomAttribute)
  private
    FMaxLength: Integer;
  public
    constructor Create(const AMaxLength: Integer);
    property MaxLength: Integer read FMaxLength;
  end;

  SchemaPatternAttribute = class(TCustomAttribute)
  private
    FPattern: string;
  public
    constructor Create(const APattern: string);
    property Pattern: string read FPattern;
  end;

  SchemaDefaultAttribute = class(TCustomAttribute)
  private
    FJson: string;
  public
    constructor Create(const AJson: string);
    property Json: string read FJson;
  end;

  SchemaNameAttribute = class(TCustomAttribute)
  private
    FName: string;
  public
    constructor Create(const AName: string);
    property Name: string read FName;
  end;

  SchemaAdditionalPropertiesAttribute = class(TCustomAttribute)
  private
    FAllowed: Boolean;
  public
    constructor Create(const AAllowed: Boolean);
    property Allowed: Boolean read FAllowed;
  end;

  SchemaDialectAttribute = class(TCustomAttribute)
  private
    FUri: string;
  public
    constructor Create(const AUri: string);
    property Uri: string read FUri;
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

  IMCPManagerEnumerator = interface
    ['{6D1F0B2C-3A4E-4F5B-8C7D-9E0F1A2B3C4D}']
    function GetManagers: TArray<IMCPCapabilityManager>;
  end;

  IMCPRegistryAware = interface
    ['{2B7C9D1E-4F6A-4B8C-9D0E-1F2A3B4C5D6E}']
    procedure SetManagerRegistry(const Registry: IMCPManagerRegistry);
  end;

  {$SCOPEDENUMS ON}
  TMCPProtocolEra = (Legacy, Modern);

  TMCPRequestIdKind = (None, Null, Text, Number, Invalid);
  {$SCOPEDENUMS OFF}

  TMCPRequestId = record
    Kind: TMCPRequestIdKind;
    Text: string;
    Number: Int64;
    class function FromJson(const Value: TJSONValue): TMCPRequestId; static;
    class function FromNumber(const Value: Int64): TMCPRequestId; static;
    class function FromText(const Value: string): TMCPRequestId; static;
    function IsPresent: Boolean;
    function ToJson: TJSONValue;
    function AsText: string;
  end;

  TMCPLegacySession = class
  private
    FProtocolVersion: string;
    FLock: TObject;
    function GetProtocolVersion: string;
    procedure SetProtocolVersion(const Value: string);
  public
    constructor Create;
    destructor Destroy; override;
    property ProtocolVersion: string read GetProtocolVersion write SetProtocolVersion;
  end;

  IMCPMessageSink = interface
    ['{2B7D4E90-6C1A-4F3B-9E8D-5A0C1B2D3E4F}']
    procedure Send(const Json: string);
  end;

  IMCPKeepAlive = interface
    ['{9C2E4A6B-1D3F-4E5A-B7C9-0D2E4F6A8B1C}']
    procedure KeepAlive;
  end;

  IMCPSubscriptionHub = interface
    ['{3E5A7C9B-2D4F-4A6B-8C1E-5F7A9B0C2D4E}']
    procedure ToolsListChanged;
    procedure PromptsListChanged;
    procedure ResourcesListChanged;
    procedure ResourceUpdated(const Uri: string);
    procedure CloseAll(const Reason: string);
    function ActiveCount: Integer;
  end;

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
    function GetInputResponses: TJSONObject;
    function GetRequestState: TJSONObject;
    function GetSink: IMCPMessageSink;
    function GetPrincipal: string;
    function GetScopes: TArray<string>;

    function HasClientCapability(const Path: string): Boolean;
    function HasScope(const Scope: string): Boolean;
    procedure RequireClientCapability(const Path: string);
    function IsCancelled: Boolean;
    procedure CheckCancelled;
    procedure Cancel;
    function HasProgressToken: Boolean;
    procedure ReportProgress(const Progress: Double; const Total: Double = -1; const Message: string = '');
    function TryGetInputResponse(const Key: string; out Response: TJSONObject): Boolean;
    procedure Log(const Level, Text: string; const Logger: string = '');
    procedure LogJson(const Level: string; const Data: TJSONValue; const Logger: string = '');

    property Era: TMCPProtocolEra read GetEra;
    property ProtocolVersion: string read GetProtocolVersion;
    property Method: string read GetMethod;
    property RequestId: TMCPRequestId read GetRequestId;
    property Meta: TJSONObject read GetMeta;
    property ClientCapabilities: TJSONObject read GetClientCapabilities;
    property ClientInfo: TJSONObject read GetClientInfo;
    property LogLevel: string read GetLogLevel;
    property ProgressToken: TJSONValue read GetProgressToken;
    property LegacySession: TMCPLegacySession read GetLegacySession;
    property ManagerRegistry: IMCPManagerRegistry read GetManagerRegistry;
    property InputResponses: TJSONObject read GetInputResponses;
    property RequestState: TJSONObject read GetRequestState;
    property Sink: IMCPMessageSink read GetSink;
    property Principal: string read GetPrincipal;
    property Scopes: TArray<string> read GetScopes;
  end;

  IMCPRequestTracker = interface
    ['{8C5E1F2A-3B4D-4E6F-A1B2-C3D4E5F6A7B8}']
    procedure Track(const Context: IMCPRequestContext);
    procedure Untrack(const Context: IMCPRequestContext);
    function TryCancel(const RequestId: TMCPRequestId; const Reason: string): Boolean;
  end;

  IMCPCapabilityManagerEx = interface
    ['{9F4B2D6A-1C3E-4E5F-A7B8-C9D0E1F2A3B4}']
    function ExecuteMethodWithContext(const Method: string; const Params: TJSONObject;
      const Context: IMCPRequestContext): TValue;
  end;

  IMCPCapabilityProvider = interface
    ['{C5D7E9F1-2A4B-4C6D-8E0F-1A2B3C4D5E6F}']
    procedure DescribeCapabilities(const Capabilities: TJSONObject; Era: TMCPProtocolEra);
  end;

  IMCPToolMetadata = interface
    ['{D2E4F6A8-1B3C-4D5E-9F0A-2B3C4D5E6F70}']
    function GetAnnotations: TJSONObject;
    function GetIcons: TJSONArray;
    property Annotations: TJSONObject read GetAnnotations;
    property Icons: TJSONArray read GetIcons;
  end;

  IMCPBinaryResource = interface
    ['{E3F5A7B9-2C4D-4E6F-A0B1-3C4D5E6F7081}']
    function ReadBinary: TBytes;
  end;

  IMCPResourceMetadata = interface
    ['{F4A6B8CA-3D5E-4F70-B1C2-4D5E6F708192}']
    function GetTitle: string;
    function GetSize: Int64;
    function GetAnnotations: TJSONObject;
    property Title: string read GetTitle;
    property Size: Int64 read GetSize;
    property Annotations: TJSONObject read GetAnnotations;
  end;

  IMCPCacheableResource = interface
    ['{05B7C9DB-4E6F-4081-C2D3-5E6F708192A3}']
    function GetTtlMs: Integer;
    function GetCacheScope: string;
    property TtlMs: Integer read GetTtlMs;
    property CacheScope: string read GetCacheScope;
  end;

  IMCPPromptMetadata = interface
    ['{16C8DAEC-5F70-4192-D3E4-6F708192A3B4}']
    function GetIcons: TJSONArray;
    property Icons: TJSONArray read GetIcons;
  end;

  TMCPCompletion = record
    Values: TArray<string>;
    Total: Integer;
    HasMore: Boolean;
    class function Create(const Values: TArray<string>; Total: Integer = -1): TMCPCompletion; static;
  end;

  IMCPCompletable = interface
    ['{27D9EBFD-6081-42A3-E4F5-708192A3B4C5}']
    function Complete(const ArgumentName, Value: string;
      const Context: TArray<TPair<string, string>>): TMCPCompletion;
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

function IsJsonString(const Value: TJSONValue): Boolean;

implementation

class function TMCPLogLevel.Rank(const Level: string): Integer;
begin
  for var I := Low(MCP_LOG_LEVELS) to High(MCP_LOG_LEVELS) do
  begin
    if MCP_LOG_LEVELS[I] = Level then
      Exit(I);
  end;
  Result := -1;
end;

class function TMCPLogLevel.IsKnown(const Level: string): Boolean;
begin
  Result := Rank(Level) >= 0;
end;

class function TMCPStrings.Contains(const Value: string; const Values: array of string): Boolean;
begin
  for var Item in Values do
  begin
    if Item = Value then
      Exit(True);
  end;
  Result := False;
end;

class function TMCPConstantTime.SameBytes(const A, B: TBytes): Boolean;
begin
  var Difference := Length(A) xor Length(B);
  var Longest := Length(A);
  if Length(B) > Longest then
    Longest := Length(B);
  for var I := 0 to Longest - 1 do
  begin
    var Left := 0;
    var Right := 0;
    if I < Length(A) then
      Left := A[I];
    if I < Length(B) then
      Right := B[I];
    Difference := Difference or (Left xor Right);
  end;
  Result := Difference = 0;
end;

function IsJsonString(const Value: TJSONValue): Boolean;
begin
  Result := (Value is TJSONString) and not (Value is TJSONNumber);
end;

{ TMCPLegacySession }

constructor TMCPLegacySession.Create;
begin
  inherited Create;
  FLock := TObject.Create;
end;

destructor TMCPLegacySession.Destroy;
begin
  FLock.Free;
  inherited;
end;

function TMCPLegacySession.GetProtocolVersion: string;
begin
  TMonitor.Enter(FLock);
  try
    Result := FProtocolVersion;
  finally
    TMonitor.Exit(FLock);
  end;
end;

procedure TMCPLegacySession.SetProtocolVersion(const Value: string);
begin
  TMonitor.Enter(FLock);
  try
    FProtocolVersion := Value;
  finally
    TMonitor.Exit(FLock);
  end;
end;

class function TMCPProtocolVersion.IsLegacy(const Version: string): Boolean;
begin
  for var Known in MCP_LEGACY_PROTOCOL_VERSIONS do
    if Known = Version then
      Exit(True);
  Result := False;
end;

class function TMCPProtocolVersion.IsModern(const Version: string): Boolean;
begin
  for var Known in MCP_MODERN_PROTOCOL_VERSIONS do
    if Known = Version then
      Exit(True);
  Result := False;
end;

class function TMCPProtocolVersion.NegotiateLegacy(const Requested: string): string;
begin
  if TMCPProtocolVersion.IsLegacy(Requested) then
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

{ SchemaMinLengthAttribute }

constructor SchemaMinLengthAttribute.Create(const AMinLength: Integer);
begin
  inherited Create;
  FMinLength := AMinLength;
end;

{ SchemaMaxLengthAttribute }

constructor SchemaMaxLengthAttribute.Create(const AMaxLength: Integer);
begin
  inherited Create;
  FMaxLength := AMaxLength;
end;

{ SchemaPatternAttribute }

constructor SchemaPatternAttribute.Create(const APattern: string);
begin
  inherited Create;
  FPattern := APattern;
end;

{ SchemaDefaultAttribute }

constructor SchemaDefaultAttribute.Create(const AJson: string);
begin
  inherited Create;
  FJson := AJson;
end;

{ SchemaNameAttribute }

constructor SchemaNameAttribute.Create(const AName: string);
begin
  inherited Create;
  FName := AName;
end;

{ SchemaAdditionalPropertiesAttribute }

constructor SchemaAdditionalPropertiesAttribute.Create(const AAllowed: Boolean);
begin
  inherited Create;
  FAllowed := AAllowed;
end;

{ SchemaDialectAttribute }

constructor SchemaDialectAttribute.Create(const AUri: string);
begin
  inherited Create;
  FUri := AUri;
end;

{ TMCPCompletion }

class function TMCPCompletion.Create(const Values: TArray<string>; Total: Integer): TMCPCompletion;
const
  MAX_COMPLETION_VALUES = 100;
begin
  if Length(Values) > MAX_COMPLETION_VALUES then
  begin
    Result.Values := Copy(Values, 0, MAX_COMPLETION_VALUES);
    Result.HasMore := True;
  end
  else
  begin
    Result.Values := Values;
    Result.HasMore := False;
  end;
  Result.Total := Total;
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