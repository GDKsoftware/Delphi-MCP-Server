unit MCPServer.Settings;

interface

uses
  System.SysUtils,
  System.IniFiles,
  System.IOUtils;

type
  TMCPSettings = class
  private
    FPort: Integer;
    FHost: string;
    FServerName: string;
    FServerVersion: string;
    FEndpoint: string;
    FCorsEnabled: Boolean;
    FCorsAllowedOrigins: string;
    FSettingsFile: string;
    FSSLEnabled: Boolean;
    FSSLCertFile: string;
    FSSLKeyFile: string;
    FSSLRootCertFile: string;
    FServerTitle: string;
    FServerDescription: string;
    FServerWebsiteUrl: string;
    FInstructions: string;
    FLenientModernPing: Boolean;
    FDiscoverListsLegacyVersions: Boolean;
    FDiscoverTtlMs: Integer;
    FBindAddress: string;
    FEndpointInfoPath: string;
    FMaxRequestBodyBytes: Integer;
    FMaxJsonDepth: Integer;
    FMaxConnections: Integer;
    FMaxConcurrentRequests: Integer;
    FSecurityAllowedOrigins: string;
    FAllowedHosts: string;
    FExposeDiagnosticsResources: Boolean;
    FRequestStateKey: string;
    FRequestStateTtlSeconds: Integer;
    FBearerTokens: string;
    FAuthorizationServers: string;
    FResourceUri: string;
    FScopesSupported: string;
    function GetProtocol: string;
    function SplitList(const Value: string): TArray<string>;
    function GetAllowedOrigins: string;

    procedure LoadDefaults;
    procedure CreateDefaultSettingsFile;
  public
    constructor Create(const ASettingsFile: string = ''; const ACreateFile: Boolean = True);
    constructor CreateDefaults;
    destructor Destroy; override;

    procedure LoadFromFile;
    procedure SaveToFile;

    property Port: Integer read FPort write FPort;
    property Host: string read FHost write FHost;
    property Protocol: string read GetProtocol;
    property ServerName: string read FServerName write FServerName;
    property ServerVersion: string read FServerVersion write FServerVersion;
    property Endpoint: string read FEndpoint write FEndpoint;
    property CorsEnabled: Boolean read FCorsEnabled write FCorsEnabled;
    property CorsAllowedOrigins: string read FCorsAllowedOrigins write FCorsAllowedOrigins;
    property SettingsFile: string read FSettingsFile;
    property SSLEnabled: Boolean read FSSLEnabled write FSSLEnabled;
    property SSLCertFile: string read FSSLCertFile write FSSLCertFile;
    property SSLKeyFile: string read FSSLKeyFile write FSSLKeyFile;
    property SSLRootCertFile: string read FSSLRootCertFile write FSSLRootCertFile;

    property ServerTitle: string read FServerTitle write FServerTitle;
    property ServerDescription: string read FServerDescription write FServerDescription;
    property ServerWebsiteUrl: string read FServerWebsiteUrl write FServerWebsiteUrl;
    property Instructions: string read FInstructions write FInstructions;

    property LenientModernPing: Boolean read FLenientModernPing write FLenientModernPing;
    property DiscoverListsLegacyVersions: Boolean read FDiscoverListsLegacyVersions write FDiscoverListsLegacyVersions;
    property DiscoverTtlMs: Integer read FDiscoverTtlMs write FDiscoverTtlMs;

    property BindAddress: string read FBindAddress write FBindAddress;
    property EndpointInfoPath: string read FEndpointInfoPath write FEndpointInfoPath;
    property MaxRequestBodyBytes: Integer read FMaxRequestBodyBytes write FMaxRequestBodyBytes;
    property MaxJsonDepth: Integer read FMaxJsonDepth write FMaxJsonDepth;
    property MaxConnections: Integer read FMaxConnections write FMaxConnections;
    property MaxConcurrentRequests: Integer read FMaxConcurrentRequests write FMaxConcurrentRequests;
    property SecurityAllowedOrigins: string read FSecurityAllowedOrigins write FSecurityAllowedOrigins;
    property AllowedOrigins: string read GetAllowedOrigins;
    property AllowedHosts: string read FAllowedHosts write FAllowedHosts;
    property ExposeDiagnosticsResources: Boolean read FExposeDiagnosticsResources write FExposeDiagnosticsResources;
    function AllowedHostList: TArray<string>;
    property RequestStateKey: string read FRequestStateKey write FRequestStateKey;
    property RequestStateTtlSeconds: Integer read FRequestStateTtlSeconds write FRequestStateTtlSeconds;
    property BearerTokens: string read FBearerTokens write FBearerTokens;
    property AuthorizationServers: string read FAuthorizationServers write FAuthorizationServers;
    property ResourceUri: string read FResourceUri write FResourceUri;
    property ScopesSupported: string read FScopesSupported write FScopesSupported;
    function BearerTokenList: TArray<string>;
    function AuthorizationServerList: TArray<string>;
    function ScopesSupportedList: TArray<string>;

    const DEFAULT_MAX_REQUEST_BODY_BYTES = 4 * 1024 * 1024;
    const DEFAULT_MAX_JSON_DEPTH = 64;
    const DEFAULT_MAX_CONCURRENT_REQUESTS = 1;
    const DEFAULT_REQUEST_STATE_TTL_SECONDS = 600;
  end;

