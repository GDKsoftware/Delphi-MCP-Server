unit MCPServer.Resource.Logs;

interface

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  System.SyncObjs,
  MCPServer.Types,
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
    FTotalCount: NativeInt;
    FFilteredCount: NativeInt;
  public
    constructor Create;
    destructor Destroy; override;

    property Entries: TObjectList<TLogEntry> read FEntries write FEntries;
    property TotalCount: NativeInt read FTotalCount write FTotalCount;
    property FilteredCount: NativeInt read FFilteredCount write FFilteredCount;
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
    function GetLogs(AMaxCount: NativeInt = 100; const ALevel: string = ''): TObjectList<TLogEntry>;
  end;

  TLogsRecentResource = class(TMCPResourceBase<TLogEntries>)
  protected
    function GetResourceData: TLogEntries; override;
  public
    constructor Create; override;
  end;

  TLogsByLevelResource = class(TMCPResourceBase<TLogEntries>)
  private
    FLevel: string;
  protected
    function GetResourceData: TLogEntries; override;
  public
    constructor CreateForLevel(const AUri, ALevel: string); reintroduce;
  end;

  TLogsByLevelTemplate = class(TMCPResourceTemplateBase, IMCPCompletable)
  public
    constructor Create; override;
    function CreateResource(const URI: string; Vars: TMCPTemplateVars): IMCPResource; override;
    function Complete(const ArgumentName, Value: string;
      const Context: TArray<TPair<string, string>>): TMCPCompletion;
  end;

implementation

uses
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  {$ENDIF}
  System.DateUtils,
  System.Math,
  MCPServer.Registration;

const
  MAX_RECENT_LOG_ENTRIES = 100;

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

    while FLogs.Count > FMaxEntries do
    begin
      FLogs[0].Free;
      FLogs.Delete(0);
    end;
  finally
    FLock.Release;
  end;
end;

function TLogBuffer.GetLogs(AMaxCount: NativeInt; const ALevel: string): TObjectList<TLogEntry>;
var
  i: NativeInt;
  Entry, NewEntry: TLogEntry;
  StartIndex: NativeInt;
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
  FTtlMs := 0;
  FCacheScope := MCP_CACHE_SCOPE_PRIVATE;
end;

function TLogsRecentResource.GetResourceData: TLogEntries;
begin
  const Logs = TLogBuffer.Instance.GetLogs(MAX_RECENT_LOG_ENTRIES);
  try
    const Entries = TLogEntries.Create;
    try
      Entries.Entries.AddRange(Logs);
      Entries.TotalCount := Logs.Count;
      Entries.FilteredCount := Logs.Count;
      Logs.OwnsObjects := False;
    except
      Entries.Entries.OwnsObjects := False;
      Entries.Free;
      raise;
    end;
    Result := Entries;
  finally
    Logs.Free;
  end;
end;

{ TLogsByLevelResource }

constructor TLogsByLevelResource.CreateForLevel(const AUri, ALevel: string);
begin
  inherited Create;
  FLevel := ALevel;
  FURI := AUri;
  FName := 'Recent logs (' + ALevel + ')';
  FDescription := 'Recent log entries at level ' + ALevel;
  FMimeType := 'application/json';
  FTtlMs := 0;
  FCacheScope := MCP_CACHE_SCOPE_PRIVATE;
end;

function TLogsByLevelResource.GetResourceData: TLogEntries;
begin
  const Logs = TLogBuffer.Instance.GetLogs(MAX_RECENT_LOG_ENTRIES, FLevel);
  try
    const Entries = TLogEntries.Create;
    try
      Entries.Entries.AddRange(Logs);
      Entries.TotalCount := Logs.Count;
      Entries.FilteredCount := Logs.Count;
      Logs.OwnsObjects := False;
    except
      Entries.Entries.OwnsObjects := False;
      Entries.Free;
      raise;
    end;
    Result := Entries;
  finally
    Logs.Free;
  end;
end;

{ TLogsByLevelTemplate }

constructor TLogsByLevelTemplate.Create;
begin
  inherited;
  FUriTemplate := 'logs://{level}';
  FName := 'Recent logs by level';
  FDescription := 'Recent log entries at the given level, e.g. logs://INFO';
  FMimeType := 'application/json';
end;

function TLogsByLevelTemplate.CreateResource(const URI: string; Vars: TMCPTemplateVars): IMCPResource;
begin
  Result := TLogsByLevelResource.CreateForLevel(URI, Vars['level']);
end;

function TLogsByLevelTemplate.Complete(const ArgumentName, Value: string;
  const Context: TArray<TPair<string, string>>): TMCPCompletion;
begin
  if ArgumentName <> 'level' then
    Exit(TMCPCompletion.Create(nil));

  var Levels := TStringList.Create;
  try
    Levels.Sorted := True;
    Levels.Duplicates := dupIgnore;
    var Entries := TLogBuffer.Instance.GetLogs(1000);
    try
      for var Entry in Entries do
        if Entry.Level.StartsWith(Value, True) then
          Levels.Add(Entry.Level);
    finally
      Entries.Free;
    end;
    Result := TMCPCompletion.Create(Levels.ToStringArray, Levels.Count);
  finally
    Levels.Free;
  end;
end;

initialization
  TLogBuffer.FLock := TCriticalSection.Create;

  TLogBuffer.Instance.AddLog('INFO', 'MCP Server started', 'SYSTEM');
  TLogBuffer.Instance.AddLog('INFO', 'Resources manager initialized', 'SYSTEM');
  TLogBuffer.Instance.AddLog('INFO', 'Tools manager initialized', 'SYSTEM');
  TLogBuffer.Instance.AddLog('WARNING', 'Debug mode is enabled', 'CONFIG');
  TLogBuffer.Instance.AddLog('INFO', 'Server listening on port 8080', 'SERVER');

  TMCPRegistry.RegisterResource('logs://recent',
    function: IMCPResource
    begin
      Result := TLogsRecentResource.Create;
    end
  );

  TMCPRegistry.RegisterResourceTemplate('logs://{level}',
    function: IMCPResourceTemplate
    begin
      Result := TLogsByLevelTemplate.Create;
    end
  );


finalization
  TLogBuffer.Finalize;
  TLogBuffer.FLock.Free;

end.