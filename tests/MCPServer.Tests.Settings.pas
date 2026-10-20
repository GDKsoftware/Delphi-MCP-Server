unit MCPServer.Tests.Settings;

interface

uses
  DUnitX.TestFramework,
  System.Rtti,
  MCPServer.Settings;

type
  [TestFixture]
  TMCPSettingsTest = class
  private
    FDirectory: string;
    FContext: TRttiContext;
    function TempSettingsPath: string;
    function SettingsFields: TArray<TRttiField>;
    procedure GiveEveryFieldItsOwnValue(const Settings: TMCPSettings);
    function DistinctValue(const Field: TRttiField; const Settings: TMCPSettings; const Number: Integer): TValue;
    function NextOrdinal(const Field: TRttiField; const Settings: TMCPSettings): TValue;
    function ValueOf(const Field: TRttiField; const Settings: TMCPSettings): TValue;
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    [Test]
    procedure Create_WithoutFile_LoadsExpectedDefaults;

    [Test]
    procedure Create_WithoutFile_LoadsExpectedLimitDefaults;

    [Test]
    procedure Create_EmptyPathAndNoCreate_CreatesNoFile;

    [Test]
    procedure Create_MissingPathAndNoCreate_CreatesNoFile;

    [Test]
    procedure Create_MissingPathAndCreate_WritesDefaultsToFile;

    [Test]
    procedure Protocol_SslDisabled_ReturnsHttp;

    [Test]
    procedure Protocol_SslEnabled_ReturnsHttps;

    [Test]
    procedure SetProperties_ReadBack_ReturnsAssignedValues;

    [Test]
    procedure LoadFromFile_ExistingFile_OverridesDefaults;

    [Test]
    procedure SaveToFile_ReloadedByNewInstance_RoundTripsValues;

    [Test]
    procedure AllowedOrigins_SecurityOriginsEmpty_FallsBackToCorsOrigins;

    [Test]
    procedure AllowedOrigins_SecurityOriginsSet_WinsOverCorsOrigins;

    [Test]
    procedure AllowedHostList_MixedSpacingAndBlanks_ReturnsTrimmedEntries;

    [Test]
    procedure BearerTokenList_EmptyValue_ReturnsEmptyArray;

    [Test]
    procedure ScopesSupportedList_TwoScopes_ReturnsBothScopes;

    [Test]
    procedure Clone_EveryField_IsCopiedByValue;

    [Test]
    procedure Clone_CopiesEverySetting;

    [Test]
    procedure Clone_ChangedCopy_LeavesTheOriginalAlone;
  end;

implementation

uses
  System.SysUtils,
  System.TypInfo,
  System.IniFiles,
  System.IOUtils;

const
  VALUE_COPIED_KINDS    = [tkInteger, tkInt64, tkEnumeration, tkUString];
  FIRST_DISTINCT_NUMBER = 100000;
  CHANGED_SERVER_NAME   = 'changed copy';

{ TMCPSettingsTest }

procedure TMCPSettingsTest.Setup;
begin
  FDirectory := TPath.Combine(TPath.GetTempPath, 'mcp-settings-' + TGuid.NewGuid.ToString);
  TDirectory.CreateDirectory(FDirectory);
  FContext := TRttiContext.Create;
end;

procedure TMCPSettingsTest.TearDown;
begin
  FContext.Free;
  if TDirectory.Exists(FDirectory) then
    TDirectory.Delete(FDirectory, True);
end;

function TMCPSettingsTest.TempSettingsPath: string;
begin
  Result := TPath.Combine(FDirectory, 'settings.ini');
end;

function TMCPSettingsTest.SettingsFields: TArray<TRttiField>;
begin
  const SettingsType = FContext.GetType(TMCPSettings);
  Result := SettingsType.GetFields;
end;

procedure TMCPSettingsTest.GiveEveryFieldItsOwnValue(const Settings: TMCPSettings);
begin
  var Number := FIRST_DISTINCT_NUMBER;
  for var Field in SettingsFields do
  begin
    const Value = DistinctValue(Field, Settings, Number);
    {$WARN UNSAFE_CAST OFF}
    Field.SetValue(Settings, Value);
    {$WARN UNSAFE_CAST ON}
    Inc(Number);
  end;
end;

