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
  TMCPResourcesManager = class(TInterfacedObject, IMCPCapabilityManager, IMCPCapabilityManagerEx, IMCPCapabilityProvider)
  private
    FResources: TDictionary<string, IMCPResource>;
    FOrder: TList<string>;
    FTemplates: TList<IMCPResourceTemplate>;
    FListTtlMs: Integer;
    FListCacheScope: string;
    procedure RegisterResource(const Resource: IMCPResource);
    procedure RegisterBuiltInResources;
    procedure RegisterBuiltInResourceTemplates;
    procedure CheckCursor(const Params: TJSONObject);
    procedure AddListCacheHints(const ResultJSON: TJSONObject; Era: TMCPProtocolEra);
    function CreateResourceJSON(const Resource: IMCPResource): TJSONObject;
    function CreateResourceTemplateJSON(const Template: IMCPResourceTemplate): TJSONObject;
    function CreateContentsItem(const Resource: IMCPResource): TJSONObject;
    function FindResource(const URI: string): IMCPResource;
    function EraOf(const Context: IMCPRequestContext): TMCPProtocolEra;
  public
    constructor Create;
    destructor Destroy; override;

    procedure AddResource(const Resource: IMCPResource);
    procedure AddResourceTemplate(const Template: IMCPResourceTemplate);
    function TryGetResource(const URI: string; out Resource: IMCPResource): Boolean;
    function TryGetResourceTemplate(const UriTemplate: string; out Template: IMCPResourceTemplate): Boolean;

    function GetCapabilityName: string;
    function HandlesMethod(const Method: string): Boolean;
    function ExecuteMethod(const Method: string; const Params: System.JSON.TJSONObject): TValue;
    function ExecuteMethodWithContext(const Method: string; const Params: TJSONObject;
      const Context: IMCPRequestContext): TValue;
    procedure DescribeCapabilities(const Capabilities: TJSONObject; Era: TMCPProtocolEra);

    function ListResources: TValue; overload;
    function ListResources(const Params: TJSONObject; Era: TMCPProtocolEra): TValue; overload;
    function ReadResource(const Params: System.JSON.TJSONObject): TValue; overload;
    function ReadResource(const Params: TJSONObject; Era: TMCPProtocolEra): TValue; overload;
    function ListResourceTemplates: TValue; overload;
    function ListResourceTemplates(const Params: TJSONObject; Era: TMCPProtocolEra): TValue; overload;

    property ListTtlMs: Integer read FListTtlMs write FListTtlMs;
    property ListCacheScope: string read FListCacheScope write FListCacheScope;
  end;

implementation

uses
  MCPServer.Registration,
  MCPServer.RequestContext,
  MCPServer.Errors,
  MCPServer.Mrtr,
  MCPServer.ContentBlocks;

{ TMCPResourcesManager }

constructor TMCPResourcesManager.Create;
begin
  inherited;
  FResources := TDictionary<string, IMCPResource>.Create;
  FOrder := TList<string>.Create;
  FTemplates := TList<IMCPResourceTemplate>.Create;
  FListTtlMs := 0;
  FListCacheScope := MCP_CACHE_SCOPE_PRIVATE;
  RegisterBuiltInResources;
  RegisterBuiltInResourceTemplates;
end;

destructor TMCPResourcesManager.Destroy;
begin
  FResources.Free;
  FOrder.Free;
  FTemplates.Free;
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

procedure TMCPResourcesManager.DescribeCapabilities(const Capabilities: TJSONObject; Era: TMCPProtocolEra);
begin
  var Resources := TJSONObject.Create;
  Resources.AddPair('subscribe', TJSONBool.Create(False));
  Resources.AddPair('listChanged', TJSONBool.Create(False));
  Capabilities.AddPair('resources', Resources);
end;

function TMCPResourcesManager.EraOf(const Context: IMCPRequestContext): TMCPProtocolEra;
begin
  if Assigned(Context) then
    Result := Context.Era
  else
    Result := TMCPProtocolEra.Legacy;
end;

function TMCPResourcesManager.ExecuteMethod(const Method: string; const Params: System.JSON.TJSONObject): TValue;
begin
  Result := ExecuteMethodWithContext(Method, Params, TMCPRequestContext.Current);
end;

function TMCPResourcesManager.ExecuteMethodWithContext(const Method: string; const Params: TJSONObject;
  const Context: IMCPRequestContext): TValue;
