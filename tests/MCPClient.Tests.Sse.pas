unit MCPClient.Tests.Sse;

interface

uses
  System.SysUtils,
  DUnitX.TestFramework;

type
  [TestFixture]
  TMCPSseParserTests = class
  private
    function Drain(const Chunks: TArray<string>): TArray<string>;
    function DrainBytes(const Chunks: TArray<TBytes>): TArray<string>;
    function Frame(const EventName, Data: string): string;
  public
    [Test]
    procedure TryNext_NothingAppended_ReturnsFalse;

    [Test]
    procedure TryNext_OneFrame_ReturnsTheNameAndTheData;

    [Test]
    procedure TryNext_KeepAliveComment_IsDropped;

    [Test]
    procedure TryNext_FrameSplitAcrossTwoChunks_ReturnsOneWholeFrame;

    [Test]
    procedure TryNext_SplitBetweenTheTerminatingNewlines_ReturnsTheFrameOnce;

    [Test]
    procedure TryNext_ChunkedSequenceWithKeepAlive_ReturnsEveryFrameInOrder;

    [Test]
    procedure TryNext_BatchedSingleFrameBody_ReturnsOneFrame;

    [Test]
    procedure TryNext_PartialTrailingLine_StaysInTheBuffer;

    [Test]
    procedure TryNext_TwoDataLines_AreJoinedWithALineFeed;

    [Test]
    procedure TryNext_CarriageReturnLineFeedEndings_AreAccepted;

    [Test]
    procedure TryNext_ServerEventText_IsReadBackUnchanged;

    [Test]
    procedure Finish_FrameWithoutATerminatingBlankLine_IsReturned;

    [Test]
    procedure Reset_AfterAPartialFrame_DropsTheBuffer;

    [Test]
    procedure AppendBytes_MultiByteCharacterSplitAcrossChunks_DecodesItWhole;
  end;

  [TestFixture]
  TMCPChallengeReaderTests = class
  public
    [Test]
    procedure Parameter_ScopeOnABearerChallenge_IsRead;

    [Test]
    procedure Parameter_ScopeAfterOtherParameters_IsRead;

    [Test]
    procedure Parameter_CommaInsideAQuotedValue_DoesNotSplitTheParameter;

    [Test]
    procedure Parameter_EscapedQuoteInsideAValue_IsUnescaped;

    [Test]
    procedure Parameter_AbsentName_ReturnsEmpty;
  end;

implementation

uses
  System.Generics.Collections,
  MCPServer.HttpStream,
  MCPClient.Http;

const
  KEEP_ALIVE = ': keep-alive'#10#10;
  EVENT_MESSAGE = 'message';
  RESPONSE_ONE = '{"jsonrpc":"2.0","id":1,"result":{"value":1}}';
  RESPONSE_TWO = '{"jsonrpc":"2.0","id":2,"result":{"value":2}}';
  RESPONSE_THREE = '{"jsonrpc":"2.0","id":3,"result":{"value":3}}';
  EURO = #$20AC;

{ TMCPSseParserTests }

function TMCPSseParserTests.Frame(const EventName, Data: string): string;
begin
  Result := 'event: ' + EventName + #10'data: ' + Data + #10#10;
end;

function TMCPSseParserTests.Drain(const Chunks: TArray<string>): TArray<string>;
begin
  var Collected := TList<string>.Create;
  try
    var Parser := TMCPSseParser.Create;
    try
      for var Chunk in Chunks do
      begin
        Parser.Append(Chunk);

        var Event: TMCPSseEvent;
        while Parser.TryNext(Event) do
          Collected.Add(Event.EventName + '|' + Event.Data);
      end;
    finally
      Parser.Free;
    end;
    Result := Collected.ToArray;
  finally
    Collected.Free;
  end;
end;

function TMCPSseParserTests.DrainBytes(const Chunks: TArray<TBytes>): TArray<string>;
begin
  var Collected := TList<string>.Create;
  try
    var Parser := TMCPSseParser.Create;
    try
      for var Chunk in Chunks do
      begin
        Parser.AppendBytes(Chunk);

        var Event: TMCPSseEvent;
        while Parser.TryNext(Event) do
          Collected.Add(Event.EventName + '|' + Event.Data);
      end;
    finally
      Parser.Free;
    end;
    Result := Collected.ToArray;
  finally
    Collected.Free;
  end;
end;

procedure TMCPSseParserTests.TryNext_NothingAppended_ReturnsFalse;
begin
  var Parser := TMCPSseParser.Create;
  try
    var Event: TMCPSseEvent;
    Assert.IsFalse(Parser.TryNext(Event));
  finally
    Parser.Free;
  end;
end;

