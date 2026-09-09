unit MCPServer.Tests.Subscriptions;

interface

uses
  DUnitX.TestFramework,
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.JSON,
  MCPServer.Types,
  MCPServer.RequestContext,
  MCPServer.SubscriptionsManager;

type
  TLockedSink = class(TInterfacedObject, IMCPMessageSink, IMCPKeepAlive)
  strict private
    FLock: TCriticalSection;
    FMessages: TStringList;
    FKeepAlives: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Send(const Json: string);
    procedure KeepAlive;
    function Messages: TArray<string>;
    function Count: Integer;
    property KeepAlives: Integer read FKeepAlives;
  end;

  TRecordingHub = class(TInterfacedObject, IMCPSubscriptionHub)
  private
    FEvents: TStringList;
  public
    constructor Create;
    destructor Destroy; override;
    procedure ToolsListChanged;
    procedure PromptsListChanged;
    procedure ResourcesListChanged;
    procedure ResourceUpdated(const Uri: string);
    procedure CloseAll(const Reason: string);
    function ActiveCount: Integer;
    property Events: TStringList read FEvents;
  end;

  [TestFixture]
  TSubscriptionsTests = class
  private
    FManager: TMCPSubscriptionsManager;
    FManagerRef: IInterface;
    FSink: TLockedSink;
    FSinkRef: IMCPMessageSink;
    FContext: IMCPRequestContext;
    FResult: TJSONObject;
    FError: string;
    FThread: TThread;
    procedure StartListen(const ParamsJson: string);
    procedure WaitUntilOpen;
    procedure JoinListen;
    function Parse(const Json: string): TJSONObject;
    function SubscriptionIdOf(const Json: TJSONObject; const MetaPath: string): Integer;
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    [Test]
    procedure Filter_FromJson_HonoursBooleansAndUris;

    [Test]
    procedure Listen_AckFirst_ThenTaggedNotifications_ThenCompletion;

    [Test]
    procedure Listen_UnrequestedNotifications_AreNotSent;

    [Test]
    procedure Listen_Cancel_EndsTheWait;

    [Test]
    procedure Listen_KeepAlive_OnInterval;

    [Test]
    procedure Listen_WithoutSink_IsInvalidRequest;

    [Test]
    procedure Listen_NotificationsNotObject_IsInvalidParams;

    [Test]
    procedure Managers_NotifyTheHub_AndAnnounceCapabilities;
  end;

implementation

uses
  MCPServer.Errors,
  MCPServer.ToolsManager,
  MCPServer.PromptsManager,
  MCPServer.ResourcesManager,
  MCPServer.Tool.ContentSamples,
  MCPServer.Prompt.ContentSamples,
  MCPServer.Tests.Support;

const
  MODERN_META = TMCPTestMeta.MODERN_FIELDS;
  WAIT_MS = 3000;

{ TLockedSink }

constructor TLockedSink.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FMessages := TStringList.Create;
end;

destructor TLockedSink.Destroy;
begin
  FMessages.Free;
  FLock.Free;
  inherited;
end;

procedure TLockedSink.Send(const Json: string);
begin
  FLock.Enter;
  try
    FMessages.Add(Json);
  finally
    FLock.Leave;
  end;
end;

procedure TLockedSink.KeepAlive;
begin
  AtomicIncrement(FKeepAlives);
end;

function TLockedSink.Messages: TArray<string>;
begin
  FLock.Enter;
  try
    Result := FMessages.ToStringArray;
  finally
    FLock.Leave;
  end;
end;

function TLockedSink.Count: Integer;
begin
  Result := Integer(Length(Messages));
end;

{ TRecordingHub }

constructor TRecordingHub.Create;
begin
  inherited Create;
  FEvents := TStringList.Create;
end;

destructor TRecordingHub.Destroy;
begin
  FEvents.Free;
  inherited;
end;

procedure TRecordingHub.ToolsListChanged;
begin
  FEvents.Add('tools');
end;

procedure TRecordingHub.PromptsListChanged;
begin
  FEvents.Add('prompts');
end;

procedure TRecordingHub.ResourcesListChanged;
begin
  FEvents.Add('resources');
end;

procedure TRecordingHub.ResourceUpdated(const Uri: string);
begin
  FEvents.Add('updated:' + Uri);
end;

procedure TRecordingHub.CloseAll(const Reason: string);
begin
  FEvents.Add('close');
