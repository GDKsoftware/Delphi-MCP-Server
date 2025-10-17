unit MCPServer.IdHTTPServer;

interface

// TaurusTLS provides OpenSSL 3.x support with modern ECDHE cipher suites
// Install via GetIt Package Manager: Search for "TaurusTLS" or get from https://github.com/JPeterMugaas/TaurusTLS
{$DEFINE USE_TAURUS_TLS}  // Comment this line to use standard Indy SSL (OpenSSL 1.0.2)

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
  {$IFDEF USE_TAURUS_TLS}
  TaurusTLS,
  {$ELSE}
  IdSSLOpenSSL,
  {$ENDIF}
  IdServerIOHandler,
  MCPServer.Types,
  MCPServer.Settings;

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
    FPort: Word;
    FActive: Boolean;
    FSettings: TMCPSettings;
    procedure ConfigureSSL;
    procedure HandleQuerySSLPort(APort: Word; var VUseSSL: Boolean);
    procedure HandleHTTPRequest(Context: TIdContext; RequestInfo: TIdHTTPRequestInfo; ResponseInfo: TIdHTTPResponseInfo);
    function VerifyAndSetCORSHeaders(RequestInfo: TIdHTTPRequestInfo; ResponseInfo: TIdHTTPResponseInfo): Boolean;
    procedure HandleOptionsRequest(ResponseInfo: TIdHTTPResponseInfo);
    procedure HandleGetRequest(RequestInfo: TIdHTTPRequestInfo; ResponseInfo: TIdHTTPResponseInfo);
    procedure HandlePostRequest(RequestInfo: TIdHTTPRequestInfo; ResponseInfo: TIdHTTPResponseInfo);
    function ProcessJSONRPCRequest(const RequestBody: string; const SessionID: string): string;
    function ParseJSONRequest(const RequestBody: string): TJSONObject;
    function ExtractRequestID(JSONRequest: TJSONObject): TValue;
    function CreateJSONResponse(const RequestID: TValue): TJSONObject;
    procedure AddRequestIDToResponse(Response: TJSONObject; const RequestID: TValue);
    function ExecuteMethodCall(const MethodName: string; Params: TJSONObject): TValue;
    function CreateErrorResponse(const RequestID: TValue; ErrorCode: Integer; const ErrorMessage: string): string;
  public
    constructor Create(Owner: TComponent); override;
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
    property Port: Word read FPort write FPort;
    property Active: Boolean read FActive;
    property ManagerRegistry: IMCPManagerRegistry read FManagerRegistry write FManagerRegistry;
    property CoreManager: IMCPCapabilityManager read FCoreManager write FCoreManager;
    property Settings: TMCPSettings read FSettings write FSettings;
  end;

implementation

uses
  MCPServer.Resource.Server,
  MCPServer.CoreManager,
  MCPServer.Logger;

const
  KEEP_ALIVE_TIMEOUT = 300;
  DEFAULT_MCP_PORT = 3000;
  
  // HTTP Status Codes
  HTTP_OK = 200;
  HTTP_NO_CONTENT = 204;
  HTTP_NOT_FOUND = 404;
  HTTP_METHOD_NOT_ALLOWED = 405;
  HTTP_NOT_ACCEPTABLE = 406;
  HTTP_FORBIDDEN = 403;
  
  // CORS Max Age (24 hours in seconds)
  CORS_MAX_AGE = 86400;
  
  // JSON-RPC 2.0 Error Codes
  JSONRPC_PARSE_ERROR = -32700;
  JSONRPC_INVALID_REQUEST = -32600;
  JSONRPC_METHOD_NOT_FOUND = -32601;
  JSONRPC_INVALID_PARAMS = -32602;
  JSONRPC_INTERNAL_ERROR = -32603;

{ TMCPIdHTTPServer }

constructor TMCPIdHTTPServer.Create(Owner: TComponent);
begin
  inherited Create(Owner);
  FPort := DEFAULT_MCP_PORT;
  FActive := False;
  
  FHTTPServer := TIdHTTPServer.Create(Self);
  FHTTPServer.OnCommandGet := HandleHTTPRequest;
  FHTTPServer.OnCommandOther := HandleHTTPRequest;
  FHTTPServer.OnQuerySSLPort := HandleQuerySSLPort;
  FSSLHandler := nil;
end;

destructor TMCPIdHTTPServer.Destroy;
begin
  if FActive then
    Stop;
  FHTTPServer.Free;
  if Assigned(FSSLHandler) then
    FSSLHandler.Free;
  inherited;
end;

