unit MCPServer.HttpHeaders;

interface

uses
  System.SysUtils;

type
  TMCPHeaderValue = record
    const SENTINEL_PREFIX = '=?base64?';
    const SENTINEL_SUFFIX = '?=';

    class function IsHeaderSafe(const Value: string): Boolean; static;
    class function IsSentinel(const Value: string): Boolean; static;
    class function TryDecodeBase64(const Text: string; out Bytes: TBytes): Boolean; static;
    class function TryDecode(const Value: string; out Decoded: string): Boolean; static;
  end;

  TMCPAcceptHeader = record
    class function Accepts(const AcceptHeader, MediaType: string): Boolean; static;
  end;

  TMCPOriginParts = record
    Scheme: string;
    Host: string;
    Port: string;
    class function Parse(const Origin: string): TMCPOriginParts; static;
    function DefaultPort: string;
  end;

  TMCPOriginPolicy = record
    const ALLOW_ALL = '*';

    class function IsLoopback(const Origin: string): Boolean; static;
    class function IsAllowed(const Origin: string; const AllowList: TArray<string>): Boolean; static;
    class function Matches(const Origin, Pattern: string): Boolean; static;
  end;

  TMCPHostPolicy = record
    class function IsAllowed(const HostHeader: string; const AllowList: TArray<string>): Boolean; static;
    class function Matches(const HostHeader, Pattern: string): Boolean; static;
  end;

  TMCPJsonLimits = record
    class function NestingDepth(const Json: string): Integer; static;
  end;

implementation

uses
  System.NetEncoding;

{ TMCPHeaderValue }