procedure TMCPSseParserTests.TryNext_OneFrame_ReturnsTheNameAndTheData;
begin
  const Frames = Drain([Frame(EVENT_MESSAGE, RESPONSE_ONE)]);

  Assert.AreEqual(1, Integer(Length(Frames)));
  Assert.AreEqual(EVENT_MESSAGE + '|' + RESPONSE_ONE, Frames[0]);
end;

procedure TMCPSseParserTests.TryNext_KeepAliveComment_IsDropped;
begin
  const Frames = Drain([KEEP_ALIVE + KEEP_ALIVE + Frame(EVENT_MESSAGE, RESPONSE_ONE)]);

  Assert.AreEqual(1, Integer(Length(Frames)), 'a comment line must not produce a frame');
  Assert.AreEqual(EVENT_MESSAGE + '|' + RESPONSE_ONE, Frames[0]);
end;

procedure TMCPSseParserTests.TryNext_FrameSplitAcrossTwoChunks_ReturnsOneWholeFrame;
begin
  const Whole = Frame(EVENT_MESSAGE, RESPONSE_ONE);
  const Head = Copy(Whole, 1, 20);
  const Tail = Copy(Whole, 21, Length(Whole) - 20);

  const Frames = Drain([Head, Tail]);

  Assert.AreEqual(1, Integer(Length(Frames)));
  Assert.AreEqual(EVENT_MESSAGE + '|' + RESPONSE_ONE, Frames[0]);
end;

