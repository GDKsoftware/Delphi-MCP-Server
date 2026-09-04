unit MCPServer.Tests.Http;

interface

uses
  DUnitX.TestFramework,
  System.SysUtils,
  System.Classes,
  System.JSON,
  IdHTTP,
  MCPServer.Types,
  MCPServer.Settings,
  MCPServer.Authorization,
  MCPServer.IdHTTPServer,
  MCPServer.Tool.Base,
  MCPServer.Tool.ContentSamples,
  MCPServer.Tests.Harness;

type
  THttpReply = record
    Status: Integer;
    Body: string;
    ContentLength: Int64;
    RawHeaders: string;
    function Header(const Name: string): string;
    function Json: TJSONObject;
  end;

  [RequiresScope('admin')]
  TScopedTool = class(TSimpleTextTool)
  public
    constructor Create; override;
  end;

  [TestFixture]
  THttpTransportTests = class
  private
    FHarness: TMCPTestHarness;
    FSettings: TMCPSettings;
    FServer: TMCPIdHTTPServer;
    procedure StartServer;
    function Url(const Path: string): string;
    function Send(const Method, Path, Body: string; const Headers: array of string): THttpReply;
    function Post(const Body: string; const Headers: array of string): THttpReply;
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    [Test] procedure Notification_Is202WithEmptyBody;
    [Test] procedure Get_IsMethodNotAllowedWithAllow;
    [Test] procedure Delete_IsMethodNotAllowed;
    [Test] procedure Options_Is204;
    [Test] procedure WrongPath_Is404;
    [Test] procedure Origin_NotAllowed_Is403WithJsonRpcBody_EvenWithCorsDisabled;
    [Test] procedure Origin_LoopbackOnAnyPort_IsAllowed;
    [Test] procedure Origin_Null_IsDenied;
    [Test] procedure Origin_AllowListWithPortWildcard;
    [Test] procedure Cors_HeadersOnlyWhenEnabled;
    [Test] procedure Cors_PreflightReflectsRequestedHeaders;
    [Test] procedure Legacy_UnknownMethod_Is200;
    [Test] procedure Modern_UnknownMethod_Is404;
    [Test] procedure Modern_MissingVersionHeader_Is400HeaderMismatch;
    [Test] procedure Modern_UnsupportedVersion_Is400;
    [Test] procedure Modern_MissingClientCapabilities_Is400;
    [Test] procedure ModernHeader_WithoutMeta_Is400InvalidParams;
    [Test] procedure Legacy_UnknownVersionHeader_Is400;
    [Test] procedure Modern_McpMethodHeader_IsRequiredAndMustMatch;
    [Test] procedure Modern_McpNameHeader_Base64IsDecoded;
    [Test] procedure Modern_Discover_Is200;
    [Test] procedure BodyTooLarge_Is413;
    [Test] procedure NestingTooDeep_Is400;
    [Test] procedure SessionId_IsEchoedForLegacyOnly;
    [Test] procedure Sse_HasNoIdLine;
    [Test] procedure Bind_DefaultIsLoopback;
    [Test] procedure Bind_ExplicitAddress;
    [Test] procedure EndpointInfoPath_AnswersJson;
    [Test] procedure Progress_IsStreamedBeforeTheResponse;
    [Test] procedure Progress_WithoutEventStreamAccept_IsPlainJson;
    [Test] procedure Log_OnlyWithLogLevel_InMeta;
    [Test] procedure InputRequired_StreamsAsFinalEvent;
    [Test] procedure StreamedError_IsFinalEvent;
    [Test] procedure Listen_StreamsAckAndChanges_UntilStopped;
    [Test] procedure Listen_WithoutEventStreamAccept_IsInvalidRequest;
    [Test] procedure Auth_MissingToken_Is401WithChallenge;
    [Test] procedure Auth_WrongToken_Is401_InvalidToken;
    [Test] procedure Auth_MalformedHeader_Is400;
    [Test] procedure Auth_ValidToken_IsServed;
    [Test] procedure Auth_PreflightAndMetadata_NeedNoToken;
    [Test] procedure Auth_ScopedTool_Is403_WithInsufficientScope;
    [Test] procedure Auth_ScopedTool_OnOpenServer_Is403;
  end;

implementation

uses
  System.Threading;

const
  MODERN_VERSION_HEADER = 'MCP-Protocol-Version: 2026-07-28';
  MODERN_META = '"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}';
  LEGACY_PING = '{"jsonrpc":"2.0","id":1,"method":"ping"}';

{ THttpReply }

