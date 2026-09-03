unit MCPServer.Tests.Logger;

interface

uses
  DUnitX.TestFramework;

type
  /// The stdout guard: while a stdio transport runs, console logging must
  /// never reach stdout, whatever a consumer sets on TLogger.
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

    [Test] procedure StdoutReserved_ForcesUseStdErr;
    [Test] procedure StdoutReserved_RefusesUseStdErrFalse_AndWarnsOnce;
    [Test] procedure StdoutReleased_AllowsUseStdErrFalseAgain;
    [Test] procedure StdioTransport_Create_ReservesStdout;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  MCPServer.Logger,
  MCPServer.StdioTransport,
  MCPServer.Tests.Harness;

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

initialization
  TDUnitX.RegisterTestFixture(TLoggerStdoutGuardTests);

end.
