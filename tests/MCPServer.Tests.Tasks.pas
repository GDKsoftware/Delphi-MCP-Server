unit MCPServer.Tests.Tasks;

interface

uses
  DUnitX.TestFramework,
  System.JSON,
  MCPServer.Types,
  MCPServer.RequestContext,
  MCPServer.JsonRpcProcessor,
  MCPServer.Task.Types,
  MCPServer.TasksManager,
  MCPServer.Tests.Harness;

type
  [TestFixture]
  TTasksTests = class
  private
    FHarness: TMCPTestHarness;
    FTasks: TMCPTasksManager;
    FTasksService: IMCPTaskService;
    FProcessor: TMCPJsonRpcProcessor;
    function Send(const Method, ParamsJson, Capabilities: string; const Hints: TMCPTransportHints): TJSONObject; overload;
    function Send(const Method, ParamsJson, Capabilities: string; const Principal: string = ''): TJSONObject; overload;
    function CallTool(const Name, ArgumentsJson, Capabilities: string): TJSONObject;
    function CreateTask(const Name, ArgumentsJson: string): string;
    function GetTask(const TaskId: string; const Principal: string = ''): TJSONObject;
    function TaskStatus(const TaskId: string): string;
    function WaitForStatus(const TaskId, Status: string): Boolean;
    function SendTaskMethod(const Method, TaskId: string; const ExtraParams: string = ''): TJSONObject;
    function ErrorCode(const Response: TJSONObject): Integer;
    procedure AnswerTask(const TaskId, InputResponses: string);

  public
    [Setup]
    procedure Setup;

    [TearDown]
    procedure TearDown;

    [Test]
    procedure Discover_AdvertisesTasksExtension;

    [Test]
    [TestCase('Get', 'tasks/get,')]
    [TestCase('Update', 'tasks/update,"inputResponses":{}')]
    [TestCase('Cancel', 'tasks/cancel,')]
    procedure TaskMethod_ClientWithoutExtension_IsMissingCapability(const Method, ExtraParams: string);

    [Test]
    procedure TasksResult_IsMethodNotFound;

    [Test]
    procedure OptionalTool_ClientWithoutExtension_RunsSynchronously;

    [Test]
    procedure OptionalTool_ClientWithExtension_ReturnsCreateTaskResult;

    [Test]
    procedure CreatedTask_IsRetrievableAtOnce;

    [Test]
    procedure CompletedTask_CarriesToolResult;

    [Test]
    procedure RequiredTool_ClientWithoutExtension_IsMissingCapability;

    [Test]
    procedure ToolError_EndsCompletedWithIsError;

    [Test]
    procedure ProtocolError_EndsFailedWithError;

    [Test]
    procedure Cancel_RunningTask_IsAcknowledgedAndCancelled;

    [Test]
    procedure Cancel_FinishedTask_IsAcknowledged;

    [Test]
    procedure InputRequired_UpdateWithAnswer_Completes;

    [Test]
    procedure InputRequired_UpdateWithUnknownKey_StaysWaiting;

    [Test]
    procedure InputRequired_PartialAnswer_KeepsRemainingRequest;

    [Test]
    procedure Starter_AsksInputBeforeTheTaskExists;

    [Test]
    procedure TasksGet_UnknownTaskId_IsInvalidParams;

    [Test]
    procedure TasksGet_OtherPrincipal_IsInvalidParams;

    [Test]
    procedure TasksGet_LegacyRequest_AsksForTheModernProtocol;

    [Test]
    procedure TasksGet_NameHeaderDiffersFromTaskId_IsHeaderMismatch;
  end;

  [TestFixture]
  TInMemoryTaskStoreTests = class
  private
    function NewTask(const TtlMs: Int64; const AgeMs: Integer): TMCPTaskSnapshot;

  public
    [Test]
    procedure TryUpdate_TerminalTask_IsRefused;

    [Test]
    procedure TryGet_ExpiredTask_IsGone;

    [Test]
    procedure TryGet_UnlimitedTtl_StaysAvailable;

    [Test]
    procedure Remove_KnownTask_IsGone;
  end;

  [TestFixture]
  TTasksHostTests = class
  public
    [Test]
    procedure TasksEnabled_AdvertisesTheExtension;

    [Test]
    procedure TasksDisabled_HasNoTasksManager;
  end;

