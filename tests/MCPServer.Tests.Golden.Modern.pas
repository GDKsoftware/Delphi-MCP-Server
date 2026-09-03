unit MCPServer.Tests.Golden.Modern;

interface

uses
  DUnitX.TestFramework,
  MCPServer.Tests.Harness,
  MCPServer.Tests.Golden;

type
  /// Pins the wire behaviour for requests that carry per-request _meta
  /// (MCP 2026-07-28), replayed through the plain JSON-RPC layer.
  [TestFixture]
  TModernGoldenTests = class
  private
    FHarness: TMCPTestHarness;
    procedure CheckGolden(const CaseName: string);
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    [Test] procedure Server_Discover;
    [Test] procedure Server_Discover_AfterInitialize;
    [Test] procedure Server_Discover_WithoutMeta;
    [Test] procedure Tools_List;
    [Test] procedure Tools_Call_Echo;
    [Test] procedure Tools_Call_UnknownTool;
    [Test] procedure Resources_List;
    [Test] procedure Resources_Read_ProjectInfo;
    [Test] procedure Resources_Templates_List;
    [Test] procedure Ping_IsNotFound;
    [Test] procedure UnknownMethod;
    [Test] procedure UnknownProtocolVersion;
    [Test] procedure MissingClientCapabilities;
    [Test] procedure InvalidLogLevel;
    [Test] procedure Initialize_WithModernMeta_IsNotFound;
    [Test] procedure Id_Null;
    [Test] procedure MissingJsonRpcField;
  end;

implementation

uses
  System.SysUtils;

const
  INITIALIZE_REQUEST = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18",'
    + '"capabilities":{},"clientInfo":{"name":"golden-client","version":"1.0.0"}}}';

{ TModernGoldenTests }

procedure TModernGoldenTests.Setup;
begin
  FHarness := TMCPTestHarness.Create;
end;

procedure TModernGoldenTests.TearDown;
begin
  FreeAndNil(FHarness);
end;

procedure TModernGoldenTests.CheckGolden(const CaseName: string);
begin
  TGoldenRunner.Check(TGoldenFiles.MODERN_SUITE, CaseName,
    function(const RequestBody: string): string
    begin
      Result := FHarness.Process(RequestBody);
    end);
end;

procedure TModernGoldenTests.Server_Discover;
begin
  CheckGolden('server-discover');
end;

procedure TModernGoldenTests.Server_Discover_AfterInitialize;
begin
  // A legacy handshake on the same process must not latch the server.
  FHarness.Process(INITIALIZE_REQUEST);
  CheckGolden('server-discover');
end;

procedure TModernGoldenTests.Server_Discover_WithoutMeta;
begin
  CheckGolden('server-discover-without-meta');
end;

procedure TModernGoldenTests.Tools_List;
begin
  CheckGolden('tools-list');
end;

procedure TModernGoldenTests.Tools_Call_Echo;
begin
  CheckGolden('tools-call-echo');
end;

procedure TModernGoldenTests.Tools_Call_UnknownTool;
begin
  CheckGolden('tools-call-unknown-tool');
end;

procedure TModernGoldenTests.Resources_List;
begin
  CheckGolden('resources-list');
end;

procedure TModernGoldenTests.Resources_Read_ProjectInfo;
begin
  CheckGolden('resources-read-project-info');
end;

procedure TModernGoldenTests.Resources_Templates_List;
begin
  CheckGolden('resources-templates-list');
end;

procedure TModernGoldenTests.Ping_IsNotFound;
begin
  CheckGolden('ping');
end;

procedure TModernGoldenTests.UnknownMethod;
begin
  CheckGolden('unknown-method');
end;

procedure TModernGoldenTests.UnknownProtocolVersion;
begin
  CheckGolden('unknown-protocol-version');
end;

procedure TModernGoldenTests.MissingClientCapabilities;
begin
  CheckGolden('missing-client-capabilities');
end;

procedure TModernGoldenTests.InvalidLogLevel;
begin
  CheckGolden('invalid-log-level');
end;

procedure TModernGoldenTests.Initialize_WithModernMeta_IsNotFound;
begin
  CheckGolden('initialize-with-modern-meta');
end;

procedure TModernGoldenTests.Id_Null;
begin
  CheckGolden('id-null');
end;

procedure TModernGoldenTests.MissingJsonRpcField;
begin
  CheckGolden('missing-jsonrpc-field');
end;

initialization
  TDUnitX.RegisterTestFixture(TModernGoldenTests);

end.
