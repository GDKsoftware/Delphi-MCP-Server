unit MCPServer.Tool.SubscriptionSamples;

interface

uses
  System.SysUtils,
  System.Rtti,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Base,
  MCPServer.Tool.ContentSamples,
  MCPServer.Prompt.Base;

type
  TDynamicTool = class(TSimpleTextTool)
  public
    constructor Create; override;
  end;

  TDynamicPrompt = class(TMCPPromptBase<TNoParams>)
  protected
    function ExecuteWithParams(const Params: TNoParams; Messages: TMCPPromptMessages): string; override;
  public
    constructor Create; override;
  end;

  TTriggerToolChangeTool = class(TMCPToolBase<TNoParams>)
  protected
    function ExecuteWithContext(const Params: TNoParams; const Context: IMCPRequestContext): TValue; override;
  public
    constructor Create; override;
  end;

  TTriggerPromptChangeTool = class(TMCPToolBase<TNoParams>)
  protected
    function ExecuteWithContext(const Params: TNoParams; const Context: IMCPRequestContext): TValue; override;
  public
    constructor Create; override;
  end;

  TTriggerResourceChangeTool = class(TMCPToolBase<TNoParams>)
  protected
    function ExecuteWithContext(const Params: TNoParams; const Context: IMCPRequestContext): TValue; override;
  public
    constructor Create; override;
  end;

implementation

uses
  MCPServer.Errors,
  MCPServer.Registration,
  MCPServer.ToolsManager,
  MCPServer.PromptsManager,
  MCPServer.ResourcesManager,
  MCPServer.Tool.Result;

const
  DYNAMIC_TOOL_NAME = 'test_dynamic_tool';
  DYNAMIC_PROMPT_NAME = 'test_dynamic_prompt';
  UPDATED_RESOURCE_URI = 'test://static-text';

{ TDynamicTool }

constructor TDynamicTool.Create;
begin
  inherited;
  FName := DYNAMIC_TOOL_NAME;
  FDescription := 'Appears and disappears when test_trigger_tool_change runs';
end;

{ TDynamicPrompt }

constructor TDynamicPrompt.Create;
begin
  inherited;
  FName := DYNAMIC_PROMPT_NAME;
  FDescription := 'Appears and disappears when test_trigger_prompt_change runs';
end;

function TDynamicPrompt.ExecuteWithParams(const Params: TNoParams; Messages: TMCPPromptMessages): string;
begin
  Messages.AddText('user', 'This prompt was added at run time.');
  Result := 'Dynamic prompt';
end;

{ TTriggerToolChangeTool }

constructor TTriggerToolChangeTool.Create;
begin
  inherited;
  FName := 'test_trigger_tool_change';
  FDescription := 'Adds or removes test_dynamic_tool, which notifies subscribed clients that the tool list changed';
end;

function TTriggerToolChangeTool.ExecuteWithContext(const Params: TNoParams; const Context: IMCPRequestContext): TValue;
begin
  var Manager := Context.ManagerRegistry.GetManagerForMethod('tools/list') as TObject;
  if not (Manager is TMCPToolsManager) then
    raise EMCPError.InternalError('No tools manager to change');

  var Tools := TMCPToolsManager(Manager);
  if Tools.HasTool(DYNAMIC_TOOL_NAME) then
  begin
    Tools.RemoveTool(DYNAMIC_TOOL_NAME);
    Result := TMCPToolResult.Text(Format('Removed %s', [DYNAMIC_TOOL_NAME]));
  end
  else
  begin
    Tools.AddTool(TDynamicTool.Create);
    Result := TMCPToolResult.Text(Format('Added %s', [DYNAMIC_TOOL_NAME]));
  end;
end;

{ TTriggerPromptChangeTool }

constructor TTriggerPromptChangeTool.Create;
begin
  inherited;
  FName := 'test_trigger_prompt_change';
  FDescription := 'Adds or removes test_dynamic_prompt, which notifies subscribed clients that the prompt list changed';
end;

function TTriggerPromptChangeTool.ExecuteWithContext(const Params: TNoParams; const Context: IMCPRequestContext): TValue;
begin
  var Manager := Context.ManagerRegistry.GetManagerForMethod('prompts/list') as TObject;
  if not (Manager is TMCPPromptsManager) then
    raise EMCPError.InternalError('No prompts manager to change');

  var Prompts := TMCPPromptsManager(Manager);
  if Prompts.HasPrompt(DYNAMIC_PROMPT_NAME) then
  begin
    Prompts.RemovePrompt(DYNAMIC_PROMPT_NAME);
    Result := TMCPToolResult.Text(Format('Removed %s', [DYNAMIC_PROMPT_NAME]));
  end
  else
  begin
    Prompts.AddPrompt(TDynamicPrompt.Create);
    Result := TMCPToolResult.Text(Format('Added %s', [DYNAMIC_PROMPT_NAME]));
  end;
end;

{ TTriggerResourceChangeTool }

constructor TTriggerResourceChangeTool.Create;
begin
  inherited;
  FName := 'test_trigger_resource_change';
  FDescription := 'Reports test://static-text as updated to the clients subscribed to it';
end;

function TTriggerResourceChangeTool.ExecuteWithContext(const Params: TNoParams; const Context: IMCPRequestContext): TValue;
begin
  var Manager := Context.ManagerRegistry.GetManagerForMethod('resources/list') as TObject;
  if not (Manager is TMCPResourcesManager) then
    raise EMCPError.InternalError('No resources manager to change');

  TMCPResourcesManager(Manager).ResourceUpdated(UPDATED_RESOURCE_URI);
  Result := TMCPToolResult.Text(Format('Reported %s as updated', [UPDATED_RESOURCE_URI]));
end;

initialization
  TMCPRegistry.RegisterTool('test_trigger_tool_change',
    function: IMCPTool
    begin
      Result := TTriggerToolChangeTool.Create;
    end);
  TMCPRegistry.RegisterTool('test_trigger_prompt_change',
    function: IMCPTool
    begin
      Result := TTriggerPromptChangeTool.Create;
    end);
  TMCPRegistry.RegisterTool('test_trigger_resource_change',
    function: IMCPTool
    begin
      Result := TTriggerResourceChangeTool.Create;
    end);

end.
