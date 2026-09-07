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
  JSONRPC_VERSION = '2.0';
  RESULT_TYPE_COMPLETE = 'complete';
  CACHE_SCOPE_PRIVATE = 'private';

  LEGACY_ONLY_METHODS: array[0..4] of string = (
    'ping', 'initialize', 'logging/setLevel', 'resources/subscribe', 'resources/unsubscribe');
  MODERN_ONLY_METHODS: array[0..1] of string = ('server/discover', 'subscriptions/listen');
  INPUT_REQUIRED_METHODS: array[0..2] of string = ('tools/call', 'resources/read', 'prompts/get');
  PARAM_INPUT_RESPONSES = 'inputResponses';
  PARAM_REQUEST_STATE = 'requestState';

function InArray(const Value: string; const Values: array of string): Boolean;
begin
  for var Item in Values do
    if Item = Value then
      Exit(True);
  Result := False;
end;

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
  Result.AddPair('name', FSettings.ServerName);
  Result.AddPair('version', FSettings.ServerVersion);
  if FSettings.ServerTitle <> '' then
    Result.AddPair('title', FSettings.ServerTitle);
  if FSettings.ServerDescription <> '' then
    Result.AddPair('description', FSettings.ServerDescription);
  if FSettings.ServerWebsiteUrl <> '' then
    Result.AddPair('websiteUrl', FSettings.ServerWebsiteUrl);
end;

function TMCPJsonRpcProcessor.IsLegacyOnlyMethod(const Method: string): Boolean;
begin
  Result := InArray(Method, LEGACY_ONLY_METHODS);
  if Result and (Method = 'ping') and FSettings.LenientModernPing then
    Result := False;
end;

function TMCPJsonRpcProcessor.IsModernOnlyMethod(const Method: string): Boolean;
begin
  Result := InArray(Method, MODERN_ONLY_METHODS);
end;

function TMCPJsonRpcProcessor.IsCacheableMethod(const Method: string): Boolean;
begin
  Result := InArray(Method, MCP_CACHEABLE_METHODS);
end;

function TMCPJsonRpcProcessor.IsInputRequiredMethod(const Method: string): Boolean;
begin
  Result := InArray(Method, INPUT_REQUIRED_METHODS);
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
    and IsModernProtocolVersion(Hints.ProtocolVersionHeader) then
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

  var MetaValue := Params.GetValue('_meta');
  if (MetaValue is TJSONObject) and (TJSONObject(MetaValue).GetValue(MCP_META_PROTOCOL_VERSION) is TJSONString) then
    Result := TMCPProtocolEra.Modern;
end;

