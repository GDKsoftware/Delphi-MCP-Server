unit MCPServer.Tests.HttpCancellation;

// What cancels a running tool over HTTP, asserted against this server with nothing but an HTTP
// client, because both claims are about the server and not about whatever is calling it.
//
// README.md and MIGRATION.md state two things a reader is entitled to rely on:
//
//   1. Closing the response stream cancels the request. The server's next write to the stream
//      fails, MCPServer.HttpStream cancels the request the tool is running, and the tool's
//      IsCancelled turns True.
//   2. A notifications/cancelled naming a request that is still in flight arrives on a connection
//      of its own, is answered 202 and is dropped, because the tracker a request consults is its
//      own response stream. The running tool never hears about it and answers as it would have.
//
// TCancelWatchTool is what makes both visible. It reports progress on every step, which is what
// turns the response into a chunked event stream and what gives the server a write that can fail,
// and it records whether it saw its request cancelled or ran to the end.

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Rtti,
  DUnitX.TestFramework,
  MCPServer.Types,
  MCPServer.RequestContext,
  MCPServer.Tool.Base,
  MCPServer.Host;

type
  TNoParams = class
  end;

  { Runs until the test releases it or its request is cancelled, and remembers which of the two
    happened. }
  TCancelWatchTool = class(TMCPToolBase<TNoParams>)
  strict private
    FStarted: TEvent;
    FRelease: TEvent;
    FCancelSeen: TEvent;
    FRequestId: string;
  protected
    function ExecuteWithContext(const Params: TNoParams;
      const Context: IMCPRequestContext): TValue; override;
  public
    constructor Create; override;
    destructor Destroy; override;

    function WaitForStart(const TimeoutMs: Cardinal): Boolean;
    function WaitForCancellation(const TimeoutMs: Cardinal): Boolean;
    function SawCancellation: Boolean;
    procedure Release;

    { The id the server gave this request, which is what a notifications/cancelled has to name.
      Written before the start is signalled, so a test that waited for the start may read it. }
    property RequestId: string read FRequestId;
  end;

  [TestFixture]
  TMCPHttpCancellationTests = class
  private
    FHost: TMCPServerHost;
    FWatch: TCancelWatchTool;
    FWatchTool: IMCPTool;
    function Url: string;
    function Post(const Body: string; out StatusCode: Integer): string;
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    [Test]
    procedure ADroppedConnection_CancelsTheRunningTool;

    [Test]
    procedure ACancellationOnASecondConnection_IsAcceptedAndTheToolRunsOn;
  end;

implementation

uses
  IdHTTP,
  IdTCPClient,
  IdGlobal,
  MCPServer.Errors,
  MCPServer.Tool.Result;

const
  LOOPBACK = '127.0.0.1';
  ENDPOINT = '/mcp';
  URL_TEMPLATE = 'http://%s:%d%s';
  ACCEPT_STREAM = 'application/json, text/event-stream';

  TOOL_CANCEL_WATCH = 'test_cancel_watch';

  WATCH_STEPS = 200;
  WATCH_STEP_MS = 25;
  WATCH_WAIT_MS = 5000;
  WATCH_STEP_MESSAGE = 'still working';
  WATCH_ANSWER = 'the watch tool ran to the end';

  { The call both tests make. Nothing negotiates first: over HTTP a legacy request stands on its
    own, which is what lets a raw socket send one. The progress token is not decoration: without
    one ReportProgress sends nothing, the response stays a single JSON object, and there is no
    stream to close. }
  CALL_REQUEST =
    '{"jsonrpc":"2.0","id":1,"method":"tools/call",' +
    '"params":{"name":"' + TOOL_CANCEL_WATCH + '","arguments":{},' +
    '"_meta":{"progressToken":"watch"}}}';

  CANCEL_NOTIFICATION =
    '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":%s,' +
    '"reason":"a second connection"}}';

  { Long enough for the server to have written its first progress frame, so the write that fails
    is a later one and not the first. }
  STREAM_SETTLE_MS = 300;

{ TCancelWatchTool }

constructor TCancelWatchTool.Create;
begin
  inherited;
  FName := TOOL_CANCEL_WATCH;
  FDescription := 'Reports progress until the caller goes away or the test releases it';
  FStarted := TEvent.Create(nil, True, False, '');
  FRelease := TEvent.Create(nil, True, False, '');
  FCancelSeen := TEvent.Create(nil, True, False, '');
end;

destructor TCancelWatchTool.Destroy;
begin
  FCancelSeen.Free;
  FRelease.Free;
  FStarted.Free;
  inherited;
end;

function TCancelWatchTool.ExecuteWithContext(const Params: TNoParams;
  const Context: IMCPRequestContext): TValue;
begin
  FRequestId := Context.RequestId.AsText;
  FStarted.SetEvent;

  for var Step := 1 to WATCH_STEPS do
  begin
    if Context.IsCancelled then
    begin
      FCancelSeen.SetEvent;
      Break;
    end;

    Context.ReportProgress(Step, WATCH_STEPS, WATCH_STEP_MESSAGE);

    if FRelease.WaitFor(WATCH_STEP_MS) = TWaitResult.wrSignaled then
      Break;
  end;

  Result := TMCPToolResult.Text(WATCH_ANSWER);
