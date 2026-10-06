unit MCPServer.Tool.TaskSamples;

interface

uses
  System.SysUtils,
  System.Rtti,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Base,
  MCPServer.Tool.ContentSamples,
  MCPServer.Task.Types;

type
  TGreetParams = class
  private
    FName: string;

  public
    [SchemaDescription('Name to greet')]
    property Name: string read FName write FName;
  end;

  TSlowComputeParams = class
  private
    FSeconds: Integer;
    FLabel: string;

  public
    [SchemaDescription('How long the computation takes, in seconds')]
    property Seconds: Integer read FSeconds write FSeconds;
    [Optional]
    [SchemaDescription('Label echoed in the result')]
    property &Label: string read FLabel write FLabel;
  end;

  TConfirmDeleteParams = class
  private
    FFilename: string;

  public
    [SchemaDescription('File to delete after the user confirms')]
    property Filename: string read FFilename write FFilename;
  end;

  TGreetTool = class(TMCPToolBase<TGreetParams>)
  protected
    function ExecuteWithContext(const Params: TGreetParams; const Context: IMCPRequestContext): TValue; override;

  public
    constructor Create; override;
  end;

  [TaskExecution(TMCPTaskExecution.Optional)]
  TSlowComputeTool = class(TMCPToolBase<TSlowComputeParams>)
  protected
    function ExecuteWithContext(const Params: TSlowComputeParams; const Context: IMCPRequestContext): TValue; override;

  public
    constructor Create; override;
  end;

  [TaskExecution(TMCPTaskExecution.Required)]
  TFailingJobTool = class(TMCPToolBase<TNoParams>)
  protected
    function ExecuteWithContext(const Params: TNoParams; const Context: IMCPRequestContext): TValue; override;

  public
    constructor Create; override;
  end;

  [TaskExecution(TMCPTaskExecution.Optional)]
  TProtocolErrorJobTool = class(TMCPToolBase<TNoParams>)
  protected
    function ExecuteWithContext(const Params: TNoParams; const Context: IMCPRequestContext): TValue; override;

  public
    constructor Create; override;
  end;

  [TaskExecution(TMCPTaskExecution.Required)]
  TConfirmDeleteTool = class(TMCPToolBase<TConfirmDeleteParams>)
  protected
    function ExecuteWithContext(const Params: TConfirmDeleteParams; const Context: IMCPRequestContext): TValue; override;

  public
    constructor Create; override;
  end;

  [TaskExecution(TMCPTaskExecution.Required)]
  TMultiInputTool = class(TMCPToolBase<TNoParams>)
  protected
    function ExecuteWithContext(const Params: TNoParams; const Context: IMCPRequestContext): TValue; override;

  public
    constructor Create; override;
  end;

  TTaskWithInputTool = class(TMCPToolBase<TNoParams>, IMCPTaskStarter)
  private
    function AskedName: string;
    procedure CompleteLater(const Task: IMCPTaskHandle; const Name: string);

  protected
    function ExecuteWithContext(const Params: TNoParams; const Context: IMCPRequestContext): TValue; override;

  public
    constructor Create; override;
    procedure StartTask(const Arguments: TJSONObject; const Task: IMCPTaskHandle);
  end;

implementation

uses
  System.Classes,
  MCPServer.Registration,
  MCPServer.RequestContext,
  MCPServer.Errors,
  MCPServer.Mrtr,
  MCPServer.Tool.Result;

const
  TOOL_GREET = 'greet';
  TOOL_SLOW_COMPUTE = 'slow_compute';
  TOOL_FAILING_JOB = 'failing_job';
  TOOL_PROTOCOL_ERROR_JOB = 'protocol_error_job';
  TOOL_CONFIRM_DELETE = 'confirm_delete';
  TOOL_MULTI_INPUT = 'multi_input';
  TOOL_TASK_WITH_INPUT = 'test_tool_with_task';
  KEY_CONFIRM = 'confirm';
  KEY_INPUT_A = 'input-a';
  KEY_INPUT_B = 'input-b';
  KEY_USER_NAME = 'user_name';
  MULTI_INPUT_KEYS: array[0..1] of string = (KEY_INPUT_A, KEY_INPUT_B);
  FIELD_CONFIRM = 'confirm';
  FIELD_VALUE = 'value';
  FIELD_NAME = 'name';
  SCHEMA_TYPE_BOOLEAN = 'boolean';
  MILLISECONDS_PER_SECOND = 1000;
  PAUSE_SLICE_MS = 50;
  FAILING_JOB_DELAY_MS = 1000;
  PROTOCOL_ERROR_DELAY_MS = 200;
  ASYNC_COMPLETION_DELAY_MS = 200;

