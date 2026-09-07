unit MCPServer.RequestState;

interface

uses
  System.SysUtils,
  System.JSON;

type
  EMCPRequestStateKey = class(Exception)
  end;

  TMCPRequestStateSealer = class
  public
    const DEFAULT_TTL_SECONDS = 600;
    const TOKEN_VERSION = 1;
  strict private
    FKey: TBytes;
    FTtlSeconds: Integer;
    FKeyIsEphemeral: Boolean;
    function Signature(const Payload: TBytes): TBytes;
    class function NewRandomKey: TBytes; static;
    class function QuotedName(const Value: string): string; static;
    class function Base64Url(const Bytes: TBytes): string; static;
    class function TryFromBase64Url(const Text: string; out Bytes: TBytes): Boolean; static;
    class function CanonicalJson(const Value: TJSONValue): string; static;
  public
    constructor Create(const Key: string; TtlSeconds: Integer = DEFAULT_TTL_SECONDS);

    function Seal(const State: TJSONObject; const Method, ArgumentDigest, Principal: string): string;
    function Open(const Token, Method, ArgumentDigest, Principal: string): TJSONObject;

    class function DigestOf(const Params: TJSONObject): string; static;

    property KeyIsEphemeral: Boolean read FKeyIsEphemeral;
    property TtlSeconds: Integer read FTtlSeconds;
  end;

implementation

uses
{$IFDEF MSWINDOWS}
  Winapi.Windows,
{$ENDIF}
  System.Classes,
  System.Hash,
  System.DateUtils,
  System.NetEncoding,
  System.Generics.Collections,
  System.Generics.Defaults,
  MCPServer.Types,
  MCPServer.Errors,
  MCPServer.Logger;

const
  MESSAGE_INTEGRITY_FAILED = 'requestState failed integrity verification';


const
  KEY_BYTES = 32;
  URANDOM_DEVICE = '/dev/urandom';
  TOKEN_SEPARATOR = '.';
  PAYLOAD_VERSION = 'v';
  PAYLOAD_METHOD = 'm';
  PAYLOAD_DIGEST = 'a';
  PAYLOAD_EXPIRY = 'exp';
  PAYLOAD_PRINCIPAL = 'p';
  PAYLOAD_STATE = 's';
  EXCLUDED_MEMBERS: array[0..2] of string = ('_meta', 'inputResponses', 'requestState');

{$IFDEF MSWINDOWS}
const
  BCRYPT_USE_SYSTEM_PREFERRED_RNG = $00000002;
  STATUS_SUCCESS = 0;

function BCryptGenRandom(Algorithm: Pointer; Buffer: PByte; BufferLength: ULONG;
  Flags: ULONG): Integer; stdcall; external 'bcrypt.dll' name 'BCryptGenRandom';
{$ENDIF}

{ TMCPRequestStateSealer }

class function TMCPRequestStateSealer.NewRandomKey: TBytes;
var
  Generated: Boolean;
begin
  SetLength(Result, KEY_BYTES);
{$IFDEF MSWINDOWS}
  Generated := BCryptGenRandom(nil, PByte(Result), KEY_BYTES, BCRYPT_USE_SYSTEM_PREFERRED_RNG) = STATUS_SUCCESS;
{$ELSE}
  const Device = TFileStream.Create(URANDOM_DEVICE, fmOpenRead or fmShareDenyNone);
  try
    Generated := Device.Read(Result[0], KEY_BYTES) = KEY_BYTES;
  finally
    Device.Free;
  end;
{$ENDIF}
  if not Generated then
    raise EMCPRequestStateKey.Create('The operating system did not provide a random key for requestState');
end;

class function TMCPRequestStateSealer.QuotedName(const Value: string): string;
begin
  const Quoted = TJSONString.Create(Value);
  try
    Result := Quoted.ToJSON;
  finally
    Quoted.Free;
  end;
end;

constructor TMCPRequestStateSealer.Create(const Key: string; TtlSeconds: Integer);
begin
  inherited Create;
  FTtlSeconds := TtlSeconds;
  const HasKey = (Key.Trim <> '');
  if HasKey then
    FKey := TEncoding.UTF8.GetBytes(Key)
  else
  begin
    FKey := NewRandomKey;
    FKeyIsEphemeral := True;
    TLogger.Warning('[Security] RequestStateKey is not set: requestState tokens are sealed with a random key ' +
      'and stop verifying after a restart or on another instance');
  end;
end;

function TMCPRequestStateSealer.Signature(const Payload: TBytes): TBytes;
begin
  Result := THashSHA2.GetHMACAsBytes(Payload, FKey, THashSHA2.TSHA2Version.SHA256);
end;

class function TMCPRequestStateSealer.Base64Url(const Bytes: TBytes): string;
begin
  var Encoding := TBase64Encoding.Create(0);
  try
    Result := Encoding.EncodeBytesToString(Bytes).Replace('+', '-').Replace('/', '_').TrimRight(['=']);
  finally
    Encoding.Free;
  end;
end;

class function TMCPRequestStateSealer.TryFromBase64Url(const Text: string; out Bytes: TBytes): Boolean;
begin
  Bytes := nil;
  const TextIsEmpty = (Text = '');
  if TextIsEmpty then
    Exit(False);
  for var C in Text do
    if not (CharInSet(C, ['A'..'Z', 'a'..'z', '0'..'9', '-', '_'])) then
      Exit(False);

  var Standard := Text.Replace('-', '+').Replace('_', '/');
  while Length(Standard) mod 4 <> 0 do
  begin
    Standard := Standard + '=';
  end;
  try
    Bytes := TNetEncoding.Base64.DecodeStringToBytes(Standard);
    Result := Length(Bytes) > 0;
  except
    Result := False;
  end;
