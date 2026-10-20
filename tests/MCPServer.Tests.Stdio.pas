unit MCPServer.Tests.Stdio;

interface

uses
  DUnitX.TestFramework,
  System.SysUtils,
  System.Classes,
  System.JSON,
  MCPServer.Types,
  MCPServer.StdioTransport,
  MCPServer.Tests.Harness;

type
  [TestFixture]
  TStdioTransportTests = class
  private
    const
      KEEP_THE_SETTINGS_DRAIN = -1;
      LINE_FEED               = #10;
    var
      FHarness: TMCPTestHarness;
      FOutputBytes: TBytes;
      FElapsedMs: Int64;
    function Run(const Lines: array of string; const DrainMs: Integer = KEEP_THE_SETTINGS_DRAIN; const Separator: string = LINE_FEED): TArray<string>;
    function JoinLines(const Lines: array of string; const Separator: string): string;
    procedure RunInto(const Output: TBytesStream; const Registry: IMCPManagerRegistry; const Input: string; const DrainMs: Integer);
    function ReadOutput(const Output: TBytesStream): TArray<string>;
    procedure AssertLineCount(const Lines: TArray<string>; const Expected: Integer; const Reason: string);
    procedure AssertErrorAnswer(const Lines: TArray<string>; const Id: string; const MessageFragment: string);
    function ParseLine(const Line: string): TJSONObject;
    function FindById(const Lines: TArray<string>; const Id: string): TJSONObject;
    function GetById(const Lines: TArray<string>; const Id: string): TJSONObject;
    function FindNotification(const Lines: TArray<string>; const Method: string): TJSONObject;

  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    [Test]
    procedure Handshake_And_ToolsList;

    [Test]
    procedure Utf8_RoundTrip_LfFraming_NoBom;

    [Test]
    procedure CrLf_Input_IsAccepted;

    [Test]
    procedure InvalidJson_IsParseError_WithNullId;

    [Test]
    procedure Notification_ProducesNoOutput;

    [Test]
    procedure DuplicateId_WhileInFlight_IsInvalidRequest;

    [Test]
    procedure Cancelled_GetsNoResponse_PingIsStillAnswered;

    [Test]
    procedure Cancelled_ByTheHandlerItself_IsNotCalledAShutdown;

    [Test]
    procedure Progress_IsSentBeforeTheResponse;

    [Test]
    procedure ModernRequest_OverStdio;

    [Test]
    procedure Eof_WithRunningRequest_IsAnsweredWithAnErrorAfterTheDrain;

    [Test]
    procedure Eof_QueuedRequestsWithinTheBound_AreAllAnswered;

    [Test]
    procedure Eof_PastTheBound_AnswersTheRestWithAnError;

    [Test]
    procedure Eof_RequestTheClientCancelled_GetsNoAnswer;

    [Test]
    procedure Eof_HandlerThatIgnoresCancellation_IsAnsweredOnce;

    [Test]
    procedure Eof_ListenerThatOutlivesTheDrain_IsAnsweredWithAnError;

    [Test]
    procedure Eof_NegativeDrain_AnswersAtOnce;

    [Test]
    procedure ShutdownDrainMs_SetBeforeTheSettings_IsKept;

    [Test]
    procedure ShutdownDrainMs_NotSet_FollowsTheSettings;

    [Test]
    procedure Listen_AckThenCancel_HasNoResponse;

    [Test]
    procedure Listen_Eof_ClosesGracefully;

    [Test]
    procedure UnsetRequestStateKey_IsNotWarnedAbout;
  end;

implementation

uses
  System.Diagnostics,
  MCPServer.RequestState,
  MCPServer.ManagerRegistry,
  MCPServer.CoreManager,
  MCPServer.Tool.Base,
  MCPServer.Tests.Support,
  MCPServer.Tests.StdioDoubles;

