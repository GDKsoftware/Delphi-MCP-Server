unit MCPServer.Tests.Authorization;

interface

uses
  DUnitX.TestFramework,
  System.SysUtils,
  System.Classes,
  System.JSON,
  IdHTTPServer,
  IdContext,
  IdCustomHTTPServer,
  MCPServer.Types,
  MCPServer.Authorization;

type
  TClaimsAuthorizer = class(TMCPOAuthResourceServerAuthorizer)
  strict private
    FClaimsJson: string;
  protected
    function TryValidateToken(const Token: string; out Claims: TJSONObject): Boolean; override;
  public
    constructor Create(const ExpectedAudience, ClaimsJson: string);
  end;

  [TestFixture]
  TAuthorizationTests = class
  private
    FIntrospection: TIdHTTPServer;
    FSeenAuthorization: string;
    FSeenBody: string;
    procedure HandleIntrospection(Context: TIdContext; Request: TIdHTTPRequestInfo; Response: TIdHTTPResponseInfo);
    function Decide(const Authorizer: IMCPAuthorizer; const Token: string): TMCPAuthResult;
  public
    [TearDown]
    procedure TearDown;

    [Test]
    procedure StaticBearer_AcceptsListedTokens_RejectsOthers;

    [Test]
    procedure StaticBearer_NeedsAToken;

    [Test]
    procedure ConstantTime_ComparesWholeToken;

    [Test]
    procedure Principal_HasScope_HonoursWildcard;

    [Test]
    procedure OAuth_RejectsWrongAudience_Expiry_AndScope;

    [Test]
    procedure OAuth_AcceptsAudienceArray_AndScopeArray;

    [Test]
    procedure OAuth_NeedsAnAudience;

    [Test]
    procedure Challenge_Build_QuotesParameters;

    [Test]
    procedure Metadata_Build_DropsOfflineAccess;

    [Test]
    procedure Introspection_PostsTokenWithClientCredentials;
  end;

implementation

uses
  System.DateUtils;

const
  AUDIENCE = 'https://mcp.example/mcp';

{ TClaimsAuthorizer }

constructor TClaimsAuthorizer.Create(const ExpectedAudience, ClaimsJson: string);
begin
  inherited Create(ExpectedAudience);
  FClaimsJson := ClaimsJson;
end;

function TClaimsAuthorizer.TryValidateToken(const Token: string; out Claims: TJSONObject): Boolean;
begin
  Claims := nil;
  if Token <> 'valid' then
    Exit(False);
  Claims := TJSONObject.ParseJSONValue(FClaimsJson) as TJSONObject;
  Result := True;
end;

{ TAuthorizationTests }

procedure TAuthorizationTests.TearDown;
begin
  FIntrospection.Free;
  FIntrospection := nil;
end;

function TAuthorizationTests.Decide(const Authorizer: IMCPAuthorizer; const Token: string): TMCPAuthResult;
begin
  Result := Authorizer.Authorize(Token, 'POST', '/mcp');
end;

procedure TAuthorizationTests.StaticBearer_AcceptsListedTokens_RejectsOthers;
begin
  var Authorizer: IMCPAuthorizer := TMCPStaticBearerAuthorizer.Create(['alpha', ' beta ']);
  var First := Decide(Authorizer, 'alpha');
  Assert.AreEqual(TMCPAuthDecision.Allow, First.Decision);
  Assert.AreEqual('token-1', First.Principal.Subject);
  Assert.IsTrue(First.Principal.HasScope('anything'), 'pre-shared tokens grant every scope');

  var Second := Decide(Authorizer, 'beta');
  Assert.AreEqual(TMCPAuthDecision.Allow, Second.Decision);
  Assert.AreEqual('token-2', Second.Principal.Subject);

  var Unknown := Decide(Authorizer, 'alph');
  Assert.AreEqual(TMCPAuthDecision.Unauthorized, Unknown.Decision);
  Assert.AreEqual('invalid_token', Unknown.Challenge.Error);
  Assert.AreEqual('', Unknown.Principal.Subject);
  Assert.AreEqual(TMCPAuthDecision.Unauthorized, Decide(Authorizer, '').Decision);

  var Scoped: IMCPAuthorizer := TMCPStaticBearerAuthorizer.Create(['alpha'], ['read']);
  var Limited := Decide(Scoped, 'alpha');
  Assert.AreEqual(TMCPAuthDecision.Allow, Limited.Decision);
  Assert.IsTrue(Limited.Principal.HasScope('read'));
  Assert.IsFalse(Limited.Principal.HasScope('write'));
end;

procedure TAuthorizationTests.StaticBearer_NeedsAToken;
begin
  Assert.WillRaise(
    procedure
    begin
      TMCPStaticBearerAuthorizer.Create(['', '  ']).Free;
    end, EMCPAuthorizationConfiguration);
end;

