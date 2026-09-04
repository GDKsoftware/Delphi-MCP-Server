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
    function ValidateToken(const Token: string; out Claims: TJSONObject): Boolean; override;
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
    function Decide(const Authorizer: IMCPAuthorizer; const Token: string; out Principal: TMCPPrincipal;
      out Challenge: TMCPAuthChallenge): TMCPAuthDecision;
  public
    [TearDown]
    procedure TearDown;

    [Test] procedure StaticBearer_AcceptsListedTokens_RejectsOthers;
    [Test] procedure StaticBearer_NeedsAToken;
    [Test] procedure ConstantTime_ComparesWholeToken;
    [Test] procedure Principal_HasScope_HonoursWildcard;
    [Test] procedure OAuth_RejectsWrongAudience_Expiry_AndScope;
    [Test] procedure OAuth_AcceptsAudienceArray_AndScopeArray;
    [Test] procedure OAuth_NeedsAnAudience;
    [Test] procedure Challenge_Build_QuotesParameters;
    [Test] procedure Metadata_Build_DropsOfflineAccess;
    [Test] procedure Introspection_PostsTokenWithClientCredentials;
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

function TClaimsAuthorizer.ValidateToken(const Token: string; out Claims: TJSONObject): Boolean;
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

function TAuthorizationTests.Decide(const Authorizer: IMCPAuthorizer; const Token: string;
  out Principal: TMCPPrincipal; out Challenge: TMCPAuthChallenge): TMCPAuthDecision;
begin
  Result := Authorizer.Authorize(Token, 'POST', '/mcp', Principal, Challenge);
end;

procedure TAuthorizationTests.StaticBearer_AcceptsListedTokens_RejectsOthers;
var
  Principal: TMCPPrincipal;
  Challenge: TMCPAuthChallenge;
begin
  var Authorizer: IMCPAuthorizer := TMCPStaticBearerAuthorizer.Create(['alpha', ' beta ']);
  Assert.AreEqual(TMCPAuthDecision.Allow, Decide(Authorizer, 'alpha', Principal, Challenge));
  Assert.AreEqual('token-1', Principal.Subject);
  Assert.IsTrue(Principal.HasScope('anything'), 'pre-shared tokens grant every scope');
  Assert.AreEqual(TMCPAuthDecision.Allow, Decide(Authorizer, 'beta', Principal, Challenge));
  Assert.AreEqual('token-2', Principal.Subject);
  Assert.AreEqual(TMCPAuthDecision.Unauthorized, Decide(Authorizer, 'alph', Principal, Challenge));
  Assert.AreEqual('invalid_token', Challenge.Error);
  Assert.AreEqual('', Principal.Subject);
  Assert.AreEqual(TMCPAuthDecision.Unauthorized, Decide(Authorizer, '', Principal, Challenge));

  var Scoped: IMCPAuthorizer := TMCPStaticBearerAuthorizer.Create(['alpha'], ['read']);
  Assert.AreEqual(TMCPAuthDecision.Allow, Decide(Scoped, 'alpha', Principal, Challenge));
  Assert.IsTrue(Principal.HasScope('read'));
  Assert.IsFalse(Principal.HasScope('write'));
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
var
  Principal: TMCPPrincipal;
  Challenge: TMCPAuthChallenge;
