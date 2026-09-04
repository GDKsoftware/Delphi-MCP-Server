unit MCPServer.Tests.StdioChannel;

interface

uses
  DUnitX.TestFramework,
  System.SysUtils,
  System.Classes,
  MCPServer.Types,
  MCPServer.StdioChannel;

type
  [TestFixture]
  TStdioChannelTests = class
  private
    function ReadAll(const Bytes: TBytes; MaxLineBytes: Integer; out Statuses: TArray<TMCPLineStatus>): TArray<string>;
  public
    [Test] procedure Reader_SplitsOnLf_DropsCr_LastLineWithoutNewline;
    [Test] procedure Reader_SkipsByteOrderMark;
    [Test] procedure Reader_DecodesUtf8;
    [Test] procedure Reader_ReportsOverlongLine_AndContinues;
    [Test] procedure Reader_ReportsInvalidUtf8_AndContinues;
    [Test] procedure Reader_OverlongLineWithoutNewline_EndsStream;
    [Test] procedure Reader_OverlongLineBeyondChunk_IsSkippedUpToNewline;
    [Test] procedure Reader_EmptyStream_HasNoLines;
    [Test] procedure Writer_OneLinePerMessage_Utf8_NoBom;
    [Test] procedure Writer_ReplacesEmbeddedNewlines;
    [Test] procedure Writer_ConcurrentSends_DoNotInterleave;
  end;

implementation

uses
  System.SyncObjs,
  System.Generics.Collections;

{ TStdioChannelTests }

function TStdioChannelTests.ReadAll(const Bytes: TBytes; MaxLineBytes: Integer;
  out Statuses: TArray<TMCPLineStatus>): TArray<string>;
var
  Line: string;
  Status: TMCPLineStatus;
begin
  Result := nil;
  Statuses := nil;
  var Stream := TBytesStream.Create(Bytes);
  var Reader := TMCPLineReader.Create(Stream, MaxLineBytes);
  try
    while Reader.ReadLine(Line, Status) do
    begin
      Result := Result + [Line];
      Statuses := Statuses + [Status];
    end;
  finally
    Reader.Free;
    Stream.Free;
  end;
end;

procedure TStdioChannelTests.Reader_SplitsOnLf_DropsCr_LastLineWithoutNewline;
var
  Statuses: TArray<TMCPLineStatus>;