class function TMCPHeaderValue.IsHeaderSafe(const Value: string): Boolean;
begin
  for var C in Value do
    if not ((C = #9) or ((C >= #$20) and (C <= #$7E))) then
      Exit(False);
  Result := True;
end;

class function TMCPHeaderValue.IsSentinel(const Value: string): Boolean;
begin
  Result := (Length(Value) >= Length(SENTINEL_PREFIX) + Length(SENTINEL_SUFFIX))
    and Value.StartsWith(SENTINEL_PREFIX, False) and Value.EndsWith(SENTINEL_SUFFIX, False);
end;

class function TMCPHeaderValue.TryDecodeBase64(const Text: string; out Bytes: TBytes): Boolean;
begin
  Bytes := nil;
  if (Text = '') or (Length(Text) mod 4 <> 0) then
    Exit(False);

  var Padding := 0;
  for var I := 1 to Length(Text) do
  begin
    var C := Text[I];
    if C = '=' then
    begin
      Inc(Padding);
      if (Padding > 2) or (I < Length(Text) - 1) then
        Exit(False);
    end
    else if Padding > 0 then
      Exit(False)
    else if not (CharInSet(C, ['A'..'Z', 'a'..'z', '0'..'9', '+', '/'])) then
      Exit(False);
  end;

  Bytes := TNetEncoding.Base64.DecodeStringToBytes(Text);
  Result := True;
end;

class function TMCPHeaderValue.TryDecode(const Value: string; out Decoded: string): Boolean;
var
  Bytes: TBytes;
begin
  Decoded := '';
  if not IsHeaderSafe(Value) then
    Exit(False);

  if not IsSentinel(Value) then
  begin
    Decoded := Value;
    Exit(True);
  end;

  var Payload := Value.Substring(Length(SENTINEL_PREFIX), Length(Value) - Length(SENTINEL_PREFIX) - Length(SENTINEL_SUFFIX));
  if not TryDecodeBase64(Payload, Bytes) then
    Exit(False);

  Decoded := TEncoding.UTF8.GetString(Bytes);
  Result := True;
end;

{ TMCPAcceptHeader }

class function TMCPAcceptHeader.Accepts(const AcceptHeader, MediaType: string): Boolean;
begin
  for var Entry in AcceptHeader.Split([',']) do
  begin
    var Media := Entry;
    var ParameterStart := Media.IndexOf(';');
    if ParameterStart >= 0 then
      Media := Media.Substring(0, ParameterStart);
    if SameText(Media.Trim, MediaType) then
      Exit(True);
  end;
  Result := False;
end;

{ TMCPOriginPolicy }

{ TMCPOriginParts }

class function TMCPOriginParts.Parse(const Origin: string): TMCPOriginParts;
begin
  Result := Default(TMCPOriginParts);
  var Rest := Origin.Trim;
  var SchemeEnd := Rest.IndexOf('://');
  if SchemeEnd < 0 then
    Exit;
  Result.Scheme := Rest.Substring(0, SchemeEnd).ToLower;
  Rest := Rest.Substring(SchemeEnd + 3);

  var PortStart: Integer;
  if Rest.StartsWith('[') then
  begin
    var BracketEnd := Rest.IndexOf(']');
    if BracketEnd < 0 then
      Exit;
    Result.Host := Rest.Substring(0, BracketEnd + 1).ToLower;
    PortStart := Rest.IndexOf(':', BracketEnd);
  end
  else
  begin
    PortStart := Rest.IndexOf(':');
    if PortStart >= 0 then
      Result.Host := Rest.Substring(0, PortStart).ToLower
    else
      Result.Host := Rest.ToLower;
  end;

  if PortStart >= 0 then
    Result.Port := Rest.Substring(PortStart + 1);
end;

function TMCPOriginParts.DefaultPort: string;
begin
  if Scheme = 'https' then
    Result := '443'
  else if Scheme = 'http' then
    Result := '80'
  else
    Result := '';
end;

class function TMCPOriginPolicy.IsLoopback(const Origin: string): Boolean;
begin
  const Parts = TMCPOriginParts.Parse(Origin);
  const IsHttp = ((Parts.Scheme = 'http') or (Parts.Scheme = 'https'));
  const IsLocal = ((Parts.Host = 'localhost') or (Parts.Host = '127.0.0.1') or (Parts.Host = '[::1]'));
  Result := IsHttp and IsLocal;
end;

class function TMCPOriginPolicy.Matches(const Origin, Pattern: string): Boolean;
begin
  if Pattern.Trim = ALLOW_ALL then
    Exit(True);

  var Wanted := TMCPOriginParts.Parse(Origin);
  var Allowed := TMCPOriginParts.Parse(Pattern);
  const IsParsed = ((Wanted.Scheme <> '') and (Allowed.Scheme <> ''));
  if not IsParsed then
    Exit(False);

  if Wanted.Port = '' then
    Wanted.Port := Wanted.DefaultPort;
  if Allowed.Port = '' then
    Allowed.Port := Allowed.DefaultPort;

  const SameHost = ((Wanted.Scheme = Allowed.Scheme) and (Wanted.Host = Allowed.Host));
  const SamePort = ((Allowed.Port = '*') or (Wanted.Port = Allowed.Port));
  Result := SameHost and SamePort;
end;

class function TMCPOriginPolicy.IsAllowed(const Origin: string; const AllowList: TArray<string>): Boolean;
begin
  var Value := Origin.Trim;
  if Value = '' then
    Exit(True);
  if SameText(Value, 'null') then
    Exit(False);
  if IsLoopback(Value) then
    Exit(True);

  for var Pattern in AllowList do
    if Matches(Value, Pattern) then
      Exit(True);
  Result := False;
end;

{ TMCPHostPolicy }

class function TMCPHostPolicy.Matches(const HostHeader, Pattern: string): Boolean;
begin
  if Pattern.Trim = TMCPOriginPolicy.ALLOW_ALL then
    Exit(True);

  const Wanted = TMCPOriginParts.Parse(Format('http://%s', [HostHeader.Trim]));
  const Allowed = TMCPOriginParts.Parse(Format('http://%s', [Pattern.Trim]));
  const SameHost = ((Wanted.Host <> '') and (Allowed.Host <> '') and (Wanted.Host = Allowed.Host));
  if not SameHost then
    Exit(False);
  Result := (Allowed.Port = '') or (Allowed.Port = '*') or (Allowed.Port = Wanted.Port);
end;

class function TMCPHostPolicy.IsAllowed(const HostHeader: string; const AllowList: TArray<string>): Boolean;
begin
  if Length(AllowList) = 0 then
    Exit(True);
  for var Pattern in AllowList do
  begin
    if Matches(HostHeader, Pattern) then
      Exit(True);
  end;
  Result := False;
end;

{ TMCPJsonLimits }

class function TMCPJsonLimits.NestingDepth(const Json: string): Integer;
begin
  Result := 0;
  var Depth := 0;
  var InString := False;
  var Escaped := False;

  for var C in Json do
  begin
    if InString then
    begin
      if Escaped then
        Escaped := False
      else if C = '\' then
        Escaped := True
      else if C = '"' then
        InString := False;
      Continue;
    end;

    case C of
      '"':
        InString := True;
      '{', '[':
        begin
          Inc(Depth);
          if Depth > Result then
            Result := Depth;
        end;
      '}', ']':
        if Depth > 0 then
          Dec(Depth);
    end;
  end;
end;

end.