implementation

uses
  System.SysUtils,
  System.DateUtils,
  System.RegularExpressions,
  MCPServer.Settings,
  MCPServer.Capabilities,
  MCPServer.Host,
  MCPServer.TaskStore.Memory,
  MCPServer.Tests.Support;

const
  TASK_TTL_MS = 60000;
  TASK_POLL_INTERVAL_MS = 250;
  MAX_RUNNING_TASKS = 4;
  WAIT_TIMEOUT_MS = 5000;
  PROTOCOL_VERSION = '2026-07-28';
  CAPABILITIES_NONE = '{}';
  CAPABILITIES_TASKS = '{"elicitation":{},"extensions":{"io.modelcontextprotocol/tasks":{}}}';
  STATUS_WORKING = 'working';
  STATUS_INPUT_REQUIRED = 'input_required';
  STATUS_COMPLETED = 'completed';
  STATUS_FAILED = 'failed';
  STATUS_CANCELLED = 'cancelled';
  PATH_RESULT_TYPE = 'result.resultType';
  PATH_STATUS = 'result.status';
  PATH_TASK_ID = 'result.taskId';
  PATH_FIRST_TEXT = 'result.result.content[0].text';
  TOOL_SLOW_COMPUTE = 'slow_compute';
  TOOL_CONFIRM_DELETE = 'confirm_delete';
  ARGUMENTS_ONE_SECOND = '{"seconds":1}';
  ARGUMENTS_LONG_RUN = '{"seconds":60}';
  ARGUMENTS_IMMEDIATE = '{"seconds":0,"label":"now"}';
  ARGUMENTS_FILE = '{"filename":"report.txt"}';
  ARGUMENTS_NONE = '{}';
  OWNER = 'alice';
  ISO_TIMESTAMP_PATTERN = '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}';
  RESULT_TYPE_COMPLETE = 'complete';
  TASK_ID_PARAM = '"taskId":"%s"';
  TOOL_FAILING_JOB = 'failing_job';

{ TTasksTests }

procedure TTasksTests.Setup;
begin
  FHarness := TMCPTestHarness.Create;
  FTasks := TMCPTasksManager.Create(TMCPInMemoryTaskStore.Create, TASK_TTL_MS, TASK_POLL_INTERVAL_MS,
                                    MAX_RUNNING_TASKS);
  FTasksService := FTasks;
  FHarness.ToolsManager.TaskService := FTasksService;
  FHarness.ManagerRegistry.RegisterManager(FTasks);
  FProcessor := TMCPJsonRpcProcessor.Create(FHarness.ManagerRegistry);
end;

procedure TTasksTests.TearDown;
begin
  FTasks.Shutdown;
  FProcessor.Free;
  FHarness.ToolsManager.TaskService := nil;
  FTasksService := nil;
  FHarness.Free;
end;

function TTasksTests.Send(const Method, ParamsJson, Capabilities: string;
  const Hints: TMCPTransportHints): TJSONObject;
begin
  var Params := ParamsJson;
  const HasParams = (Params <> '');
  if HasParams then
    Params := Params + ',';

  const Body = Format('{"jsonrpc":"2.0","id":1,"method":"%s","params":{%s"_meta":{' +
    '"io.modelcontextprotocol/protocolVersion":"%s",' +
    '"io.modelcontextprotocol/clientCapabilities":%s}}}', [Method, Params, PROTOCOL_VERSION, Capabilities]);
  const Outcome = FProcessor.ProcessRequestEx(Body, Hints);
  Result := TMCPTestJson.ParseObject(Outcome.Body);
end;

function TTasksTests.Send(const Method, ParamsJson, Capabilities, Principal: string): TJSONObject;
begin
  var Hints := TMCPTransportHints.None;
  Hints.Principal := Principal;
  Result := Send(Method, ParamsJson, Capabilities, Hints);
end;

function TTasksTests.CallTool(const Name, ArgumentsJson, Capabilities: string): TJSONObject;
begin
  const Params = Format('"name":"%s","arguments":%s', [Name, ArgumentsJson]);
  Result := Send(MCP_METHOD_TOOLS_CALL, Params, Capabilities);
end;

