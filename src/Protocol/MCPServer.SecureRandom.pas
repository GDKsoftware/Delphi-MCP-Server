unit MCPServer.SecureRandom;

interface

uses
  System.SysUtils;

type
  EMCPSecureRandom = class(Exception)
  end;

  TMCPSecureRandom = record
    class function Bytes(const Count: Integer): TBytes; static;
  end;

implementation

uses
{$IFDEF MSWINDOWS}
  Winapi.Windows;
{$ELSE}
  System.Classes;
{$ENDIF}

const
  MESSAGE_NO_RANDOM_BYTES = 'The operating system did not provide %d random bytes';

{$IFDEF MSWINDOWS}
const
  BCRYPT_USE_SYSTEM_PREFERRED_RNG = $00000002;
  STATUS_SUCCESS = 0;

function BCryptGenRandom(Algorithm: Pointer; Buffer: PByte; BufferLength: ULONG;
  Flags: ULONG): Integer; stdcall; external 'bcrypt.dll' name 'BCryptGenRandom';
{$ELSE}
const
  URANDOM_DEVICE = '/dev/urandom';
{$ENDIF}

{ TMCPSecureRandom }

class function TMCPSecureRandom.Bytes(const Count: Integer): TBytes;
var
  Generated: Boolean;
begin
  SetLength(Result, Count);
{$IFDEF MSWINDOWS}
  Generated := BCryptGenRandom(nil, PByte(Result), ULONG(Count), BCRYPT_USE_SYSTEM_PREFERRED_RNG) = STATUS_SUCCESS;
{$ELSE}
  const Device = TFileStream.Create(URANDOM_DEVICE, fmOpenRead or fmShareDenyNone);
  try
    Generated := Device.Read(Result[0], Count) = Count;
  finally
    Device.Free;
  end;
{$ENDIF}
  if not Generated then
    raise EMCPSecureRandom.CreateFmt(MESSAGE_NO_RANDOM_BYTES, [Count]);
end;

end.
