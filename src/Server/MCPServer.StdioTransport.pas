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
        function IsOwedAnAnswer: Boolean;
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

  TMCPStdioRequestRunner = class;

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
    FRunner: TMCPStdioRequestRunner;
    FRunnerLifetime: IInterface;
    FTracker: TMCPStdioRequestTracker;
    FShutdownDrainMs: Integer;
    FHasShutdownDrainMs: Boolean;
    function WorkerCount: Integer;
    procedure ReadLoop(const InputStream: TStream);
    procedure DispatchLine(const Message: TJSONValue);
    procedure DrainAndStop;
    procedure CloseSubscriptions(const DrainMs: Integer);
    procedure AbortOutstandingRequests;
    function GetSettings: TMCPSettings;
    procedure SetSettings(const Value: TMCPSettings);
    function GetShutdownDrainMs: Integer;
    procedure SetShutdownDrainMs(const Value: Integer);

  public
    constructor Create(const ManagerRegistry: IMCPManagerRegistry; const CoreManager: IMCPCapabilityManager);
    procedure Run;
    procedure RunWith(const InputStream, OutputStream: TStream);
    property Settings: TMCPSettings read GetSettings write SetSettings;
    property ShutdownDrainMs: Integer read GetShutdownDrainMs write SetShutdownDrainMs;
  end;

  TMCPStdioRequestRunner = class(TInterfacedObject)
  strict private
    FJsonRpcProcessor: TMCPJsonRpcProcessor;
    FLegacySession: TMCPLegacySession;
    FTracker: TMCPStdioRequestTracker;
    FTrackerLifetime: IMCPRequestTracker;
    FWriter: TMCPLineWriter;
    FWriterLifetime: IMCPMessageSink;
    FQueue: TThreadedQueue<TJSONValue>;
    FWorkersDone: TCountdownEvent;
    FStartedWorkers: Integer;
    FListeners: Integer;
    FAborting: Boolean;
    procedure WorkerLoop;
    procedure RunListener(const Message: TJSONValue);
    procedure ProcessQueued(const Message: TJSONValue);
    procedure AnswerRequest(const Message: TJSONValue; const RequestId: TMCPRequestId);
    procedure SendAnswerOnce(const RequestId: TMCPRequestId; const Body: string);
    procedure SendErrorOnce(const RequestId: TMCPRequestId; const Message: string);
    function TryClaimAnswer(const RequestId: TMCPRequestId): Boolean;
    function Hints: TMCPTransportHints;
    procedure SendResponse(const Body: string);
    function GetSettings: TMCPSettings;
    procedure SetSettings(const Value: TMCPSettings);

  public
    constructor Create(const ManagerRegistry: IMCPManagerRegistry);
    destructor Destroy; override;

    procedure AttachOutput(const OutputStream: TStream);
    procedure DetachOutput;
    procedure StartWorkers(const Count: Integer);
    function TryEnqueue(const Message: TJSONValue): Boolean;
    procedure StartListener(const Message: TJSONValue);
    procedure ProcessInline(const Message: TJSONValue);
    procedure SendError(const RequestId: TMCPRequestId; const Code: Integer; const Message: string);
    procedure StopWorkersWhenIdle;
    function WaitForWorkers(const TimeoutMs: Integer): Boolean;
    function HasRunningListeners: Boolean;
    procedure AbortRequests(const Reason: string);
    function WaitUntilStopped(const TimeoutMs: Integer): Boolean;
    procedure AnswerUnansweredRequests;
    procedure ReleaseWorkerState;

    property Tracker: TMCPStdioRequestTracker read FTracker;
    property Settings: TMCPSettings read GetSettings write SetSettings;
  end;

implementation

uses
  System.Math,
  MCPServer.Errors;

const
  REASON_STDIN_CLOSED       = 'stdin closed';
  MESSAGE_SHUTTING_DOWN     = 'Server is shutting down';
  MESSAGE_REQUEST_CANCELLED = 'Request was cancelled';
  MESSAGE_ANSWER_DROPPED    = 'Request %s was answered or cancelled already, so this answer is dropped';