type
  TTaskSamplePause = record
    class procedure Wait(const Context: IMCPRequestContext; const Milliseconds: Integer); static;
  end;

{ TTaskSamplePause }

class procedure TTaskSamplePause.Wait(const Context: IMCPRequestContext; const Milliseconds: Integer);
begin
  var Remaining := Milliseconds;
  while Remaining > 0 do
  begin
    Context.CheckCancelled;
    TThread.Sleep(PAUSE_SLICE_MS);
    Dec(Remaining, PAUSE_SLICE_MS);
  end;
  Context.CheckCancelled;
end;

{ TGreetTool }

constructor TGreetTool.Create;
begin
  inherited;
  FName := TOOL_GREET;
  FDescription := 'Greets someone by name; always answers synchronously';
end;

function TGreetTool.ExecuteWithContext(const Params: TGreetParams; const Context: IMCPRequestContext): TValue;
begin
  Result := TMCPToolResult.Text(Format('Hello, %s!', [Params.Name]));
end;

{ TSlowComputeTool }

constructor TSlowComputeTool.Create;
begin
  inherited;
  FName := TOOL_SLOW_COMPUTE;
  FDescription := 'Takes the given number of seconds; runs as a task when the client supports tasks';
end;

function TSlowComputeTool.ExecuteWithContext(const Params: TSlowComputeParams;
  const Context: IMCPRequestContext): TValue;
begin
  TTaskSamplePause.Wait(Context, Params.Seconds * MILLISECONDS_PER_SECOND);
  Result := TMCPToolResult.Text(Format('Computed "%s" in %d seconds', [Params.&Label, Params.Seconds]));
end;

{ TFailingJobTool }

constructor TFailingJobTool.Create;
begin
  inherited;
  FName := TOOL_FAILING_JOB;
  FDescription := 'Always runs as a task and ends with a tool error after a second';
end;

function TFailingJobTool.ExecuteWithContext(const Params: TNoParams; const Context: IMCPRequestContext): TValue;
begin
  TTaskSamplePause.Wait(Context, FAILING_JOB_DELAY_MS);
  raise EMCPToolError.Create('The job failed');
end;

{ TProtocolErrorJobTool }

constructor TProtocolErrorJobTool.Create;
begin
  inherited;
  FName := TOOL_PROTOCOL_ERROR_JOB;
  FDescription := 'Ends with a JSON-RPC error, so its task ends as failed';
end;

function TProtocolErrorJobTool.ExecuteWithContext(const Params: TNoParams; const Context: IMCPRequestContext): TValue;
begin
  TTaskSamplePause.Wait(Context, PROTOCOL_ERROR_DELAY_MS);
  raise EMCPError.InternalError('The job hit an internal error');
end;

{ TConfirmDeleteTool }

constructor TConfirmDeleteTool.Create;
begin
  inherited;
  FName := TOOL_CONFIRM_DELETE;
  FDescription := 'Always runs as a task and asks the user to confirm before it deletes the file';
end;

function TConfirmDeleteTool.ExecuteWithContext(const Params: TConfirmDeleteParams;
  const Context: IMCPRequestContext): TValue;
var
  Response: TJSONObject;
begin
  if not Context.TryGetInputResponse(KEY_CONFIRM, Response) then
  begin
    const Schema = TMCPInputRequests.FieldSchema(FIELD_CONFIRM, SCHEMA_TYPE_BOOLEAN);
    const Question = Format('Delete %s?', [Params.Filename]);
    const Requests = TMCPInputRequests.Create;
    Requests.AddElicitation(KEY_CONFIRM, Question, Schema);
    raise EMCPInputRequired.Create(Requests);
  end;

  const Confirmed = TMCPInputResponse.ElicitationField(Response, FIELD_CONFIRM);
  const IsConfirmed = SameText(Confirmed, 'true');
  if IsConfirmed then
    Result := TMCPToolResult.Text(Format('Deleted %s', [Params.Filename]))
  else
    Result := TMCPToolResult.Text(Format('Kept %s', [Params.Filename]));
