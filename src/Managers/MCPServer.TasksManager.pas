unit MCPServer.TasksManager;

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.JSON,
  System.Rtti,
  System.Threading,
  System.Generics.Collections,
  MCPServer.Types,
  MCPServer.Task.Types,
  MCPServer.TaskHandle;

type
  TMCPTasksManager = class(TInterfacedObject, IMCPCapabilityManager, IMCPCapabilityManagerEx, IMCPExtensionProvider,
    IMCPTaskService)
  private
    FStore: IMCPTaskStore;
    FTtlMs: Int64;
    FPollIntervalMs: Integer;
    FMaxRunningTasks: Integer;
    FLock: TCriticalSection;
    FControls: TDictionary<string, IMCPTaskControl>;
    FPool: TThreadPool;
    FRunningCount: Integer;
    FIdle: TEvent;
    function GetTask(const Params: TJSONObject; const Context: IMCPRequestContext): TValue;
    function UpdateTask(const Params: TJSONObject; const Context: IMCPRequestContext): TValue;
    function CancelTask(const Params: TJSONObject; const Context: IMCPRequestContext): TValue;
    function TaskIdOf(const Params: TJSONObject): string;
    function InputResponsesOf(const Params: TJSONObject): TJSONObject;
    function OwnedTask(const TaskId: string; const Context: IMCPRequestContext): TMCPTaskSnapshot;
    function ControlFor(const TaskId: string): IMCPTaskControl;
    function NewTask(const Context: IMCPRequestContext): IMCPTaskControl;
    function NewTaskId: string;
    function CreateTaskResult(const TaskId: string): TJSONObject;
    function DetailedTask(const Task: TMCPTaskSnapshot): TJSONObject;
    function TaskJson(const Task: TMCPTaskSnapshot): TJSONObject;
    procedure AddDetails(const TaskObject: TJSONObject; const Task: TMCPTaskSnapshot);
    class procedure AddDetail(const TaskObject: TJSONObject; const Key, DetailJson: string); static;
    procedure Forget(const TaskId: string);
    procedure ForgetFinished;
    procedure Schedule(const Control: IMCPTaskControl; const Work: TProc<IMCPTaskHandle>);
    procedure RunWork(const Control: IMCPTaskControl; const Work: TProc<IMCPTaskHandle>);
    procedure ReportFailure(const Task: IMCPTaskHandle; const Error: Exception);
    procedure WorkStarted;
    procedure WorkFinished;
    function Pool: TThreadPool;

  public
    const DEFAULT_SHUTDOWN_GRACE_MS = 5000;

    constructor Create(const Store: IMCPTaskStore; const TtlMs: Int64; const PollIntervalMs,
      MaxRunningTasks: Integer);
    destructor Destroy; override;

    function GetCapabilityName: string;
    function HandlesMethod(const Method: string): Boolean;
    function ExecuteMethod(const Method: string; const Params: TJSONObject): TValue;
    function ExecuteMethodWithContext(const Method: string; const Params: TJSONObject;
      const Context: IMCPRequestContext): TValue;

    function GetExtensionId: string;
    function GetExtensionSettings: TJSONObject;
    function GetResultTypes: TArray<string>;

    function StartTask(const Context: IMCPRequestContext; const Starter: TProc<IMCPTaskHandle>): TJSONObject;
    function RunTask(const Context: IMCPRequestContext; const Work: TProc<IMCPTaskHandle>): TJSONObject;
    procedure ResumeTask(const Task: IMCPTaskHandle; const Work: TProc<IMCPTaskHandle>);

    function TryGetTask(const TaskId: string; out Task: IMCPTaskHandle): Boolean;
    procedure Shutdown(const GraceMs: Cardinal = DEFAULT_SHUTDOWN_GRACE_MS);
  end;

implementation

uses
  System.DateUtils,
  MCPServer.Errors,
  MCPServer.Logger,
  System.NetEncoding,
  MCPServer.SecureRandom;