function TMCPSettingsTest.DistinctValue(const Field: TRttiField; const Settings: TMCPSettings; const Number: Integer): TValue;
begin
  const FieldType = Field.FieldType;
  case FieldType.TypeKind of
    tkInteger, tkInt64 : Result := TValue.FromOrdinal(FieldType.Handle, Number);
    tkEnumeration      : Result := NextOrdinal(Field, Settings);
    tkUString          : Result := Format('value %d', [Number]);
  else
    raise ENotSupportedException.CreateFmt('No distinct value for a %s', [FieldType.Name]);
  end;
end;

function TMCPSettingsTest.NextOrdinal(const Field: TRttiField; const Settings: TMCPSettings): TValue;
begin
  const EnumType = Field.FieldType as TRttiEnumerationType;
  const Current = ValueOf(Field, Settings);
  const Ordinal = Current.AsOrdinal;
  const IsLast = (Ordinal = EnumType.MaxValue);

  var Next := Ordinal + 1;
  if IsLast then
    Next := EnumType.MinValue;

  Result := TValue.FromOrdinal(EnumType.Handle, Next);
end;

function TMCPSettingsTest.ValueOf(const Field: TRttiField; const Settings: TMCPSettings): TValue;
begin
  {$WARN UNSAFE_CAST OFF}
  Result := Field.GetValue(Settings);
  {$WARN UNSAFE_CAST ON}
end;

procedure TMCPSettingsTest.Create_WithoutFile_LoadsExpectedDefaults;
begin
  const Settings = TMCPSettings.Create(TempSettingsPath, False);
  try
    Assert.AreEqual<Integer>(3000, Settings.Port);
    Assert.AreEqual('localhost', Settings.Host);
    Assert.AreEqual('delphi-mcp-server', Settings.ServerName);
    Assert.AreEqual('1.0.0', Settings.ServerVersion);
    Assert.AreEqual('/mcp', Settings.Endpoint);
    Assert.IsTrue(Settings.CorsEnabled);
    Assert.IsFalse(Settings.SSLEnabled);
    Assert.IsTrue(Settings.ExposeDiagnosticsResources);
  finally
    Settings.Free;
  end;
end;

procedure TMCPSettingsTest.Create_WithoutFile_LoadsExpectedLimitDefaults;
begin
  const Settings = TMCPSettings.Create(TempSettingsPath, False);
  try
    Assert.AreEqual<Integer>(TMCPSettings.DEFAULT_MAX_REQUEST_BODY_BYTES, Settings.MaxRequestBodyBytes);
    Assert.AreEqual<Integer>(TMCPSettings.DEFAULT_MAX_JSON_DEPTH, Settings.MaxJsonDepth);
    Assert.AreEqual<Integer>(TMCPSettings.DEFAULT_MAX_CONCURRENT_REQUESTS, Settings.MaxConcurrentRequests);
    Assert.AreEqual<Integer>(TMCPSettings.DEFAULT_REQUEST_STATE_TTL_SECONDS, Settings.RequestStateTtlSeconds);
    Assert.AreEqual<Integer>(0, Settings.MaxConnections);
    Assert.AreEqual<Integer>(TMCPSettings.DEFAULT_STDIO_SHUTDOWN_DRAIN_MS, Settings.StdioShutdownDrainMs);
  finally
    Settings.Free;
  end;
end;

procedure TMCPSettingsTest.Create_EmptyPathAndNoCreate_CreatesNoFile;
begin
  const ExpectedFile = TPath.Combine(ExtractFilePath(ParamStr(0)), 'settings.ini');
  const ExistedBefore = TFile.Exists(ExpectedFile);

  const Settings = TMCPSettings.Create('', False);
  try
    Assert.AreEqual(ExpectedFile, Settings.SettingsFile);
    Assert.AreEqual(ExistedBefore, TFile.Exists(ExpectedFile),
      'Create with an empty path and ACreateFile False must never write a settings file');
  finally
    Settings.Free;
  end;
end;

procedure TMCPSettingsTest.Create_MissingPathAndNoCreate_CreatesNoFile;
begin
  const SettingsFile = TempSettingsPath;

  const Settings = TMCPSettings.Create(SettingsFile, False);
  try
    Assert.AreEqual(SettingsFile, Settings.SettingsFile);
    Assert.IsFalse(TFile.Exists(SettingsFile));
  finally
    Settings.Free;
  end;
