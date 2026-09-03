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
  protected
    function GetResourceData: TServerStatus; override;
  public
    constructor Create; override;
    /// Resets the start time and the counters. Runs from the unit
    /// initialization and again from MCPServer.dpr before a transport starts.
    class procedure Initialize;
    /// Registers the resource as server://<Prefix>status. The registry is read
    /// once, when TMCPResourcesManager is created, so call this before the
    /// managers are built (before TMCPIdHTTPServer.Start or
    /// TMCPStdioTransport.Run); a later call registers a URI nobody serves.
    class procedure SetNamePrefix(const Prefix: string);
    /// Registers server://status (or the prefixed URI). MCPServer.dpr does not
    /// call this; the resource is opt-in for library consumers.
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

class procedure TServerStatusResource.SetNamePrefix(const Prefix: string);
begin
  FNamePrefix := Prefix;
  RegisterServerStatusResource;
end;

class procedure TServerStatusResource.RegisterServerStatusResource;
var
  URI: string;
begin
  if FNamePrefix <> '' then
    URI := 'server://' + FNamePrefix + 'status'
  else
    URI := 'server://status';

  TMCPRegistry.RegisterResource(URI,
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
  if FNamePrefix <> '' then
  begin
    FURI := 'server://' + FNamePrefix + 'status';
    FName := FNamePrefix + 'server_status';
  end
  else
  begin
    FURI := 'server://status';
    FName := 'server_status';
  end;
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

end.