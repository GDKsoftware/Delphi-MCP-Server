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
  TMCPToolsManager = class(TInterfacedObject, IMCPCapabilityManager, IMCPCapabilityManagerEx, IMCPCapabilityProvider)
  strict private
    FTools: TDictionary<string, IMCPTool>;
    FOrder: TList<string>;
    FListTtlMs: Integer;
    FListCacheScope: string;
    function ErrorResult(const Message: string; Era: TMCPProtocolEra): TJSONObject;
    function ResultToJson(const ResultValue: TValue; Era: TMCPProtocolEra): TJSONObject;
    function ExecuteTool(const Tool: IMCPTool; const Arguments: TJSONObject; Era: TMCPProtocolEra): TJSONObject;
    function BuildToolListResponse(Era: TMCPProtocolEra): TJSONObject;
    function CreateToolJSON(const Tool: IMCPTool): TJSONObject;
    procedure CheckCursor(const Params: TJSONObject);
    procedure ValidateToolName(const Name: string);
    function EraOf(const Context: IMCPRequestContext): TMCPProtocolEra;
  private
    procedure RegisterTool(const Tool: IMCPTool);
    procedure RegisterBuiltInTools;
  public
    constructor Create;
    destructor Destroy; override;

    procedure AddTool(const Tool: IMCPTool);

    function GetCapabilityName: string;
    function HandlesMethod(const Method: string): Boolean;
    function ExecuteMethod(const Method: string; const Params: System.JSON.TJSONObject): TValue;
    function ExecuteMethodWithContext(const Method: string; const Params: TJSONObject;
      const Context: IMCPRequestContext): TValue;
    procedure DescribeCapabilities(const Capabilities: TJSONObject; Era: TMCPProtocolEra);

    function ListTools: TValue; overload;
    function ListTools(const Params: TJSONObject; Era: TMCPProtocolEra): TValue; overload;
    function CallTool(const Params: System.JSON.TJSONObject): TValue; overload;
    function CallTool(const Params: TJSONObject; Era: TMCPProtocolEra): TValue; overload;

    property ListTtlMs: Integer read FListTtlMs write FListTtlMs;
    property ListCacheScope: string read FListCacheScope write FListCacheScope;
  end;

implementation

uses
  System.RegularExpressions,
  MCPServer.Registration,
  MCPServer.RequestContext,
  MCPServer.Errors,
  MCPServer.Tool.Result,
  MCPServer.Schema.Validator;

const
  TOOL_NAME_PATTERN = '^[A-Za-z0-9_.\-]{1,128}$';

{$IFDEF DEBUG}
procedure WarnIfStructuredContentMismatchesSchema(const Tool: IMCPTool; const Result: TJSONObject);
begin
  var OutputSchema := Tool.OutputSchema;
  try
    var StructuredContent := Result.GetValue('structuredContent');
    if not Assigned(OutputSchema) or not Assigned(StructuredContent) then
      Exit;

    var Errors: TArray<string>;
    if not TMCPSchemaValidator.Validate(OutputSchema, StructuredContent, Errors) then
      TLogger.Warning(Format('Tool "%s" structuredContent does not match its outputSchema: %s',
        [Tool.Name, string.Join('; ', Errors)]));
  finally
    OutputSchema.Free;
  end;
end;
{$ENDIF}

{ TMCPToolsManager }

constructor TMCPToolsManager.Create;
begin
  inherited;
  FTools := TDictionary<string, IMCPTool>.Create;
  FOrder := TList<string>.Create;
  FListTtlMs := 0;
  FListCacheScope := MCP_CACHE_SCOPE_PRIVATE;
  RegisterBuiltInTools;
end;

destructor TMCPToolsManager.Destroy;
begin
  FTools.Free;
  FOrder.Free;
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

procedure TMCPToolsManager.DescribeCapabilities(const Capabilities: TJSONObject; Era: TMCPProtocolEra);
begin
  var Tools := TJSONObject.Create;
  Tools.AddPair('listChanged', TJSONBool.Create(False));
  Capabilities.AddPair('tools', Tools);
end;

function TMCPToolsManager.EraOf(const Context: IMCPRequestContext): TMCPProtocolEra;
begin
  if Assigned(Context) then
    Result := Context.Era
  else
    Result := TMCPProtocolEra.Legacy;
