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
    FProtocol: string;
    FServerName: string;
    FServerVersion: string;
    FEndpoint: string;
    FProtocolVersion: string;
    FCorsEnabled: Boolean;
    FCorsAllowedOrigins: string;
    FSettingsFile: string;
    
    procedure LoadDefaults;
    procedure CreateDefaultSettingsFile;
  public
    constructor Create(const ASettingsFile: string = '');
    destructor Destroy; override;
    
    procedure LoadFromFile;
    procedure SaveToFile;
    
    property Port: Integer read FPort write FPort;
    property Host: string read FHost write FHost;
    property Protocol: string read FProtocol write FProtocol;
    property ServerName: string read FServerName write FServerName;
    property ServerVersion: string read FServerVersion write FServerVersion;
    property Endpoint: string read FEndpoint write FEndpoint;
    property ProtocolVersion: string read FProtocolVersion write FProtocolVersion;
    property CorsEnabled: Boolean read FCorsEnabled write FCorsEnabled;
    property CorsAllowedOrigins: string read FCorsAllowedOrigins write FCorsAllowedOrigins;
    property SettingsFile: string read FSettingsFile;
  end;

implementation

uses
  MCPServer.Logger;

{ TMCPSettings }

constructor TMCPSettings.Create(const ASettingsFile: string);
begin
  inherited Create;
  
  if ASettingsFile = '' then
    FSettingsFile := TPath.Combine(ExtractFilePath(ParamStr(0)), 'settings.ini')
  else
    FSettingsFile := ASettingsFile;
    
  LoadDefaults;
  
  if not TFile.Exists(FSettingsFile) then
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
  FProtocol := 'http';
  FServerName := 'delphi-mcp-server';
  FServerVersion := '1.0.0';
  FEndpoint := '/mcp';
  FProtocolVersion := '2025-03-26';
  FCorsEnabled := True;
  FCorsAllowedOrigins := 'http://localhost,http://127.0.0.1,https://localhost,https://127.0.0.1';
end;

procedure TMCPSettings.CreateDefaultSettingsFile;
begin
  var IniFile := TIniFile.Create(FSettingsFile);
  try
    IniFile.WriteString('Server', '; Server configuration', '');
    IniFile.WriteInteger('Server', 'Port', FPort);
    IniFile.WriteString('Server', 'Host', FHost);
    IniFile.WriteString('Server', 'Protocol', FProtocol);
    IniFile.WriteString('Server', 'Name', FServerName);
    IniFile.WriteString('Server', 'Version', FServerVersion);
    IniFile.WriteString('Server', 'Endpoint', FEndpoint);
    
    IniFile.WriteString('Protocol', '; MCP Protocol configuration', '');
    IniFile.WriteString('Protocol', 'Version', FProtocolVersion);
    
    IniFile.WriteString('CORS', '; Cross-Origin Resource Sharing configuration', '');
    IniFile.WriteBool('CORS', 'Enabled', FCorsEnabled);
    IniFile.WriteString('CORS', '; Comma-separated list of allowed origins', '');
    IniFile.WriteString('CORS', 'AllowedOrigins', FCorsAllowedOrigins);
  finally
    IniFile.Free;
  end;
end;

procedure TMCPSettings.LoadFromFile;
begin
  if not TFile.Exists(FSettingsFile) then
    Exit;
    
  var IniFile := TIniFile.Create(FSettingsFile);
  try
    FPort := IniFile.ReadInteger('Server', 'Port', FPort);
    FHost := IniFile.ReadString('Server', 'Host', FHost);
    FProtocol := IniFile.ReadString('Server', 'Protocol', FProtocol);
    FServerName := IniFile.ReadString('Server', 'Name', FServerName);
    FServerVersion := IniFile.ReadString('Server', 'Version', FServerVersion);
    FEndpoint := IniFile.ReadString('Server', 'Endpoint', FEndpoint);
    
    FProtocolVersion := IniFile.ReadString('Protocol', 'Version', FProtocolVersion);
    
    FCorsEnabled := IniFile.ReadBool('CORS', 'Enabled', FCorsEnabled);
    FCorsAllowedOrigins := IniFile.ReadString('CORS', 'AllowedOrigins', FCorsAllowedOrigins);
    
    TLogger.Info('Settings loaded from: ' + FSettingsFile);
    TLogger.Info('Server: ' + FHost + ':' + IntToStr(FPort));
    TLogger.Info('CORS Enabled: ' + BoolToStr(FCorsEnabled, True));
    if FCorsEnabled then
      TLogger.Info('CORS Allowed Origins: ' + FCorsAllowedOrigins);
  finally
    IniFile.Free;
  end;
end;

procedure TMCPSettings.SaveToFile;
begin
  var IniFile := TIniFile.Create(FSettingsFile);
  try
    IniFile.WriteInteger('Server', 'Port', FPort);
    IniFile.WriteString('Server', 'Host', FHost);
    IniFile.WriteString('Server', 'Protocol', FProtocol);
    IniFile.WriteString('Server', 'Name', FServerName);
    IniFile.WriteString('Server', 'Version', FServerVersion);
    IniFile.WriteString('Server', 'Endpoint', FEndpoint);
    
    IniFile.WriteString('Protocol', 'Version', FProtocolVersion);
    
    IniFile.WriteBool('CORS', 'Enabled', FCorsEnabled);
    IniFile.WriteString('CORS', 'AllowedOrigins', FCorsAllowedOrigins);
  finally
    IniFile.Free;
  end;
end;

end.