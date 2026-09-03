unit MCPServer.JsonRpcProcessor;

interface

uses
  System.SysUtils,
  System.JSON,
  System.Rtti,
  MCPServer.Types,
  MCPServer.Settings,
  MCPServer.RequestContext,
  MCPServer.Errors,
  MCPServer.Logger;

type
  /// Outcome of one JSON-RPC message. Body is empty when nothing must be
  /// sent back (notifications, client responses). HttpStatus is the status
  /// a Streamable HTTP transport should answer with.
  TMCPProcessResult = record
    Body: string;
    HttpStatus: Integer;
    Era: TMCPProtocolEra;
    IsNotification: Boolean;
  end;

  /// Transport-independent JSON-RPC pipeline: parse, validate the message
  /// shape, detect the protocol era, dispatch to the owning manager, shape
  /// the result for the era and decide the HTTP status.
  TMCPJsonRpcProcessor = class
  private
    FManagerRegistry: IMCPManagerRegistry;
    FSettings: TMCPSettings;
    FOwnsSettings: Boolean;
    procedure SetSettings(const Value: TMCPSettings);
    function SupportedModernVersions: TArray<string>;
    function BuildServerInfo: TJSONObject;
    function IsLegacyOnlyMethod(const Method: string): Boolean;
    function IsModernOnlyMethod(const Method: string): Boolean;
    function IsCacheableMethod(const Method: string): Boolean;
    function EraFromHeaders(const Hints: TMCPTransportHints): TMCPProtocolEra;
    function EraFromMessage(const Method: string; const Params: TJSONObject;
      const Hints: TMCPTransportHints): TMCPProtocolEra;
    function ExtractMeta(const Params: TJSONObject): TJSONObject;
    procedure ValidateModernMeta(const Meta: TJSONObject);
    function ProcessNotification(const Method: string; const Params: TJSONObject;
      const Hints: TMCPTransportHints): TMCPProcessResult;
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

    /// Plain JSON-RPC layer without transport hints; returns the response body.
    function ProcessRequest(const RequestBody: string; const SessionID: string): string;
    function ProcessRequestEx(const RequestBody: string; const Hints: TMCPTransportHints): TMCPProcessResult; overload;
    /// Message is the already parsed body (nil when parsing failed); the
    /// caller keeps ownership.
    function ProcessRequestEx(const Message: TJSONValue; const Hints: TMCPTransportHints): TMCPProcessResult; overload;

    /// Decides the era of a request and validates the modern _meta fields.
    /// Raises EMCPError with the HTTP status a modern transport must use.
    function BuildRequestContext(const Method: string; const Params: TJSONObject;
      const RequestId: TMCPRequestId; const Hints: TMCPTransportHints): IMCPRequestContext;

    property ManagerRegistry: IMCPManagerRegistry read FManagerRegistry;
    /// Server identity and protocol options. A processor created without
    /// settings uses the defaults (settings.ini next to the executable when present).
    property Settings: TMCPSettings read FSettings write SetSettings;
  end;

const
  // The JSON-RPC error codes are defined in MCPServer.Types. These aliases
  // keep consumer code that references MCPServer.JsonRpcProcessor.JSONRPC_*
  // compiling.
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

  /// Methods that only exist in the initialize-based revisions.
  LEGACY_ONLY_METHODS: array[0..4] of string = (
    'ping', 'initialize', 'logging/setLevel', 'resources/subscribe', 'resources/unsubscribe');
  /// Methods that only exist with per-request _meta.
  MODERN_ONLY_METHODS: array[0..1] of string = ('server/discover', 'subscriptions/listen');
  LOG_LEVELS: array[0..7] of string = (
    'debug', 'info', 'notice', 'warning', 'error', 'critical', 'alert', 'emergency');

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

function TMCPJsonRpcProcessor.EraFromHeaders(const Hints: TMCPTransportHints): TMCPProtocolEra;
begin
  // Before the body is understood only the header can tell the era apart.
  if Hints.HasHeaderLayer and Hints.HasProtocolVersionHeader
    and IsModernProtocolVersion(Hints.ProtocolVersionHeader) then
    Result := TMCPProtocolEra.Modern
  else
    Result := TMCPProtocolEra.Legacy;
end;

function TMCPJsonRpcProcessor.EraFromMessage(const Method: string; const Params: TJSONObject;
  const Hints: TMCPTransportHints): TMCPProtocolEra;
begin
  // The era that decides the status of a rejected request: a body that
  // names a protocol version in _meta is modern even when it fails validation.
  Result := EraFromHeaders(Hints);
  if (Result = TMCPProtocolEra.Modern) or (Method = 'initialize') or not Assigned(Params) then
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
  if Assigned(LogLevel) and (not (LogLevel is TJSONString) or not InArray(TJSONString(LogLevel).Value, LOG_LEVELS)) then
    raise EMCPError.Create(JSONRPC_INVALID_PARAMS,
      'params._meta.' + MCP_META_LOG_LEVEL + ' must be one of debug, info, notice, warning, error, critical, alert, emergency',
      nil, HTTP_STATUS_BAD_REQUEST);
end;

function TMCPJsonRpcProcessor.BuildRequestContext(const Method: string; const Params: TJSONObject;
  const RequestId: TMCPRequestId; const Hints: TMCPTransportHints): IMCPRequestContext;
var
  Version: string;