function TTasksTests.CreateTask(const Name, ArgumentsJson: string): string;
begin
  const Response = CallTool(Name, ArgumentsJson, CAPABILITIES_TASKS);
  try
    Assert.AreEqual(RESULT_TYPE_TASK, Response.GetValue<string>(PATH_RESULT_TYPE, ''), Response.ToJSON);
    Result := Response.GetValue<string>(PATH_TASK_ID);
  finally
    Response.Free;
  end;
end;

function TTasksTests.GetTask(const TaskId, Principal: string): TJSONObject;
begin
  const Params = Format(TASK_ID_PARAM, [TaskId]);
  Result := Send(MCP_METHOD_TASKS_GET, Params, CAPABILITIES_TASKS, Principal);
end;

function TTasksTests.TaskStatus(const TaskId: string): string;
begin
  const Response = GetTask(TaskId);
  try
    Result := Response.GetValue<string>(PATH_STATUS, '');
  finally
    Response.Free;
  end;
end;

function TTasksTests.WaitForStatus(const TaskId, Status: string): Boolean;
begin
  Result := TMCPTestWait.UntilTrue(
    function: Boolean
    begin
      Result := (TaskStatus(TaskId) = Status);
    end,
    WAIT_TIMEOUT_MS);
end;

function TTasksTests.SendTaskMethod(const Method, TaskId, ExtraParams: string): TJSONObject;
begin
  var Params := Format(TASK_ID_PARAM, [TaskId]);
  const HasExtraParams = (ExtraParams <> '');
  if HasExtraParams then
    Params := Params + ',' + ExtraParams;
  Result := Send(Method, Params, CAPABILITIES_TASKS);
end;

procedure TTasksTests.AnswerTask(const TaskId, InputResponses: string);
begin
  const Response = SendTaskMethod(MCP_METHOD_TASKS_UPDATE, TaskId, InputResponses);
  Response.Free;
end;

function TTasksTests.ErrorCode(const Response: TJSONObject): Integer;
begin
  Result := Response.GetValue<Integer>('error.code', 0);
end;

procedure TTasksTests.Discover_AdvertisesTasksExtension;
begin
  const Response = Send(MCP_METHOD_SERVER_DISCOVER, '', CAPABILITIES_NONE);
  try
    const Capabilities = Response.GetValue<TJSONObject>('result.capabilities');
    const Extensions = Capabilities.GetValue(MCP_KEY_EXTENSIONS) as TJSONObject;
    const Settings = Extensions.GetValue(MCP_EXTENSION_TASKS);

    Assert.IsTrue(Settings is TJSONObject);
  finally
    Response.Free;
  end;
end;

procedure TTasksTests.TaskMethod_ClientWithoutExtension_IsMissingCapability(const Method, ExtraParams: string);
begin
  var Params := '"taskId":"gate-test"';
  const HasExtraParams = (ExtraParams <> '');
  if HasExtraParams then
    Params := Params + ',' + ExtraParams;

  const Response = Send(Method, Params, CAPABILITIES_NONE);
  try
    Assert.AreEqual(MCP_ERROR_MISSING_REQUIRED_CLIENT_CAPABILITY, ErrorCode(Response));
  finally
    Response.Free;
  end;
end;

procedure TTasksTests.TasksResult_IsMethodNotFound;
begin
  const Response = SendTaskMethod('tasks/result', 'probe');
  try
    Assert.AreEqual(JSONRPC_METHOD_NOT_FOUND, ErrorCode(Response));
  finally
    Response.Free;
  end;
end;

procedure TTasksTests.OptionalTool_ClientWithoutExtension_RunsSynchronously;
begin
  const Response = CallTool(TOOL_SLOW_COMPUTE, ARGUMENTS_IMMEDIATE, CAPABILITIES_NONE);
  try
    const ResultType = Response.GetValue<string>(PATH_RESULT_TYPE);
    const TaskId = Response.GetValue<string>(PATH_TASK_ID, '');

    Assert.AreEqual(RESULT_TYPE_COMPLETE, ResultType);
    Assert.AreEqual('', TaskId);
    Assert.Contains(Response.GetValue<string>('result.content[0].text'), 'now');
  finally
    Response.Free;
  end;
end;

