unit MCPServer.Tool.Base;

interface

uses
  System.SysUtils,
  System.Rtti,
  System.JSON,
  MCPServer.Types;

type
  IMCPTool = interface
    ['{F1E2D3C4-B5A6-4798-8901-234567890ABC}']
    function GetName: string;
    function GetTitle: string;
    function GetDescription: string;
    function GetInputSchema: TJSONObject;
    function GetOutputSchema: TJSONObject;
    function Execute(const Arguments: TJSONObject): TValue;

    property Name: string read GetName;
    property Title: string read GetTitle;
    property Description: string read GetDescription;
    property InputSchema: TJSONObject read GetInputSchema;
    property OutputSchema: TJSONObject read GetOutputSchema;
  end;

  TMCPToolBase = class(TInterfacedObject, IMCPTool, IMCPToolMetadata)
  protected
    FName: string;
    FTitle: string;
    FDescription: string;
    FAnnotations: TJSONObject;
    FIcons: TJSONArray;
    function BuildSchema: TJSONObject; virtual; abstract;
    function DoExecute(const Arguments: TJSONObject): TValue; virtual; abstract;
  public
    constructor Create; virtual;
    destructor Destroy; override;

    function GetName: string;
    function GetTitle: string;
    function GetDescription: string;
    function GetInputSchema: TJSONObject;
    function GetOutputSchema: TJSONObject;
    function GetAnnotations: TJSONObject;
    function GetIcons: TJSONArray;
    function Execute(const Arguments: TJSONObject): TValue;
  end;

  TMCPToolBase<T : class, constructor> = class(TInterfacedObject, IMCPTool, IMCPToolMetadata)
  protected
    FName: string;
    FTitle: string;
    FDescription: string;
    FAnnotations: TJSONObject;
    FIcons: TJSONArray;
    function ExecuteWithParams(const Params: T): string; virtual;
    function ExecuteWithContext(const Params: T; const Context: IMCPRequestContext): TValue; virtual;
    function GetParamsClass: TClass; virtual;
  public
    constructor Create; virtual;
    destructor Destroy; override;

    function GetName: string;
    function GetTitle: string;
    function GetDescription: string;
    function GetInputSchema: TJSONObject;
    function GetOutputSchema: TJSONObject;
    function GetAnnotations: TJSONObject;
    function GetIcons: TJSONArray;
    function Execute(const Arguments: TJSONObject): TValue;
  end;

  TMCPToolBase<T,R : class, constructor> = class(TInterfacedObject, IMCPTool, IMCPToolMetadata)
  protected
    FName: string;
    FTitle: string;
    FDescription: string;
    FAnnotations: TJSONObject;
    FIcons: TJSONArray;
    function ExecuteWithParams(const Params: T): R; virtual;
    function ExecuteWithContext(const Params: T; const Context: IMCPRequestContext): TValue; virtual;
  public
    constructor Create; virtual;
    destructor Destroy; override;

    function GetName: string;
    function GetTitle: string;
    function GetDescription: string;
    function GetInputSchema: TJSONObject;
    function GetOutputSchema: TJSONObject;
    function GetAnnotations: TJSONObject;
    function GetIcons: TJSONArray;
    function Execute(const Arguments: TJSONObject): TValue;
  end;

implementation

uses
  MCPServer.Schema.Generator,
  MCPServer.Schema.Validator,
  MCPServer.Serializer,
  MCPServer.RequestContext,
  MCPServer.Tool.Result;

{ TMCPToolBase }

constructor TMCPToolBase.Create;
begin
  inherited Create;
end;

destructor TMCPToolBase.Destroy;
begin
  FAnnotations.Free;
  FIcons.Free;
  inherited;
end;

function TMCPToolBase.GetName: string;
begin
  Result := FName;
end;

function TMCPToolBase.GetTitle: string;
begin
  if FTitle <> '' then
    Result := FTitle
  else
    Result := FName;
end;

function TMCPToolBase.GetOutputSchema: TJSONObject;
begin
  Result := nil;
end;

function TMCPToolBase.GetDescription: string;
begin
  Result := FDescription;
end;

function TMCPToolBase.GetInputSchema: TJSONObject;
begin
  Result := BuildSchema;
end;

function TMCPToolBase.GetAnnotations: TJSONObject;
begin
  Result := FAnnotations;
end;

function TMCPToolBase.GetIcons: TJSONArray;
begin
  Result := FIcons;
end;

