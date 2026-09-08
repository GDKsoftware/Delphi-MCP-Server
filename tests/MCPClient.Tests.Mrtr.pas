unit MCPClient.Tests.Mrtr;

// What a tool call does while it is in flight: it answers the server's requests for input, it
// hands the notifications that arrive beside the answer to the sink, and it gives up when the
// caller cancels.
//
// TMCPClientMrtrTests and TMCPClientSinkTests drive a real TMCPServerHost on an ephemeral port, so
// the requestState the client echoes is a real signed token, the capability check is the server's
// own and an answer the server cannot read shows up as a failing test rather than as a passing
// one. Cancellation needs a server that is still writing when the caller changes its mind, which
// no request-response fixture can be, so TStreamingStub streams one notification and then holds
// its connection open until the cancellation arrives on another one.
//
// What cancels a call over HTTP is the closed stream, not the notifications/cancelled that goes
// out beside it, and TCancelWatchTool proves both halves of that against a real TMCPServerHost:
// the tool sees its request cancelled when the client abandons the read, and it runs on when the
// notification arrives by itself on a second connection.

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.JSON,
  System.Rtti,
  System.Generics.Collections,
  IdContext,
  IdCustomHTTPServer,
  IdHTTPServer,
  DUnitX.TestFramework,
  MCPServer.Types,
  MCPServer.Tool.Base,
  MCPServer.Tool.ContentSamples,
  MCPServer.Host,
  MCPClient.Types,
  MCPClient.Interfaces,
  MCPClient;

type
  TTopicParams = class
  private
    FTopic: string;
  public
    property Topic: string read FTopic write FTopic;
  end;

  { Takes an argument and asks for input, so that the name and the arguments the server signs into
    its requestState are not both empty and a round that dropped them would be refused. }
  TTopicInputTool = class(TMCPToolBase<TTopicParams>)
  protected
    function ExecuteWithContext(const Params: TTopicParams;
      const Context: IMCPRequestContext): TValue; override;
  public
    constructor Create; override;
  end;

  { Reports one step and then logs one line, which is one notification of each kind in the order a
    caller sees them. }
  TSinkSampleTool = class(TMCPToolBase<TNoParams>)
  protected
    function ExecuteWithContext(const Params: TNoParams;
      const Context: IMCPRequestContext): TValue; override;
  public
    constructor Create; override;
  end;

  { Reports progress without a total, which is a server saying it is working and not saying how
    much is left. }
  TOpenEndedProgressTool = class(TMCPToolBase<TNoParams>)
  protected
    function ExecuteWithContext(const Params: TNoParams;
      const Context: IMCPRequestContext): TValue; override;
  public
    constructor Create; override;
  end;

  { Runs until the test releases it or its request is cancelled, and remembers which of the two
    happened. Reporting progress on every step is what makes a closed connection visible to the
    server: the write fails, and MCPServer.HttpStream cancels the request the tool is running. }
  TCancelWatchTool = class(TMCPToolBase<TNoParams>)
  strict private
    FStarted: TEvent;
    FRelease: TEvent;
    FCancelSeen: TEvent;
    FRequestId: string;
  protected
    function ExecuteWithContext(const Params: TNoParams;
      const Context: IMCPRequestContext): TValue; override;
  public
    constructor Create; override;
    destructor Destroy; override;

    function WaitForStart(const TimeoutMs: Cardinal): Boolean;
    function WaitForCancellation(const TimeoutMs: Cardinal): Boolean;
    function SawCancellation: Boolean;
    procedure Release;

    { The id the server gave this request, which is what a notifications/cancelled has to name.
      Written before the start is signalled, so a test that waited for the start may read it. }
    property RequestId: string read FRequestId;
  end;

  TSinkEvent = record
    Kind: string;
    Token: string;
    Progress: Double;
    Total: Double;
    Text: string;
    Level: string;
    Logger: string;
    AfterTheCall: Boolean;
  end;

  { Records every notification and, with each one, whether the call it belongs to had already
    returned. That is what turns "before the result" into an assertion. }
  TRecordingSink = class(TInterfacedObject, IMCPClientSink)
  strict private
    FEvents: TList<TSinkEvent>;
    FCallFinished: Boolean;
    procedure Add(const Event: TSinkEvent);
  public
    constructor Create;
    destructor Destroy; override;

    procedure Progress(const Token: string; const Progress, Total: Double; const Message: string);
    procedure LogMessage(const Level, Logger, DataJson: string);

    function CountOf(const Kind: string): Integer;
    function First(const Kind: string): TSinkEvent;
    function AnyAfterTheCall: Boolean;

    property CallFinished: Boolean read FCallFinished write FCallFinished;
  end;

  { Streams one notification for a tools/call and then holds the connection open until a
    cancellation for that call arrives on another one. }
  TStreamingStub = class
  strict private
    FServer: TIdHTTPServer;
    FLock: TCriticalSection;
    FCancellations: TArray<string>;
    FStreaming: Boolean;
    FCancelledWhileStreaming: Boolean;
    FAlwaysAsksForInput: Boolean;
    FRefusesCancellations: Boolean;
    procedure HandleCommand(Context: TIdContext; RequestInfo: TIdHTTPRequestInfo;
      ResponseInfo: TIdHTTPResponseInfo);
    procedure StreamCall(Context: TIdContext; ResponseInfo: TIdHTTPResponseInfo; const Id: string);
    procedure Reply(ResponseInfo: TIdHTTPResponseInfo; const Body: string);
    procedure Remember(const Body: string);
    procedure SetStreaming(const Value: Boolean);
    class function ReadBody(RequestInfo: TIdHTTPRequestInfo): string; static;
    class function MethodOf(const Body: string; out Id: string): string; static;
  public
    constructor Create;
    destructor Destroy; override;

    function Url: string;
    function CancellationCount: Integer;
    function Cancellation(const Index: Integer): string;
    { True when the cancellation arrived while this stub was still inside the streamed answer,
      which is the connection the client abandoned. }
    function CancelledWhileStreaming: Boolean;

    { True makes every tools/call answer input_required, which is the one answer a real server
      never gives a client that declared it cannot be asked. }
    property AlwaysAsksForInput: Boolean read FAlwaysAsksForInput write FAlwaysAsksForInput;
    { True answers the cancellation with 500, which is a server the client cannot tell. }
    property RefusesCancellations: Boolean read FRefusesCancellations write FRefusesCancellations;
  end;

  [TestFixture]
  TMCPClientMrtrTests = class
  private
    FHost: TMCPServerHost;
    FClient: IMCPClient;
    FTrace: TMCPClient;
    FStub: TStreamingStub;
    FRequests: TArray<string>;
    FResponses: TArray<string>;
    FAsked: TArray<string>;
    FAnswered: Boolean;
    function Url: string;
    function Options: TMCPClientOptions;
    procedure NewClient(const AOptions: TMCPClientOptions);
    procedure NewClientFor(const ServerUrl: string; const AOptions: TMCPClientOptions);
    procedure RespondWith(const Responder: TMCPInputResponder);
    procedure RespondAsAHost;
    function Answer(const Key, Method: string; const Params: TJSONObject): TJSONObject;
    function Elicitation(const Params: TJSONObject): TJSONObject;
    function Sampling: TJSONObject;
    function Roots: TJSONObject;
    function CallTopic(const Topic: string): TMCPToolCallOutcome;
    function CallCount: Integer;
    function Request(const Index: Integer): TJSONObject;
    function RequestParam(const Index: Integer; const Name: string): string;
    function ResponseMember(const Index, Depth: Integer; const Name: string): string;
    class function FirstRequiredField(const Params: TJSONObject): string; static;
    class function Member(const Owner: TJSONObject; const Name: string): string; static;
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    [Test]
    procedure Elicitation_OneRound_AnswersAndCompletes;

    [Test]
    procedure Elicitation_Responder_SeesTheKeyTheMethodAndTheParams;

    [Test]
    procedure MultiRound_TwoRounds_CompletesWithThreeCalls;

    [Test]
    procedure MultiRound_EveryRound_RepeatsTheNameAndTheArguments;

    [Test]
    procedure RequestState_IsEchoedByteForByte;

    [Test]
    procedure RequestState_TheServerAcceptsWhatCameBack;

    [Test]
    procedure MultipleInputs_EveryKeyIsAnsweredInOneRound;

    [Test]
    procedure Sampling_RoundTrips;

    [Test]
    procedure ListRoots_RoundTrips;

    [Test]
    procedure WithoutAResponder_IsAnErrorOutcomeAndNotAnException;

    [Test]
    procedure ResponderThatAnswersNothing_IsAnErrorOutcome;

    [Test]
    procedure MoreRoundsThanAllowed_StopsAtMaxInputRounds;

    [Test]
    procedure LegacyEra_InputRequired_SurfacesTheServerMessageUnchanged;
  end;

  [TestFixture]
  TMCPClientSinkTests = class
  private
    FHost: TMCPServerHost;
    FClient: IMCPClient;
    FTrace: TMCPClient;
    FSink: TRecordingSink;
    FBodies: TArray<string>;
    function Url: string;
    function Options: TMCPClientOptions;
    procedure NewClient(const AOptions: TMCPClientOptions);
    function CallWithTheSink(const Tool: string): TMCPToolCallOutcome;
    function LastMeta: TJSONObject;
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    [Test]
    procedure Progress_ReachesTheSinkBeforeTheResult;

    [Test]
    procedure Progress_CarriesTheTokenTheRequestAskedFor;

    [Test]
    procedure Progress_WithoutATotal_ReportsThatTheTotalIsUnknown;

    [Test]
    procedure LogMessage_ReachesTheSink;

    [Test]
    procedure WithoutALogLevel_TheServerSendsNoLogMessages;

    [Test]
    procedure WithoutASink_NoProgressTokenIsAskedFor;

    [Test]
    procedure WithASink_AProgressTokenIsAskedFor;
  end;

  [TestFixture]
  TMCPClientCancellationTests = class
  private
    FHost: TMCPServerHost;
    FStub: TStreamingStub;
    FSink: TRecordingSink;
    FClient: IMCPClient;
    FTrace: TMCPClient;
    FBodies: TArray<string>;
    FCancelled: Boolean;
    FWatch: TCancelWatchTool;
    FWatchTool: IMCPTool;
    FNotifiedStatus: Integer;
    procedure NewClient(const ServerUrl: string);
    procedure CancelFromNowOn;
    function LastBody: string;
    function StartCancellingNotifier: TThread;
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    [Test]
    procedure CancelledDuringTheStream_IsACancelledOutcome;

    [Test]
    procedure ACheckThatStaysFalse_LeavesTheCallAlone;

    [Test]
    procedure Cancellation_ReachesTheServerOnASecondConnection;

    [Test]
    procedure Cancellation_IsSentOnceForOneCall;

    [Test]
    procedure ACancellationTheServerRefuses_IsInTheOutcome;

    [Test]
    procedure ClosingTheStream_CancelsTheToolOnTheServer;

    [Test]
    procedure ACancellationOnASecondConnection_IsAcceptedAndTheToolRunsOn;
  end;

