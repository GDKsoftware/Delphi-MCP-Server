unit MCPServer.ResourcesManager;

interface

uses
  System.SysUtils,
  System.SyncObjs,
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
    FLock: TCriticalSection;
    FChangeNotifier: IMCPSubscriptionHub;
    FListTtlMs: Integer;
    FListCacheScope: string;
    procedure NotifyListChanged;
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
    procedure RemoveResource(const URI: string);
    procedure ResourceUpdated(const URI: string);
    procedure AddResourceTemplate(const Template: IMCPResourceTemplate);
    procedure RemoveResourceTemplate(const UriTemplate: string);
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
    property ChangeNotifier: IMCPSubscriptionHub read FChangeNotifier write FChangeNotifier;
  end;

implementation

uses
  MCPServer.Registration,
  MCPServer.RequestContext,
  MCPServer.Errors,
  MCPServer.Mrtr,
  MCPServer.ContentBlocks;

const
  CAPABILITY_NAME = 'resources';


{ TMCPResourcesManager }

constructor TMCPResourcesManager.Create;
begin
  inherited;
  FLock := TCriticalSection.Create;
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
  FLock.Free;
  inherited;
end;

function TMCPResourcesManager.GetCapabilityName: string;
begin
  Result := CAPABILITY_NAME;
end;

function TMCPResourcesManager.HandlesMethod(const Method: string): Boolean;
begin
  Result := (Method = MCP_METHOD_RESOURCES_LIST) or
            (Method = MCP_METHOD_RESOURCES_READ) or
            (Method = MCP_METHOD_RESOURCES_TEMPLATES_LIST);
end;

procedure TMCPResourcesManager.DescribeCapabilities(const Capabilities: TJSONObject; Era: TMCPProtocolEra);
begin
  var Announces := Assigned(FChangeNotifier) and (Era = TMCPProtocolEra.Modern);
  var Resources := TJSONObject.Create;
  Resources.AddPair(MCP_KEY_SUBSCRIBE, TJSONBool.Create(Announces));
  Resources.AddPair(MCP_KEY_LIST_CHANGED, TJSONBool.Create(Announces));
  Capabilities.AddPair(CAPABILITY_NAME, Resources);
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
  if Method = MCP_METHOD_RESOURCES_LIST then
    Result := ListResources(Params, EraOf(Context))
  else if Method = MCP_METHOD_RESOURCES_READ then
    Result := ReadResource(Params, EraOf(Context))
  else if Method = MCP_METHOD_RESOURCES_TEMPLATES_LIST then
    Result := ListResourceTemplates(Params, EraOf(Context))
  else
    raise EMCPError.MethodNotFound(Method);
end;

procedure TMCPResourcesManager.RegisterResource(const Resource: IMCPResource);
begin
  FLock.Enter;
  try
    if not FResources.ContainsKey(Resource.URI) then
      FOrder.Add(Resource.URI);
    FResources.AddOrSetValue(Resource.URI, Resource);
  finally
    FLock.Leave;
  end;
end;

procedure TMCPResourcesManager.RemoveResource(const URI: string);
begin
  FLock.Enter;
  try
    if not FResources.ContainsKey(URI) then
      Exit;
    FResources.Remove(URI);
    FOrder.Remove(URI);
  finally
    FLock.Leave;
  end;
  NotifyListChanged;
end;

procedure TMCPResourcesManager.ResourceUpdated(const URI: string);
begin
  if Assigned(FChangeNotifier) then
    FChangeNotifier.ResourceUpdated(URI);
end;

procedure TMCPResourcesManager.NotifyListChanged;
begin
  if Assigned(FChangeNotifier) then
    FChangeNotifier.ResourcesListChanged;
end;

procedure TMCPResourcesManager.RegisterBuiltInResources;
begin
  for var ResourceURI in TMCPRegistry.GetResourceURIs do
  begin
    RegisterResource(TMCPRegistry.CreateResource(ResourceURI));
  end;
end;

procedure TMCPResourcesManager.RegisterBuiltInResourceTemplates;
begin
  for var UriTemplate in TMCPRegistry.GetResourceTemplateURIs do
  begin
    FTemplates.Add(TMCPRegistry.CreateResourceTemplate(UriTemplate));
  end;
end;

procedure TMCPResourcesManager.AddResource(const Resource: IMCPResource);
begin
  RegisterResource(Resource);
  NotifyListChanged;
end;

procedure TMCPResourcesManager.RemoveResourceTemplate(const UriTemplate: string);
begin
  var Removed := False;
  FLock.Enter;
  try
    for var I := FTemplates.Count - 1 downto 0 do
    begin
      if FTemplates[I].UriTemplate = UriTemplate then
      begin
        FTemplates.Delete(I);
        Removed := True;
      end;
    end;
  finally
    FLock.Leave;
  end;
  if Removed then
    NotifyListChanged;
end;

procedure TMCPResourcesManager.AddResourceTemplate(const Template: IMCPResourceTemplate);
begin
  FLock.Enter;
  try
    FTemplates.Add(Template);
  finally
    FLock.Leave;
  end;
  NotifyListChanged;
end;

function TMCPResourcesManager.TryGetResource(const URI: string; out Resource: IMCPResource): Boolean;
begin
  FLock.Enter;
  try
    Result := FResources.TryGetValue(URI, Resource);
  finally
    FLock.Leave;
  end;
end;

function TMCPResourcesManager.TryGetResourceTemplate(const UriTemplate: string;
  out Template: IMCPResourceTemplate): Boolean;
