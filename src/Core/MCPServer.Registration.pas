unit MCPServer.Registration;

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  MCPServer.Tool.Base,
  MCPServer.Resource.Base,
  MCPServer.Logger;

type
  TMCPToolClass = class of TMCPToolBase;

  TMCPToolFactory = reference to function: IMCPTool;
  TMCPResourceFactory = reference to function: IMCPResource;

  /// Process-wide registry of tool and resource factories.
  ///
  /// The dictionaries exist from the class constructor on, so registration
  /// from unit initialization sections needs no lazy checks. Registration is
  /// not synchronised: register everything before the managers are created.
  /// TMCPToolsManager.Create and TMCPResourcesManager.Create read the
  /// registry once, so in practice that means before TMCPIdHTTPServer.Start
  /// or TMCPStdioTransport.Run.
  TMCPRegistry = class
  private
    class var FTools: TDictionary<string, TMCPToolFactory>;
    class var FResources: TDictionary<string, TMCPResourceFactory>;

    class constructor Create;
    class destructor Destroy;
  public
    class procedure RegisterTool(const Name: string; Factory: TMCPToolFactory);
    class procedure RegisterResource(const URI: string; Factory: TMCPResourceFactory);

    class function CreateTool(const Name: string): IMCPTool;
    class function CreateResource(const URI: string): IMCPResource;

    class function GetToolNames: TArray<string>;
    class function GetResourceURIs: TArray<string>;

    class function HasTool(const Name: string): Boolean;
    class function HasResource(const URI: string): Boolean;
  end;

implementation

{ TMCPRegistry }

class constructor TMCPRegistry.Create;
begin
  FTools := TDictionary<string, TMCPToolFactory>.Create;
  FResources := TDictionary<string, TMCPResourceFactory>.Create;
end;

class destructor TMCPRegistry.Destroy;
begin
  FreeAndNil(FTools);
  FreeAndNil(FResources);
end;

class procedure TMCPRegistry.RegisterTool(const Name: string; Factory: TMCPToolFactory);
begin
  FTools.AddOrSetValue(Name, Factory);
  TLogger.Info('Registered tool: ' + Name);
end;

class procedure TMCPRegistry.RegisterResource(const URI: string; Factory: TMCPResourceFactory);
begin
  FResources.AddOrSetValue(URI, Factory);
  TLogger.Info('Registered resource: ' + URI);
end;

class function TMCPRegistry.CreateTool(const Name: string): IMCPTool;
var
  Factory: TMCPToolFactory;
begin
  if FTools.TryGetValue(Name, Factory) then
    Result := Factory()
  else
    raise Exception.CreateFmt('Tool not found: %s', [Name]);
end;

class function TMCPRegistry.CreateResource(const URI: string): IMCPResource;
var
  Factory: TMCPResourceFactory;
begin
  if FResources.TryGetValue(URI, Factory) then
    Result := Factory()
  else
    raise Exception.CreateFmt('Resource not found: %s', [URI]);
end;

class function TMCPRegistry.GetToolNames: TArray<string>;
begin
  Result := FTools.Keys.ToArray;
end;

class function TMCPRegistry.GetResourceURIs: TArray<string>;
begin
  Result := FResources.Keys.ToArray;
end;

class function TMCPRegistry.HasTool(const Name: string): Boolean;
begin
  Result := FTools.ContainsKey(Name);
end;

class function TMCPRegistry.HasResource(const URI: string): Boolean;
begin
  Result := FResources.ContainsKey(URI);
end;

end.
