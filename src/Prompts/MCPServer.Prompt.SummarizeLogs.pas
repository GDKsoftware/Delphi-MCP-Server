unit MCPServer.Prompt.SummarizeLogs;

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  MCPServer.Types,
  MCPServer.Prompt.Base;

type
  TSummarizeLogsParams = class
  private
    FLevel: string;
  public
    [Optional]
    [SchemaDescription('Only include entries at this level (e.g. INFO, WARNING); all levels when omitted')]
    property Level: string read FLevel write FLevel;
  end;

  /// Asks the model to summarize the server's recent log entries, embedding
  /// logs://recent (or a level-filtered view of it) as a resource. The
  /// level argument completes against the levels actually present in the
  /// log buffer.
  TSummarizeLogsPrompt = class(TMCPPromptBase<TSummarizeLogsParams>, IMCPCompletable)
  protected
    function ExecuteWithParams(const Params: TSummarizeLogsParams; Messages: TMCPPromptMessages): string; override;
  public
    constructor Create; override;
    function Complete(const ArgumentName, Value: string;
      const Context: TArray<TPair<string, string>>): TMCPCompletion;
  end;

implementation

uses
  System.Classes,
  MCPServer.Registration,
  MCPServer.Resource.Logs;

{ TSummarizeLogsPrompt }

constructor TSummarizeLogsPrompt.Create;
begin
  inherited;
  FName := 'summarize_logs';
  FDescription := 'Summarizes the server''s recent log entries, optionally filtered by level';
end;

function TSummarizeLogsPrompt.ExecuteWithParams(const Params: TSummarizeLogsParams;
  Messages: TMCPPromptMessages): string;
var
  Entries: TObjectList<TLogEntry>;
  ResourceUri, ResourceText: string;
begin
  if Params.Level = '' then
  begin
    Messages.AddText('user', 'Summarize the server''s recent log entries, calling out anything unusual.');
    ResourceUri := 'logs://recent';
  end
  else
  begin
    Messages.AddText('user', Format(
      'Summarize the server''s recent "%s" log entries, calling out anything unusual.', [Params.Level]));
    ResourceUri := 'logs://' + Params.Level;
  end;

  Entries := TLogBuffer.Instance.GetLogs(100, Params.Level);
  try
    var Lines := TStringList.Create;
    try
      for var Entry in Entries do
        Lines.Add(Format('[%s] [%s] %s: %s', [FormatDateTime('yyyy-mm-dd hh:nn:ss', Entry.Timestamp),
          Entry.Level, Entry.Category, Entry.Message]));
      ResourceText := Lines.Text;
    finally
      Lines.Free;
    end;
  finally
    Entries.Free;
  end;

  Messages.AddEmbeddedText('user', ResourceUri, 'text/plain', ResourceText);
  Result := 'Log summary request';
end;

function TSummarizeLogsPrompt.Complete(const ArgumentName, Value: string;
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
  TMCPRegistry.RegisterPrompt('summarize_logs',
    function: IMCPPrompt
    begin
      Result := TSummarizeLogsPrompt.Create;
    end);

end.
