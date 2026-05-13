unit MCPServer.ToolsManager;

interface

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
  System.Rtti,
  System.Generics.Collections,
  MCPServer.Types,
  MCPServer.Logger,
  MCPServer.Tool.Base;

type
  TMCPToolsManager = class(TInterfacedObject, IMCPCapabilityManager)
  strict private
    function ExtractToolNameAndArguments(const Params: System.JSON.TJSONObject; out ToolName: string; out Arguments: TJSONObject): Boolean;
    function ExecuteTool(const Tool: IMCPTool; const Arguments: TJSONObject): TValue;
    function BuildToolCallResponse(const ResultValue: TValue): TJSONObject;
    function BuildToolListResponse: TJSONObject;
    function CreateToolJSON(const Tool: IMCPTool): TJSONObject;
  private
    FTools: TDictionary<string, IMCPTool>;
    procedure RegisterTool(const Tool: IMCPTool);
    procedure RegisterBuiltInTools;
  public
    constructor Create;
    destructor Destroy; override;
    
    function GetCapabilityName: string;
    function HandlesMethod(const Method: string): Boolean;
    function ExecuteMethod(const Method: string; const Params: System.JSON.TJSONObject): TValue;
    
    function ListTools: TValue;
    function CallTool(const Params: System.JSON.TJSONObject): TValue;
  end;

implementation

uses
  MCPServer.Registration;

{ TMCPToolsManager }

constructor TMCPToolsManager.Create;
begin
  inherited;
  FTools := TDictionary<string, IMCPTool>.Create;
  RegisterBuiltInTools;
end;

destructor TMCPToolsManager.Destroy;
begin
  FTools.Free;
  inherited;
end;

function TMCPToolsManager.GetCapabilityName: string;
begin
  Result := 'tools';
end;

function TMCPToolsManager.HandlesMethod(const Method: string): Boolean;
begin
  Result := (Method = 'tools/list') or (Method = 'tools/call');
end;

function TMCPToolsManager.ExecuteMethod(const Method: string; const Params: System.JSON.TJSONObject): TValue;
begin
  if Method = 'tools/list' then
    Result := ListTools
  else if Method = 'tools/call' then
    Result := CallTool(Params)
  else
    raise Exception.CreateFmt('Method %s not handled by %s', [Method, GetCapabilityName]);
end;

procedure TMCPToolsManager.RegisterTool(const Tool: IMCPTool);
begin
  FTools.Add(Tool.Name, Tool);
end;

procedure TMCPToolsManager.RegisterBuiltInTools;
var
  Tool: IMCPTool;
  ToolName: string;
begin
  for ToolName in TMCPRegistry.GetToolNames do
  begin
    Tool := TMCPRegistry.CreateTool(ToolName);
    RegisterTool(Tool);
  end;
end;

function TMCPToolsManager.ExtractToolNameAndArguments(const Params: System.JSON.TJSONObject; out ToolName: string; out Arguments: TJSONObject): Boolean;
var
  ArgsValue: TJSONValue;
  NameValue: TJSONValue;
begin
  Result := False;
  ToolName := '';
  Arguments := nil;
  
  if not Assigned(Params) then
    Exit;
    
  NameValue := Params.GetValue('name');
  if Assigned(NameValue) then
  begin
    ToolName := NameValue.Value;
    Result := ToolName <> '';
  end;
  
  ArgsValue := Params.GetValue('arguments');
  if Assigned(ArgsValue) and (ArgsValue is TJSONObject) then
    Arguments := ArgsValue as TJSONObject;
end;

function TMCPToolsManager.ExecuteTool(const Tool: IMCPTool; const Arguments: TJSONObject): TValue;
begin
  try
    Result := Tool.Execute(Arguments);
  except
    on E: Exception do
      Result := 'Error executing tool: ' + E.Message;
  end;
end;

