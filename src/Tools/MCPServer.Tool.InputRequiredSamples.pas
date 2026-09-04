unit MCPServer.Tool.InputRequiredSamples;

interface

uses
  System.SysUtils,
  System.Rtti,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Base,
  MCPServer.Tool.ContentSamples;

type
  TElicitationInputTool = class(TMCPToolBase<TNoParams>)
  protected
    function ExecuteWithContext(const Params: TNoParams; const Context: IMCPRequestContext): TValue; override;
  public
    constructor Create; override;
  end;

  TSamplingInputTool = class(TMCPToolBase<TNoParams>)
  protected
    function ExecuteWithContext(const Params: TNoParams; const Context: IMCPRequestContext): TValue; override;
  public
    constructor Create; override;
  end;

  TListRootsInputTool = class(TMCPToolBase<TNoParams>)
  protected
    function ExecuteWithContext(const Params: TNoParams; const Context: IMCPRequestContext): TValue; override;
  public
    constructor Create; override;
  end;

  TRequestStateInputTool = class(TMCPToolBase<TNoParams>)
  protected
    function ExecuteWithContext(const Params: TNoParams; const Context: IMCPRequestContext): TValue; override;
  public
    constructor Create; override;
  end;

  TMultipleInputsTool = class(TMCPToolBase<TNoParams>)
  protected
    function ExecuteWithContext(const Params: TNoParams; const Context: IMCPRequestContext): TValue; override;
  public
    constructor Create; override;
  end;

  TMultiRoundInputTool = class(TMCPToolBase<TNoParams>)
  protected
    function ExecuteWithContext(const Params: TNoParams; const Context: IMCPRequestContext): TValue; override;
  public
    constructor Create; override;
  end;

  TTamperedStateInputTool = class(TMCPToolBase<TNoParams>)
  protected
    function ExecuteWithContext(const Params: TNoParams; const Context: IMCPRequestContext): TValue; override;
  public
    constructor Create; override;
  end;

  TCapabilityAwareInputTool = class(TMCPToolBase<TNoParams>)
  protected
    function ExecuteWithContext(const Params: TNoParams; const Context: IMCPRequestContext): TValue; override;
  public
    constructor Create; override;
  end;

  TMissingCapabilityTool = class(TMCPToolBase<TNoParams>)
  protected
    function ExecuteWithContext(const Params: TNoParams; const Context: IMCPRequestContext): TValue; override;
  public
    constructor Create; override;
  end;

  TStreamingElicitationTool = class(TMCPToolBase<TNoParams>)
  protected
    function ExecuteWithContext(const Params: TNoParams; const Context: IMCPRequestContext): TValue; override;
  public
    constructor Create; override;
  end;

  TInputSample = record
    class function DescribeRoots(const Roots: TJSONArray): string; static;
    class function NewState(const Round: Integer): TJSONObject; static;
  end;

implementation

uses
  MCPServer.Mrtr,
  MCPServer.Registration,
  MCPServer.Tool.Result;

const
  KEY_USER_NAME = 'user_name';
  KEY_CAPITAL_QUESTION = 'capital_question';
  KEY_CLIENT_ROOTS = 'client_roots';
  KEY_CONFIRM = 'confirm';
  KEY_GREETING = 'greeting';
  KEY_STEP1 = 'step1';
  KEY_STEP2 = 'step2';
  FIELD_NAME = 'name';
  FIELD_OK = 'ok';
  FIELD_COLOR = 'color';
  STATE_ROUND = 'round';
  STATE_NAME = 'name';
  STATE_NONCE = 'nonce';
  CAPABILITY_ELICITATION = 'elicitation';
  CAPABILITY_SAMPLING = 'sampling';
  CAPABILITY_ROOTS = 'roots';
  ASK_NAME = 'What is your name?';
  CAPITAL_QUESTION = 'What is the capital of France?';
  SAMPLING_MAX_TOKENS = 100;
  GREETING_MAX_TOKENS = 50;

{ TInputSample }

class function TInputSample.DescribeRoots(const Roots: TJSONArray): string;
begin
  var Uris: TArray<string> := nil;
  if Assigned(Roots) then
  begin
    for var Root in Roots do
    begin
      if Root is TJSONObject then
        Uris := Uris + [TJSONObject(Root).GetValue<string>('uri', '')];
    end;
  end;
  Result := Format('Roots: %s', [string.Join(', ', Uris)]);
end;

class function TInputSample.NewState(const Round: Integer): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair(STATE_ROUND, TJSONNumber.Create(Round));
end;

{ TElicitationInputTool }

constructor TElicitationInputTool.Create;
begin
  inherited;
  FName := 'test_input_required_result_elicitation';
  FDescription := 'Asks the client for a name through an elicitation input request, then greets it';