const
  CAPABILITY_NAME = 'tasks';
  TASK_ID_BYTES = 32;
  KEY_STATUS = 'status';
  KEY_STATUS_MESSAGE = 'statusMessage';
  KEY_CREATED_AT = 'createdAt';
  KEY_LAST_UPDATED_AT = 'lastUpdatedAt';
  KEY_POLL_INTERVAL_MS = 'pollIntervalMs';
  KEY_INPUT_REQUESTS = 'inputRequests';
  MESSAGE_TASK_NOT_FOUND = 'Failed to retrieve task: Task not found';
  MESSAGE_TASK_ID_REQUIRED = 'params.taskId is required and must be a non-empty string';
  MESSAGE_INPUT_RESPONSES_REQUIRED = 'params.inputResponses must be an object';
  MESSAGE_NEEDS_CONTEXT = 'The tasks manager needs a request context';
  MESSAGE_POOL_LIMIT_REFUSED = 'The task thread pool did not accept MaxRunningTasks = %d';
  MESSAGE_TASK_WORK_FAILED = 'Task %s failed: %s';
  MESSAGE_SHUTDOWN_TIMEOUT = 'Tasks still running %d ms after they were told to stop';
  MESSAGE_UNSUPPORTED_STATUS = 'Unsupported task status: %d';

{ TMCPTasksManager }

constructor TMCPTasksManager.Create(const Store: IMCPTaskStore; const TtlMs: Int64; const PollIntervalMs,
  MaxRunningTasks: Integer);
begin
  inherited Create;
  FStore := Store;
  FTtlMs := TtlMs;
  FPollIntervalMs := PollIntervalMs;
  FMaxRunningTasks := MaxRunningTasks;
  FLock := TCriticalSection.Create;
  FControls := TDictionary<string, IMCPTaskControl>.Create;
  FIdle := TEvent.Create(nil, True, True, '');
end;

destructor TMCPTasksManager.Destroy;
begin
  Shutdown;
  FControls.Free;
  FIdle.Free;
  FLock.Free;
  inherited;
end;

function TMCPTasksManager.GetCapabilityName: string;
begin
  Result := CAPABILITY_NAME;
end;

function TMCPTasksManager.HandlesMethod(const Method: string): Boolean;
begin
  Result := ((Method = MCP_METHOD_TASKS_GET) or
             (Method = MCP_METHOD_TASKS_UPDATE) or
             (Method = MCP_METHOD_TASKS_CANCEL));
end;

function TMCPTasksManager.ExecuteMethod(const Method: string; const Params: TJSONObject): TValue;
begin
  raise EMCPError.InternalError(MESSAGE_NEEDS_CONTEXT);
end;

function TMCPTasksManager.ExecuteMethodWithContext(const Method: string; const Params: TJSONObject;
  const Context: IMCPRequestContext): TValue;
begin
  if not Assigned(Context) then
    raise EMCPError.InternalError(MESSAGE_NEEDS_CONTEXT);

  Context.RequireClientExtension(MCP_EXTENSION_TASKS);

  const IsGet = (Method = MCP_METHOD_TASKS_GET);
  const IsUpdate = (Method = MCP_METHOD_TASKS_UPDATE);
  const IsCancel = (Method = MCP_METHOD_TASKS_CANCEL);
  if IsGet then
    Result := GetTask(Params, Context)
  else if IsUpdate then
    Result := UpdateTask(Params, Context)
  else if IsCancel then
    Result := CancelTask(Params, Context)
  else
    raise EMCPError.MethodNotFound(Method);
end;

function TMCPTasksManager.GetExtensionId: string;
begin
  Result := MCP_EXTENSION_TASKS;
end;

function TMCPTasksManager.GetExtensionSettings: TJSONObject;
begin
  Result := TJSONObject.Create;
end;

function TMCPTasksManager.GetResultTypes: TArray<string>;
begin
  Result := [RESULT_TYPE_TASK];
end;

function TMCPTasksManager.StartTask(const Context: IMCPRequestContext;
  const Starter: TProc<IMCPTaskHandle>): TJSONObject;
begin
  const Control = NewTask(Context);
  const TaskId = Control.Handle.TaskId;
  try
    Starter(Control.Handle);
  except
    Forget(TaskId);
    FStore.Remove(TaskId);
    raise;
  end;
  Result := CreateTaskResult(TaskId);