procedure TAuthorizationTests.ConstantTime_ComparesWholeToken;
begin
  Assert.IsTrue(TMCPConstantTime.SameBytes(TEncoding.UTF8.GetBytes('secret'), TEncoding.UTF8.GetBytes('secret')));
  Assert.IsFalse(TMCPConstantTime.SameBytes(TEncoding.UTF8.GetBytes('secret'), TEncoding.UTF8.GetBytes('secret2')));
  Assert.IsFalse(TMCPConstantTime.SameBytes(TEncoding.UTF8.GetBytes('secret'), TEncoding.UTF8.GetBytes('secreT')));
  Assert.IsFalse(TMCPConstantTime.SameBytes(nil, TEncoding.UTF8.GetBytes('x')));
  Assert.IsTrue(TMCPConstantTime.SameBytes(nil, nil));
end;

procedure TAuthorizationTests.Principal_HasScope_HonoursWildcard;
begin
  var Principal := TMCPPrincipal.None;
  Assert.IsFalse(Principal.HasScope('read'));
  Principal.Scopes := ['read', 'files:write'];
  Assert.IsTrue(Principal.HasScope('files:write'));
  Assert.IsFalse(Principal.HasScope('admin'));
  Principal.Scopes := ['*'];
  Assert.IsTrue(Principal.HasScope('admin'));
end;

procedure TAuthorizationTests.OAuth_RejectsWrongAudience_Expiry_AndScope;
begin
  var Future := System.DateUtils.DateTimeToUnix(Now, False) + 600;
  var Past := System.DateUtils.DateTimeToUnix(Now, False) - 600;

  var Invalid: IMCPAuthorizer := TClaimsAuthorizer.Create(AUDIENCE, Format('{"sub":"u","aud":"%s","exp":%d}', [AUDIENCE, Future]));
  var Rejected := Decide(Invalid, 'nope');
  Assert.AreEqual(TMCPAuthDecision.Unauthorized, Rejected.Decision);
  Assert.AreEqual('invalid_token', Rejected.Challenge.Error);

  var WrongAudience: IMCPAuthorizer := TClaimsAuthorizer.Create(AUDIENCE, Format('{"sub":"u","aud":"https://other","exp":%d}', [Future]));
  var ForAnother := Decide(WrongAudience, 'valid');
  Assert.AreEqual(TMCPAuthDecision.Unauthorized, ForAnother.Decision);
  Assert.IsTrue(ForAnother.Challenge.ErrorDescription.Contains('not issued for this server'),
    ForAnother.Challenge.ErrorDescription);

  var Expired: IMCPAuthorizer := TClaimsAuthorizer.Create(AUDIENCE, Format('{"sub":"u","aud":"%s","exp":%d}', [AUDIENCE, Past]));
  var Stale := Decide(Expired, 'valid');
  Assert.AreEqual(TMCPAuthDecision.Unauthorized, Stale.Decision);
  Assert.IsTrue(Stale.Challenge.ErrorDescription.Contains('expired'), Stale.Challenge.ErrorDescription);

  var NoExpiry: IMCPAuthorizer := TClaimsAuthorizer.Create(AUDIENCE, Format('{"sub":"u","aud":"%s"}', [AUDIENCE]));
  Assert.AreEqual(TMCPAuthDecision.Unauthorized, Decide(NoExpiry, 'valid').Decision, 'exp is mandatory');

  var Scoped := TClaimsAuthorizer.Create(AUDIENCE, Format('{"sub":"u","aud":"%s","exp":%d,"scope":"read"}', [AUDIENCE, Future]));
  var ScopedRef: IMCPAuthorizer := Scoped;
  Scoped.RequiredScopes := ['read', 'write'];
  var Denied := Decide(ScopedRef, 'valid');
  Assert.AreEqual(TMCPAuthDecision.Forbidden, Denied.Decision);
  Assert.AreEqual('insufficient_scope', Denied.Challenge.Error);
  Assert.AreEqual('read write', Denied.Challenge.Scope);

  Scoped.RequiredScopes := ['read'];
  var Allowed := Decide(ScopedRef, 'valid');
  Assert.AreEqual(TMCPAuthDecision.Allow, Allowed.Decision);
  Assert.AreEqual('u', Allowed.Principal.Subject);
  Assert.IsTrue(Allowed.Principal.HasScope('read'));
  Assert.IsFalse(Allowed.Principal.HasScope('write'));
end;

procedure TAuthorizationTests.OAuth_AcceptsAudienceArray_AndScopeArray;
begin
  var Future := System.DateUtils.DateTimeToUnix(Now, False) + 600;
  var Authorizer: IMCPAuthorizer := TClaimsAuthorizer.Create(AUDIENCE,
    Format('{"sub":"u","aud":["https://other","%s"],"exp":%d,"scp":["a","b"]}', [AUDIENCE.ToUpper, Future]));
  var Outcome := Decide(Authorizer, 'valid');
  Assert.AreEqual(TMCPAuthDecision.Allow, Outcome.Decision);
  Assert.IsTrue(Outcome.Principal.HasScope('a'));
  Assert.IsTrue(Outcome.Principal.HasScope('b'));
  Assert.IsFalse(Outcome.Principal.HasScope('c'));