implementation

uses
  IdHTTP,
  MCPServer.Errors,
  MCPServer.Mrtr,
  MCPServer.HttpStream,
  MCPServer.Registration,
  MCPServer.Tool.Result,
  MCPServer.Tests.Support;

const
  LOOPBACK = '127.0.0.1';
  ENDPOINT = '/mcp';
  URL_TEMPLATE = 'http://%s:%d%s';

  TOOL_ELICITATION = 'test_input_required_result_elicitation';
  TOOL_SAMPLING = 'test_input_required_result_sampling';
  TOOL_LIST_ROOTS = 'test_input_required_result_list_roots';
  TOOL_MULTIPLE_INPUTS = 'test_input_required_result_multiple_inputs';
  TOOL_MULTI_ROUND = 'test_input_required_result_multi_round';
  TOOL_TOPIC = 'test_topic_input';
  TOOL_SINK = 'test_sink_sample';
  TOOL_OPEN_ENDED = 'test_open_ended_progress';
  TOOL_PROGRESS = 'test_tool_with_progress';
  TOOL_SIMPLE_TEXT = 'test_simple_text';
  TOOL_CANCEL_WATCH = 'test_cancel_watch';

  KEY_ANSWER = 'topic_owner';
  KEY_ACTION = 'action';
  KEY_CONTENT = 'content';
  KEY_ROLE = 'role';
  KEY_MODEL = 'model';
  KEY_STOP_REASON = 'stopReason';
  KEY_REQUESTED_SCHEMA = 'requestedSchema';
  KEY_REQUIRED = 'required';
  KEY_ROOTS = 'roots';
  KEY_MESSAGE = 'message';
  KEY_RESULT_STATE = 'requestState';

  FIELD_NAME = 'name';
  FIELD_COLOR = 'color';
  FIELD_OK = 'ok';

  ACTION_ACCEPT = 'accept';
  ROLE_ASSISTANT = 'assistant';
  TYPE_TEXT = 'text';
  SAMPLED_TEXT = 'Bonjour';
  SAMPLING_MODEL = 'test-model';
  STOP_REASON_END_TURN = 'endTurn';
  ROOT_URI = 'file:///workspace';
  ROOT_NAME = 'Workspace';

  ANSWER_NAME = 'Ada';
  ANSWER_COLOR = 'blue';
  TOPIC = 'the release';

  LOG_LEVEL_INFO = 'info';
  LOG_LEVEL_WARNING = 'warning';
  LOG_LINE = 'the sink should see this';
  LOGGER_NAME = 'sink-tool';
  SINK_ANSWER = 'the sink tool ran';
  OPEN_ENDED_ANSWER = 'the open ended tool ran';
  OPEN_ENDED_PROGRESS = 7.0;
  SINK_PROGRESS = 1.0;
  SINK_TOTAL = 3.0;
  PROGRESS_STEP_MESSAGE = 'the first step';

  KIND_PROGRESS = 'progress';
  KIND_LOG = 'log';
  TOTAL_UNKNOWN = -1.0;
  TOLERANCE = 0.0001;

  ID_TOKEN = '%ID%';
  DISCOVER_RESULT =
    '{"jsonrpc":"2.0","id":' + ID_TOKEN + ',"result":{"resultType":"complete",' +
    '"supportedVersions":["' + MCP_LATEST_PROTOCOL_VERSION + '"],"capabilities":{},' +
    '"_meta":{"io.modelcontextprotocol/serverInfo":{"name":"stub","version":"1.0.0"}}}}';
  PROGRESS_NOTIFICATION =
    '{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":' + ID_TOKEN +
    ',"progress":1,"total":4,"message":"working"}}';
  LATE_RESULT =
    '{"jsonrpc":"2.0","id":' + ID_TOKEN + ',"result":{"content":[{"type":"text","text":"too late"}]}}';
  INPUT_REQUIRED_RESULT =
    '{"jsonrpc":"2.0","id":' + ID_TOKEN + ',"result":{"resultType":"input_required",' +
    '"inputRequests":{"user_name":{"method":"elicitation/create","params":{"mode":"form",' +
    '"message":"What is your name?","requestedSchema":{"type":"object",' +
    '"properties":{"name":{"type":"string"}},"required":["name"]}}}},' +
    '"requestState":"v1.stub-state"}}';

  STREAM_WAIT_MS = 4000;
  STATUS_SERVER_ERROR = 500;

  WATCH_STEPS = 200;
  WATCH_STEP_MS = 25;
  WATCH_WAIT_MS = 5000;
  WATCH_STEP_MESSAGE = 'still working';
  WATCH_ANSWER = 'the watch tool ran to the end';
  CANCEL_NOTIFICATION =
    '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":%s,' +
    '"reason":"a second connection"}}';