end;

function TMCPTasksManager.RunTask(const Context: IMCPRequestContext;
  const Work: TProc<IMCPTaskHandle>): TJSONObject;
begin
  const Control = NewTask(Context);
  Result := CreateTaskResult(Control.Handle.TaskId);
  Schedule(Control, Work);
end;

procedure TMCPTasksManager.ResumeTask(const Task: IMCPTaskHandle; const Work: TProc<IMCPTaskHandle>);
begin
  const Control = ControlFor(Task.TaskId);
  if Assigned(Control) then
    Schedule(Control, Work);
end;

function TMCPTasksManager.TryGetTask(const TaskId: string; out Task: IMCPTaskHandle): Boolean;
begin
  Task := nil;
  const Control = ControlFor(TaskId);
  if Assigned(Control) then
  begin
    Task := Control.Handle;
  end
  else
  begin
    var Snapshot: TMCPTaskSnapshot;
    if FStore.TryGet(TaskId, Snapshot) then
      Task := TMCPTaskHandle.Create(TaskId, FStore);
  end;
  Result := Assigned(Task);
end;

procedure TMCPTasksManager.Shutdown(const GraceMs: Cardinal);
begin
  var Controls: TArray<IMCPTaskControl>;
  FLock.Enter;
  try
    Controls := FControls.Values.ToArray;
  finally
    FLock.Leave;
  end;

  for var Control in Controls do
  begin
    Control.Release;
  end;

  const IsIdle = (FIdle.WaitFor(GraceMs) = TWaitResult.wrSignaled);
  if not IsIdle then
    TLogger.Warning(Format(MESSAGE_SHUTDOWN_TIMEOUT, [GraceMs]));
  FreeAndNil(FPool);
end;

function TMCPTasksManager.GetTask(const Params: TJSONObject; const Context: IMCPRequestContext): TValue;
begin
  const TaskId = TaskIdOf(Params);
  const Task = OwnedTask(TaskId, Context);
  Result := TValue.From<TJSONObject>(DetailedTask(Task));
end;

function TMCPTasksManager.UpdateTask(const Params: TJSONObject; const Context: IMCPRequestContext): TValue;
begin
  const TaskId = TaskIdOf(Params);
  const InputResponses = InputResponsesOf(Params);
  OwnedTask(TaskId, Context);

  const Control = ControlFor(TaskId);
  if Assigned(Control) then
    Control.DeliverInput(InputResponses);
  Result := TValue.From<TJSONObject>(TJSONObject.Create);
end;

function TMCPTasksManager.CancelTask(const Params: TJSONObject; const Context: IMCPRequestContext): TValue;
begin
  const TaskId = TaskIdOf(Params);
  OwnedTask(TaskId, Context);

  var Control := ControlFor(TaskId);
  if not Assigned(Control) then
    Control := TMCPTaskHandle.Create(TaskId, FStore);
  Control.Cancel;
  Result := TValue.From<TJSONObject>(TJSONObject.Create);
end;

function TMCPTasksManager.TaskIdOf(const Params: TJSONObject): string;
begin
  Result := '';
  if Assigned(Params) then
  begin
    const Value = Params.GetValue(MCP_KEY_TASK_ID);
    const IsText = (Value is TJSONString);
    if IsText then
      Result := TJSONString(Value).Value;
  end;

  const HasTaskId = (Result <> '');
  if not HasTaskId then
    raise EMCPError.InvalidParams(MESSAGE_TASK_ID_REQUIRED);
end;

function TMCPTasksManager.InputResponsesOf(const Params: TJSONObject): TJSONObject;
begin
  const Value = Params.GetValue(MCP_KEY_INPUT_RESPONSES);
  const IsObject = (Value is TJSONObject);
  if not IsObject then
    raise EMCPError.InvalidParams(MESSAGE_INPUT_RESPONSES_REQUIRED);
  Result := TJSONObject(Value);
end;