begin
  var Meta := ExtractMeta(Params);

  // 1. initialize always selects the legacy era, whatever _meta says.
  if Method = 'initialize' then
  begin
    var Requested := '';
    if Assigned(Params) then
    begin
      var RequestedValue := Params.GetValue('protocolVersion');
      if RequestedValue is TJSONString then
        Requested := TJSONString(RequestedValue).Value;
    end;
    Exit(TMCPRequestContext.Create(TMCPProtocolEra.Legacy, NegotiateLegacyProtocolVersion(Requested),
      Method, RequestId, Meta, Hints.LegacySession, FManagerRegistry));
  end;

  // 2. A protocol version in _meta makes the request modern.
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

    ValidateModernMeta(Meta);

    if IsLegacyOnlyMethod(Method) then
    begin
      var NotFound := EMCPError.MethodNotFound(Method);
      NotFound.HttpStatus := HTTP_STATUS_NOT_FOUND;
      raise NotFound;
    end;

    Exit(TMCPRequestContext.Create(TMCPProtocolEra.Modern, Version, Method, RequestId, Meta,
      Hints.LegacySession, FManagerRegistry));
  end;

  // 3. A modern-only method without _meta is a malformed modern request.
  if IsModernOnlyMethod(Method) then
    raise EMCPError.Create(JSONRPC_INVALID_PARAMS,
      Format('%s requires params._meta.%s', [Method, MCP_META_PROTOCOL_VERSION]), nil, HTTP_STATUS_BAD_REQUEST);

  // 4. On HTTP the header alone can still name the revision.
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

    Exit(TMCPRequestContext.Create(TMCPProtocolEra.Legacy, Header, Method, RequestId, Meta,
      Hints.LegacySession, FManagerRegistry));
  end;

  // 5. Legacy, with the version negotiated on this process when known.
  Version := '';
  if Assigned(Hints.LegacySession) then
    Version := Hints.LegacySession.ProtocolVersion;
  if Version = '' then
    Version := MCP_LATEST_LEGACY_PROTOCOL_VERSION;

  Result := TMCPRequestContext.Create(TMCPProtocolEra.Legacy, Version, Method, RequestId, Meta,
    Hints.LegacySession, FManagerRegistry);
end;

function TMCPJsonRpcProcessor.ProcessNotification(const Method: string; const Params: TJSONObject;
  const Hints: TMCPTransportHints): TMCPProcessResult;
begin
  Result.Body := '';
  Result.HttpStatus := HTTP_STATUS_ACCEPTED;
  Result.Era := EraFromHeaders(Hints);
  Result.IsNotification := True;

  TLogger.Info('Notification received: ' + Method);

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

function TMCPJsonRpcProcessor.DispatchRequest(const Context: IMCPRequestContext; const Params: TJSONObject): TValue;
var
  ManagerEx: IMCPCapabilityManagerEx;
begin
  if not Assigned(FManagerRegistry) then
    raise EMCPError.InternalError('Manager registry not initialized');

  var Manager := FManagerRegistry.GetManagerForMethod(Context.Method);
  if not Assigned(Manager) then
    raise EMCPError.MethodNotFound(Context.Method);

  TMCPRequestContext.SetCurrent(Context);
  try
    if Supports(Manager, IMCPCapabilityManagerEx, ManagerEx) then
      Result := ManagerEx.ExecuteMethodWithContext(Context.Method, Params, Context)
    else
      Result := Manager.ExecuteMethod(Context.Method, Params);
  finally
    TMCPRequestContext.SetCurrent(nil);
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
    // Byte-for-byte what the initialize-based revisions always received.
    if Value.IsEmpty then
      Result := nil
    else if Value.IsType<TJSONObject> then
      Result := Value.AsType<TJSONObject>
    else if Value.IsType<string> then
      Result := TJSONString.Create(Value.AsString)
    else
      Result := TJSONString.Create(Value.ToString);
    Exit;
  end;

  // Modern results are always objects with a resultType.
  var ResultObject: TJSONObject;
  if Value.IsType<TJSONObject> then
    ResultObject := Value.AsType<TJSONObject>
  else
  begin
    ResultObject := TJSONObject.Create;
    if not Value.IsEmpty then
      ResultObject.AddPair('value', Value.ToString);
  end;

  ApplyModernEnvelope(ResultObject, Context.Method);
  Result := ResultObject;
end;

function TMCPJsonRpcProcessor.StatusForError(Era: TMCPProtocolEra; const Error: EMCPError): Integer;
begin
  // Legacy clients read 404 as "session terminated"; they always get 200.
  if Era = TMCPProtocolEra.Legacy then
    Exit(HTTP_STATUS_OK);

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
end;

function TMCPJsonRpcProcessor.ExceptionToError(Era: TMCPProtocolEra; const E: Exception): EMCPError;
begin
  // The text heuristic predates typed errors; legacy answers keep it.
  if (Era = TMCPProtocolEra.Legacy) and (Pos('not found', E.Message) > 0) then
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
      if not (JsonRpc is TJSONString) or (TJSONString(JsonRpc).Value <> JSONRPC_VERSION) then
        raise EMCPError.InvalidRequest('jsonrpc must be "2.0"');

      var MethodValue := Request.GetValue('method');
      if not (MethodValue is TJSONString) then
      begin
        // A message with result or error is a response sent by the client;
        // it is never answered.
        if Assigned(Request.GetValue('result')) or Assigned(Request.GetValue('error')) then
        begin
          if Era = TMCPProtocolEra.Modern then
            raise EMCPError.InvalidRequest('JSON-RPC responses are not accepted');
          Result.Body := '';
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
          raise EMCPError.InvalidParams('params must be an object');
        Params := TJSONObject(ParamsValue);
      end;

      if RequestId.Kind = TMCPRequestIdKind.None then
        Exit(ProcessNotification(Method, Params, Hints));

      Era := EraFromMessage(Method, Params, Hints);
      Context := BuildRequestContext(Method, Params, RequestId, Hints);
      Era := Context.Era;

      var ExecuteResult := DispatchRequest(Context, Params);

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
