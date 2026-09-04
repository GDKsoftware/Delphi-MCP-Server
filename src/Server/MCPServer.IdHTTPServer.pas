unit MCPServer.IdHTTPServer;

interface

{$I MCPServer.inc}

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
  System.Rtti,
  System.IOUtils,
  System.Generics.Collections,
  IdHTTPServer,
  IdContext,
  IdCustomHTTPServer,
  IdGlobal,
  IdGlobalProtocols,
  IdSocketHandle,
  IdStack,
  {$IFDEF USE_TAURUS_TLS}
  TaurusTLS,
  {$ELSE}
  IdSSLOpenSSL,
  {$ENDIF}
  IdServerIOHandler,
  MCPServer.Types,
  MCPServer.Settings,
  MCPServer.Authorization,
  MCPServer.RequestContext,
  MCPServer.JsonRpcProcessor;

type
  TMCPIdHTTPServer = class(TComponent)
  private
    FHTTPServer: TIdHTTPServer;
    {$IFDEF USE_TAURUS_TLS}
    FSSLHandler: TTaurusTLSServerIOHandler;
    {$ELSE}
    FSSLHandler: TIdServerIOHandlerSSLOpenSSL;
    {$ENDIF}
    FManagerRegistry: IMCPManagerRegistry;
    FCoreManager: IMCPCapabilityManager;
    FJsonRpcProcessor: TMCPJsonRpcProcessor;
    FPort: Word;
    FActive: Boolean;
    FSettings: TMCPSettings;
    FAuthorizer: IMCPAuthorizer;
    procedure ConfigureSSL;
    procedure ConfigureBindings;
    procedure AddBinding(const IP: string; IPVersion: TIdIPVersion);
    procedure HandleQuerySSLPort(APort: Word; var VUseSSL: Boolean);
    procedure HandleParseAuthentication(Context: TIdContext; const AuthType, AuthData: string;
      var VUsername, VPassword: string; var VHandled: Boolean);
    procedure HandleHTTPRequest(Context: TIdContext; RequestInfo: TIdHTTPRequestInfo; ResponseInfo: TIdHTTPResponseInfo);
    function AllowedOrigins: TArray<string>;
    function ValidateOrigin(RequestInfo: TIdHTTPRequestInfo; ResponseInfo: TIdHTTPResponseInfo): Boolean;
    procedure ApplyCorsHeaders(RequestInfo: TIdHTTPRequestInfo; ResponseInfo: TIdHTTPResponseInfo);
    procedure HandleEndpointInfo(ResponseInfo: TIdHTTPResponseInfo);
    function IsProtectedResourceMetadataPath(const Document: string): Boolean;
    function ResourceUri: string;
    function ResourceMetadataUrl: string;
    procedure HandleProtectedResourceMetadata(ResponseInfo: TIdHTTPResponseInfo);
    function Authenticate(RequestInfo: TIdHTTPRequestInfo; ResponseInfo: TIdHTTPResponseInfo;
      out Principal: TMCPPrincipal): Boolean;
    procedure SendChallenge(ResponseInfo: TIdHTTPResponseInfo; Status: Integer; const Challenge: TMCPAuthChallenge;
      const Message: string);
    procedure HandlePostRequest(Context: TIdContext; RequestInfo: TIdHTTPRequestInfo; ResponseInfo: TIdHTTPResponseInfo;
      const Principal: TMCPPrincipal);
    function BuildTransportHints(RequestInfo: TIdHTTPRequestInfo): TMCPTransportHints;
    procedure EchoLegacySessionId(RequestInfo: TIdHTTPRequestInfo; ResponseInfo: TIdHTTPResponseInfo);
    procedure SendEmpty(ResponseInfo: TIdHTTPResponseInfo; Status: Integer);
    procedure SendJson(ResponseInfo: TIdHTTPResponseInfo; Status: Integer; const Body: string);
    procedure SendSse(ResponseInfo: TIdHTTPResponseInfo; const Body: string);
    procedure SendJsonRpcError(ResponseInfo: TIdHTTPResponseInfo; Status, Code: Integer; const Message: string);
    procedure SendMethodNotAllowed(ResponseInfo: TIdHTTPResponseInfo);
    function HeaderPresent(RequestInfo: TIdHTTPRequestInfo; const Name: string): Boolean;
    procedure CloseSubscriptions;
    function HeaderValue(RequestInfo: TIdHTTPRequestInfo; const Name: string): string;
  public
    constructor Create(Owner: TComponent); override;
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
    function BoundAddresses: TArray<string>;
    property Port: Word read FPort write FPort;
    property Active: Boolean read FActive;
    property ManagerRegistry: IMCPManagerRegistry read FManagerRegistry write FManagerRegistry;
    property CoreManager: IMCPCapabilityManager read FCoreManager write FCoreManager;
    property Settings: TMCPSettings read FSettings write FSettings;
    property Authorizer: IMCPAuthorizer read FAuthorizer write FAuthorizer;
  end;