function THttpReply.Header(const Name: string): string;
begin
  var Headers := TStringList.Create;
  try
    Headers.NameValueSeparator := ':';
    Headers.Text := RawHeaders;
    Result := Trim(Headers.Values[Name]);
  finally
    Headers.Free;
  end;
end;

function THttpReply.Json: TJSONObject;
begin
  Result := TJSONObject.ParseJSONValue(Body) as TJSONObject;
  Assert.IsNotNull(Result, 'body is not a JSON object: ' + Body);
end;

{ TScopedTool }

constructor TScopedTool.Create;
begin
  inherited;
  FName := 'test_scoped';
end;

{ THttpTransportTests }

procedure THttpTransportTests.Setup;
begin
  FHarness := TMCPTestHarness.Create;
  FSettings := FHarness.Settings;
  FSettings.Port := 0;
  FSettings.CorsEnabled := False;
  FServer := TMCPIdHTTPServer.Create(nil);
  FServer.Settings := FSettings;
  FServer.ManagerRegistry := FHarness.ManagerRegistry;
  FServer.CoreManager := FHarness.CoreManager;
end;

procedure THttpTransportTests.TearDown;
begin
  FServer.Free;
  FHarness.Free;
end;

procedure THttpTransportTests.StartServer;
begin
  FServer.Start;
end;

function THttpTransportTests.Url(const Path: string): string;
begin
  Result := Format('http://127.0.0.1:%d%s', [FServer.Port, Path]);
end;

function THttpTransportTests.Send(const Method, Path, Body: string; const Headers: array of string): THttpReply;
begin
  if not FServer.Active then
    StartServer;

  var Http := TIdHTTP.Create(nil);
  var Request := TStringStream.Create(Body, TEncoding.UTF8);
  var Response := TMemoryStream.Create;
  try
    Http.HTTPOptions := Http.HTTPOptions + [hoNoProtocolErrorException, hoWantProtocolErrorContent] - [hoInProcessAuth];
    Http.MaxAuthRetries := 0;
    Http.Request.ContentType := 'application/json';
    Http.Request.Accept := 'application/json';
    for var Header in Headers do
    begin
      var Separator := Header.IndexOf(':');
      var Name := Header.Substring(0, Separator).Trim;
      var Value := Header.Substring(Separator + 1).Trim;
      if SameText(Name, 'Accept') then
        Http.Request.Accept := Value
      else if SameText(Name, 'Content-Type') then
        Http.Request.ContentType := Value
      else
        Http.Request.CustomHeaders.AddValue(Name, Value);
    end;

    if Method = 'POST' then
      Http.Post(Url(Path), Request, Response)
    else if Method = 'GET' then
      Http.Get(Url(Path), Response)
    else if Method = 'DELETE' then
      Http.Delete(Url(Path), Response)
    else if Method = 'PUT' then
      Http.Put(Url(Path), Request, Response)
    else if Method = 'OPTIONS' then
      Http.Options(Url(Path), Response)
    else
      raise Exception.Create('unsupported method ' + Method);

    Result.Status := Http.ResponseCode;
    Result.ContentLength := Http.Response.ContentLength;
    Result.RawHeaders := Http.Response.RawHeaders.Text;
    var Bytes: TBytes;
    SetLength(Bytes, Integer(Response.Size));
    if Response.Size > 0 then
      Move(Response.Memory^, Bytes[0], Integer(Response.Size));
    Result.Body := TEncoding.UTF8.GetString(Bytes);
  finally
    Response.Free;
    Request.Free;
    Http.Free;
  end;
end;

function THttpTransportTests.Post(const Body: string; const Headers: array of string): THttpReply;
begin
  Result := Send('POST', '/mcp', Body, Headers);
end;

procedure THttpTransportTests.Notification_Is202WithEmptyBody;
begin
  var Reply := Post('{"jsonrpc":"2.0","method":"notifications/initialized"}', []);
  Assert.AreEqual(202, Reply.Status);
  Assert.AreEqual('', Reply.Body);
  Assert.AreEqual(Int64(0), Reply.ContentLength);
end;

procedure THttpTransportTests.Get_IsMethodNotAllowedWithAllow;
begin
  var Reply := Send('GET', '/mcp', '', ['Accept: text/event-stream']);
  Assert.AreEqual(405, Reply.Status);
  Assert.AreEqual('POST, OPTIONS', Reply.Header('Allow'));
  Assert.AreEqual('', Reply.Body);
end;

procedure THttpTransportTests.Delete_IsMethodNotAllowed;
begin
  Assert.AreEqual(405, Send('DELETE', '/mcp', '', []).Status);
  Assert.AreEqual(405, Send('PUT', '/mcp', '{}', []).Status);
end;