begin
  var Future := System.DateUtils.DateTimeToUnix(Now, False) + 600;
  var Past := System.DateUtils.DateTimeToUnix(Now, False) - 600;

  var Invalid: IMCPAuthorizer := TClaimsAuthorizer.Create(AUDIENCE, Format('{"sub":"u","aud":"%s","exp":%d}', [AUDIENCE, Future]));
  Assert.AreEqual(TMCPAuthDecision.Unauthorized, Decide(Invalid, 'nope', Principal, Challenge));
  Assert.AreEqual('invalid_token', Challenge.Error);

  var WrongAudience: IMCPAuthorizer := TClaimsAuthorizer.Create(AUDIENCE, Format('{"sub":"u","aud":"https://other","exp":%d}', [Future]));
  Assert.AreEqual(TMCPAuthDecision.Unauthorized, Decide(WrongAudience, 'valid', Principal, Challenge));
  Assert.IsTrue(Challenge.ErrorDescription.Contains('not issued for this server'), Challenge.ErrorDescription);

  var Expired: IMCPAuthorizer := TClaimsAuthorizer.Create(AUDIENCE, Format('{"sub":"u","aud":"%s","exp":%d}', [AUDIENCE, Past]));
  Assert.AreEqual(TMCPAuthDecision.Unauthorized, Decide(Expired, 'valid', Principal, Challenge));
  Assert.IsTrue(Challenge.ErrorDescription.Contains('expired'), Challenge.ErrorDescription);

  var NoExpiry: IMCPAuthorizer := TClaimsAuthorizer.Create(AUDIENCE, Format('{"sub":"u","aud":"%s"}', [AUDIENCE]));
  Assert.AreEqual(TMCPAuthDecision.Unauthorized, Decide(NoExpiry, 'valid', Principal, Challenge), 'exp is mandatory');

  var Scoped := TClaimsAuthorizer.Create(AUDIENCE, Format('{"sub":"u","aud":"%s","exp":%d,"scope":"read"}', [AUDIENCE, Future]));
  var ScopedRef: IMCPAuthorizer := Scoped;
  Scoped.RequiredScopes := ['read', 'write'];
  Assert.AreEqual(TMCPAuthDecision.Forbidden, Decide(ScopedRef, 'valid', Principal, Challenge));
  Assert.AreEqual('insufficient_scope', Challenge.Error);
  Assert.AreEqual('read write', Challenge.Scope);

  Scoped.RequiredScopes := ['read'];
  Assert.AreEqual(TMCPAuthDecision.Allow, Decide(ScopedRef, 'valid', Principal, Challenge));
  Assert.AreEqual('u', Principal.Subject);
  Assert.IsTrue(Principal.HasScope('read'));
  Assert.IsFalse(Principal.HasScope('write'));
end;

procedure TAuthorizationTests.OAuth_AcceptsAudienceArray_AndScopeArray;
var
  Principal: TMCPPrincipal;
  Challenge: TMCPAuthChallenge;
begin
  var Future := System.DateUtils.DateTimeToUnix(Now, False) + 600;
  var Authorizer: IMCPAuthorizer := TClaimsAuthorizer.Create(AUDIENCE,
    Format('{"sub":"u","aud":["https://other","%s"],"exp":%d,"scp":["a","b"]}', [AUDIENCE.ToUpper, Future]));
  Assert.AreEqual(TMCPAuthDecision.Allow, Decide(Authorizer, 'valid', Principal, Challenge));
  Assert.IsTrue(Principal.HasScope('a'));
  Assert.IsTrue(Principal.HasScope('b'));
  Assert.IsFalse(Principal.HasScope('c'));
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
var
  Principal: TMCPPrincipal;
  Challenge: TMCPAuthChallenge;
begin
  FIntrospection := TIdHTTPServer.Create(nil);
  FIntrospection.Bindings.Add.IP := '127.0.0.1';
  FIntrospection.Bindings[0].Port := 0;
  FIntrospection.OnCommandGet := HandleIntrospection;
  FIntrospection.Active := True;
  var Url := Format('http://127.0.0.1:%d/introspect', [FIntrospection.Bindings[0].Port]);

  var Authorizer: IMCPAuthorizer := TMCPIntrospectionAuthorizer.Create(AUDIENCE, Url, 'mcp', 's3cret');
  Assert.AreEqual(TMCPAuthDecision.Allow, Decide(Authorizer, 'good', Principal, Challenge));
  Assert.AreEqual('alice', Principal.Subject);
  Assert.IsTrue(Principal.HasScope('read'));
  Assert.AreEqual('token=good', FSeenBody);
  Assert.IsTrue(FSeenAuthorization.StartsWith('Basic '), FSeenAuthorization);

  Assert.AreEqual(TMCPAuthDecision.Unauthorized, Decide(Authorizer, 'stale', Principal, Challenge));
  Assert.AreEqual('invalid_token', Challenge.Error);
end;

end.
