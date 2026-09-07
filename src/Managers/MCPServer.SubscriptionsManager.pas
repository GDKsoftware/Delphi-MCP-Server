unit MCPServer.SubscriptionsManager;

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.JSON,
  System.Rtti,
  System.Generics.Collections,
  MCPServer.Types;

type
  TMCPSubscriptionFilter = record
    ToolsListChanged: Boolean;
    PromptsListChanged: Boolean;
    ResourcesListChanged: Boolean;
    ResourceSubscriptions: TArray<string>;
    class function FromJson(const Notifications: TJSONValue): TMCPSubscriptionFilter; static;
    function ToJson: TJSONObject;
    function WantsResource(const Uri: string): Boolean;
    function Wants(const Method, Uri: string): Boolean;
  end;

  IMCPSubscription = interface
    ['{5A1C7E2B-9D3F-4B6A-8C0E-2F1D3B5A7C9E}']
    function GetFilter: TMCPSubscriptionFilter;
    function GetSink: IMCPMessageSink;
    function GetClosed: TEvent;
    procedure Close;
    function Notification(const Method: string): TJSONObject;
    property Filter: TMCPSubscriptionFilter read GetFilter;
    property Sink: IMCPMessageSink read GetSink;
    property Closed: TEvent read GetClosed;
  end;

  TMCPSubscriptionsManager = class(TInterfacedObject, IMCPCapabilityManager, IMCPCapabilityManagerEx,
    IMCPSubscriptionHub)
  public
    const DEFAULT_KEEP_ALIVE_INTERVAL_MS = 15000;
    const POLL_INTERVAL_MS = 250;
    const CLOSE_GRACE_MS = 2000;
  strict private
    FLock: TCriticalSection;
    FSubscriptions: TList<IMCPSubscription>;
    FKeepAliveIntervalMs: Integer;
    function Snapshot: TArray<IMCPSubscription>;
    procedure Deliver(const Method, Uri: string);
    function Listen(const Params: TJSONObject; const Context: IMCPRequestContext): TValue;
    procedure Acknowledge(const Subscription: IMCPSubscription);
    function CompletionResult(const Subscription: IMCPSubscription): TJSONObject;
  public
    constructor Create;
    destructor Destroy; override;

    function GetCapabilityName: string;
    function HandlesMethod(const Method: string): Boolean;
    function ExecuteMethod(const Method: string; const Params: TJSONObject): TValue;
    function ExecuteMethodWithContext(const Method: string; const Params: TJSONObject;
      const Context: IMCPRequestContext): TValue;

    procedure ToolsListChanged;
    procedure PromptsListChanged;
    procedure ResourcesListChanged;
    procedure ResourceUpdated(const Uri: string);
    procedure CloseAll(const Reason: string);
    procedure CloseAllAndWait(const Reason: string);
    function ActiveCount: Integer;

    property KeepAliveIntervalMs: Integer read FKeepAliveIntervalMs write FKeepAliveIntervalMs;
  end;

implementation

uses
  MCPServer.Errors,
  MCPServer.Logger;

const
  FILTER_TOOLS = 'toolsListChanged';
  FILTER_PROMPTS = 'promptsListChanged';
  FILTER_RESOURCES = 'resourcesListChanged';
  FILTER_RESOURCE_SUBSCRIPTIONS = 'resourceSubscriptions';
  PARAM_NOTIFICATIONS = 'notifications';
  CLOSE_POLL_MS = 10;

type
  TMCPSubscription = class(TInterfacedObject, IMCPSubscription)
  strict private
    FId: TJSONValue;
    FFilter: TMCPSubscriptionFilter;
    FSink: IMCPMessageSink;
    FClosed: TEvent;
  public
    constructor Create(const Id: TJSONValue; const Filter: TMCPSubscriptionFilter; const Sink: IMCPMessageSink);
    destructor Destroy; override;
    function GetFilter: TMCPSubscriptionFilter;
    function GetSink: IMCPMessageSink;
    function GetClosed: TEvent;
    procedure Close;
    function Notification(const Method: string): TJSONObject;
  end;

{ TMCPSubscriptionFilter }

class function TMCPSubscriptionFilter.FromJson(const Notifications: TJSONValue): TMCPSubscriptionFilter;
begin
  Result := Default(TMCPSubscriptionFilter);
  if not (Notifications is TJSONObject) then
    Exit;

  var Filter := TJSONObject(Notifications);
  Result.ToolsListChanged := Filter.GetValue(FILTER_TOOLS) is TJSONTrue;
  Result.PromptsListChanged := Filter.GetValue(FILTER_PROMPTS) is TJSONTrue;
  Result.ResourcesListChanged := Filter.GetValue(FILTER_RESOURCES) is TJSONTrue;

  var Uris := Filter.GetValue(FILTER_RESOURCE_SUBSCRIPTIONS);
  if Uris is TJSONArray then
  begin
    for var Item in TJSONArray(Uris) do
    begin
      if IsJsonString(Item) and (TJSONString(Item).Value <> '') then
        Result.ResourceSubscriptions := Result.ResourceSubscriptions + [TJSONString(Item).Value];
    end;
  end;
