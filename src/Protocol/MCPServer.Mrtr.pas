unit MCPServer.Mrtr;

interface

uses
  System.SysUtils,
  System.JSON;

const
  RESULT_TYPE_INPUT_REQUIRED = 'input_required';
  MCP_METHOD_ELICITATION_CREATE = 'elicitation/create';
  MCP_METHOD_SAMPLING_CREATE_MESSAGE = 'sampling/createMessage';
  MCP_METHOD_ROOTS_LIST = 'roots/list';
  ELICITATION_MODE_FORM = 'form';
  ELICITATION_ACTION_ACCEPT = 'accept';

type
  TMCPInputRequests = class
  strict private
    FRequests: TJSONObject;
    function AddRequest(const Key, Method: string; const Params: TJSONObject): TMCPInputRequests;
  public
    constructor Create;
    destructor Destroy; override;

    function AddElicitation(const Key, Message: string; const RequestedSchema: TJSONObject): TMCPInputRequests;
    function AddSampling(const Key, UserText: string; MaxTokens: Integer;
      const SystemPrompt: string = ''): TMCPInputRequests;
    function AddListRoots(const Key: string): TMCPInputRequests;

    function Count: Integer;
    function Methods: TArray<string>;
    class function RequiredCapability(const Method: string): string; static;
    class function FieldSchema(const Field: string; const FieldType: string = 'string'): TJSONObject; static;
    function ToJson: TJSONObject;
  end;

  EMCPInputRequired = class(Exception)
  strict private
    FRequests: TMCPInputRequests;
    FState: TJSONObject;
  public
    constructor Create(Requests: TMCPInputRequests; State: TJSONObject = nil);
    destructor Destroy; override;
    property Requests: TMCPInputRequests read FRequests;
    property State: TJSONObject read FState;
  end;

implementation

{ TMCPInputRequests }

class function TMCPInputRequests.FieldSchema(const Field: string; const FieldType: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  var Properties := TJSONObject.Create;
  Result.AddPair('properties', Properties);
  var Schema := TJSONObject.Create;
  Schema.AddPair('type', FieldType);
  Properties.AddPair(Field, Schema);
  var Required := TJSONArray.Create;
  Required.Add(Field);
  Result.AddPair('required', Required);
end;

constructor TMCPInputRequests.Create;
begin
  inherited Create;
  FRequests := TJSONObject.Create;
end;

destructor TMCPInputRequests.Destroy;
begin
  FRequests.Free;
  inherited;
end;

function TMCPInputRequests.AddRequest(const Key, Method: string; const Params: TJSONObject): TMCPInputRequests;
begin
  var Request := TJSONObject.Create;
  Request.AddPair('method', Method);
  Request.AddPair('params', Params);
  FRequests.AddPair(Key, Request);
  Result := Self;
end;

function TMCPInputRequests.AddElicitation(const Key, Message: string;
  const RequestedSchema: TJSONObject): TMCPInputRequests;
begin
  var Params := TJSONObject.Create;
  Params.AddPair('mode', ELICITATION_MODE_FORM);
  Params.AddPair('message', Message);
  Params.AddPair('requestedSchema', RequestedSchema);
  Result := AddRequest(Key, MCP_METHOD_ELICITATION_CREATE, Params);
end;

function TMCPInputRequests.AddSampling(const Key, UserText: string; MaxTokens: Integer;
  const SystemPrompt: string): TMCPInputRequests;
begin
  var Params := TJSONObject.Create;
  var Messages := TJSONArray.Create;
  Params.AddPair('messages', Messages);
  var Message := TJSONObject.Create;
  Messages.AddElement(Message);
  Message.AddPair('role', 'user');
  var Content := TJSONObject.Create;
  Message.AddPair('content', Content);
  Content.AddPair('type', 'text');
  Content.AddPair('text', UserText);
  if SystemPrompt <> '' then
    Params.AddPair('systemPrompt', SystemPrompt);
  Params.AddPair('maxTokens', TJSONNumber.Create(MaxTokens));
  Result := AddRequest(Key, MCP_METHOD_SAMPLING_CREATE_MESSAGE, Params);
end;

function TMCPInputRequests.AddListRoots(const Key: string): TMCPInputRequests;
begin
  Result := AddRequest(Key, MCP_METHOD_ROOTS_LIST, TJSONObject.Create);
end;

function TMCPInputRequests.Count: Integer;
begin
  Result := FRequests.Count;
end;

function TMCPInputRequests.Methods: TArray<string>;
begin
  Result := nil;
  for var Pair in FRequests do
    Result := Result + [TJSONObject(Pair.JsonValue).GetValue<string>('method')];
end;

class function TMCPInputRequests.RequiredCapability(const Method: string): string;
begin
  if Method = MCP_METHOD_ELICITATION_CREATE then
    Result := 'elicitation'
  else if Method = MCP_METHOD_SAMPLING_CREATE_MESSAGE then
    Result := 'sampling'
  else if Method = MCP_METHOD_ROOTS_LIST then
    Result := 'roots'
  else
    Result := '';
end;

function TMCPInputRequests.ToJson: TJSONObject;
begin
  Result := TJSONObject(FRequests.Clone);
end;

{ EMCPInputRequired }

constructor EMCPInputRequired.Create(Requests: TMCPInputRequests; State: TJSONObject);
begin
  inherited Create('Input from the client is required to complete this request');
  FRequests := Requests;
  FState := State;
end;

destructor EMCPInputRequired.Destroy;
begin
  FRequests.Free;
  FState.Free;
  inherited;
end;

end.