end;

function TCancelWatchTool.WaitForStart(const TimeoutMs: Cardinal): Boolean;
begin
  Result := (FStarted.WaitFor(TimeoutMs) = TWaitResult.wrSignaled);
end;

function TCancelWatchTool.WaitForCancellation(const TimeoutMs: Cardinal): Boolean;
begin
  Result := (FCancelSeen.WaitFor(TimeoutMs) = TWaitResult.wrSignaled);
end;

function TCancelWatchTool.SawCancellation: Boolean;
begin
  Result := (FCancelSeen.WaitFor(0) = TWaitResult.wrSignaled);
end;

procedure TCancelWatchTool.Release;
begin
  FRelease.SetEvent;
end;

{ TMCPHttpCancellationTests }

procedure TMCPHttpCancellationTests.Setup;
begin
  FWatch := TCancelWatchTool.Create;
  FWatchTool := FWatch;

  FHost := TMCPServerHost.Create;
  FHost.Settings.Port := 0;
  FHost.Settings.CorsEnabled := False;
  FHost.AddTool(FWatchTool);
  FHost.StartHttp;
end;

procedure TMCPHttpCancellationTests.TearDown;
begin
  // A tool still counting its steps would hold the host open for as long as its budget lasts.
  FWatch.Release;
  FreeAndNil(FHost);
  FWatch := nil;
  FWatchTool := nil;
end;

function TMCPHttpCancellationTests.Url: string;
begin
  Result := Format(URL_TEMPLATE, [LOOPBACK, FHost.BoundPort, ENDPOINT]);
end;

function TMCPHttpCancellationTests.Post(const Body: string; out StatusCode: Integer): string;
begin
  const Http = TIdHTTP.Create(nil);
  const Request = TStringStream.Create(Body, TEncoding.UTF8);
  try
    Http.HTTPOptions := Http.HTTPOptions + [hoNoProtocolErrorException];
    Http.Request.ContentType := MEDIA_TYPE_JSON;
    Http.Request.Accept := ACCEPT_STREAM;
    Result := Http.Post(Url, Request);
    StatusCode := Http.ResponseCode;
  finally
    Request.Free;
    Http.Free;
  end;
end;

procedure TMCPHttpCancellationTests.ADroppedConnection_CancelsTheRunningTool;
begin
  const Socket = TIdTCPClient.Create(nil);
  try
    Socket.Host := LOOPBACK;
    Socket.Port := FHost.BoundPort;
    Socket.Connect;

    const Payload = TEncoding.UTF8.GetBytes(CALL_REQUEST);
    Socket.IOHandler.WriteLn('POST ' + ENDPOINT + ' HTTP/1.1');
    Socket.IOHandler.WriteLn(Format('Host: %s:%d', [LOOPBACK, FHost.BoundPort]));
    Socket.IOHandler.WriteLn('Content-Type: ' + MEDIA_TYPE_JSON);
    Socket.IOHandler.WriteLn('Accept: ' + ACCEPT_STREAM);
    Socket.IOHandler.WriteLn(Format('Content-Length: %d', [Length(Payload)]));
    Socket.IOHandler.WriteLn('Connection: close');
    Socket.IOHandler.WriteLn;
    Socket.IOHandler.Write(TIdBytes(Payload));

    Assert.IsTrue(FWatch.WaitForStart(WATCH_WAIT_MS), 'the tool never started');

    // Let the stream get going, so the write that fails is a later one and not the first.
    Socket.IOHandler.CheckForDataOnSource(STREAM_SETTLE_MS);
    Socket.Disconnect;
  finally
    Socket.Free;
  end;

  Assert.IsTrue(FWatch.WaitForCancellation(WATCH_WAIT_MS),
    'the tool never saw its request cancelled, so the closed stream cancelled nothing');
end;

procedure TMCPHttpCancellationTests.ACancellationOnASecondConnection_IsAcceptedAndTheToolRunsOn;
begin
  var Answer := '';
  var Failure := '';
  var CallStatus := 0;

  const Caller = TThread.CreateAnonymousThread(
    procedure
    begin
      try
        Answer := Post(CALL_REQUEST, CallStatus);
      except
        on E: Exception do
          Failure := E.ClassName + ': ' + E.Message;
      end;
    end);
  Caller.FreeOnTerminate := False;
  Caller.Start;
  try
    Assert.IsTrue(FWatch.WaitForStart(WATCH_WAIT_MS), 'the tool never started');

    var NotifiedStatus := 0;
    Post(Format(CANCEL_NOTIFICATION, [FWatch.RequestId]), NotifiedStatus);
    Assert.AreEqual(HTTP_STATUS_ACCEPTED, NotifiedStatus,
      'the server answered the cancellation with something other than 202');

    // The tool has now outlived the notification, which is the whole point; it may stop.
    FWatch.Release;
  finally
    Caller.WaitFor;
    Caller.Free;
  end;

  Assert.AreEqual('', Failure, 'the call itself failed');
  Assert.IsFalse(FWatch.SawCancellation,
    'the notification reached the running request after all, which the documents deny');
  Assert.IsTrue(Answer.Contains(WATCH_ANSWER),
    'the tool did not answer after the cancellation it never heard: ' + Answer);
end;

end.