implementation

uses
  MCPServer.Resource.Server,
  MCPServer.Errors,
  MCPServer.HttpHeaders,
  MCPServer.HttpStream,
  MCPServer.Logger;

const
  DEFAULT_MCP_PORT = 3000;

  HTTP_NO_CONTENT = 204;
  HTTP_UNAUTHORIZED = 401;
  HTTP_FORBIDDEN = 403;
  HTTP_METHOD_NOT_ALLOWED = 405;
  HTTP_PAYLOAD_TOO_LARGE = 413;

  SUBSCRIPTION_CLOSE_GRACE_MS = 1000;
  SUBSCRIPTION_CLOSE_POLL_MS = 10;

  CORS_MAX_AGE = 86400;
  CORS_ALLOW_METHODS = 'POST, OPTIONS';
  CORS_ALLOW_HEADERS = 'Accept, Content-Type, Authorization, MCP-Protocol-Version, Mcp-Method, Mcp-Name, Mcp-Session-Id, Last-Event-ID';
  CORS_EXPOSE_HEADERS = 'Mcp-Session-Id, WWW-Authenticate';
  ALLOW_HEADER = 'POST, OPTIONS';

  HEADER_ORIGIN = 'Origin';
  HEADER_AUTHORIZATION = 'Authorization';
  HEADER_WWW_AUTHENTICATE = 'WWW-Authenticate';
  BEARER_PREFIX = 'Bearer ';
  METADATA_CACHE_CONTROL = 'max-age=3600';
  HEADER_ACCEPT = 'Accept';
  HEADER_SESSION_ID = 'Mcp-Session-Id';
  HEADER_PROTOCOL_VERSION = 'MCP-Protocol-Version';
  HEADER_METHOD = 'Mcp-Method';
  HEADER_NAME = 'Mcp-Name';

  MEDIA_TYPE_JSON = 'application/json';
  MEDIA_TYPE_EVENT_STREAM = 'text/event-stream';

  LOOPBACK_IPV4 = '127.0.0.1';
  LOOPBACK_IPV6 = '::1';
  ANY_IPV4 = '0.0.0.0';
  ANY_IPV6 = '::';

{ TMCPIdHTTPServer }

constructor TMCPIdHTTPServer.Create(Owner: TComponent);
begin
  inherited Create(Owner);
  FPort := DEFAULT_MCP_PORT;
  FActive := False;
  FJsonRpcProcessor := nil;

  FHTTPServer := TIdHTTPServer.Create(Self);
  FHTTPServer.KeepAlive := True;
  FHTTPServer.OnCommandGet := HandleHTTPRequest;
  FHTTPServer.OnCommandOther := HandleHTTPRequest;
  FHTTPServer.OnQuerySSLPort := HandleQuerySSLPort;
  FHTTPServer.OnParseAuthentication := HandleParseAuthentication;
  FSSLHandler := nil;
end;

destructor TMCPIdHTTPServer.Destroy;
begin
  if FActive then
    Stop;
  FHTTPServer.Free;
  if Assigned(FSSLHandler) then
    FSSLHandler.Free;
  FJsonRpcProcessor.Free;
  inherited;
end;

