unit MCPServer.RequestContext;

interface

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
  MCPServer.Types;

const
  PROGRESS_MIN_INTERVAL_MS = 50;

type
  TMCPTransportHints = record
    HasHeaderLayer: Boolean;
    HasProtocolVersionHeader: Boolean;
    ProtocolVersionHeader: string;
    HasMethodHeader: Boolean;
    MethodHeader: string;
    HasNameHeader: Boolean;
    NameHeader: string;
    RemoteAddress: string;
    Principal: string;
    Scopes: TArray<string>;
    LegacySession: TMCPLegacySession;
    Sink: IMCPMessageSink;
    Tracker: IMCPRequestTracker;

    class function None: TMCPTransportHints; static;
    class function ForStdio(const Session: TMCPLegacySession): TMCPTransportHints; overload; static;
    class function ForStdio(const Session: TMCPLegacySession; const Sink: IMCPMessageSink;
      const Tracker: IMCPRequestTracker): TMCPTransportHints; overload; static;
    class function ForHttp(const HasVersionHeader: Boolean; const VersionHeader: string): TMCPTransportHints; static;
  end;

  TMCPRequestContext = class(TInterfacedObject, IMCPRequestContext)
  private
    FEra: TMCPProtocolEra;
    FProtocolVersion: string;
    FMethod: string;
    FRequestId: TMCPRequestId;
    FMeta: TJSONObject;
    FLegacySession: TMCPLegacySession;
    FManagerRegistry: IMCPManagerRegistry;
    FSink: IMCPMessageSink;
    FInputResponses: TJSONObject;
    FRequestState: TJSONObject;
    FPrincipal: string;
    FScopes: TArray<string>;
    FCancelled: Integer;
    FProgressLock: TObject;
    FProgressSent: Boolean;
    FLastProgress: Double;
    FLastProgressTick: UInt64;
    function TryClaimProgress(const Progress: Double; const Completes: Boolean): Boolean;
    function MetaObject(const Key: string): TJSONObject;
  public
    constructor Create(Era: TMCPProtocolEra; const ProtocolVersion, Method: string;
      const RequestId: TMCPRequestId; const Meta: TJSONObject;
      const LegacySession: TMCPLegacySession; const ManagerRegistry: IMCPManagerRegistry;
      const Sink: IMCPMessageSink = nil; const InputResponses: TJSONObject = nil;
      const RequestState: TJSONObject = nil; const Principal: string = '';
      const Scopes: TArray<string> = nil);
    destructor Destroy; override;

    function GetEra: TMCPProtocolEra;
    function GetProtocolVersion: string;
    function GetMethod: string;
    function GetRequestId: TMCPRequestId;
    function GetMeta: TJSONObject;
    function GetClientCapabilities: TJSONObject;
    function GetClientInfo: TJSONObject;
    function GetLogLevel: string;
    function GetProgressToken: TJSONValue;
    function GetLegacySession: TMCPLegacySession;
    function GetManagerRegistry: IMCPManagerRegistry;
    function GetInputResponses: TJSONObject;
    function GetRequestState: TJSONObject;
    function GetSink: IMCPMessageSink;
    function GetPrincipal: string;
    function GetScopes: TArray<string>;
    function HasClientCapability(const Path: string): Boolean;
    function HasScope(const Scope: string): Boolean;
    procedure RequireClientCapability(const Path: string);
    function IsCancelled: Boolean;
    procedure CheckCancelled;
    procedure Cancel;
    function HasProgressToken: Boolean;
    procedure ReportProgress(const Progress: Double; const Total: Double = -1; const Message: string = '');
    function TryGetInputResponse(const Key: string; out Response: TJSONObject): Boolean;
    procedure Log(const Level, Text: string; const Logger: string = '');
    procedure LogJson(const Level: string; const Data: TJSONValue; const Logger: string = '');

    class function Current: IMCPRequestContext;
    class function SetCurrent(const Value: IMCPRequestContext): IMCPRequestContext;
  end;

implementation

uses
  MCPServer.Errors;

threadvar
  CurrentContextPointer: Pointer;

{ TMCPTransportHints }

class function TMCPTransportHints.None: TMCPTransportHints;
begin
  Result := Default(TMCPTransportHints);
end;

class function TMCPTransportHints.ForStdio(const Session: TMCPLegacySession): TMCPTransportHints;
begin
  Result := Default(TMCPTransportHints);
  Result.LegacySession := Session;
end;

class function TMCPTransportHints.ForStdio(const Session: TMCPLegacySession; const Sink: IMCPMessageSink;
  const Tracker: IMCPRequestTracker): TMCPTransportHints;
begin
  Result := ForStdio(Session);
  Result.Sink := Sink;
  Result.Tracker := Tracker;
end;