end;

function TMCPToolsManager.ExecuteMethod(const Method: string; const Params: System.JSON.TJSONObject): TValue;
begin
  Result := ExecuteMethodWithContext(Method, Params, TMCPRequestContext.Current);
end;

function TMCPToolsManager.ExecuteMethodWithContext(const Method: string; const Params: TJSONObject;
  const Context: IMCPRequestContext): TValue;
begin
  if Method = 'tools/list' then
    Result := ListTools(Params, EraOf(Context))
  else if Method = 'tools/call' then
    Result := CallTool(Params, EraOf(Context))
  else
    raise Exception.CreateFmt('Method %s not handled by %s', [Method, GetCapabilityName]);
end;

procedure TMCPToolsManager.ValidateToolName(const Name: string);
begin
  if not TRegEx.IsMatch(Name, TOOL_NAME_PATTERN) then
    TLogger.Warning(Format('Tool name "%s" is outside the recommended form (1 to 128 characters from A-Z, a-z, 0-9, _, - and .)', [Name]));
end;

procedure TMCPToolsManager.RegisterTool(const Tool: IMCPTool);
begin
  ValidateToolName(Tool.Name);
  if not FTools.ContainsKey(Tool.Name) then
    FOrder.Add(Tool.Name);
  FTools.AddOrSetValue(Tool.Name, Tool);
end;

procedure TMCPToolsManager.RegisterBuiltInTools;
begin
  for var ToolName in TMCPRegistry.GetToolNames do
    RegisterTool(TMCPRegistry.CreateTool(ToolName));
end;

procedure TMCPToolsManager.AddTool(const Tool: IMCPTool);
begin
  RegisterTool(Tool);
end;

procedure TMCPToolsManager.CheckCursor(const Params: TJSONObject);
begin
  if Assigned(Params) and Assigned(Params.GetValue('cursor')) then
    raise EMCPError.InvalidParams('Invalid cursor');
end;

function TMCPToolsManager.ErrorResult(const Message: string; Era: TMCPProtocolEra): TJSONObject;
begin
  var ToolResult := TMCPToolResult.Error(Message);
  try
    Result := ToolResult.ToJson(Era);
  finally
    ToolResult.Free;
  end;
end;

function TMCPToolsManager.ResultToJson(const ResultValue: TValue; Era: TMCPProtocolEra): TJSONObject;
begin
  if ResultValue.IsType<TMCPToolResult> then
  begin
    var ToolResult := ResultValue.AsType<TMCPToolResult>;
    try
      Exit(ToolResult.ToJson(Era));
    finally
      ToolResult.Free;
    end;
  end;

  if ResultValue.IsType<TJSONArray> then
  begin
    Result := TJSONObject.Create;
    Result.AddPair('content', ResultValue.AsType<TJSONArray>);
    Exit;
  end;

  var ToolResult := TMCPToolResult.Create;
  try
    if ResultValue.IsType<string> then
    begin
      var Text := ResultValue.AsString;
      ToolResult.AddText(Text);
      ToolResult.IsError := Text.StartsWith('Error:') or Text.StartsWith('Error executing tool:');
    end
    else if ResultValue.IsType<TJSONObject> then
    begin
      var Structured := ResultValue.AsType<TJSONObject>;
      ToolResult.SetStructuredContent(Structured);
      var ErrorValue := Structured.GetValue('error');
      ToolResult.IsError := Assigned(ErrorValue) and (ErrorValue.Value <> '');
    end
    else if not ResultValue.IsEmpty then
      ToolResult.AddText(ResultValue.ToString);

    Result := ToolResult.ToJson(Era);
  finally
    ToolResult.Free;
  end;
end;

function TMCPToolsManager.ExecuteTool(const Tool: IMCPTool; const Arguments: TJSONObject;
  Era: TMCPProtocolEra): TJSONObject;
var
  ResultValue: TValue;