function TMCPJsonRpcProcessor.ExtractMeta(const Params: TJSONObject): TJSONObject;
begin
  Result := nil;
  if not Assigned(Params) then
    Exit;

  var MetaValue := Params.GetValue('_meta');
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
      'params._meta.' + MCP_META_CLIENT_CAPABILITIES + ' is required and must be an object',
      nil, HTTP_STATUS_BAD_REQUEST);

  var ClientInfo := Meta.GetValue(MCP_META_CLIENT_INFO);
  if Assigned(ClientInfo) and not (ClientInfo is TJSONObject) then
    raise EMCPError.Create(JSONRPC_INVALID_PARAMS,
      'params._meta.' + MCP_META_CLIENT_INFO + ' must be an object', nil, HTTP_STATUS_BAD_REQUEST);

  var LogLevel := Meta.GetValue(MCP_META_LOG_LEVEL);
  if Assigned(LogLevel) and (not IsJsonString(LogLevel) or not TMCPLogLevel.IsKnown(TJSONString(LogLevel).Value)) then
    raise EMCPError.Create(JSONRPC_INVALID_PARAMS,
      'params._meta.' + MCP_META_LOG_LEVEL + ' must be one of debug, info, notice, warning, error, critical, alert, emergency',
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
    raise EMCPError.HeaderMismatch(Format(
      'Header mismatch: Mcp-Method header value ''%s'' does not match body value ''%s''',
      [Hints.MethodHeader, Method]));

  var SourceField := '';
  if (Method = 'tools/call') or (Method = 'prompts/get') then
    SourceField := 'name'
  else if Method = 'resources/read' then
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
    raise EMCPError.HeaderMismatch(Format(
      'Header mismatch: Mcp-Name header value ''%s'' does not match body value ''%s''',
      [Decoded, BodyValue]));
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
var
  Version: string;
begin
  var Meta := ExtractMeta(Params);

  var VersionValue: TJSONValue := nil;
  if Assigned(Meta) then
    VersionValue := Meta.GetValue(MCP_META_PROTOCOL_VERSION);

  if VersionValue is TJSONString then
  begin
    Version := TJSONString(VersionValue).Value;

    if Hints.HasHeaderLayer then
    begin
      if not Hints.HasProtocolVersionHeader then
        raise EMCPError.HeaderMismatch('MCP-Protocol-Version header is missing');
      if Hints.ProtocolVersionHeader <> Version then
        raise EMCPError.HeaderMismatch(Format(
          'Header mismatch: MCP-Protocol-Version header value ''%s'' does not match body value ''%s''',
          [Hints.ProtocolVersionHeader, Version]));
    end;

    if not IsModernProtocolVersion(Version) then
      raise EMCPError.UnsupportedProtocolVersion(Version, SupportedModernVersions);

    if Hints.HasHeaderLayer then
      ValidateMirroredHeaders(Method, Params, Hints);

    ValidateModernMeta(Meta);

    if IsLegacyOnlyMethod(Method) then
    begin
      var NotFound := EMCPError.MethodNotFound(Method);
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
    Exit(NewContext(TMCPProtocolEra.Modern, Version, Method, RequestId, Meta, Hints, InputResponses, RequestState));
  end;

  if Method = 'initialize' then
  begin
    var Requested := '';
    if Assigned(Params) then
    begin
      var RequestedValue := Params.GetValue('protocolVersion');
      if IsJsonString(RequestedValue) then
        Requested := TJSONString(RequestedValue).Value;
    end;
    Exit(NewContext(TMCPProtocolEra.Legacy, NegotiateLegacyProtocolVersion(Requested), Method, RequestId, Meta, Hints));
  end;

  if IsModernOnlyMethod(Method) then
    raise EMCPError.Create(JSONRPC_INVALID_PARAMS,
      Format('%s requires params._meta.%s', [Method, MCP_META_PROTOCOL_VERSION]), nil, HTTP_STATUS_BAD_REQUEST);

  if Hints.HasHeaderLayer and Hints.HasProtocolVersionHeader then
  begin
    var Header := Hints.ProtocolVersionHeader;
    if IsModernProtocolVersion(Header) then
      raise EMCPError.Create(JSONRPC_INVALID_PARAMS,
        Format('MCP-Protocol-Version %s requires params._meta.%s', [Header, MCP_META_PROTOCOL_VERSION]),
        nil, HTTP_STATUS_BAD_REQUEST);
    if not IsLegacyProtocolVersion(Header) and (Header <> MCP_PROTOCOL_VERSION_2025_03_26) then
      raise EMCPError.Create(JSONRPC_INVALID_REQUEST,
        'Unsupported MCP-Protocol-Version header: ' + Header, nil, HTTP_STATUS_BAD_REQUEST);

    Exit(NewContext(TMCPProtocolEra.Legacy, Header, Method, RequestId, Meta, Hints));
  end;

  Version := '';
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
    ResultObject.AddPair('resultType', RESULT_TYPE_INPUT_REQUIRED);
    if Required.Requests.Count > 0 then
      ResultObject.AddPair('inputRequests', Required.Requests.ToJson);
    if Assigned(Required.State) then
      ResultObject.AddPair(PARAM_REQUEST_STATE, FStateSealer.Seal(Required.State, Context.Method,
        TMCPRequestStateSealer.DigestOf(Params), Hints.Principal));
    ApplyModernEnvelope(ResultObject, Context.Method);

    const Response = TJSONObject.Create;
    try
      Response.AddPair('jsonrpc', JSONRPC_VERSION);
      Response.AddPair('id', Context.RequestId.ToJson);
      Response.AddPair('result', TJSONObject(ResultObject.Clone));
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
  if not Assigned(ResultObject.GetValue('resultType')) then
    ResultObject.AddPair('resultType', RESULT_TYPE_COMPLETE);

  var MetaValue := ResultObject.GetValue('_meta');
  var Meta: TJSONObject := nil;
  if MetaValue is TJSONObject then
    Meta := TJSONObject(MetaValue)
  else if not Assigned(MetaValue) then
  begin
    Meta := TJSONObject.Create;
    ResultObject.AddPair('_meta', Meta);
  end;
  if Assigned(Meta) and not Assigned(Meta.GetValue(MCP_META_SERVER_INFO)) then
    Meta.AddPair(MCP_META_SERVER_INFO, BuildServerInfo);

  var ResultType := ResultObject.GetValue('resultType');
  if IsCacheableMethod(Method) and (ResultType is TJSONString)
    and (TJSONString(ResultType).Value = RESULT_TYPE_COMPLETE) then
  begin
    if not Assigned(ResultObject.GetValue('ttlMs')) then
      ResultObject.AddPair('ttlMs', TJSONNumber.Create(0));
    if not Assigned(ResultObject.GetValue('cacheScope')) then
      ResultObject.AddPair('cacheScope', CACHE_SCOPE_PRIVATE);
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
        raise EMCPError.InternalError(Format('%s answered with a %s instead of a JSON object',
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
      raise EMCPError.InternalError(Format('%s answered with a %s instead of a JSON object',
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
    Response.AddPair('jsonrpc', JSONRPC_VERSION);
    Response.AddPair('id', RequestId.ToJson);

    var ErrorObject := TJSONObject.Create;
    Response.AddPair('error', ErrorObject);
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
      if not Assigned(Message) then
        raise EMCPError.ParseError('Invalid JSON');
      if Message is TJSONArray then
        raise EMCPError.InvalidRequest('JSON-RPC batch requests are not supported');
      if not (Message is TJSONObject) then
        raise EMCPError.InvalidRequest('JSON-RPC message must be an object');

      var Request := TJSONObject(Message);

      RequestId := TMCPRequestId.FromJson(Request.GetValue('id'));
      if RequestId.Kind = TMCPRequestIdKind.Null then
        raise EMCPError.InvalidRequest('id must not be null');
      if RequestId.Kind = TMCPRequestIdKind.Invalid then
      begin
        RequestId := TMCPRequestId.FromJson(nil);
        raise EMCPError.InvalidRequest('id must be a string or an integer');
      end;

      var JsonRpc := Request.GetValue('jsonrpc');
      if not IsJsonString(JsonRpc) or (TJSONString(JsonRpc).Value <> JSONRPC_VERSION) then
        raise EMCPError.InvalidRequest('jsonrpc must be "2.0"');

      var MethodValue := Request.GetValue('method');
      if not IsJsonString(MethodValue) then
      begin
        if Assigned(Request.GetValue('result')) or Assigned(Request.GetValue('error')) then
        begin
          if Era = TMCPProtocolEra.Modern then
            raise EMCPError.InvalidRequest('JSON-RPC responses are not accepted');
          Result := Default(TMCPProcessResult);
          Result.HttpStatus := HTTP_STATUS_ACCEPTED;
          Result.Era := Era;
          Result.IsNotification := True;
          Exit;
        end;
        raise EMCPError.InvalidRequest('method must be a string');
      end;
      var Method := TJSONString(MethodValue).Value;

      var ParamsValue := Request.GetValue('params');
      var Params: TJSONObject := nil;
      if Assigned(ParamsValue) then
      begin
        if not (ParamsValue is TJSONObject) then
        begin
          if Era = TMCPProtocolEra.Modern then
            raise EMCPError.Create(JSONRPC_INVALID_PARAMS, 'params must be an object', nil, HTTP_STATUS_BAD_REQUEST);
          raise EMCPError.InvalidParams('params must be an object');
        end;
        Params := TJSONObject(ParamsValue);
      end;

      if RequestId.Kind = TMCPRequestIdKind.None then
        Exit(ProcessNotification(Method, Params, Hints));

      Era := EraFromMessage(Method, Params, Hints);
      Context := BuildRequestContext(Method, Params, RequestId, Hints);
      Era := Context.Era;

      var ExecuteResult: TValue;
      if Assigned(Hints.Tracker) then
        Hints.Tracker.Track(Context);
      try
        try
          ExecuteResult := DispatchRequest(Context, Params);
        except
          on E: EMCPInputRequired do
            Exit(InputRequiredResult(Context, Params, Hints, E));
        end;
      finally
        if Assigned(Hints.Tracker) then
          Hints.Tracker.Untrack(Context);
      end;

      if Context.IsCancelled then
      begin
        if ExecuteResult.IsObject then
          ExecuteResult.AsObject.Free;
        Exit(CancelledResult(Era));
      end;

      var Response := TJSONObject.Create;
      try
        Response.AddPair('jsonrpc', JSONRPC_VERSION);
        Response.AddPair('id', RequestId.ToJson);
        var ResultJson := ResultToJson(ExecuteResult, Context);
        if Assigned(ResultJson) then
          Response.AddPair('result', ResultJson);
        Result.Body := Response.ToJSON;
      finally
        Response.Free;
      end;
      Result.HttpStatus := HTTP_STATUS_OK;
      Result.Era := Era;
      Result.IsNotification := False;
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
