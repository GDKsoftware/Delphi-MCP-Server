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

  /// A resource whose read raises.
  TFailingResource = class(TMCPResourceBase<TFailingData>)
  protected
    function GetResourceData: TFailingData; override;
  public
    constructor Create; override;
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
    [Test] procedure Templates_AreEmpty_WithHints;
  end;

implementation

uses
  System.SysUtils,
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

{ TResourcesManagerTests }

procedure TResourcesManagerTests.Setup;
begin
  FManager := TMCPResourcesManager.Create;
  FManager.AddResource(TFailingResource.Create);
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

procedure TResourcesManagerTests.Templates_AreEmpty_WithHints;
begin
  var Modern := FManager.ListResourceTemplates(nil, TMCPProtocolEra.Modern).AsType<TJSONObject>;
  try
    Assert.AreEqual(0, (Modern.GetValue('resourceTemplates') as TJSONArray).Count);
    Assert.AreEqual('private', Modern.GetValue<string>('cacheScope'));
  finally
    Modern.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TResourcesManagerTests);

end.