begin
  if Method = 'resources/list' then
    Result := ListResources(Params, EraOf(Context))
  else if Method = 'resources/read' then
    Result := ReadResource(Params, EraOf(Context))
  else if Method = 'resources/templates/list' then
    Result := ListResourceTemplates(Params, EraOf(Context))
  else
    raise Exception.CreateFmt('Method %s not handled by %s', [Method, GetCapabilityName]);
end;

procedure TMCPResourcesManager.RegisterResource(const Resource: IMCPResource);
begin
  if not FResources.ContainsKey(Resource.URI) then
    FOrder.Add(Resource.URI);
  FResources.AddOrSetValue(Resource.URI, Resource);
end;

procedure TMCPResourcesManager.RegisterBuiltInResources;
begin
  for var ResourceURI in TMCPRegistry.GetResourceURIs do
    RegisterResource(TMCPRegistry.CreateResource(ResourceURI));
end;

procedure TMCPResourcesManager.RegisterBuiltInResourceTemplates;
begin
  for var UriTemplate in TMCPRegistry.GetResourceTemplateURIs do
    FTemplates.Add(TMCPRegistry.CreateResourceTemplate(UriTemplate));
end;

procedure TMCPResourcesManager.AddResource(const Resource: IMCPResource);
begin
  RegisterResource(Resource);
end;

procedure TMCPResourcesManager.AddResourceTemplate(const Template: IMCPResourceTemplate);
begin
  FTemplates.Add(Template);
end;

function TMCPResourcesManager.TryGetResource(const URI: string; out Resource: IMCPResource): Boolean;
begin
  Result := FResources.TryGetValue(URI, Resource);
end;

function TMCPResourcesManager.TryGetResourceTemplate(const UriTemplate: string;
  out Template: IMCPResourceTemplate): Boolean;
begin
  for var Candidate in FTemplates do
    if Candidate.UriTemplate = UriTemplate then
    begin
      Template := Candidate;
      Exit(True);
    end;
  Template := nil;
  Result := False;
end;

function TMCPResourcesManager.FindResource(const URI: string): IMCPResource;
begin
  if FResources.TryGetValue(URI, Result) then
    Exit;

  var Vars := TMCPTemplateVars.Create;
  try
    for var Template in FTemplates do
      if Template.Matches(URI, Vars) then
        Exit(Template.CreateResource(URI, Vars));
  finally
    Vars.Free;
  end;
  Result := nil;
end;

procedure TMCPResourcesManager.CheckCursor(const Params: TJSONObject);
begin
  if Assigned(Params) and Assigned(Params.GetValue('cursor')) then
    raise EMCPError.InvalidParams('Invalid cursor');
end;

procedure TMCPResourcesManager.AddListCacheHints(const ResultJSON: TJSONObject; Era: TMCPProtocolEra);
begin
  if Era = TMCPProtocolEra.Modern then
  begin
    ResultJSON.AddPair('ttlMs', TJSONNumber.Create(FListTtlMs));
    ResultJSON.AddPair('cacheScope', FListCacheScope);
  end;
end;

function TMCPResourcesManager.CreateResourceJSON(const Resource: IMCPResource): TJSONObject;
var
  Metadata: IMCPResourceMetadata;
begin
  Result := TJSONObject.Create;
  Result.AddPair('uri', Resource.URI);
  Result.AddPair('name', Resource.Name);

  if Supports(Resource, IMCPResourceMetadata, Metadata) then
  begin
    if Metadata.Title <> '' then
      Result.AddPair('title', Metadata.Title);
  end;
  if Resource.Description <> '' then
    Result.AddPair('description', Resource.Description);
  if Resource.MimeType <> '' then
    Result.AddPair('mimeType', Resource.MimeType);
  if Assigned(Metadata) then
  begin
    if Metadata.Size >= 0 then
      Result.AddPair('size', TJSONNumber.Create(Metadata.Size));
    if Assigned(Metadata.Annotations) then
      Result.AddPair('annotations', TJSONObject(Metadata.Annotations.Clone));
  end;
end;

function TMCPResourcesManager.CreateResourceTemplateJSON(const Template: IMCPResourceTemplate): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('uriTemplate', Template.UriTemplate);
  Result.AddPair('name', Template.Name);
  if Template.Title <> '' then
    Result.AddPair('title', Template.Title);
  if Template.Description <> '' then
    Result.AddPair('description', Template.Description);
  if Template.MimeType <> '' then
    Result.AddPair('mimeType', Template.MimeType);
end;