procedure TMCPIdHTTPServer.Start;
begin
  if FActive then
    Exit;

  if not Assigned(FManagerRegistry) then
    raise Exception.Create('Manager registry not assigned');

  FJsonRpcProcessor.Free;
  FJsonRpcProcessor := TMCPJsonRpcProcessor.Create(FManagerRegistry, FSettings);

  if Assigned(FSettings) then
  begin
    FPort := Word(FSettings.Port);
    FHTTPServer.MaxConnections := FSettings.MaxConnections;

    if FSettings.SSLEnabled then
      ConfigureSSL;
  end;

  if Assigned(FAuthorizer) and (not Assigned(FSettings) or (Length(FSettings.AuthorizationServerList) = 0)) then
    TLogger.Warning('An authorizer is configured without [Auth] AuthorizationServers: clients cannot discover an authorization server, only pre-shared tokens work');

  FHTTPServer.DefaultPort := FPort;
  ConfigureBindings;
  FHTTPServer.Active := True;
  FActive := True;

  if (FPort = 0) and (FHTTPServer.Bindings.Count > 0) then
    FPort := FHTTPServer.Bindings[0].Port;

  TLogger.Info('MCP Server listening on ' + string.Join(', ', BoundAddresses));
end;

procedure TMCPIdHTTPServer.CloseSubscriptions;
var
  Hub: IMCPSubscriptionHub;
begin
  if not Assigned(FManagerRegistry)
    or not Supports(FManagerRegistry.GetManagerForMethod(MCP_METHOD_SUBSCRIPTIONS_LISTEN), IMCPSubscriptionHub, Hub) then
    Exit;

  var Deadline := TThread.GetTickCount64 + SUBSCRIPTION_CLOSE_GRACE_MS;
  repeat
    Hub.CloseAll('server stopping');
    if Hub.ActiveCount = 0 then
      Break;
    Sleep(SUBSCRIPTION_CLOSE_POLL_MS);
  until TThread.GetTickCount64 >= Deadline;
end;

procedure TMCPIdHTTPServer.Stop;
begin
  if not FActive then
    Exit;

  CloseSubscriptions;
  FHTTPServer.Active := False;
  FActive := False;
  TLogger.Info('MCP Server stopped');
end;

function TMCPIdHTTPServer.BoundAddresses: TArray<string>;
begin
  Result := nil;
  for var I := 0 to FHTTPServer.Bindings.Count - 1 do
  begin
    var Binding := FHTTPServer.Bindings[I];
    if Binding.IPVersion = Id_IPv6 then
      Result := Result + [Format('[%s]:%d', [Binding.IP, Binding.Port])]
    else
      Result := Result + [Format('%s:%d', [Binding.IP, Binding.Port])];
  end;
end;

procedure TMCPIdHTTPServer.AddBinding(const IP: string; IPVersion: TIdIPVersion);
begin
  var Binding := FHTTPServer.Bindings.Add;
  Binding.IP := IP;
  Binding.Port := FPort;
  Binding.IPVersion := IPVersion;
end;

procedure TMCPIdHTTPServer.ConfigureBindings;
begin
  FHTTPServer.Bindings.Clear;

  var Address := '';
  var Host := 'localhost';
  if Assigned(FSettings) then
  begin
    Address := FSettings.BindAddress.Trim;
    Host := FSettings.Host.Trim;
  end;

  if Address <> '' then
  begin
    if (Address = ANY_IPV4) or (Address = ANY_IPV6) then
      TLogger.Warning('BindAddress ' + Address + ': the server is reachable from every network interface');
    if Address.Contains(':') then
      AddBinding(Address, Id_IPv6)
    else
      AddBinding(Address, Id_IPv4);
    Exit;
  end;

  if SameText(Host, 'localhost') or (Host = LOOPBACK_IPV4) or (Host = LOOPBACK_IPV6) then
  begin
    AddBinding(LOOPBACK_IPV4, Id_IPv4);
    if GStack.SupportsIPv6 then
      AddBinding(LOOPBACK_IPV6, Id_IPv6);
  end
  else
  begin
    TLogger.Info('Host ' + Host + ' is not loopback; listening on every network interface (set BindAddress to narrow this)');
    AddBinding(ANY_IPV4, Id_IPv4);
    if GStack.SupportsIPv6 then
      AddBinding(ANY_IPV6, Id_IPv6);
  end;
end;