type
  TMCPStdioThread = class(TThread)
  strict private
    FRunnerLifetime: IInterface;
    FWork: TProc;

  protected
    procedure Execute; override;

  public
    constructor Create(const RunnerLifetime: IInterface; const Work: TProc);
  end;

{ TMCPStdioThread }

constructor TMCPStdioThread.Create(const RunnerLifetime: IInterface; const Work: TProc);
begin
  inherited Create(False);
  FRunnerLifetime := RunnerLifetime;
  FWork           := Work;
  FreeOnTerminate := True;
end;

procedure TMCPStdioThread.Execute;
begin
  FWork();
end;

{ TMCPStdioRequestTracker.TEntry }

function TMCPStdioRequestTracker.TEntry.IsOwedAnAnswer: Boolean;
begin
  Result := (not Answered and not CancelledByClient);
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
  Entry.RequestId  := RequestId;
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
      Entry           := Default(TEntry);
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

    Result := Entry.IsOwedAnAnswer;
    Entry.Answered := True;
    FEntries[Key]  := Entry;
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
    const Keys = FEntries.Keys;
    for var Key in Keys.ToArray do
    begin
      var Entry := FEntries[Key];
      if Entry.IsOwedAnAnswer then
      begin
        Entry.Answered := True;
        FEntries[Key]  := Entry;
        Result := Result + [Entry.RequestId];
      end;
    end;
  finally
    FLock.Leave;
  end;
end;

{ TMCPStdioTransport }

constructor TMCPStdioTransport.Create(const ManagerRegistry: IMCPManagerRegistry; const CoreManager: IMCPCapabilityManager);
begin
  inherited Create;
  FManagerRegistry := ManagerRegistry;
  FCoreManager     := CoreManager;
  FRunner          := TMCPStdioRequestRunner.Create(ManagerRegistry);
  FRunnerLifetime  := FRunner;
  FTracker         := FRunner.Tracker;

  TLogger.UseStdErr := True;
  TLogger.StdoutReserved := True;
end;

procedure TMCPStdioTransport.Run;
begin
  const InputStream = StandardInputStream;
  try
    const OutputStream = StandardOutputStream;
    try
      RunWith(InputStream, OutputStream);
    finally
      OutputStream.Free;
    end;
  finally
    InputStream.Free;
  end;
end;

procedure TMCPStdioTransport.RunWith(const InputStream, OutputStream: TStream);
begin
  FRunner.AttachOutput(OutputStream);
  try
    FRunner.StartWorkers(WorkerCount);
    try
      ReadLoop(InputStream);
      TLogger.Info('STDIO transport: stdin closed');
    finally
      DrainAndStop;
    end;
  finally
    FRunner.DetachOutput;
  end;
  TLogger.Info('STDIO transport stopped');
end;

function TMCPStdioTransport.WorkerCount: Integer;
begin
  Result := Settings.MaxConcurrentRequests;
  if Result < 1 then
    Result := 1;
end;

procedure TMCPStdioTransport.ReadLoop(const InputStream: TStream);
var
  Line: TMCPLine;