begin
  var Lines := ReadAll(TEncoding.UTF8.GetBytes('one'#13#10'two'#10#10'three'), 1024, Statuses);
  Assert.AreEqual(4, Integer(Length(Lines)));
  Assert.AreEqual('one', Lines[0]);
  Assert.AreEqual('two', Lines[1]);
  Assert.AreEqual('', Lines[2]);
  Assert.AreEqual('three', Lines[3]);
  for var Status in Statuses do
    Assert.IsTrue(Status = TMCPLineStatus.Ok);
end;

procedure TStdioChannelTests.Reader_SkipsByteOrderMark;
var
  Statuses: TArray<TMCPLineStatus>;
begin
  var Bytes := TBytes.Create($EF, $BB, $BF) + TEncoding.UTF8.GetBytes('{"a":1}'#10);
  var Lines := ReadAll(Bytes, 1024, Statuses);
  Assert.AreEqual(1, Integer(Length(Lines)));
  Assert.AreEqual('{"a":1}', Lines[0]);
end;

procedure TStdioChannelTests.Reader_DecodesUtf8;
var
  Statuses: TArray<TMCPLineStatus>;
begin
  var Probe := 'h' + Char($00E9) + 'llo w' + Char($00F6) + 'rld ' + Char($D83D) + Char($DE00);
  var Lines := ReadAll(TEncoding.UTF8.GetBytes(Probe + #10), 1024, Statuses);
  Assert.AreEqual(Probe, Lines[0]);
end;

procedure TStdioChannelTests.Reader_ReportsOverlongLine_AndContinues;
var
  Statuses: TArray<TMCPLineStatus>;
begin
  var Long := StringOfChar('x', 100);
  var Lines := ReadAll(TEncoding.UTF8.GetBytes(Long + #10'short'#10), 50, Statuses);
  Assert.AreEqual(2, Integer(Length(Lines)));
  Assert.IsTrue(Statuses[0] = TMCPLineStatus.TooLong);
  Assert.AreEqual('', Lines[0]);
  Assert.IsTrue(Statuses[1] = TMCPLineStatus.Ok);
  Assert.AreEqual('short', Lines[1]);
end;

procedure TStdioChannelTests.Reader_OverlongLineWithoutNewline_EndsStream;
var
  Statuses: TArray<TMCPLineStatus>;
begin
  var Lines := ReadAll(TEncoding.UTF8.GetBytes(StringOfChar('x', 100)), 50, Statuses);
  Assert.AreEqual(1, Integer(Length(Lines)));
  Assert.IsTrue(Statuses[0] = TMCPLineStatus.TooLong);
  Assert.AreEqual('', Lines[0]);
end;

procedure TStdioChannelTests.Reader_OverlongLineBeyondChunk_IsSkippedUpToNewline;
const
  BEYOND_ONE_CHUNK = 70 * 1024;
  LIMIT = 1024;
var
  Statuses: TArray<TMCPLineStatus>;
begin
  var Long := StringOfChar('y', BEYOND_ONE_CHUNK);
  var Lines := ReadAll(TEncoding.UTF8.GetBytes(Long + #10'after'#10'last'), LIMIT, Statuses);
  Assert.AreEqual(3, Integer(Length(Lines)));
  Assert.IsTrue(Statuses[0] = TMCPLineStatus.TooLong);
  Assert.IsTrue(Statuses[1] = TMCPLineStatus.Ok);
  Assert.AreEqual('after', Lines[1]);
  Assert.IsTrue(Statuses[2] = TMCPLineStatus.Ok);
  Assert.AreEqual('last', Lines[2]);
end;

procedure TStdioChannelTests.Reader_ReportsInvalidUtf8_AndContinues;
var
  Statuses: TArray<TMCPLineStatus>;
begin
  var Bytes := TBytes.Create($FF, $FE, $41) + TEncoding.UTF8.GetBytes(#10'ok'#10);
  var Lines := ReadAll(Bytes, 1024, Statuses);
  Assert.AreEqual(2, Integer(Length(Lines)));
  Assert.IsTrue(Statuses[0] = TMCPLineStatus.InvalidUtf8, 'first line is not UTF-8');
  Assert.AreEqual('ok', Lines[1]);
end;

procedure TStdioChannelTests.Reader_EmptyStream_HasNoLines;
var
  Statuses: TArray<TMCPLineStatus>;
begin
  var Lines := ReadAll(nil, 1024, Statuses);
  Assert.AreEqual(0, Integer(Length(Lines)));
end;

procedure TStdioChannelTests.Writer_OneLinePerMessage_Utf8_NoBom;
begin
  var Stream := TMemoryStream.Create;
  try
    var SinkIntf: IMCPMessageSink := TMCPLineWriter.Create(Stream);
    SinkIntf.Send('{"a":"' + Char($00E9) + '"}');
    SinkIntf.Send('{"b":2}');

    var Bytes: TBytes;
    SetLength(Bytes, Stream.Size);
    Move(Stream.Memory^, Bytes[0], Length(Bytes));
    Assert.AreEqual($7B, Integer(Bytes[0]), 'no byte-order mark');
    var Text := TEncoding.UTF8.GetString(Bytes);
    Assert.AreEqual('{"a":"' + Char($00E9) + '"}'#10'{"b":2}'#10, Text);
    Assert.IsFalse(Text.Contains(#13));
  finally
    Stream.Free;
  end;
end;

procedure TStdioChannelTests.Writer_ReplacesEmbeddedNewlines;
begin
  var Stream := TMemoryStream.Create;
  try
    var SinkIntf: IMCPMessageSink := TMCPLineWriter.Create(Stream);
    SinkIntf.Send('a'#13#10'b');
    var Bytes: TBytes;
    SetLength(Bytes, Stream.Size);
    Move(Stream.Memory^, Bytes[0], Length(Bytes));
    Assert.AreEqual('a  b'#10, TEncoding.UTF8.GetString(Bytes));
  finally
    Stream.Free;
  end;
end;

procedure TStdioChannelTests.Writer_ConcurrentSends_DoNotInterleave;
const
  THREADS = 4;
  MESSAGES_PER_THREAD = 200;
begin
  var Stream := TMemoryStream.Create;
  var Done := TCountdownEvent.Create(THREADS);
  try
    var SinkIntf: IMCPMessageSink := TMCPLineWriter.Create(Stream);
    for var T := 1 to THREADS do
    begin
      var ThreadNo := T;
      TThread.CreateAnonymousThread(
        procedure
        begin
          try
            for var I := 1 to MESSAGES_PER_THREAD do
              SinkIntf.Send('{"thread":' + ThreadNo.ToString + ',"payload":"' + StringOfChar('x', 300) + '"}');
          finally
            Done.Signal;
          end;
        end).Start;
    end;
    Assert.IsTrue(Done.WaitFor(10000) = TWaitResult.wrSignaled);

    var Bytes: TBytes;
    SetLength(Bytes, Stream.Size);
    Move(Stream.Memory^, Bytes[0], Length(Bytes));
    var Lines := TEncoding.UTF8.GetString(Bytes).Split([#10]);
    var Count := 0;
    for var Line in Lines do
    begin
      if Line = '' then
        Continue;
      Inc(Count);
      Assert.IsTrue(Line.StartsWith('{"thread":') and Line.EndsWith('"}'), 'intact line: ' + Line);
      Assert.AreEqual(Length('{"thread":1,"payload":"' + StringOfChar('x', 300) + '"}'), Length(Line));
    end;
    Assert.AreEqual(THREADS * MESSAGES_PER_THREAD, Count);
  finally
    Done.Free;
    Stream.Free;
  end;
end;

end.