procedure TMCPIdHTTPServer.ConfigureSSL;
begin
  if not TFile.Exists(FSettings.SSLCertFile) then
  begin
    TLogger.Error('SSL Certificate file not found: ' + FSettings.SSLCertFile);
    raise Exception.Create('SSL Certificate file not found: ' + FSettings.SSLCertFile);
  end;

  if not TFile.Exists(FSettings.SSLKeyFile) then
  begin
    TLogger.Error('SSL Key file not found: ' + FSettings.SSLKeyFile);
    raise Exception.Create('SSL Key file not found: ' + FSettings.SSLKeyFile);
  end;

  {$IFDEF USE_TAURUS_TLS}
  FSSLHandler := TTaurusTLSServerIOHandler.Create(Self);
  FSSLHandler.DefaultCert.PublicKey := FSettings.SSLCertFile;
  FSSLHandler.DefaultCert.PrivateKey := FSettings.SSLKeyFile;
  {$ELSE}
  FSSLHandler := TIdServerIOHandlerSSLOpenSSL.Create(Self);
  FSSLHandler.SSLOptions.CertFile := FSettings.SSLCertFile;
  FSSLHandler.SSLOptions.KeyFile := FSettings.SSLKeyFile;

  if (FSettings.SSLRootCertFile <> '') and TFile.Exists(FSettings.SSLRootCertFile) then
    FSSLHandler.SSLOptions.RootCertFile := FSettings.SSLRootCertFile;

  FSSLHandler.SSLOptions.Method := sslvTLSv1_2;
  FSSLHandler.SSLOptions.SSLVersions := [sslvTLSv1_2];
  FSSLHandler.SSLOptions.Mode := sslmServer;
  {$ENDIF}

  FHTTPServer.IOHandler := FSSLHandler;

  TLogger.Info('SSL configured successfully');
  TLogger.Info('Certificate: ' + FSettings.SSLCertFile);
  TLogger.Info('Private Key: ' + FSettings.SSLKeyFile);
  if FSettings.SSLRootCertFile <> '' then
    TLogger.Info('Root Certificate: ' + FSettings.SSLRootCertFile);
end;

procedure TMCPIdHTTPServer.HandleParseAuthentication(Context: TIdContext; const AuthType, AuthData: string;
  var VUsername, VPassword: string; var VHandled: Boolean);
begin
  VUsername := '';
  VPassword := '';
  VHandled := True;
end;

procedure TMCPIdHTTPServer.HandleQuerySSLPort(APort: Word; var VUseSSL: Boolean);
begin
  VUseSSL := Assigned(FSettings) and FSettings.SSLEnabled and (APort = FPort);
end;

function TMCPIdHTTPServer.HeaderPresent(RequestInfo: TIdHTTPRequestInfo; const Name: string): Boolean;
begin
  Result := RequestInfo.RawHeaders.IndexOfName(Name) >= 0;
end;

function TMCPIdHTTPServer.HeaderValue(RequestInfo: TIdHTTPRequestInfo; const Name: string): string;
begin
  Result := Trim(RequestInfo.RawHeaders.Values[Name]);
end;

procedure TMCPIdHTTPServer.HandleHTTPRequest(Context: TIdContext;
  RequestInfo: TIdHTTPRequestInfo; ResponseInfo: TIdHTTPResponseInfo);
begin
  TServerStatusResource.ConnectionOpened;
  try
    TServerStatusResource.IncrementRequestCount;

    if not ValidateOrigin(RequestInfo, ResponseInfo) then
      Exit;

    ApplyCorsHeaders(RequestInfo, ResponseInfo);

    var Endpoint := '/mcp';
    var EndpointInfoPath := '';
    if Assigned(FSettings) then
    begin
      Endpoint := FSettings.Endpoint;
      EndpointInfoPath := FSettings.EndpointInfoPath;
    end;

    if (EndpointInfoPath <> '') and (RequestInfo.Document = EndpointInfoPath) and (RequestInfo.CommandType = hcGET) then
    begin
      HandleEndpointInfo(ResponseInfo);
      Exit;
    end;

    if Assigned(FAuthorizer) and (RequestInfo.CommandType = hcGET)
      and IsProtectedResourceMetadataPath(RequestInfo.Document) then
    begin
      HandleProtectedResourceMetadata(ResponseInfo);
      Exit;
    end;

    if RequestInfo.Document <> Endpoint then
    begin
      SendEmpty(ResponseInfo, HTTP_STATUS_NOT_FOUND);
      Exit;
    end;

    if RequestInfo.Command = 'OPTIONS' then
    begin
      SendEmpty(ResponseInfo, HTTP_NO_CONTENT);
      Exit;
    end;

    var Principal := TMCPPrincipal.None;
    if Assigned(FAuthorizer) and not Authenticate(RequestInfo, ResponseInfo, Principal) then
      Exit;

    if RequestInfo.CommandType = hcPOST then
      HandlePostRequest(Context, RequestInfo, ResponseInfo, Principal)
    else
      SendMethodNotAllowed(ResponseInfo);
  finally
    TServerStatusResource.ConnectionClosed;
  end;