{ TTopicInputTool }

constructor TTopicInputTool.Create;
begin
  inherited;
  FName := TOOL_TOPIC;
  FDescription := 'Asks who should hear about a topic, and answers once it knows';
end;

function TTopicInputTool.ExecuteWithContext(const Params: TTopicParams;
  const Context: IMCPRequestContext): TValue;
var
  Response: TJSONObject;
begin
  var Owner := '';
  if Context.TryGetInputResponse(KEY_ANSWER, Response) then
    Owner := TMCPInputResponse.ElicitationField(Response, FIELD_NAME);

  const IsUnanswered = (Owner = '');
  if IsUnanswered then
  begin
    const State = TJSONObject.Create;
    State.AddPair('topic', Params.Topic);
    raise EMCPInputRequired.Create(TMCPInputRequests.Create
      .AddElicitation(KEY_ANSWER, Format('Who should hear about %s?', [Params.Topic]),
        TMCPInputRequests.FieldSchema(FIELD_NAME)), State);
  end;

  Result := TMCPToolResult.Text(Format('%s hears about %s', [Owner, Params.Topic]));
end;

{ TSinkSampleTool }

constructor TSinkSampleTool.Create;
begin
  inherited;
  FName := TOOL_SINK;
  FDescription := 'Reports one step and logs one line while it runs';
end;

function TSinkSampleTool.ExecuteWithContext(const Params: TNoParams;
  const Context: IMCPRequestContext): TValue;
begin
  Context.ReportProgress(SINK_PROGRESS, SINK_TOTAL, PROGRESS_STEP_MESSAGE);
  Context.Log(LOG_LEVEL_WARNING, LOG_LINE, LOGGER_NAME);
  Result := TMCPToolResult.Text(SINK_ANSWER);
end;

{ TOpenEndedProgressTool }

constructor TOpenEndedProgressTool.Create;
begin
  inherited;
  FName := TOOL_OPEN_ENDED;
  FDescription := 'Reports progress without saying how much work there is';
end;

function TOpenEndedProgressTool.ExecuteWithContext(const Params: TNoParams;
  const Context: IMCPRequestContext): TValue;
begin
  Context.ReportProgress(OPEN_ENDED_PROGRESS);
  Result := TMCPToolResult.Text(OPEN_ENDED_ANSWER);
end;

{ TCancelWatchTool }

constructor TCancelWatchTool.Create;
begin
  inherited;
  FName := TOOL_CANCEL_WATCH;
  FDescription := 'Reports progress until the caller goes away or the test releases it';
  FStarted := TEvent.Create(nil, True, False, '');
  FRelease := TEvent.Create(nil, True, False, '');
  FCancelSeen := TEvent.Create(nil, True, False, '');
end;

destructor TCancelWatchTool.Destroy;
begin
  FCancelSeen.Free;
  FRelease.Free;
  FStarted.Free;
  inherited;
end;

function TCancelWatchTool.ExecuteWithContext(const Params: TNoParams;
  const Context: IMCPRequestContext): TValue;
begin
  FRequestId := Context.RequestId.AsText;
  FStarted.SetEvent;

  for var Step := 1 to WATCH_STEPS do
  begin
    if Context.IsCancelled then
    begin
      FCancelSeen.SetEvent;
      Break;
    end;

    Context.ReportProgress(Step, WATCH_STEPS, WATCH_STEP_MESSAGE);

    if FRelease.WaitFor(WATCH_STEP_MS) = TWaitResult.wrSignaled then
      Break;
  end;

  Result := TMCPToolResult.Text(WATCH_ANSWER);
end;

function TCancelWatchTool.WaitForStart(const TimeoutMs: Cardinal): Boolean;
begin
  Result := (FStarted.WaitFor(TimeoutMs) = TWaitResult.wrSignaled);
end;

function TCancelWatchTool.WaitForCancellation(const TimeoutMs: Cardinal): Boolean;
begin
  Result := (FCancelSeen.WaitFor(TimeoutMs) = TWaitResult.wrSignaled);
end;

function TCancelWatchTool.SawCancellation: Boolean;
begin
  Result := (FCancelSeen.WaitFor(0) = TWaitResult.wrSignaled);
end;

procedure TCancelWatchTool.Release;
begin
  FRelease.SetEvent;
end;

{ TRecordingSink }

constructor TRecordingSink.Create;
begin
  inherited Create;
  FEvents := TList<TSinkEvent>.Create;
end;

destructor TRecordingSink.Destroy;
begin
  FEvents.Free;
  inherited;
end;

procedure TRecordingSink.Add(const Event: TSinkEvent);
begin
  var Recorded := Event;
  Recorded.AfterTheCall := FCallFinished;
  FEvents.Add(Recorded);
end;

procedure TRecordingSink.Progress(const Token: string; const Progress, Total: Double;
  const Message: string);
begin
  var Event := Default(TSinkEvent);
  Event.Kind := KIND_PROGRESS;
  Event.Token := Token;
  Event.Progress := Progress;
  Event.Total := Total;
  Event.Text := Message;
  Add(Event);
end;

procedure TRecordingSink.LogMessage(const Level, Logger, DataJson: string);
begin
  var Event := Default(TSinkEvent);
  Event.Kind := KIND_LOG;
  Event.Level := Level;
  Event.Logger := Logger;
  Event.Text := DataJson;
  Add(Event);
end;

function TRecordingSink.CountOf(const Kind: string): Integer;
begin
  Result := 0;
  for var Event in FEvents do
    if Event.Kind = Kind then
      Inc(Result);
