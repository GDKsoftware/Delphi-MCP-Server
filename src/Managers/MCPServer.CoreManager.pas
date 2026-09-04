unit MCPServer.CoreManager;

interface

uses
  System.SysUtils,
  System.JSON,
  System.Rtti,
  MCPServer.Types,
  MCPServer.Settings,
  MCPServer.Logger;

type
  TMCPCoreManager = class(TInterfacedObject, IMCPCapabilityManager, IMCPCapabilityManagerEx, IMCPRegistryAware)
  private
    FSettings: TMCPSettings;
    [Weak] FManagerRegistry: IMCPManagerRegistry;
    function GetSessionID: string;
    function BuildServerInfo: TJSONObject;
    function BuildCapabilities(Era: TMCPProtocolEra): TJSONObject;
    function SupportedVersions: TJSONArray;
    procedure LogClientInfo(const ClientInfo: TJSONValue);
    procedure WarnAboutDeprecatedClientCapabilities(const Capabilities: TJSONValue);
  public
    constructor Create(ASettings: TMCPSettings);

    function GetCapabilityName: string;
    function HandlesMethod(const Method: string): Boolean;
    function ExecuteMethod(const Method: string; const Params: TJSONObject): TValue;
    function ExecuteMethodWithContext(const Method: string; const Params: TJSONObject;
      const Context: IMCPRequestContext): TValue;
    procedure SetManagerRegistry(const Registry: IMCPManagerRegistry);

    function Initialize(const Params: TJSONObject; const Context: IMCPRequestContext): TValue;
    function Discover(const Context: IMCPRequestContext): TValue;
    function Ping: TValue;

    property SessionID: string read GetSessionID;
    property ManagerRegistry: IMCPManagerRegistry read FManagerRegistry;
  end;

implementation

uses
  MCPServer.Capabilities,
  MCPServer.RequestContext;

const
  CACHE_SCOPE_PUBLIC = 'public';

{ TMCPCoreManager }

constructor TMCPCoreManager.Create(ASettings: TMCPSettings);
begin
  inherited Create;
  FSettings := ASettings;
end;

function TMCPCoreManager.GetCapabilityName: string;
begin
  Result := 'core';
end;

function TMCPCoreManager.GetSessionID: string;
begin
  Result := '';
end;

procedure TMCPCoreManager.SetManagerRegistry(const Registry: IMCPManagerRegistry);
begin
  FManagerRegistry := Registry;
end;

function TMCPCoreManager.HandlesMethod(const Method: string): Boolean;
begin
  Result := (Method = 'initialize') or
            (Method = 'notifications/initialized') or
            (Method = 'ping') or
            (Method = 'server/discover');
end;

function TMCPCoreManager.ExecuteMethod(const Method: string; const Params: TJSONObject): TValue;
begin
  Result := ExecuteMethodWithContext(Method, Params, TMCPRequestContext.Current);
end;

function TMCPCoreManager.ExecuteMethodWithContext(const Method: string; const Params: TJSONObject;
  const Context: IMCPRequestContext): TValue;
begin
  if Method = 'initialize' then
    Result := Initialize(Params, Context)
  else if Method = 'notifications/initialized' then
  begin
    TLogger.Info('MCP Initialized notification received');
    Result := TValue.Empty;
  end
  else if Method = 'ping' then
    Result := Ping
  else if Method = 'server/discover' then
    Result := Discover(Context)
  else
    raise Exception.CreateFmt('Method %s not handled by %s', [Method, GetCapabilityName]);
end;

function TMCPCoreManager.BuildServerInfo: TJSONObject;
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

function TMCPCoreManager.BuildCapabilities(Era: TMCPProtocolEra): TJSONObject;
begin
  Result := TMCPCapabilityBuilder.Build(FManagerRegistry, Era);
end;

function TMCPCoreManager.SupportedVersions: TJSONArray;
begin
  Result := TJSONArray.Create;
  for var Version in MCP_MODERN_PROTOCOL_VERSIONS do
    Result.Add(Version);
  if FSettings.DiscoverListsLegacyVersions then
    for var Version in MCP_LEGACY_PROTOCOL_VERSIONS do
      Result.Add(Version);