procedure THttpTransportTests.Options_Is204;
begin
  var Reply := Send('OPTIONS', '/mcp', '', ['Origin: http://localhost']);
  Assert.AreEqual(204, Reply.Status);
  Assert.AreEqual('', Reply.Body);
end;

procedure THttpTransportTests.WrongPath_Is404;
begin
  Assert.AreEqual(404, Send('POST', '/other', LEGACY_PING, []).Status);
  Assert.AreEqual(404, Send('GET', '/mcp/extra', '', []).Status);
end;

procedure THttpTransportTests.Origin_NotAllowed_Is403WithJsonRpcBody_EvenWithCorsDisabled;
begin
  var Reply := Post(LEGACY_PING, ['Origin: http://evil.example']);
  Assert.AreEqual(403, Reply.Status);
  Assert.AreEqual('Origin', Reply.Header('Vary'));
  var Json := Reply.Json;
  try
    Assert.AreEqual(JSONRPC_INVALID_REQUEST, Json.GetValue<Integer>('error.code'));
    Assert.IsNull(Json.GetValue('id'));
  finally
    Json.Free;
  end;
end;

procedure THttpTransportTests.Origin_LoopbackOnAnyPort_IsAllowed;
begin
  Assert.AreEqual(200, Post(LEGACY_PING, ['Origin: http://127.0.0.1:3000']).Status);
  Assert.AreEqual(200, Post(LEGACY_PING, ['Origin: http://localhost:5173']).Status);
  Assert.AreEqual(200, Post(LEGACY_PING, ['Origin: https://localhost']).Status);
end;

procedure THttpTransportTests.Origin_Null_IsDenied;
begin
  Assert.AreEqual(403, Post(LEGACY_PING, ['Origin: null']).Status);
end;

procedure THttpTransportTests.Origin_AllowListWithPortWildcard;
begin
  FSettings.SecurityAllowedOrigins := 'https://app.example:*';
  Assert.AreEqual(200, Post(LEGACY_PING, ['Origin: https://app.example:8443']).Status);
  Assert.AreEqual(403, Post(LEGACY_PING, ['Origin: https://other.example']).Status);
end;

procedure THttpTransportTests.Cors_HeadersOnlyWhenEnabled;
begin
  var Disabled := Post(LEGACY_PING, ['Origin: http://localhost']);
  Assert.AreEqual('', Disabled.Header('Access-Control-Allow-Origin'));

  FServer.Stop;
  FSettings.CorsEnabled := True;
  var Enabled := Post(LEGACY_PING, ['Origin: http://localhost']);
  Assert.AreEqual(200, Enabled.Status);
  Assert.AreEqual('http://localhost', Enabled.Header('Access-Control-Allow-Origin'));
  Assert.AreEqual('POST, OPTIONS', Enabled.Header('Access-Control-Allow-Methods'));
  Assert.IsTrue(Enabled.Header('Access-Control-Allow-Headers').Contains('Mcp-Method'));
  Assert.IsTrue(Enabled.Header('Access-Control-Expose-Headers').Contains('WWW-Authenticate'));
end;

procedure THttpTransportTests.Cors_PreflightReflectsRequestedHeaders;
begin
  FSettings.CorsEnabled := True;
  var Reply := Send('OPTIONS', '/mcp', '', ['Origin: http://localhost',
    'Access-Control-Request-Method: POST', 'Access-Control-Request-Headers: Mcp-Param-Region, X-Trace']);
  Assert.AreEqual(204, Reply.Status);
  var AllowHeaders := Reply.Header('Access-Control-Allow-Headers');
  Assert.IsTrue(AllowHeaders.Contains('Mcp-Param-Region'), AllowHeaders);
  Assert.IsTrue(AllowHeaders.Contains('X-Trace'), AllowHeaders);
end;

procedure THttpTransportTests.Legacy_UnknownMethod_Is200;
begin
  var Reply := Post('{"jsonrpc":"2.0","id":1,"method":"totally/bogus/method"}', ['MCP-Protocol-Version: 2025-06-18']);
  Assert.AreEqual(200, Reply.Status);
  Assert.IsTrue(Reply.Body.Contains('-32601'));
end;

procedure THttpTransportTests.Modern_UnknownMethod_Is404;
begin
  var Reply := Post('{"jsonrpc":"2.0","id":1,"method":"totally/bogus/method","params":{' + MODERN_META + '}}',
    [MODERN_VERSION_HEADER, 'Mcp-Method: totally/bogus/method']);
  Assert.AreEqual(404, Reply.Status);
  var Json := Reply.Json;
  try
    Assert.AreEqual(JSONRPC_METHOD_NOT_FOUND, Json.GetValue<Integer>('error.code'));
    Assert.AreEqual(1, Json.GetValue<Integer>('id'));
  finally
    Json.Free;
  end;