procedure TTasksTests.OptionalTool_ClientWithExtension_ReturnsCreateTaskResult;
begin
  const Response = CallTool(TOOL_SLOW_COMPUTE, ARGUMENTS_LONG_RUN, CAPABILITIES_TASKS);
  try
    const Created = Response.GetValue<TJSONObject>(MCP_KEY_RESULT);

    Assert.AreEqual(RESULT_TYPE_TASK, Created.GetValue<string>(MCP_KEY_RESULT_TYPE));
    Assert.AreEqual(STATUS_WORKING, Created.GetValue<string>('status'));
    const TaskId = Created.GetValue<string>(MCP_KEY_TASK_ID);
    const CreatedAt = Created.GetValue<string>('createdAt');
    const LastUpdatedAt = Created.GetValue<string>('lastUpdatedAt');
    Assert.IsTrue(TaskId.Length >= 40);
    Assert.IsTrue(TRegEx.IsMatch(CreatedAt, ISO_TIMESTAMP_PATTERN));
    Assert.IsTrue(TRegEx.IsMatch(LastUpdatedAt, ISO_TIMESTAMP_PATTERN));
    Assert.AreEqual(Int64(TASK_TTL_MS), Created.GetValue<Int64>(MCP_KEY_TTL_MS));
    Assert.AreEqual(TASK_POLL_INTERVAL_MS, Created.GetValue<Integer>('pollIntervalMs'));
    Assert.IsNull(Created.GetValue(MCP_KEY_RESULT));
    Assert.IsNull(Created.GetValue('requestState'));
  finally
    Response.Free;
  end;
end;

procedure TTasksTests.CreatedTask_IsRetrievableAtOnce;
begin
  const TaskId = CreateTask(TOOL_SLOW_COMPUTE, ARGUMENTS_LONG_RUN);

  const Response = GetTask(TaskId);
  try
    Assert.AreEqual(RESULT_TYPE_COMPLETE, Response.GetValue<string>(PATH_RESULT_TYPE));
    Assert.AreEqual(TaskId, Response.GetValue<string>(PATH_TASK_ID));
  finally
    Response.Free;
  end;
end;

procedure TTasksTests.CompletedTask_CarriesToolResult;
begin
  const TaskId = CreateTask(TOOL_SLOW_COMPUTE, ARGUMENTS_IMMEDIATE);

  Assert.IsTrue(WaitForStatus(TaskId, STATUS_COMPLETED));
  const Response = GetTask(TaskId);
  try
    const Task = Response.GetValue<TJSONObject>(MCP_KEY_RESULT);
    Assert.Contains(Response.GetValue<string>(PATH_FIRST_TEXT), 'now');
    Assert.IsNull(Task.GetValue(MCP_KEY_ERROR));
  finally
    Response.Free;
  end;
end;

procedure TTasksTests.RequiredTool_ClientWithoutExtension_IsMissingCapability;
begin
  const Response = CallTool(TOOL_FAILING_JOB, ARGUMENTS_NONE, CAPABILITIES_NONE);
  try
    const Required = Response.GetValue<TJSONObject>('error.data.requiredCapabilities.extensions');
    const Settings = Required.GetValue(MCP_EXTENSION_TASKS);

    Assert.AreEqual(MCP_ERROR_MISSING_REQUIRED_CLIENT_CAPABILITY, ErrorCode(Response));
    Assert.IsTrue(Settings is TJSONObject);
  finally
    Response.Free;
  end;
end;

procedure TTasksTests.ToolError_EndsCompletedWithIsError;
begin
  const TaskId = CreateTask(TOOL_FAILING_JOB, ARGUMENTS_NONE);

  Assert.IsTrue(WaitForStatus(TaskId, STATUS_COMPLETED));
  const Response = GetTask(TaskId);
  try
    Assert.IsTrue(Response.GetValue<Boolean>('result.result.isError'));
  finally
    Response.Free;
  end;
end;

procedure TTasksTests.ProtocolError_EndsFailedWithError;
begin
  const TaskId = CreateTask('protocol_error_job', ARGUMENTS_NONE);

  Assert.IsTrue(WaitForStatus(TaskId, STATUS_FAILED));
  const Response = GetTask(TaskId);
  try
    const Task = Response.GetValue<TJSONObject>(MCP_KEY_RESULT);

    Assert.AreEqual(JSONRPC_INTERNAL_ERROR, Task.GetValue<Integer>('error.code'));
    Assert.IsNotEmpty(Task.GetValue<string>('error.message'));
    Assert.IsNull(Task.GetValue(MCP_KEY_RESULT));
  finally
    Response.Free;
  end;