end;

procedure TMCPCoreManager.LogClientInfo(const ClientInfo: TJSONValue);
begin
  if not (ClientInfo is TJSONObject) then
    Exit;

  var ClientName := TJSONObject(ClientInfo).GetValue('name');
  var ClientVersion := TJSONObject(ClientInfo).GetValue('version');
  if Assigned(ClientName) and Assigned(ClientVersion) then
    TLogger.Info(Format('Client: %s v%s', [ClientName.Value, ClientVersion.Value]));
end;

procedure TMCPCoreManager.WarnAboutDeprecatedClientCapabilities(const Capabilities: TJSONValue);
begin
  if not (Capabilities is TJSONObject) then
    Exit;

  for var Deprecated in ['roots', 'sampling'] do
    if Assigned(TJSONObject(Capabilities).GetValue(Deprecated)) then
      TLogger.Warning(Format('Client declares the %s capability; this server does not use it (deprecated in MCP 2026-07-28)', [Deprecated]));
end;

function TMCPCoreManager.Initialize(const Params: TJSONObject; const Context: IMCPRequestContext): TValue;
var
  Negotiated: string;
begin
  TLogger.Info('MCP Initialize called');

  if Assigned(Context) then
    Negotiated := Context.ProtocolVersion
  else
  begin
    var Requested := '';
    if Assigned(Params) then
    begin
      var RequestedValue := Params.GetValue('protocolVersion');
      if RequestedValue is TJSONString then
        Requested := TJSONString(RequestedValue).Value;
    end;
    Negotiated := NegotiateLegacyProtocolVersion(Requested);
  end;

  if Assigned(Params) then
  begin
    LogClientInfo(Params.GetValue('clientInfo'));
    WarnAboutDeprecatedClientCapabilities(Params.GetValue('capabilities'));
  end;

  var ResultJSON := TJSONObject.Create;
  try
    ResultJSON.AddPair('protocolVersion', Negotiated);
    ResultJSON.AddPair('capabilities', BuildCapabilities(TMCPProtocolEra.Legacy));
    ResultJSON.AddPair('serverInfo', BuildServerInfo);
    if FSettings.Instructions <> '' then
      ResultJSON.AddPair('instructions', FSettings.Instructions);

    if Assigned(Context) and Assigned(Context.LegacySession) then
      Context.LegacySession.ProtocolVersion := Negotiated;

    TLogger.Info('Negotiated protocol version ' + Negotiated);
    Result := TValue.From<TJSONObject>(ResultJSON);
  except
    ResultJSON.Free;
    raise;
  end;
end;

function TMCPCoreManager.Discover(const Context: IMCPRequestContext): TValue;
begin
  TLogger.Info('MCP Discover called');

  var ResultJSON := TJSONObject.Create;
  try
    ResultJSON.AddPair('resultType', 'complete');
    ResultJSON.AddPair('supportedVersions', SupportedVersions);
    ResultJSON.AddPair('capabilities', BuildCapabilities(TMCPProtocolEra.Modern));

    var Meta := TJSONObject.Create;
    ResultJSON.AddPair('_meta', Meta);
    Meta.AddPair(MCP_META_SERVER_INFO, BuildServerInfo);

    if FSettings.Instructions <> '' then
      ResultJSON.AddPair('instructions', FSettings.Instructions);
    ResultJSON.AddPair('ttlMs', TJSONNumber.Create(FSettings.DiscoverTtlMs));
    ResultJSON.AddPair('cacheScope', CACHE_SCOPE_PUBLIC);

    Result := TValue.From<TJSONObject>(ResultJSON);
  except
    ResultJSON.Free;
    raise;
  end;
end;

function TMCPCoreManager.Ping: TValue;
begin
  TLogger.Info('MCP Ping called');
  Result := TValue.From<TJSONObject>(TJSONObject.Create);
end;

end.