end;

function TRecordingSink.First(const Kind: string): TSinkEvent;
begin
  for var Event in FEvents do
    if Event.Kind = Kind then
      Exit(Event);

  Assert.Fail('the sink saw no ' + Kind + ' notification');
  Result := Default(TSinkEvent);
end;

function TRecordingSink.AnyAfterTheCall: Boolean;
begin
  Result := False;
  for var Event in FEvents do
    if Event.AfterTheCall then
      Exit(True);
end;

{ TMCPClientMrtrTests }

procedure TMCPClientMrtrTests.Setup;
begin
  FHost := TMCPServerHost.Create;
  FHost.Settings.Port := 0;
  FHost.Settings.CorsEnabled := False;
  FHost.AddTool(TMCPRegistry.CreateTool(TOOL_ELICITATION));
  FHost.AddTool(TMCPRegistry.CreateTool(TOOL_SAMPLING));
  FHost.AddTool(TMCPRegistry.CreateTool(TOOL_LIST_ROOTS));
  FHost.AddTool(TMCPRegistry.CreateTool(TOOL_MULTIPLE_INPUTS));
  FHost.AddTool(TMCPRegistry.CreateTool(TOOL_MULTI_ROUND));
  FHost.AddTool(TTopicInputTool.Create);
  FHost.StartHttp;

  NewClient(Options);
  RespondAsAHost;
end;

procedure TMCPClientMrtrTests.TearDown;
begin
  FTrace := nil;
  FClient := nil;
  FreeAndNil(FStub);
  FreeAndNil(FHost);
end;

function TMCPClientMrtrTests.Url: string;
begin
  Result := Format(URL_TEMPLATE, [LOOPBACK, FHost.BoundPort, ENDPOINT]);
end;

function TMCPClientMrtrTests.Options: TMCPClientOptions;
begin
  Result := TMCPClientOptions.Default;
  Result.Era := TMCPClientEra.Modern;
end;

procedure TMCPClientMrtrTests.NewClient(const AOptions: TMCPClientOptions);
begin
  NewClientFor(Url, AOptions);
end;

procedure TMCPClientMrtrTests.NewClientFor(const ServerUrl: string; const AOptions: TMCPClientOptions);
begin
  FRequests := nil;
  FResponses := nil;
  FAsked := nil;
  FAnswered := False;

  FTrace := TMCPClient.Create(ServerUrl, AOptions);
  FClient := FTrace;
  FTrace.OnRequestBody :=
    procedure(Body: string)
    begin
      FRequests := FRequests + [Body];
    end;
  FTrace.OnResponseBody :=
    procedure(Body: string)
    begin
      FResponses := FResponses + [Body];
    end;
end;

procedure TMCPClientMrtrTests.RespondWith(const Responder: TMCPInputResponder);
begin
  FClient.SetInputResponder(Responder);
end;

procedure TMCPClientMrtrTests.RespondAsAHost;
begin
  RespondWith(
    function(const Key, Method: string; const Params: TJSONObject): TJSONObject
    begin
      Result := Answer(Key, Method, Params);
    end);
end;

function TMCPClientMrtrTests.Answer(const Key, Method: string; const Params: TJSONObject): TJSONObject;
begin
  FAsked := FAsked + [Key + ' ' + Method];
  FAnswered := True;

  if Method = MCP_METHOD_ELICITATION_CREATE then
    Result := Elicitation(Params)
  else if Method = MCP_METHOD_SAMPLING_CREATE_MESSAGE then
    Result := Sampling
  else if Method = MCP_METHOD_ROOTS_LIST then
    Result := Roots
  else
    Result := nil;
end;

function TMCPClientMrtrTests.Elicitation(const Params: TJSONObject): TJSONObject;
begin
  const Field = FirstRequiredField(Params);

  const Content = TJSONObject.Create;
  if Field = FIELD_COLOR then
    Content.AddPair(Field, ANSWER_COLOR)
  else if Field = FIELD_OK then
    Content.AddPair(Field, TJSONBool.Create(True))
  else
    Content.AddPair(Field, ANSWER_NAME);

  Result := TJSONObject.Create;
  Result.AddPair(KEY_ACTION, ACTION_ACCEPT);
  Result.AddPair(KEY_CONTENT, Content);
end;

function TMCPClientMrtrTests.Sampling: TJSONObject;
begin
  const Content = TJSONObject.Create;
  Content.AddPair(MCP_KEY_TYPE, TYPE_TEXT);
  Content.AddPair(MCP_KEY_TEXT, SAMPLED_TEXT);

  Result := TJSONObject.Create;
  Result.AddPair(KEY_ROLE, ROLE_ASSISTANT);
  Result.AddPair(KEY_CONTENT, Content);
  Result.AddPair(KEY_MODEL, SAMPLING_MODEL);
  Result.AddPair(KEY_STOP_REASON, STOP_REASON_END_TURN);
end;

function TMCPClientMrtrTests.Roots: TJSONObject;
begin
  const Root = TJSONObject.Create;
  Root.AddPair(MCP_KEY_URI, ROOT_URI);
  Root.AddPair(MCP_KEY_NAME, ROOT_NAME);

  const Listed = TJSONArray.Create;
  Listed.AddElement(Root);

  Result := TJSONObject.Create;
  Result.AddPair(KEY_ROOTS, Listed);
end;

function TMCPClientMrtrTests.CallTopic(const Topic: string): TMCPToolCallOutcome;
begin
  const Arguments = TJSONObject.Create.AddPair('topic', Topic);
  try
    Result := FClient.CallTool(TOOL_TOPIC, Arguments);
  finally
    Arguments.Free;
  end;
end;

function TMCPClientMrtrTests.CallCount: Integer;
begin
  Result := 0;
  for var Body in FRequests do
    if Body.Contains('"' + MCP_METHOD_TOOLS_CALL + '"') then
      Inc(Result);
end;

function TMCPClientMrtrTests.Request(const Index: Integer): TJSONObject;
begin
  Assert.IsTrue(Index < Length(FRequests), Format('the client sent fewer than %d requests', [Index + 1]));
  Result := TMCPTestJson.ParseObject(FRequests[Index]);
end;

function TMCPClientMrtrTests.RequestParam(const Index: Integer; const Name: string): string;
begin
  const Body = Request(Index);
  try
    const Params = Body.GetValue(MCP_KEY_PARAMS);
    Assert.IsTrue(Params is TJSONObject, 'the request carries no params: ' + FRequests[Index]);
    Result := Member(TJSONObject(Params), Name);
  finally
    Body.Free;
  end;
end;

function TMCPClientMrtrTests.ResponseMember(const Index, Depth: Integer; const Name: string): string;
begin
  Assert.IsTrue(Index < Length(FResponses), Format('the server sent fewer than %d responses', [Index + 1]));

  const Body = TMCPTestJson.ParseObject(FResponses[Index]);
  try
    var Owner := Body;
    if Depth > 0 then
    begin
      const Outcome = Body.GetValue(MCP_KEY_RESULT);
      Assert.IsTrue(Outcome is TJSONObject, 'the response carries no result: ' + FResponses[Index]);
      Owner := TJSONObject(Outcome);
    end;
    Result := Member(Owner, Name);
  finally
    Body.Free;
  end;