end;

function TRecordingHub.ActiveCount: Integer;
begin
  Result := 0;
end;

{ TSubscriptionsTests }

procedure TSubscriptionsTests.Setup;
begin
  FManager := TMCPSubscriptionsManager.Create;
  FManagerRef := FManager;
  FSink := TLockedSink.Create;
  FSinkRef := FSink;
  FResult := nil;
  FError := '';
  FThread := nil;
end;

procedure TSubscriptionsTests.TearDown;
begin
  FManager.CloseAll('teardown');
  JoinListen;
  FResult.Free;
  FContext := nil;
  FSinkRef := nil;
  FManagerRef := nil;
end;

function TSubscriptionsTests.SubscriptionIdOf(const Json: TJSONObject; const MetaPath: string): Integer;
begin
  var Meta := Json.FindValue(MetaPath);
  Assert.IsTrue(Meta is TJSONObject, MetaPath);
  var Id := TJSONObject(Meta).GetValue(MCP_META_SUBSCRIPTION_ID);
  Assert.IsTrue(Id is TJSONNumber, MCP_META_SUBSCRIPTION_ID);
  Result := TJSONNumber(Id).AsInt;
end;

function TSubscriptionsTests.Parse(const Json: string): TJSONObject;
begin
  Result := TJSONObject.ParseJSONValue(Json) as TJSONObject;
  Assert.IsNotNull(Result, Json);
end;

procedure TSubscriptionsTests.StartListen(const ParamsJson: string);
begin
  var Meta := TJSONObject.ParseJSONValue(MODERN_META) as TJSONObject;
  try
    FContext := TMCPRequestContext.Create(TMCPProtocolEra.Modern, MCP_LATEST_PROTOCOL_VERSION,
      MCP_METHOD_SUBSCRIPTIONS_LISTEN, TMCPRequestId.FromNumber(5), Meta, nil, nil, FSinkRef);
  finally
    Meta.Free;
  end;

  var Params := TJSONObject.ParseJSONValue(ParamsJson) as TJSONObject;
  var Context := FContext;
  FThread := TThread.CreateAnonymousThread(
    procedure
    begin
      try
        try
          FResult := FManager.ExecuteMethodWithContext(MCP_METHOD_SUBSCRIPTIONS_LISTEN, Params, Context).AsType<TJSONObject>;
        except
          on E: Exception do
            FError := E.ClassName + ': ' + E.Message;
        end;
      finally
        Params.Free;
      end;
    end);
  FThread.FreeOnTerminate := False;
  FThread.Start;
end;

procedure TSubscriptionsTests.WaitUntilOpen;
begin
  TMCPTestWait.UntilTrue(
    function: Boolean
    begin
      Result := (FManager.ActiveCount > 0) or (FError <> '');
    end, WAIT_MS);
  Assert.AreEqual('', FError);
  Assert.AreEqual(1, FManager.ActiveCount, 'the subscription is registered');
end;

procedure TSubscriptionsTests.JoinListen;
begin
  if not Assigned(FThread) then
    Exit;
  FThread.WaitFor;
  FreeAndNil(FThread);
end;

procedure TSubscriptionsTests.Filter_FromJson_HonoursBooleansAndUris;
begin
  var Json := TJSONObject.ParseJSONValue(
    '{"toolsListChanged":true,"promptsListChanged":"yes","resourcesListChanged":false,"resourceSubscriptions":["a://x",7,""]}');
  try
    var Filter := TMCPSubscriptionFilter.FromJson(Json);
    Assert.IsTrue(Filter.ToolsListChanged);
    Assert.IsFalse(Filter.PromptsListChanged, 'only a JSON true counts');
    Assert.IsFalse(Filter.ResourcesListChanged);
    Assert.AreEqual(1, Integer(Length(Filter.ResourceSubscriptions)));
    Assert.IsTrue(Filter.WantsResource('a://x'));
    Assert.IsFalse(Filter.WantsResource('a://y'));
    var Honoured := Filter.ToJson;
    try
      Assert.IsTrue(Honoured.GetValue<Boolean>('toolsListChanged'));
      Assert.IsNull(Honoured.GetValue('promptsListChanged'));
      Assert.AreEqual('a://x', Honoured.GetValue<string>('resourceSubscriptions[0]'));
    finally
      Honoured.Free;
    end;
  finally
    Json.Free;
  end;
  var Empty := TMCPSubscriptionFilter.FromJson(nil).ToJson;
  try
    Assert.AreEqual(0, Empty.Count);
  finally
    Empty.Free;
  end;