class function TMCPTransportHints.ForHttp(const HasVersionHeader: Boolean; const VersionHeader: string): TMCPTransportHints;
begin
  Result := Default(TMCPTransportHints);
  Result.HasHeaderLayer := True;
  Result.HasProtocolVersionHeader := HasVersionHeader;
  Result.ProtocolVersionHeader := VersionHeader;
end;

{ TMCPRequestContext }

constructor TMCPRequestContext.Create(Era: TMCPProtocolEra; const ProtocolVersion, Method: string;
  const RequestId: TMCPRequestId; const Meta: TJSONObject; const LegacySession: TMCPLegacySession;
  const ManagerRegistry: IMCPManagerRegistry; const Sink: IMCPMessageSink; const InputResponses: TJSONObject;
  const RequestState: TJSONObject; const Principal: string; const Scopes: TArray<string>);
begin
  inherited Create;
  FEra := Era;
  FProtocolVersion := ProtocolVersion;
  FMethod := Method;
  FRequestId := RequestId;
  if Assigned(Meta) then
    FMeta := TJSONObject(Meta.Clone);
  FLegacySession := LegacySession;
  FManagerRegistry := ManagerRegistry;
  FSink := Sink;
  if Assigned(InputResponses) then
    FInputResponses := TJSONObject(InputResponses.Clone);
  FRequestState := RequestState;
  FPrincipal := Principal;
  FScopes := Scopes;
  FProgressLock := TObject.Create;
end;

destructor TMCPRequestContext.Destroy;
begin
  FMeta.Free;
  FInputResponses.Free;
  FRequestState.Free;
  FProgressLock.Free;
  inherited;
end;

function TMCPRequestContext.MetaObject(const Key: string): TJSONObject;
begin
  Result := nil;
  if not Assigned(FMeta) then
    Exit;

  var Value := FMeta.GetValue(Key);
  if Value is TJSONObject then
    Result := TJSONObject(Value);
end;

function TMCPRequestContext.GetEra: TMCPProtocolEra;
begin
  Result := FEra;
end;

function TMCPRequestContext.GetProtocolVersion: string;
begin
  Result := FProtocolVersion;
end;

function TMCPRequestContext.GetMethod: string;
begin
  Result := FMethod;
end;

function TMCPRequestContext.GetRequestId: TMCPRequestId;
begin
  Result := FRequestId;
end;

function TMCPRequestContext.GetMeta: TJSONObject;
begin
  Result := FMeta;
end;

function TMCPRequestContext.GetClientCapabilities: TJSONObject;
begin
  Result := MetaObject(MCP_META_CLIENT_CAPABILITIES);
end;

function TMCPRequestContext.GetClientInfo: TJSONObject;
begin
  Result := MetaObject(MCP_META_CLIENT_INFO);
end;

function TMCPRequestContext.GetLogLevel: string;
begin
  Result := '';
  if not Assigned(FMeta) then
    Exit;

  var Value := FMeta.GetValue(MCP_META_LOG_LEVEL);
  if IsJsonString(Value) then
    Result := TJSONString(Value).Value;
end;

function TMCPRequestContext.GetProgressToken: TJSONValue;
begin
  Result := nil;
  if Assigned(FMeta) then
    Result := FMeta.GetValue(MCP_META_PROGRESS_TOKEN);
end;

function TMCPRequestContext.GetLegacySession: TMCPLegacySession;
begin
  Result := FLegacySession;
end;

function TMCPRequestContext.GetManagerRegistry: IMCPManagerRegistry;
begin
  Result := FManagerRegistry;
end;

function TMCPRequestContext.GetInputResponses: TJSONObject;
begin
  Result := FInputResponses;
end;

function TMCPRequestContext.GetRequestState: TJSONObject;
begin
  Result := FRequestState;
end;

function TMCPRequestContext.GetSink: IMCPMessageSink;
begin
  Result := FSink;
end;

function TMCPRequestContext.GetPrincipal: string;
begin
  Result := FPrincipal;
end;

function TMCPRequestContext.GetScopes: TArray<string>;
begin
  Result := FScopes;
end;

function TMCPRequestContext.HasScope(const Scope: string): Boolean;
begin
  for var Granted in FScopes do
  begin
    if (Granted = Scope) or (Granted = MCP_SCOPE_ANY) then
      Exit(True);
  end;
  Result := False;
end;

function TMCPRequestContext.TryGetInputResponse(const Key: string; out Response: TJSONObject): Boolean;
begin
  Response := nil;
  if not Assigned(FInputResponses) then
    Exit(False);

  var Value := FInputResponses.GetValue(Key);
  if Value is TJSONObject then
    Response := TJSONObject(Value);
  Result := Assigned(Response);
end;

function TMCPRequestContext.HasClientCapability(const Path: string): Boolean;
begin
  Result := False;
  var Node: TJSONValue := GetClientCapabilities;
  if not Assigned(Node) then
    Exit;

  for var Segment in Path.Split(['.']) do
  begin
    if not (Node is TJSONObject) then
      Exit;
    Node := TJSONObject(Node).GetValue(Segment);
    if not Assigned(Node) then
      Exit;
  end;
  Result := True;
