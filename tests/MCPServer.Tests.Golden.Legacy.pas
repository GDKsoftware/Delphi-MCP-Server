unit MCPServer.Tests.Golden.Legacy;

interface

uses
  DUnitX.TestFramework,
  MCPServer.Tests.Harness,
  MCPServer.Tests.Golden;

type
  /// Pins the legacy (initialize-based) wire behaviour of the JSON-RPC layer.
  ///
  /// Every test replays one file from tests\golden\legacy through a fresh
  /// harness and compares the normalised response with the recorded one.
  /// The only differences allowed after the recording are the items in the
  /// allow-list of docs\mcp-2026-07-28-implementation-plan.md, section 4.3.
  [TestFixture]
  TLegacyGoldenTests = class
  private
    FHarness: TMCPTestHarness;
    procedure CheckGolden(const CaseName: string);
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    // Lifecycle
    [Test] procedure Initialize_2025_06_18;
    [Test] procedure Initialize_2025_11_25;
    [Test] procedure Initialize_2025_03_26;
    [Test] procedure Initialize_UnknownVersion;
    [Test] procedure Initialize_WithoutParams;
    [Test] procedure Notifications_Initialized;
    [Test] procedure Ping;

    // Tools
    [Test] procedure Tools_List;
    [Test] procedure Tools_Call_Echo;
    [Test] procedure Tools_Call_Echo_Unicode;
    [Test] procedure Tools_Call_Calculate;
    [Test] procedure Tools_Call_Calculate_DivideByZero;
    [Test] procedure Tools_Call_GetTime;
    [Test] procedure Tools_Call_ListFiles;
    [Test] procedure Tools_Call_ListFiles_OutsideAllowedDirectory;
    [Test] procedure Tools_Call_MissingArguments;
    [Test] procedure Tools_Call_UnknownTool;
    [Test] procedure Tools_Call_InvalidArgumentType;
    [Test] procedure Tools_Call_WithoutParams;
    [Test] procedure Tools_Call_EmptyName;

    // Resources
    [Test] procedure Resources_List;
    [Test] procedure Resources_Read_ProjectInfo;
    [Test] procedure Resources_Read_ProjectReadme;
    [Test] procedure Resources_Read_LogsRecent;
    [Test] procedure Resources_Read_ServerStatus;
    [Test] procedure Resources_Read_UnknownUri;
    [Test] procedure Resources_Read_WithoutParams;
    [Test] procedure Resources_Templates_List;

    // Method and message shape
    [Test] procedure UnknownMethod;
    [Test] procedure ServerDiscover_WithoutMeta;
    [Test] procedure ParseError;
    [Test] procedure EmptyBody;
    [Test] procedure RequestNotAnObject;
    [Test] procedure Id_Null;
    [Test] procedure Id_String;
    [Test] procedure MissingJsonRpcField;
    [Test] procedure MissingMethod;
    [Test] procedure ParamsNotAnObject;
  end;

implementation

uses
  System.SysUtils;

{ TLegacyGoldenTests }

procedure TLegacyGoldenTests.Setup;
begin
  FHarness := TMCPTestHarness.Create;
end;

procedure TLegacyGoldenTests.TearDown;
begin
  FreeAndNil(FHarness);
end;

procedure TLegacyGoldenTests.CheckGolden(const CaseName: string);
begin
  var GoldenCase := TGoldenCase.Create(TGoldenFiles.CaseFile(TGoldenFiles.LEGACY_SUITE, CaseName));
  try
    var Response: string;
    var SavedDirectory := GetCurrentDir;
    if GoldenCase.WorkingDirectory <> '' then
      SetCurrentDir(GoldenCase.WorkingDirectory);
    try
      Response := FHarness.Process(GoldenCase.RequestBody);
    finally
      SetCurrentDir(SavedDirectory);
    end;

    if TGoldenFiles.RecordMode then
    begin
      GoldenCase.RecordExpected(Response);
      Exit;
    end;

    Assert.AreEqual(GoldenCase.ExpectedText, GoldenCase.NormalizeResponse(Response),
      'Golden mismatch for ' + CaseName);
  finally
    GoldenCase.Free;
  end;
end;

procedure TLegacyGoldenTests.Initialize_2025_06_18;
begin
  CheckGolden('initialize-2025-06-18');
end;

procedure TLegacyGoldenTests.Initialize_2025_11_25;
begin
  CheckGolden('initialize-2025-11-25');
end;

procedure TLegacyGoldenTests.Initialize_2025_03_26;
begin
  CheckGolden('initialize-2025-03-26');
end;

