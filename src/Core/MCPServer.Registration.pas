unit MCPServer.Registration;

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  MCPServer.Tool.Base,
  MCPServer.Resource.Base,
  MCPServer.Prompt.Base,
  MCPServer.Logger;

type
  EMCPRegistryNotFound = class(Exception)
  end;

  TMCPToolClass = class of TMCPToolBase;

  TMCPToolFactory = reference to function: IMCPTool;
  TMCPResourceFactory = reference to function: IMCPResource;
  TMCPPromptFactory = reference to function: IMCPPrompt;
  TMCPResourceTemplateFactory = reference to function: IMCPResourceTemplate;

  TMCPRegistry = class
  private
    class var FTools: TDictionary<string, TMCPToolFactory>;
    class var FToolOrder: TList<string>;
    class var FResources: TDictionary<string, TMCPResourceFactory>;
    class var FResourceOrder: TList<string>;
    class var FPrompts: TDictionary<string, TMCPPromptFactory>;
    class var FPromptOrder: TList<string>;
    class var FResourceTemplates: TDictionary<string, TMCPResourceTemplateFactory>;
    class var FResourceTemplateOrder: TList<string>;

    class constructor Create;
    class destructor Destroy;
  public
    class procedure RegisterTool(const Name: string; Factory: TMCPToolFactory);
    class procedure RegisterResource(const URI: string; Factory: TMCPResourceFactory);
    class procedure RegisterPrompt(const Name: string; Factory: TMCPPromptFactory);
    class procedure RegisterResourceTemplate(const UriTemplate: string; Factory: TMCPResourceTemplateFactory);
    class procedure UnregisterResource(const URI: string);

    class function CreateTool(const Name: string): IMCPTool;
    class function CreateResource(const URI: string): IMCPResource;
    class function CreatePrompt(const Name: string): IMCPPrompt;
    class function CreateResourceTemplate(const UriTemplate: string): IMCPResourceTemplate;

    class function GetToolNames: TArray<string>;
    class function GetResourceURIs: TArray<string>;
    class function GetPromptNames: TArray<string>;
    class function GetResourceTemplateURIs: TArray<string>;

    class function HasTool(const Name: string): Boolean;
    class function HasResource(const URI: string): Boolean;
    class function HasPrompt(const Name: string): Boolean;
  end;

implementation

{ TMCPRegistry }

class constructor TMCPRegistry.Create;
begin
  FTools := TDictionary<string, TMCPToolFactory>.Create;
  FToolOrder := TList<string>.Create;
  FResources := TDictionary<string, TMCPResourceFactory>.Create;
  FResourceOrder := TList<string>.Create;
  FPrompts := TDictionary<string, TMCPPromptFactory>.Create;
  FPromptOrder := TList<string>.Create;
  FResourceTemplates := TDictionary<string, TMCPResourceTemplateFactory>.Create;
  FResourceTemplateOrder := TList<string>.Create;
end;

class destructor TMCPRegistry.Destroy;
begin
  FreeAndNil(FTools);
  FreeAndNil(FToolOrder);
  FreeAndNil(FResources);
  FreeAndNil(FResourceOrder);
  FreeAndNil(FPrompts);
  FreeAndNil(FPromptOrder);
  FreeAndNil(FResourceTemplates);
  FreeAndNil(FResourceTemplateOrder);
end;

class procedure TMCPRegistry.RegisterTool(const Name: string; Factory: TMCPToolFactory);
begin
  if not FTools.ContainsKey(Name) then
    FToolOrder.Add(Name);
  FTools.AddOrSetValue(Name, Factory);
  TLogger.Info('Registered tool: ' + Name);
end;

class procedure TMCPRegistry.RegisterResource(const URI: string; Factory: TMCPResourceFactory);
begin
  if not FResources.ContainsKey(URI) then
    FResourceOrder.Add(URI);
  FResources.AddOrSetValue(URI, Factory);
  TLogger.Info('Registered resource: ' + URI);
end;

class procedure TMCPRegistry.RegisterPrompt(const Name: string; Factory: TMCPPromptFactory);
begin
  if not FPrompts.ContainsKey(Name) then
    FPromptOrder.Add(Name);
  FPrompts.AddOrSetValue(Name, Factory);
  TLogger.Info('Registered prompt: ' + Name);
end;

class procedure TMCPRegistry.RegisterResourceTemplate(const UriTemplate: string;
  Factory: TMCPResourceTemplateFactory);
begin
  if not FResourceTemplates.ContainsKey(UriTemplate) then
    FResourceTemplateOrder.Add(UriTemplate);
  FResourceTemplates.AddOrSetValue(UriTemplate, Factory);
  TLogger.Info('Registered resource template: ' + UriTemplate);
end;

class procedure TMCPRegistry.UnregisterResource(const URI: string);
begin
  if FResources.ContainsKey(URI) then
  begin
    FResources.Remove(URI);
    FResourceOrder.Remove(URI);
    TLogger.Info('Unregistered resource: ' + URI);
  end;
end;

class function TMCPRegistry.CreateTool(const Name: string): IMCPTool;
var
  Factory: TMCPToolFactory;
begin
  if FTools.TryGetValue(Name, Factory) then
    Result := Factory()
  else
    raise EMCPRegistryNotFound.CreateFmt('Tool not found: %s', [Name]);
end;

class function TMCPRegistry.CreateResource(const URI: string): IMCPResource;
var
  Factory: TMCPResourceFactory;
begin
  if FResources.TryGetValue(URI, Factory) then
    Result := Factory()
  else
    raise EMCPRegistryNotFound.CreateFmt('Resource not found: %s', [URI]);
end;

class function TMCPRegistry.CreatePrompt(const Name: string): IMCPPrompt;
var
  Factory: TMCPPromptFactory;
begin
  if FPrompts.TryGetValue(Name, Factory) then
    Result := Factory()
  else
    raise EMCPRegistryNotFound.CreateFmt('Prompt not found: %s', [Name]);
end;

class function TMCPRegistry.CreateResourceTemplate(const UriTemplate: string): IMCPResourceTemplate;
var
  Factory: TMCPResourceTemplateFactory;
begin
  if FResourceTemplates.TryGetValue(UriTemplate, Factory) then
    Result := Factory()
  else
    raise EMCPRegistryNotFound.CreateFmt('Resource template not found: %s', [UriTemplate]);
end;

class function TMCPRegistry.GetToolNames: TArray<string>;
begin
  Result := FToolOrder.ToArray;
end;

class function TMCPRegistry.GetResourceURIs: TArray<string>;
begin
  Result := FResourceOrder.ToArray;
end;

class function TMCPRegistry.GetPromptNames: TArray<string>;
begin
  Result := FPromptOrder.ToArray;
end;

class function TMCPRegistry.GetResourceTemplateURIs: TArray<string>;
begin
  Result := FResourceTemplateOrder.ToArray;
end;

class function TMCPRegistry.HasTool(const Name: string): Boolean;
begin
  Result := FTools.ContainsKey(Name);
end;

class function TMCPRegistry.HasResource(const URI: string): Boolean;
begin
  Result := FResources.ContainsKey(URI);
end;

class function TMCPRegistry.HasPrompt(const Name: string): Boolean;
begin
  Result := FPrompts.ContainsKey(Name);
end;

end.