end;

procedure THttpTransportTests.Modern_MissingVersionHeader_Is400HeaderMismatch;
begin
  var Reply := Post('{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{' + MODERN_META + '}}', ['Mcp-Method: tools/list']);
  Assert.AreEqual(400, Reply.Status);
  Assert.IsTrue(Reply.Body.Contains('-32020'), Reply.Body);
end;

procedure THttpTransportTests.Modern_UnsupportedVersion_Is400;
begin
  var Reply := Post('{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"1900-01-01","io.modelcontextprotocol/clientCapabilities":{}}}}',
    ['MCP-Protocol-Version: 1900-01-01', 'Mcp-Method: tools/list']);
  Assert.AreEqual(400, Reply.Status);
  var Json := Reply.Json;
  try
    Assert.AreEqual(MCP_ERROR_UNSUPPORTED_PROTOCOL_VERSION, Json.GetValue<Integer>('error.code'));
    Assert.AreEqual('2026-07-28', Json.GetValue<string>('error.data.supported[0]'));
  finally
    Json.Free;
  end;
end;

procedure THttpTransportTests.Modern_MissingClientCapabilities_Is400;
begin
  var Reply := Post('{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}',
    [MODERN_VERSION_HEADER, 'Mcp-Method: tools/list']);
  Assert.AreEqual(400, Reply.Status);
  Assert.IsTrue(Reply.Body.Contains('-32602'), Reply.Body);
end;

procedure THttpTransportTests.ModernHeader_WithoutMeta_Is400InvalidParams;
begin
  var Reply := Post('{"jsonrpc":"2.0","id":1,"method":"tools/list"}', [MODERN_VERSION_HEADER, 'Mcp-Method: tools/list']);
  Assert.AreEqual(400, Reply.Status);
  Assert.IsTrue(Reply.Body.Contains('-32602'), Reply.Body);
end;

procedure THttpTransportTests.Legacy_UnknownVersionHeader_Is400;
begin
  var Reply := Post(LEGACY_PING, ['MCP-Protocol-Version: 1900-01-01']);
  Assert.AreEqual(400, Reply.Status);
  Assert.IsTrue(Reply.Body.Contains('-32600'), Reply.Body);
end;

procedure THttpTransportTests.Modern_McpMethodHeader_IsRequiredAndMustMatch;
begin
  var Body := '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{' + MODERN_META + '}}';

  var Missing := Post(Body, [MODERN_VERSION_HEADER]);
  Assert.AreEqual(400, Missing.Status);
  Assert.IsTrue(Missing.Body.Contains('-32020'), Missing.Body);

  var Mismatch := Post(Body, [MODERN_VERSION_HEADER, 'Mcp-Method: TOOLS/LIST']);
  Assert.AreEqual(400, Mismatch.Status);
  Assert.IsTrue(Mismatch.Body.Contains('-32020'), Mismatch.Body);

  var Matching := Post(Body, [MODERN_VERSION_HEADER, 'mcp-method: tools/list']);
  Assert.AreEqual(200, Matching.Status);
end;

procedure THttpTransportTests.Modern_McpNameHeader_Base64IsDecoded;
begin
  var Body := '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":{"message":"hi"},' + MODERN_META + '}}';

  var Encoded := Post(Body, [MODERN_VERSION_HEADER, 'Mcp-Method: tools/call', 'Mcp-Name: =?base64?ZWNobw==?=']);
  Assert.AreEqual(200, Encoded.Status);
  Assert.IsTrue(Encoded.Body.Contains('Echo: hi'), Encoded.Body);

  var Wrong := Post(Body, [MODERN_VERSION_HEADER, 'Mcp-Method: tools/call', 'Mcp-Name: calculate']);
  Assert.AreEqual(400, Wrong.Status);
  Assert.IsTrue(Wrong.Body.Contains('-32020'), Wrong.Body);

  var Missing := Post(Body, [MODERN_VERSION_HEADER, 'Mcp-Method: tools/call']);
  Assert.AreEqual(400, Missing.Status);
end;

procedure THttpTransportTests.Modern_Discover_Is200;
begin
  var Reply := Post('{"jsonrpc":"2.0","id":"d","method":"server/discover","params":{' + MODERN_META + '}}',
    [MODERN_VERSION_HEADER, 'Mcp-Method: server/discover']);
  Assert.AreEqual(200, Reply.Status);
  var Json := Reply.Json;
  try
    Assert.AreEqual('complete', Json.GetValue<string>('result.resultType'));
    Assert.AreEqual('2026-07-28', Json.GetValue<string>('result.supportedVersions[0]'));
  finally
    Json.Free;
  end;
