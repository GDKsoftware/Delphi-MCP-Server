unit MCPClient.Tests.Auth;

// What the client does when the server wants a bearer token, and what it does when the token it
// holds stops being accepted.
//
// The fixture drives a real TMCPServerHost on an ephemeral port with an authorizer a test can
// steer, so the 401 and the 403 come out of the same code a deployed server runs rather than out
// of a canned reply. TScriptedAuth counts every call, which is what turns "refreshes once and
// retries once" into an assertion: Agora never called RefreshToken at all, so an expired token
// became an unexplained tool error.
//
// A 401 is a token problem and the client fixes it once. A 403 is a permission problem that no
// refresh can fix, so tools/call reports the missing scope in its outcome and every other method
// raises.

interface

uses
  System.SysUtils,
  System.SyncObjs,
  System.JSON,
  DUnitX.TestFramework,
  MCPServer.Authorization,
  MCPServer.Host,
  MCPServer.Tool.ContentSamples,
  MCPClient.Types,
  MCPClient.Interfaces,
  MCPClient.Errors,
  MCPClient;

const
  SCOPE_READ = 'tools:read';
  SCOPE_WRITE = 'tools:write';

type
  { A tool nobody may call without a scope the test server does not grant. }
  [RequiresScope(SCOPE_WRITE)]
  TScopedEchoTool = class(TSimpleTextTool)
  public
    constructor Create; override;
  end;

  {$SCOPEDENUMS ON}
  TAuthorizerVerdict = (Accept, Forbid);
  {$SCOPEDENUMS OFF}

  { Accepts exactly one token at a time and records every token it was shown, so a test can retire
    a token in the middle of a session and then count what the client presented. Indy answers each
    connection on its own thread, hence the lock. }
  TRetiringAuthorizer = class(TInterfacedObject, IMCPAuthorizer)
  strict private
    FLock: TCriticalSection;
    FAccepted: string;
    FVerdict: TAuthorizerVerdict;
    FScopes: TArray<string>;
    FSeen: TArray<string>;
  public
    constructor Create(const Accepted: string; const Scopes: TArray<string>);
    destructor Destroy; override;

    function Authorize(const BearerToken, HttpMethod, Path: string): TMCPAuthResult;

    procedure Accept(const Token: string);
    procedure Forbid;
    function SeenCount: Integer;
    function Seen(const Index: Integer): string;
  end;

  { A token source a test scripts up front: GetToken hands out the token in hand, Refresh moves to
    the next one and returns '' once the script is spent, which is how a host says it cannot
    refresh. }
  TScriptedAuth = class(TInterfacedObject, IMCPClientAuth)
  strict private
    FTokens: TArray<string>;
    FIndex: Integer;
    FRefreshCalls: Integer;
  public
    constructor Create(const Tokens: TArray<string>);

    function GetToken: string;
    function Refresh: string;

    property RefreshCalls: Integer read FRefreshCalls;
  end;

  [TestFixture]
  TMCPClientAuthTests = class
  private
    FHost: TMCPServerHost;
    FAuthorizer: TRetiringAuthorizer;
    FAuth: TScriptedAuth;
    FClient: IMCPClient;
    FTrace: TMCPClient;
    FRequests: Integer;
    function Url: string;
    function Options: TMCPClientOptions;
    procedure NewClient(const Tokens: TArray<string>); overload;
    procedure NewClient(const Tokens: TArray<string>; const AOptions: TMCPClientOptions); overload;
    function ConnectFailure: EMCPClientError;
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    [Test]
    procedure Connect_WithAnAcceptedToken_PresentsItOnce;

    [Test]
    procedure Connect_StaleToken_RefreshesOnceAndRetriesOnce;

    [Test]
    procedure Connect_RefreshThatDoesNotHelp_RaisesOnTheSecondUnauthorized;

    [Test]
    procedure Connect_RefreshThatReturnsNothing_RaisesWithoutARetry;

    [Test]
    procedure Connect_WithoutAnAuth_RaisesWithTheChallenge;

    [Test]
    procedure Connect_WithoutAuthRetries_DoesNotRefresh;

    [Test]
    procedure CallTool_TokenRetiredMidSession_RefreshesAndAnswers;

    [Test]
    procedure EveryRequest_CarriesTheBearerToken;

    [Test]
    procedure Connect_ForbiddenToken_RaisesAScopeErrorWithoutRefreshing;

    [Test]
    procedure CallTool_WithoutTheRequiredScope_ReportsTheScopeInTheOutcome;
  end;