end;

function TMCPIdHTTPServer.AllowedOrigins: TArray<string>;
begin
  Result := nil;
  if not Assigned(FSettings) then
    Exit;

  var List := FSettings.AllowedOrigins;
  if List.Trim = '' then
    Exit;

  for var Entry in List.Split([',']) do
    if Entry.Trim <> '' then
      Result := Result + [Entry.Trim];
end;

function TMCPIdHTTPServer.ValidateOrigin(RequestInfo: TIdHTTPRequestInfo; ResponseInfo: TIdHTTPResponseInfo): Boolean;
begin
  if not HeaderPresent(RequestInfo, HEADER_ORIGIN) then
    Exit(True);

  var Origin := HeaderValue(RequestInfo, HEADER_ORIGIN);
  ResponseInfo.CustomHeaders.Values['Vary'] := HEADER_ORIGIN;

  if TMCPOriginPolicy.IsAllowed(Origin, AllowedOrigins) then
    Exit(True);

  TLogger.Warning('Origin not allowed: ' + Origin);
  SendJsonRpcError(ResponseInfo, HTTP_FORBIDDEN, JSONRPC_INVALID_REQUEST, 'Origin not allowed');
  Result := False;
end;

procedure TMCPIdHTTPServer.ApplyCorsHeaders(RequestInfo: TIdHTTPRequestInfo; ResponseInfo: TIdHTTPResponseInfo);
begin
  if not Assigned(FSettings) or not FSettings.CorsEnabled then
    Exit;

  var Origin := HeaderValue(RequestInfo, HEADER_ORIGIN);
  var AllowAll := False;
  for var Entry in AllowedOrigins do
    if Entry = TMCPOriginPolicy.ALLOW_ALL then
      AllowAll := True;

  if (Origin = '') or AllowAll then
    ResponseInfo.CustomHeaders.Values['Access-Control-Allow-Origin'] := TMCPOriginPolicy.ALLOW_ALL
  else
    ResponseInfo.CustomHeaders.Values['Access-Control-Allow-Origin'] := Origin;

  var AllowHeaders := CORS_ALLOW_HEADERS;
  for var Requested in HeaderValue(RequestInfo, 'Access-Control-Request-Headers').Split([',']) do
  begin
    var Name := Requested.Trim;
    if (Name <> '') and (Pos(LowerCase(Name), LowerCase(AllowHeaders)) = 0) then
      AllowHeaders := AllowHeaders + ', ' + Name;
  end;

  ResponseInfo.CustomHeaders.Values['Access-Control-Allow-Methods'] := CORS_ALLOW_METHODS;
  ResponseInfo.CustomHeaders.Values['Access-Control-Allow-Headers'] := AllowHeaders;
  ResponseInfo.CustomHeaders.Values['Access-Control-Expose-Headers'] := CORS_EXPOSE_HEADERS;
  ResponseInfo.CustomHeaders.Values['Access-Control-Max-Age'] := CORS_MAX_AGE.ToString;
end;

