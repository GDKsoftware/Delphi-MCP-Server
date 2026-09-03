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
    /// Resets the start time and the counters. Runs from the unit
    /// initialization and again from MCPServer.dpr before a transport starts.
    class procedure Initialize;
    /// Re-registers the resource as server://<Prefix>status and removes the
    /// URI registered before. The registry is read once, when
    /// TMCPResourcesManager is created, so call this before the managers are
    /// built (before TMCPIdHTTPServer.Start or TMCPStdioTransport.Run).
    class procedure SetNamePrefix(const Prefix: string);
    /// Registers server://status (or the prefixed URI). The unit
    /// initialization does this once, so the resource is available by default.
    class procedure RegisterServerStatusResource;
    // The counters are updated from every Indy connection thread, so they
    // use atomic operations.
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
  TMCPRegistry.UnregisterResource(StatusURI);
  FNamePrefix := Prefix;
  RegisterServerStatusResource;
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
  // Never below zero, and without a moment in which a reader can see -1.
  var Current := AtomicCmpExchange(FActiveConnections, 0, 0);
  while Current > 0 do
  begin
    var Previous := AtomicCmpExchange(FActiveConnections, Current - 1, Current);
    if Previous = Current then
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
  Result.MemoryUsed := 0; // Not implemented for other platforms
  {$ENDIF}
end;


initialization
  TServerStatusResource.Initialize;
  TServerStatusResource.RegisterServerStatusResource;

end.