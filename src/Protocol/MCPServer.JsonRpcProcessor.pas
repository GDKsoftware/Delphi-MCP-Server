unit MCPServer.JsonRpcProcessor;

interface

uses
  System.SysUtils,
  System.JSON,
  System.Rtti,
  MCPServer.Types,
  MCPServer.Settings,
  MCPServer.RequestContext,
  MCPServer.RequestState,
  MCPServer.Mrtr,
  MCPServer.Errors,
  MCPServer.HttpHeaders,
  MCPServer.Registration,
  MCPServer.Logger;

type
  TMCPProcessResult = record
    Body: string;
    HttpStatus: Integer;
    Era: TMCPProtocolEra;
    IsNotification: Boolean;
    Cancelled: Boolean;
    RequiredScope: string;
  end;

  TMCPJsonRpcProcessor = class
  private
    FManagerRegistry: IMCPManagerRegistry;
    FSettings: TMCPSettings;
    FOwnsSettings: Boolean;
    FStateSealer: TMCPRequestStateSealer;
    procedure SetSettings(const Value: TMCPSettings);
    function SupportedModernVersions: TArray<string>;
    function BuildServerInfo: TJSONObject;
    function IsLegacyOnlyMethod(const Method: string): Boolean;
    function IsModernOnlyMethod(const Method: string): Boolean;
    function IsCacheableMethod(const Method: string): Boolean;
    function IsInputRequiredMethod(const Method: string): Boolean;
    function ClientInputResponses(const Params: TJSONObject): TJSONObject;
    function OpenClientRequestState(const Method: string; const Params: TJSONObject;
      const Hints: TMCPTransportHints): TJSONObject;
    function NewContext(Era: TMCPProtocolEra; const Version, Method: string; const RequestId: TMCPRequestId;
      const Meta: TJSONObject; const Hints: TMCPTransportHints; const InputResponses: TJSONObject = nil;
      const RequestState: TJSONObject = nil): IMCPRequestContext;
    function ModernContext(const Method: string; const Params: TJSONObject; const RequestId: TMCPRequestId;
      const Meta: TJSONObject; const Version: string; const Hints: TMCPTransportHints): IMCPRequestContext;
    function LegacyContext(const Method: string; const Params: TJSONObject; const RequestId: TMCPRequestId;
      const Meta: TJSONObject; const Hints: TMCPTransportHints): IMCPRequestContext;
    function ReadRequestObject(const Message: TJSONValue): TJSONObject;
    function ReadRequestId(const Request: TJSONObject): TMCPRequestId;
    function ReadMethod(const Request: TJSONObject; Era: TMCPProtocolEra; out IsClientResponse: Boolean): string;
    function ReadParams(const Request: TJSONObject; Era: TMCPProtocolEra): TJSONObject;
    function RunRequest(const Context: IMCPRequestContext; const Params: TJSONObject;
      const Hints: TMCPTransportHints): TMCPProcessResult;
    function SuccessResult(const Context: IMCPRequestContext; const Value: TValue): TMCPProcessResult;
    function AcceptedResult(Era: TMCPProtocolEra): TMCPProcessResult;
    function InputRequiredResult(const Context: IMCPRequestContext; const Params: TJSONObject;
      const Hints: TMCPTransportHints; const Required: EMCPInputRequired): TMCPProcessResult;
    function EraFromHeaders(const Hints: TMCPTransportHints): TMCPProtocolEra;
    function EraFromMessage(const Method: string; const Params: TJSONObject;
      const Hints: TMCPTransportHints): TMCPProtocolEra;
    function ExtractMeta(const Params: TJSONObject): TJSONObject;
    procedure ValidateModernMeta(const Meta: TJSONObject);
    procedure ValidateMirroredHeaders(const Method: string; const Params: TJSONObject;
      const Hints: TMCPTransportHints);
    function ProcessNotification(const Method: string; const Params: TJSONObject;
      const Hints: TMCPTransportHints): TMCPProcessResult;
    procedure HandleCancelled(const Params: TJSONObject; const Hints: TMCPTransportHints);
    function CancelledResult(Era: TMCPProtocolEra): TMCPProcessResult;
    function DispatchRequest(const Context: IMCPRequestContext; const Params: TJSONObject): TValue;
    function ResultToJson(const Value: TValue; const Context: IMCPRequestContext): TJSONValue;
    procedure ApplyModernEnvelope(const ResultObject: TJSONObject; const Method: string);
    function StatusForError(Era: TMCPProtocolEra; const Error: EMCPError): Integer;
    function ErrorResult(Era: TMCPProtocolEra; const RequestId: TMCPRequestId; const Error: EMCPError): TMCPProcessResult;
    function ExceptionToError(Era: TMCPProtocolEra; const E: Exception): EMCPError;
  public
    constructor Create(ManagerRegistry: IMCPManagerRegistry); overload;
    constructor Create(ManagerRegistry: IMCPManagerRegistry; Settings: TMCPSettings); overload;
    destructor Destroy; override;

    function ProcessRequest(const RequestBody: string; const SessionID: string): string;
    function ProcessRequestEx(const RequestBody: string; const Hints: TMCPTransportHints): TMCPProcessResult; overload;
    function ProcessRequestEx(const Message: TJSONValue; const Hints: TMCPTransportHints): TMCPProcessResult; overload;

    function BuildRequestContext(const Method: string; const Params: TJSONObject;
      const RequestId: TMCPRequestId; const Hints: TMCPTransportHints): IMCPRequestContext;
    function BuildErrorResponse(const RequestId: TMCPRequestId; const Error: EMCPError): string;

    property ManagerRegistry: IMCPManagerRegistry read FManagerRegistry;
    property Settings: TMCPSettings read FSettings write SetSettings;
  end;

