unit MCPServer.ResourcesManager;

interface

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
  System.Rtti,
  System.Generics.Collections,
  MCPServer.Types,
  MCPServer.Logger,
  MCPServer.Resource.Base;

type
  TMCPResourcesManager = class(TInterfacedObject, IMCPCapabilityManager)
  private
    FResources: TDictionary<string, IMCPResource>;
    procedure RegisterResource(const Resource: IMCPResource);
    procedure RegisterBuiltInResources;
  public
    constructor Create;
    destructor Destroy; override;
    
    function GetCapabilityName: string;
    function HandlesMethod(const Method: string): Boolean;
    function ExecuteMethod(const Method: string; const Params: System.JSON.TJSONObject): TValue;
    
    function ListResources: TValue;
    function ReadResource(const Params: System.JSON.TJSONObject): TValue;
    function ListResourceTemplates: TValue;
  end;

implementation

uses
  MCPServer.Registration;

{ TMCPResourcesManager }

constructor TMCPResourcesManager.Create;
begin
  inherited;
  FResources := TDictionary<string, IMCPResource>.Create;
  RegisterBuiltInResources;
end;

destructor TMCPResourcesManager.Destroy;
begin
  FResources.Free;
  inherited;
end;

function TMCPResourcesManager.GetCapabilityName: string;
begin
  Result := 'resources';
end;

function TMCPResourcesManager.HandlesMethod(const Method: string): Boolean;
begin
  Result := (Method = 'resources/list') or 
            (Method = 'resources/read') or 
            (Method = 'resources/templates/list');
end;

function TMCPResourcesManager.ExecuteMethod(const Method: string; const Params: System.JSON.TJSONObject): TValue;
begin
  if Method = 'resources/list' then
    Result := ListResources
  else if Method = 'resources/read' then
    Result := ReadResource(Params)
  else if Method = 'resources/templates/list' then
    Result := ListResourceTemplates
  else
    raise Exception.CreateFmt('Method %s not handled by %s', [Method, GetCapabilityName]);
end;

procedure TMCPResourcesManager.RegisterResource(const Resource: IMCPResource);
begin
  FResources.Add(Resource.URI, Resource);
end;

procedure TMCPResourcesManager.RegisterBuiltInResources;
begin
  for var ResourceURI in TMCPRegistry.GetResourceURIs do
  begin
    RegisterResource(TMCPRegistry.CreateResource(ResourceURI));
  end;
end;

function TMCPResourcesManager.ListResources: TValue;
begin
  TLogger.Info('MCP ListResources called');
  
  var ResultJSON := TJSONObject.Create;
  try
    var ResourcesArray := TJSONArray.Create;
    ResultJSON.AddPair('resources', ResourcesArray);
    
    for var Resource in FResources.Values do
    begin
      var ResourceObj := TJSONObject.Create;
      ResourceObj.AddPair('uri', Resource.URI);
      ResourceObj.AddPair('name', Resource.Name);
      ResourceObj.AddPair('description', Resource.Description);
      ResourceObj.AddPair('mimeType', Resource.MimeType);
      ResourcesArray.AddElement(ResourceObj);
    end;
    
    Result := TValue.From<TJSONObject>(ResultJSON);
  except
    ResultJSON.Free;
    raise;
  end;
end;

function TMCPResourcesManager.ReadResource(const Params: System.JSON.TJSONObject): TValue;
begin
  var URIValue := Params.GetValue('uri');
  var URI: string;
  if Assigned(URIValue) then
    URI := URIValue.Value
  else
    URI := '';
  
  TLogger.Info('MCP ReadResource called for URI: ' + URI);
  
  var ResultJSON := TJSONObject.Create;
  try
    var ContentsArray := TJSONArray.Create;
    ResultJSON.AddPair('contents', ContentsArray);
    
    var ContentItem := TJSONObject.Create;
    ContentsArray.AddElement(ContentItem);
    
    var Resource: IMCPResource;
    if FResources.TryGetValue(URI, Resource) then
    begin
      ContentItem.AddPair('uri', Resource.URI);
      ContentItem.AddPair('mimeType', Resource.MimeType);
      
      try
        var ResourceText := Resource.Read;
        ContentItem.AddPair('text', ResourceText);
      except
        on E: Exception do
        begin
          ContentItem.AddPair('text', 'Error reading resource: ' + E.Message);
        end;
      end;
    end
    else
    begin
      ContentItem.AddPair('uri', URI);
      ContentItem.AddPair('mimeType', 'text/plain');
      ContentItem.AddPair('text', 'Error: Resource not found: ' + URI);
    end;
    
    Result := TValue.From<TJSONObject>(ResultJSON);
  except
    ResultJSON.Free;
    raise;
  end;
end;

function TMCPResourcesManager.ListResourceTemplates: TValue;
begin
  TLogger.Info('MCP ListResourceTemplates called');
  
  var ResultJSON := TJSONObject.Create;
  try
    var ResourceTemplatesArray := TJSONArray.Create;
    ResultJSON.AddPair('resourceTemplates', ResourceTemplatesArray);
    
    // Return empty array since this server doesn't support resource templates
    
    Result := TValue.From<TJSONObject>(ResultJSON);
  except
    ResultJSON.Free;
    raise;
  end;
end;

end.