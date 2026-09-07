unit MCPServer.PromptsManager;

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.JSON,
  System.Rtti,
  System.Generics.Collections,
  MCPServer.Types,
  MCPServer.Logger,
  MCPServer.Prompt.Base;

type
  TMCPPromptsManager = class(TInterfacedObject, IMCPCapabilityManager, IMCPCapabilityManagerEx, IMCPCapabilityProvider)
  strict private
    FPrompts: TDictionary<string, IMCPPrompt>;
    FOrder: TList<string>;
    FLock: TCriticalSection;
    FListTtlMs: Integer;
    FListCacheScope: string;
    FChangeNotifier: IMCPSubscriptionHub;
    procedure NotifyListChanged;
    procedure RegisterPrompt(const Prompt: IMCPPrompt);
    procedure RegisterBuiltInPrompts;
    procedure CheckCursor(const Params: TJSONObject);
    function CreatePromptJSON(const Prompt: IMCPPrompt): TJSONObject;
    function EraOf(const Context: IMCPRequestContext): TMCPProtocolEra;
  public
    constructor Create;
    destructor Destroy; override;

    procedure AddPrompt(const Prompt: IMCPPrompt);
    procedure RemovePrompt(const Name: string);
    function HasPrompt(const Name: string): Boolean;
    function TryGetPrompt(const Name: string; out Prompt: IMCPPrompt): Boolean;

    function GetCapabilityName: string;
    function HandlesMethod(const Method: string): Boolean;
    function ExecuteMethod(const Method: string; const Params: System.JSON.TJSONObject): TValue;
    function ExecuteMethodWithContext(const Method: string; const Params: TJSONObject;
      const Context: IMCPRequestContext): TValue;
    procedure DescribeCapabilities(const Capabilities: TJSONObject; Era: TMCPProtocolEra);

    function ListPrompts: TValue; overload;
    function ListPrompts(const Params: TJSONObject; Era: TMCPProtocolEra): TValue; overload;
    function GetPrompt(const Params: System.JSON.TJSONObject): TValue; overload;
    function GetPrompt(const Params: TJSONObject; Era: TMCPProtocolEra): TValue; overload;

    property ListTtlMs: Integer read FListTtlMs write FListTtlMs;
    property ListCacheScope: string read FListCacheScope write FListCacheScope;
    property ChangeNotifier: IMCPSubscriptionHub read FChangeNotifier write FChangeNotifier;
  end;

implementation

uses
  MCPServer.Registration,
  MCPServer.RequestContext,
  MCPServer.Errors;

const
  CAPABILITY_NAME = 'prompts';


{ TMCPPromptsManager }

constructor TMCPPromptsManager.Create;
begin
  inherited;
  FLock := TCriticalSection.Create;
  FPrompts := TDictionary<string, IMCPPrompt>.Create;
  FOrder := TList<string>.Create;
  FListTtlMs := 0;
  FListCacheScope := MCP_CACHE_SCOPE_PRIVATE;
  RegisterBuiltInPrompts;
end;

destructor TMCPPromptsManager.Destroy;
begin
  FPrompts.Free;
  FOrder.Free;
  FLock.Free;
  inherited;
end;

function TMCPPromptsManager.GetCapabilityName: string;
begin
  Result := CAPABILITY_NAME;
end;

function TMCPPromptsManager.HandlesMethod(const Method: string): Boolean;
begin
  Result := (Method = MCP_METHOD_PROMPTS_LIST) or (Method = MCP_METHOD_PROMPTS_GET);
end;

procedure TMCPPromptsManager.DescribeCapabilities(const Capabilities: TJSONObject; Era: TMCPProtocolEra);
begin
  var Announces := Assigned(FChangeNotifier) and (Era = TMCPProtocolEra.Modern);
  var Prompts := TJSONObject.Create;
  Prompts.AddPair(MCP_KEY_LIST_CHANGED, TJSONBool.Create(Announces));
  Capabilities.AddPair(CAPABILITY_NAME, Prompts);
end;

