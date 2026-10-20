unit MCPServer.Tests.StdioRequestTracker;

interface

uses
  DUnitX.TestFramework,
  MCPServer.Types,
  MCPServer.StdioTransport;

type
  [TestFixture]
  TStdioRequestTrackerTests = class
  private
    FTracker: TMCPStdioRequestTracker;
    FTrackerLifetime: IMCPRequestTracker;
    function NewContext(const RequestId: TMCPRequestId): IMCPRequestContext;

  public
    [Setup]
    procedure Setup;

    [TearDown]
    procedure TearDown;

    [Test]
    procedure TryClaimAnswer_FirstClaim_Wins;

    [Test]
    procedure TryClaimAnswer_SecondClaim_Loses;

    [Test]
    procedure TryClaimAnswer_AfterTheClientCancelled_Loses;

    [Test]
    procedure TryClaimAnswer_UnknownRequest_Wins;

    [Test]
    procedure ClaimUnanswered_ReturnsOnlyTheRequestsStillOwedAnAnswer;

    [Test]
    procedure ClaimUnanswered_SecondCall_ReturnsNothing;

    [Test]
    procedure Untrack_ReservedRequest_StaysOwedAnAnswer;

    [Test]
    procedure Untrack_RequestThatWasNotReserved_IsForgotten;

    [Test]
    procedure Track_AfterCancelAll_CancelsTheContext;
  end;

implementation

uses
  MCPServer.RequestContext;

const
  FIRST_ID      = 1;
  SECOND_ID     = 2;
  THIRD_ID      = 3;
  CANCEL_REASON = 'test';

{ TStdioRequestTrackerTests }

procedure TStdioRequestTrackerTests.Setup;
begin
  FTracker := TMCPStdioRequestTracker.Create;
  FTrackerLifetime := FTracker;
end;

procedure TStdioRequestTrackerTests.TearDown;
begin
  FTrackerLifetime := nil;
end;

function TStdioRequestTrackerTests.NewContext(const RequestId: TMCPRequestId): IMCPRequestContext;
begin
  Result := TMCPRequestContext.Create(TMCPProtocolEra.Modern, MCP_LATEST_PROTOCOL_VERSION, MCP_METHOD_TOOLS_CALL,
                                      RequestId, nil, nil, nil);
end;

procedure TStdioRequestTrackerTests.TryClaimAnswer_FirstClaim_Wins;
begin
  const RequestId = TMCPRequestId.FromNumber(FIRST_ID);
  FTracker.Reserve(RequestId);

  const IsClaimed = FTracker.TryClaimAnswer(RequestId);

  Assert.IsTrue(IsClaimed, 'the first answer to a request goes out');
end;

procedure TStdioRequestTrackerTests.TryClaimAnswer_SecondClaim_Loses;
begin
  const RequestId = TMCPRequestId.FromNumber(FIRST_ID);
  FTracker.Reserve(RequestId);
  FTracker.TryClaimAnswer(RequestId);

  const IsClaimed = FTracker.TryClaimAnswer(RequestId);

  Assert.IsFalse(IsClaimed, 'a request is answered once');
end;

procedure TStdioRequestTrackerTests.TryClaimAnswer_AfterTheClientCancelled_Loses;
begin
  const RequestId = TMCPRequestId.FromNumber(FIRST_ID);
  FTracker.Reserve(RequestId);
  FTracker.TryCancel(RequestId, CANCEL_REASON);

  const IsClaimed = FTracker.TryClaimAnswer(RequestId);

  Assert.IsFalse(IsClaimed, 'a request the client cancelled gets no answer');
end;

procedure TStdioRequestTrackerTests.TryClaimAnswer_UnknownRequest_Wins;
begin
  const RequestId = TMCPRequestId.FromNumber(FIRST_ID);

  const IsClaimed = FTracker.TryClaimAnswer(RequestId);

  Assert.IsTrue(IsClaimed, 'a request the tracker does not hold is not held back');
end;

procedure TStdioRequestTrackerTests.ClaimUnanswered_ReturnsOnlyTheRequestsStillOwedAnAnswer;
begin
  const Answered  = TMCPRequestId.FromNumber(FIRST_ID);
  const Cancelled = TMCPRequestId.FromNumber(SECOND_ID);
  const Waiting   = TMCPRequestId.FromNumber(THIRD_ID);
  FTracker.Reserve(Answered);
  FTracker.Reserve(Cancelled);
  FTracker.Reserve(Waiting);
  FTracker.TryClaimAnswer(Answered);
  FTracker.TryCancel(Cancelled, CANCEL_REASON);

  const Unanswered = FTracker.ClaimUnanswered;

  const UnansweredCount = Length(Unanswered);
  const Claimed         = Unanswered[0];
  const ExpectedId      = Waiting.AsText;
  const ClaimedId       = Claimed.AsText;
  Assert.AreEqual<NativeInt>(1, UnansweredCount);
  Assert.AreEqual(ExpectedId, ClaimedId);
end;

procedure TStdioRequestTrackerTests.ClaimUnanswered_SecondCall_ReturnsNothing;
begin
  const RequestId = TMCPRequestId.FromNumber(FIRST_ID);
  FTracker.Reserve(RequestId);
  FTracker.ClaimUnanswered;

  const Unanswered = FTracker.ClaimUnanswered;

  const UnansweredCount = Length(Unanswered);
  Assert.AreEqual<NativeInt>(0, UnansweredCount, 'a claimed request is not claimed again');
end;

procedure TStdioRequestTrackerTests.Untrack_ReservedRequest_StaysOwedAnAnswer;
begin
  const RequestId = TMCPRequestId.FromNumber(FIRST_ID);
  const Context = NewContext(RequestId);
  FTracker.Reserve(RequestId);
  FTracker.Track(Context);

  FTracker.Untrack(Context);

  const Unanswered = FTracker.ClaimUnanswered;
  const UnansweredCount = Length(Unanswered);
  Assert.AreEqual<NativeInt>(1, UnansweredCount, 'a queued request keeps its place until it is answered');
end;

procedure TStdioRequestTrackerTests.Untrack_RequestThatWasNotReserved_IsForgotten;
begin
  const RequestId = TMCPRequestId.FromNumber(FIRST_ID);
  const Context = NewContext(RequestId);
  FTracker.Track(Context);

  FTracker.Untrack(Context);

  const Unanswered = FTracker.ClaimUnanswered;
  const UnansweredCount = Length(Unanswered);
  Assert.AreEqual<NativeInt>(0, UnansweredCount, 'a request answered inline leaves nothing behind');
end;

procedure TStdioRequestTrackerTests.Track_AfterCancelAll_CancelsTheContext;
begin
  const RequestId = TMCPRequestId.FromNumber(FIRST_ID);
  const Context = NewContext(RequestId);
  FTracker.Reserve(RequestId);
  FTracker.CancelAll(CANCEL_REASON);

  FTracker.Track(Context);

  Assert.IsTrue(Context.IsCancelled, 'a request that starts after the abort is cancelled at once');
end;

end.