end;

function TMCPSubscriptionFilter.ToJson: TJSONObject;
begin
  Result := TJSONObject.Create;
  if ToolsListChanged then
    Result.AddPair(FILTER_TOOLS, TJSONBool.Create(True));
  if PromptsListChanged then
    Result.AddPair(FILTER_PROMPTS, TJSONBool.Create(True));
  if ResourcesListChanged then
    Result.AddPair(FILTER_RESOURCES, TJSONBool.Create(True));
  if Length(ResourceSubscriptions) > 0 then
  begin
    var Uris := TJSONArray.Create;
    Result.AddPair(FILTER_RESOURCE_SUBSCRIPTIONS, Uris);
    for var Uri in ResourceSubscriptions do
    begin
      Uris.Add(Uri);
    end;
  end;
end;

function TMCPSubscriptionFilter.WantsResource(const Uri: string): Boolean;
begin
  for var Subscribed in ResourceSubscriptions do
  begin
    if Subscribed = Uri then
      Exit(True);
  end;
  Result := False;
end;

function TMCPSubscriptionFilter.Wants(const Method, Uri: string): Boolean;
begin
  if Method = MCP_METHOD_NOTIFICATIONS_TOOLS_LIST_CHANGED then
    Result := ToolsListChanged
  else if Method = MCP_METHOD_NOTIFICATIONS_PROMPTS_LIST_CHANGED then
    Result := PromptsListChanged
  else if Method = MCP_METHOD_NOTIFICATIONS_RESOURCES_LIST_CHANGED then
    Result := ResourcesListChanged
  else if Method = MCP_METHOD_NOTIFICATIONS_RESOURCES_UPDATED then
    Result := WantsResource(Uri)
  else
    Result := False;
end;

{ TMCPSubscription }

constructor TMCPSubscription.Create(const Id: TJSONValue; const Filter: TMCPSubscriptionFilter;
  const Sink: IMCPMessageSink);
begin
  inherited Create;
  FId := TJSONValue(Id.Clone);
  FFilter := Filter;
  FSink := Sink;
  FClosed := TEvent.Create(nil, True, False, '');
end;

destructor TMCPSubscription.Destroy;
begin
  FClosed.Free;
  FId.Free;
  inherited;
end;

function TMCPSubscription.GetFilter: TMCPSubscriptionFilter;
begin
  Result := FFilter;
end;

function TMCPSubscription.GetSink: IMCPMessageSink;
begin
  Result := FSink;
end;

function TMCPSubscription.GetClosed: TEvent;
begin
  Result := FClosed;
end;

procedure TMCPSubscription.Close;
begin
  FClosed.SetEvent;
end;

