unit MCPServer.RequestState;

interface

uses
  System.SysUtils,
  System.JSON;

type
  TMCPRequestStateSealer = class
  public
    const DEFAULT_TTL_SECONDS = 600;
    const TOKEN_VERSION = 1;
  strict private
    FKey: TBytes;
    FTtlSeconds: Integer;
    FKeyIsEphemeral: Boolean;
    function Signature(const Payload: TBytes): TBytes;
    class function QuotedName(const Value: string): string; static;
    class function CanonicalJson(const Value: TJSONValue): string; static;
    class function TryDecodeBase64Url(const Text: string; out Bytes: TBytes): Boolean; static;
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
  System.Hash,
  System.DateUtils,
  System.Generics.Collections,
  System.Generics.Defaults,
  MCPServer.Types,
  MCPServer.Errors,
  MCPServer.Logger,
  MCPServer.SecureRandom,
  System.NetEncoding;

const
  MESSAGE_INTEGRITY_FAILED = 'requestState failed integrity verification';


const
  KEY_BYTES = 32;
  TOKEN_SEPARATOR = '.';
  PAYLOAD_VERSION = 'v';
  PAYLOAD_METHOD = 'm';
  PAYLOAD_DIGEST = 'a';
  PAYLOAD_EXPIRY = 'exp';
  PAYLOAD_PRINCIPAL = 'p';
  PAYLOAD_STATE = 's';
  EXCLUDED_MEMBERS: array[0..2] of string = ('_meta', 'inputResponses', 'requestState');

{ TMCPRequestStateSealer }

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
    FKey := TMCPSecureRandom.Bytes(KEY_BYTES);
    FKeyIsEphemeral := True;
    TLogger.Warning('[Security] RequestStateKey is not set: requestState tokens are sealed with a random key ' +
      'and stop verifying after a restart or on another instance');
  end;
end;

function TMCPRequestStateSealer.Signature(const Payload: TBytes): TBytes;
begin
  Result := THashSHA2.GetHMACAsBytes(Payload, FKey, THashSHA2.TSHA2Version.SHA256);
end;

class function TMCPRequestStateSealer.TryDecodeBase64Url(const Text: string; out Bytes: TBytes): Boolean;
begin
  Bytes := nil;
  const TextIsEmpty = (Text = '');
  if TextIsEmpty then
    Exit(False);

  for var C in Text do
  begin
    const IsUrlSafe = CharInSet(C, ['A'..'Z', 'a'..'z', '0'..'9', '-', '_']);
    if not IsUrlSafe then
      Exit(False);
  end;

  Bytes := TNetEncoding.Base64URL.DecodeStringToBytes(Text);
  Result := (Length(Bytes) > 0);
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
    const EncodedPayload = TNetEncoding.Base64URL.EncodeBytesToString(PayloadBytes);
    const EncodedSignature = TNetEncoding.Base64URL.EncodeBytesToString(Signature(PayloadBytes));
    Result := EncodedPayload + TOKEN_SEPARATOR + EncodedSignature;
  finally
    Payload.Free;
  end;
end;

function TMCPRequestStateSealer.Open(const Token, Method, ArgumentDigest, Principal: string): TJSONObject;
var
  PayloadBytes, SignatureBytes: TBytes;
begin
  var Separator := Token.LastIndexOf(TOKEN_SEPARATOR);
  if (Separator <= 0) or not TryDecodeBase64Url(Token.Substring(0, Separator), PayloadBytes) or
    not TryDecodeBase64Url(Token.Substring(Separator + 1), SignatureBytes) or
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
