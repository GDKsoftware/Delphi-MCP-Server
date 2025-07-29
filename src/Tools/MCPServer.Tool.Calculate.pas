unit MCPServer.Tool.Calculate;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Tool.Base,
  MCPServer.Types;

type
  TOperationType = (otAdd, otSubtract, otMultiply, otDivide);
  
  TCalculateParams = class
  private
    FOperation: string;
    FA: Double;
    FB: Double;
  public
    [SchemaDescription('Operation: add, subtract, multiply, divide')]
    [SchemaEnum('add', 'subtract', 'multiply', 'divide')]
    property Operation: string read FOperation write FOperation;
    
    [SchemaDescription('First number')]
    property A: Double read FA write FA;
    
    [SchemaDescription('Second number')]
    property B: Double read FB write FB;
  end;

  TCalculateTool = class(TMCPToolBase<TCalculateParams>)
  protected
    function ExecuteWithParams(const Params: TCalculateParams): string; override;
  public
    constructor Create; override;
  end;

implementation

uses
  MCPServer.Registration;

{ TCalculateTool }

constructor TCalculateTool.Create;
begin
  inherited;
  FName := 'calculate';
  FDescription := 'Perform basic arithmetic calculations';
end;

function TCalculateTool.ExecuteWithParams(const Params: TCalculateParams): string;
var
  ResultValue: Double;
begin
  if Params.Operation = 'add' then
    ResultValue := Params.A + Params.B
  else if Params.Operation = 'subtract' then
    ResultValue := Params.A - Params.B
  else if Params.Operation = 'multiply' then
    ResultValue := Params.A * Params.B
  else if Params.Operation = 'divide' then
  begin
    if Params.B <> 0 then
      ResultValue := Params.A / Params.B
    else
    begin
      Result := 'Error: Division by zero';
      Exit;
    end;
  end
  else
  begin
    Result := 'Error: Unknown operation: ' + Params.Operation;
    Exit;
  end;
  
  Result := Format('%s %s %s = %g', [
    FloatToStr(Params.A), Params.Operation, FloatToStr(Params.B), ResultValue
  ]);
end;

initialization
  TMCPRegistry.RegisterTool('calculate',
    function: IMCPTool
    begin
      Result := TCalculateTool.Create;
    end
  );

end.