function TMCPSubscription.Notification(const Method: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair(MCP_KEY_JSONRPC, JSONRPC_VERSION);
  Result.AddPair(MCP_KEY_METHOD, Method);
  var Params := TJSONObject.Create;
  Result.AddPair(MCP_KEY_PARAMS, Params);
  var Meta := TJSONObject.Create;
  Params.AddPair(MCP_KEY_META, Meta);
  Meta.AddPair(MCP_META_SUBSCRIPTION_ID, TJSONValue(FId.Clone));
end;

{ TMCPSubscriptionsManager }

constructor TMCPSubscriptionsManager.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FSubscriptions := TList<IMCPSubscription>.Create;
  FKeepAliveIntervalMs := DEFAULT_KEEP_ALIVE_INTERVAL_MS;
end;

destructor TMCPSubscriptionsManager.Destroy;
begin
  CloseAllAndWait('subscriptions manager destroyed');
  FSubscriptions.Free;
  FLock.Free;
  inherited;
end;

function TMCPSubscriptionsManager.GetCapabilityName: string;
begin
  Result := 'subscriptions';
end;

function TMCPSubscriptionsManager.HandlesMethod(const Method: string): Boolean;
begin
  Result := Method = MCP_METHOD_SUBSCRIPTIONS_LISTEN;
end;

function TMCPSubscriptionsManager.ExecuteMethod(const Method: string; const Params: TJSONObject): TValue;
begin
  Result := ExecuteMethodWithContext(Method, Params, nil);
end;

function TMCPSubscriptionsManager.ExecuteMethodWithContext(const Method: string; const Params: TJSONObject;
  const Context: IMCPRequestContext): TValue;
begin
  if Method <> MCP_METHOD_SUBSCRIPTIONS_LISTEN then
    raise EMCPError.MethodNotFound(Method);
  Result := Listen(Params, Context);
end;

function TMCPSubscriptionsManager.Snapshot: TArray<IMCPSubscription>;
begin
  FLock.Enter;
  try
    Result := FSubscriptions.ToArray;
  finally
    FLock.Leave;
  end;
end;

procedure TMCPSubscriptionsManager.Acknowledge(const Subscription: IMCPSubscription);
begin
  var Notification := Subscription.Notification(MCP_METHOD_NOTIFICATIONS_SUBSCRIPTIONS_ACKNOWLEDGED);
  try
    TJSONObject(Notification.GetValue(MCP_KEY_PARAMS)).AddPair(PARAM_NOTIFICATIONS, Subscription.Filter.ToJson);
    Subscription.Sink.Send(Notification.ToJSON);
  finally
    Notification.Free;
  end;
end;

function TMCPSubscriptionsManager.CompletionResult(const Subscription: IMCPSubscription): TJSONObject;
begin
  var Notification := Subscription.Notification('');
  try
    Result := TJSONObject.Create;
    Result.AddPair(MCP_KEY_META, TJSONObject(Notification.FindValue('params._meta').Clone));
  finally
    Notification.Free;
  end;
end;

function TMCPSubscriptionsManager.Listen(const Params: TJSONObject; const Context: IMCPRequestContext): TValue;
var
  KeepAlive: IMCPKeepAlive;
begin
  if not Assigned(Context) or not Assigned(Context.Sink) then
    raise EMCPError.InvalidRequest(Format(
      '%s needs a response stream: accept text/event-stream or use stdio', [MCP_METHOD_SUBSCRIPTIONS_LISTEN]));

  var Notifications: TJSONValue := nil;
  if Assigned(Params) then
    Notifications := Params.GetValue(PARAM_NOTIFICATIONS);
  if Assigned(Notifications) and not (Notifications is TJSONObject) then
    raise EMCPError.InvalidParams(Format('params.%s must be an object', [PARAM_NOTIFICATIONS]));

  var Id := Context.RequestId.ToJson;
  var Subscription: IMCPSubscription;
  try
    Subscription := TMCPSubscription.Create(Id, TMCPSubscriptionFilter.FromJson(Notifications), Context.Sink);
  finally
    Id.Free;
  end;

  FLock.Enter;
  try
    FSubscriptions.Add(Subscription);
  finally
    FLock.Leave;
  end;
  try
    Acknowledge(Subscription);
    TLogger.Info(Format('Subscription %s opened', [Context.RequestId.AsText]));

    Supports(Context.Sink, IMCPKeepAlive, KeepAlive);
    var SinceKeepAlive := 0;
    while not Context.IsCancelled and (Subscription.Closed.WaitFor(POLL_INTERVAL_MS) = TWaitResult.wrTimeout) do
    begin
      Inc(SinceKeepAlive, POLL_INTERVAL_MS);
      if Assigned(KeepAlive) and (SinceKeepAlive >= FKeepAliveIntervalMs) then
      begin
        SinceKeepAlive := 0;
        KeepAlive.KeepAlive;
      end;
    end;
  finally
    FLock.Enter;
    try
      FSubscriptions.Remove(Subscription);
    finally
      FLock.Leave;
    end;
  end;

  TLogger.Info(Format('Subscription %s closed', [Context.RequestId.AsText]));
  Result := TValue.From<TJSONObject>(CompletionResult(Subscription));
end;

procedure TMCPSubscriptionsManager.Deliver(const Method, Uri: string);
begin
  for var Subscription in Snapshot do
  begin
    if not Subscription.Filter.Wants(Method, Uri) then
      Continue;

    var Notification := Subscription.Notification(Method);
    try
      if Uri <> '' then
        TJSONObject(Notification.GetValue(MCP_KEY_PARAMS)).AddPair(MCP_KEY_URI, Uri);
      Subscription.Sink.Send(Notification.ToJSON);
    finally
      Notification.Free;
    end;
  end;
end;

procedure TMCPSubscriptionsManager.ToolsListChanged;
begin
  Deliver(MCP_METHOD_NOTIFICATIONS_TOOLS_LIST_CHANGED, '');
end;

procedure TMCPSubscriptionsManager.PromptsListChanged;
begin
  Deliver(MCP_METHOD_NOTIFICATIONS_PROMPTS_LIST_CHANGED, '');
end;

procedure TMCPSubscriptionsManager.ResourcesListChanged;
begin
  Deliver(MCP_METHOD_NOTIFICATIONS_RESOURCES_LIST_CHANGED, '');
end;

procedure TMCPSubscriptionsManager.ResourceUpdated(const Uri: string);
begin
  Deliver(MCP_METHOD_NOTIFICATIONS_RESOURCES_UPDATED, Uri);
end;

procedure TMCPSubscriptionsManager.CloseAll(const Reason: string);
begin
  var Open := Snapshot;
  if Length(Open) > 0 then
    TLogger.Info(Format('Closing %d subscription(s): %s', [Length(Open), Reason]));
  for var Subscription in Open do
  begin
    Subscription.Close;
  end;
end;

procedure TMCPSubscriptionsManager.CloseAllAndWait(const Reason: string);
begin
  const Deadline = TThread.GetTickCount64 + CLOSE_GRACE_MS;
  repeat
    CloseAll(Reason);
    const AllGone = (ActiveCount = 0);
    if AllGone then
      Break;
    Sleep(CLOSE_POLL_MS);
  until TThread.GetTickCount64 >= Deadline;

  const StillOpen = ActiveCount;
  if StillOpen > 0 then
    TLogger.Warning(Format('%d subscription(s) did not close in time', [StillOpen]));
end;

function TMCPSubscriptionsManager.ActiveCount: Integer;
begin
  Result := Integer(Length(Snapshot));
end;

end.
