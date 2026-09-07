unit MCPServer.CompletionManager;

interface

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
  System.Rtti,
  System.Generics.Collections,
  MCPServer.Types,
  MCPServer.Logger,
  MCPServer.PromptsManager,
  MCPServer.ResourcesManager;

type
  TMCPCompletionManager = class(TInterfacedObject, IMCPCapabilityManager, IMCPCapabilityManagerEx, IMCPCapabilityProvider)
  strict private
    FPrompts: TMCPPromptsManager;
    FResources: TMCPResourcesManager;
    FPromptsRef: IInterface;
    FResourcesRef: IInterface;
    function EraOf(const Context: IMCPRequestContext): TMCPProtocolEra;
    function ResolveTarget(const Ref: TJSONObject; Era: TMCPProtocolEra): IInterface;
    function ParseContext(const Params: TJSONObject): TArray<TPair<string, string>>;
    function BuildCompletionJSON(const Completion: TMCPCompletion): TJSONObject;
  public
    constructor Create(const Prompts: TMCPPromptsManager; const Resources: TMCPResourcesManager);

    function GetCapabilityName: string;
    function HandlesMethod(const Method: string): Boolean;
    function ExecuteMethod(const Method: string; const Params: System.JSON.TJSONObject): TValue;
    function ExecuteMethodWithContext(const Method: string; const Params: TJSONObject;
      const Context: IMCPRequestContext): TValue;
    procedure DescribeCapabilities(const Capabilities: TJSONObject; Era: TMCPProtocolEra);

    function Complete(const Params: System.JSON.TJSONObject): TValue; overload;
    function Complete(const Params: TJSONObject; Era: TMCPProtocolEra): TValue; overload;
  end;

implementation

uses
  MCPServer.Errors,
  MCPServer.RequestContext,
  MCPServer.Prompt.Base,
  MCPServer.Resource.Base;

const
  CAPABILITY_NAME = 'completions';


{ TMCPCompletionManager }

constructor TMCPCompletionManager.Create(const Prompts: TMCPPromptsManager; const Resources: TMCPResourcesManager);
begin
  inherited Create;
  FPrompts := Prompts;
  FResources := Resources;
  FPromptsRef := Prompts;
  FResourcesRef := Resources;
end;

function TMCPCompletionManager.GetCapabilityName: string;
begin
  Result := CAPABILITY_NAME;
end;

function TMCPCompletionManager.HandlesMethod(const Method: string): Boolean;
begin
  Result := Method = MCP_METHOD_COMPLETION_COMPLETE;
end;

procedure TMCPCompletionManager.DescribeCapabilities(const Capabilities: TJSONObject; Era: TMCPProtocolEra);
begin
  Capabilities.AddPair(CAPABILITY_NAME, TJSONObject.Create);
end;

function TMCPCompletionManager.EraOf(const Context: IMCPRequestContext): TMCPProtocolEra;
begin
  if Assigned(Context) then
    Result := Context.Era
  else
    Result := TMCPProtocolEra.Legacy;
end;

function TMCPCompletionManager.ExecuteMethod(const Method: string; const Params: System.JSON.TJSONObject): TValue;
begin
  Result := ExecuteMethodWithContext(Method, Params, TMCPRequestContext.Current);
end;

function TMCPCompletionManager.ExecuteMethodWithContext(const Method: string; const Params: TJSONObject;
  const Context: IMCPRequestContext): TValue;
begin
  if Method = MCP_METHOD_COMPLETION_COMPLETE then
    Result := Complete(Params, EraOf(Context))
  else
    raise EMCPError.MethodNotFound(Method);
end;

function TMCPCompletionManager.ResolveTarget(const Ref: TJSONObject; Era: TMCPProtocolEra): IInterface;
var
  Prompt: IMCPPrompt;
  Template: IMCPResourceTemplate;
  Resource: IMCPResource;
