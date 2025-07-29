unit MCPServer.Tool.Base;

interface

uses
  System.SysUtils,
  System.Rtti,
  System.JSON;

type
  IMCPTool = interface
    ['{F1E2D3C4-B5A6-4798-8901-234567890ABC}']
    function GetName: string;
    function GetDescription: string;
    function GetInputSchema: TJSONObject;
    function Execute(const Arguments: TJSONObject): string;
    
    property Name: string read GetName;
    property Description: string read GetDescription;
    property InputSchema: TJSONObject read GetInputSchema;
  end;
  
  TMCPToolBase = class(TInterfacedObject, IMCPTool)
  protected
    FName: string;
    FDescription: string;
    function BuildSchema: TJSONObject; virtual; abstract;
  public
    constructor Create; virtual;
    
    function GetName: string;
    function GetDescription: string;
    function GetInputSchema: TJSONObject;
    function Execute(const Arguments: TJSONObject): string; virtual; abstract;
  end;
  
  TMCPToolBase<T: class, constructor> = class(TInterfacedObject, IMCPTool)
  protected
    FName: string;
    FDescription: string;
    function ExecuteWithParams(const Params: T): string; virtual; abstract;
    function GetParamsClass: TClass; virtual;
  public
    constructor Create; virtual;
    
    function GetName: string;
    function GetDescription: string;
    function GetInputSchema: TJSONObject;
    function Execute(const Arguments: TJSONObject): string;
  end;

implementation

uses
  MCPServer.Schema.Generator,
  MCPServer.Serializer;

{ TMCPToolBase }

constructor TMCPToolBase.Create;
begin
  inherited Create;
end;

function TMCPToolBase.GetName: string;
begin
  Result := FName;
end;

function TMCPToolBase.GetDescription: string;
begin
  Result := FDescription;
end;

function TMCPToolBase.GetInputSchema: TJSONObject;
begin
  Result := BuildSchema;
end;

{ TMCPToolBase<T> }

constructor TMCPToolBase<T>.Create;
begin
  inherited Create;
end;

function TMCPToolBase<T>.GetName: string;
begin
  Result := FName;
end;

function TMCPToolBase<T>.GetDescription: string;
begin
  Result := FDescription;
end;

function TMCPToolBase<T>.GetInputSchema: TJSONObject;
begin
  Result := TMCPSchemaGenerator.GenerateSchema(T);
end;

function TMCPToolBase<T>.Execute(const Arguments: TJSONObject): string;
var
  ParamsInstance: T;
begin
  ParamsInstance := TMCPSerializer.Deserialize<T>(Arguments);
  try
    Result := ExecuteWithParams(ParamsInstance);
  finally
    ParamsInstance.Free;
  end;
end;

function TMCPToolBase<T>.GetParamsClass: TClass;
begin
  Result := T;
end;

end.