end;

function TElicitationInputTool.ExecuteWithContext(const Params: TNoParams; const Context: IMCPRequestContext): TValue;
var
  Response: TJSONObject;
begin
  var Name := '';
  if Context.TryGetInputResponse(KEY_USER_NAME, Response) then
    Name := TMCPInputResponse.ElicitationField(Response, FIELD_NAME);
  if Name = '' then
    raise EMCPInputRequired.Create(TMCPInputRequests.Create
      .AddElicitation(KEY_USER_NAME, ASK_NAME, TMCPInputRequests.FieldSchema(FIELD_NAME)));

  Result := TMCPToolResult.Text(Format('Hello, %s!', [Name]));
end;

{ TSamplingInputTool }

constructor TSamplingInputTool.Create;
begin
  inherited;
  FName := 'test_input_required_result_sampling';
  FDescription := 'Asks the client to sample an answer, then returns that answer';
end;

function TSamplingInputTool.ExecuteWithContext(const Params: TNoParams; const Context: IMCPRequestContext): TValue;
var
  Response: TJSONObject;
begin
  var Answer := '';
  if Context.TryGetInputResponse(KEY_CAPITAL_QUESTION, Response) then
    Answer := TMCPInputResponse.SamplingText(Response);
  if Answer = '' then
    raise EMCPInputRequired.Create(TMCPInputRequests.Create
      .AddSampling(KEY_CAPITAL_QUESTION, CAPITAL_QUESTION, SAMPLING_MAX_TOKENS));

  Result := TMCPToolResult.Text(Format('LLM response: %s', [Answer]));
end;

{ TListRootsInputTool }

constructor TListRootsInputTool.Create;
begin
  inherited;
  FName := 'test_input_required_result_list_roots';
  FDescription := 'Asks the client for its roots, then lists them';
end;

function TListRootsInputTool.ExecuteWithContext(const Params: TNoParams; const Context: IMCPRequestContext): TValue;
var
  Response: TJSONObject;
begin
  if not Context.TryGetInputResponse(KEY_CLIENT_ROOTS, Response)
    or not Assigned(TMCPInputResponse.Roots(Response)) then
    raise EMCPInputRequired.Create(TMCPInputRequests.Create.AddListRoots(KEY_CLIENT_ROOTS));

  Result := TMCPToolResult.Text(TInputSample.DescribeRoots(TMCPInputResponse.Roots(Response)));
end;

{ TRequestStateInputTool }

constructor TRequestStateInputTool.Create;
begin
  inherited;
  FName := 'test_input_required_result_request_state';
  FDescription := 'Asks for a confirmation and carries a signed requestState across the round trip';
end;

function TRequestStateInputTool.ExecuteWithContext(const Params: TNoParams; const Context: IMCPRequestContext): TValue;
var
  Response: TJSONObject;
begin
  var Confirmed := Context.TryGetInputResponse(KEY_CONFIRM, Response)
    and (TMCPInputResponse.ElicitationField(Response, FIELD_OK) = 'true');
  var HasState := Assigned(Context.RequestState) and Assigned(Context.RequestState.GetValue(STATE_NONCE));
  if not Confirmed or not HasState then
  begin
    var State := TJSONObject.Create;
    State.AddPair(STATE_NONCE, TGUID.NewGuid.ToString);
    raise EMCPInputRequired.Create(TMCPInputRequests.Create
      .AddElicitation(KEY_CONFIRM, 'Please confirm', TMCPInputRequests.FieldSchema(FIELD_OK, 'boolean')), State);
  end;

  Result := TMCPToolResult.Text(Format('state-ok: confirmed with nonce %s',
    [Context.RequestState.GetValue<string>(STATE_NONCE)]));
end;

{ TMultipleInputsTool }

constructor TMultipleInputsTool.Create;
begin
  inherited;
  FName := 'test_input_required_result_multiple_inputs';
  FDescription := 'Asks for a name, a sampled greeting and the client roots in one round trip';
end;

function TMultipleInputsTool.ExecuteWithContext(const Params: TNoParams; const Context: IMCPRequestContext): TValue;
var
  NameResponse, GreetingResponse, RootsResponse: TJSONObject;
begin
  var Complete := Context.TryGetInputResponse(KEY_USER_NAME, NameResponse)
    and Context.TryGetInputResponse(KEY_GREETING, GreetingResponse)
    and Context.TryGetInputResponse(KEY_CLIENT_ROOTS, RootsResponse)
    and Assigned(Context.RequestState);
  if not Complete then
    raise EMCPInputRequired.Create(TMCPInputRequests.Create
      .AddElicitation(KEY_USER_NAME, ASK_NAME, TMCPInputRequests.FieldSchema(FIELD_NAME))
      .AddSampling(KEY_GREETING, 'Generate a greeting', GREETING_MAX_TOKENS)
      .AddListRoots(KEY_CLIENT_ROOTS), TInputSample.NewState(1));

  Result := TMCPToolResult.Text(Format('%s, %s! %s', [
    TMCPInputResponse.SamplingText(GreetingResponse),
    TMCPInputResponse.ElicitationField(NameResponse, FIELD_NAME),
    TInputSample.DescribeRoots(TMCPInputResponse.Roots(RootsResponse))]));