end;

procedure TAuthorizationTests.OAuth_NeedsAnAudience;
begin
  Assert.WillRaise(
    procedure
    begin
      TClaimsAuthorizer.Create(' ', '{}').Free;
    end, EMCPAuthorizationConfiguration);
end;

procedure TAuthorizationTests.Challenge_Build_QuotesParameters;
begin
  Assert.AreEqual('Bearer', TMCPBearerChallenge.Build('', TMCPAuthChallenge.None));
  Assert.AreEqual('Bearer resource_metadata="https://s/.well-known/oauth-protected-resource/mcp"',
    TMCPBearerChallenge.Build('https://s/.well-known/oauth-protected-resource/mcp', TMCPAuthChallenge.None));
  Assert.AreEqual('Bearer error="invalid_token", error_description="say \"hi\""',
    TMCPBearerChallenge.Build('', TMCPAuthChallenge.InvalidToken('say "hi"')));
  Assert.AreEqual('Bearer resource_metadata="https://s/m", error="insufficient_scope", scope="read write"',
    TMCPBearerChallenge.Build('https://s/m', TMCPAuthChallenge.InsufficientScope('read write')));
  Assert.IsFalse(TMCPBearerChallenge.Build('', TMCPAuthChallenge.InvalidRequest('a'#13#10'b')).Contains(#10));
end;

procedure TAuthorizationTests.Metadata_Build_DropsOfflineAccess;
begin
  var Metadata := TMCPProtectedResourceMetadata.Build('https://mcp.example/mcp', 'demo',
    ['https://auth.example'], ['read', 'offline_access', 'write']);
  try
    Assert.AreEqual('https://mcp.example/mcp', Metadata.GetValue<string>('resource'));
    Assert.AreEqual('https://auth.example', Metadata.GetValue<string>('authorization_servers[0]'));
    Assert.AreEqual(2, (Metadata.GetValue('scopes_supported') as TJSONArray).Count);
    Assert.AreEqual('header', Metadata.GetValue<string>('bearer_methods_supported[0]'));
    Assert.AreEqual('demo', Metadata.GetValue<string>('resource_name'));
  finally
    Metadata.Free;
  end;

  var Bare := TMCPProtectedResourceMetadata.Build('https://mcp.example/mcp', '', nil, nil);
  try
    Assert.AreEqual(0, (Bare.GetValue('authorization_servers') as TJSONArray).Count);
    Assert.IsNull(Bare.GetValue('scopes_supported'));
    Assert.IsNull(Bare.GetValue('resource_name'));
  finally
    Bare.Free;
  end;
end;

procedure TAuthorizationTests.HandleIntrospection(Context: TIdContext; Request: TIdHTTPRequestInfo;
  Response: TIdHTTPResponseInfo);
begin
  FSeenAuthorization := Request.RawHeaders.Values['Authorization'];
  FSeenBody := Request.FormParams;
  Response.ContentType := 'application/json';
  if FSeenBody.Contains('token=good') then
    Response.ContentText := Format('{"active":true,"sub":"alice","aud":"%s","exp":%d,"scope":"read"}',
      [AUDIENCE, System.DateUtils.DateTimeToUnix(Now, False) + 600])
  else
    Response.ContentText := '{"active":false}';
end;

procedure TAuthorizationTests.Introspection_PostsTokenWithClientCredentials;
begin
  FIntrospection := TIdHTTPServer.Create(nil);
  FIntrospection.Bindings.Add.IP := '127.0.0.1';
  FIntrospection.Bindings[0].Port := 0;
  FIntrospection.OnCommandGet := HandleIntrospection;
  FIntrospection.Active := True;
  var Url := Format('http://127.0.0.1:%d/introspect', [FIntrospection.Bindings[0].Port]);

  var Authorizer: IMCPAuthorizer := TMCPIntrospectionAuthorizer.Create(AUDIENCE, Url, 'mcp', 's3cret');
  var Active := Decide(Authorizer, 'good');
  Assert.AreEqual(TMCPAuthDecision.Allow, Active.Decision);
  Assert.AreEqual('alice', Active.Principal.Subject);
  Assert.IsTrue(Active.Principal.HasScope('read'));
  Assert.AreEqual('token=good', FSeenBody);
  Assert.IsTrue(FSeenAuthorization.StartsWith('Basic '), FSeenAuthorization);

  var Stale := Decide(Authorizer, 'stale');
  Assert.AreEqual(TMCPAuthDecision.Unauthorized, Stale.Decision);
  Assert.AreEqual('invalid_token', Stale.Challenge.Error);
end;

end.