procedure TMCPIdHTTPServer.Start;
begin
  if FActive then
    Exit;
    
  if Assigned(FSettings) then
  begin
    FPort := Word(FSettings.Port);
    
    // Configure SSL if enabled
    if FSettings.SSLEnabled then
      ConfigureSSL;
  end;
    
  FHTTPServer.DefaultPort := FPort;
  FHTTPServer.Active := True;
  FActive := True;
  
  TLogger.Info('MCP Server started on ' + FSettings.Protocol + '://' + FSettings.Host + ':' + IntToStr(FPort));
end;

procedure TMCPIdHTTPServer.Stop;
begin
  if not FActive then
    Exit;
    
  FHTTPServer.Active := False;
  FActive := False;
  TLogger.Info('MCP Server stopped');
end;

procedure TMCPIdHTTPServer.HandleHTTPRequest(Context: TIdContext; 
  RequestInfo: TIdHTTPRequestInfo; ResponseInfo: TIdHTTPResponseInfo);
begin
  TServerStatusResource.ConnectionOpened;
  try
    TServerStatusResource.IncrementRequestCount;

    if not VerifyAndSetCORSHeaders(RequestInfo, ResponseInfo) then
      Exit; // CORS blocked the request

    var RequestPath := RequestInfo.Document;

    // Only handle requests to the configured MCP endpoint
    if (RequestPath <> FSettings.Endpoint) then
    begin
      ResponseInfo.ResponseNo := HTTP_NOT_FOUND;
      ResponseInfo.ResponseText := 'Not Found';
      Exit;
    end;
    
    if RequestInfo.Command = 'OPTIONS' then
      HandleOptionsRequest(ResponseInfo)
    else if RequestInfo.CommandType = hcGET then
      HandleGetRequest(RequestInfo, ResponseInfo)
    else if RequestInfo.CommandType = hcPOST then
      HandlePostRequest(RequestInfo, ResponseInfo)
    else
    begin
      ResponseInfo.ResponseNo := HTTP_METHOD_NOT_ALLOWED;
      ResponseInfo.ResponseText := 'Method Not Allowed';
    end;
  finally
    TServerStatusResource.ConnectionClosed;
  end;
end;

function TMCPIdHTTPServer.VerifyAndSetCORSHeaders(RequestInfo: TIdHTTPRequestInfo;
  ResponseInfo: TIdHTTPResponseInfo): Boolean;
begin
  Result := True;

  if not Assigned(FSettings) or not FSettings.CorsEnabled then
    Exit;

  var Origin := RequestInfo.RawHeaders.Values['Origin'];
  var AllowedOrigin: string := '*';

  if (FSettings.CorsAllowedOrigins <> '*') and (Origin <> '') then
  begin
    var OriginsList := TStringList.Create;
    try
      OriginsList.CommaText := FSettings.CorsAllowedOrigins;
      var Found := False;

      for var CurrentOrigin in OriginsList do
      begin
        if SameText(Trim(CurrentOrigin), Origin) then
        begin
          AllowedOrigin := Origin;
          Found := True;
          Break;
        end;
      end;

      if not Found then
      begin
        Result := False;
        ResponseInfo.ResponseNo := HTTP_FORBIDDEN;
        ResponseInfo.ResponseText := 'Forbidden - Origin not allowed';
        TLogger.Info('CORS blocked origin: ' + Origin);
        Exit;
      end;
    finally
      OriginsList.Free;
    end;
  end;

  ResponseInfo.CustomHeaders.Values['Access-Control-Allow-Origin'] := AllowedOrigin;
  ResponseInfo.CustomHeaders.Values['Access-Control-Allow-Methods'] := 'POST, GET, OPTIONS';
  ResponseInfo.CustomHeaders.Values['Access-Control-Allow-Headers'] := 
    'Content-Type, Mcp-Session-Id';
  ResponseInfo.CustomHeaders.Values['Access-Control-Max-Age'] := CORS_MAX_AGE.ToString;
end;

procedure TMCPIdHTTPServer.HandleOptionsRequest(ResponseInfo: TIdHTTPResponseInfo);
begin
  ResponseInfo.ResponseNo := HTTP_OK;
  ResponseInfo.ResponseText := 'OK';
end;

procedure TMCPIdHTTPServer.HandleGetRequest(RequestInfo: TIdHTTPRequestInfo; 
  ResponseInfo: TIdHTTPResponseInfo);
begin
  TLogger.Info('Received GET request - returning endpoint info');
  
  ResponseInfo.ContentType := 'application/json';
  ResponseInfo.CustomHeaders.Values['Cache-Control'] := 'no-cache';
  ResponseInfo.CustomHeaders.Values['Connection'] := 'keep-alive';
  
  ResponseInfo.ContentText := '{"url": "' + FSettings.Protocol + '://' + FSettings.Host + ':' + IntToStr(FPort) +
                  FSettings.Endpoint + '", "transport": "' + FSettings.Protocol + '"}';

  ResponseInfo.ResponseNo := HTTP_OK;
