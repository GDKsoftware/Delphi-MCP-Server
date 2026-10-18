unit MCPServer.StdioTransport;

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.JSON,
  System.Generics.Collections,
  MCPServer.Types,
  MCPServer.Settings,
  MCPServer.RequestContext,
  MCPServer.JsonRpcProcessor,
  MCPServer.StdioChannel,
  MCPServer.Logger;

type
  TMCPStdioRequestTracker = class(TInterfacedObject, IMCPRequestTracker)
  strict private
    type
      TEntry = record
        RequestId: TMCPRequestId;
        Context: IMCPRequestContext;
        IsReserved: Boolean;
        Cancelled: Boolean;
        CancelledByClient: Boolean;
        Answered: Boolean;
      end;
    var
      FLock: TCriticalSection;
      FEntries: TDictionary<string, TEntry>;
    class function KeyOf(const RequestId: TMCPRequestId): string; static;
  public
    constructor Create;
    destructor Destroy; override;
    function Reserve(const RequestId: TMCPRequestId): Boolean;
    procedure Release(const RequestId: TMCPRequestId);
    procedure Track(const Context: IMCPRequestContext);
    procedure Untrack(const Context: IMCPRequestContext);
    function TryCancel(const RequestId: TMCPRequestId; const Reason: string): Boolean;
    function CancelAll(const Reason: string): Integer;
    function TryClaimAnswer(const RequestId: TMCPRequestId): Boolean;
    function WasCancelledByClient(const RequestId: TMCPRequestId): Boolean;
    function ClaimUnanswered: TArray<TMCPRequestId>;
  end;

  TMCPStdioTransport = class
  public
    const DEFAULT_SHUTDOWN_DRAIN_MS = TMCPSettings.DEFAULT_STDIO_SHUTDOWN_DRAIN_MS;
    const SHUTDOWN_CANCEL_GRACE_MS = 500;
    const QUEUE_DEPTH = 1024;
    const LISTENER_POLL_MS = 10;
    const QUEUE_PUSH_TIMEOUT_MS = 1000;
  strict private
    FManagerRegistry: IMCPManagerRegistry;
    FCoreManager: IMCPCapabilityManager;
    FJsonRpcProcessor: TMCPJsonRpcProcessor;
    FLegacySession: TMCPLegacySession;
    FTracker: TMCPStdioRequestTracker;
    FTrackerIntf: IMCPRequestTracker;
    FWriter: IMCPMessageSink;
    FQueue: TThreadedQueue<TJSONValue>;
    FWorkersDone: TCountdownEvent;
    FShutdownDrainMs: Integer;
    FAborting: Boolean;
    FWorkerStuck: Boolean;
    FListeners: Integer;
    FStartedWorkers: Integer;
    function GetSettings: TMCPSettings;
    procedure SetSettings(const Value: TMCPSettings);
    function Hints: TMCPTransportHints;
    function WorkerCount: Integer;
    procedure SendResponse(const Body: string);
    procedure SendError(const RequestId: TMCPRequestId; Code: Integer; const Message: string);
    procedure ProcessInline(const Message: TJSONValue);
    procedure DispatchLine(const Message: TJSONValue);
    procedure ProcessQueued(const Message: TJSONValue);
    procedure AnswerRequest(const Message: TJSONValue; const RequestId: TMCPRequestId);
    procedure SendAnswer(const RequestId: TMCPRequestId; const Body: string);
    procedure AnswerShuttingDown(const RequestId: TMCPRequestId);
    procedure StartListener(const Message: TJSONValue);
    procedure CloseSubscriptions;
    procedure StartWorkers;
    procedure DrainAndStop;
    procedure StopWorkersWhenIdle;
    function WaitForWorkers(const TimeoutMs: Integer): Boolean;
    procedure AbortOutstandingRequests;
    procedure AnswerUnansweredRequests;
    procedure ReleaseWorkerState;
    procedure ReadLoop(InputStream: TStream);
  private
    procedure WorkerLoop;
  public
    constructor Create(ManagerRegistry: IMCPManagerRegistry; CoreManager: IMCPCapabilityManager);
    destructor Destroy; override;
    procedure Run;
    procedure RunWith(InputStream, OutputStream: TStream);
    property Settings: TMCPSettings read GetSettings write SetSettings;
    property ShutdownDrainMs: Integer read FShutdownDrainMs write FShutdownDrainMs;
  end;

implementation

uses
  System.Math,
  MCPServer.Errors;

const
  REASON_STDIN_CLOSED = 'stdin closed';
  MESSAGE_SHUTTING_DOWN = 'Server is shutting down';


