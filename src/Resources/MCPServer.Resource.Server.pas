unit MCPServer.Resource.Server;

interface

uses
  System.SysUtils,
  System.DateUtils,
  System.Generics.Collections,
  MCPServer.Resource.Base;

type
  TServerStatus = class
  private
    FStatus: string;
    FUptime: Int64;
    FStartTime: TDateTime;
    FCurrentTime: TDateTime;
    FMemoryUsed: UInt64;
    FRequestCount: Int64;
    FActiveConnections: Integer;
  public
    property Status: string read FStatus write FStatus;
    property Uptime: Int64 read FUptime write FUptime;
    property StartTime: TDateTime read FStartTime write FStartTime;
    property CurrentTime: TDateTime read FCurrentTime write FCurrentTime;
    property MemoryUsed: UInt64 read FMemoryUsed write FMemoryUsed;
    property RequestCount: Int64 read FRequestCount write FRequestCount;
    property ActiveConnections: Integer read FActiveConnections write FActiveConnections;
  end;

  TServerStatusResource = class(TMCPResourceBase<TServerStatus>)
  private
    class var FServerStartTime: TDateTime;
    class var FRequestCount: Int64;
    class var FActiveConnections: Integer;
    class var FNamePrefix: string;
    class function StatusURI: string;
  protected
    function GetResourceData: TServerStatus; override;
  public
    constructor Create; override;
    class procedure Initialize;
    class procedure SetNamePrefix(const Prefix: string);
    class procedure RegisterServerStatusResource;
    class procedure IncrementRequestCount;
    class procedure ConnectionOpened;
    class procedure ConnectionClosed;
  end;

implementation

uses
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  Winapi.PsAPI,
  {$ENDIF}
  System.Classes,
  MCPServer.Registration;

{ TServerStatusResource }

class procedure TServerStatusResource.Initialize;
begin
  FServerStartTime := Now;
  FRequestCount := 0;
  FActiveConnections := 0;
  FNamePrefix := '';
end;

class function TServerStatusResource.StatusURI: string;
begin
  Result := 'server://' + FNamePrefix + 'status';
end;

class procedure TServerStatusResource.SetNamePrefix(const Prefix: string);
begin
  const PreviousUri = StatusURI;
  FNamePrefix := Prefix;
  RegisterServerStatusResource;
  const UriChanged = (PreviousUri <> StatusURI);
  if UriChanged then
    TMCPRegistry.UnregisterResource(PreviousUri);
end;

class procedure TServerStatusResource.RegisterServerStatusResource;
begin
  TMCPRegistry.RegisterResource(StatusURI,
    function: IMCPResource
    begin
      Result := TServerStatusResource.Create;
    end
  );
end;

class procedure TServerStatusResource.IncrementRequestCount;
begin
  AtomicIncrement(FRequestCount);
end;

class procedure TServerStatusResource.ConnectionOpened;
begin
  AtomicIncrement(FActiveConnections);
end;

class procedure TServerStatusResource.ConnectionClosed;
begin
  var Current := AtomicCmpExchange(FActiveConnections, 0, 0);
  while Current > 0 do
  begin
    var Previous := AtomicCmpExchange(FActiveConnections, Current - 1, Current);
    const IsCurrent = (Previous = Current);
    if IsCurrent then
      Exit;
    Current := Previous;
  end;
end;

constructor TServerStatusResource.Create;
begin
  inherited;
  FURI := StatusURI;
  FName := FNamePrefix + 'server_status';
  FDescription := 'Current server status and health information';
  FMimeType := 'application/json';
end;

function TServerStatusResource.GetResourceData: TServerStatus;
{$IFDEF MSWINDOWS}
var
  ProcessMemoryCounters: TProcessMemoryCounters;
{$ENDIF}
begin
  Result := TServerStatus.Create;
  Result.Status := 'running';
  Result.StartTime := FServerStartTime;
  Result.CurrentTime := Now;
  Result.Uptime := SecondsBetween(Now, FServerStartTime);
  Result.RequestCount := AtomicCmpExchange(FRequestCount, 0, 0);
  Result.ActiveConnections := AtomicCmpExchange(FActiveConnections, 0, 0);

  {$IFDEF MSWINDOWS}
  ProcessMemoryCounters.cb := SizeOf(ProcessMemoryCounters);
  if GetProcessMemoryInfo(GetCurrentProcess, @ProcessMemoryCounters, SizeOf(ProcessMemoryCounters)) then
    Result.MemoryUsed := ProcessMemoryCounters.WorkingSetSize
  else
    Result.MemoryUsed := 0;
  {$ELSE}
  Result.MemoryUsed := 0;
  {$ENDIF}
end;

initialization
  TServerStatusResource.Initialize;
  TServerStatusResource.RegisterServerStatusResource;

end.