begin
  var TypeValue := Ref.GetValue(MCP_KEY_TYPE);
  if not (TypeValue is TJSONString) then
    raise EMCPError.InvalidParams('params.ref.type is required');
  var RefType := TJSONString(TypeValue).Value;

  if RefType = 'ref/prompt' then
  begin
    var NameValue := Ref.GetValue(MCP_KEY_NAME);
    if not (NameValue is TJSONString) or (TJSONString(NameValue).Value = '') then
      raise EMCPError.InvalidParams('params.ref.name is required for ref/prompt');
    var PromptName := TJSONString(NameValue).Value;
    if not FPrompts.TryGetPrompt(PromptName, Prompt) then
      raise EMCPError.UnknownPrompt(PromptName);
    Result := Prompt;
  end
  else if RefType = 'ref/resource' then
  begin
    var UriValue := Ref.GetValue(MCP_KEY_URI);
    if not (UriValue is TJSONString) or (TJSONString(UriValue).Value = '') then
      raise EMCPError.InvalidParams('params.ref.uri is required for ref/resource');
    var Uri := TJSONString(UriValue).Value;
    if FResources.TryGetResourceTemplate(Uri, Template) then
      Result := Template
    else if FResources.TryGetResource(Uri, Resource) then
      Result := Resource
    else
      raise EMCPError.ResourceNotFound(Uri, Era);
  end
  else
    raise EMCPError.InvalidParams('params.ref.type must be "ref/prompt" or "ref/resource"');
end;

function TMCPCompletionManager.ParseContext(const Params: TJSONObject): TArray<TPair<string, string>>;
begin
  Result := nil;
  var ContextValue := Params.GetValue('context');
  if not (ContextValue is TJSONObject) then
    Exit;
  var ArgumentsValue := TJSONObject(ContextValue).GetValue(MCP_KEY_ARGUMENTS);
  if not (ArgumentsValue is TJSONObject) then
    Exit;

  var List := TList<TPair<string, string>>.Create;
  try
    for var Pair in TJSONObject(ArgumentsValue) do
      if Pair.JsonValue is TJSONString then
        List.Add(TPair<string, string>.Create(Pair.JsonString.Value, TJSONString(Pair.JsonValue).Value));
    Result := List.ToArray;
  finally
    List.Free;
  end;
end;

function TMCPCompletionManager.BuildCompletionJSON(const Completion: TMCPCompletion): TJSONObject;
begin
  var Values := TJSONArray.Create;
  for var Value in Completion.Values do
    Values.Add(Value);

  Result := TJSONObject.Create;
  Result.AddPair('values', Values);
  if Completion.Total >= 0 then
    Result.AddPair('total', TJSONNumber.Create(Completion.Total));
  Result.AddPair('hasMore', TJSONBool.Create(Completion.HasMore));
end;

function TMCPCompletionManager.Complete(const Params: System.JSON.TJSONObject): TValue;
begin
  Result := Complete(Params, TMCPProtocolEra.Legacy);
end;

function TMCPCompletionManager.Complete(const Params: TJSONObject; Era: TMCPProtocolEra): TValue;
var
  Completable: IMCPCompletable;
begin
  if not Assigned(Params) then
    raise EMCPError.InvalidParams('params.ref is required');

  var RefValue := Params.GetValue('ref');
  if not (RefValue is TJSONObject) then
    raise EMCPError.InvalidParams('params.ref is required and must be an object');

  var ArgumentValue := Params.GetValue('argument');
  if not (ArgumentValue is TJSONObject) then
    raise EMCPError.InvalidParams('params.argument is required and must be an object');
  var Argument := TJSONObject(ArgumentValue);
  var ArgumentNameValue := Argument.GetValue(MCP_KEY_NAME);
  if not (ArgumentNameValue is TJSONString) or (TJSONString(ArgumentNameValue).Value = '') then
    raise EMCPError.InvalidParams('params.argument.name is required and must be a non-empty string');
  var ArgumentValueValue := Argument.GetValue('value');
  if not (ArgumentValueValue is TJSONString) then
    raise EMCPError.InvalidParams('params.argument.value is required and must be a string');

  TLogger.Info('MCP Complete called for argument: ' + TJSONString(ArgumentNameValue).Value);

  var Target := ResolveTarget(TJSONObject(RefValue), Era);
  var Completion: TMCPCompletion;
  if Supports(Target, IMCPCompletable, Completable) then
    Completion := Completable.Complete(TJSONString(ArgumentNameValue).Value, TJSONString(ArgumentValueValue).Value,
      ParseContext(Params))
  else
    Completion := TMCPCompletion.Create(nil);

  var ResultJSON := TJSONObject.Create;
  try
    ResultJSON.AddPair('completion', BuildCompletionJSON(Completion));
    Result := TValue.From<TJSONObject>(ResultJSON);
  except
    ResultJSON.Free;
    raise;
  end;
end;

end.