function TMCPResourcesManager.CreateContentsItem(const Resource: IMCPResource): TJSONObject;
var
  Binary: IMCPBinaryResource;
begin
  Result := TJSONObject.Create;
  try
    Result.AddPair('uri', Resource.URI);
    if Resource.MimeType <> '' then
      Result.AddPair('mimeType', Resource.MimeType);

    if Supports(Resource, IMCPBinaryResource, Binary) then
      Result.AddPair('blob', EncodeBase64Blob(Binary.ReadBinary))
    else
      Result.AddPair('text', Resource.Read);
  except
    Result.Free;
    raise;
  end;
end;

function TMCPResourcesManager.ListResources: TValue;
begin
  Result := ListResources(nil, TMCPProtocolEra.Legacy);
end;

function TMCPResourcesManager.ListResources(const Params: TJSONObject; Era: TMCPProtocolEra): TValue;
begin
  TLogger.Info('MCP ListResources called');
  CheckCursor(Params);

  var ResultJSON := TJSONObject.Create;
  try
    var ResourcesArray := TJSONArray.Create;
    ResultJSON.AddPair('resources', ResourcesArray);
    for var URI in FOrder do
      ResourcesArray.AddElement(CreateResourceJSON(FResources[URI]));
    AddListCacheHints(ResultJSON, Era);

    Result := TValue.From<TJSONObject>(ResultJSON);
  except
    ResultJSON.Free;
    raise;
  end;
end;

function TMCPResourcesManager.ReadResource(const Params: System.JSON.TJSONObject): TValue;
begin
  Result := ReadResource(Params, TMCPProtocolEra.Legacy);
end;

function TMCPResourcesManager.ReadResource(const Params: TJSONObject; Era: TMCPProtocolEra): TValue;
var
  Resource: IMCPResource;
  Cacheable: IMCPCacheableResource;
begin
  if not Assigned(Params) then
    raise EMCPError.InvalidParams('params.uri is required');
  var URIValue := Params.GetValue('uri');
  if not (URIValue is TJSONString) or (TJSONString(URIValue).Value = '') then
    raise EMCPError.InvalidParams('params.uri is required and must be a non-empty string');
  var URI := TJSONString(URIValue).Value;

  TLogger.Info('MCP ReadResource called for URI: ' + URI);

  Resource := FindResource(URI);
  if not Assigned(Resource) then
    raise EMCPError.ResourceNotFound(URI, Era);

  var ResultJSON := TJSONObject.Create;
  try
    var ContentsArray := TJSONArray.Create;
    ResultJSON.AddPair('contents', ContentsArray);
    try
      ContentsArray.AddElement(CreateContentsItem(Resource));
    except
      on E: EMCPError do
        raise;
      on E: EMCPRequestCancelled do
        raise;
      on E: EMCPInputRequired do
        raise;
      on E: Exception do
        raise EMCPError.InternalError('Error reading resource: ' + E.Message);
    end;

    if Era = TMCPProtocolEra.Modern then
    begin
      var TtlMs := 0;
      var CacheScope := MCP_CACHE_SCOPE_PRIVATE;
      if Supports(Resource, IMCPCacheableResource, Cacheable) then
      begin
        TtlMs := Cacheable.TtlMs;
        CacheScope := Cacheable.CacheScope;
      end;
      ResultJSON.AddPair('ttlMs', TJSONNumber.Create(TtlMs));
      ResultJSON.AddPair('cacheScope', CacheScope);
    end;

    Result := TValue.From<TJSONObject>(ResultJSON);
  except
    ResultJSON.Free;
    raise;
  end;
end;

function TMCPResourcesManager.ListResourceTemplates: TValue;
begin
  Result := ListResourceTemplates(nil, TMCPProtocolEra.Legacy);
end;

function TMCPResourcesManager.ListResourceTemplates(const Params: TJSONObject; Era: TMCPProtocolEra): TValue;
begin
  TLogger.Info('MCP ListResourceTemplates called');
  CheckCursor(Params);

  var ResultJSON := TJSONObject.Create;
  try
    var TemplatesArray := TJSONArray.Create;
    ResultJSON.AddPair('resourceTemplates', TemplatesArray);
    for var Template in FTemplates do
      TemplatesArray.AddElement(CreateResourceTemplateJSON(Template));
    AddListCacheHints(ResultJSON, Era);
    Result := TValue.From<TJSONObject>(ResultJSON);
  except
    ResultJSON.Free;
    raise;
  end;
end;

end.