end;

class function TMCPClientMrtrTests.FirstRequiredField(const Params: TJSONObject): string;
begin
  Result := '';
  if not Assigned(Params) then
    Exit;

  const Schema = Params.GetValue(KEY_REQUESTED_SCHEMA);
  if not (Schema is TJSONObject) then
    Exit;

  const Required = TJSONObject(Schema).GetValue(KEY_REQUIRED);
  if not (Required is TJSONArray) then
    Exit;
  if TJSONArray(Required).Count = 0 then
    Exit;

  Result := TJSONArray(Required).Items[0].Value;
end;

class function TMCPClientMrtrTests.Member(const Owner: TJSONObject; const Name: string): string;
begin
  Result := '';
  const Value = Owner.GetValue(Name);
  if Value is TJSONString then
    Result := TJSONString(Value).Value
  else if Assigned(Value) then
    Result := Value.ToJSON;
end;

procedure TMCPClientMrtrTests.Elicitation_OneRound_AnswersAndCompletes;
begin
  const Outcome = FClient.CallTool(TOOL_ELICITATION, nil);

  Assert.IsFalse(Outcome.IsError, 'the elicitation round trip failed: ' + Outcome.Text);
  Assert.AreEqual('Hello, ' + ANSWER_NAME + '!', Outcome.Text);
  Assert.AreEqual('complete', Outcome.ResultType);
  Assert.AreEqual(2, CallCount, 'one question and one answer make two tools/call requests');
end;

procedure TMCPClientMrtrTests.Elicitation_Responder_SeesTheKeyTheMethodAndTheParams;
begin
  var SeenMessage := '';
  RespondWith(
    function(const Key, Method: string; const Params: TJSONObject): TJSONObject
    begin
      if Assigned(Params) then
        SeenMessage := Params.GetValue<string>(KEY_MESSAGE, '');
      Result := Answer(Key, Method, Params);
    end);

  FClient.CallTool(TOOL_ELICITATION, nil);

  Assert.AreEqual(1, Integer(Length(FAsked)), 'the responder was asked once');
  Assert.AreEqual('user_name ' + MCP_METHOD_ELICITATION_CREATE, FAsked[0]);
  Assert.AreEqual('What is your name?', SeenMessage, 'the responder never saw the request params');
end;

procedure TMCPClientMrtrTests.MultiRound_TwoRounds_CompletesWithThreeCalls;
begin
  const Outcome = FClient.CallTool(TOOL_MULTI_ROUND, nil);

  Assert.IsFalse(Outcome.IsError, 'the two round trip failed: ' + Outcome.Text);
  Assert.AreEqual(Format('Hello, %s! Your favorite color is %s.', [ANSWER_NAME, ANSWER_COLOR]),
    Outcome.Text);
  Assert.AreEqual(3, CallCount, 'two rounds of input take three tools/call requests');
  Assert.AreEqual(2, Integer(Length(FAsked)), 'the responder answered twice');
end;

procedure TMCPClientMrtrTests.MultiRound_EveryRound_RepeatsTheNameAndTheArguments;
begin
  CallTopic(TOPIC);

  // The server signs a digest of the name and the arguments into the requestState and checks it
  // again on the way back, so a round that changed either would be refused.
  Assert.AreEqual(TOOL_TOPIC, RequestParam(1, MCP_KEY_NAME));
  Assert.AreEqual(TOOL_TOPIC, RequestParam(2, MCP_KEY_NAME));
  Assert.AreEqual(RequestParam(1, MCP_KEY_ARGUMENTS), RequestParam(2, MCP_KEY_ARGUMENTS));
  Assert.IsTrue(RequestParam(2, MCP_KEY_ARGUMENTS).Contains(TOPIC),
    'the second round dropped the arguments: ' + RequestParam(2, MCP_KEY_ARGUMENTS));
end;

procedure TMCPClientMrtrTests.RequestState_IsEchoedByteForByte;
begin
  CallTopic(TOPIC);

  const SealedState = ResponseMember(1, 1, KEY_RESULT_STATE);
  Assert.IsTrue(SealedState <> '', 'the server sealed no requestState');
  Assert.AreEqual(SealedState, RequestParam(2, KEY_RESULT_STATE),
    'the client did not echo the requestState exactly as it arrived');
end;

procedure TMCPClientMrtrTests.RequestState_TheServerAcceptsWhatCameBack;
begin
  const Outcome = CallTopic(TOPIC);

  Assert.IsFalse(Outcome.IsError, 'the server refused the requestState it had sealed: ' + Outcome.Text);
  Assert.AreEqual(Format('%s hears about %s', [ANSWER_NAME, TOPIC]), Outcome.Text);
end;

procedure TMCPClientMrtrTests.MultipleInputs_EveryKeyIsAnsweredInOneRound;
begin
  const Outcome = FClient.CallTool(TOOL_MULTIPLE_INPUTS, nil);

  Assert.IsFalse(Outcome.IsError, 'the three-in-one round trip failed: ' + Outcome.Text);
  Assert.AreEqual(3, Integer(Length(FAsked)), 'not every key was answered');
  Assert.AreEqual(2, CallCount, 'three keys in one round still take two tools/call requests');
  Assert.IsTrue(Outcome.Text.Contains(ANSWER_NAME), Outcome.Text);
  Assert.IsTrue(Outcome.Text.Contains(SAMPLED_TEXT), Outcome.Text);
  Assert.IsTrue(Outcome.Text.Contains(ROOT_URI), Outcome.Text);
end;

procedure TMCPClientMrtrTests.Sampling_RoundTrips;
begin
  const Outcome = FClient.CallTool(TOOL_SAMPLING, nil);

  Assert.IsFalse(Outcome.IsError, Outcome.Text);
  Assert.AreEqual('LLM response: ' + SAMPLED_TEXT, Outcome.Text);
end;

procedure TMCPClientMrtrTests.ListRoots_RoundTrips;
begin
  const Outcome = FClient.CallTool(TOOL_LIST_ROOTS, nil);

  Assert.IsFalse(Outcome.IsError, Outcome.Text);
  Assert.AreEqual('Roots: ' + ROOT_URI, Outcome.Text);
end;

procedure TMCPClientMrtrTests.WithoutAResponder_IsAnErrorOutcomeAndNotAnException;
begin
  // A real server only asks a client that declared it can be asked, so this takes a stub: the
  // client must still answer for itself rather than raise into the caller's loop.
  FStub := TStreamingStub.Create;
  FStub.AlwaysAsksForInput := True;
  NewClientFor(FStub.Url, Options);

  const Outcome = FClient.CallTool(TOOL_ELICITATION, nil);

  Assert.IsTrue(Outcome.IsError);
  Assert.AreEqual('The server asked for client input and no input responder is configured.',
    Outcome.Text);
  Assert.AreEqual(1, CallCount, 'the client answered a question it has nobody to answer');
end;

