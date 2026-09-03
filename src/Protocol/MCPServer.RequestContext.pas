unit MCPServer.RequestContext;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Types;

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

    /// No headers, no session: the plain JSON-RPC layer.
    class function None: TMCPTransportHints; static;
    /// stdio: no headers, one session slot per process.
    class function ForStdio(const Session: TMCPLegacySession): TMCPTransportHints; static;
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
    function MetaObject(const Key: string): TJSONObject;
  public
    /// Meta is cloned; the context owns its copy.
    constructor Create(AEra: TMCPProtocolEra; const AProtocolVersion, AMethod: string;
      const ARequestId: TMCPRequestId; const AMeta: TJSONObject;
      const ALegacySession: TMCPLegacySession; const AManagerRegistry: IMCPManagerRegistry);
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
  const AManagerRegistry: IMCPManagerRegistry);
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
  Result := False;
end;

procedure TMCPRequestContext.CheckCancelled;
begin
  // Cancellation is not wired to a transport yet; nothing to check.
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
