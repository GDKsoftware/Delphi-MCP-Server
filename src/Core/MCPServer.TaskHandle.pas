unit MCPServer.TaskHandle;

interface

uses
  System.SysUtils,
  System.SyncObjs,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Result,
  MCPServer.Task.Types;

type
  IMCPTaskControl = interface
    ['{9B5D3F7A-2E4C-4A6B-8D0F-6E8A0C2E4A57}']
    function GetHandle: IMCPTaskHandle;
    procedure Cancel;
    procedure DeliverInput(const InputResponses: TJSONObject);
    function IsFinished: Boolean;
    property Handle: IMCPTaskHandle read GetHandle;
  end;

  TMCPTaskHandle = class(TInterfacedObject, IMCPTaskHandle, IMCPTaskControl)
  private
    FTaskId: string;
    FStore: IMCPTaskStore;
    FLock: TCriticalSection;
    FInputArrived: TEvent;
    FCancelled: Integer;
    FFinished: Integer;
    FOutstanding: TJSONObject;
    FResponses: TJSONObject;
    FBoundContext: IMCPRequestContext;
    function TryLoad(out Task: TMCPTaskSnapshot): Boolean;
    procedure Save(const Task: TMCPTaskSnapshot);
    procedure Finish(const Task: TMCPTaskSnapshot);
    procedure AcceptResponses(const InputResponses: TJSONObject);
    procedure SaveOutstanding(const Task: TMCPTaskSnapshot);
    procedure SignalCancelled;
    function TakeResponses: TJSONObject;
    function AwaitInput(const TimeoutMs: Cardinal): Boolean;
    function IsStillKnown: Boolean;

  public
    constructor Create(const TaskId: string; const Store: IMCPTaskStore);
    destructor Destroy; override;

    function GetTaskId: string;
    function GetHandle: IMCPTaskHandle;
    function IsCancelled: Boolean;
    function IsFinished: Boolean;
    procedure SetStatusMessage(const StatusMessage: string);
    procedure RequestInput(const InputRequests: TJSONObject);
    function WaitForInput(const TimeoutMs: Cardinal; out InputResponses: TJSONObject): Boolean;
    procedure DeliverInput(const InputResponses: TJSONObject);
    procedure Complete(const ToolResult: TJSONObject); overload;
    procedure Complete(const ToolResult: TMCPToolResult); overload;
    procedure Fail(const Code: Integer; const Message: string; const Data: TJSONValue = nil);
    procedure Cancel;
    procedure BindCancellation(const Context: IMCPRequestContext);
  end;

implementation

const
  WAIT_SLICE_MS = 1000;
  KEY_CODE = 'code';
  KEY_MESSAGE = 'message';
  KEY_DATA = 'data';

{ TMCPTaskHandle }

constructor TMCPTaskHandle.Create(const TaskId: string; const Store: IMCPTaskStore);
begin
  inherited Create;
  FTaskId := TaskId;
  FStore := Store;
  FLock := TCriticalSection.Create;
  FInputArrived := TEvent.Create(nil, True, False, '');
end;

destructor TMCPTaskHandle.Destroy;
begin
  FOutstanding.Free;
  FResponses.Free;
  FInputArrived.Free;
  FLock.Free;
  inherited;
end;

function TMCPTaskHandle.GetTaskId: string;
begin
  Result := FTaskId;
end;

function TMCPTaskHandle.GetHandle: IMCPTaskHandle;
begin
  Result := Self;
end;

function TMCPTaskHandle.IsCancelled: Boolean;
begin
  Result := (AtomicCmpExchange(FCancelled, 0, 0) <> 0);
end;

function TMCPTaskHandle.IsFinished: Boolean;
begin
  Result := (AtomicCmpExchange(FFinished, 0, 0) <> 0);
end;

procedure TMCPTaskHandle.SetStatusMessage(const StatusMessage: string);
begin
  FLock.Enter;
  try
    var Task: TMCPTaskSnapshot;
    if not TryLoad(Task) then
      Exit;

    Task.StatusMessage := StatusMessage;
    Save(Task);
  finally
    FLock.Leave;
  end;
end;

procedure TMCPTaskHandle.RequestInput(const InputRequests: TJSONObject);
begin
  FLock.Enter;
  try
    var Task: TMCPTaskSnapshot;
    if not TryLoad(Task) then
      Exit;

    FOutstanding.Free;
    FOutstanding := TJSONObject(InputRequests.Clone);
    FResponses.Free;
    FResponses := TJSONObject.Create;
    FInputArrived.ResetEvent;
    SaveOutstanding(Task);
  finally
    FLock.Leave;
  end;
end;

function TMCPTaskHandle.WaitForInput(const TimeoutMs: Cardinal; out InputResponses: TJSONObject): Boolean;
begin
  InputResponses := nil;
  if not AwaitInput(TimeoutMs) then
    Exit(False);

  FLock.Enter;
  try
    InputResponses := TakeResponses;
    Result := Assigned(InputResponses);
  finally
    FLock.Leave;
  end;
end;

procedure TMCPTaskHandle.DeliverInput(const InputResponses: TJSONObject);
begin
  FLock.Enter;
  try
    if not Assigned(FOutstanding) then
      Exit;

    AcceptResponses(InputResponses);
    var Task: TMCPTaskSnapshot;
    if not TryLoad(Task) then
      Exit;

    SaveOutstanding(Task);
    const IsAnswered = (FOutstanding.Count = 0);
    if IsAnswered then
      FInputArrived.SetEvent;
  finally
    FLock.Leave;
  end;
end;