implementation

uses
  MCPServer.Types,
  MCPServer.Registration;

const
  LOOPBACK = '127.0.0.1';
  ENDPOINT = '/mcp';
  URL_TEMPLATE = 'http://%s:%d%s';

  TOOL_ECHO = 'echo';
  TOOL_SCOPED = 'test_scoped_echo';

  TOKEN_FIRST = 'token-one';
  TOKEN_SECOND = 'token-two';
  TOKEN_STALE = 'token-stale';
  TOKEN_STALER = 'token-staler';

  MESSAGE_INVALID_TOKEN = 'The token is no longer accepted';
  MESSAGE_ARGUMENT = 'message';
  ECHOED_TEXT = 'still here';

{ TScopedEchoTool }

constructor TScopedEchoTool.Create;
begin
  inherited;
  FName := TOOL_SCOPED;
  FDescription := 'A tool that needs a scope the test server never grants';
end;

{ TRetiringAuthorizer }

constructor TRetiringAuthorizer.Create(const Accepted: string; const Scopes: TArray<string>);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FAccepted := Accepted;
  FScopes := Scopes;
  FVerdict := TAuthorizerVerdict.Accept;
end;

destructor TRetiringAuthorizer.Destroy;
begin
  FLock.Free;
  inherited;
end;

function TRetiringAuthorizer.Authorize(const BearerToken, HttpMethod, Path: string): TMCPAuthResult;
begin
  FLock.Enter;
  try
    FSeen := FSeen + [BearerToken];

    if FVerdict = TAuthorizerVerdict.Forbid then
      Exit(TMCPAuthResult.Denied(TMCPAuthDecision.Forbidden,
        TMCPAuthChallenge.InsufficientScope(SCOPE_WRITE)));

    const IsAccepted = (BearerToken = FAccepted);
    if not IsAccepted then
      Exit(TMCPAuthResult.Denied(TMCPAuthDecision.Unauthorized,
        TMCPAuthChallenge.InvalidToken(MESSAGE_INVALID_TOKEN)));

    var Principal := TMCPPrincipal.None;
    Principal.Subject := BearerToken;
    Principal.Scopes := FScopes;
    Result := TMCPAuthResult.Allowed(Principal);
  finally
    FLock.Leave;
  end;
end;

procedure TRetiringAuthorizer.Accept(const Token: string);
begin
  FLock.Enter;
  try
    FAccepted := Token;
  finally
    FLock.Leave;
  end;
end;

procedure TRetiringAuthorizer.Forbid;
begin
  FLock.Enter;
  try
    FVerdict := TAuthorizerVerdict.Forbid;
  finally
    FLock.Leave;
  end;
end;

function TRetiringAuthorizer.SeenCount: Integer;
begin
  FLock.Enter;
  try
    Result := Integer(Length(FSeen));
  finally
    FLock.Leave;
  end;
end;

function TRetiringAuthorizer.Seen(const Index: Integer): string;
begin
  FLock.Enter;
  try
    Result := FSeen[Index];
  finally
    FLock.Leave;
  end;
end;

{ TScriptedAuth }

constructor TScriptedAuth.Create(const Tokens: TArray<string>);
begin
  inherited Create;
  FTokens := Tokens;
end;

function TScriptedAuth.GetToken: string;
begin
  const IsSpent = (FIndex >= Length(FTokens));
  if IsSpent then
    Exit('');
  Result := FTokens[FIndex];
end;

function TScriptedAuth.Refresh: string;
begin
  Inc(FRefreshCalls);
  Inc(FIndex);
  Result := GetToken;
end;

{ TMCPClientAuthTests }

procedure TMCPClientAuthTests.Setup;
begin
  FAuthorizer := TRetiringAuthorizer.Create(TOKEN_FIRST, [SCOPE_READ]);

  FHost := TMCPServerHost.Create;
  FHost.Settings.Port := 0;
  FHost.Settings.CorsEnabled := False;
  FHost.Authorizer := FAuthorizer;
  FHost.AddTool(TMCPRegistry.CreateTool(TOOL_ECHO));
  FHost.AddTool(TScopedEchoTool.Create);
  FHost.StartHttp;
end;

procedure TMCPClientAuthTests.TearDown;
begin
  FTrace := nil;
  FClient := nil;
  FAuth := nil;
  FAuthorizer := nil;
  FreeAndNil(FHost);