procedure TMCPIdHTTPServer.HandleEndpointInfo(ResponseInfo: TIdHTTPResponseInfo);
begin
  var Info := TJSONObject.Create;
  try
    Info.AddPair('url', FSettings.Protocol + '://' + FSettings.Host + ':' + IntToStr(FPort) + FSettings.Endpoint);
    Info.AddPair('transport', 'streamable-http');
    var Versions := TJSONArray.Create;
    Info.AddPair('protocolVersions', Versions);
    for var Version in MCP_MODERN_PROTOCOL_VERSIONS do
      Versions.Add(Version);
    for var Version in MCP_LEGACY_PROTOCOL_VERSIONS do
      Versions.Add(Version);
    SendJson(ResponseInfo, HTTP_STATUS_OK, Info.ToJSON);
  finally
    Info.Free;
  end;
end;

function TMCPIdHTTPServer.IsProtectedResourceMetadataPath(const Document: string): Boolean;
begin
  var Endpoint := '/mcp';
  if Assigned(FSettings) then
    Endpoint := FSettings.Endpoint;
  Result := (Document = TMCPProtectedResourceMetadata.WELL_KNOWN_PATH)
    or (Document = TMCPProtectedResourceMetadata.WELL_KNOWN_PATH + Endpoint);
end;

function TMCPIdHTTPServer.ResourceUri: string;
begin
  Result := '';
  if Assigned(FSettings) then
    Result := FSettings.ResourceUri.Trim;
  if Result <> '' then
    Exit;

  Result := Format('%s://%s:%d%s', [FSettings.Protocol.ToLower, FSettings.Host.ToLower, FPort, FSettings.Endpoint]);
end;

function TMCPIdHTTPServer.ResourceMetadataUrl: string;
begin
  Result := '';
  if not Assigned(FSettings) or (Length(FSettings.AuthorizationServerList) = 0) then
    Exit;
  Result := Format('%s://%s:%d%s%s', [FSettings.Protocol.ToLower, FSettings.Host.ToLower, FPort,
    TMCPProtectedResourceMetadata.WELL_KNOWN_PATH, FSettings.Endpoint]);
end;

procedure TMCPIdHTTPServer.HandleProtectedResourceMetadata(ResponseInfo: TIdHTTPResponseInfo);
begin
  var Metadata := TMCPProtectedResourceMetadata.Build(ResourceUri, FSettings.ServerName,
    FSettings.AuthorizationServerList, FSettings.ScopesSupportedList);
  try
    ResponseInfo.CustomHeaders.Values['Cache-Control'] := METADATA_CACHE_CONTROL;
    SendJson(ResponseInfo, HTTP_STATUS_OK, Metadata.ToJSON);
  finally
    Metadata.Free;
  end;
end;

procedure TMCPIdHTTPServer.SendChallenge(ResponseInfo: TIdHTTPResponseInfo; Status: Integer;
  const Challenge: TMCPAuthChallenge; const Message: string);
begin
  ResponseInfo.CustomHeaders.Values[HEADER_WWW_AUTHENTICATE] := TMCPBearerChallenge.Build(ResourceMetadataUrl, Challenge);
  SendJsonRpcError(ResponseInfo, Status, JSONRPC_INVALID_REQUEST, Message);
end;

function TMCPIdHTTPServer.Authenticate(RequestInfo: TIdHTTPRequestInfo; ResponseInfo: TIdHTTPResponseInfo;
  out Principal: TMCPPrincipal): Boolean;
var
  Challenge: TMCPAuthChallenge;
begin
  Principal := TMCPPrincipal.None;
  Result := False;

  var Header := HeaderValue(RequestInfo, HEADER_AUTHORIZATION);
  if Header = '' then
  begin
    SendChallenge(ResponseInfo, HTTP_UNAUTHORIZED, TMCPAuthChallenge.None, 'Authorization required');
    Exit;
  end;
  if not Header.StartsWith(BEARER_PREFIX, True) or (Header.Length <= BEARER_PREFIX.Length) then
  begin
    SendChallenge(ResponseInfo, HTTP_STATUS_BAD_REQUEST,
      TMCPAuthChallenge.InvalidRequest('Only the Bearer scheme is supported'), 'Malformed Authorization header');
    Exit;
  end;

  var Token := Header.Substring(BEARER_PREFIX.Length).Trim;
  case FAuthorizer.Authorize(Token, RequestInfo.Command, RequestInfo.Document, Principal, Challenge) of
    TMCPAuthDecision.Allow:
      Result := True;
    TMCPAuthDecision.Unauthorized:
      SendChallenge(ResponseInfo, HTTP_UNAUTHORIZED, Challenge, 'Unauthorized');
    TMCPAuthDecision.Forbidden:
      SendChallenge(ResponseInfo, HTTP_FORBIDDEN, Challenge, 'Forbidden');
    TMCPAuthDecision.BadRequest:
      SendChallenge(ResponseInfo, HTTP_STATUS_BAD_REQUEST, Challenge, 'Malformed authorization request');
  else
    SendChallenge(ResponseInfo, HTTP_UNAUTHORIZED, Challenge, 'Unauthorized');
  end;