implementation

uses
  MCPServer.Logger;

const
  SECTION_SERVER = 'Server';
  SECTION_SECURITY = 'Security';
  SECTION_AUTH = 'Auth';
  SECTION_SSL = 'SSL';
  SECTION_PROTOCOL = 'Protocol';
  SECTION_CORS = 'CORS';


{ TMCPSettings }

constructor TMCPSettings.Create(const ASettingsFile: string; const ACreateFile: Boolean);
begin
  inherited Create;

  const ASettingsFileIsEmpty = (ASettingsFile = '');
  if ASettingsFileIsEmpty then
    FSettingsFile := TPath.Combine(ExtractFilePath(ParamStr(0)), 'settings.ini')
  else
    FSettingsFile := ASettingsFile;

  LoadDefaults;

  if ACreateFile and (not TFile.Exists(FSettingsFile)) then
  begin
    TLogger.Info('Settings file not found. Creating default settings: ' + FSettingsFile);
    CreateDefaultSettingsFile;
  end;

  LoadFromFile;
end;

constructor TMCPSettings.CreateDefaults;
begin
  inherited Create;
  LoadDefaults;
end;

destructor TMCPSettings.Destroy;
begin
  inherited;
end;

procedure TMCPSettings.LoadDefaults;
begin
  FPort := 3000;
  FHost := 'localhost';
  FServerName := 'delphi-mcp-server';
  FServerVersion := '1.0.0';
  FEndpoint := '/mcp';
  FCorsEnabled := True;
  FCorsAllowedOrigins := 'http://localhost,http://127.0.0.1,https://localhost,https://127.0.0.1';
  FSSLEnabled := False;
  FSSLCertFile := '';
  FSSLKeyFile := '';
  FSSLRootCertFile := '';
  FServerTitle := '';
  FServerDescription := '';
  FServerWebsiteUrl := '';
  FInstructions := '';
  FLenientModernPing := False;
  FDiscoverListsLegacyVersions := False;
  FDiscoverTtlMs := 0;
  FBindAddress := '';
  FEndpointInfoPath := '';
  FMaxRequestBodyBytes := DEFAULT_MAX_REQUEST_BODY_BYTES;
  FMaxJsonDepth := DEFAULT_MAX_JSON_DEPTH;
  FMaxConcurrentRequests := DEFAULT_MAX_CONCURRENT_REQUESTS;
  FMaxConnections := 0;
  FSecurityAllowedOrigins := '';
  FAllowedHosts := '';
  FExposeDiagnosticsResources := True;
  FRequestStateKey := '';
  FRequestStateTtlSeconds := DEFAULT_REQUEST_STATE_TTL_SECONDS;
  FBearerTokens := '';
  FAuthorizationServers := '';
  FResourceUri := '';
  FScopesSupported := '';