end;

procedure TTasksTests.Cancel_RunningTask_IsAcknowledgedAndCancelled;
begin
  const TaskId = CreateTask(TOOL_SLOW_COMPUTE, ARGUMENTS_LONG_RUN);

  const Response = SendTaskMethod(MCP_METHOD_TASKS_CANCEL, TaskId);
  try
    const Ack = Response.GetValue<TJSONObject>(MCP_KEY_RESULT);

    Assert.AreEqual(RESULT_TYPE_COMPLETE, Ack.GetValue<string>(MCP_KEY_RESULT_TYPE));
    Assert.IsNull(Ack.GetValue(MCP_KEY_TASK_ID));
    Assert.IsNull(Ack.GetValue('status'));
  finally
    Response.Free;
  end;
  Assert.AreEqual(STATUS_CANCELLED, TaskStatus(TaskId));
end;

procedure TTasksTests.Cancel_FinishedTask_IsAcknowledged;
begin
  const TaskId = CreateTask(TOOL_SLOW_COMPUTE, ARGUMENTS_IMMEDIATE);
  Assert.IsTrue(WaitForStatus(TaskId, STATUS_COMPLETED));

  const Response = SendTaskMethod(MCP_METHOD_TASKS_CANCEL, TaskId);
  try
    Assert.AreEqual(RESULT_TYPE_COMPLETE, Response.GetValue<string>(PATH_RESULT_TYPE));
  finally
    Response.Free;
  end;
  Assert.AreEqual(STATUS_COMPLETED, TaskStatus(TaskId));
end;

procedure TTasksTests.InputRequired_UpdateWithAnswer_Completes;
begin
  const TaskId = CreateTask(TOOL_CONFIRM_DELETE, ARGUMENTS_FILE);
  Assert.IsTrue(WaitForStatus(TaskId, STATUS_INPUT_REQUIRED));

  const Waiting = GetTask(TaskId);
  try
    Assert.AreEqual('elicitation/create', Waiting.GetValue<string>('result.inputRequests.confirm.method'));
  finally
    Waiting.Free;
  end;

  const Answer = '"inputResponses":{"confirm":{"action":"accept","content":{"confirm":true}}}';
  AnswerTask(TaskId, Answer);

  Assert.IsTrue(WaitForStatus(TaskId, STATUS_COMPLETED));
  const Response = GetTask(TaskId);
  try
    Assert.AreEqual('Deleted report.txt', Response.GetValue<string>(PATH_FIRST_TEXT));
  finally
    Response.Free;
  end;
end;

procedure TTasksTests.InputRequired_UpdateWithUnknownKey_StaysWaiting;
begin
  const TaskId = CreateTask(TOOL_CONFIRM_DELETE, ARGUMENTS_FILE);
  Assert.IsTrue(WaitForStatus(TaskId, STATUS_INPUT_REQUIRED));

  const Response = SendTaskMethod(MCP_METHOD_TASKS_UPDATE, TaskId, '"inputResponses":{"unknown-key":{"ignored":true}}');
  try
    Assert.AreEqual(RESULT_TYPE_COMPLETE, Response.GetValue<string>(PATH_RESULT_TYPE));
  finally
    Response.Free;
  end;
  Assert.AreEqual(STATUS_INPUT_REQUIRED, TaskStatus(TaskId));
end;

procedure TTasksTests.InputRequired_PartialAnswer_KeepsRemainingRequest;
begin
  const TaskId = CreateTask('multi_input', ARGUMENTS_NONE);
  Assert.IsTrue(WaitForStatus(TaskId, STATUS_INPUT_REQUIRED));

  const FirstAnswer = '"inputResponses":{"input-a":{"action":"accept","content":{"value":"one"}}}';
  AnswerTask(TaskId, FirstAnswer);

  const Waiting = GetTask(TaskId);
  try
    const Requests = Waiting.GetValue<TJSONObject>('result.inputRequests');

    Assert.AreEqual(STATUS_INPUT_REQUIRED, Waiting.GetValue<string>(PATH_STATUS));
    Assert.IsNull(Requests.GetValue('input-a'));
    Assert.IsNotNull(Requests.GetValue('input-b'));
  finally
    Waiting.Free;
  end;

  const SecondAnswer = '"inputResponses":{"input-b":{"action":"accept","content":{"value":"two"}}}';
  AnswerTask(TaskId, SecondAnswer);
  Assert.IsTrue(WaitForStatus(TaskId, STATUS_COMPLETED));
