unit MCPServer.StdioChannel;

/// The byte-level side of the stdio transport: one UTF-8 encoded JSON-RPC
/// message per line, LF-delimited, no BOM, and the standard handles as
/// streams. Text I/O is deliberately not used: it decodes stdin with the
/// console code page on Windows and would alter every non-ASCII character.

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  MCPServer.Types;

type
  TMCPLineStatus = (
    /// A complete line was decoded.
    Ok,
    /// The line exceeded the limit; it was skipped up to its newline.
    TooLong,
    /// The bytes were not valid UTF-8; the line was skipped.
    InvalidUtf8
  );

  /// Reads LF-delimited UTF-8 lines from a byte stream. A trailing CR is
  /// dropped, a leading byte-order mark is ignored, the last line needs no
  /// newline.
  TMCPLineReader = class
  strict private
    const READ_CHUNK_BYTES = 64 * 1024;
  strict private
    FStream: TStream;
    FMaxLineBytes: Integer;
    FPending: TBytes;
    FPendingLength: Integer;
    FAtStart: Boolean;
    FEndOfStream: Boolean;
    function Fill: Boolean;
    function DecodeLine(Start, Count: Integer; out Line: string): TMCPLineStatus;
  public
    constructor Create(Stream: TStream; MaxLineBytes: Integer);
    /// False at the end of the stream. Status says whether Line is usable.
    function ReadLine(out Line: string; out Status: TMCPLineStatus): Boolean;
  end;

  /// Writes one message per line, UTF-8 with a bare LF, and serialises
  /// concurrent writers so lines never interleave. Any newline inside a
  /// message is replaced by a space: the framing does not allow it.
  TMCPLineWriter = class(TInterfacedObject, IMCPMessageSink)
  strict private
    FStream: TStream;
    FLock: TCriticalSection;
  public
    constructor Create(Stream: TStream);
    destructor Destroy; override;
    procedure Send(const Json: string);
  end;

/// Streams over the process's standard input and output handles.
function StandardInputStream: TStream;
function StandardOutputStream: TStream;

implementation

uses
{$IFDEF MSWINDOWS}
  Winapi.Windows,
{$ENDIF}
{$IFDEF POSIX}
  Posix.Unistd,
{$ENDIF}
  System.Math;

function StandardInputStream: TStream;
begin
{$IFDEF MSWINDOWS}
  Result := THandleStream.Create(GetStdHandle(STD_INPUT_HANDLE));
{$ELSE}
  Result := THandleStream.Create(STDIN_FILENO);
{$ENDIF}
end;

function StandardOutputStream: TStream;
begin
{$IFDEF MSWINDOWS}
  Result := THandleStream.Create(GetStdHandle(STD_OUTPUT_HANDLE));
{$ELSE}
  Result := THandleStream.Create(STDOUT_FILENO);
{$ENDIF}
end;

{ TMCPLineReader }

constructor TMCPLineReader.Create(Stream: TStream; MaxLineBytes: Integer);
begin
  inherited Create;
  FStream := Stream;
  FMaxLineBytes := MaxLineBytes;
  FAtStart := True;
  SetLength(FPending, READ_CHUNK_BYTES);
end;

function TMCPLineReader.Fill: Boolean;
begin
  // Grow the buffer when a line is longer than a chunk, then append a chunk.
  if Length(FPending) - FPendingLength < READ_CHUNK_BYTES then
    SetLength(FPending, Length(FPending) + READ_CHUNK_BYTES);

  var BytesRead := FStream.Read(FPending[FPendingLength], READ_CHUNK_BYTES);
  if BytesRead <= 0 then
  begin
    FEndOfStream := True;
    Exit(False);
  end;

  if FAtStart then
  begin
    FAtStart := False;
    if (BytesRead >= 3) and (FPending[0] = $EF) and (FPending[1] = $BB) and (FPending[2] = $BF) then
    begin
      Move(FPending[3], FPending[0], BytesRead - 3);
      Dec(BytesRead, 3);
    end;
  end;

  Inc(FPendingLength, BytesRead);
  Result := True;
end;

function TMCPLineReader.DecodeLine(Start, Count: Integer; out Line: string): TMCPLineStatus;
begin
  if (Count > 0) and (FPending[Start + Count - 1] = 13) then
    Dec(Count);

  if Count > FMaxLineBytes then
  begin
    Line := '';
    Exit(TMCPLineStatus.TooLong);
  end;

  try
    Line := TEncoding.UTF8.GetString(FPending, Start, Count);
  except
    // Some malformed sequences raise instead of decoding leniently.
    Line := '';
    Exit(TMCPLineStatus.InvalidUtf8);
  end;
  // The RTL decoder answers an empty string for other malformed input.
  if (Line = '') and (Count > 0) then
    Exit(TMCPLineStatus.InvalidUtf8);
  Result := TMCPLineStatus.Ok;
end;

function TMCPLineReader.ReadLine(out Line: string; out Status: TMCPLineStatus): Boolean;
begin
  Line := '';
  Status := TMCPLineStatus.Ok;
  var ScanFrom := 0;

  while True do
  begin
    for var I := ScanFrom to FPendingLength - 1 do
      if FPending[I] = 10 then
      begin
        Status := DecodeLine(0, I, Line);
        var Remaining := FPendingLength - (I + 1);
        if Remaining > 0 then
          Move(FPending[I + 1], FPending[0], Remaining);
        FPendingLength := Remaining;
        Exit(True);
      end;
    ScanFrom := FPendingLength;

    if FEndOfStream or not Fill then
    begin
      // The final line may end without a newline.
      if FPendingLength = 0 then
        Exit(False);
      Status := DecodeLine(0, FPendingLength, Line);
      FPendingLength := 0;
      Exit(True);
    end;
  end;
end;

{ TMCPLineWriter }

constructor TMCPLineWriter.Create(Stream: TStream);
begin
  inherited Create;
  FStream := Stream;
  FLock := TCriticalSection.Create;
end;

destructor TMCPLineWriter.Destroy;
begin
  FLock.Free;
  inherited;
end;

procedure TMCPLineWriter.Send(const Json: string);
begin
  var Line := Json.Replace(#13, ' ').Replace(#10, ' ') + #10;
  var Bytes := TEncoding.UTF8.GetBytes(Line);
  FLock.Enter;
  try
    FStream.WriteBuffer(Bytes, Length(Bytes));
  finally
    FLock.Leave;
  end;
end;

end.