end;

function TMCPSettings.SplitList(const Value: string): TArray<string>;
begin
  Result := nil;
  for var Item in Value.Split([',']) do
  begin
    if Item.Trim <> '' then
      Result := Result + [Item.Trim];
  end;
end;

function TMCPSettings.AllowedHostList: TArray<string>;
begin
  Result := SplitList(FAllowedHosts);
end;

function TMCPSettings.BearerTokenList: TArray<string>;
begin
  Result := SplitList(FBearerTokens);
end;

function TMCPSettings.AuthorizationServerList: TArray<string>;
begin
  Result := SplitList(FAuthorizationServers);
end;

function TMCPSettings.ScopesSupportedList: TArray<string>;
begin
  Result := SplitList(FScopesSupported);
end;

function TMCPSettings.GetAllowedOrigins: string;
begin
  if FSecurityAllowedOrigins.Trim <> '' then
    Result := FSecurityAllowedOrigins
  else
    Result := FCorsAllowedOrigins;
end;

function TMCPSettings.GetProtocol: string;
begin
  if FSSLEnabled then
    Result := 'https'
  else
    Result := 'http';
end;

procedure TMCPSettings.CreateDefaultSettingsFile;
var
  IniFile: TIniFile;
begin
  IniFile := TIniFile.Create(FSettingsFile);
  try
    IniFile.WriteString(SECTION_SERVER, '; Server configuration', '');
    IniFile.WriteInteger(SECTION_SERVER, 'Port', FPort);
    IniFile.WriteString(SECTION_SERVER, 'Host', FHost);
    IniFile.WriteString(SECTION_SERVER, 'Name', FServerName);
    IniFile.WriteString(SECTION_SERVER, 'Version', FServerVersion);
    IniFile.WriteString(SECTION_SERVER, 'Endpoint', FEndpoint);
    IniFile.WriteString(SECTION_SERVER, '; Optional identity reported to clients', '');
    IniFile.WriteString(SECTION_SERVER, 'Title', FServerTitle);
    IniFile.WriteString(SECTION_SERVER, 'Description', FServerDescription);
    IniFile.WriteString(SECTION_SERVER, 'WebsiteUrl', FServerWebsiteUrl);
    IniFile.WriteString(SECTION_SERVER, 'Instructions', FInstructions);
    IniFile.WriteString(SECTION_SERVER, '; Network: BindAddress empty = derived from Host (loopback for localhost)', '');
    IniFile.WriteString(SECTION_SERVER, 'BindAddress', FBindAddress);
    IniFile.WriteString(SECTION_SERVER, 'EndpointInfoPath', FEndpointInfoPath);
    IniFile.WriteInteger(SECTION_SERVER, 'MaxRequestBodyBytes', FMaxRequestBodyBytes);
    IniFile.WriteInteger(SECTION_SERVER, 'MaxJsonDepth', FMaxJsonDepth);
    IniFile.WriteInteger(SECTION_SERVER, 'MaxConcurrentRequests', FMaxConcurrentRequests);
    IniFile.WriteInteger(SECTION_SERVER, 'MaxConnections', FMaxConnections);
    IniFile.WriteString(SECTION_SERVER, '; Serve logs://recent, logs://{level} and server://status (0 = keep diagnostics private)', '');
    IniFile.WriteBool(SECTION_SERVER, 'ExposeDiagnosticsResources', FExposeDiagnosticsResources);

    IniFile.WriteString(SECTION_SECURITY, '; Origins allowed next to the loopback origins (empty = [CORS] AllowedOrigins)', '');
    IniFile.WriteString(SECTION_SECURITY, 'AllowedOrigins', FSecurityAllowedOrigins);
    IniFile.WriteString(SECTION_SECURITY, '; Host header values accepted, comma-separated host[:port] (empty = any)', '');
    IniFile.WriteString(SECTION_SECURITY, 'AllowedHosts', FAllowedHosts);
    IniFile.WriteString(SECTION_SECURITY, '; Secret that signs requestState tokens (empty = random per process)', '');
    IniFile.WriteString(SECTION_SECURITY, 'RequestStateKey', FRequestStateKey);
    IniFile.WriteInteger(SECTION_SECURITY, 'RequestStateTtlSeconds', FRequestStateTtlSeconds);

    IniFile.WriteString(SECTION_AUTH, '; Bearer tokens accepted on the HTTP endpoint (comma-separated; empty = open server)', '');
    IniFile.WriteString(SECTION_AUTH, 'BearerTokens', FBearerTokens);
    IniFile.WriteString(SECTION_AUTH, '; OAuth authorization servers published in the protected resource metadata', '');
    IniFile.WriteString(SECTION_AUTH, 'AuthorizationServers', FAuthorizationServers);
    IniFile.WriteString(SECTION_AUTH, 'ResourceUri', FResourceUri);
    IniFile.WriteString(SECTION_AUTH, 'ScopesSupported', FScopesSupported);

    IniFile.WriteString(SECTION_PROTOCOL, '; Protocol options (1 = on, 0 = off)', '');
    IniFile.WriteBool(SECTION_PROTOCOL, 'LenientModernPing', FLenientModernPing);
    IniFile.WriteBool(SECTION_PROTOCOL, 'DiscoverListsLegacyVersions', FDiscoverListsLegacyVersions);
    IniFile.WriteInteger(SECTION_PROTOCOL, 'DiscoverTtlMs', FDiscoverTtlMs);

    IniFile.WriteString(SECTION_CORS, '; Cross-Origin Resource Sharing configuration', '');
    IniFile.WriteBool(SECTION_CORS, 'Enabled', FCorsEnabled);
    IniFile.WriteString(SECTION_CORS, '; Comma-separated list of allowed origins', '');
    IniFile.WriteString(SECTION_CORS, 'AllowedOrigins', FCorsAllowedOrigins);

    IniFile.WriteString(SECTION_SSL, '; SSL/TLS configuration (optional)', '');
    IniFile.WriteBool(SECTION_SSL, 'Enabled', FSSLEnabled);
    IniFile.WriteString(SECTION_SSL, 'CertFile', FSSLCertFile);
    IniFile.WriteString(SECTION_SSL, 'KeyFile', FSSLKeyFile);
    IniFile.WriteString(SECTION_SSL, 'RootCertFile', FSSLRootCertFile);
  finally
    IniFile.Free;
  end;
