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
    class function Base64Url(const Bytes: TBytes): string; static;
    class function TryFromBase64Url(const Text: string; out Bytes: TBytes): Boolean; static;
    class function SameBytes(const A, B: TBytes): Boolean; static;
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
  System.Classes,
  System.Hash,
  System.DateUtils,
  System.NetEncoding,
  System.Generics.Collections,
  System.Generics.Defaults,
  MCPServer.Errors,
  MCPServer.Logger;

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

constructor TMCPRequestStateSealer.Create(const Key: string; TtlSeconds: Integer);
begin
  inherited Create;
  FTtlSeconds := TtlSeconds;
  if Key.Trim <> '' then
    FKey := TEncoding.UTF8.GetBytes(Key)
  else
  begin
    SetLength(FKey, KEY_BYTES);
    Randomize;
    for var I := 0 to High(FKey) do
      FKey[I] := Byte(Random(256));
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
  if Text = '' then
    Exit(False);
  for var C in Text do
    if not (CharInSet(C, ['A'..'Z', 'a'..'z', '0'..'9', '-', '_'])) then
      Exit(False);

  var Standard := Text.Replace('-', '+').Replace('_', '/');
  while Length(Standard) mod 4 <> 0 do
    Standard := Standard + '=';
  try
    Bytes := TNetEncoding.Base64.DecodeStringToBytes(Standard);
    Result := Length(Bytes) > 0;
  except
    Result := False;
  end;
end;

class function TMCPRequestStateSealer.SameBytes(const A, B: TBytes): Boolean;
begin
  var Difference := Length(A) xor Length(B);
  var Longest := Length(A);
  if Length(B) > Longest then
    Longest := Length(B);
  for var I := 0 to Longest - 1 do
  begin
    var Left := 0;
    var Right := 0;
    if I < Length(A) then
      Left := A[I];
    if I < Length(B) then
      Right := B[I];
    Difference := Difference or (Left xor Right);
  end;
  Result := Difference = 0;
end;

class function TMCPRequestStateSealer.CanonicalJson(const Value: TJSONValue): string;
begin
  if Value is TJSONObject then
  begin
    var Names := TList<string>.Create;
    try
      for var Pair in TJSONObject(Value) do
        Names.Add(Pair.JsonString.Value);
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
          Parts.Append(TJSONString.Create(Names[I]).ToJSON).Append(':')
            .Append(CanonicalJson(TJSONObject(Value).GetValue(Names[I])));
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
  if (Separator <= 0) or not TryFromBase64Url(Token.Substring(0, Separator), PayloadBytes)
    or not TryFromBase64Url(Token.Substring(Separator + 1), SignatureBytes)
    or not SameBytes(SignatureBytes, Signature(PayloadBytes)) then
    raise EMCPError.InvalidParams('requestState failed integrity verification');

  var Payload := TJSONObject.ParseJSONValue(TEncoding.UTF8.GetString(PayloadBytes)) as TJSONObject;
  if not Assigned(Payload) then
    raise EMCPError.InvalidParams('requestState failed integrity verification');
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