begin
  const Reader = TMCPLineReader.Create(InputStream, Settings.MaxRequestBodyBytes);
  try
    while Reader.TryReadLine(Line) do
    begin
      try
        case Line.Status of
          TMCPLineStatus.TooLong:
            begin
              const NoId = TMCPRequestId.FromJson(nil);
              const TooLong = Format('Message exceeds %d bytes', [Settings.MaxRequestBodyBytes]);
              FRunner.SendError(NoId, JSONRPC_INVALID_REQUEST, TooLong);
            end;
          TMCPLineStatus.InvalidUtf8:
            begin
              const NoId = TMCPRequestId.FromJson(nil);
              FRunner.SendError(NoId, JSONRPC_PARSE_ERROR, 'Message is not valid UTF-8');
            end;
        else
          const Trimmed = Line.Text.Trim;
          if Trimmed.IsEmpty then
            Continue;

          const Redacted = TLogger.RedactJson(Line.Text);
          TLogger.Debug('Received: %s', [Redacted]);
          const Message = TJSONObject.ParseJSONValue(Line.Text);
          DispatchLine(Message);
        end;
      except
        on E: Exception do
          TLogger.Error('Error reading stdio request: %s', [E.Message]);
      end;
    end;
  finally
    Reader.Free;
  end;
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
          const InFlight = Format('Request id %s is still in flight', [RequestId.AsText]);
          FRunner.SendError(RequestId, JSONRPC_INVALID_REQUEST, InFlight);
          Exit;
        end;
        try
          if Method = MCP_METHOD_SUBSCRIPTIONS_LISTEN then
          begin
            FRunner.StartListener(Message);
            Queued := True;
            Exit;
          end;
          const Accepted = FRunner.TryEnqueue(Message);
          if not Accepted then
          begin
            FTracker.Release(RequestId);
            FRunner.SendError(RequestId, JSONRPC_INTERNAL_ERROR, MESSAGE_SHUTTING_DOWN);
            Exit;
          end;
          Queued := True;
          Exit;
        except
          on E: Exception do
          begin
            FTracker.Release(RequestId);
            const NotStarted = Format('Request could not be started: %s', [E.Message]);
            FRunner.SendError(RequestId, JSONRPC_INTERNAL_ERROR, NotStarted);
            Exit;
          end;
        end;
      end;
    end;

    FRunner.ProcessInline(Message);
  finally
    if not Queued then
      Message.Free;
  end;
end;

procedure TMCPStdioTransport.DrainAndStop;
begin
  const DrainMs = Max(ShutdownDrainMs, 0);

  FRunner.StopWorkersWhenIdle;
  const WorkersDrained = FRunner.WaitForWorkers(DrainMs);
  CloseSubscriptions(DrainMs);

  const IsEverythingAnswered = (WorkersDrained and not FRunner.HasRunningListeners);
  if not IsEverythingAnswered then
    AbortOutstandingRequests;

  FRunner.ReleaseWorkerState;
end;

procedure TMCPStdioTransport.CloseSubscriptions(const DrainMs: Integer);
var
  Hub: IMCPSubscriptionHub;
begin
  Supports(FManagerRegistry.GetManagerForMethod(MCP_METHOD_SUBSCRIPTIONS_LISTEN), IMCPSubscriptionHub, Hub);
  const Deadline = TThread.GetTickCount64 + UInt64(DrainMs);
  repeat
    if Assigned(Hub) then
      Hub.CloseAll(REASON_STDIN_CLOSED);
    if not FRunner.HasRunningListeners then
      Break;
    Sleep(LISTENER_POLL_MS);
  until TThread.GetTickCount64 >= Deadline;
end;

procedure TMCPStdioTransport.AbortOutstandingRequests;
begin
  FRunner.AbortRequests(REASON_STDIN_CLOSED);

  const HasStopped = FRunner.WaitUntilStopped(SHUTDOWN_CANCEL_GRACE_MS);
  if not HasStopped then
    FRunner.AnswerUnansweredRequests;
end;

function TMCPStdioTransport.GetSettings: TMCPSettings;
begin
  Result := FRunner.Settings;
end;

procedure TMCPStdioTransport.SetSettings(const Value: TMCPSettings);
begin
  FRunner.Settings := Value;
end;

function TMCPStdioTransport.GetShutdownDrainMs: Integer;
begin
  if FHasShutdownDrainMs then
    Exit(FShutdownDrainMs);

  Result := Settings.StdioShutdownDrainMs;
end;

procedure TMCPStdioTransport.SetShutdownDrainMs(const Value: Integer);
begin
  FShutdownDrainMs    := Value;
  FHasShutdownDrainMs := True;
end;

{ TMCPStdioRequestRunner }

constructor TMCPStdioRequestRunner.Create(const ManagerRegistry: IMCPManagerRegistry);
begin
  inherited Create;
  FJsonRpcProcessor := TMCPJsonRpcProcessor.Create(ManagerRegistry);
  FLegacySession    := TMCPLegacySession.Create;
  FTracker          := TMCPStdioRequestTracker.Create;
  FTrackerLifetime  := FTracker;
end;