const
  JSONRPC_PARSE_ERROR = MCPServer.Types.JSONRPC_PARSE_ERROR;
  JSONRPC_INVALID_REQUEST = MCPServer.Types.JSONRPC_INVALID_REQUEST;
  JSONRPC_METHOD_NOT_FOUND = MCPServer.Types.JSONRPC_METHOD_NOT_FOUND;
  JSONRPC_INVALID_PARAMS = MCPServer.Types.JSONRPC_INVALID_PARAMS;
  JSONRPC_INTERNAL_ERROR = MCPServer.Types.JSONRPC_INTERNAL_ERROR;

implementation


const
  MESSAGE_NOT_A_JSON_RESULT = '%s answered with a %s instead of a JSON object';
  META_PATH_PREFIX = 'params._meta.';
  MESSAGE_PARAMS_NOT_OBJECT = 'params must be an object';
  MESSAGE_HEADER_MISMATCH = 'Header mismatch: %s header value ''%s'' does not match body value ''%s''';
  RESULT_TYPE_COMPLETE = 'complete';

  LEGACY_ONLY_METHODS: array[0..4] of string = (
    MCP_METHOD_PING, MCP_METHOD_INITIALIZE, MCP_METHOD_LOGGING_SET_LEVEL, MCP_METHOD_RESOURCES_SUBSCRIBE, MCP_METHOD_RESOURCES_UNSUBSCRIBE);
  MODERN_ONLY_METHODS: array[0..1] of string = (MCP_METHOD_SERVER_DISCOVER, 'subscriptions/listen');
  INPUT_REQUIRED_METHODS: array[0..2] of string = (MCP_METHOD_TOOLS_CALL, MCP_METHOD_RESOURCES_READ, MCP_METHOD_PROMPTS_GET);
  PARAM_INPUT_RESPONSES = 'inputResponses';
  PARAM_REQUEST_STATE = 'requestState';

{ TMCPJsonRpcProcessor }

constructor TMCPJsonRpcProcessor.Create(ManagerRegistry: IMCPManagerRegistry);
begin
  Create(ManagerRegistry, nil);
end;

constructor TMCPJsonRpcProcessor.Create(ManagerRegistry: IMCPManagerRegistry; Settings: TMCPSettings);
begin
  inherited Create;
  FManagerRegistry := ManagerRegistry;
  SetSettings(Settings);
end;

destructor TMCPJsonRpcProcessor.Destroy;
begin
  FStateSealer.Free;
  if FOwnsSettings then
    FSettings.Free;
  inherited;
end;

procedure TMCPJsonRpcProcessor.SetSettings(const Value: TMCPSettings);
begin
  if FOwnsSettings then
    FreeAndNil(FSettings);
  FOwnsSettings := False;

  if Assigned(Value) then
    FSettings := Value
  else
  begin
    FSettings := TMCPSettings.Create('', False);
    FOwnsSettings := True;
  end;

  FreeAndNil(FStateSealer);
  FStateSealer := TMCPRequestStateSealer.Create(FSettings.RequestStateKey, FSettings.RequestStateTtlSeconds);
end;

function TMCPJsonRpcProcessor.SupportedModernVersions: TArray<string>;
begin
  Result := nil;
  for var Version in MCP_MODERN_PROTOCOL_VERSIONS do
    Result := Result + [Version];
  if FSettings.DiscoverListsLegacyVersions then
    for var Version in MCP_LEGACY_PROTOCOL_VERSIONS do
      Result := Result + [Version];
end;

function TMCPJsonRpcProcessor.BuildServerInfo: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair(MCP_KEY_NAME, FSettings.ServerName);
  Result.AddPair(MCP_KEY_VERSION, FSettings.ServerVersion);
  if FSettings.ServerTitle <> '' then
    Result.AddPair(MCP_KEY_TITLE, FSettings.ServerTitle);
  if FSettings.ServerDescription <> '' then
    Result.AddPair(MCP_KEY_DESCRIPTION, FSettings.ServerDescription);
  if FSettings.ServerWebsiteUrl <> '' then
    Result.AddPair('websiteUrl', FSettings.ServerWebsiteUrl);
end;

function TMCPJsonRpcProcessor.IsLegacyOnlyMethod(const Method: string): Boolean;
begin
  Result := TMCPStrings.Contains(Method, LEGACY_ONLY_METHODS);
  if Result and (Method = MCP_METHOD_PING) and FSettings.LenientModernPing then
    Result := False;
end;