procedure TMCPSseParserTests.TryNext_SplitBetweenTheTerminatingNewlines_ReturnsTheFrameOnce;
begin
  const Frames = Drain(['event: ' + EVENT_MESSAGE + #10'data: ' + RESPONSE_ONE + #10, #10]);

  Assert.AreEqual(1, Integer(Length(Frames)));
  Assert.AreEqual(EVENT_MESSAGE + '|' + RESPONSE_ONE, Frames[0]);
end;

procedure TMCPSseParserTests.TryNext_ChunkedSequenceWithKeepAlive_ReturnsEveryFrameInOrder;
begin
  const Second = Frame(EVENT_MESSAGE, RESPONSE_TWO);

  const Frames = Drain([
    KEEP_ALIVE + Frame(EVENT_MESSAGE, RESPONSE_ONE) + Copy(Second, 1, 10),
    Copy(Second, 11, Length(Second) - 10) + KEEP_ALIVE,
    Frame(EVENT_MESSAGE, RESPONSE_THREE)]);

  Assert.AreEqual(3, Integer(Length(Frames)));
  Assert.AreEqual(EVENT_MESSAGE + '|' + RESPONSE_ONE, Frames[0]);
  Assert.AreEqual(EVENT_MESSAGE + '|' + RESPONSE_TWO, Frames[1]);
  Assert.AreEqual(EVENT_MESSAGE + '|' + RESPONSE_THREE, Frames[2]);
end;

procedure TMCPSseParserTests.TryNext_BatchedSingleFrameBody_ReturnsOneFrame;
begin
  const Frames = Drain([TMCPHttpResponseStream.EventText(RESPONSE_ONE)]);

  Assert.AreEqual(1, Integer(Length(Frames)), 'the batched body carries exactly one frame');
  Assert.AreEqual(EVENT_MESSAGE + '|' + RESPONSE_ONE, Frames[0]);
end;

procedure TMCPSseParserTests.TryNext_PartialTrailingLine_StaysInTheBuffer;
begin
  const Frames = Drain([Frame(EVENT_MESSAGE, RESPONSE_ONE) + 'event: mes']);

  Assert.AreEqual(1, Integer(Length(Frames)), 'an unterminated line must not be handed out');
  Assert.AreEqual(EVENT_MESSAGE + '|' + RESPONSE_ONE, Frames[0]);
end;

procedure TMCPSseParserTests.TryNext_TwoDataLines_AreJoinedWithALineFeed;
begin
  const Frames = Drain(['event: ' + EVENT_MESSAGE + #10'data: first'#10'data: second'#10#10]);

  Assert.AreEqual(1, Integer(Length(Frames)));
  Assert.AreEqual(EVENT_MESSAGE + '|first'#10'second', Frames[0]);
end;

procedure TMCPSseParserTests.TryNext_CarriageReturnLineFeedEndings_AreAccepted;
begin
  const Frames = Drain(['event: ' + EVENT_MESSAGE + #13#10'data: ' + RESPONSE_ONE + #13#10#13#10]);

  Assert.AreEqual(1, Integer(Length(Frames)));
  Assert.AreEqual(EVENT_MESSAGE + '|' + RESPONSE_ONE, Frames[0]);
end;

procedure TMCPSseParserTests.TryNext_ServerEventText_IsReadBackUnchanged;
begin
  const Frames = Drain([
    TMCPHttpResponseStream.EventText(RESPONSE_ONE),
    TMCPHttpResponseStream.EventText(RESPONSE_TWO)]);

  Assert.AreEqual(2, Integer(Length(Frames)), 'the client must read exactly what the server writes');
  Assert.AreEqual(EVENT_MESSAGE + '|' + RESPONSE_ONE, Frames[0]);
  Assert.AreEqual(EVENT_MESSAGE + '|' + RESPONSE_TWO, Frames[1]);
end;

procedure TMCPSseParserTests.Finish_FrameWithoutATerminatingBlankLine_IsReturned;
begin
  var Parser := TMCPSseParser.Create;
  try
    Parser.Append('event: ' + EVENT_MESSAGE + #10'data: ' + RESPONSE_ONE);

    var Event: TMCPSseEvent;
    Assert.IsFalse(Parser.TryNext(Event), 'an unterminated frame is not complete');

    Parser.Finish;

    Assert.IsTrue(Parser.TryNext(Event), 'the end of the stream terminates the last frame');
    Assert.AreEqual(RESPONSE_ONE, Event.Data);
    Assert.IsFalse(Parser.TryNext(Event));
  finally
    Parser.Free;
  end;
end;

procedure TMCPSseParserTests.Reset_AfterAPartialFrame_DropsTheBuffer;
begin
  var Parser := TMCPSseParser.Create;
  try
    Parser.Append('event: ' + EVENT_MESSAGE + #10'data: half');
    Parser.Reset;
    Parser.Append(Frame(EVENT_MESSAGE, RESPONSE_ONE));

    var Event: TMCPSseEvent;
    Assert.IsTrue(Parser.TryNext(Event));
    Assert.AreEqual(RESPONSE_ONE, Event.Data);
    Assert.IsFalse(Parser.TryNext(Event));
  finally
    Parser.Free;
  end;
end;

procedure TMCPSseParserTests.AppendBytes_MultiByteCharacterSplitAcrossChunks_DecodesItWhole;
begin
  const Payload = '{"price":"' + EURO + '9"}';
  const Cut = 32;
  var Encoded := TEncoding.UTF8.GetBytes(Frame(EVENT_MESSAGE, Payload));

  const Frames = DrainBytes([
    Copy(Encoded, 0, Cut),
    Copy(Encoded, Cut, Integer(Length(Encoded)) - Cut)]);

  Assert.AreEqual(1, Integer(Length(Frames)), 'a chunk boundary inside a UTF-8 sequence must not corrupt it');
  Assert.AreEqual(EVENT_MESSAGE + '|' + Payload, Frames[0]);
end;

{ TMCPChallengeReaderTests }

procedure TMCPChallengeReaderTests.Parameter_ScopeOnABearerChallenge_IsRead;
begin
  Assert.AreEqual('orders.read',
    TMCPChallengeReader.Parameter('Bearer scope="orders.read"', 'scope'));
end;

procedure TMCPChallengeReaderTests.Parameter_ScopeAfterOtherParameters_IsRead;
begin
  const Challenge = 'Bearer resource_metadata="https://host/.well-known/x", ' +
    'error="insufficient_scope", scope="orders.read orders.write"';

  Assert.AreEqual('orders.read orders.write',
    TMCPChallengeReader.Parameter(Challenge, 'scope'));
  Assert.AreEqual('insufficient_scope', TMCPChallengeReader.Parameter(Challenge, 'error'));
end;

procedure TMCPChallengeReaderTests.Parameter_CommaInsideAQuotedValue_DoesNotSplitTheParameter;
begin
  const Challenge = 'Bearer error_description="one, two", scope="orders.read"';

  Assert.AreEqual('one, two', TMCPChallengeReader.Parameter(Challenge, 'error_description'));
  Assert.AreEqual('orders.read', TMCPChallengeReader.Parameter(Challenge, 'scope'));
end;

procedure TMCPChallengeReaderTests.Parameter_EscapedQuoteInsideAValue_IsUnescaped;
begin
  const Challenge = 'Bearer error_description="say \"no\"", scope="a"';

  Assert.AreEqual('say "no"', TMCPChallengeReader.Parameter(Challenge, 'error_description'));
  Assert.AreEqual('a', TMCPChallengeReader.Parameter(Challenge, 'scope'));
end;

procedure TMCPChallengeReaderTests.Parameter_AbsentName_ReturnsEmpty;
begin
  Assert.AreEqual('', TMCPChallengeReader.Parameter('Bearer error="invalid_token"', 'scope'));
  Assert.AreEqual('', TMCPChallengeReader.Parameter('', 'scope'));
end;

end.
