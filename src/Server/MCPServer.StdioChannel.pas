unit MCPServer.StdioChannel;

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  MCPServer.Types;

type
  TMCPLineStatus = (
    Ok,
    TooLong,
    InvalidUtf8
  );

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
    function ReadLine(out Line: string; out Status: TMCPLineStatus): Boolean;
  end;

  TMCPLineWriter = class(TInterfacedObject, IMCPMessageSink)
  strict private
    FStream: TStream;
    FLock: TCriticalSection;
  public
    constructor Create(Stream: TStream);
    destructor Destroy; override;
    procedure Send(const Json: string);
  end;

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
    Line := '';
    Exit(TMCPLineStatus.InvalidUtf8);
  end;
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

    if FPendingLength > FMaxLineBytes then
    begin
      FPendingLength := 0;
      var Skipped: TArray<Byte>;
      SetLength(Skipped, READ_CHUNK_BYTES);
      while True do
      begin
        var Count := Integer(FStream.Read(Skipped[0], Length(Skipped)));
        if Count <= 0 then
        begin
          FEndOfStream := True;
          Line := '';
          Status := TMCPLineStatus.TooLong;
          Exit(True);
        end;
        for var I := 0 to Count - 1 do
          if Skipped[I] = 10 then
          begin
            var Rest: Integer := Count - (I + 1);
            if Rest > 0 then
              Move(Skipped[I + 1], FPending[0], Rest);
            FPendingLength := Rest;
            Line := '';
            Status := TMCPLineStatus.TooLong;
            Exit(True);
          end;
      end;
    end;

    if FEndOfStream or not Fill then
    begin
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