end;

procedure TSubscriptionsTests.Listen_AckFirst_ThenTaggedNotifications_ThenCompletion;
begin
  StartListen('{"notifications":{"toolsListChanged":true,"resourceSubscriptions":["a://x"]}}');
  WaitUntilOpen;
  Assert.AreEqual(1, FSink.Count, 'the acknowledgement is the first message');

  FManager.ToolsListChanged;
  FManager.ResourceUpdated('a://x');
  FManager.ResourceUpdated('a://other');
  FManager.CloseAll('test');
  FThread.WaitFor;
  Assert.AreEqual('', FError);

  var Messages := FSink.Messages;
  Assert.AreEqual(3, Integer(Length(Messages)), string.Join(' | ', Messages));
  var Ack := Parse(Messages[0]);
  var Changed := Parse(Messages[1]);
  var Updated := Parse(Messages[2]);
  try
    Assert.AreEqual(MCP_METHOD_NOTIFICATIONS_SUBSCRIPTIONS_ACKNOWLEDGED, Ack.GetValue<string>('method'));
    Assert.AreEqual(5, SubscriptionIdOf(Ack, 'params._meta'));
    Assert.IsTrue(Ack.GetValue<Boolean>('params.notifications.toolsListChanged'));
    Assert.AreEqual('a://x', Ack.GetValue<string>('params.notifications.resourceSubscriptions[0]'));
    Assert.IsNull(Ack.GetValue('id'));

    Assert.AreEqual(MCP_METHOD_NOTIFICATIONS_TOOLS_LIST_CHANGED, Changed.GetValue<string>('method'));
    Assert.AreEqual(5, SubscriptionIdOf(Changed, 'params._meta'));

    Assert.AreEqual(MCP_METHOD_NOTIFICATIONS_RESOURCES_UPDATED, Updated.GetValue<string>('method'));
    Assert.AreEqual('a://x', Updated.GetValue<string>('params.uri'));
  finally
    Ack.Free;
    Changed.Free;
    Updated.Free;
  end;

  Assert.IsNotNull(FResult, 'closing on the server side completes the request');
  Assert.AreEqual(5, SubscriptionIdOf(FResult, '_meta'));
  Assert.AreEqual(0, FManager.ActiveCount);
end;

procedure TSubscriptionsTests.Listen_UnrequestedNotifications_AreNotSent;
begin
  StartListen('{"notifications":{"promptsListChanged":true}}');
  WaitUntilOpen;
  FManager.ToolsListChanged;
  FManager.ResourcesListChanged;
  FManager.ResourceUpdated('a://x');
  FManager.PromptsListChanged;
  FManager.CloseAll('test');
  FThread.WaitFor;

  var Messages := FSink.Messages;
  Assert.AreEqual(2, Integer(Length(Messages)), string.Join(' | ', Messages));
  Assert.IsTrue(Messages[1].Contains(MCP_METHOD_NOTIFICATIONS_PROMPTS_LIST_CHANGED), Messages[1]);
end;

procedure TSubscriptionsTests.Listen_Cancel_EndsTheWait;
begin
  StartListen('{"notifications":{"toolsListChanged":true}}');
  WaitUntilOpen;
  FContext.Cancel;
  TMCPTestWait.UntilTrue(
    function: Boolean
    begin
      Result := FManager.ActiveCount = 0;
    end, WAIT_MS);
  Assert.AreEqual(0, FManager.ActiveCount, 'cancellation ends the subscription');
  FThread.WaitFor;
  Assert.AreEqual(1, FSink.Count, 'nothing after the acknowledgement');
end;

procedure TSubscriptionsTests.Listen_KeepAlive_OnInterval;
begin
  FManager.KeepAliveIntervalMs := TMCPSubscriptionsManager.POLL_INTERVAL_MS;
  StartListen('{}');
  WaitUntilOpen;
  TMCPTestWait.UntilTrue(
    function: Boolean
    begin
      Result := FSink.KeepAlives >= 2;
    end, WAIT_MS);
  Assert.IsTrue(FSink.KeepAlives >= 2, 'keep-alives are sent while the subscription is quiet');
  Assert.AreEqual(1, FSink.Count, 'keep-alives are not messages');
end;

