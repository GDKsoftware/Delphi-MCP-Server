unit MCPServer.TaskStore.Memory;

interface

uses
  System.SysUtils,
  System.SyncObjs,
  System.Generics.Collections,
  MCPServer.Task.Types;

type
  TMCPInMemoryTaskStore = class(TInterfacedObject, IMCPTaskStore)
  private
    FTasks: TDictionary<string, TMCPTaskSnapshot>;
    FLock: TCriticalSection;
    procedure PurgeExpired;

  public
    constructor Create;
    destructor Destroy; override;

    procedure Add(const Task: TMCPTaskSnapshot);
    function TryGet(const TaskId: string; out Task: TMCPTaskSnapshot): Boolean;
    function TryUpdate(const Task: TMCPTaskSnapshot): Boolean;
    procedure Remove(const TaskId: string);
  end;

implementation

uses
  MCPServer.Errors;

const
  MESSAGE_DUPLICATE_TASK_ID = 'A task with id ''%s'' already exists';

{ TMCPInMemoryTaskStore }

constructor TMCPInMemoryTaskStore.Create;
begin
  inherited Create;
  FTasks := TDictionary<string, TMCPTaskSnapshot>.Create;
  FLock := TCriticalSection.Create;
end;

destructor TMCPInMemoryTaskStore.Destroy;
begin
  FTasks.Free;
  FLock.Free;
  inherited;
end;

procedure TMCPInMemoryTaskStore.Add(const Task: TMCPTaskSnapshot);
begin
  FLock.Enter;
  try
    PurgeExpired;
    const IsDuplicate = FTasks.ContainsKey(Task.TaskId);
    if IsDuplicate then
      raise EMCPError.InternalError(Format(MESSAGE_DUPLICATE_TASK_ID, [Task.TaskId]));
    FTasks.Add(Task.TaskId, Task);
  finally
    FLock.Leave;
  end;
end;

function TMCPInMemoryTaskStore.TryGet(const TaskId: string; out Task: TMCPTaskSnapshot): Boolean;
begin
  FLock.Enter;
  try
    PurgeExpired;
    Result := FTasks.TryGetValue(TaskId, Task);
  finally
    FLock.Leave;
  end;
end;

function TMCPInMemoryTaskStore.TryUpdate(const Task: TMCPTaskSnapshot): Boolean;
begin
  FLock.Enter;
  try
    PurgeExpired;
    var Stored: TMCPTaskSnapshot;
    if not FTasks.TryGetValue(Task.TaskId, Stored) then
      Exit(False);
    if Stored.Status.IsTerminal then
      Exit(False);

    FTasks[Task.TaskId] := Task;
    Result := True;
  finally
    FLock.Leave;
  end;
end;

procedure TMCPInMemoryTaskStore.Remove(const TaskId: string);
begin
  FLock.Enter;
  try
    FTasks.Remove(TaskId);
  finally
    FLock.Leave;
  end;
end;

procedure TMCPInMemoryTaskStore.PurgeExpired;
begin
  const NowUtc = TMCPTaskSnapshot.NowUtc;
  var Expired: TArray<string> := nil;
  for var Task in FTasks.Values do
  begin
    if Task.IsExpired(NowUtc) then
      Expired := Expired + [Task.TaskId];
  end;

  for var TaskId in Expired do
  begin
    FTasks.Remove(TaskId);
  end;
end;

end.