procedure TMCPClientMrtrTests.ResponderThatAnswersNothing_IsAnErrorOutcome;
begin
  RespondWith(
    function(const Key, Method: string; const Params: TJSONObject): TJSONObject
    begin
      Result := nil;
    end);

  const Outcome = FClient.CallTool(TOOL_ELICITATION, nil);

  Assert.IsTrue(Outcome.IsError);
  Assert.AreEqual('The input responder produced no answer for user_name.', Outcome.Text);
  Assert.AreEqual(1, CallCount, 'the client sent a round it had no answers for');
end;

procedure TMCPClientMrtrTests.MoreRoundsThanAllowed_StopsAtMaxInputRounds;
begin
  var Impatient := Options;
  Impatient.MaxInputRounds := 1;
  NewClient(Impatient);
  RespondAsAHost;

  const Outcome = FClient.CallTool(TOOL_MULTI_ROUND, nil);

  Assert.IsTrue(Outcome.IsError, 'the two round tool completed inside one round');
  Assert.AreEqual('The server asked for input more than 1 times.', Outcome.Text);
  Assert.AreEqual(2, CallCount, 'one allowed round is one question and one answer');
end;

procedure TMCPClientMrtrTests.LegacyEra_InputRequired_SurfacesTheServerMessageUnchanged;
begin
  var Legacy := Options;
  Legacy.Era := TMCPClientEra.Legacy;
  NewClient(Legacy);
  RespondAsAHost;

  const Outcome = FClient.CallTool(TOOL_ELICITATION, nil);

  Assert.IsTrue(Outcome.IsError, 'the legacy era answered an input request it cannot deliver');
  Assert.AreEqual(JSONRPC_INTERNAL_ERROR, Outcome.ErrorCode);
  Assert.IsTrue(Outcome.ErrorMessage.Contains('cannot deliver'), Outcome.ErrorMessage);
  Assert.IsFalse(FAnswered, 'the client answered a question the server never managed to ask');
end;

{ TMCPClientSinkTests }

procedure TMCPClientSinkTests.Setup;
begin
  FHost := TMCPServerHost.Create;
  FHost.Settings.Port := 0;
  FHost.Settings.CorsEnabled := False;
  FHost.AddTool(TSinkSampleTool.Create);
  FHost.AddTool(TOpenEndedProgressTool.Create);
  FHost.AddTool(TMCPRegistry.CreateTool(TOOL_SIMPLE_TEXT));
  FHost.StartHttp;

  NewClient(Options);
end;

procedure TMCPClientSinkTests.TearDown;
begin
  FTrace := nil;
  FClient := nil;
  FSink := nil;
  FreeAndNil(FHost);
end;

function TMCPClientSinkTests.Url: string;
begin
  Result := Format(URL_TEMPLATE, [LOOPBACK, FHost.BoundPort, ENDPOINT]);
end;

function TMCPClientSinkTests.Options: TMCPClientOptions;
begin
  Result := TMCPClientOptions.Default;
  Result.Era := TMCPClientEra.Modern;
  Result.LogLevel := LOG_LEVEL_INFO;
end;

procedure TMCPClientSinkTests.NewClient(const AOptions: TMCPClientOptions);
begin
  FBodies := nil;
  FTrace := TMCPClient.Create(Url, AOptions);
  FClient := FTrace;
  FTrace.OnRequestBody :=
    procedure(Body: string)
    begin
      FBodies := FBodies + [Body];
    end;
end;

function TMCPClientSinkTests.CallWithTheSink(const Tool: string): TMCPToolCallOutcome;
begin
  FSink := TRecordingSink.Create;
  FClient.SetSink(FSink);

  Result := FClient.CallTool(Tool, nil);
  FSink.CallFinished := True;
end;

function TMCPClientSinkTests.LastMeta: TJSONObject;
begin
  Assert.IsTrue(Length(FBodies) > 0, 'the client sent nothing');

  const Body = TMCPTestJson.ParseObject(FBodies[High(FBodies)]);
  try
    const Params = Body.GetValue(MCP_KEY_PARAMS);
    Assert.IsTrue(Params is TJSONObject, 'the request carries no params');

    const Fields = TJSONObject(Params).GetValue(MCP_KEY_META);
    Assert.IsTrue(Fields is TJSONObject, 'the request carries no params._meta');
    Result := TJSONObject(Fields.Clone);
  finally
    Body.Free;
  end;
end;

procedure TMCPClientSinkTests.Progress_ReachesTheSinkBeforeTheResult;
begin
  const Outcome = CallWithTheSink(TOOL_SINK);

  Assert.AreEqual(SINK_ANSWER, Outcome.Text);
  Assert.AreEqual(1, FSink.CountOf(KIND_PROGRESS), 'the progress notification never arrived');
  Assert.IsFalse(FSink.AnyAfterTheCall, 'a notification reached the sink after the call returned');

  const Reported = FSink.First(KIND_PROGRESS);
  Assert.AreEqual(PROGRESS_STEP_MESSAGE, Reported.Text);
  Assert.AreEqual(SINK_PROGRESS, Reported.Progress, TOLERANCE);
  Assert.AreEqual(SINK_TOTAL, Reported.Total, TOLERANCE);
end;

procedure TMCPClientSinkTests.Progress_CarriesTheTokenTheRequestAskedFor;
begin
  CallWithTheSink(TOOL_SINK);

  const Fields = LastMeta;
  try
    const Token = Fields.GetValue(MCP_META_PROGRESS_TOKEN);
    Assert.IsNotNull(Token, 'the request asked for no progress token');
    Assert.AreEqual(Token.ToJSON, FSink.First(KIND_PROGRESS).Token,
      'the progress reported a token the request never asked for');
  finally
    Fields.Free;
  end;
end;

procedure TMCPClientSinkTests.Progress_WithoutATotal_ReportsThatTheTotalIsUnknown;
begin
  CallWithTheSink(TOOL_OPEN_ENDED);

  const Reported = FSink.First(KIND_PROGRESS);
  Assert.AreEqual(OPEN_ENDED_PROGRESS, Reported.Progress, TOLERANCE);
  Assert.AreEqual(TOTAL_UNKNOWN, Reported.Total, TOLERANCE,
    'a missing total was reported as a real one');
end;

procedure TMCPClientSinkTests.LogMessage_ReachesTheSink;
begin
  CallWithTheSink(TOOL_SINK);

  Assert.AreEqual(1, FSink.CountOf(KIND_LOG), 'the log notification never arrived');

  const Logged = FSink.First(KIND_LOG);
  Assert.AreEqual(LOG_LEVEL_WARNING, Logged.Level);
  Assert.AreEqual(LOGGER_NAME, Logged.Logger);
  Assert.AreEqual(LOG_LINE, Logged.Text);
end;

procedure TMCPClientSinkTests.WithoutALogLevel_TheServerSendsNoLogMessages;
begin
  var Quiet := Options;
  Quiet.LogLevel := '';
  NewClient(Quiet);

  CallWithTheSink(TOOL_SINK);

  Assert.AreEqual(1, FSink.CountOf(KIND_PROGRESS), 'progress does not depend on a log level');
  Assert.AreEqual(0, FSink.CountOf(KIND_LOG), 'a client that asked for no log level was sent one');
end;

