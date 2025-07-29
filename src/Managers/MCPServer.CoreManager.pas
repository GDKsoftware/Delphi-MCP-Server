unit MCPServer.CoreManager;

interface

uses
  System.SysUtils,
  System.JSON,
  System.Rtti,
  System.DateUtils,
  MCPServer.Types,
  MCPServer.Settings,
  MCPServer.Logger;

type
  TMCPCoreManager = class(TInterfacedObject, IMCPCapabilityManager)
  private
    FSessionID: string;
    FSettings: TMCPSettings;
  public
    constructor Create(ASettings: TMCPSettings);
    
    function GetCapabilityName: string;
    function HandlesMethod(const Method: string): Boolean;
    function ExecuteMethod(const Method: string; const Params: TJSONObject): TValue;
    
    function Initialize(const Params: TJSONObject): TValue;
    function Ping: TValue;
    
    property SessionID: string read FSessionID;
  end;

implementation

{ TMCPCoreManager }

constructor TMCPCoreManager.Create(ASettings: TMCPSettings);
begin
  inherited Create;
  FSettings := ASettings;
  FSessionID := '';
end;

function TMCPCoreManager.GetCapabilityName: string;
begin
  Result := 'core';
end;

function TMCPCoreManager.HandlesMethod(const Method: string): Boolean;
begin
  Result := (Method = 'initialize') or 
            (Method = 'notifications/initialized') or
            (Method = 'ping');
end;

function TMCPCoreManager.ExecuteMethod(const Method: string; const Params: TJSONObject): TValue;
begin
  if Method = 'initialize' then
    Result := Initialize(Params)
  else if Method = 'notifications/initialized' then
  begin
    TLogger.Info('MCP Initialized notification received');
    Result := TValue.Empty;
  end
  else if Method = 'ping' then
    Result := Ping
  else
    raise Exception.CreateFmt('Method %s not handled by %s', [Method, GetCapabilityName]);
end;

function TMCPCoreManager.Initialize(const Params: TJSONObject): TValue;
begin
  TLogger.Info('MCP Initialize called');
  
  if Assigned(Params) then
  begin
    var ClientInfo := Params.GetValue('clientInfo') as TJSONObject;

    if Assigned(ClientInfo) then
    begin
      var ClientName := ClientInfo.GetValue('name');
      var ClientVersion := ClientInfo.GetValue('version');

      if Assigned(ClientName) and Assigned(ClientVersion) then
        TLogger.Info(Format('Client: %s v%s', [ClientName.Value, ClientVersion.Value]));
    end;
  end;
  
  FSessionID := TGuid.NewGuid.ToString;
  
  var ResultJSON := TJSONObject.Create;
  try
    ResultJSON.AddPair('protocolVersion', FSettings.ProtocolVersion);
    
    var Capabilities := TJSONObject.Create;
    ResultJSON.AddPair('capabilities', Capabilities);
    
    var ToolsCap := TJSONObject.Create;
    Capabilities.AddPair('tools', ToolsCap);
    ToolsCap.AddPair('supportsProgress', TJSONBool.Create(False));
    ToolsCap.AddPair('supportsCancellation', TJSONBool.Create(False));
    
    var ResourcesCap := TJSONObject.Create;
    Capabilities.AddPair('resources', ResourcesCap);
    ResourcesCap.AddPair('subscribe', TJSONBool.Create(False));
    ResourcesCap.AddPair('listChanged', TJSONBool.Create(False));
    
    ResultJSON.AddPair('sessionId', FSessionID);
    
    var ServerInfo := TJSONObject.Create;
    ResultJSON.AddPair('serverInfo', ServerInfo);
    ServerInfo.AddPair('name', FSettings.ServerName);
    ServerInfo.AddPair('version', FSettings.ServerVersion);
    
    TLogger.Info('Created new MCP session: ' + FSessionID);
    
    Result := TValue.From<TJSONObject>(ResultJSON);
  except
    ResultJSON.Free;
    raise;
  end;
end;

function TMCPCoreManager.Ping: TValue;
begin
  TLogger.Info('MCP Ping called');
  
  var ResultJSON := TJSONObject.Create;
  try
    Result := TValue.From<TJSONObject>(ResultJSON);
  except
    ResultJSON.Free;
    raise;
  end;
end;

end.