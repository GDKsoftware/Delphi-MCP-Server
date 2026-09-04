unit MCPServer.Authorization;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Types;

type
  TMCPAuthDecision = (Allow, Unauthorized, Forbidden, BadRequest);

  TMCPPrincipal = record
    Subject: string;
    Scopes: TArray<string>;
    function HasScope(const Scope: string): Boolean;
    class function None: TMCPPrincipal; static;
  end;

  TMCPAuthChallenge = record
    Error: string;
    ErrorDescription: string;
    Scope: string;
    class function None: TMCPAuthChallenge; static;
    class function InvalidToken(const Description: string): TMCPAuthChallenge; static;
    class function InvalidRequest(const Description: string): TMCPAuthChallenge; static;
    class function InsufficientScope(const Scope: string): TMCPAuthChallenge; static;
  end;

  IMCPAuthorizer = interface
    ['{7B3D5F1A-9C2E-4A8B-B6D0-1E3F5A7C9B2D}']
    function Authorize(const BearerToken, HttpMethod, Path: string; out Principal: TMCPPrincipal;
      out Challenge: TMCPAuthChallenge): TMCPAuthDecision;
  end;

  RequiresScopeAttribute = class(TCustomAttribute)
  private
    FScope: string;
  public
    constructor Create(const AScope: string);
    property Scope: string read FScope;
  end;

  TMCPBearerChallenge = record
    const SCHEME = 'Bearer';
    const ERROR_INVALID_TOKEN = 'invalid_token';
    const ERROR_INVALID_REQUEST = 'invalid_request';
    const ERROR_INSUFFICIENT_SCOPE = 'insufficient_scope';
    class function Build(const ResourceMetadataUrl: string; const Challenge: TMCPAuthChallenge): string; static;
    class function Quote(const Value: string): string; static;
  end;

  TMCPProtectedResourceMetadata = record
    const WELL_KNOWN_PATH = '/.well-known/oauth-protected-resource';
    class function Build(const ResourceUri, ResourceName: string;
      const AuthorizationServers, ScopesSupported: TArray<string>): TJSONObject; static;
    class function WithoutOfflineAccess(const Scopes: TArray<string>): TArray<string>; static;
  end;

  TMCPStaticBearerAuthorizer = class(TInterfacedObject, IMCPAuthorizer)
  strict private
    FTokens: TArray<TBytes>;
    FScopes: TArray<string>;
  public
    constructor Create(const Tokens: TArray<string>; const Scopes: TArray<string> = nil);
    function Authorize(const BearerToken, HttpMethod, Path: string; out Principal: TMCPPrincipal;
      out Challenge: TMCPAuthChallenge): TMCPAuthDecision;
    class function SameToken(const Presented, Expected: TBytes): Boolean; static;
  end;

  TMCPOAuthResourceServerAuthorizer = class abstract(TInterfacedObject, IMCPAuthorizer)
  strict private
    FExpectedAudience: string;
    FRequiredScopes: TArray<string>;
  protected
    function ValidateToken(const Token: string; out Claims: TJSONObject): Boolean; virtual; abstract;
    function AudienceMatches(const Claims: TJSONObject): Boolean; virtual;
    function IsExpired(const Claims: TJSONObject): Boolean; virtual;
    function ScopesOf(const Claims: TJSONObject): TArray<string>; virtual;
  public
    constructor Create(const ExpectedAudience: string);
    function Authorize(const BearerToken, HttpMethod, Path: string; out Principal: TMCPPrincipal;
      out Challenge: TMCPAuthChallenge): TMCPAuthDecision;
    property ExpectedAudience: string read FExpectedAudience;
    property RequiredScopes: TArray<string> read FRequiredScopes write FRequiredScopes;
  end;

  TMCPIntrospectionAuthorizer = class(TMCPOAuthResourceServerAuthorizer)
  strict private
    FIntrospectionUrl: string;
    FClientId: string;
    FClientSecret: string;
    FTimeoutMs: Integer;
  protected
    function ValidateToken(const Token: string; out Claims: TJSONObject): Boolean; override;
  public
    const DEFAULT_TIMEOUT_MS = 5000;
    constructor Create(const ExpectedAudience, IntrospectionUrl, ClientId, ClientSecret: string);
    property IntrospectionUrl: string read FIntrospectionUrl;
    property TimeoutMs: Integer read FTimeoutMs write FTimeoutMs;
  end;

  EMCPAuthorizationConfiguration = class(Exception)
  end;