end;

{ TMultiInputTool }

constructor TMultiInputTool.Create;
begin
  inherited;
  FName := TOOL_MULTI_INPUT;
  FDescription := 'Always runs as a task and asks for two inputs at once';
end;

function TMultiInputTool.ExecuteWithContext(const Params: TNoParams; const Context: IMCPRequestContext): TValue;
var
  Response: TJSONObject;
begin
  const Requests = TMCPInputRequests.Create;
  try
    for var Key in MULTI_INPUT_KEYS do
    begin
      if not Context.TryGetInputResponse(Key, Response) then
      begin
        const Schema = TMCPInputRequests.FieldSchema(FIELD_VALUE);
        const Question = Format('Value for %s?', [Key]);
        Requests.AddElicitation(Key, Question, Schema);
      end;
    end;
  except
    Requests.Free;
    raise;
  end;

  const IsComplete = (Requests.Count = 0);
  if not IsComplete then
    raise EMCPInputRequired.Create(Requests);

  Requests.Free;
  Result := TMCPToolResult.Text('Received both inputs');
end;

{ TTaskWithInputTool }

constructor TTaskWithInputTool.Create;
begin
  inherited;
  FName := TOOL_TASK_WITH_INPUT;
  FDescription := 'Asks for a name before it creates a task, then greets it from a thread of its own';
end;

function TTaskWithInputTool.ExecuteWithContext(const Params: TNoParams; const Context: IMCPRequestContext): TValue;
begin
  raise EMCPToolError.Create('This tool only runs as a task');
end;

procedure TTaskWithInputTool.StartTask(const Arguments: TJSONObject; const Task: IMCPTaskHandle);
begin
  const Name = AskedName;
  CompleteLater(Task, Name);
end;

function TTaskWithInputTool.AskedName: string;
var
  Response: TJSONObject;
begin
  const Context = TMCPRequestContext.Current;
  Result := '';
  if Context.TryGetInputResponse(KEY_USER_NAME, Response) then
    Result := TMCPInputResponse.ElicitationField(Response, FIELD_NAME);

  const NameIsEmpty = (Result = '');
  if NameIsEmpty then
  begin
    const Schema = TMCPInputRequests.FieldSchema(FIELD_NAME);
    const Requests = TMCPInputRequests.Create;
    Requests.AddElicitation(KEY_USER_NAME, 'What is your name?', Schema);
    raise EMCPInputRequired.Create(Requests);
  end;
end;

procedure TTaskWithInputTool.CompleteLater(const Task: IMCPTaskHandle; const Name: string);
begin
  const Worker = TThread.CreateAnonymousThread(
    procedure
    begin
      TThread.Sleep(ASYNC_COMPLETION_DELAY_MS);
      const Greeting = TMCPToolResult.Text(Format('Hello, %s! (async)', [Name]));
      try
        Task.Complete(Greeting);
      finally
        Greeting.Free;
      end;
    end);
  Worker.Start;
end;

initialization
  TMCPRegistry.RegisterTool(TOOL_GREET,
    function: IMCPTool
    begin
      Result := TGreetTool.Create;
    end);
  TMCPRegistry.RegisterTool(TOOL_SLOW_COMPUTE,
    function: IMCPTool
    begin
      Result := TSlowComputeTool.Create;
    end);
  TMCPRegistry.RegisterTool(TOOL_FAILING_JOB,
    function: IMCPTool
    begin
      Result := TFailingJobTool.Create;
    end);
  TMCPRegistry.RegisterTool(TOOL_PROTOCOL_ERROR_JOB,
    function: IMCPTool
    begin
      Result := TProtocolErrorJobTool.Create;
    end);
  TMCPRegistry.RegisterTool(TOOL_CONFIRM_DELETE,
    function: IMCPTool
    begin
      Result := TConfirmDeleteTool.Create;
    end);
  TMCPRegistry.RegisterTool(TOOL_MULTI_INPUT,
    function: IMCPTool
    begin
      Result := TMultiInputTool.Create;
    end);
  TMCPRegistry.RegisterTool(TOOL_TASK_WITH_INPUT,
    function: IMCPTool
    begin
      Result := TTaskWithInputTool.Create;
    end);

end.