function TMCPPromptsManager.EraOf(const Context: IMCPRequestContext): TMCPProtocolEra;
begin
  if Assigned(Context) then
    Result := Context.Era
  else
    Result := TMCPProtocolEra.Legacy;
end;

function TMCPPromptsManager.ExecuteMethod(const Method: string; const Params: System.JSON.TJSONObject): TValue;
begin
  Result := ExecuteMethodWithContext(Method, Params, TMCPRequestContext.Current);
end;

function TMCPPromptsManager.ExecuteMethodWithContext(const Method: string; const Params: TJSONObject;
  const Context: IMCPRequestContext): TValue;
begin
  if Method = MCP_METHOD_PROMPTS_LIST then
    Result := ListPrompts(Params, EraOf(Context))
  else if Method = MCP_METHOD_PROMPTS_GET then
    Result := GetPrompt(Params, EraOf(Context))
  else
    raise EMCPError.MethodNotFound(Method);
end;

procedure TMCPPromptsManager.RegisterPrompt(const Prompt: IMCPPrompt);
begin
  FLock.Enter;
  try
    if not FPrompts.ContainsKey(Prompt.Name) then
      FOrder.Add(Prompt.Name);
    FPrompts.AddOrSetValue(Prompt.Name, Prompt);
  finally
    FLock.Leave;
  end;
end;

procedure TMCPPromptsManager.RemovePrompt(const Name: string);
begin
  FLock.Enter;
  try
    if not FPrompts.ContainsKey(Name) then
      Exit;
    FPrompts.Remove(Name);
    FOrder.Remove(Name);
  finally
    FLock.Leave;
  end;
  NotifyListChanged;
end;

function TMCPPromptsManager.HasPrompt(const Name: string): Boolean;
var
  Prompt: IMCPPrompt;
begin
  Result := TryGetPrompt(Name, Prompt);
end;

procedure TMCPPromptsManager.NotifyListChanged;
begin
  if Assigned(FChangeNotifier) then
    FChangeNotifier.PromptsListChanged;
end;

procedure TMCPPromptsManager.RegisterBuiltInPrompts;
begin
  for var PromptName in TMCPRegistry.GetPromptNames do
    RegisterPrompt(TMCPRegistry.CreatePrompt(PromptName));
end;

procedure TMCPPromptsManager.AddPrompt(const Prompt: IMCPPrompt);
begin
  RegisterPrompt(Prompt);
  NotifyListChanged;
end;

function TMCPPromptsManager.TryGetPrompt(const Name: string; out Prompt: IMCPPrompt): Boolean;
begin
  FLock.Enter;
  try
    Result := FPrompts.TryGetValue(Name, Prompt);
  finally
    FLock.Leave;
  end;
end;

procedure TMCPPromptsManager.CheckCursor(const Params: TJSONObject);
begin
  if Assigned(Params) and Assigned(Params.GetValue(MCP_KEY_CURSOR)) then
    raise EMCPError.InvalidParams('Invalid cursor');
end;

function TMCPPromptsManager.CreatePromptJSON(const Prompt: IMCPPrompt): TJSONObject;
var
  Metadata: IMCPPromptMetadata;
begin
  Result := TJSONObject.Create;
  Result.AddPair(MCP_KEY_NAME, Prompt.Name);
  if Prompt.Title <> Prompt.Name then
    Result.AddPair(MCP_KEY_TITLE, Prompt.Title);
  if Prompt.Description <> '' then
    Result.AddPair(MCP_KEY_DESCRIPTION, Prompt.Description);

  var Arguments := Prompt.Arguments;
  if Length(Arguments) > 0 then
  begin
    var ArgumentsArray := TJSONArray.Create;
    Result.AddPair(MCP_KEY_ARGUMENTS, ArgumentsArray);
    for var Arg in Arguments do
    begin
      var ArgObject := TJSONObject.Create;
      ArgumentsArray.AddElement(ArgObject);
      ArgObject.AddPair(MCP_KEY_NAME, Arg.Name);
      if Arg.Description <> '' then
        ArgObject.AddPair(MCP_KEY_DESCRIPTION, Arg.Description);
      ArgObject.AddPair('required', TJSONBool.Create(Arg.Required));
    end;
  end;

  if Supports(Prompt, IMCPPromptMetadata, Metadata) and Assigned(Metadata.Icons) then
    Result.AddPair(MCP_KEY_ICONS, TJSONArray(Metadata.Icons.Clone));