type
  TMCPStdioWorker = class(TThread)
  strict private
    FTransport: TMCPStdioTransport;
  protected
    procedure Execute; override;
  public
    constructor Create(Transport: TMCPStdioTransport);
  end;

{ TMCPStdioWorker }

constructor TMCPStdioWorker.Create(Transport: TMCPStdioTransport);
begin
  inherited Create(False);
  FTransport := Transport;
  FreeOnTerminate := True;
end;

procedure TMCPStdioWorker.Execute;
begin
  FTransport.WorkerLoop;
end;

{ TMCPStdioRequestTracker }

constructor TMCPStdioRequestTracker.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FEntries := TDictionary<string, TEntry>.Create;
end;

destructor TMCPStdioRequestTracker.Destroy;
begin
  FEntries.Free;
  FLock.Free;
  inherited;
end;

class function TMCPStdioRequestTracker.KeyOf(const RequestId: TMCPRequestId): string;
begin
  if RequestId.Kind = TMCPRequestIdKind.Number then
    Result := 'n:' + RequestId.AsText
  else
    Result := 's:' + RequestId.AsText;
end;

function TMCPStdioRequestTracker.Reserve(const RequestId: TMCPRequestId): Boolean;
begin
  var Entry := Default(TEntry);
  Entry.RequestId := RequestId;
  Entry.IsReserved := True;
  FLock.Enter;
  try
    Result := not FEntries.ContainsKey(KeyOf(RequestId));
    if Result then
      FEntries.Add(KeyOf(RequestId), Entry);
  finally
    FLock.Leave;
  end;
end;

procedure TMCPStdioRequestTracker.Release(const RequestId: TMCPRequestId);
begin
  FLock.Enter;
  try
    FEntries.Remove(KeyOf(RequestId));
  finally
    FLock.Leave;
  end;
end;

procedure TMCPStdioRequestTracker.Track(const Context: IMCPRequestContext);
var
  Entry: TEntry;
begin
  var Key := KeyOf(Context.RequestId);
  var CancelNow: Boolean;
  FLock.Enter;
  try
    if not FEntries.TryGetValue(Key, Entry) then
    begin
      Entry := Default(TEntry);
      Entry.RequestId := Context.RequestId;
    end;
    Entry.Context := Context;
    FEntries.AddOrSetValue(Key, Entry);
    CancelNow := Entry.Cancelled;
  finally
    FLock.Leave;
  end;
  if CancelNow then
    Context.Cancel;
end;

procedure TMCPStdioRequestTracker.Untrack(const Context: IMCPRequestContext);
begin
  const Key = KeyOf(Context.RequestId);
  var Entry: TEntry;
  FLock.Enter;
  try
    if not FEntries.TryGetValue(Key, Entry) then
      Exit;

    if not Entry.IsReserved then
    begin
      FEntries.Remove(Key);
      Exit;
    end;

    Entry.Context := nil;
    FEntries[Key] := Entry;
  finally
    FLock.Leave;
  end;
end;

function TMCPStdioRequestTracker.TryCancel(const RequestId: TMCPRequestId; const Reason: string): Boolean;
var
  Entry: TEntry;
begin
  var Context: IMCPRequestContext := nil;
  FLock.Enter;
  try
    Result := FEntries.TryGetValue(KeyOf(RequestId), Entry);
    if Result then
    begin
      Entry.Cancelled := True;
      Entry.CancelledByClient := True;
      FEntries[KeyOf(RequestId)] := Entry;
      Context := Entry.Context;
    end;
  finally
    FLock.Leave;
  end;

  if not Result then
    Exit;
  if Assigned(Context) then
    Context.Cancel;
  const HasReason = (Reason <> '');
  if HasReason then
    TLogger.Info(Format('Request %s cancelled by the client: %s', [RequestId.AsText, Reason]))
  else
    TLogger.Info(Format('Request %s cancelled by the client', [RequestId.AsText]));
end;

function TMCPStdioRequestTracker.CancelAll(const Reason: string): Integer;
begin
  var Contexts := TList<IMCPRequestContext>.Create;
  try
    FLock.Enter;
    try
      Result := Integer(FEntries.Count);
      for var Key in FEntries.Keys.ToArray do
      begin
        var Entry := FEntries[Key];
        Entry.Cancelled := True;
        FEntries[Key] := Entry;
        if Assigned(Entry.Context) then
          Contexts.Add(Entry.Context);
      end;
    finally
      FLock.Leave;
    end;
    for var Context in Contexts do
    begin
      Context.Cancel;
    end;
  finally
    Contexts.Free;
  end;
  if Result > 0 then
    TLogger.Warning(Format('%d request(s) cancelled: %s', [Result, Reason]));