end;

procedure TMCPSettingsTest.Create_MissingPathAndCreate_WritesDefaultsToFile;
begin
  const SettingsFile = TempSettingsPath;

  const Settings = TMCPSettings.Create(SettingsFile, True);
  try
    Assert.IsTrue(TFile.Exists(SettingsFile));
  finally
    Settings.Free;
  end;

  const IniFile = TIniFile.Create(SettingsFile);
  try
    Assert.AreEqual<Integer>(3000, IniFile.ReadInteger('Server', 'Port', 0));
    Assert.AreEqual('localhost', IniFile.ReadString('Server', 'Host', ''));
    Assert.IsFalse(IniFile.ReadBool('SSL', 'Enabled', True));
  finally
    IniFile.Free;
  end;
end;

procedure TMCPSettingsTest.Protocol_SslDisabled_ReturnsHttp;
begin
  const Settings = TMCPSettings.Create(TempSettingsPath, False);
  try
    Assert.IsFalse(Settings.SSLEnabled);

    Assert.AreEqual('http', Settings.Protocol);
  finally
    Settings.Free;
  end;
end;

procedure TMCPSettingsTest.Protocol_SslEnabled_ReturnsHttps;
begin
  const Settings = TMCPSettings.Create(TempSettingsPath, False);
  try
    Settings.SSLEnabled := True;

    Assert.AreEqual('https', Settings.Protocol);
  finally
    Settings.Free;
  end;
end;

procedure TMCPSettingsTest.SetProperties_ReadBack_ReturnsAssignedValues;
begin
  const Settings = TMCPSettings.Create(TempSettingsPath, False);
  try
    Settings.Port := 8080;
    Settings.Host := '127.0.0.1';
    Settings.ServerName := 'custom-server';
    Settings.Endpoint := '/agent';

    Assert.AreEqual<Integer>(8080, Settings.Port);
    Assert.AreEqual('127.0.0.1', Settings.Host);
    Assert.AreEqual('custom-server', Settings.ServerName);
    Assert.AreEqual('/agent', Settings.Endpoint);
  finally
    Settings.Free;
  end;
end;

procedure TMCPSettingsTest.LoadFromFile_ExistingFile_OverridesDefaults;
begin
  const SettingsFile = TempSettingsPath;

  const IniFile = TIniFile.Create(SettingsFile);
  try
    IniFile.WriteInteger('Server', 'Port', 9123);
    IniFile.WriteString('Server', 'Name', 'from-file');
    IniFile.WriteBool('SSL', 'Enabled', True);
    IniFile.WriteString('Security', 'AllowedHosts', 'localhost:9123');
  finally
    IniFile.Free;
  end;

  const Settings = TMCPSettings.Create(SettingsFile, False);
  try
    Assert.AreEqual<Integer>(9123, Settings.Port);
    Assert.AreEqual('from-file', Settings.ServerName);
    Assert.AreEqual('https', Settings.Protocol);
    Assert.AreEqual('localhost:9123', Settings.AllowedHosts);
    Assert.AreEqual('localhost', Settings.Host, 'A key absent from the file keeps its default');
  finally
    Settings.Free;
  end;
end;

procedure TMCPSettingsTest.SaveToFile_ReloadedByNewInstance_RoundTripsValues;
begin
  const SettingsFile = TempSettingsPath;

  const Written = TMCPSettings.Create(SettingsFile, False);
  try
    Written.Port := 8123;
    Written.ServerName := 'round-trip';
    Written.BearerTokens := 'alpha,beta';
    Written.MaxJsonDepth := 12;
    Written.StdioShutdownDrainMs := 15000;
    Written.SaveToFile;
  finally
    Written.Free;
  end;

  const Reloaded = TMCPSettings.Create(SettingsFile, False);
  try
    Assert.AreEqual<Integer>(8123, Reloaded.Port);
    Assert.AreEqual('round-trip', Reloaded.ServerName);
    Assert.AreEqual('alpha,beta', Reloaded.BearerTokens);
    Assert.AreEqual<Integer>(12, Reloaded.MaxJsonDepth);
    Assert.AreEqual<Integer>(15000, Reloaded.StdioShutdownDrainMs);
    Assert.AreEqual<NativeInt>(2, Length(Reloaded.BearerTokenList));
  finally
    Reloaded.Free;
  end;
