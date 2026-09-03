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
    FSecurityAllowedOrigins: string;
    function GetProtocol: string;
    function GetAllowedOrigins: string;

    procedure LoadDefaults;
    procedure CreateDefaultSettingsFile;
  public
    constructor Create(const ASettingsFile: string = ''; const ACreateFile: Boolean = True);
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

    // Optional server identity ([Server] Title, Description, WebsiteUrl,
    // Instructions); reported in initialize and server/discover when set.
    property ServerTitle: string read FServerTitle write FServerTitle;
    property ServerDescription: string read FServerDescription write FServerDescription;
    property ServerWebsiteUrl: string read FServerWebsiteUrl write FServerWebsiteUrl;
    property Instructions: string read FInstructions write FInstructions;

    /// [Protocol] LenientModernPing: answer ping for 2026-07-28 requests
    /// although the revision removed it. Default off.
    property LenientModernPing: Boolean read FLenientModernPing write FLenientModernPing;
    /// [Protocol] DiscoverListsLegacyVersions: also list the initialize-based
    /// revisions in server/discover and in unsupported-version errors. Default off.
    property DiscoverListsLegacyVersions: Boolean read FDiscoverListsLegacyVersions write FDiscoverListsLegacyVersions;
    /// [Protocol] DiscoverTtlMs: cache hint on server/discover. Default 0.
    property DiscoverTtlMs: Integer read FDiscoverTtlMs write FDiscoverTtlMs;

    /// [Server] BindAddress: the interface to listen on. Empty (default)
    /// derives it from Host: a loopback Host binds 127.0.0.1 and ::1, any
    /// other Host binds every interface.
    property BindAddress: string read FBindAddress write FBindAddress;
    /// [Server] EndpointInfoPath: optional GET path that answers a small JSON
    /// document with the endpoint URL and the protocol versions. Empty = off.
    property EndpointInfoPath: string read FEndpointInfoPath write FEndpointInfoPath;
    /// [Server] MaxRequestBodyBytes: larger POST bodies get 413. Default 4 MB.
    property MaxRequestBodyBytes: Integer read FMaxRequestBodyBytes write FMaxRequestBodyBytes;
    /// [Server] MaxJsonDepth: deeper nesting gets 400. Default 64.
    property MaxJsonDepth: Integer read FMaxJsonDepth write FMaxJsonDepth;
    /// [Server] MaxConnections: Indy connection limit; 0 = unlimited.
    property MaxConnections: Integer read FMaxConnections write FMaxConnections;
    /// [Security] AllowedOrigins: origins that pass the Origin check next to
    /// the loopback origins. Falls back to [CORS] AllowedOrigins when empty.
    property SecurityAllowedOrigins: string read FSecurityAllowedOrigins write FSecurityAllowedOrigins;
    /// The effective allow-list for the Origin check.
    property AllowedOrigins: string read GetAllowedOrigins;

    const DEFAULT_MAX_REQUEST_BODY_BYTES = 4 * 1024 * 1024;
    const DEFAULT_MAX_JSON_DEPTH = 64;
  end;

implementation

uses
  MCPServer.Logger;

{ TMCPSettings }