end;

function TMCPStdioRequestTracker.TryClaimAnswer(const RequestId: TMCPRequestId): Boolean;
begin
  const Key = KeyOf(RequestId);
  var Entry: TEntry;
  FLock.Enter;
  try
    if not FEntries.TryGetValue(Key, Entry) then
      Exit(True);

    Result := (not Entry.Answered and not Entry.CancelledByClient);
    Entry.Answered := True;
    FEntries[Key] := Entry;
  finally
    FLock.Leave;
  end;
end;

function TMCPStdioRequestTracker.WasCancelledByClient(const RequestId: TMCPRequestId): Boolean;
begin
  var Entry: TEntry;
  FLock.Enter;
  try
    const IsKnown = FEntries.TryGetValue(KeyOf(RequestId), Entry);
    Result := (IsKnown and Entry.CancelledByClient);
  finally
    FLock.Leave;
  end;
end;

function TMCPStdioRequestTracker.ClaimUnanswered: TArray<TMCPRequestId>;
begin
  Result := nil;
  FLock.Enter;
  try
    for var Key in FEntries.Keys.ToArray do
    begin
      var Entry := FEntries[Key];
      const IsOwedAnAnswer = (not Entry.Answered and not Entry.CancelledByClient);
      if IsOwedAnAnswer then
      begin
        Entry.Answered := True;
        FEntries[Key] := Entry;
        Result := Result + [Entry.RequestId];
      end;
    end;
  finally
    FLock.Leave;
  end;
end;

{ TMCPStdioTransport }

constructor TMCPStdioTransport.Create(ManagerRegistry: IMCPManagerRegistry; CoreManager: IMCPCapabilityManager);
begin
  inherited Create;
  FManagerRegistry := ManagerRegistry;
  FCoreManager := CoreManager;
  FJsonRpcProcessor := TMCPJsonRpcProcessor.Create(ManagerRegistry);
  FLegacySession := TMCPLegacySession.Create;
  FTracker := TMCPStdioRequestTracker.Create;
  FTrackerIntf := FTracker;
  FShutdownDrainMs := Settings.StdioShutdownDrainMs;

  TLogger.UseStdErr := True;
  TLogger.StdoutReserved := True;
end;

destructor TMCPStdioTransport.Destroy;
begin
  if not FWorkerStuck then
  begin
    FJsonRpcProcessor.Free;
    FLegacySession.Free;
    FTrackerIntf := nil;
  end;
  inherited;
end;

function TMCPStdioTransport.GetSettings: TMCPSettings;
begin
  Result := FJsonRpcProcessor.Settings;
end;

procedure TMCPStdioTransport.SetSettings(const Value: TMCPSettings);
begin
  FJsonRpcProcessor.Settings := Value;
  FShutdownDrainMs := Settings.StdioShutdownDrainMs;
end;

function TMCPStdioTransport.Hints: TMCPTransportHints;
begin
  Result := TMCPTransportHints.ForStdio(FLegacySession, FWriter, FTrackerIntf);
end;

function TMCPStdioTransport.WorkerCount: Integer;
begin
  Result := Settings.MaxConcurrentRequests;
  if Result < 1 then
    Result := 1;
end;

procedure TMCPStdioTransport.SendResponse(const Body: string);
begin
  if Body = '' then
    Exit;
  FWriter.Send(Body);
  TLogger.Debug('Sent: ' + TLogger.RedactJson(Body));
end;

procedure TMCPStdioTransport.SendError(const RequestId: TMCPRequestId; Code: Integer; const Message: string);
begin
  var Error := EMCPError.Create(Code, Message);
  try
    SendResponse(FJsonRpcProcessor.BuildErrorResponse(RequestId, Error));
  finally
    Error.Free;
  end;
end;

procedure TMCPStdioTransport.ProcessInline(const Message: TJSONValue);
begin
  SendResponse(FJsonRpcProcessor.ProcessRequestEx(Message, Hints).Body);
end;