end;

procedure TMCPSettingsTest.AllowedOrigins_SecurityOriginsEmpty_FallsBackToCorsOrigins;
begin
  const Settings = TMCPSettings.Create(TempSettingsPath, False);
  try
    Settings.CorsAllowedOrigins := 'http://localhost';
    Settings.SecurityAllowedOrigins := '';

    Assert.AreEqual('http://localhost', Settings.AllowedOrigins);
  finally
    Settings.Free;
  end;
end;

procedure TMCPSettingsTest.AllowedOrigins_SecurityOriginsSet_WinsOverCorsOrigins;
begin
  const Settings = TMCPSettings.Create(TempSettingsPath, False);
  try
    Settings.CorsAllowedOrigins := 'http://localhost';
    Settings.SecurityAllowedOrigins := 'https://example.test';

    Assert.AreEqual('https://example.test', Settings.AllowedOrigins);
  finally
    Settings.Free;
  end;
end;

procedure TMCPSettingsTest.AllowedHostList_MixedSpacingAndBlanks_ReturnsTrimmedEntries;
begin
  const Settings = TMCPSettings.Create(TempSettingsPath, False);
  try
    Settings.AllowedHosts := ' localhost:3000 , ,127.0.0.1:3000';

    const Hosts = Settings.AllowedHostList;

    Assert.AreEqual<NativeInt>(2, Length(Hosts));
    Assert.AreEqual('localhost:3000', Hosts[0]);
    Assert.AreEqual('127.0.0.1:3000', Hosts[1]);
  finally
    Settings.Free;
  end;
end;

procedure TMCPSettingsTest.BearerTokenList_EmptyValue_ReturnsEmptyArray;
begin
  const Settings = TMCPSettings.Create(TempSettingsPath, False);
  try
    Assert.AreEqual('', Settings.BearerTokens);

    Assert.AreEqual<NativeInt>(0, Length(Settings.BearerTokenList));
  finally
    Settings.Free;
  end;
end;

procedure TMCPSettingsTest.ScopesSupportedList_TwoScopes_ReturnsBothScopes;
begin
  const Settings = TMCPSettings.Create(TempSettingsPath, False);
  try
    Settings.ScopesSupported := 'mcp:read, mcp:write';

    const Scopes = Settings.ScopesSupportedList;

    Assert.AreEqual<NativeInt>(2, Length(Scopes));
    Assert.AreEqual('mcp:read', Scopes[0]);
    Assert.AreEqual('mcp:write', Scopes[1]);
  finally
    Settings.Free;
  end;
end;

procedure TMCPSettingsTest.Clone_EveryField_IsCopiedByValue;
begin
  const Fields = SettingsFields;

  for var Field in Fields do
  begin
    const FieldType = Field.FieldType;
    const IsCopiedByValue = (FieldType.TypeKind in VALUE_COPIED_KINDS);
    const Reason = Format('TMCPSettings.%s is a %s: Clone copies objects, interfaces and arrays by reference, ' +
                          'and this test knows integers, enumerations and strings only', [Field.Name, FieldType.Name]);
    Assert.IsTrue(IsCopiedByValue, Reason);
  end;
end;

procedure TMCPSettingsTest.Clone_CopiesEverySetting;
begin
  const Original = TMCPSettings.Create(TempSettingsPath, False);
  try
    GiveEveryFieldItsOwnValue(Original);

    const Cloned = Original.Clone;
    try
      for var Field in SettingsFields do
      begin
        const Expected = ValueOf(Field, Original);
        const Actual = ValueOf(Field, Cloned);
        const ExpectedText = Expected.ToString;
        const ActualText = Actual.ToString;
        Assert.AreEqual(ExpectedText, ActualText, Field.Name);
      end;
    finally
      Cloned.Free;
    end;
  finally
    Original.Free;
  end;
end;

procedure TMCPSettingsTest.Clone_ChangedCopy_LeavesTheOriginalAlone;
begin
  const Original = TMCPSettings.Create(TempSettingsPath, False);
  try
    const Cloned = Original.Clone;
    try
      Cloned.ServerName := CHANGED_SERVER_NAME;

      Assert.AreNotEqual(CHANGED_SERVER_NAME, Original.ServerName);
    finally
      Cloned.Free;
    end;
  finally
    Original.Free;
  end;
end;

end.