constructor TMCPSettings.Create(const ASettingsFile: string; const ACreateFile: Boolean);
begin
  inherited Create;
  
  if ASettingsFile = '' then
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
  FMaxConnections := 0;
  FSecurityAllowedOrigins := '';
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
    IniFile.WriteString('Server', '; Server configuration', '');
    IniFile.WriteInteger('Server', 'Port', FPort);
    IniFile.WriteString('Server', 'Host', FHost);
    IniFile.WriteString('Server', 'Name', FServerName);
    IniFile.WriteString('Server', 'Version', FServerVersion);
    IniFile.WriteString('Server', 'Endpoint', FEndpoint);
    IniFile.WriteString('Server', '; Optional identity reported to clients', '');
    IniFile.WriteString('Server', 'Title', FServerTitle);
    IniFile.WriteString('Server', 'Description', FServerDescription);
    IniFile.WriteString('Server', 'WebsiteUrl', FServerWebsiteUrl);
    IniFile.WriteString('Server', 'Instructions', FInstructions);
    IniFile.WriteString('Server', '; Network: BindAddress empty = derived from Host (loopback for localhost)', '');
    IniFile.WriteString('Server', 'BindAddress', FBindAddress);
    IniFile.WriteString('Server', 'EndpointInfoPath', FEndpointInfoPath);
    IniFile.WriteInteger('Server', 'MaxRequestBodyBytes', FMaxRequestBodyBytes);
    IniFile.WriteInteger('Server', 'MaxJsonDepth', FMaxJsonDepth);
    IniFile.WriteInteger('Server', 'MaxConnections', FMaxConnections);

    IniFile.WriteString('Security', '; Origins allowed next to the loopback origins (empty = [CORS] AllowedOrigins)', '');
    IniFile.WriteString('Security', 'AllowedOrigins', FSecurityAllowedOrigins);

    IniFile.WriteString('Protocol', '; Protocol options (1 = on, 0 = off)', '');
    IniFile.WriteBool('Protocol', 'LenientModernPing', FLenientModernPing);
    IniFile.WriteBool('Protocol', 'DiscoverListsLegacyVersions', FDiscoverListsLegacyVersions);
    IniFile.WriteInteger('Protocol', 'DiscoverTtlMs', FDiscoverTtlMs);

    IniFile.WriteString('CORS', '; Cross-Origin Resource Sharing configuration', '');
    IniFile.WriteBool('CORS', 'Enabled', FCorsEnabled);
    IniFile.WriteString('CORS', '; Comma-separated list of allowed origins', '');
    IniFile.WriteString('CORS', 'AllowedOrigins', FCorsAllowedOrigins);
    
    IniFile.WriteString('SSL', '; SSL/TLS configuration (optional)', '');
    IniFile.WriteBool('SSL', 'Enabled', FSSLEnabled);
    IniFile.WriteString('SSL', 'CertFile', FSSLCertFile);
    IniFile.WriteString('SSL', 'KeyFile', FSSLKeyFile);
    IniFile.WriteString('SSL', 'RootCertFile', FSSLRootCertFile);
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
    FPort := IniFile.ReadInteger('Server', 'Port', FPort);
    FHost := IniFile.ReadString('Server', 'Host', FHost);
    FServerName := IniFile.ReadString('Server', 'Name', FServerName);
    FServerVersion := IniFile.ReadString('Server', 'Version', FServerVersion);
    FEndpoint := IniFile.ReadString('Server', 'Endpoint', FEndpoint);
    FServerTitle := IniFile.ReadString('Server', 'Title', FServerTitle);
    FServerDescription := IniFile.ReadString('Server', 'Description', FServerDescription);
    FServerWebsiteUrl := IniFile.ReadString('Server', 'WebsiteUrl', FServerWebsiteUrl);
    FInstructions := IniFile.ReadString('Server', 'Instructions', FInstructions);
    FBindAddress := IniFile.ReadString('Server', 'BindAddress', FBindAddress);
    FEndpointInfoPath := IniFile.ReadString('Server', 'EndpointInfoPath', FEndpointInfoPath);
    FMaxRequestBodyBytes := IniFile.ReadInteger('Server', 'MaxRequestBodyBytes', FMaxRequestBodyBytes);
    FMaxJsonDepth := IniFile.ReadInteger('Server', 'MaxJsonDepth', FMaxJsonDepth);
    FMaxConnections := IniFile.ReadInteger('Server', 'MaxConnections', FMaxConnections);

    FSecurityAllowedOrigins := IniFile.ReadString('Security', 'AllowedOrigins', FSecurityAllowedOrigins);

    FLenientModernPing := IniFile.ReadBool('Protocol', 'LenientModernPing', FLenientModernPing);
    FDiscoverListsLegacyVersions := IniFile.ReadBool('Protocol', 'DiscoverListsLegacyVersions', FDiscoverListsLegacyVersions);
    FDiscoverTtlMs := IniFile.ReadInteger('Protocol', 'DiscoverTtlMs', FDiscoverTtlMs);

    FCorsEnabled := IniFile.ReadBool('CORS', 'Enabled', FCorsEnabled);
    FCorsAllowedOrigins := IniFile.ReadString('CORS', 'AllowedOrigins', FCorsAllowedOrigins);
    
    FSSLEnabled := IniFile.ReadBool('SSL', 'Enabled', FSSLEnabled);
    FSSLCertFile := IniFile.ReadString('SSL', 'CertFile', FSSLCertFile);
    FSSLKeyFile := IniFile.ReadString('SSL', 'KeyFile', FSSLKeyFile);
    FSSLRootCertFile := IniFile.ReadString('SSL', 'RootCertFile', FSSLRootCertFile);
    
    TLogger.Info('Settings loaded from: ' + FSettingsFile);
    TLogger.Info('Server: ' + Protocol + '://' + FHost + ':' + IntToStr(FPort));
    if FSSLEnabled then
    begin
      TLogger.Info('SSL Enabled: True');
      if FSSLCertFile <> '' then
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
  IniFile := TIniFile.Create(FSettingsFile);
  try
    IniFile.WriteInteger('Server', 'Port', FPort);
    IniFile.WriteString('Server', 'Host', FHost);
    IniFile.WriteString('Server', 'Name', FServerName);
    IniFile.WriteString('Server', 'Version', FServerVersion);
    IniFile.WriteString('Server', 'Endpoint', FEndpoint);
    IniFile.WriteString('Server', 'Title', FServerTitle);
    IniFile.WriteString('Server', 'Description', FServerDescription);
    IniFile.WriteString('Server', 'WebsiteUrl', FServerWebsiteUrl);
    IniFile.WriteString('Server', 'Instructions', FInstructions);
    IniFile.WriteString('Server', 'BindAddress', FBindAddress);
    IniFile.WriteString('Server', 'EndpointInfoPath', FEndpointInfoPath);
    IniFile.WriteInteger('Server', 'MaxRequestBodyBytes', FMaxRequestBodyBytes);
    IniFile.WriteInteger('Server', 'MaxJsonDepth', FMaxJsonDepth);
    IniFile.WriteInteger('Server', 'MaxConnections', FMaxConnections);

    IniFile.WriteString('Security', 'AllowedOrigins', FSecurityAllowedOrigins);

    IniFile.WriteBool('Protocol', 'LenientModernPing', FLenientModernPing);
    IniFile.WriteBool('Protocol', 'DiscoverListsLegacyVersions', FDiscoverListsLegacyVersions);
    IniFile.WriteInteger('Protocol', 'DiscoverTtlMs', FDiscoverTtlMs);

    IniFile.WriteBool('CORS', 'Enabled', FCorsEnabled);
    IniFile.WriteString('CORS', 'AllowedOrigins', FCorsAllowedOrigins);
    
    IniFile.WriteBool('SSL', 'Enabled', FSSLEnabled);
    IniFile.WriteString('SSL', 'CertFile', FSSLCertFile);
    IniFile.WriteString('SSL', 'KeyFile', FSSLKeyFile);
    IniFile.WriteString('SSL', 'RootCertFile', FSSLRootCertFile);
  finally
    IniFile.Free;
  end;
end;

end.