function TMCPJsonRpcProcessor.IsModernOnlyMethod(const Method: string): Boolean;
begin
  Result := TMCPStrings.Contains(Method, MODERN_ONLY_METHODS);
end;

function TMCPJsonRpcProcessor.IsCacheableMethod(const Method: string): Boolean;
begin
  Result := TMCPStrings.Contains(Method, MCP_CACHEABLE_METHODS);
end;

function TMCPJsonRpcProcessor.IsInputRequiredMethod(const Method: string): Boolean;
begin
  Result := TMCPStrings.Contains(Method, INPUT_REQUIRED_METHODS);
end;

function TMCPJsonRpcProcessor.ClientInputResponses(const Params: TJSONObject): TJSONObject;
begin
  Result := nil;
  if not Assigned(Params) then
    Exit;

  var Value := Params.GetValue(PARAM_INPUT_RESPONSES);
  if not Assigned(Value) then
    Exit;
  if not (Value is TJSONObject) then
    raise EMCPError.InvalidParams(Format('params.%s must be an object', [PARAM_INPUT_RESPONSES]));

  for var Pair in TJSONObject(Value) do
  begin
    if not (Pair.JsonValue is TJSONObject) then
      raise EMCPError.InvalidParams(Format('params.%s.%s must be an object', [PARAM_INPUT_RESPONSES, Pair.JsonString.Value]));
  end;
  Result := TJSONObject(Value);
end;

function TMCPJsonRpcProcessor.OpenClientRequestState(const Method: string; const Params: TJSONObject;
  const Hints: TMCPTransportHints): TJSONObject;
begin
  Result := nil;
  if not Assigned(Params) then
    Exit;

  var Value := Params.GetValue(PARAM_REQUEST_STATE);
  if not Assigned(Value) then
    Exit;
  if not IsJsonString(Value) then
    raise EMCPError.InvalidParams(Format('params.%s must be a string', [PARAM_REQUEST_STATE]));

  Result := FStateSealer.Open(TJSONString(Value).Value, Method, TMCPRequestStateSealer.DigestOf(Params), Hints.Principal);
end;

function TMCPJsonRpcProcessor.EraFromHeaders(const Hints: TMCPTransportHints): TMCPProtocolEra;
begin
  if Hints.HasHeaderLayer and Hints.HasProtocolVersionHeader
    and TMCPProtocolVersion.IsModern(Hints.ProtocolVersionHeader) then
    Result := TMCPProtocolEra.Modern
  else
    Result := TMCPProtocolEra.Legacy;
end;

function TMCPJsonRpcProcessor.EraFromMessage(const Method: string; const Params: TJSONObject;
  const Hints: TMCPTransportHints): TMCPProtocolEra;
begin
  Result := EraFromHeaders(Hints);
  if (Result = TMCPProtocolEra.Modern) or not Assigned(Params) then
    Exit;

  var MetaValue := Params.GetValue(MCP_KEY_META);
  if (MetaValue is TJSONObject) and (TJSONObject(MetaValue).GetValue(MCP_META_PROTOCOL_VERSION) is TJSONString) then
    Result := TMCPProtocolEra.Modern;
end;

function TMCPJsonRpcProcessor.ExtractMeta(const Params: TJSONObject): TJSONObject;
begin
  Result := nil;
  if not Assigned(Params) then
    Exit;

  var MetaValue := Params.GetValue(MCP_KEY_META);
  if not Assigned(MetaValue) then
    Exit;
  if not (MetaValue is TJSONObject) then
    raise EMCPError.Create(JSONRPC_INVALID_PARAMS, 'params._meta must be an object', nil, HTTP_STATUS_BAD_REQUEST);
  Result := TJSONObject(MetaValue);
end;

procedure TMCPJsonRpcProcessor.ValidateModernMeta(const Meta: TJSONObject);
begin
  var Capabilities := Meta.GetValue(MCP_META_CLIENT_CAPABILITIES);
  if not (Capabilities is TJSONObject) then
    raise EMCPError.Create(JSONRPC_INVALID_PARAMS,
      META_PATH_PREFIX + MCP_META_CLIENT_CAPABILITIES + ' is required and must be an object',
      nil, HTTP_STATUS_BAD_REQUEST);

  var ClientInfo := Meta.GetValue(MCP_META_CLIENT_INFO);
  if Assigned(ClientInfo) and not (ClientInfo is TJSONObject) then
    raise EMCPError.Create(JSONRPC_INVALID_PARAMS,
      META_PATH_PREFIX + MCP_META_CLIENT_INFO + ' must be an object', nil, HTTP_STATUS_BAD_REQUEST);

  var LogLevel := Meta.GetValue(MCP_META_LOG_LEVEL);
  if Assigned(LogLevel) and (not IsJsonString(LogLevel) or not TMCPLogLevel.IsKnown(TJSONString(LogLevel).Value)) then
    raise EMCPError.Create(JSONRPC_INVALID_PARAMS,
      META_PATH_PREFIX + MCP_META_LOG_LEVEL + ' must be one of debug, info, notice, warning, error, critical, alert, emergency',
      nil, HTTP_STATUS_BAD_REQUEST);
end;