destructor TMCPStdioRequestRunner.Destroy;
begin
  FWorkersDone.Free;
  FQueue.Free;
  FJsonRpcProcessor.Free;
  FLegacySession.Free;
  FTrackerLifetime := nil;
  FWriterLifetime  := nil;
  inherited;
end;

procedure TMCPStdioRequestRunner.AttachOutput(const OutputStream: TStream);
begin
  FWriter         := TMCPLineWriter.Create(OutputStream);
  FWriterLifetime := FWriter;
end;

procedure TMCPStdioRequestRunner.DetachOutput;
begin
  FWriter.Close;
end;

procedure TMCPStdioRequestRunner.StartWorkers(const Count: Integer);
begin
  FStartedWorkers := Count;
  FQueue := TThreadedQueue<TJSONValue>.Create(TMCPStdioTransport.QUEUE_DEPTH,
                                              TMCPStdioTransport.QUEUE_PUSH_TIMEOUT_MS,
                                              INFINITE);
  FWorkersDone := TCountdownEvent.Create(Count);
  for var WorkerNumber := 1 to Count do
  begin
    TMCPStdioThread.Create(Self, WorkerLoop);
  end;
  TLogger.Info('STDIO transport started: %d worker thread(s), logging to stderr', [Count]);
end;

function TMCPStdioRequestRunner.TryEnqueue(const Message: TJSONValue): Boolean;
begin
  const Outcome = FQueue.PushItem(Message);
  Result := (Outcome = TWaitResult.wrSignaled);
end;

procedure TMCPStdioRequestRunner.StartListener(const Message: TJSONValue);
begin
  AtomicIncrement(FListeners);
  TMCPStdioThread.Create(Self,
    procedure
    begin
      RunListener(Message);
    end);
end;

procedure TMCPStdioRequestRunner.ProcessInline(const Message: TJSONValue);
begin
  const RequestHints = Hints;
  const Outcome = FJsonRpcProcessor.ProcessRequestEx(Message, RequestHints);
  SendResponse(Outcome.Body);
end;

procedure TMCPStdioRequestRunner.SendError(const RequestId: TMCPRequestId; const Code: Integer; const Message: string);
begin
  const Error = EMCPError.Create(Code, Message);
  try
    const Body = FJsonRpcProcessor.BuildErrorResponse(RequestId, Error);
    SendResponse(Body);
  finally
    Error.Free;
  end;
end;

procedure TMCPStdioRequestRunner.StopWorkersWhenIdle;
begin
  for var WorkerNumber := 1 to FStartedWorkers do
  begin
    FQueue.PushItem(nil);
  end;
end;

function TMCPStdioRequestRunner.WaitForWorkers(const TimeoutMs: Integer): Boolean;
begin
  const Outcome = FWorkersDone.WaitFor(Cardinal(TimeoutMs));
  Result := (Outcome = TWaitResult.wrSignaled);
end;

function TMCPStdioRequestRunner.HasRunningListeners: Boolean;
begin
  Result := (AtomicCmpExchange(FListeners, 0, 0) <> 0);
end;

procedure TMCPStdioRequestRunner.AbortRequests(const Reason: string);
begin
  FAborting := True;
  FTracker.CancelAll(Reason);
end;

function TMCPStdioRequestRunner.WaitUntilStopped(const TimeoutMs: Integer): Boolean;
begin
  const Deadline = TThread.GetTickCount64 + UInt64(TimeoutMs);
  const WorkersStopped = WaitForWorkers(TimeoutMs);
  while HasRunningListeners and (TThread.GetTickCount64 < Deadline) do
  begin
    Sleep(TMCPStdioTransport.LISTENER_POLL_MS);
  end;

  Result := (WorkersStopped and not HasRunningListeners);
end;

procedure TMCPStdioRequestRunner.AnswerUnansweredRequests;
begin
  const Unanswered = FTracker.ClaimUnanswered;
  for var RequestId in Unanswered do
  begin
    SendError(RequestId, JSONRPC_INTERNAL_ERROR, MESSAGE_SHUTTING_DOWN);
  end;
end;

