unit MCPServer.Tests.Stdio;

interface

uses
  DUnitX.TestFramework,
  System.SysUtils,
  System.Classes,
  System.JSON,
  System.Rtti,
  System.SyncObjs,
  MCPServer.Types,
  MCPServer.Tool.Base,
  MCPServer.StdioTransport,
  MCPServer.Tests.Harness;

type
  TStubbornTool = class(TMCPToolBase)
  strict private
    FReleased: TEvent;
    FReturned: TEvent;
  protected
    function BuildSchema: TJSONObject; override;
    function DoExecute(const Arguments: TJSONObject): TValue; override;
  public
    constructor Create; override;
    destructor Destroy; override;

    procedure Release;
    function WaitUntilReturned: Boolean;
  end;

  [TestFixture]
  TStdioTransportTests = class
  private
    const KEEP_THE_SETTINGS_DRAIN = -1;
  private
    FHarness: TMCPTestHarness;
    FOutputBytes: TBytes;
    FElapsedMs: Int64;
    function Run(const Lines: array of string; DrainMs: Integer = KEEP_THE_SETTINGS_DRAIN;
      const Separator: string = #10): TArray<string>;
    function OutputLines(const Output: TBytesStream): TArray<string>;
    procedure AssertShuttingDownError(const Lines: TArray<string>; const Id: string);
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
    procedure Listen_AckThenCancel_HasNoResponse;

    [Test]
    procedure Listen_Eof_ClosesGracefully;

    [Test]
    procedure UnsetRequestStateKey_IsNotWarnedAbout;
  end;

implementation

uses
  System.Diagnostics,
  MCPServer.Logger,
  MCPServer.RequestState;

const
  INITIALIZE = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}';
  INITIALIZED = '{"jsonrpc":"2.0","method":"notifications/initialized"}';
  SLOW_CALL = '{"jsonrpc":"2.0","id":%d,"method":"tools/call","params":{"name":"test_tool_with_progress","arguments":{"steps":%d,"stepMs":100}}}';
  STUBBORN_TOOL_NAME = 'test_stubborn_tool';
  STUBBORN_CALL = '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"' + STUBBORN_TOOL_NAME + '","arguments":{}}}';
  SHUTTING_DOWN = 'shutting down';
  STUBBORN_WAIT_MS = 10000;
  LATE_ANSWER_GRACE_MS = 300;

{ TStubbornTool }

constructor TStubbornTool.Create;
begin
  inherited Create;
  FName := STUBBORN_TOOL_NAME;
  FDescription := 'A tool that never looks at its cancellation';
  FReleased := TEvent.Create(nil, True, False, '');
  FReturned := TEvent.Create(nil, True, False, '');
end;

destructor TStubbornTool.Destroy;
begin
  FReturned.Free;
  FReleased.Free;
  inherited;
end;

function TStubbornTool.BuildSchema: TJSONObject;
begin
  Result := TJSONObject.ParseJSONValue(
    '{"type":"object","properties":{},"additionalProperties":false}') as TJSONObject;
end;

function TStubbornTool.DoExecute(const Arguments: TJSONObject): TValue;
begin
  FReleased.WaitFor(STUBBORN_WAIT_MS);
  FReturned.SetEvent;
  Result := TValue.From<string>('finished late');
end;

procedure TStubbornTool.Release;
begin
  FReleased.SetEvent;
end;

function TStubbornTool.WaitUntilReturned: Boolean;
begin
  Result := (FReturned.WaitFor(STUBBORN_WAIT_MS) = TWaitResult.wrSignaled);
end;

{ TStdioTransportTests }

procedure TStdioTransportTests.Setup;
begin
  FHarness := TMCPTestHarness.Create;
end;

procedure TStdioTransportTests.TearDown;
begin
  FHarness.Free;
end;

function TStdioTransportTests.Run(const Lines: array of string; DrainMs: Integer;
  const Separator: string): TArray<string>;