end;

procedure TMCPSettings.LoadFromFile;
var
  IniFile: TIniFile;
begin
  if not TFile.Exists(FSettingsFile) then
    Exit;

  IniFile := TIniFile.Create(FSettingsFile);
  try
    FPort := IniFile.ReadInteger(SECTION_SERVER, 'Port', FPort);
    FHost := IniFile.ReadString(SECTION_SERVER, 'Host', FHost);
    FServerName := IniFile.ReadString(SECTION_SERVER, 'Name', FServerName);
    FServerVersion := IniFile.ReadString(SECTION_SERVER, 'Version', FServerVersion);
    FEndpoint := IniFile.ReadString(SECTION_SERVER, 'Endpoint', FEndpoint);
    FServerTitle := IniFile.ReadString(SECTION_SERVER, 'Title', FServerTitle);
    FServerDescription := IniFile.ReadString(SECTION_SERVER, 'Description', FServerDescription);
    FServerWebsiteUrl := IniFile.ReadString(SECTION_SERVER, 'WebsiteUrl', FServerWebsiteUrl);
    FInstructions := IniFile.ReadString(SECTION_SERVER, 'Instructions', FInstructions);
    FBindAddress := IniFile.ReadString(SECTION_SERVER, 'BindAddress', FBindAddress);
    FEndpointInfoPath := IniFile.ReadString(SECTION_SERVER, 'EndpointInfoPath', FEndpointInfoPath);
    FMaxRequestBodyBytes := IniFile.ReadInteger(SECTION_SERVER, 'MaxRequestBodyBytes', FMaxRequestBodyBytes);
    FMaxJsonDepth := IniFile.ReadInteger(SECTION_SERVER, 'MaxJsonDepth', FMaxJsonDepth);
    FMaxConcurrentRequests := IniFile.ReadInteger(SECTION_SERVER, 'MaxConcurrentRequests', FMaxConcurrentRequests);
    FMaxConnections := IniFile.ReadInteger(SECTION_SERVER, 'MaxConnections', FMaxConnections);

    FSecurityAllowedOrigins := IniFile.ReadString(SECTION_SECURITY, 'AllowedOrigins', FSecurityAllowedOrigins);
    FAllowedHosts := IniFile.ReadString(SECTION_SECURITY, 'AllowedHosts', FAllowedHosts);
    FExposeDiagnosticsResources := IniFile.ReadBool(SECTION_SERVER, 'ExposeDiagnosticsResources', FExposeDiagnosticsResources);
    FRequestStateKey := IniFile.ReadString(SECTION_SECURITY, 'RequestStateKey', FRequestStateKey);
    FRequestStateTtlSeconds := IniFile.ReadInteger(SECTION_SECURITY, 'RequestStateTtlSeconds', FRequestStateTtlSeconds);

    FBearerTokens := IniFile.ReadString(SECTION_AUTH, 'BearerTokens', FBearerTokens);
    FAuthorizationServers := IniFile.ReadString(SECTION_AUTH, 'AuthorizationServers', FAuthorizationServers);
    FResourceUri := IniFile.ReadString(SECTION_AUTH, 'ResourceUri', FResourceUri);
    FScopesSupported := IniFile.ReadString(SECTION_AUTH, 'ScopesSupported', FScopesSupported);

    FLenientModernPing := IniFile.ReadBool(SECTION_PROTOCOL, 'LenientModernPing', FLenientModernPing);
    FDiscoverListsLegacyVersions := IniFile.ReadBool(SECTION_PROTOCOL, 'DiscoverListsLegacyVersions', FDiscoverListsLegacyVersions);
    FDiscoverTtlMs := IniFile.ReadInteger(SECTION_PROTOCOL, 'DiscoverTtlMs', FDiscoverTtlMs);

    FCorsEnabled := IniFile.ReadBool(SECTION_CORS, 'Enabled', FCorsEnabled);
    FCorsAllowedOrigins := IniFile.ReadString(SECTION_CORS, 'AllowedOrigins', FCorsAllowedOrigins);

    FSSLEnabled := IniFile.ReadBool(SECTION_SSL, 'Enabled', FSSLEnabled);
    FSSLCertFile := IniFile.ReadString(SECTION_SSL, 'CertFile', FSSLCertFile);
    FSSLKeyFile := IniFile.ReadString(SECTION_SSL, 'KeyFile', FSSLKeyFile);
    FSSLRootCertFile := IniFile.ReadString(SECTION_SSL, 'RootCertFile', FSSLRootCertFile);

    TLogger.Info('Settings loaded from: ' + FSettingsFile);
    TLogger.Info('Server: ' + Protocol + '://' + FHost + ':' + IntToStr(FPort));
    if FSSLEnabled then
    begin
      TLogger.Info('SSL Enabled: True');
      const HasSSLCertFile = (FSSLCertFile <> '');
      if HasSSLCertFile then
        TLogger.Info('SSL Certificate: ' + FSSLCertFile);
    end;
    TLogger.Info('CORS Enabled: ' + BoolToStr(FCorsEnabled, True));
    if FCorsEnabled then
      TLogger.Info('CORS Allowed Origins: ' + FCorsAllowedOrigins);
  finally
    IniFile.Free;
  end;