end;

function TMCPIdHTTPServer.BuildTransportHints(RequestInfo: TIdHTTPRequestInfo): TMCPTransportHints;
begin
  Result := TMCPTransportHints.ForHttp(
    HeaderPresent(RequestInfo, HEADER_PROTOCOL_VERSION), HeaderValue(RequestInfo, HEADER_PROTOCOL_VERSION));
  Result.HasMethodHeader := HeaderPresent(RequestInfo, HEADER_METHOD);
  Result.MethodHeader := HeaderValue(RequestInfo, HEADER_METHOD);
  Result.HasNameHeader := HeaderPresent(RequestInfo, HEADER_NAME);
  Result.NameHeader := HeaderValue(RequestInfo, HEADER_NAME);
  Result.RemoteAddress := RequestInfo.RemoteIP;
end;

procedure TMCPIdHTTPServer.EchoLegacySessionId(RequestInfo: TIdHTTPRequestInfo; ResponseInfo: TIdHTTPResponseInfo);
begin
  var SessionId := HeaderValue(RequestInfo, HEADER_SESSION_ID);
  if (SessionId <> '') and TMCPHeaderValue.IsHeaderSafe(SessionId) and not SessionId.Contains(' ') then
    ResponseInfo.CustomHeaders.Values[HEADER_SESSION_ID] := SessionId;
end;

procedure TMCPIdHTTPServer.HandlePostRequest(Context: TIdContext; RequestInfo: TIdHTTPRequestInfo;
  ResponseInfo: TIdHTTPResponseInfo; const Principal: TMCPPrincipal);
begin
  var MaxBodyBytes: Integer := TMCPSettings.DEFAULT_MAX_REQUEST_BODY_BYTES;
  var MaxDepth: Integer := TMCPSettings.DEFAULT_MAX_JSON_DEPTH;
  if Assigned(FSettings) then
  begin
    MaxBodyBytes := FSettings.MaxRequestBodyBytes;
    MaxDepth := FSettings.MaxJsonDepth;
  end;

  if Assigned(RequestInfo.PostStream) and (RequestInfo.PostStream.Size > MaxBodyBytes) then
  begin
    SendJsonRpcError(ResponseInfo, HTTP_PAYLOAD_TOO_LARGE, JSONRPC_INVALID_REQUEST,
      Format('Request body exceeds %d bytes', [MaxBodyBytes]));
    Exit;
  end;

  var RequestBody := '';
  if Assigned(RequestInfo.PostStream) and (RequestInfo.PostStream.Size > 0) then
  begin
    RequestInfo.PostStream.Position := 0;
    RequestBody := ReadStringFromStream(RequestInfo.PostStream, -1, IndyTextEncoding_UTF8);
  end;

  TLogger.Debug('Request: ' + TLogger.RedactJson(RequestBody));

  if TMCPJsonLimits.NestingDepth(RequestBody) > MaxDepth then
  begin
    SendJsonRpcError(ResponseInfo, HTTP_STATUS_BAD_REQUEST, JSONRPC_PARSE_ERROR,
      Format('JSON nesting exceeds %d levels', [MaxDepth]));
    Exit;
  end;

  var AcceptsEventStream := TMCPAcceptHeader.Accepts(HeaderValue(RequestInfo, HEADER_ACCEPT), MEDIA_TYPE_EVENT_STREAM);
  var Hints := BuildTransportHints(RequestInfo);
  Hints.Principal := Principal.Subject;
  Hints.Scopes := Principal.Scopes;
  var Stream: TMCPHttpResponseStream := nil;
  var StreamRef: IMCPMessageSink := nil;
  if AcceptsEventStream then
  begin
    Stream := TMCPHttpResponseStream.Create(Context, ResponseInfo);
    StreamRef := Stream;
    Hints.Sink := Stream;
    Hints.Tracker := Stream;
  end;

  var Outcome: TMCPProcessResult;
  var Message := TJSONObject.ParseJSONValue(RequestBody);
  try
    Outcome := FJsonRpcProcessor.ProcessRequestEx(Message, Hints);
  finally
    Message.Free;
  end;

  if Assigned(Stream) and Stream.Opened then
  begin
    TLogger.Debug('Response (streamed): ' + TLogger.RedactJson(Outcome.Body));
    Stream.Finish(Outcome.Body);
    Exit;
  end;

  if Outcome.Era = TMCPProtocolEra.Legacy then
    EchoLegacySessionId(RequestInfo, ResponseInfo);
  if Outcome.RequiredScope <> '' then
    ResponseInfo.CustomHeaders.Values[HEADER_WWW_AUTHENTICATE] :=
      TMCPBearerChallenge.Build(ResourceMetadataUrl, TMCPAuthChallenge.InsufficientScope(Outcome.RequiredScope));

  if Outcome.Body = '' then
  begin
    SendEmpty(ResponseInfo, Outcome.HttpStatus);
    Exit;
  end;

  TLogger.Debug('Response: ' + TLogger.RedactJson(Outcome.Body));

  if (Outcome.HttpStatus = HTTP_STATUS_OK) and AcceptsEventStream then
    SendSse(ResponseInfo, Outcome.Body)
  else
    SendJson(ResponseInfo, Outcome.HttpStatus, Outcome.Body);