end;

{ TMultiRoundInputTool }

constructor TMultiRoundInputTool.Create;
begin
  inherited;
  FName := 'test_input_required_result_multi_round';
  FDescription := 'Asks for a name and then a colour in two consecutive round trips';
end;

function TMultiRoundInputTool.ExecuteWithContext(const Params: TNoParams; const Context: IMCPRequestContext): TValue;
var
  Response: TJSONObject;
begin
  var Round := 0;
  if Assigned(Context.RequestState) then
    Round := Context.RequestState.GetValue<Integer>(STATE_ROUND, 0);

  if Round < 1 then
    raise EMCPInputRequired.Create(TMCPInputRequests.Create
      .AddElicitation(KEY_STEP1, 'Step 1: What is your name?', TMCPInputRequests.FieldSchema(FIELD_NAME)), TInputSample.NewState(1));

  if Round = 1 then
  begin
    var Name := '';
    if Context.TryGetInputResponse(KEY_STEP1, Response) then
      Name := TMCPInputResponse.ElicitationField(Response, FIELD_NAME);
    if Name = '' then
      raise EMCPInputRequired.Create(TMCPInputRequests.Create
        .AddElicitation(KEY_STEP1, 'Step 1: What is your name?', TMCPInputRequests.FieldSchema(FIELD_NAME)), TInputSample.NewState(1));

    var State := TInputSample.NewState(2);
    State.AddPair(STATE_NAME, Name);
    raise EMCPInputRequired.Create(TMCPInputRequests.Create
      .AddElicitation(KEY_STEP2, 'Step 2: What is your favorite color?', TMCPInputRequests.FieldSchema(FIELD_COLOR)), State);
  end;

  var Color := '';
  if Context.TryGetInputResponse(KEY_STEP2, Response) then
    Color := TMCPInputResponse.ElicitationField(Response, FIELD_COLOR);
  if Color = '' then
  begin
    var State := TInputSample.NewState(2);
    State.AddPair(STATE_NAME, Context.RequestState.GetValue<string>(STATE_NAME, ''));
    raise EMCPInputRequired.Create(TMCPInputRequests.Create
      .AddElicitation(KEY_STEP2, 'Step 2: What is your favorite color?', TMCPInputRequests.FieldSchema(FIELD_COLOR)), State);
  end;

  Result := TMCPToolResult.Text(Format('Hello, %s! Your favorite color is %s.',
    [Context.RequestState.GetValue<string>(STATE_NAME, ''), Color]));
end;

{ TTamperedStateInputTool }

constructor TTamperedStateInputTool.Create;
begin
  inherited;
  FName := 'test_input_required_result_tampered_state';
  FDescription := 'Asks for a confirmation with a signed requestState that must come back unchanged';
end;

function TTamperedStateInputTool.ExecuteWithContext(const Params: TNoParams; const Context: IMCPRequestContext): TValue;
var
  Response: TJSONObject;
begin
  var Confirmed := Context.TryGetInputResponse(KEY_CONFIRM, Response)
    and (TMCPInputResponse.ElicitationField(Response, FIELD_OK) = 'true');
  if not Confirmed or not Assigned(Context.RequestState) then
    raise EMCPInputRequired.Create(TMCPInputRequests.Create
      .AddElicitation(KEY_CONFIRM, 'Please confirm', TMCPInputRequests.FieldSchema(FIELD_OK, 'boolean')), TInputSample.NewState(1));

  Result := TMCPToolResult.Text('state-ok: the requestState verified');
end;

{ TCapabilityAwareInputTool }

constructor TCapabilityAwareInputTool.Create;
begin
  inherited;
  FName := 'test_input_required_result_capabilities';
  FDescription := 'Asks only for the kinds of input the client declared it can provide';
end;

