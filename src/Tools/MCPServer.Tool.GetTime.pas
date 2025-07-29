unit MCPServer.Tool.GetTime;

interface

uses
  System.SysUtils,
  System.DateUtils,
  System.JSON,
  MCPServer.Tool.Base;

type
  TGetTimeParams = class
  end;

  TGetTimeTool = class(TMCPToolBase<TGetTimeParams>)
  protected
    function ExecuteWithParams(const Params: TGetTimeParams): string; override;
  public
    constructor Create; override;
  end;

implementation

uses
  MCPServer.Registration;

{ TGetTimeTool }

constructor TGetTimeTool.Create;
begin
  inherited;
  FName := 'get_time';
  FDescription := 'Get the current server time in ISO format';
end;

function TGetTimeTool.ExecuteWithParams(const Params: TGetTimeParams): string;
begin
  Result := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss.zzz"Z"', TTimeZone.Local.ToUniversalTime(Now));
end;

initialization
  TMCPRegistry.RegisterTool('get_time',
    function: IMCPTool
    begin
      Result := TGetTimeTool.Create;
    end
  );

end.