const
  INITIALIZE           = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}';
  INITIALIZED          = '{"jsonrpc":"2.0","method":"notifications/initialized"}';
  SLOW_CALL            = '{"jsonrpc":"2.0","id":%d,"method":"tools/call","params":{"name":"test_tool_with_progress","arguments":{"steps":%d,"stepMs":100}}}';
  ECHO_CALL            = '{"jsonrpc":"2.0","id":%d,"method":"tools/call","params":{"name":"echo","arguments":{"message":"quick"}}}';
  STUBBORN_CALL        = '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"' + STUBBORN_TOOL_NAME + '","arguments":{}}}';
  SELF_CANCELLING_CALL = '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"' + SELF_CANCELLING_TOOL_NAME + '","arguments":{}}}';
  STUBBORN_LISTEN      = '{"jsonrpc":"2.0","id":9,"method":"subscriptions/listen","params":{"notifications":{"toolsListChanged":true},' +
                         TMCPTestMeta.MODERN_MEMBER + '}}';
  FIRST_TEXT_PATH      = 'result.content[0].text';
  OUTPUT_SEPARATOR     = ' | ';
  SHUTTING_DOWN        = 'shutting down';
  REQUEST_CANCELLED    = 'Request was cancelled';
  LONG_STEPS           = 600;
  LISTENER_DRAIN_MS    = 200;
  QUICK_ANSWER         = 'Echo: quick';

{ TStdioTransportTests }

procedure TStdioTransportTests.Setup;
begin
  FHarness := TMCPTestHarness.Create;
end;

procedure TStdioTransportTests.TearDown;
begin
  FHarness.Free;
end;

function TStdioTransportTests.Run(const Lines: array of string; const DrainMs: Integer; const Separator: string): TArray<string>;
begin
  const Input = JoinLines(Lines, Separator);
  const Output = TBytesStream.Create;
  try
    RunInto(Output, FHarness.ManagerRegistry, Input, DrainMs);
    Result := ReadOutput(Output);
  finally
    Output.Free;
  end;
end;

function TStdioTransportTests.JoinLines(const Lines: array of string; const Separator: string): string;
begin
  Result := '';
  for var Line in Lines do
  begin
    Result := Result + Line + Separator;
  end;
end;

procedure TStdioTransportTests.RunInto(const Output: TBytesStream; const Registry: IMCPManagerRegistry; const Input: string; const DrainMs: Integer);
begin
  const InputBytes = TEncoding.UTF8.GetBytes(Input);
  const InputStream = TBytesStream.Create(InputBytes);
  try
    const Transport = TMCPStdioTransport.Create(Registry, FHarness.CoreManager);
    try
      Transport.Settings := FHarness.Settings;
      const KeepsTheSettingsDrain = (DrainMs = KEEP_THE_SETTINGS_DRAIN);
      if not KeepsTheSettingsDrain then
        Transport.ShutdownDrainMs := DrainMs;

      var Watch := TStopwatch.StartNew;
      Transport.RunWith(InputStream, Output);
      FElapsedMs := Watch.ElapsedMilliseconds;
    finally
      Transport.Free;
    end;
  finally
    InputStream.Free;
  end;
end;

function TStdioTransportTests.ReadOutput(const Output: TBytesStream): TArray<string>;
begin
  FOutputBytes := Copy(Output.Bytes, 0, Output.Size);
  const Text = TEncoding.UTF8.GetString(FOutputBytes);
  Result := Text.Split([LINE_FEED], TStringSplitOptions.ExcludeEmpty);
end;

procedure TStdioTransportTests.AssertLineCount(const Lines: TArray<string>; const Expected: Integer; const Reason: string);
begin
  const LineCount = Length(Lines);
  const Output = string.Join(OUTPUT_SEPARATOR, Lines);
  const Message = Format('%s: %s', [Reason, Output]);
  Assert.AreEqual<NativeInt>(Expected, LineCount, Message);
end;

procedure TStdioTransportTests.AssertErrorAnswer(const Lines: TArray<string>; const Id: string; const MessageFragment: string);
begin
  const Answer = GetById(Lines, Id);
  try
    const Code = Answer.GetValue<Integer>('error.code');
    const ErrorMessage = Answer.GetValue<string>('error.message');
    const AnswerText = Answer.ToJSON;
    Assert.AreEqual(JSONRPC_INTERNAL_ERROR, Code, AnswerText);
    Assert.Contains(ErrorMessage, MessageFragment);
  finally
    Answer.Free;
  end;
end;

function TStdioTransportTests.ParseLine(const Line: string): TJSONObject;
begin
  Result := TJSONObject.ParseJSONValue(Line) as TJSONObject;
  Assert.IsNotNull(Result, 'stdout line is JSON: ' + Line);
end;

function TStdioTransportTests.FindById(const Lines: TArray<string>; const Id: string): TJSONObject;
begin
  for var Line in Lines do
  begin
    var Json := ParseLine(Line);
    var IdValue := Json.GetValue('id');
    if Assigned(IdValue) and (IdValue.Value = Id) then
      Exit(Json);
    Json.Free;
  end;
  Result := nil;