procedure TMCPStdioTransport.DispatchLine(const Message: TJSONValue);
begin
  var Queued := False;
  try
    if Message is TJSONObject then
    begin
      var Request := TJSONObject(Message);
      var RequestId := TMCPRequestId.FromJson(Request.GetValue(MCP_KEY_ID));
      var MethodValue := Request.GetValue(MCP_KEY_METHOD);
      var Method := '';
      if MethodValue is TJSONString then
        Method := TJSONString(MethodValue).Value;

      if RequestId.IsPresent and (Method <> '') and (Method <> MCP_METHOD_PING) then
      begin
        if not FTracker.Reserve(RequestId) then
        begin
          SendError(RequestId, JSONRPC_INVALID_REQUEST, Format('Request id %s is still in flight', [RequestId.AsText]));
          Exit;
        end;
        try
          if Method = MCP_METHOD_SUBSCRIPTIONS_LISTEN then
          begin
            StartListener(Message);
            Queued := True;
            Exit;
          end;
          const Accepted = (FQueue.PushItem(Message) = TWaitResult.wrSignaled);
          if not Accepted then
          begin
            FTracker.Release(RequestId);
            SendError(RequestId, JSONRPC_INTERNAL_ERROR, MESSAGE_SHUTTING_DOWN);
            Exit;
          end;
          Queued := True;
          Exit;
        except
          on E: Exception do
          begin
            FTracker.Release(RequestId);
            SendError(RequestId, JSONRPC_INTERNAL_ERROR, Format('Request could not be started: %s', [E.Message]));
            Exit;
          end;
        end;
      end;
    end;

    ProcessInline(Message);
  finally
    if not Queued then
      Message.Free;
  end;
end;

procedure TMCPStdioTransport.ProcessQueued(const Message: TJSONValue);
begin
  const IdValue = TJSONObject(Message).GetValue(MCP_KEY_ID);
  const RequestId = TMCPRequestId.FromJson(IdValue);
  try
    if FAborting then
      AnswerShuttingDown(RequestId)
    else
      AnswerRequest(Message, RequestId);
  finally
    FTracker.Release(RequestId);
    Message.Free;
  end;
end;

procedure TMCPStdioTransport.AnswerRequest(const Message: TJSONValue; const RequestId: TMCPRequestId);
begin
  const Outcome = FJsonRpcProcessor.ProcessRequestEx(Message, Hints);
  const IsClientCancellation = (Outcome.Cancelled and FTracker.WasCancelledByClient(RequestId));

  if not Outcome.Cancelled then
    SendAnswer(RequestId, Outcome.Body)
  else if IsClientCancellation then
    TLogger.Info(Format('No response for cancelled request %s', [RequestId.AsText]))
  else
    AnswerShuttingDown(RequestId);
end;

procedure TMCPStdioTransport.SendAnswer(const RequestId: TMCPRequestId; const Body: string);
begin
  const IsFirstAnswer = FTracker.TryClaimAnswer(RequestId);
  if IsFirstAnswer then
    SendResponse(Body);
end;

procedure TMCPStdioTransport.AnswerShuttingDown(const RequestId: TMCPRequestId);
begin
  const IsFirstAnswer = FTracker.TryClaimAnswer(RequestId);
  if IsFirstAnswer then
    SendError(RequestId, JSONRPC_INTERNAL_ERROR, MESSAGE_SHUTTING_DOWN);
end;

procedure TMCPStdioTransport.StartListener(const Message: TJSONValue);
begin
  AtomicIncrement(FListeners);
  TThread.CreateAnonymousThread(
    procedure
    begin
      try
        try
          ProcessQueued(Message);
        except
          on E: Exception do
            TLogger.Error(Format('Error processing stdio subscription: %s', [E.Message]));
        end;
      finally
        AtomicDecrement(FListeners);
      end;
    end).Start;
end;

procedure TMCPStdioTransport.CloseSubscriptions;
var
  Hub: IMCPSubscriptionHub;
begin
  Supports(FManagerRegistry.GetManagerForMethod(MCP_METHOD_SUBSCRIPTIONS_LISTEN), IMCPSubscriptionHub, Hub);
  var Deadline := TThread.GetTickCount64 + UInt64(FShutdownDrainMs);
  repeat
    if Assigned(Hub) then
      Hub.CloseAll(REASON_STDIN_CLOSED);
    if AtomicCmpExchange(FListeners, 0, 0) = 0 then
      Break;
    Sleep(LISTENER_POLL_MS);
  until TThread.GetTickCount64 >= Deadline;
end;

procedure TMCPStdioTransport.WorkerLoop;
var
  Message: TJSONValue;
begin
  var Queue := FQueue;
  var Done := FWorkersDone;
  try
    while Queue.PopItem(Message) = TWaitResult.wrSignaled do
    begin
      if not Assigned(Message) then
        Break;
      try
        ProcessQueued(Message);
      except
        on E: Exception do
          TLogger.Error('Error processing stdio request: ' + E.Message);
      end;
    end;
  finally
    Done.Signal;
  end;