begin
  var Input := '';
  for var Line in Lines do
  begin
    Input := Input + Line + Separator;
  end;

  var InputStream := TBytesStream.Create(TEncoding.UTF8.GetBytes(Input));
  var OutputStream := TBytesStream.Create;
  var Transport := TMCPStdioTransport.Create(FHarness.ManagerRegistry, FHarness.CoreManager);
  try
    Transport.Settings := FHarness.Settings;
    const KeepsTheSettingsDrain = (DrainMs = KEEP_THE_SETTINGS_DRAIN);
    if not KeepsTheSettingsDrain then
      Transport.ShutdownDrainMs := DrainMs;
    var Watch := TStopwatch.StartNew;
    Transport.RunWith(InputStream, OutputStream);
    FElapsedMs := Watch.ElapsedMilliseconds;

    FOutputBytes := Copy(OutputStream.Bytes, 0, OutputStream.Size);
    Result := TEncoding.UTF8.GetString(FOutputBytes).Split([#10], TStringSplitOptions.ExcludeEmpty);
  finally
    Transport.Free;
    OutputStream.Free;
    InputStream.Free;
  end;
end;

function TStdioTransportTests.OutputLines(const Output: TBytesStream): TArray<string>;
begin
  const Bytes = Copy(Output.Bytes, 0, Output.Size);
  const Text = TEncoding.UTF8.GetString(Bytes);
  Result := Text.Split([#10], TStringSplitOptions.ExcludeEmpty);
end;

procedure TStdioTransportTests.AssertShuttingDownError(const Lines: TArray<string>; const Id: string);
begin
  const Answer = GetById(Lines, Id);
  try
    Assert.AreEqual(JSONRPC_INTERNAL_ERROR, Answer.GetValue<Integer>('error.code'), Answer.ToJSON);
    Assert.Contains(Answer.GetValue<string>('error.message'), SHUTTING_DOWN);
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
  Assert.IsNotNull(Result, Format('no message with id %s in %s', [Id, string.Join(' | ', Lines)]));
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
    Assert.AreEqual('Echo: ' + Probe, Echo.GetValue<string>('result.content[0].text'));
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
        Assert.AreEqual('Completed 3 steps', Json.GetValue<string>('result.content[0].text'));
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
  const Running = Format(SLOW_CALL, [4, 100]);

  const Lines = Run([Running], 300);

  Assert.AreEqual(1, Integer(Length(Lines)), 'the request still running at the bound gets an answer');
  AssertShuttingDownError(Lines, '4');
  Assert.IsTrue(FElapsedMs < 3000, Format('Run returned after the drain timeout: %d ms', [FElapsedMs]));
end;

procedure TStdioTransportTests.Eof_QueuedRequestsWithinTheBound_AreAllAnswered;
begin
  FHarness.Settings.StdioShutdownDrainMs := 10000;
  const First = Format(SLOW_CALL, [1, 8]);
  const Second = Format(SLOW_CALL, [2, 8]);
  const Third = Format(SLOW_CALL, [3, 8]);

  const Lines = Run([First, Second, Third]);

  Assert.AreEqual(3, Integer(Length(Lines)), string.Join(' | ', Lines));
  for var Id in ['1', '2', '3'] do
  begin
    const Answer = GetById(Lines, Id);
    try
      Assert.AreEqual('Completed 8 steps', Answer.GetValue<string>('result.content[0].text'));
    finally
      Answer.Free;
    end;
  end;
end;

procedure TStdioTransportTests.Eof_PastTheBound_AnswersTheRestWithAnError;
begin
  const Quick = Format(SLOW_CALL, [1, 2]);
  const Long = Format(SLOW_CALL, [2, 50]);
  const Queued = Format(SLOW_CALL, [3, 2]);

  const Lines = Run([Quick, Long, Queued], 500);

  Assert.AreEqual(3, Integer(Length(Lines)), 'every request gets exactly one answer: ' + string.Join(' | ', Lines));
  const Finished = GetById(Lines, '1');
  try
    Assert.AreEqual('Completed 2 steps', Finished.GetValue<string>('result.content[0].text'));
  finally
    Finished.Free;
  end;
  AssertShuttingDownError(Lines, '2');
  AssertShuttingDownError(Lines, '3');
end;

procedure TStdioTransportTests.Eof_RequestTheClientCancelled_GetsNoAnswer;
begin
  const Long = Format(SLOW_CALL, [5, 50]);
  const Cancel = '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":5}}';

  const Lines = Run([Long, Cancel], 0);

  Assert.AreEqual(0, Integer(Length(Lines)), 'a request the client cancelled is never answered: ' +
    string.Join(' | ', Lines));
end;

procedure TStdioTransportTests.Eof_HandlerThatIgnoresCancellation_IsAnsweredOnce;
begin
  const Stubborn = TStubbornTool.Create;
  const StubbornTool: IMCPTool = Stubborn;
  FHarness.ToolsManager.AddTool(StubbornTool);
  const Input = TBytesStream.Create(TEncoding.UTF8.GetBytes(STUBBORN_CALL + #10));
  const Output = TBytesStream.Create;
  const Transport = TMCPStdioTransport.Create(FHarness.ManagerRegistry, FHarness.CoreManager);
  try
    Transport.Settings := FHarness.Settings;
    Transport.ShutdownDrainMs := 100;

    Transport.RunWith(Input, Output);
    const AtShutdown = OutputLines(Output);
    Stubborn.Release;
    const HasReturned = Stubborn.WaitUntilReturned;
    Sleep(LATE_ANSWER_GRACE_MS);
    const AfterItReturned = OutputLines(Output);

    Assert.IsTrue(HasReturned, 'the stubborn tool returned once it was released');
    Assert.AreEqual(1, Integer(Length(AtShutdown)), 'the transport answered before it returned');
    AssertShuttingDownError(AtShutdown, '1');
    Assert.AreEqual(1, Integer(Length(AfterItReturned)), 'the late result is not sent a second time');
  finally
    Transport.Free;
    Output.Free;
    Input.Free;
  end;
end;

procedure TStdioTransportTests.Listen_AckThenCancel_HasNoResponse;
const
  LISTEN = '{"jsonrpc":"2.0","id":9,"method":"subscriptions/listen","params":{"notifications":{"toolsListChanged":true},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}';
  CANCEL = '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":9}}';
  PING = '{"jsonrpc":"2.0","id":10,"method":"ping"}';
begin
  var Lines := Run([LISTEN, PING, CANCEL]);
  Assert.AreEqual(2, Integer(Length(Lines)), string.Join(' | ', Lines));
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
  Assert.IsTrue(Length(Lines) >= 4, string.Join(' | ', Lines));
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
  const Warnings = TStringList.Create;
  try
    TLogger.OnLogMessage :=
      procedure(const Message: string)
      begin
        const IsKeyWarning = Message.Contains(TMCPRequestStateSealer.EPHEMERAL_KEY_WARNING);
        if IsKeyWarning then
          Warnings.Add(Message);
      end;

    Run([INITIALIZE]);

    Assert.AreEqual(0, Warnings.Count, 'a stdio server lives exactly as long as its one client');
  finally
    TLogger.OnLogMessage := nil;
    Warnings.Free;
  end;
end;

end.
