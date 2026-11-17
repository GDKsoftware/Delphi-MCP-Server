unit MCPServer.Tests.Logger;

interface

uses
  DUnitX.TestFramework,
  System.Classes,
  MCPServer.Logger;

type
  [TestFixture]
  TLoggerStdoutGuardTests = class
  private
    FOriginalUseStdErr: Boolean;
    FOriginalStdoutReserved: Boolean;
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    [Test]
    procedure StdoutReserved_ForcesUseStdErr;

    [Test]
    procedure StdoutReserved_RefusesUseStdErrFalse_AndWarnsOnce;

    [Test]
    procedure StdoutReleased_AllowsUseStdErrFalseAgain;

    [Test]
    procedure StdioTransport_Create_ReservesStdout;
  end;

  [TestFixture]
  TLoggerExternalTextTests = class
  public
    [Test]
    procedure ExternalText_PlainText_IsUnchanged;

    [Test]
    procedure ExternalText_ControlCharacters_BecomeSpaces;

    [Test]
    procedure ExternalText_AtTheLimit_IsNotCut;

    [Test]
    procedure ExternalText_OverTheLimit_IsCutAndSaysSo;

    [Test]
    procedure ExternalText_CutInsideSurrogatePair_DropsTheHalfPair;
  end;

  [TestFixture]
  TLoggerDebugJsonTests = class
  private
    FOriginalMinLogLevel: TLogLevel;
    FLines: TStringList;
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    [Test]
    procedure DebugJson_AtDebugLevel_WritesCaptionAndRedactedJson;

    [Test]
    procedure DebugJson_AtInfoLevel_WritesNothing;
  end;

implementation

uses
  System.SysUtils,
  MCPServer.StdioTransport,
  MCPServer.Tests.Harness;

const
  EXTERNAL_TEXT_LIMIT = 200;
  CUT_FORMAT = '%s... <cut, %d characters>';

{ TLoggerStdoutGuardTests }

procedure TLoggerStdoutGuardTests.Setup;
begin
  FOriginalUseStdErr := TLogger.UseStdErr;
  FOriginalStdoutReserved := TLogger.StdoutReserved;
  TLogger.StdoutReserved := False;
  TLogger.UseStdErr := False;
end;

procedure TLoggerStdoutGuardTests.TearDown;
begin
  TLogger.OnLogMessage := nil;
  TLogger.StdoutReserved := FOriginalStdoutReserved;
  TLogger.UseStdErr := FOriginalUseStdErr;
end;

procedure TLoggerStdoutGuardTests.StdoutReserved_ForcesUseStdErr;
begin
  Assert.IsFalse(TLogger.UseStdErr);

  TLogger.StdoutReserved := True;

  Assert.IsTrue(TLogger.UseStdErr);
end;

procedure TLoggerStdoutGuardTests.StdoutReserved_RefusesUseStdErrFalse_AndWarnsOnce;
begin
  var Warnings := TStringList.Create;
  try
    TLogger.OnLogMessage :=
      procedure(const Message: string)
      begin
        if Message.Contains('[WARN ]') and Message.Contains('stdout is reserved') then
          Warnings.Add(Message);
      end;

    TLogger.StdoutReserved := True;
    TLogger.UseStdErr := False;
    TLogger.UseStdErr := False;

    Assert.IsTrue(TLogger.UseStdErr, 'UseStdErr must stay True while stdout is reserved');
    Assert.AreEqual(1, Warnings.Count, 'the refusal is logged once');
  finally
    TLogger.OnLogMessage := nil;
    Warnings.Free;
  end;
end;

procedure TLoggerStdoutGuardTests.StdoutReleased_AllowsUseStdErrFalseAgain;
begin
  TLogger.StdoutReserved := True;
  TLogger.StdoutReserved := False;

  TLogger.UseStdErr := False;

  Assert.IsFalse(TLogger.UseStdErr);
end;