end;

function TMCPClientAuthTests.Url: string;
begin
  Result := Format(URL_TEMPLATE, [LOOPBACK, FHost.BoundPort, ENDPOINT]);
end;

function TMCPClientAuthTests.Options: TMCPClientOptions;
begin
  Result := TMCPClientOptions.Default;
  Result.Era := TMCPClientEra.Modern;
end;

procedure TMCPClientAuthTests.NewClient(const Tokens: TArray<string>);
begin
  NewClient(Tokens, Options);
end;

procedure TMCPClientAuthTests.NewClient(const Tokens: TArray<string>; const AOptions: TMCPClientOptions);
begin
  var Auth: IMCPClientAuth := nil;
  FAuth := nil;
  const HasTokens = (Length(Tokens) > 0);
  if HasTokens then
  begin
    FAuth := TScriptedAuth.Create(Tokens);
    Auth := FAuth;
  end;

  FRequests := 0;
  FTrace := TMCPClient.Create(Url, AOptions, Auth);
  FClient := FTrace;
  FTrace.OnRequestBody :=
    procedure(Body: string)
    begin
      Inc(FRequests);
    end;
end;

function TMCPClientAuthTests.ConnectFailure: EMCPClientError;
begin
  Result := nil;
  try
    FClient.Connect;
  except
    on E: EMCPClientError do
      Result := EMCPClientError(AcquireExceptionObject);
  end;
  Assert.IsNotNull(Result, 'the client connected to a server that refused it');
end;

procedure TMCPClientAuthTests.Connect_WithAnAcceptedToken_PresentsItOnce;
begin
  NewClient([TOKEN_FIRST]);

  FClient.Connect;

  Assert.IsTrue(FClient.IsConnected);
  Assert.AreEqual(1, FAuthorizer.SeenCount, 'the client presented the token more than once');
  Assert.AreEqual(TOKEN_FIRST, FAuthorizer.Seen(0));
  Assert.AreEqual(0, FAuth.RefreshCalls, 'an accepted token was refreshed anyway');
end;

procedure TMCPClientAuthTests.Connect_StaleToken_RefreshesOnceAndRetriesOnce;
begin
  NewClient([TOKEN_STALE, TOKEN_FIRST]);

  FClient.Connect;

  Assert.IsTrue(FClient.IsConnected, 'the retry with the refreshed token did not connect');
  Assert.AreEqual(1, FAuth.RefreshCalls, 'the client did not refresh exactly once');
  Assert.AreEqual(2, FAuthorizer.SeenCount, 'the client did not retry exactly once');
  Assert.AreEqual(TOKEN_STALE, FAuthorizer.Seen(0));
  Assert.AreEqual(TOKEN_FIRST, FAuthorizer.Seen(1), 'the retry did not carry the refreshed token');
end;

procedure TMCPClientAuthTests.Connect_RefreshThatDoesNotHelp_RaisesOnTheSecondUnauthorized;
begin
  NewClient([TOKEN_STALE, TOKEN_STALER]);

  const Failure = ConnectFailure;
  try
    Assert.IsTrue(Failure is EMCPClientAuthError, 'the second 401 did not raise an auth error: ' +
      Failure.ClassName);
    Assert.AreEqual(1, FAuth.RefreshCalls, 'the client refreshed more than once');
    Assert.AreEqual(2, FAuthorizer.SeenCount, 'the client retried more than once');
    Assert.IsFalse(FClient.IsConnected);
  finally
    Failure.Free;
  end;
end;

procedure TMCPClientAuthTests.Connect_RefreshThatReturnsNothing_RaisesWithoutARetry;
begin
  NewClient([TOKEN_STALE]);

  const Failure = ConnectFailure;
  try
    Assert.IsTrue(Failure is EMCPClientAuthError, 'the 401 did not raise an auth error: ' +
      Failure.ClassName);
    Assert.AreEqual(1, FAuth.RefreshCalls, 'the client did not ask for a refresh');
    Assert.AreEqual(1, FAuthorizer.SeenCount, 'the client retried with a token it does not have');
  finally
    Failure.Free;
  end;
end;

