unit MCPServer.Logger;

interface

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
  System.SyncObjs;

type
  {$SCOPEDENUMS ON}
  TLogLevel = (Debug, Info, Warning, Error);
  {$SCOPEDENUMS OFF}

  TLogMessageProc = reference to procedure(const Message: string);

  TLogger = class
  private
    class var FInstance: TLogger;
    class var FLock: TCriticalSection;

    FLogToConsole: Boolean;
    FLogToFile: Boolean;
    FLogFile: TStreamWriter;
    FLogFileName: string;
    FMinLogLevel: TLogLevel;
    FOnLogMessage: TLogMessageProc;
    FUseStdErr: Boolean;
    FStdoutReserved: Boolean;
    FStdoutWarningIssued: Boolean;

    class procedure SetLogToConsole(const Value: Boolean); static;
    class procedure SetLogToFile(const Value: Boolean); static;
    class procedure SetLogFileName(const Value: string); static;
    class procedure SetMinLogLevel(const Value: TLogLevel); static;
    class procedure SetOnLogMessage(const Value: TLogMessageProc); static;
    class procedure SetUseStdErr(const Value: Boolean); static;
    class procedure SetStdoutReserved(const Value: Boolean); static;

    class function GetLogToConsole: Boolean; static;
    class function GetLogToFile: Boolean; static;
    class function GetLogFileName: string; static;
    class function GetMinLogLevel: TLogLevel; static;
    class function GetOnLogMessage: TLogMessageProc; static;
    class function GetUseStdErr: Boolean; static;
    class function GetStdoutReserved: Boolean; static;

    constructor CreateInstance;
    procedure DoWriteLog(const Level: TLogLevel; const Message: string);
    procedure EnsureLogFile;
    function OpenSharedLogStream: TFileStream;
    procedure DisableFileLogging(const Reason: string);
    procedure DoCloseLogFile;
  public
    class constructor Create;
    class destructor Destroy;
    destructor Destroy; override;

    class function Instance: TLogger;

    class procedure Debug(const Message: string); overload;
    class procedure Debug(const Format: string; const Args: array of const); overload;

    class procedure Info(const Message: string); overload;
    class procedure Info(const Format: string; const Args: array of const); overload;

    class procedure Warning(const Message: string); overload;
    class procedure Warning(const Format: string; const Args: array of const); overload;

    class procedure Error(const Message: string); overload;
    class procedure Error(const Format: string; const Args: array of const); overload;
    class procedure Error(const Exception: Exception); overload;

    class function IsSensitiveKey(const Key: string): Boolean;
    class procedure RedactValue(const Value: TJSONValue);
    class function RedactJson(const Json: string): string;

    class property LogToConsole: Boolean read GetLogToConsole write SetLogToConsole;
    class property LogToFile: Boolean read GetLogToFile write SetLogToFile;
    class property LogFileName: string read GetLogFileName write SetLogFileName;
    class property MinLogLevel: TLogLevel read GetMinLogLevel write SetMinLogLevel;
    class property OnLogMessage: TLogMessageProc read GetOnLogMessage write SetOnLogMessage;
    class property UseStdErr: Boolean read GetUseStdErr write SetUseStdErr;
    class property StdoutReserved: Boolean read GetStdoutReserved write SetStdoutReserved;
  end;

implementation

{$IFDEF MSWINDOWS}
uses
  Winapi.Windows;
{$ENDIF}

const
  LOG_LEVEL_NAMES: array[TLogLevel] of string = ('DEBUG', 'INFO', 'WARN', 'ERROR');
  LOG_LEVEL_COLORS: array[TLogLevel] of Word = (7, 15, 14, 12);

{ TLogger }

class constructor TLogger.Create;
begin
  FLock := TCriticalSection.Create;
end;

class destructor TLogger.Destroy;
begin
  FreeAndNil(FInstance);
  FreeAndNil(FLock);
end;

constructor TLogger.CreateInstance;
begin
  inherited Create;
  FLogToConsole := False;
  FLogToFile := False;
  FLogFileName := ChangeFileExt(ParamStr(0), '.log');
  FMinLogLevel := TLogLevel.Info;
end;

destructor TLogger.Destroy;
begin
  DoCloseLogFile;
  inherited;
end;

class function TLogger.Instance: TLogger;
begin
  if not Assigned(FInstance) then
  begin
    FLock.Enter;
    try
      if not Assigned(FInstance) then
        FInstance := TLogger.CreateInstance;
    finally
      FLock.Leave;
    end;
  end;
  Result := FInstance;
end;