end;

procedure TMCPIdHTTPServer.HandlePostRequest(RequestInfo: TIdHTTPRequestInfo; 
  ResponseInfo: TIdHTTPResponseInfo);
begin

  var ReqBody: string;
  if Assigned(RequestInfo.PostStream) and (RequestInfo.PostStream.Size > 0) then
  begin
    RequestInfo.PostStream.Position := 0;
    ReqBody := ReadStringFromStream(RequestInfo.PostStream, -1, IndyTextEncoding_UTF8);
  end
  else
    ReqBody := '';
  
  TLogger.Info('Request: ' + ReqBody);
  
  var SessID := RequestInfo.RawHeaders.Values['Mcp-Session-Id'];
  if SessID <> '' then
    TLogger.Info('Session ID from header: ' + SessID);
  
  var ResponseBody := ProcessJSONRPCRequest(ReqBody, SessID);
  
  if ResponseBody = '' then
  begin
    ResponseInfo.ResponseNo := HTTP_NO_CONTENT;
    Exit;
  end;
  
  ResponseInfo.ContentType := 'application/json';
  ResponseInfo.CustomHeaders.Values['Connection'] := 'keep-alive';
  
  if (SessID = '') and (Pos('"sessionId"', ResponseBody) > 0) then
  begin
    var ResponseJSON := TJSONObject.ParseJSONValue(ResponseBody) as TJSONObject;
    try
      var ResultObj := ResponseJSON.GetValue('result') as TJSONObject;
      if Assigned(ResultObj) then
      begin
        var SessionValue := ResultObj.GetValue('sessionId');
        if Assigned(SessionValue) then
          ResponseInfo.CustomHeaders.Values['Mcp-Session-Id'] := SessionValue.Value;
      end;
    finally
      ResponseJSON.Free;
    end;
  end
  else if SessID <> '' then
    ResponseInfo.CustomHeaders.Values['Mcp-Session-Id'] := SessID;

  ResponseInfo.ContentStream := TStringStream.Create(ResponseBody, TEncoding.UTF8);
  ResponseInfo.FreeContentStream := True;
  ResponseInfo.ResponseNo := HTTP_OK;
  
  TLogger.Info('Response: ' + ResponseBody);
end;

function TMCPIdHTTPServer.ParseJSONRequest(const RequestBody: string): TJSONObject;
begin
  var ParsedValue := TJSONObject.ParseJSONValue(RequestBody);
  if not (ParsedValue is TJSONObject) then
  begin
    ParsedValue.Free;
    raise Exception.Create('Invalid JSON request');
  end;
  Result := ParsedValue as TJSONObject;
end;

function TMCPIdHTTPServer.ExtractRequestID(JSONRequest: TJSONObject): TValue;
begin
  var IdValue := JSONRequest.GetValue('id');
  if not Assigned(IdValue) then
  begin
    Result := TValue.Empty;
    Exit;
  end;

  if IdValue is TJSONNumber then
    Result := TValue.From<Int64>((IdValue as TJSONNumber).AsInt64)
  else if IdValue is TJSONString then
    Result := TValue.From<string>((IdValue as TJSONString).Value)
  else
    Result := TValue.Empty;
end;

function TMCPIdHTTPServer.CreateJSONResponse(const RequestID: TValue): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('jsonrpc', '2.0');
  AddRequestIDToResponse(Result, RequestID);
end;

procedure TMCPIdHTTPServer.AddRequestIDToResponse(Response: TJSONObject; const RequestID: TValue);
begin
  if RequestID.IsEmpty then
  begin
    Response.AddPair('id', TJSONNull.Create);
    Exit;
  end;

  if RequestID.Kind in [tkString, tkUString, tkWString, tkLString] then
    Response.AddPair('id', RequestID.AsString)
  else if RequestID.Kind in [tkInteger, tkInt64] then
    Response.AddPair('id', TJSONNumber.Create(RequestID.AsInt64))
  else
    Response.AddPair('id', TJSONNull.Create);
end;

function TMCPIdHTTPServer.ExecuteMethodCall(const MethodName: string; Params: TJSONObject): TValue;
begin
  if not Assigned(FManagerRegistry) then
    raise Exception.Create('Manager registry not initialized');

  var Manager := FManagerRegistry.GetManagerForMethod(MethodName);
  if not Assigned(Manager) then
    raise Exception.CreateFmt('Method [%s] not found. The method does not exist or is not available.', [MethodName]);

  Result := Manager.ExecuteMethod(MethodName, Params);
end;