procedure TMCPClientSinkTests.WithoutASink_NoProgressTokenIsAskedFor;
begin
  FClient.CallTool(TOOL_SIMPLE_TEXT, nil);

  const Fields = LastMeta;
  try
    Assert.IsNull(Fields.GetValue(MCP_META_PROGRESS_TOKEN),
      'the client asked for progress it has nowhere to report');
  finally
    Fields.Free;
  end;
end;

procedure TMCPClientSinkTests.WithASink_AProgressTokenIsAskedFor;
begin
  CallWithTheSink(TOOL_SIMPLE_TEXT);

  const Fields = LastMeta;
  try
    Assert.IsNotNull(Fields.GetValue(MCP_META_PROGRESS_TOKEN),
      'a client with a sink asked for no progress');
  finally
    Fields.Free;
  end;
end;

{ TStreamingStub }

constructor TStreamingStub.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;

  FServer := TIdHTTPServer.Create(nil);
  FServer.OnCommandGet := HandleCommand;
  FServer.OnCommandOther := HandleCommand;
  FServer.DefaultPort := 0;
  FServer.Bindings.Add.IP := LOOPBACK;
  FServer.Active := True;
end;

destructor TStreamingStub.Destroy;
begin
  FServer.Active := False;
  FServer.Free;
  FLock.Free;
  inherited;
end;

function TStreamingStub.Url: string;
begin
  Result := Format(URL_TEMPLATE, [LOOPBACK, FServer.Bindings[0].Port, ENDPOINT]);
end;

function TStreamingStub.CancellationCount: Integer;
begin
  FLock.Enter;
  try
    Result := Integer(Length(FCancellations));
  finally
    FLock.Leave;
  end;
end;

function TStreamingStub.Cancellation(const Index: Integer): string;
begin
  FLock.Enter;
  try
    Result := FCancellations[Index];
  finally
    FLock.Leave;
  end;
end;

function TStreamingStub.CancelledWhileStreaming: Boolean;
begin
  FLock.Enter;
  try
    Result := FCancelledWhileStreaming;
  finally
    FLock.Leave;
  end;
end;

procedure TStreamingStub.Remember(const Body: string);
begin
  FLock.Enter;
  try
    FCancellations := FCancellations + [Body];
    // Recorded here rather than after the fact, because whether the streamed answer was still
    // open at this instant is the whole question.
    FCancelledWhileStreaming := FCancelledWhileStreaming or FStreaming;
  finally
    FLock.Leave;
  end;
end;

procedure TStreamingStub.SetStreaming(const Value: Boolean);
begin
  FLock.Enter;
  try
    FStreaming := Value;
  finally
    FLock.Leave;
  end;
end;

class function TStreamingStub.ReadBody(RequestInfo: TIdHTTPRequestInfo): string;
begin
  Result := '';
  const HasBody = (Assigned(RequestInfo.PostStream) and (RequestInfo.PostStream.Size > 0));
  if not HasBody then
    Exit;

  RequestInfo.PostStream.Position := 0;
  const Reader = TStringStream.Create('', TEncoding.UTF8);
  try
    Reader.CopyFrom(RequestInfo.PostStream, 0);
    Result := Reader.DataString;
  finally
    Reader.Free;
  end;
end;

class function TStreamingStub.MethodOf(const Body: string; out Id: string): string;
begin
  Result := '';
  Id := '0';

  const Value = TJSONObject.ParseJSONValue(Body);
  try
    if not (Value is TJSONObject) then
      Exit;

    Result := TJSONObject(Value).GetValue<string>(MCP_KEY_METHOD, '');
    const Number = TJSONObject(Value).GetValue(MCP_KEY_ID);
    if Number is TJSONNumber then
      Id := Number.Value;
  finally
    Value.Free;
  end;
end;

procedure TStreamingStub.HandleCommand(Context: TIdContext; RequestInfo: TIdHTTPRequestInfo;
  ResponseInfo: TIdHTTPResponseInfo);
var
  Id: string;
begin
  const Body = ReadBody(RequestInfo);
  const Method = MethodOf(Body, Id);

  if Method = MCP_METHOD_NOTIFICATIONS_CANCELLED then
  begin
    Remember(Body);
    if FRefusesCancellations then
      ResponseInfo.ResponseNo := STATUS_SERVER_ERROR
    else
      ResponseInfo.ResponseNo := HTTP_STATUS_ACCEPTED;
    ResponseInfo.ContentText := '';
    Exit;
  end;

  if Method = MCP_METHOD_TOOLS_CALL then
  begin
    if FAlwaysAsksForInput then
      Reply(ResponseInfo, StringReplace(INPUT_REQUIRED_RESULT, ID_TOKEN, Id, [rfReplaceAll]))
    else
      StreamCall(Context, ResponseInfo, Id);
    Exit;
  end;

  Reply(ResponseInfo, StringReplace(DISCOVER_RESULT, ID_TOKEN, Id, [rfReplaceAll]));
end;

procedure TStreamingStub.Reply(ResponseInfo: TIdHTTPResponseInfo; const Body: string);
begin
  ResponseInfo.ResponseNo := HTTP_STATUS_OK;
  ResponseInfo.ContentType := MEDIA_TYPE_JSON;
  ResponseInfo.ContentStream := TStringStream.Create(Body, TEncoding.UTF8);
  ResponseInfo.FreeContentStream := True;
end;

procedure TStreamingStub.StreamCall(Context: TIdContext; ResponseInfo: TIdHTTPResponseInfo;
  const Id: string);
begin
  const Streamer = TMCPHttpResponseStream.Create(Context, ResponseInfo);
  var Owned: IMCPMessageSink := Streamer;

  Streamer.Send(StringReplace(PROGRESS_NOTIFICATION, ID_TOKEN, Id, [rfReplaceAll]));
  SetStreaming(True);
  try
    // The answer waits until the client has had its say on another connection, which is the whole
    // point: a cancellation that only arrived after this one closed would prove nothing.
    TMCPTestWait.UntilTrue(
      function: Boolean
      begin
        Result := CancellationCount > 0;
      end, STREAM_WAIT_MS);
  finally
    SetStreaming(False);
  end;

  Streamer.Finish(StringReplace(LATE_RESULT, ID_TOKEN, Id, [rfReplaceAll]));
end;

{ TMCPClientCancellationTests }

procedure TMCPClientCancellationTests.Setup;
begin
  FCancelled := False;

  FNotifiedStatus := 0;

  FWatch := TCancelWatchTool.Create;
  FWatchTool := FWatch;

  FHost := TMCPServerHost.Create;
  FHost.Settings.Port := 0;
  FHost.Settings.CorsEnabled := False;
  FHost.AddTool(TMCPRegistry.CreateTool(TOOL_PROGRESS));
  FHost.AddTool(FWatchTool);
  FHost.StartHttp;

  FStub := TStreamingStub.Create;
end;

procedure TMCPClientCancellationTests.TearDown;
begin
  FTrace := nil;
  FClient := nil;
  FSink := nil;
  // A tool still counting its steps would hold the host open for as long as its budget lasts.
  FWatch.Release;
  FreeAndNil(FStub);
  FreeAndNil(FHost);
  FWatch := nil;
  FWatchTool := nil;
