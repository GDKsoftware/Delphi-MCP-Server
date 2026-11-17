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
    type
      TMember = record
        Name: string;
        Position: Integer;
        Value: TJSONValue;
      end;
  strict private
    FKey: TBytes;
    FTtlSeconds: Integer;
    FKeyIsEphemeral: Boolean;
    function Signature(const Payload: TBytes): TBytes;
    class function QuotedName(const Value: string): string; static;
    class function CanonicalJson(const Value: TJSONValue): string; static;
    class function CanonicalObject(const Source: TJSONObject): string; static;
    class function MembersByName(const Source: TJSONObject): TArray<TMember>; static;
    class function CanonicalArray(const Source: TJSONArray): string; static;
    class function TryDecodeBase64Url(const Text: string; out Bytes: TBytes): Boolean; static;
  public
    constructor Create(const Key: string; TtlSeconds: Integer = DEFAULT_TTL_SECONDS);

    function Seal(const State: TJSONObject; const Method, ArgumentDigest, Principal: string): string;
    function Open(const Token, Method, ArgumentDigest, Principal: string): TJSONObject; overload;
    function Open(const Token, Method: string; const ArgumentDigest: TFunc<string>;
      const Principal: string): TJSONObject; overload;

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
    Result := CanonicalObject(TJSONObject(Value))
  else if Value is TJSONArray then
    Result := CanonicalArray(TJSONArray(Value))
  else if Assigned(Value) then
    Result := Value.ToJSON
  else
    Result := 'null';
end;

class function TMCPRequestStateSealer.CanonicalObject(const Source: TJSONObject): string;
begin
  const Members = MembersByName(Source);

  const Parts = TStringBuilder.Create;
  try
    Parts.Append('{');
    var FirstValueOfName: TJSONValue := nil;
    for var Index := 0 to High(Members) do
    begin
      const IsFirstMember = (Index = 0);
      const RepeatsName = ((not IsFirstMember) and (Members[Index].Name = Members[Index - 1].Name));
      if not RepeatsName then
        FirstValueOfName := Members[Index].Value;

      const Name = QuotedName(Members[Index].Name);
      const Value = CanonicalJson(FirstValueOfName);
      if not IsFirstMember then
        Parts.Append(',');
      Parts.Append(Name);
      Parts.Append(':');
      Parts.Append(Value);
    end;
    Parts.Append('}');
    Result := Parts.ToString;
  finally
    Parts.Free;
  end;
end;

class function TMCPRequestStateSealer.MembersByName(const Source: TJSONObject): TArray<TMember>;
begin
  SetLength(Result, Source.Count);
  for var Position := 0 to Source.Count - 1 do
  begin
    const Pair = Source.Pairs[Position];
    Result[Position].Name     := Pair.JsonString.Value;
    Result[Position].Position := Position;
    Result[Position].Value    := Pair.JsonValue;
  end;

  const ByNameThenPosition = TComparer<TMember>.Construct(
    function(const Left, Right: TMember): Integer
    begin
      Result := CompareStr(Left.Name, Right.Name);
      const HasSameName = (Result = 0);
      if HasSameName then
        Result := Left.Position - Right.Position;
    end);
  TArray.Sort<TMember>(Result, ByNameThenPosition);
end;

class function TMCPRequestStateSealer.CanonicalArray(const Source: TJSONArray): string;
begin
  const Parts = TStringBuilder.Create;
  try
    Parts.Append('[');
    for var Index := 0 to Source.Count - 1 do
    begin
      const IsFirstItem = (Index = 0);
      const Item = CanonicalJson(Source.Items[Index]);
      if not IsFirstItem then
        Parts.Append(',');
      Parts.Append(Item);
    end;
    Parts.Append(']');
    Result := Parts.ToString;
  finally
    Parts.Free;
  end;
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
begin
  const KnownDigest: TFunc<string> =
    function: string
    begin
      Result := ArgumentDigest;
    end;
  Result := Open(Token, Method, KnownDigest, Principal);
end;

function TMCPRequestStateSealer.Open(const Token, Method: string; const ArgumentDigest: TFunc<string>;
  const Principal: string): TJSONObject;
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
    const SealedDigest = Payload.GetValue<string>(PAYLOAD_DIGEST, '');
    const IsSameRequest = (SealedDigest = ArgumentDigest());
    if not IsSameRequest then
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