function TMCPToolBase.Execute(const Arguments: TJSONObject): TValue;
begin
  var Schema := BuildSchema;
  try
    var Errors: TArray<string>;
    if not TMCPSchemaValidator.TryValidate(Schema, Arguments, Errors) then
      raise EArgumentException.Create(string.Join('; ', Errors));
  finally
    Schema.Free;
  end;
  Result := DoExecute(Arguments);
end;

{ TMCPToolBase<T> }

constructor TMCPToolBase<T>.Create;
begin
  inherited Create;
end;

destructor TMCPToolBase<T>.Destroy;
begin
  FAnnotations.Free;
  FIcons.Free;
  inherited;
end;

function TMCPToolBase<T>.GetName: string;
begin
  Result := FName;
end;

function TMCPToolBase<T>.GetTitle: string;
begin
  if FTitle <> '' then
    Result := FTitle
  else
    Result := FName;
end;

function TMCPToolBase<T>.GetOutputSchema: TJSONObject;
begin
  Result := nil;
end;

function TMCPToolBase<T>.GetDescription: string;
begin
  Result := FDescription;
end;

function TMCPToolBase<T>.GetInputSchema: TJSONObject;
begin
  Result := TMCPSchemaGenerator.GenerateSchema(T);
end;

function TMCPToolBase<T>.GetAnnotations: TJSONObject;
begin
  Result := FAnnotations;
end;

function TMCPToolBase<T>.GetIcons: TJSONArray;
begin
  Result := FIcons;
end;

function TMCPToolBase<T>.ExecuteWithParams(const Params: T): string;
begin
  raise ENotImplemented.CreateFmt('%s overrides neither ExecuteWithParams nor ExecuteWithContext', [ClassName]);
end;

function TMCPToolBase<T>.ExecuteWithContext(const Params: T; const Context: IMCPRequestContext): TValue;
begin
  Result := ExecuteWithParams(Params);
end;

function TMCPToolBase<T>.Execute(const Arguments: TJSONObject): TValue;
var
  ParamsInstance: T;
begin
  ParamsInstance := TMCPSerializer.Deserialize<T>(Arguments);
  try
    Result := ExecuteWithContext(ParamsInstance, TMCPRequestContext.Current);
  finally
    ParamsInstance.Free;
  end;
end;

function TMCPToolBase<T>.GetParamsClass: TClass;
begin
  Result := T;
end;

{ TMCPToolBase<T, R> }

constructor TMCPToolBase<T, R>.Create;
begin
  inherited Create;
end;

destructor TMCPToolBase<T, R>.Destroy;
begin
  FAnnotations.Free;
  FIcons.Free;
  inherited;
end;

function TMCPToolBase<T, R>.ExecuteWithParams(const Params: T): R;
begin
  raise ENotImplemented.CreateFmt('%s overrides neither ExecuteWithParams nor ExecuteWithContext', [ClassName]);
end;

function TMCPToolBase<T, R>.ExecuteWithContext(const Params: T; const Context: IMCPRequestContext): TValue;
var
  Response: R;
begin
  Response := ExecuteWithParams(Params);
  try
    var JsonObj := TJSONObject.Create;
    try
      TMCPSerializer.Serialize(Response, JsonObj);
    except
      JsonObj.Free;
      raise;
    end;
    Result := TValue.From<TJSONObject>(JsonObj);
  finally
    Response.Free;
  end;
end;

function TMCPToolBase<T, R>.Execute(const Arguments: TJSONObject): TValue;
var
  ParamsInstance: T;
begin
  ParamsInstance := TMCPSerializer.Deserialize<T>(Arguments);
  try
    Result := ExecuteWithContext(ParamsInstance, TMCPRequestContext.Current);
  finally
    ParamsInstance.Free;
  end;
end;

function TMCPToolBase<T, R>.GetDescription: string;
begin
  Result := FDescription;
end;

function TMCPToolBase<T, R>.GetInputSchema: TJSONObject;
begin
  Result := TMCPSchemaGenerator.GenerateSchema(T);
end;

function TMCPToolBase<T, R>.GetName: string;
begin
  Result := FName;
end;

function TMCPToolBase<T, R>.GetTitle: string;
begin
  if FTitle <> '' then
    Result := FTitle
  else
    Result := FName;
end;

function TMCPToolBase<T, R>.GetOutputSchema: TJSONObject;
begin
  Result := TMCPSchemaGenerator.GenerateSchema(R);
end;

function TMCPToolBase<T, R>.GetAnnotations: TJSONObject;
begin
  Result := FAnnotations;
end;

function TMCPToolBase<T, R>.GetIcons: TJSONArray;
begin
  Result := FIcons;
end;

end.