end;

procedure TMCPClientCancellationTests.NewClient(const ServerUrl: string);
begin
  FBodies := nil;

  var ClientOptions := TMCPClientOptions.Default;
  ClientOptions.Era := TMCPClientEra.Modern;

  FTrace := TMCPClient.Create(ServerUrl, ClientOptions);
  FClient := FTrace;
  FTrace.OnRequestBody :=
    procedure(Body: string)
    begin
      FBodies := FBodies + [Body];
    end;

  FSink := TRecordingSink.Create;
  FClient.SetSink(FSink);
  FClient.SetCancellationCheck(
    function: Boolean
    begin
      Result := FCancelled;
    end);
end;

procedure TMCPClientCancellationTests.CancelFromNowOn;
begin
  // The handshake has to finish first: a check that is already True would abort the probe.
  FClient.Connect;
  FCancelled := True;
end;

function TMCPClientCancellationTests.LastBody: string;
begin
  Assert.IsTrue(Length(FBodies) > 0, 'the client sent nothing');
  Result := FBodies[High(FBodies)];
end;

procedure TMCPClientCancellationTests.CancelledDuringTheStream_IsACancelledOutcome;
begin
  NewClient(Format(URL_TEMPLATE, [LOOPBACK, FHost.BoundPort, ENDPOINT]));
  CancelFromNowOn;

  const Outcome = FClient.CallTool(TOOL_PROGRESS, nil);

  Assert.IsTrue(Outcome.IsError, 'a cancelled call reported success');
  Assert.AreEqual('The tool call was cancelled.', Outcome.Text);
end;

procedure TMCPClientCancellationTests.ACheckThatStaysFalse_LeavesTheCallAlone;
begin
  NewClient(Format(URL_TEMPLATE, [LOOPBACK, FHost.BoundPort, ENDPOINT]));

  const Outcome = FClient.CallTool(TOOL_PROGRESS, nil);

  Assert.IsFalse(Outcome.IsError, 'an uncancelled call was cancelled: ' + Outcome.Text);
  Assert.IsTrue(Outcome.Text.StartsWith('Completed'), Outcome.Text);
  Assert.IsTrue(FSink.CountOf(KIND_PROGRESS) > 0, 'the streamed progress never arrived');
end;

procedure TMCPClientCancellationTests.Cancellation_ReachesTheServerOnASecondConnection;
begin
  NewClient(FStub.Url);
  CancelFromNowOn;

  const Outcome = FClient.CallTool(TOOL_PROGRESS, nil);

  Assert.AreEqual('The tool call was cancelled.', Outcome.Text);
  Assert.IsTrue(FStub.CancelledWhileStreaming,
    'the cancellation did not arrive while the answer was still being streamed');
  Assert.AreEqual(1, FStub.CancellationCount,
    'the server was never told, or was told more than once');

  const Told = TMCPTestJson.ParseObject(FStub.Cancellation(0));
  try
    const Params = Told.GetValue(MCP_KEY_PARAMS);
    Assert.IsTrue(Params is TJSONObject, 'the cancellation carries no params');
    Assert.AreEqual('2', TJSONObject(Params).GetValue('requestId').ToJSON,
      'the cancellation names another request than the one in flight');
    Assert.AreEqual('client cancelled', TJSONObject(Params).GetValue<string>('reason'));
  finally
    Told.Free;
  end;
end;

function TMCPClientCancellationTests.StartCancellingNotifier: TThread;
begin
  Result := TThread.CreateAnonymousThread(
    procedure
    begin
      if not FWatch.WaitForStart(WATCH_WAIT_MS) then
        Exit;

      var Http := TIdHTTP.Create(nil);
      var Request := TStringStream.Create(Format(CANCEL_NOTIFICATION, [FWatch.RequestId]),
        TEncoding.UTF8);
      try
        Http.HTTPOptions := Http.HTTPOptions + [hoNoProtocolErrorException];
        Http.Request.ContentType := MEDIA_TYPE_JSON;
        Http.Post(Format(URL_TEMPLATE, [LOOPBACK, FHost.BoundPort, ENDPOINT]), Request);
        FNotifiedStatus := Http.ResponseCode;
      finally
        Request.Free;
        Http.Free;
      end;

      // The tool has now outlived the notification, which is the whole point; it may stop.
      FWatch.Release;
    end);
  Result.FreeOnTerminate := False;
  Result.Start;
end;

procedure TMCPClientCancellationTests.ACancellationTheServerRefuses_IsInTheOutcome;
begin
  FStub.RefusesCancellations := True;
  NewClient(FStub.Url);
  CancelFromNowOn;

  const Outcome = FClient.CallTool(TOOL_PROGRESS, nil);

  Assert.AreEqual(1, FStub.CancellationCount, 'the client never tried to tell the server');
  Assert.IsTrue(Outcome.IsError, 'a cancelled call reported success');
  Assert.IsTrue(Outcome.Text.Contains(IntToStr(STATUS_SERVER_ERROR)),
    'the refused cancellation was swallowed: ' + Outcome.Text);
end;

procedure TMCPClientCancellationTests.ClosingTheStream_CancelsTheToolOnTheServer;
begin
  NewClient(Format(URL_TEMPLATE, [LOOPBACK, FHost.BoundPort, ENDPOINT]));
  CancelFromNowOn;

  const Outcome = FClient.CallTool(TOOL_CANCEL_WATCH, nil);

  Assert.IsTrue(Outcome.IsError, 'a cancelled call reported success');
  Assert.IsTrue(FWatch.WaitForCancellation(WATCH_WAIT_MS),
    'the tool never saw its request cancelled, so the closed stream cancelled nothing');
end;

procedure TMCPClientCancellationTests.ACancellationOnASecondConnection_IsAcceptedAndTheToolRunsOn;
begin
  NewClient(Format(URL_TEMPLATE, [LOOPBACK, FHost.BoundPort, ENDPOINT]));

  const Notifier = StartCancellingNotifier;
  try
    const Outcome = FClient.CallTool(TOOL_CANCEL_WATCH, nil);

    Assert.IsFalse(Outcome.IsError, 'the call failed: ' + Outcome.Text);
    Assert.AreEqual(WATCH_ANSWER, Outcome.Text, 'the tool did not answer');
  finally
    Notifier.WaitFor;
    Notifier.Free;
  end;

  Assert.AreEqual(HTTP_STATUS_ACCEPTED, FNotifiedStatus,
    'the server answered the cancellation with something other than 202');
  Assert.IsFalse(FWatch.SawCancellation,
    'the notification reached the request after all, which the documents deny');
end;

procedure TMCPClientCancellationTests.Cancellation_IsSentOnceForOneCall;
begin
  NewClient(FStub.Url);
  CancelFromNowOn;

  FClient.CallTool(TOOL_PROGRESS, nil);

  Assert.AreEqual(1, FStub.CancellationCount, 'the client repeated the cancellation');
  Assert.IsTrue(LastBody.Contains(MCP_METHOD_NOTIFICATIONS_CANCELLED),
    'the last thing the client sent was not the cancellation: ' + LastBody);
end;

end.