function TMCPTasksManager.OwnedTask(const TaskId: string; const Context: IMCPRequestContext): TMCPTaskSnapshot;
begin
  const IsKnown = FStore.TryGet(TaskId, Result);
  const IsOwner = (IsKnown and (Result.Owner = Context.Principal));
  if not IsOwner then
    raise EMCPError.InvalidParams(MESSAGE_TASK_NOT_FOUND);
end;

function TMCPTasksManager.ControlFor(const TaskId: string): IMCPTaskControl;
begin
  FLock.Enter;
  try
    if not FControls.TryGetValue(TaskId, Result) then
      Result := nil;
  finally
    FLock.Leave;
  end;
end;

function TMCPTasksManager.NewTask(const Context: IMCPRequestContext): IMCPTaskControl;
begin
  ForgetFinished;

  var Task := Default(TMCPTaskSnapshot);
  Task.TaskId := NewTaskId;
  Task.Owner := Context.Principal;
  Task.Status := TMCPTaskStatus.Working;
  Task.CreatedAt := TMCPTaskSnapshot.NowUtc;
  Task.LastUpdatedAt := Task.CreatedAt;
  Task.TtlMs := FTtlMs;
  Task.PollIntervalMs := FPollIntervalMs;
  FStore.Add(Task);

  Result := TMCPTaskHandle.Create(Task.TaskId, FStore);
  FLock.Enter;
  try
    FControls.Add(Task.TaskId, Result);
  finally
    FLock.Leave;
  end;
end;

function TMCPTasksManager.NewTaskId: string;
begin
  const Bytes = TMCPSecureRandom.Bytes(TASK_ID_BYTES);
  Result := TNetEncoding.Base64URL.EncodeBytesToString(Bytes);
end;

function TMCPTasksManager.CreateTaskResult(const TaskId: string): TJSONObject;
begin
  var Task: TMCPTaskSnapshot;
  if not FStore.TryGet(TaskId, Task) then
    raise EMCPError.InternalError(MESSAGE_TASK_NOT_FOUND);

  Result := TaskJson(Task);
  Result.AddPair(MCP_KEY_RESULT_TYPE, RESULT_TYPE_TASK);
end;

function TMCPTasksManager.DetailedTask(const Task: TMCPTaskSnapshot): TJSONObject;
begin
  Result := TaskJson(Task);
  try
    AddDetails(Result, Task);
  except
    Result.Free;
    raise;
  end;
end;

function TMCPTasksManager.TaskJson(const Task: TMCPTaskSnapshot): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair(MCP_KEY_TASK_ID, Task.TaskId);
  Result.AddPair(KEY_STATUS, Task.Status.ToWire);

  const HasStatusMessage = (Task.StatusMessage <> '');
  if HasStatusMessage then
    Result.AddPair(KEY_STATUS_MESSAGE, Task.StatusMessage);

  const CreatedAt = DateToISO8601(Task.CreatedAt, True);
  const LastUpdatedAt = DateToISO8601(Task.LastUpdatedAt, True);
  Result.AddPair(KEY_CREATED_AT, CreatedAt);
  Result.AddPair(KEY_LAST_UPDATED_AT, LastUpdatedAt);

  if Task.HasTtl then
    Result.AddPair(MCP_KEY_TTL_MS, TJSONNumber.Create(Task.TtlMs))
  else
    Result.AddPair(MCP_KEY_TTL_MS, TJSONNull.Create);

  const HasPollInterval = (Task.PollIntervalMs > 0);
  if HasPollInterval then
    Result.AddPair(KEY_POLL_INTERVAL_MS, TJSONNumber.Create(Task.PollIntervalMs));
end;

procedure TMCPTasksManager.AddDetails(const TaskObject: TJSONObject; const Task: TMCPTaskSnapshot);
begin
  case Task.Status of
    TMCPTaskStatus.Working,
    TMCPTaskStatus.Cancelled     : Exit;
    TMCPTaskStatus.InputRequired : AddDetail(TaskObject, KEY_INPUT_REQUESTS, Task.InputRequests);
    TMCPTaskStatus.Completed     : AddDetail(TaskObject, MCP_KEY_RESULT, Task.ToolResult);
    TMCPTaskStatus.Failed        : AddDetail(TaskObject, MCP_KEY_ERROR, Task.Error);
  else
    raise ENotSupportedException.CreateFmt(MESSAGE_UNSUPPORTED_STATUS, [Ord(Task.Status)]);
  end;