procedure TLogger.EnsureLogFile;
begin
  const AlreadyOpen = (not FLogToFile) or Assigned(FLogFile);
  if AlreadyOpen then
    Exit;

  try
    const LogStream = OpenSharedLogStream;
    FLogFile := TStreamWriter.Create(LogStream, TEncoding.UTF8);
    FLogFile.OwnStream;
    FLogFile.AutoFlush := True;
  except
    on E: Exception do
      DisableFileLogging(E.Message);
  end;
end;

function TLogger.OpenSharedLogStream: TFileStream;
begin
  const Exists = FileExists(FLogFileName);
  if Exists then
    Result := TFileStream.Create(FLogFileName, fmOpenReadWrite or fmShareDenyNone)
  else
    Result := TFileStream.Create(FLogFileName, fmCreate or fmShareDenyNone);
  Result.Seek(0, soEnd);
end;

procedure TLogger.DisableFileLogging(const Reason: string);
begin
  FLogToFile := False;
  if not FLogToConsole then
    Exit;

  const Warning = Format('[WARN ] File logging disabled, cannot open "%s": %s', [FLogFileName, Reason]);
  const ToStdErr = (FUseStdErr or FStdoutReserved);
  if ToStdErr then
    WriteLn(ErrOutput, Warning)
  else
    WriteLn(Warning);
end;

procedure TLogger.DoCloseLogFile;
begin
  FLock.Enter;
  try
    if Assigned(FLogFile) then
      FreeAndNil(FLogFile);
  finally
    FLock.Leave;
  end;
end;

procedure TLogger.DoWriteLog(const Level: TLogLevel; const Message: string);
var
  Timestamp: string;
  LogLine: string;
  ToStdErr: Boolean;
  {$IFDEF MSWINDOWS}
  ConsoleHandle: THandle;
  {$ENDIF}
begin
  if Level < FMinLogLevel then
    Exit;

  Timestamp := FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now);
  LogLine := Format('[%s] [%-5s] %s', [Timestamp, LOG_LEVEL_NAMES[Level], Message]);

  FLock.Enter;
  try
    if FLogToConsole then
    begin
      ToStdErr := FUseStdErr or FStdoutReserved;

      {$IFDEF MSWINDOWS}
      if ToStdErr then
        ConsoleHandle := GetStdHandle(STD_ERROR_HANDLE)
      else
        ConsoleHandle := GetStdHandle(STD_OUTPUT_HANDLE);
      SetConsoleTextAttribute(ConsoleHandle, LOG_LEVEL_COLORS[Level]);
      {$ENDIF}

      if ToStdErr then
        WriteLn(ErrOutput, LogLine)
      else
        WriteLn(LogLine);

      {$IFDEF MSWINDOWS}
      SetConsoleTextAttribute(ConsoleHandle, 7);
      {$ENDIF}
    end;

    if FLogToFile then
    begin
      EnsureLogFile;
      if Assigned(FLogFile) then
      begin
        FLogFile.BaseStream.Seek(0, soEnd);
        FLogFile.WriteLine(LogLine);
      end;
    end;

    if Assigned(FOnLogMessage) then
      FOnLogMessage(LogLine);
  finally
    FLock.Leave;
  end;
end;

class procedure TLogger.Debug(const Message: string);
begin
  Instance.DoWriteLog(TLogLevel.Debug, Message);
end;

class procedure TLogger.Debug(const Format: string; const Args: array of const);
begin
  Instance.DoWriteLog(TLogLevel.Debug, System.SysUtils.Format(Format, Args));
end;

class procedure TLogger.Info(const Message: string);
begin
  Instance.DoWriteLog(TLogLevel.Info, Message);
end;

class procedure TLogger.Info(const Format: string; const Args: array of const);
begin
  Instance.DoWriteLog(TLogLevel.Info, System.SysUtils.Format(Format, Args));
end;

class procedure TLogger.Warning(const Message: string);
begin
  Instance.DoWriteLog(TLogLevel.Warning, Message);
end;

class procedure TLogger.Warning(const Format: string; const Args: array of const);
begin
  Instance.DoWriteLog(TLogLevel.Warning, System.SysUtils.Format(Format, Args));
end;

class procedure TLogger.Error(const Message: string);
begin
  Instance.DoWriteLog(TLogLevel.Error, Message);
end;

class procedure TLogger.Error(const Format: string; const Args: array of const);
begin
  Instance.DoWriteLog(TLogLevel.Error, System.SysUtils.Format(Format, Args));
end;

class procedure TLogger.Error(const Exception: Exception);
begin
  Instance.DoWriteLog(TLogLevel.Error, System.SysUtils.Format('%s: %s', [Exception.ClassName, Exception.Message]));
end;