procedure TSubscriptionsTests.Listen_WithoutSink_IsInvalidRequest;
begin
  var Context: IMCPRequestContext := TMCPRequestContext.Create(TMCPProtocolEra.Modern, MCP_LATEST_PROTOCOL_VERSION,
    MCP_METHOD_SUBSCRIPTIONS_LISTEN, TMCPRequestId.FromNumber(1), nil, nil, nil, nil);
  try
    FManager.ExecuteMethodWithContext(MCP_METHOD_SUBSCRIPTIONS_LISTEN, nil, Context).AsType<TJSONObject>.Free;
    Assert.Fail('expected an error');
  except
    on E: EMCPError do
      Assert.AreEqual(JSONRPC_INVALID_REQUEST, E.Code);
  end;
end;

procedure TSubscriptionsTests.Listen_NotificationsNotObject_IsInvalidParams;
begin
  var Context: IMCPRequestContext := TMCPRequestContext.Create(TMCPProtocolEra.Modern, MCP_LATEST_PROTOCOL_VERSION,
    MCP_METHOD_SUBSCRIPTIONS_LISTEN, TMCPRequestId.FromNumber(1), nil, nil, nil, FSinkRef);
  var Params := TJSONObject.ParseJSONValue('{"notifications":[1]}') as TJSONObject;
  try
    try
      FManager.ExecuteMethodWithContext(MCP_METHOD_SUBSCRIPTIONS_LISTEN, Params, Context).AsType<TJSONObject>.Free;
      Assert.Fail('expected an error');
    except
      on E: EMCPError do
        Assert.AreEqual(JSONRPC_INVALID_PARAMS, E.Code);
    end;
  finally
    Params.Free;
  end;
end;

procedure TSubscriptionsTests.Managers_NotifyTheHub_AndAnnounceCapabilities;
begin
  var Hub := TRecordingHub.Create;
  var HubRef: IMCPSubscriptionHub := Hub;
  var Tools := TMCPToolsManager.Create;
  var Prompts := TMCPPromptsManager.Create;
  var Resources := TMCPResourcesManager.Create;
  var ToolsRef: IInterface := Tools;
  var PromptsRef: IInterface := Prompts;
  var ResourcesRef: IInterface := Resources;
  var Legacy := TJSONObject.Create;
  var Modern := TJSONObject.Create;
  try
    Tools.DescribeCapabilities(Legacy, TMCPProtocolEra.Legacy);
    Assert.IsFalse(Legacy.GetValue<Boolean>('tools.listChanged'), 'without a hub nothing is announced');
    Legacy.RemovePair('tools').Free;

    Tools.ChangeNotifier := HubRef;
    Prompts.ChangeNotifier := HubRef;
    Resources.ChangeNotifier := HubRef;
    Tools.DescribeCapabilities(Legacy, TMCPProtocolEra.Legacy);
    Tools.DescribeCapabilities(Modern, TMCPProtocolEra.Modern);
    Resources.DescribeCapabilities(Modern, TMCPProtocolEra.Modern);
    Prompts.DescribeCapabilities(Modern, TMCPProtocolEra.Modern);
    Assert.IsFalse(Legacy.GetValue<Boolean>('tools.listChanged'), 'legacy clients cannot listen');
    Assert.IsTrue(Modern.GetValue<Boolean>('tools.listChanged'));
    Assert.IsTrue(Modern.GetValue<Boolean>('prompts.listChanged'));
    Assert.IsTrue(Modern.GetValue<Boolean>('resources.listChanged'));
    Assert.IsTrue(Modern.GetValue<Boolean>('resources.subscribe'));

    Tools.AddTool(TSimpleTextTool.Create);
    Assert.IsTrue(Tools.HasTool('test_simple_text'));
    Tools.RemoveTool('test_simple_text');
    Tools.RemoveTool('test_simple_text');
    Assert.IsFalse(Tools.HasTool('test_simple_text'));
    Prompts.AddPrompt(TSimplePrompt.Create);
    Prompts.RemovePrompt('test_simple_prompt');
    Resources.ResourceUpdated('a://x');
    Assert.AreEqual('tools,tools,prompts,prompts,updated:a://x', string.Join(',', Hub.Events.ToStringArray));
  finally
    Modern.Free;
    Legacy.Free;
    ResourcesRef := nil;
    PromptsRef := nil;
    ToolsRef := nil;
    HubRef := nil;
  end;
end;

end.