end;

procedure TMCPIdHTTPServer.SendEmpty(ResponseInfo: TIdHTTPResponseInfo; Status: Integer);
begin
  ResponseInfo.ResponseNo := Status;
  ResponseInfo.ContentStream := TMemoryStream.Create;
  ResponseInfo.FreeContentStream := True;
end;

procedure TMCPIdHTTPServer.SendJson(ResponseInfo: TIdHTTPResponseInfo; Status: Integer; const Body: string);
begin
  ResponseInfo.ResponseNo := Status;
  ResponseInfo.ContentType := MEDIA_TYPE_JSON;
  ResponseInfo.ContentStream := TStringStream.Create(Body, TEncoding.UTF8);
  ResponseInfo.FreeContentStream := True;
end;

procedure TMCPIdHTTPServer.SendSse(ResponseInfo: TIdHTTPResponseInfo; const Body: string);
begin
  ResponseInfo.ResponseNo := HTTP_STATUS_OK;
  ResponseInfo.ContentType := MEDIA_TYPE_EVENT_STREAM;
  ResponseInfo.CharSet := 'utf-8';
  ResponseInfo.CustomHeaders.Values['Cache-Control'] := 'no-cache';
  ResponseInfo.CustomHeaders.Values['X-Accel-Buffering'] := 'no';
  ResponseInfo.ContentStream := TStringStream.Create(TMCPHttpResponseStream.EventText(Body), TEncoding.UTF8);
  ResponseInfo.FreeContentStream := True;
end;

procedure TMCPIdHTTPServer.SendJsonRpcError(ResponseInfo: TIdHTTPResponseInfo; Status, Code: Integer; const Message: string);
begin
  var Response := TJSONObject.Create;
  try
    Response.AddPair('jsonrpc', '2.0');
    var Error := TJSONObject.Create;
    Response.AddPair('error', Error);
    Error.AddPair('code', TJSONNumber.Create(Code));
    Error.AddPair('message', Message);
    SendJson(ResponseInfo, Status, Response.ToJSON);
  finally
    Response.Free;
  end;
end;

procedure TMCPIdHTTPServer.SendMethodNotAllowed(ResponseInfo: TIdHTTPResponseInfo);
begin
  ResponseInfo.CustomHeaders.Values['Allow'] := ALLOW_HEADER;
  SendEmpty(ResponseInfo, HTTP_METHOD_NOT_ALLOWED);
end;

end.