function TCapabilityAwareInputTool.ExecuteWithContext(const Params: TNoParams; const Context: IMCPRequestContext): TValue;
begin
  var Answers: TArray<string> := nil;
  var Requests := TMCPInputRequests.Create;
  try
    var Response: TJSONObject;
    if Context.HasClientCapability(CAPABILITY_ELICITATION) then
    begin
      if Context.TryGetInputResponse(KEY_USER_NAME, Response) then
        Answers := Answers + [Format('name=%s', [TMCPInputResponse.ElicitationField(Response, FIELD_NAME)])]
      else
        Requests.AddElicitation(KEY_USER_NAME, ASK_NAME, TMCPInputRequests.FieldSchema(FIELD_NAME));
    end;
    if Context.HasClientCapability(CAPABILITY_SAMPLING) then
    begin
      if Context.TryGetInputResponse(KEY_CAPITAL_QUESTION, Response) then
        Answers := Answers + [Format('capital=%s', [TMCPInputResponse.SamplingText(Response)])]
      else
        Requests.AddSampling(KEY_CAPITAL_QUESTION, CAPITAL_QUESTION, SAMPLING_MAX_TOKENS);
    end;
    if Context.HasClientCapability(CAPABILITY_ROOTS) then
    begin
      if Context.TryGetInputResponse(KEY_CLIENT_ROOTS, Response) then
        Answers := Answers + [TInputSample.DescribeRoots(TMCPInputResponse.Roots(Response))]
      else
        Requests.AddListRoots(KEY_CLIENT_ROOTS);
    end;

    if Requests.Count > 0 then
    begin
      var Pending := Requests;
      Requests := nil;
      raise EMCPInputRequired.Create(Pending);
    end;
  finally
    Requests.Free;
  end;

  if Length(Answers) = 0 then
    Result := TMCPToolResult.Text('The client declared no capability this tool can ask input through')
  else
    Result := TMCPToolResult.Text(string.Join('; ', Answers));
end;

{ TMissingCapabilityTool }

constructor TMissingCapabilityTool.Create;
begin
  inherited;
  FName := 'test_missing_capability';
  FDescription := 'Requires the sampling client capability and fails with -32021 when it is absent';
end;

function TMissingCapabilityTool.ExecuteWithContext(const Params: TNoParams; const Context: IMCPRequestContext): TValue;
begin
  Context.RequireClientCapability(CAPABILITY_SAMPLING);
  Result := TMCPToolResult.Text('The client declared the sampling capability');
end;

{ TStreamingElicitationTool }

constructor TStreamingElicitationTool.Create;
begin
  inherited;
  FName := 'test_streaming_elicitation';
  FDescription := 'Logs to the response stream, then asks the client for a confirmation';
end;

function TStreamingElicitationTool.ExecuteWithContext(const Params: TNoParams; const Context: IMCPRequestContext): TValue;
var
  Response: TJSONObject;
begin
  Context.Log('info', 'Asking the client to confirm', 'test_streaming_elicitation');
  var Confirmed := Context.TryGetInputResponse(KEY_CONFIRM, Response)
    and (TMCPInputResponse.ElicitationField(Response, FIELD_OK) = 'true');
  if not Confirmed then
    raise EMCPInputRequired.Create(TMCPInputRequests.Create
      .AddElicitation(KEY_CONFIRM, 'Please confirm', TMCPInputRequests.FieldSchema(FIELD_OK, 'boolean')));

  Result := TMCPToolResult.Text('Confirmed');
end;

initialization
  TMCPRegistry.RegisterTool('test_input_required_result_elicitation',
    function: IMCPTool
    begin
      Result := TElicitationInputTool.Create;
    end);
  TMCPRegistry.RegisterTool('test_input_required_result_sampling',
    function: IMCPTool
    begin
      Result := TSamplingInputTool.Create;
    end);
  TMCPRegistry.RegisterTool('test_input_required_result_list_roots',
    function: IMCPTool
    begin
      Result := TListRootsInputTool.Create;
    end);
  TMCPRegistry.RegisterTool('test_input_required_result_request_state',
    function: IMCPTool
    begin
      Result := TRequestStateInputTool.Create;
    end);
  TMCPRegistry.RegisterTool('test_input_required_result_multiple_inputs',
    function: IMCPTool
    begin
      Result := TMultipleInputsTool.Create;
    end);
  TMCPRegistry.RegisterTool('test_input_required_result_multi_round',
    function: IMCPTool
    begin
      Result := TMultiRoundInputTool.Create;
    end);
  TMCPRegistry.RegisterTool('test_input_required_result_tampered_state',
    function: IMCPTool
    begin
      Result := TTamperedStateInputTool.Create;
    end);
  TMCPRegistry.RegisterTool('test_input_required_result_capabilities',
    function: IMCPTool
    begin
      Result := TCapabilityAwareInputTool.Create;
    end);
  TMCPRegistry.RegisterTool('test_missing_capability',
    function: IMCPTool
    begin
      Result := TMissingCapabilityTool.Create;
    end);
  TMCPRegistry.RegisterTool('test_streaming_elicitation',
    function: IMCPTool
    begin
      Result := TStreamingElicitationTool.Create;
    end);

end.
