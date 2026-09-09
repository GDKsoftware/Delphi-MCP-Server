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

const
  TOOL_NAME = 'get_time';


{ TGetTimeTool }

constructor TGetTimeTool.Create;
begin
  inherited;
  FName := TOOL_NAME;
  FDescription := 'Get the current server time in ISO format';
end;

function TGetTimeTool.ExecuteWithParams(const Params: TGetTimeParams): string;
begin
  Result := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss.zzz"Z"', TTimeZone.Local.ToUniversalTime(Now));
end;

initialization
  TMCPRegistry.RegisterTool(TOOL_NAME,
    function: IMCPTool
    begin
      Result := TGetTimeTool.Create;
    end
  );

end.