end;

procedure TMCPSettings.SaveToFile;
var
  IniFile: TIniFile;
begin
  const HasSettingsFile = (FSettingsFile <> '');
  if not HasSettingsFile then
    Exit;

  IniFile := TIniFile.Create(FSettingsFile);
  try
    IniFile.WriteInteger(SECTION_SERVER, 'Port', FPort);
    IniFile.WriteString(SECTION_SERVER, 'Host', FHost);
    IniFile.WriteString(SECTION_SERVER, 'Name', FServerName);
    IniFile.WriteString(SECTION_SERVER, 'Version', FServerVersion);
    IniFile.WriteString(SECTION_SERVER, 'Endpoint', FEndpoint);
    IniFile.WriteString(SECTION_SERVER, 'Title', FServerTitle);
    IniFile.WriteString(SECTION_SERVER, 'Description', FServerDescription);
    IniFile.WriteString(SECTION_SERVER, 'WebsiteUrl', FServerWebsiteUrl);
    IniFile.WriteString(SECTION_SERVER, 'Instructions', FInstructions);
    IniFile.WriteString(SECTION_SERVER, 'BindAddress', FBindAddress);
    IniFile.WriteString(SECTION_SERVER, 'EndpointInfoPath', FEndpointInfoPath);
    IniFile.WriteInteger(SECTION_SERVER, 'MaxRequestBodyBytes', FMaxRequestBodyBytes);
    IniFile.WriteInteger(SECTION_SERVER, 'MaxJsonDepth', FMaxJsonDepth);
    IniFile.WriteInteger(SECTION_SERVER, 'MaxConcurrentRequests', FMaxConcurrentRequests);
    IniFile.WriteInteger(SECTION_SERVER, 'MaxConnections', FMaxConnections);
    IniFile.WriteBool(SECTION_SERVER, 'ExposeDiagnosticsResources', FExposeDiagnosticsResources);

    IniFile.WriteString(SECTION_SECURITY, 'AllowedOrigins', FSecurityAllowedOrigins);
    IniFile.WriteString(SECTION_SECURITY, 'AllowedHosts', FAllowedHosts);
    IniFile.WriteString(SECTION_SECURITY, 'RequestStateKey', FRequestStateKey);
    IniFile.WriteInteger(SECTION_SECURITY, 'RequestStateTtlSeconds', FRequestStateTtlSeconds);

    IniFile.WriteString(SECTION_AUTH, 'BearerTokens', FBearerTokens);
    IniFile.WriteString(SECTION_AUTH, 'AuthorizationServers', FAuthorizationServers);
    IniFile.WriteString(SECTION_AUTH, 'ResourceUri', FResourceUri);
    IniFile.WriteString(SECTION_AUTH, 'ScopesSupported', FScopesSupported);

    IniFile.WriteBool(SECTION_PROTOCOL, 'LenientModernPing', FLenientModernPing);
    IniFile.WriteBool(SECTION_PROTOCOL, 'DiscoverListsLegacyVersions', FDiscoverListsLegacyVersions);
    IniFile.WriteInteger(SECTION_PROTOCOL, 'DiscoverTtlMs', FDiscoverTtlMs);

    IniFile.WriteBool(SECTION_CORS, 'Enabled', FCorsEnabled);
    IniFile.WriteString(SECTION_CORS, 'AllowedOrigins', FCorsAllowedOrigins);

    IniFile.WriteBool(SECTION_SSL, 'Enabled', FSSLEnabled);
    IniFile.WriteString(SECTION_SSL, 'CertFile', FSSLCertFile);
    IniFile.WriteString(SECTION_SSL, 'KeyFile', FSSLKeyFile);
    IniFile.WriteString(SECTION_SSL, 'RootCertFile', FSSLRootCertFile);
  finally
    IniFile.Free;
  end;
end;

end.