end;

function TMCPPromptsManager.ListPrompts: TValue;
begin
  Result := ListPrompts(nil, TMCPProtocolEra.Legacy);
end;

function TMCPPromptsManager.ListPrompts(const Params: TJSONObject; Era: TMCPProtocolEra): TValue;
begin
  TLogger.Info('MCP ListPrompts called');
  CheckCursor(Params);

  var ResultJSON := TJSONObject.Create;
  try
    var PromptsArray := TJSONArray.Create;
    ResultJSON.AddPair(CAPABILITY_NAME, PromptsArray);
    FLock.Enter;
    try
      for var Name in FOrder do
      begin
        PromptsArray.AddElement(CreatePromptJSON(FPrompts[Name]));
      end;
    finally
      FLock.Leave;
    end;

    if Era = TMCPProtocolEra.Modern then
    begin
      ResultJSON.AddPair(MCP_KEY_TTL_MS, TJSONNumber.Create(FListTtlMs));
      ResultJSON.AddPair(MCP_KEY_CACHE_SCOPE, FListCacheScope);
    end;

    Result := TValue.From<TJSONObject>(ResultJSON);
  except
    ResultJSON.Free;
    raise;
  end;
end;

function TMCPPromptsManager.GetPrompt(const Params: System.JSON.TJSONObject): TValue;
begin
  Result := GetPrompt(Params, TMCPProtocolEra.Legacy);
end;

function TMCPPromptsManager.GetPrompt(const Params: TJSONObject; Era: TMCPProtocolEra): TValue;
var
  Prompt: IMCPPrompt;
begin
  if not Assigned(Params) then
    raise EMCPError.InvalidParams('params.name is required');
  var NameValue := Params.GetValue(MCP_KEY_NAME);
  if not (NameValue is TJSONString) or (TJSONString(NameValue).Value = '') then
    raise EMCPError.InvalidParams('params.name is required and must be a non-empty string');
  var PromptName := TJSONString(NameValue).Value;

  var ArgumentsValue := Params.GetValue(MCP_KEY_ARGUMENTS);
  if Assigned(ArgumentsValue) and not (ArgumentsValue is TJSONObject) and not (ArgumentsValue is TJSONNull) then
    raise EMCPError.InvalidParams('params.arguments must be an object');
  var OwnedArguments: TJSONObject := nil;
  var Arguments: TJSONObject;
  if ArgumentsValue is TJSONObject then
    Arguments := TJSONObject(ArgumentsValue)
  else
  begin
    OwnedArguments := TJSONObject.Create;
    Arguments := OwnedArguments;
  end;

  try
    if not TryGetPrompt(PromptName, Prompt) then
      raise EMCPError.UnknownPrompt(PromptName);

    TLogger.Info('MCP GetPrompt called for prompt: ' + PromptName);

    var Messages := TMCPPromptMessages.Create;
    try
      var Description: string;
      try
        Description := Prompt.Get(Arguments, Messages);
      except
        on E: EArgumentException do
          raise EMCPError.InvalidParams('Invalid arguments: ' + E.Message);
      end;

      var ResultJSON := TJSONObject.Create;
      try
        if Description <> '' then
          ResultJSON.AddPair(MCP_KEY_DESCRIPTION, Description);
        ResultJSON.AddPair('messages', Messages.ToJson);
        Result := TValue.From<TJSONObject>(ResultJSON);
      except
        ResultJSON.Free;
        raise;
      end;
    finally
      Messages.Free;
    end;
  finally
    OwnedArguments.Free;
  end;
end;

end.