function TMCPIdHTTPServer.CreateErrorResponse(const RequestID: TValue; ErrorCode: Integer; const ErrorMessage: string): string;
begin
  var JSONResponse := CreateJSONResponse(RequestID);
  try
    var ErrorObj := TJSONObject.Create;
    JSONResponse.AddPair('error', ErrorObj);
    ErrorObj.AddPair('code', TJSONNumber.Create(ErrorCode));
    ErrorObj.AddPair('message', ErrorMessage);
    Result := JSONResponse.ToJSON;
  finally
    JSONResponse.Free;
  end;
end;

function TMCPIdHTTPServer.ProcessJSONRPCRequest(const RequestBody: string; const SessionID: string): string;
begin
  Result := '';
  var JSONRequest: TJSONObject := nil;
  var JSONResponse: TJSONObject := nil;

  try
    try
      // Parse JSON request
      JSONRequest := ParseJSONRequest(RequestBody);
      
      // Extract request ID
      var RequestID := ExtractRequestID(JSONRequest);
      
      // Extract method name
      var MethodValue := JSONRequest.GetValue('method');
      var MethodName := '';
      if Assigned(MethodValue) then
        MethodName := MethodValue.Value;
      
      // Handle notifications (no response)
      if MethodName = 'initialized' then
      begin
        TLogger.Info('MCP Initialized notification received');
        Exit;
      end;
      
      // Create response
      JSONResponse := CreateJSONResponse(RequestID);
      
      // Extract parameters
      var ParamsValue := JSONRequest.GetValue('params');
      var Params: TJSONObject := nil;
      if Assigned(ParamsValue) and (ParamsValue is TJSONObject) then
        Params := ParamsValue as TJSONObject;
      
      // Execute method
      var ExecuteResult := ExecuteMethodCall(MethodName, Params);
      
      // Add result to response
      if not ExecuteResult.IsEmpty then
      begin
        if ExecuteResult.IsType<TJSONObject> then
          JSONResponse.AddPair('result', ExecuteResult.AsType<TJSONObject>)
        else if ExecuteResult.IsType<string> then
          JSONResponse.AddPair('result', ExecuteResult.AsString)
        else
          JSONResponse.AddPair('result', ExecuteResult.ToString);
      end;
      
      Result := JSONResponse.ToJSON;
      
    except
      on E: Exception do
      begin
        TLogger.Error('Error processing request: ' + E.Message);
        
        // Determine error code
        var ErrorCode := JSONRPC_INTERNAL_ERROR;
        if Pos('not found', E.Message) > 0 then
          ErrorCode := JSONRPC_METHOD_NOT_FOUND;
          
        Result := CreateErrorResponse(ExtractRequestID(JSONRequest), ErrorCode, E.Message);
      end;
    end;
  finally
    JSONRequest.Free;
    JSONResponse.Free;    
  end;
end;

procedure TMCPIdHTTPServer.ConfigureSSL;
begin
  // Check if certificate files exist
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
  
  // Create and configure SSL handler
  {$IFDEF USE_TAURUS_TLS}
  // TaurusTLS with OpenSSL 3.x support
  FSSLHandler := TTaurusTLSServerIOHandler.Create(Self);
  FSSLHandler.DefaultCert.PublicKey := FSettings.SSLCertFile;
  FSSLHandler.DefaultCert.PrivateKey := FSettings.SSLKeyFile;
  {$ELSE}
  // Standard Indy SSL with OpenSSL 1.0.2
  FSSLHandler := TIdServerIOHandlerSSLOpenSSL.Create(Self);
  FSSLHandler.SSLOptions.CertFile := FSettings.SSLCertFile;
  FSSLHandler.SSLOptions.KeyFile := FSettings.SSLKeyFile;
  
  if (FSettings.SSLRootCertFile <> '') and TFile.Exists(FSettings.SSLRootCertFile) then
    FSSLHandler.SSLOptions.RootCertFile := FSettings.SSLRootCertFile;
  
  // Configure SSL options
  FSSLHandler.SSLOptions.Method := sslvTLSv1_2;
  FSSLHandler.SSLOptions.SSLVersions := [sslvTLSv1, sslvTLSv1_1, sslvTLSv1_2];
  FSSLHandler.SSLOptions.Mode := sslmServer;
  {$ENDIF}
  
  // Assign handler to HTTP server
  FHTTPServer.IOHandler := FSSLHandler;
  
  TLogger.Info('SSL configured successfully');
  TLogger.Info('Certificate: ' + FSettings.SSLCertFile);
  TLogger.Info('Private Key: ' + FSettings.SSLKeyFile);
  if FSettings.SSLRootCertFile <> '' then
    TLogger.Info('Root Certificate: ' + FSettings.SSLRootCertFile);
end;

procedure TMCPIdHTTPServer.HandleQuerySSLPort(APort: Word; var VUseSSL: Boolean);
begin
  // Enable SSL for our configured port when SSL is enabled
  VUseSSL := FSettings.SSLEnabled and (APort = FPort);
end;

end.