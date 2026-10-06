unit MCPServer.Task.Types;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Result;

const
  MCP_EXTENSION_TASKS = 'io.modelcontextprotocol/tasks';
  MCP_METHOD_TASKS_GET = 'tasks/get';
  MCP_METHOD_TASKS_UPDATE = 'tasks/update';
  MCP_METHOD_TASKS_CANCEL = 'tasks/cancel';
  MCP_KEY_TASK_ID = 'taskId';
  RESULT_TYPE_TASK = 'task';

type
  {$SCOPEDENUMS ON}
  TMCPTaskStatus = (Working, InputRequired, Completed, Failed, Cancelled);
  TMCPTaskExecution = (Synchronous, Optional, Required);
  {$SCOPEDENUMS OFF}

  TMCPTaskStatusHelper = record helper for TMCPTaskStatus
    function ToWire: string;
    function IsTerminal: Boolean;
  end;

  TMCPTaskSnapshot = record
    TaskId: string;
    Owner: string;
    Status: TMCPTaskStatus;
    StatusMessage: string;
    CreatedAt: TDateTime;
    LastUpdatedAt: TDateTime;
    TtlMs: Int64;
    PollIntervalMs: Integer;
    InputRequests: string;
    ToolResult: string;
    Error: string;
    class function NowUtc: TDateTime; static;
    function HasTtl: Boolean;
    function ExpiresAt: TDateTime;
    function IsExpired(const NowUtc: TDateTime): Boolean;
  end;

  IMCPTaskStore = interface
    ['{6F2B8D4A-1C3E-4A5B-9D7F-0E2C4A6B8D13}']
    procedure Add(const Task: TMCPTaskSnapshot);
    function TryGet(const TaskId: string; out Task: TMCPTaskSnapshot): Boolean;
    function TryUpdate(const Task: TMCPTaskSnapshot): Boolean;
    procedure Remove(const TaskId: string);
  end;

  IMCPTaskHandle = interface
    ['{8A4C1E6B-3D5F-4B7A-8C9E-1F3A5C7E9B24}']
    function GetTaskId: string;
    function IsCancelled: Boolean;
    procedure SetStatusMessage(const StatusMessage: string);
    procedure RequestInput(const InputRequests: TJSONObject);
    function WaitForInput(const TimeoutMs: Cardinal; out InputResponses: TJSONObject): Boolean;
    procedure Complete(const ToolResult: TJSONObject); overload;
    procedure Complete(const ToolResult: TMCPToolResult); overload;
    procedure Fail(const Code: Integer; const Message: string; const Data: TJSONValue = nil);
    procedure BindCancellation(const Context: IMCPRequestContext);
    property TaskId: string read GetTaskId;
  end;

  IMCPTaskStarter = interface
    ['{2C6E9A1B-5D7F-4C8A-9E0B-3A5C7E9B1D35}']
    procedure StartTask(const Arguments: TJSONObject; const Task: IMCPTaskHandle);
  end;

  IMCPTaskService = interface
    ['{4E8A2C6D-7F9B-4D1C-8A2E-5C7E9B1D3F46}']
    function StartTask(const Context: IMCPRequestContext; const Starter: TProc<IMCPTaskHandle>): TJSONObject;
    function RunTask(const Context: IMCPRequestContext; const Work: TProc<IMCPTaskHandle>): TJSONObject;
  end;

  TaskExecutionAttribute = class(TCustomAttribute)
  private
    FExecution: TMCPTaskExecution;

  public
    constructor Create(const Execution: TMCPTaskExecution);
    property Execution: TMCPTaskExecution read FExecution;
  end;

implementation

uses
  System.DateUtils;

const
  TASK_STATUS_WORKING = 'working';
  TASK_STATUS_INPUT_REQUIRED = 'input_required';
  TASK_STATUS_COMPLETED = 'completed';
  TASK_STATUS_FAILED = 'failed';
  TASK_STATUS_CANCELLED = 'cancelled';

{ TMCPTaskStatusHelper }

function TMCPTaskStatusHelper.ToWire: string;
begin
  case Self of
    TMCPTaskStatus.Working       : Result := TASK_STATUS_WORKING;
    TMCPTaskStatus.InputRequired : Result := TASK_STATUS_INPUT_REQUIRED;
    TMCPTaskStatus.Completed     : Result := TASK_STATUS_COMPLETED;
    TMCPTaskStatus.Failed        : Result := TASK_STATUS_FAILED;
    TMCPTaskStatus.Cancelled     : Result := TASK_STATUS_CANCELLED;
  else
    raise ENotSupportedException.CreateFmt('Unsupported task status: %d', [Ord(Self)]);
  end;
end;

function TMCPTaskStatusHelper.IsTerminal: Boolean;
begin
  Result := (Self in [TMCPTaskStatus.Completed, TMCPTaskStatus.Failed, TMCPTaskStatus.Cancelled]);
end;

{ TMCPTaskSnapshot }

class function TMCPTaskSnapshot.NowUtc: TDateTime;
begin
  Result := TTimeZone.Local.ToUniversalTime(Now);
end;

function TMCPTaskSnapshot.HasTtl: Boolean;
begin
  Result := (TtlMs > 0);
end;

function TMCPTaskSnapshot.ExpiresAt: TDateTime;
begin
  Result := IncMilliSecond(CreatedAt, TtlMs);
end;

function TMCPTaskSnapshot.IsExpired(const NowUtc: TDateTime): Boolean;
begin
  Result := (HasTtl and (NowUtc >= ExpiresAt));
end;

{ TaskExecutionAttribute }

constructor TaskExecutionAttribute.Create(const Execution: TMCPTaskExecution);
begin
  inherited Create;
  FExecution := Execution;
end;

end.