procedure TMCPJsonRpcProcessor.ValidateMirroredHeaders(const Method: string; const Params: TJSONObject;
  const Hints: TMCPTransportHints);
var
  Decoded: string;
begin
  if not Hints.HasMethodHeader then
    raise EMCPError.HeaderMismatch('Mcp-Method header is missing');
  if Hints.MethodHeader <> Method then
    raise EMCPError.HeaderMismatch(Format(MESSAGE_HEADER_MISMATCH,
      ['Mcp-Method', Hints.MethodHeader, Method]));

  var SourceField := '';
  if (Method = MCP_METHOD_TOOLS_CALL) or (Method = MCP_METHOD_PROMPTS_GET) then
    SourceField := 'name'
  else if Method = MCP_METHOD_RESOURCES_READ then
    SourceField := 'uri';
  if SourceField = '' then
    Exit;

  if not Hints.HasNameHeader then
    raise EMCPError.HeaderMismatch('Mcp-Name header is missing');
  if not TMCPHeaderValue.TryDecode(Hints.NameHeader, Decoded) then
    raise EMCPError.HeaderMismatch('Mcp-Name header value is not a valid header value');

  var BodyValue := '';
  if Assigned(Params) then
  begin
    var Source := Params.GetValue(SourceField);
    if IsJsonString(Source) then
      BodyValue := TJSONString(Source).Value;
  end;
  if Decoded <> BodyValue then
    raise EMCPError.HeaderMismatch(Format(MESSAGE_HEADER_MISMATCH,
      ['Mcp-Name', Decoded, BodyValue]));
end;

function TMCPJsonRpcProcessor.NewContext(Era: TMCPProtocolEra; const Version, Method: string;
  const RequestId: TMCPRequestId; const Meta: TJSONObject; const Hints: TMCPTransportHints;
  const InputResponses: TJSONObject; const RequestState: TJSONObject): IMCPRequestContext;
begin
  Result := TMCPRequestContext.Create(Era, Version, Method, RequestId, Meta, Hints.LegacySession, FManagerRegistry,
    Hints.Sink, InputResponses, RequestState, Hints.Principal, Hints.Scopes);
end;

function TMCPJsonRpcProcessor.BuildRequestContext(const Method: string; const Params: TJSONObject;
  const RequestId: TMCPRequestId; const Hints: TMCPTransportHints): IMCPRequestContext;
begin
  const Meta = ExtractMeta(Params);

  var VersionValue: TJSONValue := nil;
  if Assigned(Meta) then
    VersionValue := Meta.GetValue(MCP_META_PROTOCOL_VERSION);

  const CarriesModernMeta = (VersionValue is TJSONString);
  if CarriesModernMeta then
    begin
      Result := ModernContext(Method, Params, RequestId, Meta, TJSONString(VersionValue).Value, Hints);
      Exit;
    end;

  Result := LegacyContext(Method, Params, RequestId, Meta, Hints);
end;

function TMCPJsonRpcProcessor.ModernContext(const Method: string; const Params: TJSONObject;
  const RequestId: TMCPRequestId; const Meta: TJSONObject; const Version: string;
  const Hints: TMCPTransportHints): IMCPRequestContext;
begin
  if Hints.HasHeaderLayer then
  begin
    if not Hints.HasProtocolVersionHeader then
      raise EMCPError.HeaderMismatch('MCP-Protocol-Version header is missing');
    if Hints.ProtocolVersionHeader <> Version then
      raise EMCPError.HeaderMismatch(Format(MESSAGE_HEADER_MISMATCH,
        ['MCP-Protocol-Version', Hints.ProtocolVersionHeader, Version]));
  end;

  if not TMCPProtocolVersion.IsModern(Version) then
    raise EMCPError.UnsupportedProtocolVersion(Version, SupportedModernVersions);

  if Hints.HasHeaderLayer then
    ValidateMirroredHeaders(Method, Params, Hints);

  ValidateModernMeta(Meta);

  if IsLegacyOnlyMethod(Method) then
  begin
    const NotFound = EMCPError.MethodNotFound(Method);
    NotFound.HttpStatus := HTTP_STATUS_NOT_FOUND;
    raise NotFound;
  end;

  var InputResponses: TJSONObject := nil;
  var RequestState: TJSONObject := nil;
  if IsInputRequiredMethod(Method) then
  begin
    InputResponses := ClientInputResponses(Params);
    RequestState := OpenClientRequestState(Method, Params, Hints);
  end;
  Result := NewContext(TMCPProtocolEra.Modern, Version, Method, RequestId, Meta, Hints, InputResponses, RequestState);
end;

function TMCPJsonRpcProcessor.LegacyContext(const Method: string; const Params: TJSONObject;
  const RequestId: TMCPRequestId; const Meta: TJSONObject; const Hints: TMCPTransportHints): IMCPRequestContext;