end;

procedure TMCPStdioTransport.StartWorkers;
begin
  FStartedWorkers := WorkerCount;
  FQueue := TThreadedQueue<TJSONValue>.Create(QUEUE_DEPTH, QUEUE_PUSH_TIMEOUT_MS, INFINITE);
  FWorkersDone := TCountdownEvent.Create(FStartedWorkers);
  for var WorkerNumber := 1 to FStartedWorkers do
  begin
    TMCPStdioWorker.Create(Self);
  end;
  TLogger.Info(Format('STDIO transport started: %d worker thread(s), logging to stderr', [FStartedWorkers]));
end;

procedure TMCPStdioTransport.DrainAndStop;
begin
  StopWorkersWhenIdle;
  const Drained = WaitForWorkers(FShutdownDrainMs);
  CloseSubscriptions;
  if not Drained then
    AbortOutstandingRequests;

  ReleaseWorkerState;
end;

procedure TMCPStdioTransport.StopWorkersWhenIdle;
begin
  for var WorkerNumber := 1 to FStartedWorkers do
  begin
    FQueue.PushItem(nil);
  end;
end;

function TMCPStdioTransport.WaitForWorkers(const TimeoutMs: Integer): Boolean;
begin
  const NonNegativeMs = Max(TimeoutMs, 0);
  const Outcome = FWorkersDone.WaitFor(Cardinal(NonNegativeMs));
  Result := (Outcome = TWaitResult.wrSignaled);
end;

procedure TMCPStdioTransport.AbortOutstandingRequests;
begin
  FAborting := True;
  FTracker.CancelAll(REASON_STDIN_CLOSED);

  const Stopped = WaitForWorkers(SHUTDOWN_CANCEL_GRACE_MS);
  if not Stopped then
    AnswerUnansweredRequests;
end;

procedure TMCPStdioTransport.AnswerUnansweredRequests;
begin
  for var RequestId in FTracker.ClaimUnanswered do
  begin
    SendError(RequestId, JSONRPC_INTERNAL_ERROR, MESSAGE_SHUTTING_DOWN);
  end;
end;

procedure TMCPStdioTransport.ReleaseWorkerState;
begin
  const AllStopped = (FWorkersDone.IsSet and (AtomicCmpExchange(FListeners, 0, 0) = 0));
  if AllStopped then
  begin
    FWorkersDone.Free;
    FQueue.Free;
    FWorkersDone := nil;
    FQueue := nil;
  end
  else
  begin
    FWorkerStuck := True;
    TLogger.Warning('A request handler did not stop; leaving it to the process exit');
  end;
end;

procedure TMCPStdioTransport.ReadLoop(InputStream: TStream);
var
  Line: TMCPLine;
begin
  var Reader := TMCPLineReader.Create(InputStream, Settings.MaxRequestBodyBytes);
  try
    while Reader.TryReadLine(Line) do
    begin
      try
        case Line.Status of
          TMCPLineStatus.TooLong:
            SendError(TMCPRequestId.FromJson(nil), JSONRPC_INVALID_REQUEST,
              Format('Message exceeds %d bytes', [Settings.MaxRequestBodyBytes]));
          TMCPLineStatus.InvalidUtf8:
            SendError(TMCPRequestId.FromJson(nil), JSONRPC_PARSE_ERROR, 'Message is not valid UTF-8');
        else
          if Line.Text.Trim = '' then
            Continue;
          TLogger.Debug('Received: ' + TLogger.RedactJson(Line.Text));
          DispatchLine(TJSONObject.ParseJSONValue(Line.Text));
        end;
      except
        on E: Exception do
          TLogger.Error('Error reading stdio request: ' + E.Message);
      end;
    end;
  finally
    Reader.Free;
  end;
end;

procedure TMCPStdioTransport.RunWith(InputStream, OutputStream: TStream);
begin
  FWriter := TMCPLineWriter.Create(OutputStream);
  try
    StartWorkers;
    try
      ReadLoop(InputStream);
      TLogger.Info('STDIO transport: stdin closed');
    finally
      DrainAndStop;
    end;
  finally
    FWriter := nil;
  end;
  TLogger.Info('STDIO transport stopped');
end;

procedure TMCPStdioTransport.Run;
begin
  var InputStream := StandardInputStream;
  var OutputStream := StandardOutputStream;
  try
    RunWith(InputStream, OutputStream);
  finally
    OutputStream.Free;
    InputStream.Free;
  end;
end;

end.