end;

procedure THttpTransportTests.BodyTooLarge_Is413;
begin
  FSettings.MaxRequestBodyBytes := 64;
  var Reply := Post('{"jsonrpc":"2.0","id":1,"method":"ping","params":{"padding":"' + StringOfChar('x', 100) + '"}}', []);
  Assert.AreEqual(413, Reply.Status);
  Assert.IsTrue(Reply.Body.Contains('-32600'), Reply.Body);
end;

procedure THttpTransportTests.NestingTooDeep_Is400;
begin
  FSettings.MaxJsonDepth := 3;
  var Reply := Post('{"jsonrpc":"2.0","id":1,"method":"ping","params":{"a":{"b":{"c":{}}}}}', []);
  Assert.AreEqual(400, Reply.Status);
  Assert.IsTrue(Reply.Body.Contains('-32700'), Reply.Body);
end;

procedure THttpTransportTests.SessionId_IsEchoedForLegacyOnly;
begin
  var Legacy := Post(LEGACY_PING, ['Mcp-Session-Id: session-42']);
  Assert.AreEqual('session-42', Legacy.Header('Mcp-Session-Id'));

  var Modern := Post('{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{' + MODERN_META + '}}',
    [MODERN_VERSION_HEADER, 'Mcp-Method: tools/list', 'Mcp-Session-Id: session-42']);
  Assert.AreEqual(200, Modern.Status);
  Assert.AreEqual('', Modern.Header('Mcp-Session-Id'));

  var Initialize := Post('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}', []);
  Assert.AreEqual('', Initialize.Header('Mcp-Session-Id'), 'sessions are never minted');
end;