implementation

uses
  System.Classes,
  System.DateUtils,
  System.NetEncoding,
  System.Net.HttpClient,
  System.Net.URLClient,
  System.NetConsts,
  MCPServer.Logger;

const
  CLAIM_SUBJECT = 'sub';
  CLAIM_AUDIENCE = 'aud';
  CLAIM_EXPIRY = 'exp';
  CLAIM_SCOPE = 'scope';
  CLAIM_SCOPE_ARRAY = 'scp';
  CLAIM_ACTIVE = 'active';
  SCOPE_ANY = '*';
  SCOPE_OFFLINE_ACCESS = 'offline_access';
  SCOPE_SEPARATOR = ' ';
  STATIC_SUBJECT_FORMAT = 'token-%d';
  MEDIA_TYPE_FORM = 'application/x-www-form-urlencoded';

{ TMCPPrincipal }

class function TMCPPrincipal.None: TMCPPrincipal;
begin
  Result := Default(TMCPPrincipal);
end;

function TMCPPrincipal.HasScope(const Scope: string): Boolean;
begin
  for var Granted in Scopes do
  begin
    if (Granted = Scope) or (Granted = SCOPE_ANY) then
      Exit(True);
  end;
  Result := False;
end;

{ TMCPAuthChallenge }

class function TMCPAuthChallenge.None: TMCPAuthChallenge;
begin
  Result := Default(TMCPAuthChallenge);
end;

class function TMCPAuthChallenge.InvalidToken(const Description: string): TMCPAuthChallenge;
begin
  Result := Default(TMCPAuthChallenge);
  Result.Error := TMCPBearerChallenge.ERROR_INVALID_TOKEN;
  Result.ErrorDescription := Description;
end;

class function TMCPAuthChallenge.InvalidRequest(const Description: string): TMCPAuthChallenge;
begin
  Result := Default(TMCPAuthChallenge);
  Result.Error := TMCPBearerChallenge.ERROR_INVALID_REQUEST;
  Result.ErrorDescription := Description;
end;

class function TMCPAuthChallenge.InsufficientScope(const Scope: string): TMCPAuthChallenge;
begin
  Result := Default(TMCPAuthChallenge);
  Result.Error := TMCPBearerChallenge.ERROR_INSUFFICIENT_SCOPE;
  Result.Scope := Scope;
end;

{ RequiresScopeAttribute }

constructor RequiresScopeAttribute.Create(const AScope: string);
begin
  inherited Create;
  FScope := AScope;
end;

{ TMCPBearerChallenge }