begin
  if Method = MCP_METHOD_INITIALIZE then
  begin
    var Requested := '';
    if Assigned(Params) then
    begin
      const RequestedValue = Params.GetValue(MCP_KEY_PROTOCOL_VERSION);
      if IsJsonString(RequestedValue) then
        Requested := TJSONString(RequestedValue).Value;
    end;
    const Negotiated = TMCPProtocolVersion.NegotiateLegacy(Requested);
    begin
      Result := NewContext(TMCPProtocolEra.Legacy, Negotiated, Method, RequestId, Meta, Hints);
      Exit;
    end;
  end;

  if IsModernOnlyMethod(Method) then
    raise EMCPError.Create(JSONRPC_INVALID_PARAMS,
      Format('%s requires %s%s', [Method, META_PATH_PREFIX, MCP_META_PROTOCOL_VERSION]), nil, HTTP_STATUS_BAD_REQUEST);

  const HasVersionHeader = (Hints.HasHeaderLayer and Hints.HasProtocolVersionHeader);
  if HasVersionHeader then
  begin
    const Header = Hints.ProtocolVersionHeader;
    if TMCPProtocolVersion.IsModern(Header) then
      raise EMCPError.Create(JSONRPC_INVALID_PARAMS,
        Format('MCP-Protocol-Version %s requires %s%s', [Header, META_PATH_PREFIX, MCP_META_PROTOCOL_VERSION]),
        nil, HTTP_STATUS_BAD_REQUEST);

    const IsKnownHeader = (TMCPProtocolVersion.IsLegacy(Header) or (Header = MCP_PROTOCOL_VERSION_2025_03_26));
    if not IsKnownHeader then
      raise EMCPError.Create(JSONRPC_INVALID_REQUEST,
        Format('Unsupported MCP-Protocol-Version header: %s', [Header]), nil, HTTP_STATUS_BAD_REQUEST);

    begin
      Result := NewContext(TMCPProtocolEra.Legacy, Header, Method, RequestId, Meta, Hints);
      Exit;
    end;
  end;

  var Version := '';
  if Assigned(Hints.LegacySession) then
    Version := Hints.LegacySession.ProtocolVersion;
  if Version = '' then
    Version := MCP_LATEST_LEGACY_PROTOCOL_VERSION;

  Result := NewContext(TMCPProtocolEra.Legacy, Version, Method, RequestId, Meta, Hints);
end;

function TMCPJsonRpcProcessor.ProcessNotification(const Method: string; const Params: TJSONObject;
  const Hints: TMCPTransportHints): TMCPProcessResult;
begin
  Result := Default(TMCPProcessResult);
  Result.HttpStatus := HTTP_STATUS_ACCEPTED;
  Result.Era := EraFromHeaders(Hints);
  Result.IsNotification := True;

  TLogger.Info('Notification received: ' + Method);

  if Method = MCP_METHOD_NOTIFICATIONS_CANCELLED then
  begin
    HandleCancelled(Params, Hints);
    Exit;
  end;

  var Manager: IMCPCapabilityManager := nil;
  if Assigned(FManagerRegistry) then
    Manager := FManagerRegistry.GetManagerForMethod(Method);
  if not Assigned(Manager) then
    Exit;

  try
    Manager.ExecuteMethod(Method, Params);
  except
    on E: Exception do
      TLogger.Error('Notification ' + Method + ' failed: ' + E.Message);
  end;
end;

procedure TMCPJsonRpcProcessor.HandleCancelled(const Params: TJSONObject; const Hints: TMCPTransportHints);
begin
  if not Assigned(Hints.Tracker) or not Assigned(Params) then
    Exit;

  var RequestId := TMCPRequestId.FromJson(Params.GetValue('requestId'));
  if not RequestId.IsPresent then
  begin
    TLogger.Warning('notifications/cancelled without a usable requestId');
    Exit;
  end;

  var Reason := '';
  var ReasonValue := Params.GetValue('reason');
  if IsJsonString(ReasonValue) then
    Reason := TJSONString(ReasonValue).Value;

  if not Hints.Tracker.TryCancel(RequestId, Reason) then
    TLogger.Debug('notifications/cancelled for unknown or finished request ' + RequestId.AsText);
end;

function TMCPJsonRpcProcessor.CancelledResult(Era: TMCPProtocolEra): TMCPProcessResult;
begin
  Result := Default(TMCPProcessResult);
  Result.HttpStatus := HTTP_STATUS_OK;
  Result.Era := Era;
  Result.Cancelled := True;
end;

function TMCPJsonRpcProcessor.InputRequiredResult(const Context: IMCPRequestContext; const Params: TJSONObject;
  const Hints: TMCPTransportHints; const Required: EMCPInputRequired): TMCPProcessResult;
