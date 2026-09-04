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
        Context: IMCPRequestContext;
        Cancelled: Boolean;
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
  end;

  TMCPStdioTransport = class
  public
    const DEFAULT_SHUTDOWN_DRAIN_MS = 2000;
    const SHUTDOWN_CANCEL_GRACE_MS = 500;
    const QUEUE_DEPTH = 1024;
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
    FWorkerStuck: Boolean;
    function GetSettings: TMCPSettings;
    procedure SetSettings(const Value: TMCPSettings);
    function Hints: TMCPTransportHints;
    function WorkerCount: Integer;
    procedure SendResponse(const Body: string);
    procedure SendError(const RequestId: TMCPRequestId; Code: Integer; const Message: string);
    procedure ProcessInline(const Message: TJSONValue);
    procedure DispatchLine(const Message: TJSONValue);
    procedure ProcessQueued(const Message: TJSONValue);
    procedure StartWorkers;
    procedure DrainAndStop;
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
  MCPServer.Errors;

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
  FLock.Enter;
  try
    Result := not FEntries.ContainsKey(KeyOf(RequestId));
    if Result then
      FEntries.Add(KeyOf(RequestId), Default(TEntry));
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
      Entry := Default(TEntry);
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
  Release(Context.RequestId);
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
  if Reason <> '' then
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
      Context.Cancel;
  finally
    Contexts.Free;
  end;
  if Result > 0 then
    TLogger.Warning(Format('%d request(s) cancelled: %s', [Result, Reason]));
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
  FShutdownDrainMs := DEFAULT_SHUTDOWN_DRAIN_MS;

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
      var RequestId := TMCPRequestId.FromJson(Request.GetValue('id'));
      var MethodValue := Request.GetValue('method');
      var Method := '';
      if MethodValue is TJSONString then
        Method := TJSONString(MethodValue).Value;

      if RequestId.IsPresent and (Method <> '') and (Method <> 'ping') then
      begin
        if not FTracker.Reserve(RequestId) then
        begin
          SendError(RequestId, JSONRPC_INVALID_REQUEST, 'Request id ' + RequestId.AsText + ' is still in flight');
          Exit;
        end;
        if FQueue.PushItem(Message) <> TWaitResult.wrSignaled then
        begin
          FTracker.Release(RequestId);
          SendError(RequestId, JSONRPC_INTERNAL_ERROR, 'Server is shutting down');
          Exit;
        end;
        Queued := True;
        Exit;
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
  var RequestId := TMCPRequestId.FromJson(TJSONObject(Message).GetValue('id'));
  try
    var Outcome := FJsonRpcProcessor.ProcessRequestEx(Message, Hints);
    if Outcome.Cancelled then
      TLogger.Info('No response for cancelled request ' + RequestId.AsText)
    else
      SendResponse(Outcome.Body);
  finally
    FTracker.Release(RequestId);
    Message.Free;
  end;
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
  var Count := WorkerCount;
  FQueue := TThreadedQueue<TJSONValue>.Create(QUEUE_DEPTH, INFINITE, INFINITE);
  FWorkersDone := TCountdownEvent.Create(Count);
  for var I := 1 to Count do
    TMCPStdioWorker.Create(Self);
  TLogger.Info(Format('STDIO transport started: %d worker thread(s), logging to stderr', [Count]));
end;

procedure TMCPStdioTransport.DrainAndStop;
begin
  for var I := 1 to WorkerCount do
    FQueue.PushItem(nil);

  if FWorkersDone.WaitFor(Cardinal(FShutdownDrainMs)) <> TWaitResult.wrSignaled then
  begin
    FTracker.CancelAll('stdin closed');
    FWorkersDone.WaitFor(SHUTDOWN_CANCEL_GRACE_MS);
  end;

  if FWorkersDone.IsSet then
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
  Line: string;
  Status: TMCPLineStatus;
begin
  var Reader := TMCPLineReader.Create(InputStream, Settings.MaxRequestBodyBytes);
  try
    while Reader.ReadLine(Line, Status) do
    begin
      try
        case Status of
          TMCPLineStatus.TooLong:
            SendError(TMCPRequestId.FromJson(nil), JSONRPC_INVALID_REQUEST,
              Format('Message exceeds %d bytes', [Settings.MaxRequestBodyBytes]));
          TMCPLineStatus.InvalidUtf8:
            SendError(TMCPRequestId.FromJson(nil), JSONRPC_PARSE_ERROR, 'Message is not valid UTF-8');
        else
          if Line.Trim = '' then
            Continue;
          TLogger.Debug('Received: ' + TLogger.RedactJson(Line));
          DispatchLine(TJSONObject.ParseJSONValue(Line));
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