function TMCPToolsManager.BuildToolCallResponse(const ResultValue: TValue): TJSONObject;
var
  ContentArray: TJSONArray;
  ContentItem: TJSONObject;
  ErrorValue: TJSONValue;
  HasError: Boolean;
  JsonResult: TJSONObject;
  TextValue: string;
begin
  Result := TJSONObject.Create;

  if ResultValue.IsType<string> then
  begin
    TextValue := ResultValue.AsString;
    HasError := TextValue.StartsWith('Error:') or TextValue.StartsWith('Error executing tool:');

    ContentArray := TJSONArray.Create;
    Result.AddPair('content', ContentArray);

    ContentItem := TJSONObject.Create;
    ContentArray.AddElement(ContentItem);
    ContentItem.AddPair('type', 'text');
    ContentItem.AddPair('text', TextValue);

    if HasError then
{$IF COMPILERVERSION <= 29}
      Result.AddPair('isError', TJSONTrue.Create);
{$ELSE}
      Result.AddPair('isError', TJSONBool.Create(True));
{$ENDIF}
  end
  else if ResultValue.IsType<TJsonObject> then
  begin
    JsonResult := ResultValue.AsType<TJsonObject>;
    Result.AddPair('structuredContent', TJSONObject(JsonResult.Clone));

    ErrorValue := JsonResult.GetValue('error');
    HasError := Assigned(ErrorValue) and (ErrorValue.Value <> '');
    if HasError then
{$IF COMPILERVERSION <= 29}
      Result.AddPair('isError', TJSONTrue.Create);
{$ELSE}
      Result.AddPair('isError', TJSONBool.Create(True));
{$ENDIF}
  end;

end;

function TMCPToolsManager.CreateToolJSON(const Tool: IMCPTool): TJSONObject;
var
  Schema: TJSONObject;
  SchemaClone: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('name', Tool.Name);
  if Tool.Title <> Tool.Name then
    Result.AddPair('title', Tool.Title);
  Result.AddPair('description', Tool.Description);

  Schema := Tool.InputSchema;
  if Assigned(Schema) then
  begin
    SchemaClone := TJSONObject.ParseJSONValue(Schema.ToJSON) as TJSONObject;
    Result.AddPair('inputSchema', SchemaClone);
    Schema.Free;
  end;
  Schema := Tool.OutputSchema;
  if Assigned(Schema) then
  begin
    SchemaClone := TJSONObject.ParseJSONValue(Schema.ToJSON) as TJSONObject;
    Result.AddPair('outputSchema', SchemaClone);
    Schema.Free;
  end;

end;

function TMCPToolsManager.BuildToolListResponse: TJSONObject;
var
  Tool: IMCPTool;
  ToolsArray: TJSONArray;
  ToolJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  ToolsArray := TJSONArray.Create;
  Result.AddPair('tools', ToolsArray);

  for Tool in FTools.Values do
  begin
    ToolJSON := CreateToolJSON(Tool);
    ToolsArray.AddElement(ToolJSON);
  end;
end;

function TMCPToolsManager.CallTool(const Params: System.JSON.TJSONObject): TValue;
var
  Arguments: TJSONObject;
  ResultValue: TValue;
  Tool: IMCPTool;
  ToolName: string;
begin
  if not ExtractToolNameAndArguments(Params, ToolName, Arguments) then
  begin
    Result := TValue.From<TJSONObject>(BuildToolCallResponse('Error: Invalid tool parameters'));
    Exit;
  end;

  TLogger.Info('MCP CallTool called for tool: ' + ToolName);

  if FTools.TryGetValue(ToolName, Tool) then
    resultValue := ExecuteTool(Tool, Arguments)
  else
    ResultValue := TValue.From('Error: Tool not found: ' + ToolName);
    
  Result := TValue.From<TJSONObject>(BuildToolCallResponse(ResultValue));
end;

function TMCPToolsManager.ListTools: TValue;
begin
  TLogger.Info('MCP ListTools called');
  Result := TValue.From<TJSONObject>(BuildToolListResponse);
end;

end.