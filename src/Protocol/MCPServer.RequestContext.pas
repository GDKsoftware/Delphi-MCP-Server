unit MCPServer.RequestContext;

interface

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
  MCPServer.Types;

const
  /// Progress notifications for one request are sent at most this often,
  /// except for the one that reaches the total.
  PROGRESS_MIN_INTERVAL_MS = 50;

type
  /// What the transport knows about a request before the processor sees it.
  TMCPTransportHints = record
    /// True when the transport carries HTTP headers (Streamable HTTP).
    HasHeaderLayer: Boolean;
    HasProtocolVersionHeader: Boolean;
    ProtocolVersionHeader: string;
    HasMethodHeader: Boolean;
    MethodHeader: string;
    HasNameHeader: Boolean;
    NameHeader: string;
    RemoteAddress: string;
    /// Per-process legacy state (stdio); nil for stateless transports.
    LegacySession: TMCPLegacySession;
    /// Channel for request-scoped notifications (progress); nil when the
    /// transport cannot deliver them before the response.
    Sink: IMCPMessageSink;
    /// In-flight bookkeeping for notifications/cancelled; nil when the
    /// transport signals cancellation another way.
    Tracker: IMCPRequestTracker;

    /// No headers, no session: the plain JSON-RPC layer.
    class function None: TMCPTransportHints; static;
    /// stdio: no headers, one session slot per process.
    class function ForStdio(const Session: TMCPLegacySession): TMCPTransportHints; overload; static;
    /// stdio with a channel for progress notifications and cancellation.
    class function ForStdio(const Session: TMCPLegacySession; const Sink: IMCPMessageSink;
      const Tracker: IMCPRequestTracker): TMCPTransportHints; overload; static;
    /// HTTP: the MCP-Protocol-Version header, empty and HasHeader False when absent.
    class function ForHttp(const HasVersionHeader: Boolean; const VersionHeader: string): TMCPTransportHints; static;
  end;

  /// Default IMCPRequestContext implementation and the thread-local Current.
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
    FCancelled: Integer;
    FProgressSent: Boolean;
    FLastProgress: Double;
    FLastProgressTick: UInt64;
    function MetaObject(const Key: string): TJSONObject;
  public
    /// Meta is cloned; the context owns its copy. Sink is where progress
    /// notifications go; nil disables them.
    constructor Create(AEra: TMCPProtocolEra; const AProtocolVersion, AMethod: string;
      const ARequestId: TMCPRequestId; const AMeta: TJSONObject;
      const ALegacySession: TMCPLegacySession; const AManagerRegistry: IMCPManagerRegistry;
      const ASink: IMCPMessageSink = nil);
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
    function HasClientCapability(const Path: string): Boolean;
    procedure RequireClientCapability(const Path: string);
    function IsCancelled: Boolean;
    procedure CheckCancelled;
    procedure Cancel;
    function HasProgressToken: Boolean;
    procedure ReportProgress(const Progress: Double; const Total: Double = -1; const Message: string = '');

    /// The context of the request the calling thread is serving, or nil.
    class function Current: IMCPRequestContext;
    /// Set by the processor around a handler call; nil clears it.
    class procedure SetCurrent(const Value: IMCPRequestContext);
  end;

implementation

uses
  MCPServer.Errors;

threadvar
  // Raw pointer with manual reference counting: a managed threadvar is not
  // finalised when a thread ends.
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

constructor TMCPRequestContext.Create(AEra: TMCPProtocolEra; const AProtocolVersion, AMethod: string;
  const ARequestId: TMCPRequestId; const AMeta: TJSONObject; const ALegacySession: TMCPLegacySession;
  const AManagerRegistry: IMCPManagerRegistry; const ASink: IMCPMessageSink);
begin
  inherited Create;
  FEra := AEra;
  FProtocolVersion := AProtocolVersion;
  FMethod := AMethod;
  FRequestId := ARequestId;
  if Assigned(AMeta) then
    FMeta := TJSONObject(AMeta.Clone);
  FLegacySession := ALegacySession;
  FManagerRegistry := AManagerRegistry;
  FSink := ASink;
end;

destructor TMCPRequestContext.Destroy;
begin
  FMeta.Free;
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
  if Value is TJSONString then
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

  // Rebuild the dotted path as nested objects: 'elicitation.form' becomes
  // {"elicitation": {"form": {}}}.
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

function TMCPRequestContext.IsCancelled: Boolean;
begin
  Result := AtomicCmpExchange(FCancelled, 0, 0) <> 0;
end;

procedure TMCPRequestContext.CheckCancelled;
begin
  if IsCancelled then
    raise EMCPRequestCancelled.Create('Request ' + FRequestId.AsText + ' was cancelled by the client');
end;

procedure TMCPRequestContext.Cancel;
begin
  AtomicExchange(FCancelled, 1);
end;

function TMCPRequestContext.HasProgressToken: Boolean;
begin
  var Token := GetProgressToken;
  // A whole-valued number or a string; TJSONNumber must be checked first
  // since it descends from TJSONString.
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
  // Nothing to deliver without a token or a channel, and nothing more for a
  // request the client cancelled.
  if not Assigned(FSink) or not HasProgressToken or IsCancelled then
    Exit;

  var Completes := (Total >= 0) and (Progress >= Total);
  var Tick := TThread.GetTickCount64;
  if FProgressSent then
  begin
    if Progress <= FLastProgress then
      Exit;
    if (Tick - FLastProgressTick < PROGRESS_MIN_INTERVAL_MS) and not Completes then
      Exit;
  end;
  FProgressSent := True;
  FLastProgress := Progress;
  FLastProgressTick := Tick;

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

class function TMCPRequestContext.Current: IMCPRequestContext;
begin
  Result := IMCPRequestContext(CurrentContextPointer);
end;

class procedure TMCPRequestContext.SetCurrent(const Value: IMCPRequestContext);
begin
  if Assigned(CurrentContextPointer) then
    IMCPRequestContext(CurrentContextPointer)._Release;

  CurrentContextPointer := Pointer(Value);
  if Assigned(Value) then
    Value._AddRef;
end;

end.