end;

procedure TMCPRequestContext.RequireClientCapability(const Path: string);
begin
  if HasClientCapability(Path) then
    Exit;

  var Required := TJSONObject.Create;
  var Node := Required;
  for var Segment in Path.Split(['.']) do
  begin
    var Child := TJSONObject.Create;
    Node.AddPair(Segment, Child);
    Node := Child;
  end;
  raise EMCPError.MissingRequiredClientCapability(Required);
end;

function TMCPRequestContext.TryClaimProgress(const Progress: Double; const Completes: Boolean): Boolean;
begin
  const Tick = TThread.GetTickCount64;
  TMonitor.Enter(FProgressLock);
  try
    if FProgressSent then
    begin
      const Stale = (Progress <= FLastProgress);
      const TooSoon = ((Tick - FLastProgressTick < PROGRESS_MIN_INTERVAL_MS) and not Completes);
      if Stale or TooSoon then
        Exit(False);
    end;
    FProgressSent := True;
    FLastProgress := Progress;
    FLastProgressTick := Tick;
    Result := True;
  finally
    TMonitor.Exit(FProgressLock);
  end;
end;

function TMCPRequestContext.IsCancelled: Boolean;
begin
  Result := AtomicCmpExchange(FCancelled, 0, 0) <> 0;
end;

procedure TMCPRequestContext.CheckCancelled;
begin
  if IsCancelled then
    raise EMCPRequestCancelled.CreateFmt('Request %s was cancelled by the client', [FRequestId.AsText]);
end;

procedure TMCPRequestContext.Cancel;
begin
  AtomicExchange(FCancelled, 1);
end;

function TMCPRequestContext.HasProgressToken: Boolean;
begin
  var Token := GetProgressToken;
  if not Assigned(Token) then
    Exit(False);
  if Token is TJSONNumber then
    Exit(Frac(TJSONNumber(Token).AsDouble) = 0);
  Result := Token is TJSONString;
end;

procedure TMCPRequestContext.ReportProgress(const Progress, Total: Double; const Message: string);
const
  JSON_RPC_VERSION = '2.0';
begin
  if not Assigned(FSink) or not HasProgressToken or IsCancelled then
    Exit;

  const Completes = ((Total >= 0) and (Progress >= Total));
  if not TryClaimProgress(Progress, Completes) then
    Exit;

  var Notification := TJSONObject.Create;
  try
    Notification.AddPair('jsonrpc', JSON_RPC_VERSION);
    Notification.AddPair('method', MCP_METHOD_NOTIFICATIONS_PROGRESS);
    var Params := TJSONObject.Create;
    Notification.AddPair('params', Params);
    Params.AddPair(MCP_META_PROGRESS_TOKEN, TJSONValue(GetProgressToken.Clone));
    Params.AddPair('progress', TJSONNumber.Create(Progress));
    if Total >= 0 then
      Params.AddPair('total', TJSONNumber.Create(Total));
    if Message <> '' then
      Params.AddPair('message', Message);
    FSink.Send(Notification.ToJSON);
  finally
    Notification.Free;
  end;
end;

procedure TMCPRequestContext.Log(const Level, Text: string; const Logger: string);
begin
  LogJson(Level, TJSONString.Create(Text), Logger);
end;

procedure TMCPRequestContext.LogJson(const Level: string; const Data: TJSONValue; const Logger: string);
const
  JSON_RPC_VERSION = '2.0';
begin
  var Threshold := GetLogLevel;
  var Wanted := Assigned(FSink) and (Threshold <> '') and not IsCancelled
    and (TMCPLogLevel.Rank(Level) >= TMCPLogLevel.Rank(Threshold));
  if not Wanted then
  begin
    Data.Free;
    Exit;
  end;

  var Notification := TJSONObject.Create;
  try
    Notification.AddPair('jsonrpc', JSON_RPC_VERSION);
    Notification.AddPair('method', MCP_METHOD_NOTIFICATIONS_MESSAGE);
    var Params := TJSONObject.Create;
    Notification.AddPair('params', Params);
    Params.AddPair('level', Level);
    if Logger <> '' then
      Params.AddPair('logger', Logger);
    Params.AddPair('data', Data);
    FSink.Send(Notification.ToJSON);
  finally
    Notification.Free;
  end;
end;

class function TMCPRequestContext.Current: IMCPRequestContext;
begin
  Result := IMCPRequestContext(CurrentContextPointer);
end;

class function TMCPRequestContext.SetCurrent(const Value: IMCPRequestContext): IMCPRequestContext;
begin
  Result := IMCPRequestContext(CurrentContextPointer);
  if Assigned(CurrentContextPointer) then
    IMCPRequestContext(CurrentContextPointer)._Release;

  CurrentContextPointer := Pointer(Value);
  if Assigned(Value) then
    Value._AddRef;
end;

end.