end;

class procedure TMCPTasksManager.AddDetail(const TaskObject: TJSONObject; const Key, DetailJson: string);
begin
  const Detail = TJSONObject.ParseJSONValue(DetailJson);
  TaskObject.AddPair(Key, Detail);
end;

procedure TMCPTasksManager.Forget(const TaskId: string);
begin
  FLock.Enter;
  try
    FControls.Remove(TaskId);
  finally
    FLock.Leave;
  end;
end;

procedure TMCPTasksManager.ForgetFinished;
begin
  var Finished: TArray<IMCPTaskControl> := nil;
  FLock.Enter;
  try
    for var Pair in FControls do
    begin
      var Snapshot: TMCPTaskSnapshot;
      const IsGone = (Pair.Value.IsFinished or not FStore.TryGet(Pair.Key, Snapshot));
      if IsGone then
        Finished := Finished + [Pair.Value];
    end;

    for var Control in Finished do
    begin
      FControls.Remove(Control.Handle.TaskId);
    end;
  finally
    FLock.Leave;
  end;

  for var Control in Finished do
  begin
    Control.Release;
  end;
end;

procedure TMCPTasksManager.Schedule(const Control: IMCPTaskControl; const Work: TProc<IMCPTaskHandle>);
begin
  WorkStarted;
  try
    TTask.Run(
      procedure
      begin
        RunWork(Control, Work);
      end,
      Pool);
  except
    WorkFinished;
    raise;
  end;
end;

procedure TMCPTasksManager.RunWork(const Control: IMCPTaskControl; const Work: TProc<IMCPTaskHandle>);
begin
  const Task = Control.Handle;
  try
    try
      Work(Task);
    except
      on E: Exception do
        ReportFailure(Task, E);
    end;
  finally
    if Control.IsFinished then
      Forget(Task.TaskId);
    WorkFinished;
  end;
end;

procedure TMCPTasksManager.ReportFailure(const Task: IMCPTaskHandle; const Error: Exception);
begin
  if Task.IsCancelled then
    Exit;

  TLogger.Error(Format(MESSAGE_TASK_WORK_FAILED, [Task.TaskId, Error.Message]));
  const IsProtocolError = (Error is EMCPError);
  if IsProtocolError then
  begin
    const ProtocolError = EMCPError(Error);
    Task.Fail(ProtocolError.Code, ProtocolError.Message, ProtocolError.Data);
  end
  else
  begin
    Task.Fail(JSONRPC_INTERNAL_ERROR, Error.Message);
  end;
end;

procedure TMCPTasksManager.WorkStarted;
begin
  FLock.Enter;
  try
    Inc(FRunningCount);
    FIdle.ResetEvent;
  finally
    FLock.Leave;
  end;
end;

procedure TMCPTasksManager.WorkFinished;
begin
  FLock.Enter;
  try
    Dec(FRunningCount);
    const IsIdle = (FRunningCount = 0);
    if IsIdle then
      FIdle.SetEvent;
  finally
    FLock.Leave;
  end;
end;

function TMCPTasksManager.Pool: TThreadPool;
begin
  FLock.Enter;
  try
    if not Assigned(FPool) then
    begin
      FPool := TThreadPool.Create;
{$IF RTLVersion >= 36.0}
      FPool.UnlimitedWorkerThreadsWhenBlocked := False;
{$IFEND}
      const MinimumAccepted = FPool.SetMinWorkerThreads(0);
      const MaximumAccepted = FPool.SetMaxWorkerThreads(FMaxRunningTasks);
      const IsLimited = (MinimumAccepted and MaximumAccepted and (FPool.MaxWorkerThreads = FMaxRunningTasks));
      if not IsLimited then
      begin
        FreeAndNil(FPool);
        raise EMCPConfigurationError.CreateFmt(MESSAGE_POOL_LIMIT_REFUSED, [FMaxRunningTasks]);
      end;
    end;
    Result := FPool;
  finally
    FLock.Leave;
  end;
end;

end.