procedure TLoggerStdoutGuardTests.StdioTransport_Create_ReservesStdout;
begin
  var Harness := TMCPTestHarness.Create;
  try
    var Transport := TMCPStdioTransport.Create(Harness.ManagerRegistry, Harness.CoreManager);
    try
      Assert.IsTrue(TLogger.StdoutReserved);
      Assert.IsTrue(TLogger.UseStdErr);
    finally
      Transport.Free;
    end;
  finally
    Harness.Free;
  end;
end;

{ TLoggerExternalTextTests }

procedure TLoggerExternalTextTests.ExternalText_PlainText_IsUnchanged;
begin
  const Plain = 'tools/call get_time v1.2 ~';

  const Actual = TLogger.ExternalText(Plain);

  Assert.AreEqual(Plain, Actual);
end;

procedure TLoggerExternalTextTests.ExternalText_ControlCharacters_BecomeSpaces;
begin
  const Forged = 'ping'#13#10'[2026-01-01] [ERROR] forged'#9'tab'#0'nul'#27'esc'#127'del';

  const Actual = TLogger.ExternalText(Forged);

  Assert.AreEqual('ping  [2026-01-01] [ERROR] forged tab nul esc del', Actual);
end;

procedure TLoggerExternalTextTests.ExternalText_AtTheLimit_IsNotCut;
begin
  const AtLimit = StringOfChar('x', EXTERNAL_TEXT_LIMIT);

  const Actual = TLogger.ExternalText(AtLimit);

  Assert.AreEqual(AtLimit, Actual);
end;

procedure TLoggerExternalTextTests.ExternalText_OverTheLimit_IsCutAndSaysSo;
begin
  const OriginalLength = EXTERNAL_TEXT_LIMIT + 50;
  const TooLong = StringOfChar('x', OriginalLength);
  const Kept = StringOfChar('x', EXTERNAL_TEXT_LIMIT);
  const Expected = Format(CUT_FORMAT, [Kept, OriginalLength]);

  const Actual = TLogger.ExternalText(TooLong);

  Assert.AreEqual(Expected, Actual);
end;

procedure TLoggerExternalTextTests.ExternalText_CutInsideSurrogatePair_DropsTheHalfPair;
begin
  const KeptLength = EXTERNAL_TEXT_LIMIT - 1;
  const SurrogatePair = #$D83D#$DE00;
  const Kept = StringOfChar('x', KeptLength);
  const Straddling = Kept + SurrogatePair + 'tail';
  const Expected = Format(CUT_FORMAT, [Kept, Length(Straddling)]);

  const Actual = TLogger.ExternalText(Straddling);

  Assert.AreEqual(Expected, Actual);
end;

{ TLoggerDebugJsonTests }

procedure TLoggerDebugJsonTests.Setup;
begin
  FOriginalMinLogLevel := TLogger.MinLogLevel;
  FLines := TStringList.Create;
  const Lines = FLines;
  TLogger.OnLogMessage :=
    procedure(const Message: string)
    begin
      Lines.Add(Message);
    end;
end;

procedure TLoggerDebugJsonTests.TearDown;
begin
  TLogger.OnLogMessage := nil;
  TLogger.MinLogLevel := FOriginalMinLogLevel;
  FLines.Free;
end;

procedure TLoggerDebugJsonTests.DebugJson_AtDebugLevel_WritesCaptionAndRedactedJson;
begin
  TLogger.MinLogLevel := TLogLevel.Debug;

  TLogger.DebugJson('Request', '{"method":"ping","password":"hunter2"}');

  Assert.AreEqual(1, FLines.Count);
  Assert.EndsWith('Request: {"method":"ping","password":"<redacted>"}', FLines[0]);
end;

procedure TLoggerDebugJsonTests.DebugJson_AtInfoLevel_WritesNothing;
begin
  TLogger.MinLogLevel := TLogLevel.Info;

  TLogger.DebugJson('Request', '{"method":"ping"}');

  Assert.AreEqual(0, FLines.Count);
end;

end.