procedure TMCPStdioRequestRunner.ReleaseWorkerState;
begin
  const AllStopped = (FWorkersDone.IsSet and not HasRunningListeners);
  if not AllStopped then
  begin
    TLogger.Warning('A request handler did not stop; it is answered and its late result will be dropped');
    Exit;
  end;

  FWorkersDone.Free;
  FQueue.Free;
  FWorkersDone := nil;
  FQueue       := nil;
end;

procedure TMCPStdioRequestRunner.WorkerLoop;
var
  Message: TJSONValue;
begin
  const Queue = FQueue;
  const Done = FWorkersDone;
  try
    while Queue.PopItem(Message) = TWaitResult.wrSignaled do
    begin
      if not Assigned(Message) then
        Break;
      try
        ProcessQueued(Message);
      except
        on E: Exception do
          TLogger.Error('Error processing stdio request: %s', [E.Message]);
      end;
    end;
  finally
    Done.Signal;
  end;
end;

procedure TMCPStdioRequestRunner.RunListener(const Message: TJSONValue);
begin
  try
    try
      ProcessQueued(Message);
    except
      on E: Exception do
        TLogger.Error('Error processing stdio subscription: %s', [E.Message]);
    end;
  finally
    AtomicDecrement(FListeners);
  end;
end;

procedure TMCPStdioRequestRunner.ProcessQueued(const Message: TJSONValue);
begin
  const IdValue = TJSONObject(Message).GetValue(MCP_KEY_ID);
  const RequestId = TMCPRequestId.FromJson(IdValue);
  try
    if FAborting then
      SendErrorOnce(RequestId, MESSAGE_SHUTTING_DOWN)
    else
      AnswerRequest(Message, RequestId);
  finally
    FTracker.Release(RequestId);
    Message.Free;
  end;
end;

procedure TMCPStdioRequestRunner.AnswerRequest(const Message: TJSONValue; const RequestId: TMCPRequestId);
begin
  const RequestHints = Hints;
  const Outcome = FJsonRpcProcessor.ProcessRequestEx(Message, RequestHints);
  if not Outcome.Cancelled then
  begin
    SendAnswerOnce(RequestId, Outcome.Body);
    Exit;
  end;

  const IsClientCancellation = FTracker.WasCancelledByClient(RequestId);
  if IsClientCancellation then
    TLogger.Info('No response for cancelled request %s', [RequestId.AsText])
  else if FAborting then
    SendErrorOnce(RequestId, MESSAGE_SHUTTING_DOWN)
  else
    SendErrorOnce(RequestId, MESSAGE_REQUEST_CANCELLED);
end;

procedure TMCPStdioRequestRunner.SendAnswerOnce(const RequestId: TMCPRequestId; const Body: string);
begin
  const IsFirstAnswer = TryClaimAnswer(RequestId);
  if IsFirstAnswer then
    SendResponse(Body);
end;

procedure TMCPStdioRequestRunner.SendErrorOnce(const RequestId: TMCPRequestId; const Message: string);
begin
  const IsFirstAnswer = TryClaimAnswer(RequestId);
  if IsFirstAnswer then
    SendError(RequestId, JSONRPC_INTERNAL_ERROR, Message);
end;

function TMCPStdioRequestRunner.TryClaimAnswer(const RequestId: TMCPRequestId): Boolean;
begin
  Result := FTracker.TryClaimAnswer(RequestId);
  if not Result then
    TLogger.Info(MESSAGE_ANSWER_DROPPED, [RequestId.AsText]);
end;

function TMCPStdioRequestRunner.Hints: TMCPTransportHints;
begin
  Result := TMCPTransportHints.ForStdio(FLegacySession, FWriterLifetime, FTrackerLifetime);
end;

procedure TMCPStdioRequestRunner.SendResponse(const Body: string);
begin
  if Body.IsEmpty then
    Exit;

  FWriter.Send(Body);
  const Redacted = TLogger.RedactJson(Body);
  TLogger.Debug('Sent: %s', [Redacted]);
end;

function TMCPStdioRequestRunner.GetSettings: TMCPSettings;
begin
  Result := FJsonRpcProcessor.Settings;
end;

procedure TMCPStdioRequestRunner.SetSettings(const Value: TMCPSettings);
begin
  FJsonRpcProcessor.Settings := Value;
end;

end.
