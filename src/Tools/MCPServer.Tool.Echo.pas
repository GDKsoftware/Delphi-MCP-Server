unit MCPServer.Tool.Echo;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Tool.Base,
  MCPServer.Types;

type
  TEchoParams = class
  private
    FMessage: string;
  public
    [SchemaDescription('Message to echo back')]
    property Message: string read FMessage write FMessage;
  end;

  TEchoTool = class(TMCPToolBase<TEchoParams>)
  protected
    function ExecuteWithParams(const Params: TEchoParams): string; override;
  public
    constructor Create; override;
  end;

implementation

uses
  MCPServer.Registration;

{ TEchoTool }

constructor TEchoTool.Create;
begin
  inherited;
  FName := 'echo';
  FDescription := 'Echo a message back to the user';
end;

function TEchoTool.ExecuteWithParams(const Params: TEchoParams): string;
begin
  Result := 'Echo: ' + Params.Message;
end;

initialization
  TMCPRegistry.RegisterTool('echo',
    function: IMCPTool
    begin
      Result := TEchoTool.Create;
    end
  );

end.