begin
  if Context.Era = TMCPProtocolEra.Legacy then
    raise EMCPError.InternalError(Format(
      '%s needs input from the client, which protocol version %s cannot deliver',
      [Context.Method, Context.ProtocolVersion]));
  if not IsInputRequiredMethod(Context.Method) then
    raise EMCPError.InternalError(Format('%s must not answer with an InputRequiredResult', [Context.Method]));
  if (Required.Requests.Count = 0) and not Assigned(Required.State) then
    raise EMCPError.InternalError('An InputRequiredResult needs inputRequests or requestState');

  for var Method in Required.Requests.Methods do
  begin
    var Capability := TMCPInputRequests.RequiredCapability(Method);
    if Capability = '' then
      raise EMCPError.InternalError(Format('%s is not a request a client can answer', [Method]));
    Context.RequireClientCapability(Capability);
  end;

  var ResultObject := TJSONObject.Create;
  try
    ResultObject.AddPair(MCP_KEY_RESULT_TYPE, RESULT_TYPE_INPUT_REQUIRED);
    if Required.Requests.Count > 0 then
      ResultObject.AddPair('inputRequests', Required.Requests.ToJson);
    if Assigned(Required.State) then
      ResultObject.AddPair(PARAM_REQUEST_STATE, FStateSealer.Seal(Required.State, Context.Method,
        TMCPRequestStateSealer.DigestOf(Params), Hints.Principal));
    ApplyModernEnvelope(ResultObject, Context.Method);

    const Response = TJSONObject.Create;
    try
      Response.AddPair(MCP_KEY_JSONRPC, JSONRPC_VERSION);
      Response.AddPair(MCP_KEY_ID, Context.RequestId.ToJson);
      Response.AddPair(MCP_KEY_RESULT, TJSONObject(ResultObject.Clone));
      Result.Body := Response.ToJSON;
    finally
      Response.Free;
    end;
  finally
    ResultObject.Free;
  end;
  Result.HttpStatus := HTTP_STATUS_OK;
  Result.Era := Context.Era;
  Result.IsNotification := False;
  Result.Cancelled := False;
end;

function TMCPJsonRpcProcessor.BuildErrorResponse(const RequestId: TMCPRequestId; const Error: EMCPError): string;
begin
  Result := ErrorResult(TMCPProtocolEra.Legacy, RequestId, Error).Body;
end;

function TMCPJsonRpcProcessor.DispatchRequest(const Context: IMCPRequestContext; const Params: TJSONObject): TValue;
var
  ManagerEx: IMCPCapabilityManagerEx;
begin
  if not Assigned(FManagerRegistry) then
    raise EMCPError.InternalError('Manager registry not initialized');

  var Manager := FManagerRegistry.GetManagerForMethod(Context.Method);
  if not Assigned(Manager) then
    raise EMCPError.MethodNotFound(Context.Method);

  const Previous = TMCPRequestContext.SetCurrent(Context);
  try
    if Supports(Manager, IMCPCapabilityManagerEx, ManagerEx) then
      Result := ManagerEx.ExecuteMethodWithContext(Context.Method, Params, Context)
    else
      Result := Manager.ExecuteMethod(Context.Method, Params);
  finally
    TMCPRequestContext.SetCurrent(Previous);
  end;
end;

procedure TMCPJsonRpcProcessor.ApplyModernEnvelope(const ResultObject: TJSONObject; const Method: string);
begin
  if not Assigned(ResultObject.GetValue(MCP_KEY_RESULT_TYPE)) then
    ResultObject.AddPair(MCP_KEY_RESULT_TYPE, RESULT_TYPE_COMPLETE);

  var MetaValue := ResultObject.GetValue(MCP_KEY_META);
  var Meta: TJSONObject := nil;
  if MetaValue is TJSONObject then
    Meta := TJSONObject(MetaValue)
  else if not Assigned(MetaValue) then
  begin
    Meta := TJSONObject.Create;
    ResultObject.AddPair(MCP_KEY_META, Meta);
  end;
  if Assigned(Meta) and not Assigned(Meta.GetValue(MCP_META_SERVER_INFO)) then
    Meta.AddPair(MCP_META_SERVER_INFO, BuildServerInfo);

  var ResultType := ResultObject.GetValue(MCP_KEY_RESULT_TYPE);
  if IsCacheableMethod(Method) and (ResultType is TJSONString)
    and (TJSONString(ResultType).Value = RESULT_TYPE_COMPLETE) then
  begin
    if not Assigned(ResultObject.GetValue(MCP_KEY_TTL_MS)) then
      ResultObject.AddPair(MCP_KEY_TTL_MS, TJSONNumber.Create(0));
    if not Assigned(ResultObject.GetValue(MCP_KEY_CACHE_SCOPE)) then
      ResultObject.AddPair(MCP_KEY_CACHE_SCOPE, MCP_CACHE_SCOPE_PRIVATE);
  end;
end;

function TMCPJsonRpcProcessor.ResultToJson(const Value: TValue; const Context: IMCPRequestContext): TJSONValue;
begin
  if Context.Era = TMCPProtocolEra.Legacy then
  begin
    if Value.IsEmpty then
      Result := nil
    else if Value.IsType<TJSONObject> then
      Result := Value.AsType<TJSONObject>
    else if Value.IsType<string> then
      Result := TJSONString.Create(Value.AsString)
    else
    begin
      if Value.IsObject then
        raise EMCPError.InternalError(Format(MESSAGE_NOT_A_JSON_RESULT,
          [Context.Method, Value.AsObject.ClassName]));
      Result := TJSONString.Create(Value.ToString);
    end;
    Exit;
  end;

  var ResultObject: TJSONObject;
  if Value.IsType<TJSONObject> then
    ResultObject := Value.AsType<TJSONObject>
  else
  begin
    if Value.IsObject then
      raise EMCPError.InternalError(Format(MESSAGE_NOT_A_JSON_RESULT,
        [Context.Method, Value.AsObject.ClassName]));
    ResultObject := TJSONObject.Create;
    if not Value.IsEmpty then
      ResultObject.AddPair('value', Value.ToString);
  end;

  ApplyModernEnvelope(ResultObject, Context.Method);
  Result := ResultObject;
