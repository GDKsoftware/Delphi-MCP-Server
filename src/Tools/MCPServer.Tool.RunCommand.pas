unit MCPServer.Tool.RunCommand;

interface

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
  MCPServer.Tool.Base,
  MCPServer.Types;

type
  TRunCommandParams = class
  private
    FCommand: string;
  public
    [SchemaDescription('Command to execute')]
    property Command: string read FCommand write FCommand;
  end;

  TRunCommandTool = class(TMCPToolBase<TRunCommandParams>)
  protected
    function ExecuteWithParams(const Params: TRunCommandParams): string; override;
    function ExecuteWithParamsStructured(const Params: TRunCommandParams): TMCPToolResult; override;
  public
    constructor Create; override;
    function SupportsStructuredOutput: Boolean; override;
  end;

implementation

uses
  MCPServer.Registration;

{ TRunCommandTool }

constructor TRunCommandTool.Create;
begin
  inherited;
  FName := 'run_command';
  FDescription := 'Dummy tool demonstrating structured output (simulated command execution). Include "success" in command to simulate success.';
end;

function TRunCommandTool.SupportsStructuredOutput: Boolean;
begin
  Result := True;
end;

function TRunCommandTool.ExecuteWithParams(const Params: TRunCommandParams): string;
var
  ToolResult: TMCPToolResult;
  ResultJSON: TJSONObject;
begin
  ToolResult := ExecuteWithParamsStructured(Params);
  try
    ResultJSON := ToolResult.ToJSON;
    try
      Result := ResultJSON.ToJSON;
    finally
      ResultJSON.Free;
    end;
  finally
    ToolResult.Free;
  end;
end;

function TRunCommandTool.ExecuteWithParamsStructured(const Params: TRunCommandParams): TMCPToolResult;
var
  StructuredData: TJSONObject;
  Success: Boolean;
  ExitCode: Integer;
  StdOut: string;
begin
  Result := TMCPToolResult.Create;

  Success := Params.Command.Contains('success');

  if Success then
  begin
    ExitCode := 0;
    StdOut := 'This is a dummy tool demonstrating structured output.' + sLineBreak +
              'Command: ' + Params.Command + sLineBreak +
              'Output: Hello from structured tool!';
    Result.AddTextContent('Command executed successfully (simulated)');
  end
  else
  begin
    ExitCode := 1;
    StdOut := '';
    Result.AddTextContent('Command failed (simulated)');
    Result.IsError := True;
  end;

  StructuredData := TJSONObject.Create;
  StructuredData.AddPair('exitCode', TJSONNumber.Create(ExitCode));
  StructuredData.AddPair('stdout', StdOut);
  StructuredData.AddPair('stderr', '');
  StructuredData.AddPair('success', TJSONBool.Create(Success));
  StructuredData.AddPair('command', Params.Command);
  StructuredData.AddPair('note', 'This is a dummy tool for demonstration purposes');
  Result.SetStructuredContent(StructuredData);
end;

initialization
  TMCPRegistry.RegisterTool('run_command',
    function: IMCPTool
    begin
      Result := TRunCommandTool.Create;
    end
  );

end.