class function TLogger.IsSensitiveKey(const Key: string): Boolean;
const
  EXACT_KEYS: array[0..2] of string = ('_meta', 'requestState', 'inputResponses');
  PARTIAL_KEYS: array[0..5] of string = ('token', 'secret', 'password', 'authorization', 'apikey', 'api_key');
begin
  for var Exact in EXACT_KEYS do
    if Key = Exact then
      Exit(True);

  var Lower := Key.ToLower;
  for var Partial in PARTIAL_KEYS do
    if Lower.Contains(Partial) then
      Exit(True);
  Result := False;
end;

class procedure TLogger.RedactValue(const Value: TJSONValue);
begin
  if Value is TJSONObject then
  begin
    for var Pair in TJSONObject(Value) do
      if IsSensitiveKey(Pair.JsonString.Value) then
        Pair.JsonValue := TJSONString.Create('<redacted>')
      else
        RedactValue(Pair.JsonValue);
  end
  else if Value is TJSONArray then
    for var Item in TJSONArray(Value) do
    begin
      RedactValue(Item);
    end;
end;

class function TLogger.RedactJson(const Json: string): string;
begin
  var Parsed := TJSONObject.ParseJSONValue(Json);
  if not Assigned(Parsed) then
    begin
      Result := Format('<%d characters, not JSON>', [Length(Json)]);
      Exit;
    end;

  try
    RedactValue(Parsed);
    Result := Parsed.ToJSON;
  finally
    Parsed.Free;
  end;
end;

class function TLogger.GetLogToConsole: Boolean;
begin
  Result := Instance.FLogToConsole;
end;

class function TLogger.GetLogToFile: Boolean;
begin
  Result := Instance.FLogToFile;
end;

class function TLogger.GetLogFileName: string;
begin
  Result := Instance.FLogFileName;
end;

class function TLogger.GetMinLogLevel: TLogLevel;
begin
  Result := Instance.FMinLogLevel;
end;

class function TLogger.GetOnLogMessage: TLogMessageProc;
begin
  Result := Instance.FOnLogMessage;
end;

class procedure TLogger.SetLogToConsole(const Value: Boolean);
var
  lInstance: TLogger;
begin
  lInstance := Instance;
  if Assigned(lInstance) then
    lInstance.FLogToConsole := Value;
end;

class procedure TLogger.SetLogToFile(const Value: Boolean);
var
  lInstance: TLogger;
begin
  lInstance := Instance;
  if Assigned(lInstance) then
    lInstance.FLogToFile := Value;
end;

class procedure TLogger.SetLogFileName(const Value: string);
var
  lInstance: TLogger;
begin
  FLock.Enter;
  try
    lInstance := Instance;
    if lInstance = nil then
      Exit;

    lInstance.FLogFileName := Value;

    if Assigned(lInstance.FLogFile) then
      FreeAndNil(lInstance.FLogFile);
  finally
    FLock.Leave;
  end;
end;

class procedure TLogger.SetMinLogLevel(const Value: TLogLevel);
var
  lInstance: TLogger;
begin
  lInstance := Instance;
  if Assigned(lInstance) then
    lInstance.FMinLogLevel := Value;
end;

class procedure TLogger.SetOnLogMessage(const Value: TLogMessageProc);
var
  lInstance: TLogger;
begin
  lInstance := Instance;
  if Assigned(lInstance) then
    lInstance.FOnLogMessage := Value;
end;

class function TLogger.GetUseStdErr: Boolean;
begin
  Result := Instance.FUseStdErr;
end;

class procedure TLogger.SetUseStdErr(const Value: Boolean);
var
  lInstance: TLogger;
  WarnOnce: Boolean;
begin
  lInstance := Instance;
  if not Assigned(lInstance) then
    Exit;

  if Value or not lInstance.FStdoutReserved then
  begin
    lInstance.FUseStdErr := Value;
    Exit;
  end;

  FLock.Enter;
  try
    WarnOnce := not lInstance.FStdoutWarningIssued;
    lInstance.FStdoutWarningIssued := True;
  finally
    FLock.Leave;
  end;

  if WarnOnce then
    lInstance.DoWriteLog(TLogLevel.Warning,
      'TLogger.UseStdErr := False ignored: stdout is reserved for MCP messages while the stdio transport runs');
end;

class function TLogger.GetStdoutReserved: Boolean;
begin
  Result := Instance.FStdoutReserved;
end;

class procedure TLogger.SetStdoutReserved(const Value: Boolean);
var
  lInstance: TLogger;
begin
  lInstance := Instance;
  if not Assigned(lInstance) then
    Exit;

  lInstance.FStdoutReserved := Value;
  if Value then
    lInstance.FUseStdErr := True
  else
    lInstance.FStdoutWarningIssued := False;
end;

end.