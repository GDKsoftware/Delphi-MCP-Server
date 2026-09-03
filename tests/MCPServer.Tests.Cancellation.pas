unit MCPServer.Tests.Cancellation;

interface

uses
  DUnitX.TestFramework,
  System.SysUtils,
  System.Classes,
  System.JSON,
  MCPServer.Types,
  MCPServer.RequestContext,
  MCPServer.Tests.Harness;

type
  /// Collects what a context sends through the sink.
  TRecordingSink = class(TInterfacedObject, IMCPMessageSink)
  private
    FMessages: TStrings;
  public
    constructor Create(Messages: TStrings);
    procedure Send(const Json: string);
  end;

  /// A tracker that cancels every request as soon as it is tracked and
  /// records the cancellations it is asked for.
  TCancellingTracker = class(TInterfacedObject, IMCPRequestTracker)
  private
    FCancelOnTrack: Boolean;
    FCancelledIds: TStrings;
    FReasons: TStrings;
  public
    constructor Create(CancelOnTrack: Boolean; CancelledIds, Reasons: TStrings);
    procedure Track(const Context: IMCPRequestContext);
    procedure Untrack(const Context: IMCPRequestContext);
    function TryCancel(const RequestId: TMCPRequestId; const Reason: string): Boolean;
  end;

  [TestFixture]
  TCancellationTests = class
  private
    FMessages: TStringList;
    FSink: IMCPMessageSink;
    function NewContext(const MetaJson: string): IMCPRequestContext;
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    [Test] procedure Cancel_SetsIsCancelled_And_CheckRaises;
    [Test] procedure Progress_WithoutToken_SendsNothing;
    [Test] procedure Progress_NotificationShape;
    [Test] procedure Progress_IntegerToken_IsKept;
    [Test] procedure Progress_Monotonic_And_Throttled;
    [Test] procedure Progress_AfterCancel_SendsNothing;
    [Test] procedure Progress_WithoutSink_IsNoOp;
    [Test] procedure Processor_CancelledRequest_HasNoResponse;
    [Test] procedure Processor_CancelledNotification_ReachesTracker;
  end;

implementation

uses
  MCPServer.Errors,
  MCPServer.JsonRpcProcessor;

{ TRecordingSink }

constructor TRecordingSink.Create(Messages: TStrings);
begin
  inherited Create;
  FMessages := Messages;
end;

procedure TRecordingSink.Send(const Json: string);
begin
  FMessages.Add(Json);
end;

{ TCancellingTracker }

constructor TCancellingTracker.Create(CancelOnTrack: Boolean; CancelledIds, Reasons: TStrings);
begin
  inherited Create;
  FCancelOnTrack := CancelOnTrack;
  FCancelledIds := CancelledIds;
  FReasons := Reasons;
end;

procedure TCancellingTracker.Track(const Context: IMCPRequestContext);
begin
  if FCancelOnTrack then
    Context.Cancel;
end;

procedure TCancellingTracker.Untrack(const Context: IMCPRequestContext);
begin
end;

function TCancellingTracker.TryCancel(const RequestId: TMCPRequestId; const Reason: string): Boolean;
begin
  FCancelledIds.Add(RequestId.AsText);
  FReasons.Add(Reason);
  Result := True;
end;

{ TCancellationTests }

procedure TCancellationTests.Setup;
begin
  FMessages := TStringList.Create;
  FSink := TRecordingSink.Create(FMessages);
end;

procedure TCancellationTests.TearDown;
begin
  FSink := nil;
  FMessages.Free;
end;

function TCancellationTests.NewContext(const MetaJson: string): IMCPRequestContext;
begin
  var Meta: TJSONObject := nil;
  if MetaJson <> '' then
    Meta := TJSONObject.ParseJSONValue(MetaJson) as TJSONObject;
  try
    Result := TMCPRequestContext.Create(TMCPProtocolEra.Modern, MCP_LATEST_PROTOCOL_VERSION, 'tools/call',
      TMCPRequestId.FromNumber(7), Meta, nil, nil, FSink);
  finally
    Meta.Free;
  end;
end;

procedure TCancellationTests.Cancel_SetsIsCancelled_And_CheckRaises;
begin
  var Context := NewContext('');
  Assert.IsFalse(Context.IsCancelled);
  Context.CheckCancelled;
  Context.Cancel;
  Assert.IsTrue(Context.IsCancelled);
  var Check: TProc := procedure begin Context.CheckCancelled end;
  Assert.WillRaise(Check, EMCPRequestCancelled);
end;

procedure TCancellationTests.Progress_WithoutToken_SendsNothing;
begin
  var Context := NewContext('{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}');
  Assert.IsFalse(Context.HasProgressToken);
  Context.ReportProgress(1, 2, 'half');
  Assert.AreEqual(0, FMessages.Count);
end;