procedure TMCPTaskHandle.Complete(const ToolResult: TJSONObject);
begin
  FLock.Enter;
  try
    var Task: TMCPTaskSnapshot;
    if not TryLoad(Task) then
      Exit;

    Task.Status := TMCPTaskStatus.Completed;
    Task.ToolResult := ToolResult.ToJSON;
    Finish(Task);
  finally
    FLock.Leave;
  end;
end;

procedure TMCPTaskHandle.Complete(const ToolResult: TMCPToolResult);
begin
  const Json = ToolResult.ToJson(TMCPProtocolEra.Modern);
  try
    Complete(Json);
  finally
    Json.Free;
  end;
end;

procedure TMCPTaskHandle.Fail(const Code: Integer; const Message: string; const Data: TJSONValue);
begin
  const Error = TJSONObject.Create;
  try
    Error.AddPair(KEY_CODE, TJSONNumber.Create(Code));
    Error.AddPair(KEY_MESSAGE, Message);
    if Assigned(Data) then
      Error.AddPair(KEY_DATA, TJSONValue(Data.Clone));

    FLock.Enter;
    try
      var Task: TMCPTaskSnapshot;
      if not TryLoad(Task) then
        Exit;

      Task.Status := TMCPTaskStatus.Failed;
      Task.Error := Error.ToJSON;
      Finish(Task);
    finally
      FLock.Leave;
    end;
  finally
    Error.Free;
  end;
end;

procedure TMCPTaskHandle.Cancel;
begin
  FLock.Enter;
  try
    var Task: TMCPTaskSnapshot;
    if TryLoad(Task) then
    begin
      Task.Status := TMCPTaskStatus.Cancelled;
      Finish(Task);
    end;
    SignalCancelled;
  finally
    FLock.Leave;
  end;
end;

procedure TMCPTaskHandle.BindCancellation(const Context: IMCPRequestContext);
begin
  FLock.Enter;
  try
    FBoundContext := Context;
    if IsCancelled then
      Context.Cancel;
  finally
    FLock.Leave;
  end;
end;

function TMCPTaskHandle.TryLoad(out Task: TMCPTaskSnapshot): Boolean;
begin
  const IsKnown = FStore.TryGet(FTaskId, Task);
  if not IsKnown then
    SignalCancelled;

  Result := (IsKnown and not Task.Status.IsTerminal);
  if not Result then
    AtomicExchange(FFinished, 1);
end;

procedure TMCPTaskHandle.Save(const Task: TMCPTaskSnapshot);
begin
  var Changed := Task;
  Changed.LastUpdatedAt := TMCPTaskSnapshot.NowUtc;
  const IsStored = FStore.TryUpdate(Changed);
  if not IsStored then
    AtomicExchange(FFinished, 1);
end;

procedure TMCPTaskHandle.Finish(const Task: TMCPTaskSnapshot);
begin
  var Finished := Task;
  Finished.InputRequests := '';
  Save(Finished);
  AtomicExchange(FFinished, 1);
end;

procedure TMCPTaskHandle.AcceptResponses(const InputResponses: TJSONObject);
begin
  if not Assigned(InputResponses) then
    Exit;

  for var Pair in InputResponses do
  begin
    const Key = Pair.JsonString.Value;
    const Answered = FOutstanding.RemovePair(Key);
    if not Assigned(Answered) then
      Continue;

    Answered.Free;
    FResponses.AddPair(Key, TJSONValue(Pair.JsonValue.Clone));
  end;
end;

procedure TMCPTaskHandle.SaveOutstanding(const Task: TMCPTaskSnapshot);
begin
  var Changed := Task;
  const IsWaiting = (FOutstanding.Count > 0);
  if IsWaiting then
  begin
    Changed.Status := TMCPTaskStatus.InputRequired;
    Changed.InputRequests := FOutstanding.ToJSON;
  end
  else
  begin
    Changed.Status := TMCPTaskStatus.Working;
    Changed.InputRequests := '';
  end;
  Save(Changed);
end;

procedure TMCPTaskHandle.SignalCancelled;
begin
  AtomicExchange(FCancelled, 1);
  if Assigned(FBoundContext) then
    FBoundContext.Cancel;
  FInputArrived.SetEvent;
end;

function TMCPTaskHandle.AwaitInput(const TimeoutMs: Cardinal): Boolean;
begin
  const IsUnlimited = (TimeoutMs = INFINITE);
  var Remaining: Int64 := TimeoutMs;
  while not IsCancelled do
  begin
    var Slice: Cardinal := WAIT_SLICE_MS;
    const IsLastSlice = (not IsUnlimited and (Remaining < WAIT_SLICE_MS));
    if IsLastSlice then
      Slice := Cardinal(Remaining);

    const Signalled = (FInputArrived.WaitFor(Slice) = TWaitResult.wrSignaled);
    if Signalled then
      Exit(not IsCancelled);
    if not IsStillKnown then
      Exit(False);

    Dec(Remaining, Slice);
    const IsTimedOut = (not IsUnlimited and (Remaining <= 0));
    if IsTimedOut then
      Exit(False);
  end;
  Result := False;
end;

function TMCPTaskHandle.IsStillKnown: Boolean;
begin
  FLock.Enter;
  try
    var Task: TMCPTaskSnapshot;
    Result := TryLoad(Task);
  finally
    FLock.Leave;
  end;
end;

function TMCPTaskHandle.TakeResponses: TJSONObject;
begin
  Result := FResponses;
  FResponses := nil;
  FreeAndNil(FOutstanding);
  FInputArrived.ResetEvent;
end;

end.