end;

procedure TTasksTests.Starter_AsksInputBeforeTheTaskExists;
begin
  const FirstRound = CallTool('test_tool_with_task', ARGUMENTS_NONE, CAPABILITIES_TASKS);
  try
    const Answer = FirstRound.GetValue<TJSONObject>(MCP_KEY_RESULT);
    Assert.AreEqual(STATUS_INPUT_REQUIRED, Answer.GetValue<string>(MCP_KEY_RESULT_TYPE));
    Assert.IsNull(Answer.GetValue(MCP_KEY_TASK_ID));
  finally
    FirstRound.Free;
  end;

  const Params = '"name":"test_tool_with_task","arguments":{},' +
    '"inputResponses":{"user_name":{"action":"accept","content":{"name":"Alice"}}}';
  const SecondRound = Send(MCP_METHOD_TOOLS_CALL, Params, CAPABILITIES_TASKS);
  var TaskId := '';
  try
    Assert.AreEqual(RESULT_TYPE_TASK, SecondRound.GetValue<string>(PATH_RESULT_TYPE));
    TaskId := SecondRound.GetValue<string>(PATH_TASK_ID);
  finally
    SecondRound.Free;
  end;

  Assert.IsTrue(WaitForStatus(TaskId, STATUS_COMPLETED));
  const Response = GetTask(TaskId);
  try
    Assert.AreEqual('Hello, Alice! (async)', Response.GetValue<string>(PATH_FIRST_TEXT));
  finally
    Response.Free;
  end;
end;

procedure TTasksTests.TasksGet_UnknownTaskId_IsInvalidParams;
begin
  const Response = GetTask('tasks-conformance-nonexistent-12345');
  try
    Assert.AreEqual(JSONRPC_INVALID_PARAMS, ErrorCode(Response));
  finally
    Response.Free;
  end;
end;

procedure TTasksTests.TasksGet_OtherPrincipal_IsInvalidParams;
begin
  const Params = Format('"name":"%s","arguments":%s', [TOOL_SLOW_COMPUTE, ARGUMENTS_LONG_RUN]);
  const Created = Send(MCP_METHOD_TOOLS_CALL, Params, CAPABILITIES_TASKS, OWNER);
  var TaskId := '';
  try
    TaskId := Created.GetValue<string>(PATH_TASK_ID);
  finally
    Created.Free;
  end;

  const AsOwner = GetTask(TaskId, OWNER);
  const AsStranger = GetTask(TaskId, 'mallory');
  try
    Assert.AreEqual(TaskId, AsOwner.GetValue<string>(PATH_TASK_ID));
    Assert.AreEqual(JSONRPC_INVALID_PARAMS, ErrorCode(AsStranger));
  finally
    AsOwner.Free;
    AsStranger.Free;
  end;
end;

procedure TTasksTests.TasksGet_LegacyRequest_AsksForTheModernProtocol;
begin
  const Body = '{"jsonrpc":"2.0","id":1,"method":"tasks/get","params":{"taskId":"probe"}}';
  const Outcome = FProcessor.ProcessRequestEx(Body, TMCPTransportHints.ForHttp(True, '2025-11-25'));
  const Response = TMCPTestJson.ParseObject(Outcome.Body);
  try
    Assert.AreEqual(JSONRPC_INVALID_PARAMS, ErrorCode(Response));
  finally
    Response.Free;
  end;
end;

procedure TTasksTests.TasksGet_NameHeaderDiffersFromTaskId_IsHeaderMismatch;
begin
  const TaskId = CreateTask(TOOL_SLOW_COMPUTE, ARGUMENTS_LONG_RUN);

  var Hints := TMCPTransportHints.ForHttp(True, PROTOCOL_VERSION);
  Hints.HasMethodHeader := True;
  Hints.MethodHeader := MCP_METHOD_TASKS_GET;
  Hints.HasNameHeader := True;
  Hints.NameHeader := 'some-other-task';
  const Params = Format(TASK_ID_PARAM, [TaskId]);
  const Response = Send(MCP_METHOD_TASKS_GET, Params, CAPABILITIES_TASKS, Hints);
  try
    Assert.AreEqual(MCP_ERROR_HEADER_MISMATCH, ErrorCode(Response));
  finally
    Response.Free;
  end;
