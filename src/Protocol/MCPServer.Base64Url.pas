unit MCPServer.Base64Url;

interface

uses
  System.SysUtils;

type
  TMCPBase64Url = record
    class function Encode(const Bytes: TBytes): string; static;
    class function TryDecode(const Text: string; out Bytes: TBytes): Boolean; static;
  end;

implementation

uses
  System.NetEncoding;

{ TMCPBase64Url }

class function TMCPBase64Url.Encode(const Bytes: TBytes): string;
begin
  const Encoding = TBase64Encoding.Create(0);
  try
    Result := Encoding.EncodeBytesToString(Bytes).Replace('+', '-').Replace('/', '_').TrimRight(['=']);
  finally
    Encoding.Free;
  end;
end;

class function TMCPBase64Url.TryDecode(const Text: string; out Bytes: TBytes): Boolean;
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

end.