end;

function TMCPJsonRpcProcessor.StatusForError(Era: TMCPProtocolEra; const Error: EMCPError): Integer;
begin
  if Era = TMCPProtocolEra.Legacy then
  begin
    if (Error.HttpStatus = HTTP_STATUS_BAD_REQUEST) or (Error.HttpStatus = HTTP_STATUS_FORBIDDEN) then
      Exit(Error.HttpStatus);
    Exit(HTTP_STATUS_OK);
  end;

  if Error.HttpStatus <> 0 then
    Exit(Error.HttpStatus);

  case Error.Code of
    JSONRPC_PARSE_ERROR, JSONRPC_INVALID_REQUEST,
    MCP_ERROR_HEADER_MISMATCH, MCP_ERROR_MISSING_REQUIRED_CLIENT_CAPABILITY,
    MCP_ERROR_UNSUPPORTED_PROTOCOL_VERSION:
      Result := HTTP_STATUS_BAD_REQUEST;
    JSONRPC_METHOD_NOT_FOUND:
      Result := HTTP_STATUS_NOT_FOUND;
  else
    Result := HTTP_STATUS_OK;
  end;
end;

function TMCPJsonRpcProcessor.ErrorResult(Era: TMCPProtocolEra; const RequestId: TMCPRequestId;
  const Error: EMCPError): TMCPProcessResult;
begin
  TLogger.Error('Error processing request: ' + Error.Message);
  var RequiredScope := '';
  if Error.HttpStatus = HTTP_STATUS_FORBIDDEN then
    RequiredScope := Error.RequiredScope;

  var Response := TJSONObject.Create;
  try
    Response.AddPair(MCP_KEY_JSONRPC, JSONRPC_VERSION);
    Response.AddPair(MCP_KEY_ID, RequestId.ToJson);

    var ErrorObject := TJSONObject.Create;
    Response.AddPair(MCP_KEY_ERROR, ErrorObject);
    ErrorObject.AddPair('code', TJSONNumber.Create(Error.Code));
    ErrorObject.AddPair('message', Error.Message);
    if Assigned(Error.Data) then
      ErrorObject.AddPair('data', Error.DetachData);

    Result.Body := Response.ToJSON;
  finally
    Response.Free;
  end;

  Result.HttpStatus := StatusForError(Era, Error);
  Result.Era := Era;
  Result.IsNotification := False;
  Result.Cancelled := False;
  Result.RequiredScope := RequiredScope;
end;

function TMCPJsonRpcProcessor.ExceptionToError(Era: TMCPProtocolEra; const E: Exception): EMCPError;
begin
  if E is EMCPRegistryNotFound then
    Result := EMCPError.Create(JSONRPC_METHOD_NOT_FOUND, E.Message)
  else
    Result := EMCPError.InternalError(E.Message);
end;

function TMCPJsonRpcProcessor.ReadRequestObject(const Message: TJSONValue): TJSONObject;
begin
  if not Assigned(Message) then
    raise EMCPError.ParseError('Invalid JSON');
  if Message is TJSONArray then
    raise EMCPError.InvalidRequest('JSON-RPC batch requests are not supported');
  if not (Message is TJSONObject) then
    raise EMCPError.InvalidRequest('JSON-RPC message must be an object');
  Result := TJSONObject(Message);
end;

function TMCPJsonRpcProcessor.ReadRequestId(const Request: TJSONObject): TMCPRequestId;
begin
  Result := TMCPRequestId.FromJson(Request.GetValue(MCP_KEY_ID));
  if Result.Kind = TMCPRequestIdKind.Null then
    raise EMCPError.InvalidRequest('id must not be null');
  if Result.Kind = TMCPRequestIdKind.Invalid then
  begin
    Result := TMCPRequestId.FromJson(nil);
    raise EMCPError.InvalidRequest('id must be a string or an integer');
  end;
end;

function TMCPJsonRpcProcessor.ReadMethod(const Request: TJSONObject; Era: TMCPProtocolEra;
  out IsClientResponse: Boolean): string;
begin
  IsClientResponse := False;
  const JsonRpc = Request.GetValue(MCP_KEY_JSONRPC);
  const IsSupportedVersion = (IsJsonString(JsonRpc) and (TJSONString(JsonRpc).Value = JSONRPC_VERSION));
  if not IsSupportedVersion then
    raise EMCPError.InvalidRequest('jsonrpc must be "2.0"');

  const MethodValue = Request.GetValue(MCP_KEY_METHOD);
  if IsJsonString(MethodValue) then
    begin
      Result := TJSONString(MethodValue).Value;
      Exit;
    end;

  const IsResponse = (Assigned(Request.GetValue(MCP_KEY_RESULT)) or Assigned(Request.GetValue(MCP_KEY_ERROR)));
  if not IsResponse then
    raise EMCPError.InvalidRequest('method must be a string');
  if Era = TMCPProtocolEra.Modern then
    raise EMCPError.InvalidRequest('JSON-RPC responses are not accepted');

  IsClientResponse := True;
  Result := '';
