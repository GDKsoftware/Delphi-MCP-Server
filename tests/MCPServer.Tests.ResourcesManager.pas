unit MCPServer.Tests.ResourcesManager;

interface

uses
  DUnitX.TestFramework,
  System.JSON,
  MCPServer.Types,
  MCPServer.Resource.Base,
  MCPServer.ResourcesManager;

type
  TFailingData = class
  end;

  TFailingResource = class(TMCPResourceBase<TFailingData>)
  protected
    function GetResourceData: TFailingData; override;
  public
    constructor Create; override;
  end;

  TEchoTemplateData = class
  private
    FValue: string;
  public
    property Value: string read FValue write FValue;
  end;

  TEchoResource = class(TMCPResourceBase<TEchoTemplateData>)
  private
    FValue: string;
  protected
    function GetResourceData: TEchoTemplateData; override;
  public
    constructor CreateForValue(const AUri, AValue: string);
  end;

  TEchoTemplate = class(TMCPResourceTemplateBase)
  public
    constructor Create; override;
    function CreateResource(const URI: string; Vars: TMCPTemplateVars): IMCPResource; override;
  end;

  [TestFixture]
  TResourcesManagerTests = class
  private
    FManager: TMCPResourcesManager;
    function Read(const Uri: string; Era: TMCPProtocolEra): TJSONObject;
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    [Test] procedure Unknown_Modern_Is32602_WithUri;
    [Test] procedure Unknown_Legacy_Is32002_WithUri;
    [Test] procedure MissingUri_IsInvalidParams;
    [Test] procedure ReadFailure_IsInternalError;
    [Test] procedure Text_ReadsText;
    [Test] procedure Binary_ReadsBlob;
    [Test] procedure Read_CacheHints_ModernOnly_FromResource;
    [Test] procedure List_HasMetadata_AndOmitsEmptyFields;
    [Test] procedure List_CacheHints_ModernOnly;
    [Test] procedure Templates_ListsRegisteredTemplates_WithHints;
    [Test] procedure Templates_Cursor_IsInvalidParams;
    [Test] procedure Read_ViaTemplate_ResolvesWithActualUri;
    [Test] procedure Read_TemplateMismatch_IsNotFound;
    [Test] procedure Read_ViaTemplate_PercentDecodes_KeepsPlusLiteral;
    [Test] procedure Read_ViaTemplate_ConcurrentReads_Succeed;
    [Test] procedure RemoveResourceTemplate_StopsMatching;
  end;

implementation

uses
  System.SysUtils,
  System.Threading,
  System.Generics.Collections,
  MCPServer.Errors;

{ TFailingResource }

constructor TFailingResource.Create;
begin
  inherited;
  FURI := 'test://failing';
  FName := 'Failing';
  FMimeType := 'application/json';
end;

function TFailingResource.GetResourceData: TFailingData;
begin
  raise Exception.Create('disk on fire');
end;

{ TEchoResource }

constructor TEchoResource.CreateForValue(const AUri, AValue: string);
begin
  inherited Create;
  FURI := AUri;
  FName := 'Echo';
  FMimeType := 'application/json';
  FValue := AValue;
end;

function TEchoResource.GetResourceData: TEchoTemplateData;
begin
  Result := TEchoTemplateData.Create;
  Result.Value := FValue;
end;

{ TEchoTemplate }

constructor TEchoTemplate.Create;
begin
  inherited;
  FUriTemplate := 'echo://{value}';
  FName := 'Echo template';
  FDescription := 'Echoes the captured value';
  FMimeType := 'application/json';
end;

function TEchoTemplate.CreateResource(const URI: string; Vars: TMCPTemplateVars): IMCPResource;
begin
  Result := TEchoResource.CreateForValue(URI, Vars['value']);
end;

{ TResourcesManagerTests }

procedure TResourcesManagerTests.Setup;
begin
  FManager := TMCPResourcesManager.Create;
  FManager.AddResource(TFailingResource.Create);
  FManager.AddResourceTemplate(TEchoTemplate.Create);
end;

procedure TResourcesManagerTests.TearDown;
begin
  FManager.Free;
end;

function TResourcesManagerTests.Read(const Uri: string; Era: TMCPProtocolEra): TJSONObject;
begin
  var Params := TJSONObject.Create;
  try
    Params.AddPair('uri', Uri);
    Result := FManager.ReadResource(Params, Era).AsType<TJSONObject>;
  finally
    Params.Free;
  end;
end;