procedure TCancellationTests.Progress_NotificationShape;
begin
  var Context := NewContext('{"progressToken":"abc"}');
  Assert.IsTrue(Context.HasProgressToken);
  Context.ReportProgress(1, 4, 'quarter');
  Assert.AreEqual(1, FMessages.Count);
  var Json := TJSONObject.ParseJSONValue(FMessages[0]) as TJSONObject;
  try
    Assert.AreEqual('2.0', Json.GetValue<string>('jsonrpc'));
    Assert.AreEqual('notifications/progress', Json.GetValue<string>('method'));
    Assert.AreEqual('abc', Json.GetValue<string>('params.progressToken'));
    Assert.AreEqual(1.0, Json.GetValue<Double>('params.progress'), 0.0001);
    Assert.AreEqual(4.0, Json.GetValue<Double>('params.total'), 0.0001);
    Assert.AreEqual('quarter', Json.GetValue<string>('params.message'));
    Assert.IsNull(Json.GetValue('id'));
  finally
    Json.Free;
  end;
end;

procedure TCancellationTests.Progress_IntegerToken_IsKept;
begin
  var Context := NewContext('{"progressToken":42}');
  Context.ReportProgress(0.5);
  var Json := TJSONObject.ParseJSONValue(FMessages[0]) as TJSONObject;
  try
    Assert.AreEqual(42, Json.GetValue<Integer>('params.progressToken'));
    Assert.AreEqual(0.5, Json.GetValue<Double>('params.progress'), 0.0001);
    Assert.IsNull(Json.FindValue('params.total'), 'unknown total is omitted');
  finally
    Json.Free;
  end;
end;

procedure TCancellationTests.Progress_Monotonic_And_Throttled;
begin
  var Context := NewContext('{"progressToken":"t"}');
  Context.ReportProgress(1, 10);
  Context.ReportProgress(0.5, 10);
  Assert.AreEqual(1, FMessages.Count, 'a smaller value is dropped');
  Context.ReportProgress(2, 10);
  Assert.AreEqual(1, FMessages.Count, 'a burst within the interval is dropped');
  Context.ReportProgress(10, 10);
  Assert.AreEqual(2, FMessages.Count, 'reaching the total is always sent');
  Sleep(PROGRESS_MIN_INTERVAL_MS + 20);
  Context.ReportProgress(11);
  Assert.AreEqual(3, FMessages.Count, 'after the interval the next value goes out');
end;

procedure TCancellationTests.Progress_AfterCancel_SendsNothing;
begin
  var Context := NewContext('{"progressToken":"t"}');
  Context.Cancel;
  Context.ReportProgress(1, 2);
  Assert.AreEqual(0, FMessages.Count);
end;

procedure TCancellationTests.Progress_WithoutSink_IsNoOp;
begin
  var Meta := TJSONObject.ParseJSONValue('{"progressToken":"t"}') as TJSONObject;
  try
    var Context: IMCPRequestContext := TMCPRequestContext.Create(TMCPProtocolEra.Legacy,
      MCP_LATEST_LEGACY_PROTOCOL_VERSION, 'tools/call', TMCPRequestId.FromNumber(1), Meta, nil, nil);
    Context.ReportProgress(1, 2);
    Assert.IsTrue(Context.HasProgressToken);
  finally
    Meta.Free;
  end;
end;

procedure TCancellationTests.Processor_CancelledRequest_HasNoResponse;
begin
  var Harness := TMCPTestHarness.Create;
  var Ids := TStringList.Create;
  var Reasons := TStringList.Create;
  var Processor := TMCPJsonRpcProcessor.Create(Harness.ManagerRegistry);
  try
    var Hints := TMCPTransportHints.ForStdio(nil, FSink, TCancellingTracker.Create(True, Ids, Reasons));
    var Outcome := Processor.ProcessRequestEx(
      '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"echo","arguments":{"message":"x"}}}', Hints);
    Assert.IsTrue(Outcome.Cancelled);
    Assert.AreEqual('', Outcome.Body);
  finally
    Processor.Free;
    Reasons.Free;
    Ids.Free;
    Harness.Free;
  end;
end;

procedure TCancellationTests.Processor_CancelledNotification_ReachesTracker;
begin
  var Harness := TMCPTestHarness.Create;
  var Ids := TStringList.Create;
  var Reasons := TStringList.Create;
  var Processor := TMCPJsonRpcProcessor.Create(Harness.ManagerRegistry);
  try
    var Hints := TMCPTransportHints.ForStdio(nil, FSink, TCancellingTracker.Create(False, Ids, Reasons));
    var Outcome := Processor.ProcessRequestEx(
      '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":5,"reason":"user"}}', Hints);
    Assert.AreEqual('', Outcome.Body);
    Assert.IsTrue(Outcome.IsNotification);
    Assert.AreEqual(1, Ids.Count);
    Assert.AreEqual('5', Ids[0]);
    Assert.AreEqual('user', Reasons[0]);

    Outcome := Processor.ProcessRequestEx(
      '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"abc"}}', Hints);
    Assert.AreEqual('abc', Ids[1]);
    Assert.AreEqual('', Reasons[1]);
  finally
    Processor.Free;
    Reasons.Free;
    Ids.Free;
    Harness.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TCancellationTests);

end.