begin
  Template := nil;
  Result := False;
  FLock.Enter;
  try
    for var Candidate in FTemplates do
    begin
      if Candidate.UriTemplate = UriTemplate then
      begin
        Template := Candidate;
        Exit(True);
      end;
    end;
  finally
    FLock.Leave;
  end;
end;

function TMCPResourcesManager.FindResource(const URI: string): IMCPResource;
var
  Templates: TArray<IMCPResourceTemplate>;
begin
  FLock.Enter;
  try
    if FResources.TryGetValue(URI, Result) then
      Exit;
    Templates := FTemplates.ToArray;
  finally
    FLock.Leave;
  end;

  var Vars := TMCPTemplateVars.Create;
  try
    for var Template in Templates do
    begin
      if Template.Matches(URI, Vars) then
        begin
          Result := Template.CreateResource(URI, Vars);
          Exit;
        end;
    end;
  finally
    Vars.Free;
  end;
  Result := nil;
end;

procedure TMCPResourcesManager.CheckCursor(const Params: TJSONObject);
begin
  if Assigned(Params) and Assigned(Params.GetValue(MCP_KEY_CURSOR)) then
    raise EMCPError.InvalidParams('Invalid cursor');
end;

procedure TMCPResourcesManager.AddListCacheHints(const ResultJSON: TJSONObject; Era: TMCPProtocolEra);
begin
  if Era = TMCPProtocolEra.Modern then
  begin
    ResultJSON.AddPair(MCP_KEY_TTL_MS, TJSONNumber.Create(FListTtlMs));
    ResultJSON.AddPair(MCP_KEY_CACHE_SCOPE, FListCacheScope);
  end;
end;

function TMCPResourcesManager.CreateResourceJSON(const Resource: IMCPResource): TJSONObject;
var
  Metadata: IMCPResourceMetadata;
begin
  Result := TJSONObject.Create;
  Result.AddPair(MCP_KEY_URI, Resource.URI);
  Result.AddPair(MCP_KEY_NAME, Resource.Name);

  if Supports(Resource, IMCPResourceMetadata, Metadata) then
  begin
    if Metadata.Title <> '' then
      Result.AddPair(MCP_KEY_TITLE, Metadata.Title);
  end;
  const HasDescription = (Resource.Description <> '');
  if HasDescription then
    Result.AddPair(MCP_KEY_DESCRIPTION, Resource.Description);
  const HasMimeType = (Resource.MimeType <> '');
  if HasMimeType then
    Result.AddPair(MCP_KEY_MIME_TYPE, Resource.MimeType);
  if Assigned(Metadata) then
  begin
    if Metadata.Size >= 0 then
      Result.AddPair('size', TJSONNumber.Create(Metadata.Size));
    if Assigned(Metadata.Annotations) then
      Result.AddPair(MCP_KEY_ANNOTATIONS, TJSONObject(Metadata.Annotations.Clone));
  end;
end;

function TMCPResourcesManager.CreateResourceTemplateJSON(const Template: IMCPResourceTemplate): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('uriTemplate', Template.UriTemplate);
  Result.AddPair(MCP_KEY_NAME, Template.Name);
  const HasTitle = (Template.Title <> '');
  if HasTitle then
    Result.AddPair(MCP_KEY_TITLE, Template.Title);
  const HasDescription = (Template.Description <> '');
  if HasDescription then
    Result.AddPair(MCP_KEY_DESCRIPTION, Template.Description);
  const HasMimeType = (Template.MimeType <> '');
  if HasMimeType then
    Result.AddPair(MCP_KEY_MIME_TYPE, Template.MimeType);
end;

function TMCPResourcesManager.CreateContentsItem(const Resource: IMCPResource): TJSONObject;
var
  Binary: IMCPBinaryResource;
begin
  Result := TJSONObject.Create;
  try
    Result.AddPair(MCP_KEY_URI, Resource.URI);
    const HasMimeType = (Resource.MimeType <> '');
    if HasMimeType then
      Result.AddPair(MCP_KEY_MIME_TYPE, Resource.MimeType);

    if Supports(Resource, IMCPBinaryResource, Binary) then
      Result.AddPair('blob', TMCPContentBlock.EncodeBlob(Binary.ReadBinary))
    else
      Result.AddPair(MCP_KEY_TEXT, Resource.Read);
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
    ResultJSON.AddPair(CAPABILITY_NAME, ResourcesArray);
    FLock.Enter;
    try
      for var URI in FOrder do
      begin
        ResourcesArray.AddElement(CreateResourceJSON(FResources[URI]));
      end;
    finally
      FLock.Leave;
    end;
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
  var URIValue := Params.GetValue(MCP_KEY_URI);
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

    const IsModern = (Era = TMCPProtocolEra.Modern);
    if IsModern then
    begin
      var TtlMs := 0;
      var CacheScope := MCP_CACHE_SCOPE_PRIVATE;
      if Supports(Resource, IMCPCacheableResource, Cacheable) then
      begin
        TtlMs := Cacheable.TtlMs;
        CacheScope := Cacheable.CacheScope;
      end;
      ResultJSON.AddPair(MCP_KEY_TTL_MS, TJSONNumber.Create(TtlMs));
      ResultJSON.AddPair(MCP_KEY_CACHE_SCOPE, CacheScope);
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
    FLock.Enter;
    try
      for var Template in FTemplates do
      begin
        TemplatesArray.AddElement(CreateResourceTemplateJSON(Template));
      end;
    finally
      FLock.Leave;
    end;
    AddListCacheHints(ResultJSON, Era);
    Result := TValue.From<TJSONObject>(ResultJSON);
  except
    ResultJSON.Free;
    raise;
  end;
end;

end.