procedure TResourcesManagerTests.Unknown_Modern_Is32602_WithUri;
begin
  try
    Read('test://missing', TMCPProtocolEra.Modern).Free;
    Assert.Fail('expected -32602');
  except
    on E: EMCPError do
    begin
      Assert.AreEqual(JSONRPC_INVALID_PARAMS, E.Code);
      Assert.AreEqual('test://missing', (E.Data as TJSONObject).GetValue<string>('uri'));
    end;
  end;
end;

procedure TResourcesManagerTests.Unknown_Legacy_Is32002_WithUri;
begin
  try
    Read('test://missing', TMCPProtocolEra.Legacy).Free;
    Assert.Fail('expected -32002');
  except
    on E: EMCPError do
    begin
      Assert.AreEqual(MCP_ERROR_RESOURCE_NOT_FOUND_LEGACY, E.Code);
      Assert.AreEqual('test://missing', (E.Data as TJSONObject).GetValue<string>('uri'));
    end;
  end;
end;

procedure TResourcesManagerTests.MissingUri_IsInvalidParams;
begin
  try
    FManager.ReadResource(nil, TMCPProtocolEra.Modern).AsType<TJSONObject>.Free;
    Assert.Fail('expected -32602');
  except
    on E: EMCPError do
      Assert.AreEqual(JSONRPC_INVALID_PARAMS, E.Code);
  end;
end;

procedure TResourcesManagerTests.ReadFailure_IsInternalError;
begin
  try
    Read('test://failing', TMCPProtocolEra.Modern).Free;
    Assert.Fail('expected -32603');
  except
    on E: EMCPError do
    begin
      Assert.AreEqual(JSONRPC_INTERNAL_ERROR, E.Code);
      Assert.IsTrue(E.Message.Contains('disk on fire'));
    end;
  end;
end;

procedure TResourcesManagerTests.Text_ReadsText;
begin
  var Json := Read('test://static-text', TMCPProtocolEra.Legacy);
  try
    Assert.AreEqual('test://static-text', Json.GetValue<string>('contents[0].uri'));
    Assert.AreEqual('text/plain', Json.GetValue<string>('contents[0].mimeType'));
    Assert.IsTrue(Json.GetValue<string>('contents[0].text').Contains('static text resource'));
    Assert.IsNull(Json.FindValue('contents[0].blob'));
    Assert.IsNull(Json.GetValue('ttlMs'));
  finally
    Json.Free;
  end;
end;

procedure TResourcesManagerTests.Binary_ReadsBlob;
begin
  var Json := Read('test://static-binary', TMCPProtocolEra.Modern);
  try
    Assert.AreEqual('image/png', Json.GetValue<string>('contents[0].mimeType'));
    Assert.IsTrue(Json.GetValue<string>('contents[0].blob').StartsWith('iVBORw0KGgo'));
    Assert.IsNull(Json.FindValue('contents[0].text'));
  finally
    Json.Free;
  end;
end;

procedure TResourcesManagerTests.Read_CacheHints_ModernOnly_FromResource;
begin
  var ProjectInfo := Read('project://info', TMCPProtocolEra.Modern);
  var Logs := Read('logs://recent', TMCPProtocolEra.Modern);
  try
    Assert.AreEqual(3600000, ProjectInfo.GetValue<Integer>('ttlMs'));
    Assert.AreEqual('public', ProjectInfo.GetValue<string>('cacheScope'));
    Assert.AreEqual(0, Logs.GetValue<Integer>('ttlMs'));
    Assert.AreEqual('private', Logs.GetValue<string>('cacheScope'));
  finally
    ProjectInfo.Free;
    Logs.Free;
  end;
end;

procedure TResourcesManagerTests.List_HasMetadata_AndOmitsEmptyFields;
begin
  var Json := FManager.ListResources(nil, TMCPProtocolEra.Legacy).AsType<TJSONObject>;
  try
    var Resources := Json.GetValue('resources') as TJSONArray;
    Assert.AreEqual('server://status', Json.GetValue<string>('resources[0].uri'), 'registration order');
    var Found := False;
    for var Item in Resources do
      if Item.GetValue<string>('uri') = 'test://static-text' then
      begin
        Found := True;
        Assert.AreEqual('Static text resource', Item.GetValue<string>('title'));
      end;
    Assert.IsTrue(Found);
    var Failing := Resources.Items[Resources.Count - 1] as TJSONObject;
    Assert.AreEqual('test://failing', Failing.GetValue<string>('uri'));
    Assert.IsNull(Failing.GetValue('description'), 'empty description is omitted');
    Assert.IsNull(Failing.GetValue('title'));
    Assert.IsNull(Failing.GetValue('size'));
  finally
    Json.Free;
  end;