end;

function TMCPJsonRpcProcessor.ReadParams(const Request: TJSONObject; Era: TMCPProtocolEra): TJSONObject;
begin
  Result := nil;
  const ParamsValue = Request.GetValue(MCP_KEY_PARAMS);
  if not Assigned(ParamsValue) then
    Exit;

  if not (ParamsValue is TJSONObject) then
  begin
    if Era = TMCPProtocolEra.Modern then
      raise EMCPError.Create(JSONRPC_INVALID_PARAMS, MESSAGE_PARAMS_NOT_OBJECT, nil, HTTP_STATUS_BAD_REQUEST);
    raise EMCPError.InvalidParams(MESSAGE_PARAMS_NOT_OBJECT);
  end;
  Result := TJSONObject(ParamsValue);
end;

function TMCPJsonRpcProcessor.AcceptedResult(Era: TMCPProtocolEra): TMCPProcessResult;
begin
  Result := Default(TMCPProcessResult);
  Result.HttpStatus := HTTP_STATUS_ACCEPTED;
  Result.Era := Era;
  Result.IsNotification := True;
end;

function TMCPJsonRpcProcessor.RunRequest(const Context: IMCPRequestContext; const Params: TJSONObject;
  const Hints: TMCPTransportHints): TMCPProcessResult;
var
  ExecuteResult: TValue;
begin
  if Assigned(Hints.Tracker) then
    Hints.Tracker.Track(Context);
  try
    try
      ExecuteResult := DispatchRequest(Context, Params);
    except
      on E: EMCPInputRequired do
        begin
          Result := InputRequiredResult(Context, Params, Hints, E);
          Exit;
        end;
    end;
  finally
    if Assigned(Hints.Tracker) then
      Hints.Tracker.Untrack(Context);
  end;

  if Context.IsCancelled then
  begin
    if ExecuteResult.IsObject then
      ExecuteResult.AsObject.Free;
    begin
      Result := CancelledResult(Context.Era);
      Exit;
    end;
  end;

  Result := SuccessResult(Context, ExecuteResult);
end;

function TMCPJsonRpcProcessor.SuccessResult(const Context: IMCPRequestContext; const Value: TValue): TMCPProcessResult;
begin
  Result := Default(TMCPProcessResult);
  const Response = TJSONObject.Create;
  try
    Response.AddPair(MCP_KEY_JSONRPC, JSONRPC_VERSION);
    Response.AddPair(MCP_KEY_ID, Context.RequestId.ToJson);
    const ResultJson = ResultToJson(Value, Context);
    if Assigned(ResultJson) then
      Response.AddPair(MCP_KEY_RESULT, ResultJson);
    Result.Body := Response.ToJSON;
  finally
    Response.Free;
  end;
  Result.HttpStatus := HTTP_STATUS_OK;
  Result.Era := Context.Era;
end;

function TMCPJsonRpcProcessor.ProcessRequest(const RequestBody: string; const SessionID: string): string;
begin
  Result := ProcessRequestEx(RequestBody, TMCPTransportHints.None).Body;
end;

function TMCPJsonRpcProcessor.ProcessRequestEx(const RequestBody: string;
  const Hints: TMCPTransportHints): TMCPProcessResult;
begin
  var Message := TJSONObject.ParseJSONValue(RequestBody);
  try
    Result := ProcessRequestEx(Message, Hints);
  finally
    Message.Free;
  end;
end;

function TMCPJsonRpcProcessor.ProcessRequestEx(const Message: TJSONValue;
  const Hints: TMCPTransportHints): TMCPProcessResult;
var
  RequestId: TMCPRequestId;
  Era: TMCPProtocolEra;
  Context: IMCPRequestContext;
begin
  RequestId := TMCPRequestId.FromJson(nil);
  Era := EraFromHeaders(Hints);
  Context := nil;

  try
    try
      const Request = ReadRequestObject(Message);
      RequestId := ReadRequestId(Request);

      var IsClientResponse := False;
      const Method = ReadMethod(Request, Era, IsClientResponse);
      if IsClientResponse then
        begin
          Result := AcceptedResult(Era);
          Exit;
        end;

      const Params = ReadParams(Request, Era);
      if RequestId.Kind = TMCPRequestIdKind.None then
        begin
          Result := ProcessNotification(Method, Params, Hints);
          Exit;
        end;

      Era := EraFromMessage(Method, Params, Hints);
      Context := BuildRequestContext(Method, Params, RequestId, Hints);
      Era := Context.Era;
      Result := RunRequest(Context, Params, Hints);
    except
      on E: EMCPRequestCancelled do
        Result := CancelledResult(Era);
      on E: EMCPError do
        Result := ErrorResult(Era, RequestId, E);
      on E: Exception do
      begin
        var Error := ExceptionToError(Era, E);
        try
          Result := ErrorResult(Era, RequestId, Error);
        finally
          Error.Free;
        end;
      end;
    end;
  finally
    Context := nil;
  end;
end;

end.
