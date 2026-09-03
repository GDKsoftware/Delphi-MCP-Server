unit MCPServer.Tests.PromptsManager;

interface

uses
  DUnitX.TestFramework,
  System.JSON,
  MCPServer.Types,
  MCPServer.Prompt.Base,
  MCPServer.PromptsManager;

type
  TNoteParams = class
  private
    FText: string;
  public
    [SchemaDescription('The note text')]
    property Text: string read FText write FText;
  end;

  TNotePrompt = class(TMCPPromptBase<TNoteParams>)
  protected
    function ExecuteWithParams(const Params: TNoteParams; Messages: TMCPPromptMessages): string; override;
  public
    constructor Create; override;
  end;

  [TestFixture]
  TPromptsManagerTests = class
  private
    FManager: TMCPPromptsManager;
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    [Test] procedure List_IsInRegistrationOrder_WithArguments;
    [Test] procedure List_CacheHints_ModernOnly;
    [Test] procedure List_Cursor_IsInvalidParams;
    [Test] procedure Get_MissingName_IsInvalidParams;
    [Test] procedure Get_UnknownPrompt_IsInvalidParams_WithName;
    [Test] procedure Get_MissingRequiredArgument_IsInvalidParams;
    [Test] procedure Get_ReturnsDescriptionAndMessages;
    [Test] procedure Get_ResultHasNoCacheHints;
  end;

implementation

uses
  System.Rtti,
  System.SysUtils,
  System.Generics.Collections,
  MCPServer.Errors;

{ TNotePrompt }

constructor TNotePrompt.Create;
begin
  inherited;
  FName := 'note';
  FDescription := 'Wraps a note';
end;

function TNotePrompt.ExecuteWithParams(const Params: TNoteParams; Messages: TMCPPromptMessages): string;
begin
  Messages.AddText('user', Params.Text);
  Result := 'Note prompt';
end;

{ TPromptsManagerTests }

procedure TPromptsManagerTests.Setup;
begin
  FManager := TMCPPromptsManager.Create;
  FManager.AddPrompt(TNotePrompt.Create);
end;

procedure TPromptsManagerTests.TearDown;
begin
  FManager.Free;
end;

procedure TPromptsManagerTests.List_IsInRegistrationOrder_WithArguments;
begin
  var Json := FManager.ListPrompts(nil, TMCPProtocolEra.Legacy).AsType<TJSONObject>;
  try
    var Prompts := Json.GetValue('prompts') as TJSONArray;
    Assert.AreEqual('summarize_logs', Json.GetValue<string>('prompts[0].name'), 'registration order');
    Assert.AreEqual('note', Prompts.Items[Prompts.Count - 1].GetValue<string>('name'));
    var NoteJson := Prompts.Items[Prompts.Count - 1] as TJSONObject;
    Assert.AreEqual('text', NoteJson.GetValue<string>('arguments[0].name'));
    Assert.IsTrue(NoteJson.GetValue<Boolean>('arguments[0].required'));
  finally
    Json.Free;
  end;
end;

procedure TPromptsManagerTests.List_CacheHints_ModernOnly;
begin
  FManager.ListTtlMs := 60000;
  FManager.ListCacheScope := MCP_CACHE_SCOPE_PUBLIC;

  var Legacy := FManager.ListPrompts(nil, TMCPProtocolEra.Legacy).AsType<TJSONObject>;
  var Modern := FManager.ListPrompts(nil, TMCPProtocolEra.Modern).AsType<TJSONObject>;
  try
    Assert.IsNull(Legacy.GetValue('ttlMs'));
    Assert.AreEqual(60000, Modern.GetValue<Integer>('ttlMs'));
    Assert.AreEqual('public', Modern.GetValue<string>('cacheScope'));
  finally
    Legacy.Free;
    Modern.Free;
  end;
end;

procedure TPromptsManagerTests.List_Cursor_IsInvalidParams;
begin
  var Params := TJSONObject.ParseJSONValue('{"cursor":"abc"}') as TJSONObject;
  try
    try
      FManager.ListPrompts(Params, TMCPProtocolEra.Modern).AsType<TJSONObject>.Free;
      Assert.Fail('expected -32602');
    except
      on E: EMCPError do
        Assert.AreEqual(JSONRPC_INVALID_PARAMS, E.Code);
    end;
  finally
    Params.Free;
  end;
end;

procedure TPromptsManagerTests.Get_MissingName_IsInvalidParams;
begin
  try
    FManager.GetPrompt(nil, TMCPProtocolEra.Modern).AsType<TJSONObject>.Free;
    Assert.Fail('expected -32602');
  except
    on E: EMCPError do
      Assert.AreEqual(JSONRPC_INVALID_PARAMS, E.Code);
  end;
end;

procedure TPromptsManagerTests.Get_UnknownPrompt_IsInvalidParams_WithName;
begin
  var Params := TJSONObject.ParseJSONValue('{"name":"nope"}') as TJSONObject;
  try
    try
      FManager.GetPrompt(Params, TMCPProtocolEra.Modern).AsType<TJSONObject>.Free;
      Assert.Fail('expected -32602');
    except
      on E: EMCPError do
      begin
        Assert.AreEqual(JSONRPC_INVALID_PARAMS, E.Code);
        Assert.AreEqual('nope', (E.Data as TJSONObject).GetValue<string>('name'));
      end;
    end;
  finally
    Params.Free;
  end;
end;

procedure TPromptsManagerTests.Get_MissingRequiredArgument_IsInvalidParams;
begin
  var Params := TJSONObject.ParseJSONValue('{"name":"note"}') as TJSONObject;
  try
    try
      FManager.GetPrompt(Params, TMCPProtocolEra.Modern).AsType<TJSONObject>.Free;
      Assert.Fail('expected -32602');
    except
      on E: EMCPError do
      begin
        Assert.AreEqual(JSONRPC_INVALID_PARAMS, E.Code);
        Assert.IsTrue(E.Message.Contains('Missing required parameter "text"'));
      end;
    end;
  finally
    Params.Free;
  end;
end;

procedure TPromptsManagerTests.Get_ReturnsDescriptionAndMessages;
begin
  var Params := TJSONObject.ParseJSONValue('{"name":"note","arguments":{"text":"hi"}}') as TJSONObject;
  try
    var Json := FManager.GetPrompt(Params, TMCPProtocolEra.Legacy).AsType<TJSONObject>;
    try
      Assert.AreEqual('Note prompt', Json.GetValue<string>('description'));
      Assert.AreEqual('hi', Json.GetValue<string>('messages[0].content.text'));
    finally
      Json.Free;
    end;
  finally
    Params.Free;
  end;
end;

procedure TPromptsManagerTests.Get_ResultHasNoCacheHints;
begin
  var Params := TJSONObject.ParseJSONValue('{"name":"note","arguments":{"text":"hi"}}') as TJSONObject;
  try
    var Json := FManager.GetPrompt(Params, TMCPProtocolEra.Modern).AsType<TJSONObject>;
    try
      Assert.IsNull(Json.GetValue('ttlMs'), 'prompts/get is not a cacheable result');
      Assert.IsNull(Json.GetValue('cacheScope'));
    finally
      Json.Free;
    end;
  finally
    Params.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TPromptsManagerTests);

end.