end;

{ TInMemoryTaskStoreTests }

function TInMemoryTaskStoreTests.NewTask(const TtlMs: Int64; const AgeMs: Integer): TMCPTaskSnapshot;
begin
  Result := Default(TMCPTaskSnapshot);
  Result.TaskId := TGUID.NewGuid.ToString;
  Result.Status := TMCPTaskStatus.Working;
  Result.CreatedAt := IncMilliSecond(TMCPTaskSnapshot.NowUtc, -AgeMs);
  Result.LastUpdatedAt := Result.CreatedAt;
  Result.TtlMs := TtlMs;
end;

procedure TInMemoryTaskStoreTests.TryUpdate_TerminalTask_IsRefused;
begin
  const Store: IMCPTaskStore = TMCPInMemoryTaskStore.Create;
  var Task := NewTask(TASK_TTL_MS, 0);
  Store.Add(Task);
  Task.Status := TMCPTaskStatus.Completed;
  Assert.IsTrue(Store.TryUpdate(Task));

  Task.Status := TMCPTaskStatus.Cancelled;
  const IsUpdated = Store.TryUpdate(Task);

  var Stored: TMCPTaskSnapshot;
  Assert.IsFalse(IsUpdated);
  Assert.IsTrue(Store.TryGet(Task.TaskId, Stored));
  Assert.AreEqual(Ord(TMCPTaskStatus.Completed), Ord(Stored.Status));
end;

procedure TInMemoryTaskStoreTests.TryGet_ExpiredTask_IsGone;
begin
  const Store: IMCPTaskStore = TMCPInMemoryTaskStore.Create;
  const Task = NewTask(1000, 2000);
  Store.Add(Task);

  var Stored: TMCPTaskSnapshot;
  const IsFound = Store.TryGet(Task.TaskId, Stored);

  Assert.IsFalse(IsFound);
end;

procedure TInMemoryTaskStoreTests.TryGet_UnlimitedTtl_StaysAvailable;
begin
  const Store: IMCPTaskStore = TMCPInMemoryTaskStore.Create;
  const Task = NewTask(0, 24 * 60 * 60 * 1000);
  Store.Add(Task);

  var Stored: TMCPTaskSnapshot;
  const IsFound = Store.TryGet(Task.TaskId, Stored);

  Assert.IsTrue(IsFound);
end;

procedure TInMemoryTaskStoreTests.Remove_KnownTask_IsGone;
begin
  const Store: IMCPTaskStore = TMCPInMemoryTaskStore.Create;
  const Task = NewTask(TASK_TTL_MS, 0);
  Store.Add(Task);

  Store.Remove(Task.TaskId);

  var Stored: TMCPTaskSnapshot;
  Assert.IsFalse(Store.TryGet(Task.TaskId, Stored));
end;

{ TTasksHostTests }

procedure TTasksHostTests.TasksEnabled_AdvertisesTheExtension;
begin
  const Host = TMCPServerHost.Create;
  try
    Host.Settings.TasksEnabled := True;

    const Capabilities = TMCPCapabilityBuilder.Build(Host.ManagerRegistry, TMCPProtocolEra.Modern);
    try
      const Extensions = Capabilities.GetValue(MCP_KEY_EXTENSIONS) as TJSONObject;

      Assert.IsNotNull(Host.Tasks);
      Assert.IsTrue(Extensions.GetValue(MCP_EXTENSION_TASKS) is TJSONObject);
    finally
      Capabilities.Free;
    end;
  finally
    Host.Free;
  end;
end;

procedure TTasksHostTests.TasksDisabled_HasNoTasksManager;
begin
  const Host = TMCPServerHost.Create;
  try
    const Capabilities = TMCPCapabilityBuilder.Build(Host.ManagerRegistry, TMCPProtocolEra.Modern);
    try
      Assert.IsNull(Host.Tasks);
      Assert.IsNull(Capabilities.GetValue(MCP_KEY_EXTENSIONS));
    finally
      Capabilities.Free;
    end;
  finally
    Host.Free;
  end;
end;

end.