end;

function TStdioTransportTests.GetById(const Lines: TArray<string>; const Id: string): TJSONObject;
begin
  Result := FindById(Lines, Id);
  const Output = string.Join(OUTPUT_SEPARATOR, Lines);
  const Message = Format('no message with id %s in %s', [Id, Output]);
  Assert.IsNotNull(Result, Message);
end;

function TStdioTransportTests.FindNotification(const Lines: TArray<string>; const Method: string): TJSONObject;
begin
  for var Line in Lines do
  begin
    var Json := ParseLine(Line);
    var MethodValue := Json.GetValue('method');
    if IsJsonString(MethodValue) and (TJSONString(MethodValue).Value = Method) then
      Exit(Json);
    Json.Free;
  end;
  Result := nil;
end;

procedure TStdioTransportTests.Handshake_And_ToolsList;
begin
  var Lines := Run([INITIALIZE, INITIALIZED, '{"jsonrpc":"2.0","id":2,"method":"tools/list"}']);
  Assert.AreEqual(2, Integer(Length(Lines)));
  var Init := GetById(Lines, '1');
  var Tools := GetById(Lines, '2');
  try
    Assert.AreEqual('2025-06-18', Init.GetValue<string>('result.protocolVersion'));
    Assert.AreEqual('echo', Tools.GetValue<string>('result.tools[0].name'));
  finally
    Init.Free;
    Tools.Free;
  end;
end;

procedure TStdioTransportTests.Utf8_RoundTrip_LfFraming_NoBom;
begin
  var Probe := 'h' + Char($00E9) + 'llo w' + Char($00F6) + 'rld ' + Char($D83D) + Char($DE00);
  var Lines := Run([INITIALIZE, INITIALIZED,
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"message":"' + Probe + '"}}}']);
  var Echo := GetById(Lines, '3');
  try
    const Expected = Format('Echo: %s', [Probe]);
    const Text = Echo.GetValue<string>(FIRST_TEXT_PATH);
    Assert.AreEqual(Expected, Text);
  finally
    Echo.Free;
  end;
  Assert.AreEqual($7B, Integer(FOutputBytes[0]), 'no byte-order mark');
  Assert.AreEqual(10, Integer(FOutputBytes[High(FOutputBytes)]), 'ends with LF');
  for var B in FOutputBytes do
  begin
    Assert.AreNotEqual(13, Integer(B), 'no CR on stdout');
  end;
end;