begin
  var OwnedArguments: TJSONObject := nil;
  var EffectiveArguments := Arguments;
  if not Assigned(EffectiveArguments) then
  begin
    OwnedArguments := TJSONObject.Create;
    EffectiveArguments := OwnedArguments;
  end;

  try
    try
      ResultValue := Tool.Execute(EffectiveArguments);
    except
      on E: EMCPToolError do
        Exit(ErrorResult(E.Message, Era));
      on E: EArgumentException do
        Exit(ErrorResult('Invalid arguments: ' + E.Message, Era));
      on E: EMCPError do
        raise;
      on E: EMCPRequestCancelled do
        raise;
      on E: Exception do
        Exit(ErrorResult('Error executing tool: ' + E.Message, Era));
    end;
    Result := ResultToJson(ResultValue, Era);
    {$IFDEF DEBUG}
    WarnIfStructuredContentMismatchesSchema(Tool, Result);
    {$ENDIF}
  finally
    OwnedArguments.Free;
  end;
end;

function TMCPToolsManager.CreateToolJSON(const Tool: IMCPTool): TJSONObject;
var
  Metadata: IMCPToolMetadata;
begin
  Result := TJSONObject.Create;
  Result.AddPair('name', Tool.Name);
  if Tool.Title <> Tool.Name then
    Result.AddPair('title', Tool.Title);
  Result.AddPair('description', Tool.Description);

  var Schema := Tool.InputSchema;
  if Assigned(Schema) then
    Result.AddPair('inputSchema', Schema);

  Schema := Tool.OutputSchema;
  if Assigned(Schema) then
    Result.AddPair('outputSchema', Schema);

  if Supports(Tool, IMCPToolMetadata, Metadata) then
  begin
    if Assigned(Metadata.Annotations) then
      Result.AddPair('annotations', TJSONObject(Metadata.Annotations.Clone));
    if Assigned(Metadata.Icons) then
      Result.AddPair('icons', TJSONArray(Metadata.Icons.Clone));
  end;
end;

function TMCPToolsManager.BuildToolListResponse(Era: TMCPProtocolEra): TJSONObject;
begin
  Result := TJSONObject.Create;
  var ToolsArray := TJSONArray.Create;
  Result.AddPair('tools', ToolsArray);

  for var Name in FOrder do
    ToolsArray.AddElement(CreateToolJSON(FTools[Name]));

  if Era = TMCPProtocolEra.Modern then
  begin
    Result.AddPair('ttlMs', TJSONNumber.Create(FListTtlMs));
    Result.AddPair('cacheScope', FListCacheScope);
  end;
end;

function TMCPToolsManager.ListTools: TValue;
begin
  Result := ListTools(nil, TMCPProtocolEra.Legacy);
end;

function TMCPToolsManager.ListTools(const Params: TJSONObject; Era: TMCPProtocolEra): TValue;
begin
  TLogger.Info('MCP ListTools called');
  CheckCursor(Params);
  Result := TValue.From<TJSONObject>(BuildToolListResponse(Era));
end;

function TMCPToolsManager.CallTool(const Params: System.JSON.TJSONObject): TValue;
begin
  Result := CallTool(Params, TMCPProtocolEra.Legacy);
end;

function TMCPToolsManager.CallTool(const Params: TJSONObject; Era: TMCPProtocolEra): TValue;
var
  Tool: IMCPTool;
begin
  if not Assigned(Params) then
    raise EMCPError.InvalidParams('params.name is required');

  var NameValue := Params.GetValue('name');
  if not (NameValue is TJSONString) or (TJSONString(NameValue).Value = '') then
    raise EMCPError.InvalidParams('params.name is required and must be a non-empty string');
  var ToolName := TJSONString(NameValue).Value;

  var ArgumentsValue := Params.GetValue('arguments');
  if Assigned(ArgumentsValue) and not (ArgumentsValue is TJSONObject) and not (ArgumentsValue is TJSONNull) then
    raise EMCPError.InvalidParams('params.arguments must be an object');
  var Arguments: TJSONObject := nil;
  if ArgumentsValue is TJSONObject then
    Arguments := TJSONObject(ArgumentsValue);

  if not FTools.TryGetValue(ToolName, Tool) then
    raise EMCPError.UnknownTool(ToolName);

  TLogger.Info('MCP CallTool called for tool: ' + ToolName);
  Result := TValue.From<TJSONObject>(ExecuteTool(Tool, Arguments, Era));
end;

end.