end;

class function TMCPRequestStateSealer.CanonicalJson(const Value: TJSONValue): string;
begin
  if Value is TJSONObject then
  begin
    var Names := TList<string>.Create;
    try
      for var Pair in TJSONObject(Value) do
      begin
        Names.Add(Pair.JsonString.Value);
      end;
      Names.Sort(TComparer<string>.Construct(
        function(const Left, Right: string): Integer
        begin
          Result := CompareStr(Left, Right);
        end));
      var Parts := TStringBuilder.Create;
      try
        Parts.Append('{');
        for var I := 0 to Names.Count - 1 do
        begin
          if I > 0 then
            Parts.Append(',');
          const Member = TJSONObject(Value).GetValue(Names[I]);
          Parts.Append(QuotedName(Names[I]));
          Parts.Append(':');
          Parts.Append(CanonicalJson(Member));
        end;
        Parts.Append('}');
        Result := Parts.ToString;
      finally
        Parts.Free;
      end;
    finally
      Names.Free;
    end;
  end
  else if Value is TJSONArray then
  begin
    var Parts := TStringBuilder.Create;
    try
      Parts.Append('[');
      for var I := 0 to TJSONArray(Value).Count - 1 do
      begin
        if I > 0 then
          Parts.Append(',');
        Parts.Append(CanonicalJson(TJSONArray(Value).Items[I]));
      end;
      Parts.Append(']');
      Result := Parts.ToString;
    finally
      Parts.Free;
    end;
  end
  else if Assigned(Value) then
    Result := Value.ToJSON
  else
    Result := 'null';
end;

class function TMCPRequestStateSealer.DigestOf(const Params: TJSONObject): string;
begin
  var Salient := TJSONObject.Create;
  try
    if Assigned(Params) then
      for var Pair in Params do
      begin
        var Excluded := False;
        for var Name in EXCLUDED_MEMBERS do
          if Pair.JsonString.Value = Name then
            Excluded := True;
        if not Excluded then
          Salient.AddPair(Pair.JsonString.Value, TJSONValue(Pair.JsonValue.Clone));
      end;
    Result := THashSHA2.GetHashString(CanonicalJson(Salient), THashSHA2.TSHA2Version.SHA256);
  finally
    Salient.Free;
  end;
end;

function TMCPRequestStateSealer.Seal(const State: TJSONObject; const Method, ArgumentDigest,
  Principal: string): string;
begin
  var Payload := TJSONObject.Create;
  try
    Payload.AddPair(PAYLOAD_VERSION, TJSONNumber.Create(TOKEN_VERSION));
    Payload.AddPair(PAYLOAD_METHOD, Method);
    Payload.AddPair(PAYLOAD_DIGEST, ArgumentDigest);
    Payload.AddPair(PAYLOAD_EXPIRY, TJSONNumber.Create(DateTimeToUnix(Now, False) + FTtlSeconds));
    Payload.AddPair(PAYLOAD_PRINCIPAL, Principal);
    if Assigned(State) then
      Payload.AddPair(PAYLOAD_STATE, TJSONObject(State.Clone))
    else
      Payload.AddPair(PAYLOAD_STATE, TJSONObject.Create);

    var PayloadBytes := TEncoding.UTF8.GetBytes(Payload.ToJSON);
    Result := Base64Url(PayloadBytes) + TOKEN_SEPARATOR + Base64Url(Signature(PayloadBytes));
  finally
    Payload.Free;
  end;
end;

function TMCPRequestStateSealer.Open(const Token, Method, ArgumentDigest, Principal: string): TJSONObject;
var
  PayloadBytes, SignatureBytes: TBytes;
begin
  var Separator := Token.LastIndexOf(TOKEN_SEPARATOR);
  if (Separator <= 0) or not TryFromBase64Url(Token.Substring(0, Separator), PayloadBytes) or
    not TryFromBase64Url(Token.Substring(Separator + 1), SignatureBytes) or
    not TMCPConstantTime.SameBytes(SignatureBytes, Signature(PayloadBytes)) then
    raise EMCPError.InvalidParams(MESSAGE_INTEGRITY_FAILED);

  const Parsed = TJSONObject.ParseJSONValue(TEncoding.UTF8.GetString(PayloadBytes));
  const IsPayloadObject = (Parsed is TJSONObject);
  if not IsPayloadObject then
  begin
    Parsed.Free;
    raise EMCPError.InvalidParams(MESSAGE_INTEGRITY_FAILED);
  end;

  const Payload = TJSONObject(Parsed);
  try
    if Payload.GetValue<Integer>(PAYLOAD_VERSION, 0) <> TOKEN_VERSION then
      raise EMCPError.InvalidParams('requestState has an unsupported version');
    if Payload.GetValue<string>(PAYLOAD_METHOD, '') <> Method then
      raise EMCPError.InvalidParams('requestState belongs to another method');
    if Payload.GetValue<string>(PAYLOAD_DIGEST, '') <> ArgumentDigest then
      raise EMCPError.InvalidParams('requestState belongs to another request');
    if Payload.GetValue<string>(PAYLOAD_PRINCIPAL, '') <> Principal then
      raise EMCPError.InvalidParams('requestState belongs to another principal');
    if Payload.GetValue<Int64>(PAYLOAD_EXPIRY, 0) < DateTimeToUnix(Now, False) then
      raise EMCPError.InvalidParams('requestState has expired');

    var State := Payload.GetValue(PAYLOAD_STATE);
    if State is TJSONObject then
      Result := TJSONObject(State.Clone)
    else
      Result := TJSONObject.Create;
  finally
    Payload.Free;
  end;
end;

end.