procedure TStdioTransportTests.CrLf_Input_IsAccepted;
begin
  var Lines := Run([INITIALIZE, INITIALIZED, '{"jsonrpc":"2.0","id":2,"method":"ping"}'], 2000, #13#10);
  var Pong := GetById(Lines, '2');
  try
    Assert.IsNotNull(Pong);
    Assert.IsNotNull(Pong.GetValue('result'));
  finally
    Pong.Free;
  end;
end;

procedure TStdioTransportTests.InvalidJson_IsParseError_WithNullId;
begin
  var Lines := Run(['this is not json', '{"jsonrpc":"2.0","id":2,"method":"ping"}']);
  Assert.AreEqual(2, Integer(Length(Lines)));
  var Error := ParseLine(Lines[0]);
  try
    Assert.IsTrue(Error.GetValue('id') is TJSONNull);
    Assert.AreEqual(JSONRPC_PARSE_ERROR, Error.GetValue<Integer>('error.code'));
  finally
    Error.Free;
  end;
end;

procedure TStdioTransportTests.Notification_ProducesNoOutput;
begin
  var Lines := Run([INITIALIZED, '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":99}}']);
  Assert.AreEqual(0, Integer(Length(Lines)));
end;

procedure TStdioTransportTests.DuplicateId_WhileInFlight_IsInvalidRequest;
begin
  var Slow := '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"test_tool_with_progress","arguments":{"steps":4,"stepMs":100}}}';
  var Lines := Run([Slow, '{"jsonrpc":"2.0","id":7,"method":"ping"}']);
  Lines := Run([Slow, Slow]);
  Assert.AreEqual(2, Integer(Length(Lines)));
  var First := ParseLine(Lines[0]);
  var Second := ParseLine(Lines[1]);
  try
    Assert.AreEqual(JSONRPC_INVALID_REQUEST, First.GetValue<Integer>('error.code'), 'the duplicate is refused at once');
    Assert.IsNotNull(Second.GetValue('result'), 'the first request still completes');
  finally
    First.Free;
    Second.Free;
  end;
end;

procedure TStdioTransportTests.Cancelled_GetsNoResponse_PingIsStillAnswered;
begin
  var Lines := Run([
    '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"test_tool_with_progress","arguments":{"steps":50,"stepMs":100}}}',
    '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":5,"reason":"test"}}',
    '{"jsonrpc":"2.0","id":6,"method":"ping"}']);
  Assert.AreEqual(1, Integer(Length(Lines)), 'only the ping is answered');
  var Pong := GetById(Lines, '6');
  try
    Assert.IsNotNull(Pong);
  finally
    Pong.Free;
  end;
  Assert.IsTrue(FElapsedMs < 3000, 'the cancelled tool stopped early: ' + FElapsedMs.ToString + ' ms');
end;

procedure TStdioTransportTests.Cancelled_ByTheHandlerItself_IsNotCalledAShutdown;
begin
  const Tool: IMCPTool = TSelfCancellingTool.Create;
  FHarness.ToolsManager.AddTool(Tool);

  const Lines = Run([SELF_CANCELLING_CALL]);

  AssertLineCount(Lines, 1, 'a request nobody cancelled still gets an answer');
  AssertErrorAnswer(Lines, '1', REQUEST_CANCELLED);
end;

procedure TStdioTransportTests.Progress_IsSentBeforeTheResponse;
begin
  var Lines := Run([
    '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"test_tool_with_progress","arguments":{"steps":3,"stepMs":80},"_meta":{"progressToken":"p1"}}}']);
  Assert.IsTrue(Length(Lines) >= 4, 'at least three progress notifications and the response');

  var LastProgress := -1.0;
  var ProgressCount := 0;
  for var I := 0 to High(Lines) do
  begin
    var Json := ParseLine(Lines[I]);
    try
      if I = High(Lines) then
      begin
        Assert.AreEqual('8', Json.GetValue('id').Value, 'the response comes last');
        Assert.AreEqual('Completed 3 steps', Json.GetValue<string>(FIRST_TEXT_PATH));
      end
      else
      begin
        Assert.AreEqual('notifications/progress', Json.GetValue<string>('method'));
        Assert.AreEqual('p1', Json.GetValue<string>('params.progressToken'));
        var Progress := Json.GetValue<Double>('params.progress');
        Assert.IsTrue(Progress > LastProgress, 'progress increases');
        LastProgress := Progress;
        Inc(ProgressCount);
      end;
    finally
      Json.Free;
    end;
  end;
  Assert.IsTrue(ProgressCount >= 3);
  Assert.AreEqual(3.0, LastProgress, 0.0001, 'the final notification reaches the total');
end;

procedure TStdioTransportTests.ModernRequest_OverStdio;
begin
  var Lines := Run([
    '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}']);
  var Json := GetById(Lines, '1');
  try
    Assert.AreEqual('complete', Json.GetValue<string>('result.resultType'));
    Assert.AreEqual(0, Json.GetValue<Integer>('result.ttlMs'));
  finally
    Json.Free;
  end;
end;

procedure TStdioTransportTests.Eof_WithRunningRequest_IsAnsweredWithAnErrorAfterTheDrain;
begin
  const Running = Format(SLOW_CALL, [4, LONG_STEPS]);

  const Lines = Run([Running], 300);

  AssertLineCount(Lines, 1, 'the request still running at the bound gets an answer');
  AssertErrorAnswer(Lines, '4', SHUTTING_DOWN);
  const ReturnedSoon = (FElapsedMs < 3000);
  const Elapsed = Format('Run returned after the drain timeout: %d ms', [FElapsedMs]);
  Assert.IsTrue(ReturnedSoon, Elapsed);
end;

procedure TStdioTransportTests.Eof_QueuedRequestsWithinTheBound_AreAllAnswered;
begin
  FHarness.Settings.StdioShutdownDrainMs := 10000;
  const First = Format(SLOW_CALL, [1, 3]);
  const Second = Format(SLOW_CALL, [2, 3]);
  const Third = Format(SLOW_CALL, [3, 3]);

  const Lines = Run([First, Second, Third]);

  AssertLineCount(Lines, 3, 'every queued request finishes within the bound');
  for var Id in ['1', '2', '3'] do
  begin
    const Answer = GetById(Lines, Id);
    try
      const Text = Answer.GetValue<string>(FIRST_TEXT_PATH);
      Assert.AreEqual('Completed 3 steps', Text);
    finally
      Answer.Free;
    end;
  end;
end;

procedure TStdioTransportTests.Eof_PastTheBound_AnswersTheRestWithAnError;
begin
  const Quick = Format(ECHO_CALL, [1]);
  const Long = Format(SLOW_CALL, [2, LONG_STEPS]);
  const Queued = Format(ECHO_CALL, [3]);

  const Lines = Run([Quick, Long, Queued], 500);

  AssertLineCount(Lines, 3, 'every request gets exactly one answer');
  const Finished = GetById(Lines, '1');
  try
    const Text = Finished.GetValue<string>(FIRST_TEXT_PATH);
    Assert.AreEqual(QUICK_ANSWER, Text);
  finally
    Finished.Free;
  end;
  AssertErrorAnswer(Lines, '2', SHUTTING_DOWN);
  AssertErrorAnswer(Lines, '3', SHUTTING_DOWN);
end;

procedure TStdioTransportTests.Eof_RequestTheClientCancelled_GetsNoAnswer;
begin
  const Long = Format(SLOW_CALL, [5, 50]);
  const Cancel = '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":5}}';

  const Lines = Run([Long, Cancel], 0);

  AssertLineCount(Lines, 0, 'a request the client cancelled is never answered');
end;

procedure TStdioTransportTests.Eof_HandlerThatIgnoresCancellation_IsAnsweredOnce;
begin
  const Gate: IStubbornGate = TStubbornGate.Create;
  const Tool: IMCPTool = TStubbornTool.Create(Gate);
  FHarness.ToolsManager.AddTool(Tool);
  const Log = TMCPTestLogWatch.Create;
  try
    const Output = TBytesStream.Create;
    try
      RunInto(Output, FHarness.ManagerRegistry, STUBBORN_CALL, 100);
      const AtShutdown = ReadOutput(Output);
      Gate.Release;
      const HasReturned = Gate.WaitUntilReturned;
      const IsDropped = Log.WaitFor(LATE_ANSWER_LOG_FRAGMENT);
      const AfterItReturned = ReadOutput(Output);

      Assert.IsTrue(HasReturned, 'the stubborn tool returned once it was released');
      Assert.IsTrue(IsDropped, 'the late result reached the transport after it stopped');
      AssertLineCount(AtShutdown, 1, 'the transport answered before the handler returned');
      AssertErrorAnswer(AtShutdown, '1', SHUTTING_DOWN);
      AssertLineCount(AfterItReturned, 1, 'the late result is not sent a second time');
    finally
      Output.Free;
    end;
  finally
    Log.Free;
  end;
end;

procedure TStdioTransportTests.Eof_ListenerThatOutlivesTheDrain_IsAnsweredWithAnError;
begin
  const Gate: IStubbornGate = TStubbornGate.Create;
  const ListenManager: IMCPCapabilityManager = TStubbornListenManager.Create(Gate);
  const CoreManager: IMCPCapabilityManager = TMCPCoreManager.Create(FHarness.Settings);
  const Registry: IMCPManagerRegistry = TMCPManagerRegistry.Create;
  Registry.RegisterManager(CoreManager);
  Registry.RegisterManager(ListenManager);
  const Log = TMCPTestLogWatch.Create;
  try
    const Output = TBytesStream.Create;
    try
      RunInto(Output, Registry, STUBBORN_LISTEN, LISTENER_DRAIN_MS);
      const AtShutdown = ReadOutput(Output);
      Gate.Release;
      const IsDropped = Log.WaitFor(LATE_ANSWER_LOG_FRAGMENT);

      AssertLineCount(AtShutdown, 1, 'a listener that does not close in time is answered');
      AssertErrorAnswer(AtShutdown, '9', SHUTTING_DOWN);
      Assert.IsTrue(IsDropped, 'the listener returned after the transport stopped');
    finally
      Output.Free;
    end;
  finally
    Log.Free;
  end;
end;

procedure TStdioTransportTests.Eof_NegativeDrain_AnswersAtOnce;
begin
  FHarness.Settings.StdioShutdownDrainMs := -5;
  const Running = Format(SLOW_CALL, [4, LONG_STEPS]);

  const Lines = Run([Running]);

  AssertLineCount(Lines, 1, 'a negative bound is no bound at all');
  AssertErrorAnswer(Lines, '4', SHUTTING_DOWN);
end;

procedure TStdioTransportTests.ShutdownDrainMs_SetBeforeTheSettings_IsKept;
begin
  FHarness.Settings.StdioShutdownDrainMs := 10000;
  const Transport = TMCPStdioTransport.Create(FHarness.ManagerRegistry, FHarness.CoreManager);
  try
    Transport.ShutdownDrainMs := 100;

    Transport.Settings := FHarness.Settings;

    const DrainMs = Transport.ShutdownDrainMs;
    Assert.AreEqual(100, DrainMs, 'a bound set in code wins over the setting');
  finally
    Transport.Free;
  end;
end;

procedure TStdioTransportTests.ShutdownDrainMs_NotSet_FollowsTheSettings;
begin
  FHarness.Settings.StdioShutdownDrainMs := 10000;
  const Transport = TMCPStdioTransport.Create(FHarness.ManagerRegistry, FHarness.CoreManager);
  try
    Transport.Settings := FHarness.Settings;

    const DrainMs = Transport.ShutdownDrainMs;
    Assert.AreEqual(10000, DrainMs, 'without a bound in code the setting applies');
  finally
    Transport.Free;
  end;
end;

procedure TStdioTransportTests.Listen_AckThenCancel_HasNoResponse;
const
  LISTEN = '{"jsonrpc":"2.0","id":9,"method":"subscriptions/listen","params":{"notifications":{"toolsListChanged":true},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}';
  CANCEL = '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":9}}';
  PING = '{"jsonrpc":"2.0","id":10,"method":"ping"}';
begin
  var Lines := Run([LISTEN, PING, CANCEL]);
  AssertLineCount(Lines, 2, 'the acknowledgement and the pong');
  var Ack := FindNotification(Lines, 'notifications/subscriptions/acknowledged');
  try
    Assert.IsNotNull(Ack, 'the subscription is acknowledged');
    Assert.AreEqual(9, TJSONNumber(TJSONObject(Ack.FindValue('params._meta')).GetValue(MCP_META_SUBSCRIPTION_ID)).AsInt);
    Assert.IsTrue(Ack.GetValue<Boolean>('params.notifications.toolsListChanged'));
  finally
    Ack.Free;
  end;
  var Pong := GetById(Lines, '10');
  try
    Assert.IsNotNull(Pong, 'ping is answered while a subscription is open');
  finally
    Pong.Free;
  end;
  var Response := FindById(Lines, '9');
  Assert.IsNull(Response, 'a cancelled subscription gets no response');
end;

procedure TStdioTransportTests.Listen_Eof_ClosesGracefully;
const
  LISTEN = '{"jsonrpc":"2.0","id":9,"method":"subscriptions/listen","params":{"notifications":{"promptsListChanged":true},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}';
  TRIGGER = '{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"test_trigger_prompt_change","arguments":{},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}';
  SLOW = '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"test_tool_with_progress","arguments":{"steps":3,"stepMs":100}}}';
begin
  var Lines := Run([LISTEN, SLOW, TRIGGER]);
  const Output = string.Join(OUTPUT_SEPARATOR, Lines);
  const HasEveryAnswer = (Length(Lines) >= 4);
  Assert.IsTrue(HasEveryAnswer, Output);
  var Ack := FindNotification(Lines, 'notifications/subscriptions/acknowledged');
  try
    Assert.IsNotNull(Ack, 'the subscription is acknowledged');
  finally
    Ack.Free;
  end;
  var Changed := False;
  for var Line in Lines do
  begin
    if Line.Contains('"notifications/prompts/list_changed"') then
      Changed := True;
  end;
  Assert.IsTrue(Changed, 'the prompt change reached the subscription');
  var Response := GetById(Lines, '9');
  try
    Assert.IsNotNull(Response, 'stdin closing ends the subscription with a response');
    Assert.AreEqual('complete', Response.GetValue<string>('result.resultType'));
    Assert.AreEqual(9, TJSONNumber(TJSONObject(Response.FindValue('result._meta')).GetValue(MCP_META_SUBSCRIPTION_ID)).AsInt);
  finally
    Response.Free;
  end;
end;

procedure TStdioTransportTests.UnsetRequestStateKey_IsNotWarnedAbout;
begin
  FHarness.Settings.RequestStateKey := '';
  const Log = TMCPTestLogWatch.Create;
  try
    Run([INITIALIZE]);

    const Warnings = Log.CountOf(TMCPRequestStateSealer.EPHEMERAL_KEY_WARNING);
    Assert.AreEqual(0, Warnings, 'a stdio server lives exactly as long as its one client');
  finally
    Log.Free;
  end;
end;

end.