end;

procedure TResourcesManagerTests.List_CacheHints_ModernOnly;
begin
  var Legacy := FManager.ListResources(nil, TMCPProtocolEra.Legacy).AsType<TJSONObject>;
  var Modern := FManager.ListResources(nil, TMCPProtocolEra.Modern).AsType<TJSONObject>;
  try
    Assert.IsNull(Legacy.GetValue('cacheScope'));
    Assert.AreEqual(0, Modern.GetValue<Integer>('ttlMs'));
    Assert.AreEqual('private', Modern.GetValue<string>('cacheScope'));
  finally
    Legacy.Free;
    Modern.Free;
  end;
end;

procedure TResourcesManagerTests.Templates_ListsRegisteredTemplates_WithHints;
begin
  var Modern := FManager.ListResourceTemplates(nil, TMCPProtocolEra.Modern).AsType<TJSONObject>;
  try
    var Templates := Modern.GetValue('resourceTemplates') as TJSONArray;
    Assert.AreEqual('logs://{level}', Modern.GetValue<string>('resourceTemplates[0].uriTemplate'),
      'the built-in template is listed first');
    var LastTemplate := Templates.Items[Templates.Count - 1] as TJSONObject;
    Assert.AreEqual('echo://{value}', LastTemplate.GetValue<string>('uriTemplate'));
    Assert.AreEqual('Echo template', LastTemplate.GetValue<string>('name'));
    Assert.AreEqual('Echoes the captured value', LastTemplate.GetValue<string>('description'));
    Assert.AreEqual('application/json', LastTemplate.GetValue<string>('mimeType'));
    Assert.AreEqual('private', Modern.GetValue<string>('cacheScope'));
  finally
    Modern.Free;
  end;
end;

procedure TResourcesManagerTests.Templates_Cursor_IsInvalidParams;
begin
  var Params := TJSONObject.ParseJSONValue('{"cursor":"abc"}') as TJSONObject;
  try
    try
      FManager.ListResourceTemplates(Params, TMCPProtocolEra.Modern).AsType<TJSONObject>.Free;
      Assert.Fail('expected -32602');
    except
      on E: EMCPError do
        Assert.AreEqual(JSONRPC_INVALID_PARAMS, E.Code);
    end;
  finally
    Params.Free;
  end;
end;

procedure TResourcesManagerTests.Read_ViaTemplate_ResolvesWithActualUri;
begin
  var Json := Read('echo://hello', TMCPProtocolEra.Modern);
  try
    Assert.AreEqual('echo://hello', Json.GetValue<string>('contents[0].uri'));
    Assert.AreEqual('application/json', Json.GetValue<string>('contents[0].mimeType'));
    Assert.AreEqual('{"value":"hello"}', Json.GetValue<string>('contents[0].text'));
  finally
    Json.Free;
  end;
end;

procedure TResourcesManagerTests.Read_ViaTemplate_PercentDecodes_KeepsPlusLiteral;
begin
  var Json := Read('echo://a%20b+c%2Fd', TMCPProtocolEra.Modern);
  try
    Assert.AreEqual('{"value":"a b+c/d"}', Json.GetValue<string>('contents[0].text'));
  finally
    Json.Free;
  end;
end;

procedure TResourcesManagerTests.Read_ViaTemplate_ConcurrentReads_Succeed;
const
  READS = 400;
begin
  TParallel.For(1, READS,
    procedure(Index: Integer)
    begin
      var Json := Read(Format('echo://item%d', [Index]), TMCPProtocolEra.Modern);
      try
        Assert.AreEqual(Format('{"value":"item%d"}', [Index]), Json.GetValue<string>('contents[0].text'));
      finally
        Json.Free;
      end;
    end);
end;

procedure TResourcesManagerTests.RemoveResourceTemplate_StopsMatching;
begin
  FManager.RemoveResourceTemplate('echo://{value}');
  try
    Read('echo://hello', TMCPProtocolEra.Modern).Free;
    Assert.Fail('the template is gone');
  except
    on E: EMCPError do
      Assert.AreEqual(JSONRPC_INVALID_PARAMS, E.Code);
  end;
end;

procedure TResourcesManagerTests.Read_TemplateMismatch_IsNotFound;
begin
  try
    Read('echo://a/b', TMCPProtocolEra.Modern).Free;
    Assert.Fail('expected -32602: {value} does not match a path with a slash');
  except
    on E: EMCPError do
      Assert.AreEqual(JSONRPC_INVALID_PARAMS, E.Code);
  end;
end;

end.