class function TMCPBearerChallenge.Quote(const Value: string): string;
begin
  var Clean := Value.Replace(#13, ' ').Replace(#10, ' ');
  Result := '"' + Clean.Replace('\', '\\').Replace('"', '\"') + '"';
end;

class function TMCPBearerChallenge.Build(const ResourceMetadataUrl: string; const Challenge: TMCPAuthChallenge): string;
begin
  var Parameters: TArray<string> := nil;
  if ResourceMetadataUrl <> '' then
    Parameters := Parameters + ['resource_metadata=' + Quote(ResourceMetadataUrl)];
  if Challenge.Error <> '' then
    Parameters := Parameters + ['error=' + Quote(Challenge.Error)];
  if Challenge.ErrorDescription <> '' then
    Parameters := Parameters + ['error_description=' + Quote(Challenge.ErrorDescription)];
  if Challenge.Scope <> '' then
    Parameters := Parameters + ['scope=' + Quote(Challenge.Scope)];

  Result := SCHEME;
  if Length(Parameters) > 0 then
    Result := Result + ' ' + string.Join(', ', Parameters);
end;

{ TMCPProtectedResourceMetadata }

class function TMCPProtectedResourceMetadata.WithoutOfflineAccess(const Scopes: TArray<string>): TArray<string>;
begin
  Result := nil;
  for var Scope in Scopes do
  begin
    if Scope = SCOPE_OFFLINE_ACCESS then
      TLogger.Warning('offline_access is not advertised: refresh tokens are not a resource requirement')
    else if Scope <> '' then
      Result := Result + [Scope];
  end;
end;

class function TMCPProtectedResourceMetadata.Build(const ResourceUri, ResourceName: string;
  const AuthorizationServers, ScopesSupported: TArray<string>): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('resource', ResourceUri);
  var Servers := TJSONArray.Create;
  Result.AddPair('authorization_servers', Servers);
  for var Server in AuthorizationServers do
  begin
    Servers.Add(Server);
  end;
  var Scopes := WithoutOfflineAccess(ScopesSupported);
  if Length(Scopes) > 0 then
  begin
    var ScopesArray := TJSONArray.Create;
    Result.AddPair('scopes_supported', ScopesArray);
    for var Scope in Scopes do
    begin
      ScopesArray.Add(Scope);
    end;
  end;
  var Methods := TJSONArray.Create;
  Methods.Add('header');
  Result.AddPair('bearer_methods_supported', Methods);
  if ResourceName <> '' then
    Result.AddPair('resource_name', ResourceName);
end;

{ TMCPStaticBearerAuthorizer }

constructor TMCPStaticBearerAuthorizer.Create(const Tokens: TArray<string>; const Scopes: TArray<string>);
begin
  inherited Create;
  for var Token in Tokens do
  begin
    if Token.Trim <> '' then
      FTokens := FTokens + [TEncoding.UTF8.GetBytes(Token.Trim)];
  end;
  if Length(FTokens) = 0 then
    raise EMCPAuthorizationConfiguration.Create('A static bearer authorizer needs at least one token');
  FScopes := Scopes;
  if Length(FScopes) = 0 then
    FScopes := [SCOPE_ANY];
end;

class function TMCPStaticBearerAuthorizer.SameToken(const Presented, Expected: TBytes): Boolean;
begin
  Result := TMCPConstantTime.SameBytes(Presented, Expected);
end;

function TMCPStaticBearerAuthorizer.Authorize(const BearerToken, HttpMethod, Path: string;
  out Principal: TMCPPrincipal; out Challenge: TMCPAuthChallenge): TMCPAuthDecision;
begin
  Principal := TMCPPrincipal.None;
  Challenge := TMCPAuthChallenge.None;
  var Presented := TEncoding.UTF8.GetBytes(BearerToken);
  var Matched: Integer := -1;
  for var I := 0 to High(FTokens) do
  begin
    if SameToken(Presented, FTokens[I]) then
      Matched := Integer(I);
  end;

  if Matched < 0 then
  begin
    Challenge := TMCPAuthChallenge.InvalidToken('The bearer token is not recognised');
    Exit(TMCPAuthDecision.Unauthorized);
  end;
  Principal.Subject := Format(STATIC_SUBJECT_FORMAT, [Matched + 1]);
  Principal.Scopes := FScopes;
  Result := TMCPAuthDecision.Allow;
end;

{ TMCPOAuthResourceServerAuthorizer }

constructor TMCPOAuthResourceServerAuthorizer.Create(const ExpectedAudience: string);
begin
  inherited Create;
  if ExpectedAudience.Trim = '' then
    raise EMCPAuthorizationConfiguration.Create('An OAuth resource server authorizer needs the expected audience');
  FExpectedAudience := ExpectedAudience.Trim;
end;

function TMCPOAuthResourceServerAuthorizer.AudienceMatches(const Claims: TJSONObject): Boolean;
begin
  var Audience := Claims.GetValue(CLAIM_AUDIENCE);
  if IsJsonString(Audience) then
    Exit(SameText(TJSONString(Audience).Value, FExpectedAudience));
  if Audience is TJSONArray then
  begin
    for var Item in TJSONArray(Audience) do
    begin
      if IsJsonString(Item) and SameText(TJSONString(Item).Value, FExpectedAudience) then
        Exit(True);
    end;
  end;
  Result := False;
end;

function TMCPOAuthResourceServerAuthorizer.IsExpired(const Claims: TJSONObject): Boolean;
begin
  var Expiry := Claims.GetValue(CLAIM_EXPIRY);
  if not (Expiry is TJSONNumber) then
    Exit(True);
  Result := TJSONNumber(Expiry).AsInt64 <= DateTimeToUnix(Now, False);
end;

function TMCPOAuthResourceServerAuthorizer.ScopesOf(const Claims: TJSONObject): TArray<string>;
begin
  Result := nil;
  var Scope := Claims.GetValue(CLAIM_SCOPE);
  if IsJsonString(Scope) then
    Exit(TJSONString(Scope).Value.Split([SCOPE_SEPARATOR], TStringSplitOptions.ExcludeEmpty));

  var ScopeArray := Claims.GetValue(CLAIM_SCOPE_ARRAY);
  if ScopeArray is TJSONArray then
  begin
    for var Item in TJSONArray(ScopeArray) do
    begin
      if IsJsonString(Item) then
        Result := Result + [TJSONString(Item).Value];
    end;
  end;
end;

function TMCPOAuthResourceServerAuthorizer.Authorize(const BearerToken, HttpMethod, Path: string;
  out Principal: TMCPPrincipal; out Challenge: TMCPAuthChallenge): TMCPAuthDecision;
var
  Claims: TJSONObject;
begin
  Principal := TMCPPrincipal.None;
  Challenge := TMCPAuthChallenge.None;
  if not ValidateToken(BearerToken, Claims) then
  begin
    Challenge := TMCPAuthChallenge.InvalidToken('The access token is not valid');
    Exit(TMCPAuthDecision.Unauthorized);
  end;

  try
    if not AudienceMatches(Claims) then
    begin
      Challenge := TMCPAuthChallenge.InvalidToken('The access token was not issued for this server');
      Exit(TMCPAuthDecision.Unauthorized);
    end;
    if IsExpired(Claims) then
    begin
      Challenge := TMCPAuthChallenge.InvalidToken('The access token has expired');
      Exit(TMCPAuthDecision.Unauthorized);
    end;

    Principal.Subject := Claims.GetValue<string>(CLAIM_SUBJECT, '');
    Principal.Scopes := ScopesOf(Claims);
    for var Required in FRequiredScopes do
    begin
      if not Principal.HasScope(Required) then
      begin
        Challenge := TMCPAuthChallenge.InsufficientScope(string.Join(SCOPE_SEPARATOR, FRequiredScopes));
        Exit(TMCPAuthDecision.Forbidden);
      end;
    end;
    Result := TMCPAuthDecision.Allow;
  finally
    Claims.Free;
  end;
end;

{ TMCPIntrospectionAuthorizer }

constructor TMCPIntrospectionAuthorizer.Create(const ExpectedAudience, IntrospectionUrl, ClientId, ClientSecret: string);
begin
  inherited Create(ExpectedAudience);
  if IntrospectionUrl.Trim = '' then
    raise EMCPAuthorizationConfiguration.Create('An introspection authorizer needs the introspection endpoint URL');
  FIntrospectionUrl := IntrospectionUrl.Trim;
  FClientId := ClientId;
  FClientSecret := ClientSecret;
  FTimeoutMs := DEFAULT_TIMEOUT_MS;
end;

function TMCPIntrospectionAuthorizer.ValidateToken(const Token: string; out Claims: TJSONObject): Boolean;
begin
  Claims := nil;
  var Client := THTTPClient.Create;
  var Form := TStringStream.Create('token=' + TNetEncoding.URL.EncodeForm(Token), TEncoding.UTF8);
  try
    Client.ConnectionTimeout := FTimeoutMs;
    Client.ResponseTimeout := FTimeoutMs;
    Client.ContentType := MEDIA_TYPE_FORM;
    var Headers: TArray<TNetHeader> := [TNetHeader.Create('Accept', 'application/json')];
    if FClientId <> '' then
      Headers := Headers + [TNetHeader.Create('Authorization', 'Basic ' + TNetEncoding.Base64.Encode(FClientId + ':' + FClientSecret))];

    var Response := Client.Post(FIntrospectionUrl, Form, nil, Headers);
    if Response.StatusCode <> 200 then
    begin
      TLogger.Warning(Format('Token introspection answered HTTP %d', [Response.StatusCode]));
      Exit(False);
    end;

    var Parsed := TJSONObject.ParseJSONValue(Response.ContentAsString(TEncoding.UTF8));
    if not (Parsed is TJSONObject) then
    begin
      Parsed.Free;
      Exit(False);
    end;
    if not (TJSONObject(Parsed).GetValue(CLAIM_ACTIVE) is TJSONTrue) then
    begin
      Parsed.Free;
      Exit(False);
    end;
    Claims := TJSONObject(Parsed);
    Result := True;
  finally
    Form.Free;
    Client.Free;
  end;
end;

end.