procedure THttpTransportTests.Sse_HasNoIdLine;
begin
  var Reply := Post(LEGACY_PING, ['Accept: application/json, text/event-stream']);
  Assert.AreEqual(200, Reply.Status);
  Assert.IsTrue(Reply.Header('Content-Type').StartsWith('text/event-stream'), Reply.Header('Content-Type'));
  Assert.IsTrue(Reply.Body.StartsWith('event: message'#10'data: '), Reply.Body);
  Assert.IsFalse(Reply.Body.Contains(#10'id:'), Reply.Body);
end;

procedure THttpTransportTests.Bind_DefaultIsLoopback;
begin
  StartServer;
  var Addresses := FServer.BoundAddresses;
  Assert.IsTrue(Length(Addresses) >= 1);
  for var Address in Addresses do
    Assert.IsTrue(Address.StartsWith('127.0.0.1:') or Address.StartsWith('[::1]:')
      or Address.StartsWith('[0:0:0:0:0:0:0:1]:'), Address);
end;

procedure THttpTransportTests.Bind_ExplicitAddress;
begin
  FSettings.BindAddress := '127.0.0.1';
  StartServer;
  var Addresses := FServer.BoundAddresses;
  Assert.AreEqual(1, Integer(Length(Addresses)));
  Assert.IsTrue(Addresses[0].StartsWith('127.0.0.1:'), Addresses[0]);
  Assert.AreEqual(200, Post(LEGACY_PING, []).Status);
end;

procedure THttpTransportTests.EndpointInfoPath_AnswersJson;
begin
  FSettings.EndpointInfoPath := '/info';
  var Reply := Send('GET', '/info', '', []);
  Assert.AreEqual(200, Reply.Status);
  var Json := Reply.Json;
  try
    Assert.IsTrue(Json.GetValue<string>('url').EndsWith('/mcp'));
    Assert.AreEqual('2026-07-28', Json.GetValue<string>('protocolVersions[0]'));
  finally
    Json.Free;
  end;
  Assert.AreEqual(404, Send('GET', '/nothing', '', []).Status);
end;

procedure THttpTransportTests.Progress_IsStreamedBeforeTheResponse;
begin
  var Reply := Post('{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"test_tool_with_progress",'
    + '"arguments":{"steps":3,"stepMs":10},"_meta":{"progressToken":"p1"}}}',
    ['Accept: application/json, text/event-stream', 'MCP-Protocol-Version: 2025-11-25']);
  Assert.AreEqual(200, Reply.Status);
  Assert.IsTrue(Reply.Header('Content-Type').StartsWith('text/event-stream'), Reply.Header('Content-Type'));
  Assert.AreEqual('no', Reply.Header('X-Accel-Buffering'));

  var Events := Reply.Body.Split([#10#10], TStringSplitOptions.ExcludeEmpty);
  Assert.IsTrue(Length(Events) >= 3, Reply.Body);
  for var I := 0 to High(Events) - 1 do
  begin
    Assert.IsTrue(Events[I].Contains('"method":"notifications/progress"'), Events[I]);
    Assert.IsTrue(Events[I].Contains('"progressToken":"p1"'), Events[I]);
  end;
  Assert.IsTrue(Events[High(Events)].Contains('"id":9'), Events[High(Events)]);
  Assert.IsTrue(Events[High(Events)].Contains('Completed 3 steps'), Events[High(Events)]);
end;

procedure THttpTransportTests.Progress_WithoutEventStreamAccept_IsPlainJson;
begin
  var Reply := Post('{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"test_tool_with_progress",'
    + '"arguments":{"steps":2,"stepMs":10},"_meta":{"progressToken":"p1"}}}', []);
  Assert.AreEqual(200, Reply.Status);
  Assert.IsTrue(Reply.Header('Content-Type').StartsWith('application/json'), Reply.Header('Content-Type'));
  Assert.IsFalse(Reply.Body.Contains('notifications/progress'), Reply.Body);
  var Json := Reply.Json;
  try
    Assert.AreEqual('Completed 2 steps', Json.GetValue<string>('result.content[0].text'));
  finally
    Json.Free;
  end;
end;

procedure THttpTransportTests.Log_OnlyWithLogLevel_InMeta;
const
  CALL = '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"test_logging_tool","arguments":{},'
    + '"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}%s}}}';
begin
  var Silent := Post(Format(CALL, ['']),
    ['Accept: application/json, text/event-stream', MODERN_VERSION_HEADER, 'Mcp-Method: tools/call', 'Mcp-Name: test_logging_tool']);
  Assert.AreEqual(200, Silent.Status);
  Assert.IsFalse(Silent.Body.Contains('notifications/message'), Silent.Body);
  Assert.IsTrue(Silent.Body.Contains('"resultType":"complete"'), Silent.Body);

  var Verbose := Post(Format(CALL, [',"io.modelcontextprotocol/logLevel":"error"']),
    ['Accept: application/json, text/event-stream', MODERN_VERSION_HEADER, 'Mcp-Method: tools/call', 'Mcp-Name: test_logging_tool']);
  Assert.AreEqual(200, Verbose.Status);
  var Events := Verbose.Body.Split([#10#10], TStringSplitOptions.ExcludeEmpty);
  Assert.AreEqual(5, Integer(Length(Events)), Verbose.Body);
  Assert.IsTrue(Events[0].Contains('"level":"error"'), Events[0]);
  Assert.IsFalse(Verbose.Body.Contains('"level":"warning"'), Verbose.Body);
  Assert.IsTrue(Events[4].Contains('"id":3'), Events[4]);
end;

procedure THttpTransportTests.InputRequired_StreamsAsFinalEvent;
begin
  var Reply := Post('{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"test_streaming_elicitation","arguments":{},'
    + '"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{"elicitation":{}},'
    + '"io.modelcontextprotocol/logLevel":"info"}}}',
    ['Accept: application/json, text/event-stream', MODERN_VERSION_HEADER, 'Mcp-Method: tools/call', 'Mcp-Name: test_streaming_elicitation']);
  Assert.AreEqual(200, Reply.Status);
  var Events := Reply.Body.Split([#10#10], TStringSplitOptions.ExcludeEmpty);
  Assert.AreEqual(2, Integer(Length(Events)), Reply.Body);
  Assert.IsTrue(Events[0].Contains('notifications/message'), Events[0]);
  Assert.IsTrue(Events[1].Contains('"resultType":"input_required"'), Events[1]);
  Assert.IsTrue(Events[1].Contains('"confirm"'), Events[1]);
end;

procedure THttpTransportTests.StreamedError_IsFinalEvent;
begin
  var Reply := Post('{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"test_streaming_elicitation","arguments":{},'
    + '"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{},'
    + '"io.modelcontextprotocol/logLevel":"info"}}}',
    ['Accept: application/json, text/event-stream', MODERN_VERSION_HEADER, 'Mcp-Method: tools/call', 'Mcp-Name: test_streaming_elicitation']);
  Assert.AreEqual(200, Reply.Status, 'the stream was already open when the -32021 error arose');
  var Events := Reply.Body.Split([#10#10], TStringSplitOptions.ExcludeEmpty);
  Assert.AreEqual(2, Integer(Length(Events)), Reply.Body);
  Assert.IsTrue(Events[1].Contains('"code":-32021'), Events[1]);
end;

procedure THttpTransportTests.Listen_StreamsAckAndChanges_UntilStopped;
const
  LISTEN = '{"jsonrpc":"2.0","id":"sub-1","method":"subscriptions/listen","params":{"notifications":{"toolsListChanged":true,"resourceSubscriptions":["test://static-text"]},' + MODERN_META + '}}';
  TRIGGER = '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"%s","arguments":{},' + MODERN_META + '}}';
begin
  StartServer;
  var Listener := TTask.Future<THttpReply>(
    function: THttpReply
    begin
      Result := Post(LISTEN, ['Accept: application/json, text/event-stream', MODERN_VERSION_HEADER, 'Mcp-Method: subscriptions/listen']);
    end);

  var Deadline := TThread.GetTickCount64 + 2000;
  while (FHarness.SubscriptionsManager.ActiveCount = 0) and (TThread.GetTickCount64 < Deadline) do
    Sleep(10);
  Assert.AreEqual(1, FHarness.SubscriptionsManager.ActiveCount, 'the subscription is open');

  Post(Format(TRIGGER, ['test_trigger_tool_change']), [MODERN_VERSION_HEADER, 'Mcp-Method: tools/call', 'Mcp-Name: test_trigger_tool_change']);
  Post(Format(TRIGGER, ['test_trigger_prompt_change']), [MODERN_VERSION_HEADER, 'Mcp-Method: tools/call', 'Mcp-Name: test_trigger_prompt_change']);
  Post(Format(TRIGGER, ['test_trigger_resource_change']), [MODERN_VERSION_HEADER, 'Mcp-Method: tools/call', 'Mcp-Name: test_trigger_resource_change']);
  FServer.Stop;

  var Reply := Listener.Value;
  Assert.AreEqual(200, Reply.Status);
  var Events := Reply.Body.Split([#10#10], TStringSplitOptions.ExcludeEmpty);
  Assert.AreEqual(4, Integer(Length(Events)), Reply.Body);
  Assert.IsTrue(Events[0].Contains('"method":"notifications/subscriptions/acknowledged"'), Events[0]);
  Assert.IsTrue(Events[0].Contains('"toolsListChanged":true'), Events[0]);
  Assert.IsTrue(Events[0].Contains('"resourceSubscriptions":["test://static-text"]'), Events[0]);
  Assert.IsTrue(Events[0].Contains('"io.modelcontextprotocol/subscriptionId":"sub-1"'), Events[0]);
  Assert.IsTrue(Events[1].Contains('"method":"notifications/tools/list_changed"'), Events[1]);
  Assert.IsTrue(Events[2].Contains('"method":"notifications/resources/updated"'), Events[2]);
  Assert.IsTrue(Events[2].Contains('"uri":"test://static-text"'), Events[2]);
  Assert.IsFalse(Reply.Body.Contains('prompts/list_changed'), 'not requested');
  Assert.IsTrue(Events[3].Contains('"id":"sub-1"'), Events[3]);
  Assert.IsTrue(Events[3].Contains('"resultType":"complete"'), Events[3]);
  Assert.IsTrue(Events[3].Contains('"io.modelcontextprotocol/subscriptionId":"sub-1"'), Events[3]);
end;

procedure THttpTransportTests.Listen_WithoutEventStreamAccept_IsInvalidRequest;
begin
  var Reply := Post('{"jsonrpc":"2.0","id":1,"method":"subscriptions/listen","params":{"notifications":{"toolsListChanged":true},' + MODERN_META + '}}',
    [MODERN_VERSION_HEADER, 'Mcp-Method: subscriptions/listen']);
  Assert.AreEqual(400, Reply.Status);
  Assert.IsTrue(Reply.Body.Contains('-32600'), Reply.Body);
end;

procedure THttpTransportTests.Auth_MissingToken_Is401WithChallenge;
begin
  FSettings.AuthorizationServers := 'https://auth.example';
  FServer.Authorizer := TMCPStaticBearerAuthorizer.Create(['s3cret']);
  var Reply := Post(LEGACY_PING, []);
  Assert.AreEqual(401, Reply.Status);
  Assert.AreEqual(Format('Bearer resource_metadata="http://localhost:%d/.well-known/oauth-protected-resource/mcp"', [FServer.Port]),
    Reply.Header('WWW-Authenticate'));
  Assert.IsTrue(Reply.Body.Contains('-32600'), Reply.Body);
  Assert.IsFalse(Reply.Body.Contains('"id"'), 'the challenge body carries no id');
end;

procedure THttpTransportTests.Auth_WrongToken_Is401_InvalidToken;
begin
  FServer.Authorizer := TMCPStaticBearerAuthorizer.Create(['s3cret']);
  var Reply := Post(LEGACY_PING, ['Authorization: Bearer nope']);
  Assert.AreEqual(401, Reply.Status);
  Assert.AreEqual('Bearer error="invalid_token", error_description="The bearer token is not recognised"',
    Reply.Header('WWW-Authenticate'));
end;

procedure THttpTransportTests.Auth_MalformedHeader_Is400;
begin
  FServer.Authorizer := TMCPStaticBearerAuthorizer.Create(['s3cret']);
  var Reply := Post(LEGACY_PING, ['Authorization: Basic abc']);
  Assert.AreEqual(400, Reply.Status);
  Assert.IsTrue(Reply.Header('WWW-Authenticate').Contains('error="invalid_request"'), Reply.Header('WWW-Authenticate'));
  var Empty := Post(LEGACY_PING, ['Authorization: Bearer']);
  Assert.AreEqual(400, Empty.Status);
end;

procedure THttpTransportTests.Auth_ValidToken_IsServed;
begin
  FServer.Authorizer := TMCPStaticBearerAuthorizer.Create(['s3cret']);
  var Reply := Post(LEGACY_PING, ['Authorization: bearer s3cret']);
  Assert.AreEqual(200, Reply.Status);
  Assert.AreEqual('', Reply.Header('WWW-Authenticate'));
  var Modern := Post('{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{' + MODERN_META + '}}',
    [MODERN_VERSION_HEADER, 'Mcp-Method: tools/list', 'Authorization: Bearer s3cret']);
  Assert.AreEqual(200, Modern.Status);
end;

procedure THttpTransportTests.Auth_PreflightAndMetadata_NeedNoToken;
begin
  FSettings.CorsEnabled := True;
  FSettings.AuthorizationServers := 'https://auth.example, https://auth2.example';
  FSettings.ScopesSupported := 'read,offline_access';
  FServer.Authorizer := TMCPStaticBearerAuthorizer.Create(['s3cret']);
  Assert.AreEqual(204, Send('OPTIONS', '/mcp', '', ['Origin: http://localhost:5173']).Status);

  for var Path in ['/.well-known/oauth-protected-resource', '/.well-known/oauth-protected-resource/mcp'] do
  begin
    var Reply := Send('GET', Path, '', []);
    Assert.AreEqual(200, Reply.Status, Path);
    Assert.AreEqual('max-age=3600', Reply.Header('Cache-Control'));
    var Json := Reply.Json;
    try
      Assert.AreEqual(Format('http://localhost:%d/mcp', [FServer.Port]), Json.GetValue<string>('resource'));
      Assert.AreEqual('https://auth2.example', Json.GetValue<string>('authorization_servers[1]'));
      Assert.AreEqual(1, (Json.GetValue('scopes_supported') as TJSONArray).Count, 'offline_access is dropped');
      Assert.AreEqual('header', Json.GetValue<string>('bearer_methods_supported[0]'));
    finally
      Json.Free;
    end;
  end;

  Assert.AreEqual(404, Send('GET', '/.well-known/other', '', []).Status);
  Assert.AreEqual(401, Send('GET', '/mcp', '', []).Status, 'GET on the endpoint is authenticated before 405');
end;

procedure THttpTransportTests.Auth_ScopedTool_Is403_WithInsufficientScope;
const
  CALL = '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"test_scoped","arguments":{}}}';
begin
  FHarness.ToolsManager.AddTool(TScopedTool.Create);
  FServer.Authorizer := TMCPStaticBearerAuthorizer.Create(['reader'], ['read']);
  var Denied := Post(CALL, ['Authorization: Bearer reader']);
  Assert.AreEqual(403, Denied.Status);
  Assert.AreEqual('Bearer error="insufficient_scope", scope="admin"', Denied.Header('WWW-Authenticate'));
  var Json := Denied.Json;
  try
    Assert.AreEqual(4, Json.GetValue<Integer>('id'));
    Assert.AreEqual(-32600, Json.GetValue<Integer>('error.code'));
    Assert.AreEqual('admin', Json.GetValue<string>('error.data.requiredScope'));
  finally
    Json.Free;
  end;

  FServer.Authorizer := TMCPStaticBearerAuthorizer.Create(['admin-token'], ['read', 'admin']);
  var Allowed := Post(CALL, ['Authorization: Bearer admin-token']);
  Assert.AreEqual(200, Allowed.Status);
  Assert.IsTrue(Allowed.Body.Contains('This is a simple text response'), Allowed.Body);
end;

procedure THttpTransportTests.Auth_ScopedTool_OnOpenServer_Is403;
begin
  FHarness.ToolsManager.AddTool(TScopedTool.Create);
  var Reply := Post('{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"test_scoped","arguments":{}}}', []);
  Assert.AreEqual(403, Reply.Status, 'nobody holds a scope on an open server');
end;

end.
