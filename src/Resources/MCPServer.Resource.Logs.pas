unit MCPServer.Resource.Logs;

interface

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  System.SyncObjs,
  MCPServer.Resource.Base;

type
  TLogEntry = class
  private
    FTimestamp: TDateTime;
    FLevel: string;
    FMessage: string;
    FThreadID: Cardinal;
    FCategory: string;
  public
    property Timestamp: TDateTime read FTimestamp write FTimestamp;
    property Level: string read FLevel write FLevel;
    property Message: string read FMessage write FMessage;
    property ThreadID: Cardinal read FThreadID write FThreadID;
    property Category: string read FCategory write FCategory;
  end;

  TLogEntries = class
  private
    FEntries: TObjectList<TLogEntry>;
    FTotalCount: Integer;
    FFilteredCount: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    
    property Entries: TObjectList<TLogEntry> read FEntries write FEntries;
    property TotalCount: Integer read FTotalCount write FTotalCount;
    property FilteredCount: Integer read FFilteredCount write FFilteredCount;
  end;

  TLogBuffer = class
  private
    class var FInstance: TLogBuffer;
    class var FLock: TCriticalSection;
    FLogs: TList<TLogEntry>;
    FMaxEntries: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    
    class function Instance: TLogBuffer;
    class procedure Finalize;
    
    procedure AddLog(const ALevel, AMessage, ACategory: string);
    function GetLogs(AMaxCount: Integer = 100; const ALevel: string = ''): TObjectList<TLogEntry>;
  end;

  TLogsRecentResource = class(TMCPResourceBase<TLogEntries>)
  protected
    function GetResourceData: TLogEntries; override;
  public
    constructor Create; override;
  end;


implementation

uses
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  {$ENDIF}
  System.DateUtils,
  System.Math,
  MCPServer.Registration;

{ TLogEntries }

constructor TLogEntries.Create;
begin
  inherited;
  FEntries := TObjectList<TLogEntry>.Create(True);
end;

destructor TLogEntries.Destroy;
begin
  FEntries.Free;
  inherited;
end;

{ TLogBuffer }

constructor TLogBuffer.Create;
begin
  inherited;
  FLogs := TList<TLogEntry>.Create;
  FMaxEntries := 1000;
end;

destructor TLogBuffer.Destroy;
var
  Entry: TLogEntry;
begin
  for Entry in FLogs do
    Entry.Free;
  FLogs.Free;
  inherited;
end;

class function TLogBuffer.Instance: TLogBuffer;
begin
  if not Assigned(FInstance) then
  begin
    FLock.Acquire;
    try
      if not Assigned(FInstance) then
        FInstance := TLogBuffer.Create;
    finally
      FLock.Release;
    end;
  end;
  Result := FInstance;
end;

class procedure TLogBuffer.Finalize;
begin
  FreeAndNil(FInstance);
end;

procedure TLogBuffer.AddLog(const ALevel, AMessage, ACategory: string);
var
  Entry: TLogEntry;
begin
  FLock.Acquire;
  try
    Entry := TLogEntry.Create;
    Entry.Timestamp := Now;
    Entry.Level := ALevel;
    Entry.Message := AMessage;
    Entry.Category := ACategory;
    {$IFDEF MSWINDOWS}
    Entry.ThreadID := GetCurrentThreadId;
    {$ELSE}
    Entry.ThreadID := TThread.CurrentThread.ThreadID;
    {$ENDIF}
    
    FLogs.Add(Entry);
    
    // Remove earliest entries if buffer exceeds maximum capacity
    while FLogs.Count > FMaxEntries do
    begin
      FLogs[0].Free;
      FLogs.Delete(0);
    end;
  finally
    FLock.Release;
  end;
end;

function TLogBuffer.GetLogs(AMaxCount: Integer; const ALevel: string): TObjectList<TLogEntry>;
var
  i: Integer;
  Entry, NewEntry: TLogEntry;
  StartIndex: Integer;
begin
  Result := TObjectList<TLogEntry>.Create(True);
  
  FLock.Acquire;
  try
    StartIndex := Max(0, FLogs.Count - AMaxCount);
    
    for i := StartIndex to FLogs.Count - 1 do
    begin
      Entry := FLogs[i];
      if (ALevel = '') or (Entry.Level = ALevel) then
      begin
        NewEntry := TLogEntry.Create;
        NewEntry.Timestamp := Entry.Timestamp;
        NewEntry.Level := Entry.Level;
        NewEntry.Message := Entry.Message;
        NewEntry.ThreadID := Entry.ThreadID;
        NewEntry.Category := Entry.Category;
        Result.Add(NewEntry);
      end;
    end;
  finally
    FLock.Release;
  end;
end;

{ TLogsRecentResource }

constructor TLogsRecentResource.Create;
begin
  inherited;
  FURI := 'logs://recent';
  FName := 'Recent Logs';
  FDescription := 'Recent log entries from all categories';
  FMimeType := 'application/json';
end;

function TLogsRecentResource.GetResourceData: TLogEntries;
var
  Logs: TObjectList<TLogEntry>;
begin
  Result := TLogEntries.Create;
  
  // Add access log entry
  TLogBuffer.Instance.AddLog('INFO', 'Resource accessed: logs://recent', 'ACCESS');
  
  Logs := TLogBuffer.Instance.GetLogs(100);
  try
    Result.Entries.AddRange(Logs.ToArray);
    Result.TotalCount := Logs.Count;
    Result.FilteredCount := Logs.Count;
  finally
    Logs.Free;
  end;
end;


initialization
  TLogBuffer.FLock := TCriticalSection.Create;
  
  // Example initialization logs
  TLogBuffer.Instance.AddLog('INFO', 'MCP Server started', 'SYSTEM');
  TLogBuffer.Instance.AddLog('INFO', 'Resources manager initialized', 'SYSTEM');
  TLogBuffer.Instance.AddLog('INFO', 'Tools manager initialized', 'SYSTEM');
  TLogBuffer.Instance.AddLog('WARNING', 'Debug mode is enabled', 'CONFIG');
  TLogBuffer.Instance.AddLog('INFO', 'Server listening on port 8080', 'SERVER');
  
  // Register Logs resources
  TMCPRegistry.RegisterResource('logs://recent',
    function: IMCPResource
    begin
      Result := TLogsRecentResource.Create;
    end
  );
  

finalization
  TLogBuffer.Finalize;
  TLogBuffer.FLock.Free;

end.