procedure TLegacyGoldenTests.Initialize_UnknownVersion;
begin
  CheckGolden('initialize-unknown-version');
end;

procedure TLegacyGoldenTests.Initialize_WithoutParams;
begin
  CheckGolden('initialize-without-params');
end;

procedure TLegacyGoldenTests.Notifications_Initialized;
begin
  CheckGolden('notifications-initialized');
end;

procedure TLegacyGoldenTests.Ping;
begin
  CheckGolden('ping');
end;

procedure TLegacyGoldenTests.Tools_List;
begin
  CheckGolden('tools-list');
end;

procedure TLegacyGoldenTests.Tools_Call_Echo;
begin
  CheckGolden('tools-call-echo');
end;

procedure TLegacyGoldenTests.Tools_Call_Echo_Unicode;
begin
  CheckGolden('tools-call-echo-unicode');
end;

procedure TLegacyGoldenTests.Tools_Call_Calculate;
begin
  CheckGolden('tools-call-calculate');
end;

procedure TLegacyGoldenTests.Tools_Call_Calculate_DivideByZero;
begin
  CheckGolden('tools-call-calculate-divide-by-zero');
end;

procedure TLegacyGoldenTests.Tools_Call_GetTime;
begin
  CheckGolden('tools-call-get-time');
end;

procedure TLegacyGoldenTests.Tools_Call_ListFiles;
begin
  CheckGolden('tools-call-list-files');
end;

procedure TLegacyGoldenTests.Tools_Call_ListFiles_OutsideAllowedDirectory;
begin
  CheckGolden('tools-call-list-files-outside-allowed-directory');
end;

procedure TLegacyGoldenTests.Tools_Call_MissingArguments;
begin
  CheckGolden('tools-call-missing-arguments');
end;

procedure TLegacyGoldenTests.Tools_Call_UnknownTool;
begin
  CheckGolden('tools-call-unknown-tool');
end;

procedure TLegacyGoldenTests.Tools_Call_InvalidArgumentType;
begin
  CheckGolden('tools-call-invalid-argument-type');
end;

procedure TLegacyGoldenTests.Tools_Call_WithoutParams;
begin
  CheckGolden('tools-call-without-params');
end;

procedure TLegacyGoldenTests.Tools_Call_EmptyName;
begin
  CheckGolden('tools-call-empty-name');
end;

procedure TLegacyGoldenTests.Resources_List;
begin
  CheckGolden('resources-list');
end;

procedure TLegacyGoldenTests.Resources_Read_ProjectInfo;
begin
  CheckGolden('resources-read-project-info');
end;

procedure TLegacyGoldenTests.Resources_Read_ProjectReadme;
begin
  CheckGolden('resources-read-project-readme');
end;

procedure TLegacyGoldenTests.Resources_Read_LogsRecent;
begin
  CheckGolden('resources-read-logs-recent');
end;

procedure TLegacyGoldenTests.Resources_Read_ServerStatus;
begin
  CheckGolden('resources-read-server-status');
end;

procedure TLegacyGoldenTests.Resources_Read_UnknownUri;
begin
  CheckGolden('resources-read-unknown-uri');
end;

procedure TLegacyGoldenTests.Resources_Read_WithoutParams;
begin
  CheckGolden('resources-read-without-params');
end;

procedure TLegacyGoldenTests.Resources_Templates_List;
begin
  CheckGolden('resources-templates-list');
end;

procedure TLegacyGoldenTests.UnknownMethod;
begin
  CheckGolden('unknown-method');
end;

procedure TLegacyGoldenTests.ServerDiscover_WithoutMeta;
begin
  CheckGolden('server-discover-without-meta');
end;

procedure TLegacyGoldenTests.ParseError;
begin
  CheckGolden('parse-error');
end;

procedure TLegacyGoldenTests.EmptyBody;
begin
  CheckGolden('empty-body');
end;

procedure TLegacyGoldenTests.RequestNotAnObject;
begin
  CheckGolden('request-not-an-object');
end;

procedure TLegacyGoldenTests.Id_Null;
begin
  CheckGolden('id-null');
end;

procedure TLegacyGoldenTests.Id_String;
begin
  CheckGolden('id-string');
end;

procedure TLegacyGoldenTests.MissingJsonRpcField;
begin
  CheckGolden('missing-jsonrpc-field');
end;

procedure TLegacyGoldenTests.MissingMethod;
begin
  CheckGolden('missing-method');
end;

procedure TLegacyGoldenTests.ParamsNotAnObject;
begin
  CheckGolden('params-not-an-object');
end;

initialization
  TDUnitX.RegisterTestFixture(TLegacyGoldenTests);

end.
