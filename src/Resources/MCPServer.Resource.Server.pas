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
    FMemoryUsed: Int64;
    FRequestCount: Int64;
    FActiveConnections: Integer;
  public
    property Status: string read FStatus write FStatus;
    property Uptime: Int64 read FUptime write FUptime;
    property StartTime: TDateTime read FStartTime write FStartTime;
    property CurrentTime: TDateTime read FCurrentTime write FCurrentTime;
    property MemoryUsed: Int64 read FMemoryUsed write FMemoryUsed;
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
    class procedure Initialize;
    class procedure SetNamePrefix(const Prefix: string);
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
end;

class procedure TServerStatusResource.IncrementRequestCount;
begin
  Inc(FRequestCount);
end;

class procedure TServerStatusResource.ConnectionOpened;
begin
  Inc(FActiveConnections);
end;

class procedure TServerStatusResource.ConnectionClosed;
begin
  if FActiveConnections > 0 then
    Dec(FActiveConnections);
end;

constructor TServerStatusResource.Create;
begin
  inherited;
  FURI := 'server://status';
  if FNamePrefix <> '' then
    FName := FNamePrefix + 'server_status'
  else
    FName := 'server_status';
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
  Result.RequestCount := FRequestCount;
  Result.ActiveConnections := FActiveConnections;
  
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
  
  TMCPRegistry.RegisterResource('server://status',
    function: IMCPResource
    begin
      Result := TServerStatusResource.Create;
    end
  );
  

end.