procedure TMCPClientAuthTests.Connect_WithoutAnAuth_RaisesWithTheChallenge;
begin
  NewClient([]);

  const Failure = ConnectFailure;
  try
    Assert.IsTrue(Failure is EMCPClientAuthError, 'an anonymous client did not raise an auth error');
    Assert.IsTrue(EMCPClientAuthError(Failure).Challenge.StartsWith(TMCPBearerChallenge.SCHEME),
      'the challenge is missing: ' + EMCPClientAuthError(Failure).Challenge);
    Assert.AreEqual(0, FAuthorizer.SeenCount,
      'a request without an Authorization header never reaches the authorizer');
    Assert.AreEqual(1, FRequests, 'the client retried with a token it never had');
  finally
    Failure.Free;
  end;
end;

procedure TMCPClientAuthTests.Connect_WithoutAuthRetries_DoesNotRefresh;
begin
  var Strict := Options;
  Strict.MaxAuthRetries := 0;
  NewClient([TOKEN_STALE, TOKEN_FIRST], Strict);

  const Failure = ConnectFailure;
  try
    Assert.IsTrue(Failure is EMCPClientAuthError, 'the 401 did not raise an auth error');
    Assert.AreEqual(0, FAuth.RefreshCalls, 'MaxAuthRetries = 0 still refreshed');
    Assert.AreEqual(1, FAuthorizer.SeenCount);
  finally
    Failure.Free;
  end;
end;

procedure TMCPClientAuthTests.CallTool_TokenRetiredMidSession_RefreshesAndAnswers;
begin
  NewClient([TOKEN_FIRST, TOKEN_SECOND]);
  FClient.Connect;

  // The server retires the token the client is holding, which is what an expiry looks like from
  // the client side: the connection was fine and the next request is not.
  FAuthorizer.Accept(TOKEN_SECOND);

  const Arguments = TJSONObject.Create.AddPair(MESSAGE_ARGUMENT, ECHOED_TEXT);
  try
    const Outcome = FClient.CallTool(TOOL_ECHO, Arguments);

    Assert.IsFalse(Outcome.IsError, 'the refreshed call failed: ' + Outcome.Text);
    Assert.AreEqual('Echo: ' + ECHOED_TEXT, Outcome.Text);
  finally
    Arguments.Free;
  end;

  Assert.AreEqual(1, FAuth.RefreshCalls, 'the client did not refresh exactly once');
  Assert.AreEqual(3, FAuthorizer.SeenCount, 'the probe, the refused call and the retry make three');
  Assert.AreEqual(TOKEN_SECOND, FAuthorizer.Seen(2));
end;

procedure TMCPClientAuthTests.EveryRequest_CarriesTheBearerToken;
begin
  NewClient([TOKEN_FIRST]);

  FClient.ListTools;

  Assert.AreEqual(2, FAuthorizer.SeenCount, 'the probe and tools/list make two requests');
  for var Index := 0 to FAuthorizer.SeenCount - 1 do
    Assert.AreEqual(TOKEN_FIRST, FAuthorizer.Seen(Index),
      Format('request %d went out without the token', [Index]));
end;

procedure TMCPClientAuthTests.Connect_ForbiddenToken_RaisesAScopeErrorWithoutRefreshing;
begin
  NewClient([TOKEN_FIRST]);
  FAuthorizer.Forbid;

  const Failure = ConnectFailure;
  try
    Assert.IsTrue(Failure is EMCPClientScopeError, 'a 403 did not raise a scope error: ' +
      Failure.ClassName);
    Assert.AreEqual(SCOPE_WRITE, EMCPClientScopeError(Failure).RequiredScope);
    Assert.AreEqual(0, FAuth.RefreshCalls, 'a refresh cannot grant a scope, so none was due');
    Assert.AreEqual(1, FAuthorizer.SeenCount, 'the client retried a request no token can fix');
  finally
    Failure.Free;
  end;
end;

procedure TMCPClientAuthTests.CallTool_WithoutTheRequiredScope_ReportsTheScopeInTheOutcome;
begin
  NewClient([TOKEN_FIRST]);

  const Outcome = FClient.CallTool(TOOL_SCOPED, nil);

  Assert.IsTrue(Outcome.IsError, 'a refused tool call reported success');
  Assert.AreEqual(SCOPE_WRITE, Outcome.RequiredScope, 'the model cannot say what a human must grant');
  Assert.AreEqual(JSONRPC_INVALID_REQUEST, Outcome.ErrorCode);
  Assert.IsTrue(Outcome.ErrorMessage.Contains(SCOPE_WRITE), Outcome.ErrorMessage);
  Assert.AreEqual(0, FAuth.RefreshCalls, 'a missing scope is not a token problem');
end;

end.
