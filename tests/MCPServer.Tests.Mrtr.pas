unit MCPServer.Tests.Mrtr;

interface

uses
  DUnitX.TestFramework,
  System.JSON,
  MCPServer.Types,
  MCPServer.RequestContext,
  MCPServer.RequestState,
  MCPServer.JsonRpcProcessor,
  MCPServer.Tests.Harness;

type
  [TestFixture]
  TRequestStateSealerTests = class
  public
    [Test] procedure Seal_Open_RoundTripsState;
    [Test] procedure Open_TamperedToken_Fails;
    [Test] procedure Open_OtherMethodOrDigestOrPrincipal_Fails;
    [Test] procedure Open_Expired_Fails;
    [Test] procedure Open_OtherKey_Fails;
    [Test] procedure DigestOf_IgnoresMetaInputResponsesAndRequestState;
    [Test] procedure EmptyKey_IsEphemeral;
  end;

  [TestFixture]
  TInputRequestsTests = class
  public
    [Test] procedure ToJson_HasMethodAndParamsPerKey;
    [Test] procedure RequiredCapability_PerMethod;
    [Test] procedure FieldSchema_IsObjectWithRequiredField;
    [Test] procedure InputResponse_Readers;
  end;

  [TestFixture]
  TInputRequiredFlowTests = class
  private
    FHarness: TMCPTestHarness;
    FProcessor: TMCPJsonRpcProcessor;
    function Call(const Method, ParamsJson: string; const Capabilities: string = '{"elicitation":{},"sampling":{},"roots":{"listChanged":true}}'): TJSONObject;
    function CallTool(const Name, ExtraParams: string; const Capabilities: string = '{"elicitation":{},"sampling":{},"roots":{"listChanged":true}}'): TJSONObject;
    function CallLegacy(const Name: string): TJSONObject;
    function ResultText(const Response: TJSONObject): string;
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    [Test] procedure Elicitation_RoundOne_IsInputRequired_WithResultType;
    [Test] procedure Elicitation_RoundTwo_Completes;
    [Test] procedure Elicitation_WrongKey_ReRequests;
    [Test] procedure Elicitation_ExtraKeys_AreIgnored;
    [Test] procedure InputResponses_NotObject_IsInvalidParams;
    [Test] procedure InputResponses_ValueNotObject_IsInvalidParams;
    [Test] procedure Sampling_RoundTrip;
    [Test] procedure ListRoots_RoundTrip;
    [Test] procedure RequestState_RoundTrip_MentionsStateOk;
    [Test] procedure RequestState_Tampered_IsInvalidParams;
    [Test] procedure RequestState_OtherTool_IsInvalidParams;
    [Test] procedure MultipleInputs_RoundTrip;
    [Test] procedure MultiRound_StateChangesPerRound;
    [Test] procedure Capabilities_OnlyDeclaredKinds;
    [Test] procedure Capabilities_UndeclaredKind_Is32021;
    [Test] procedure MissingCapabilityTool_Is32021_WithRequiredCapabilities;
    [Test] procedure Legacy_IsInternalError;
    [Test] procedure Prompt_RoundTrip;
    [Test] procedure ToolsList_IsNeverInputRequired;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  MCPServer.Errors,
  MCPServer.Mrtr;

const
  SEALER_KEY = 'unit-test-key';
  DIGEST_A = 'digest-a';
  PRINCIPAL_A = 'alice';

{ TRequestStateSealerTests }

procedure TRequestStateSealerTests.Seal_Open_RoundTripsState;
begin
  var Sealer := TMCPRequestStateSealer.Create(SEALER_KEY);
  var State := TJSONObject.Create;
  try
    State.AddPair('round', TJSONNumber.Create(2));
    State.AddPair('name', 'Alice');
    var Token := Sealer.Seal(State, 'tools/call', DIGEST_A, PRINCIPAL_A);
    Assert.IsFalse(Token.Contains('='), 'base64url without padding');

    var Opened := Sealer.Open(Token, 'tools/call', DIGEST_A, PRINCIPAL_A);
    try
      Assert.AreEqual(2, Opened.GetValue<Integer>('round'));
      Assert.AreEqual('Alice', Opened.GetValue<string>('name'));
    finally
      Opened.Free;
    end;
  finally
    State.Free;
    Sealer.Free;
  end;
end;

procedure TRequestStateSealerTests.Open_TamperedToken_Fails;
begin
  var Sealer := TMCPRequestStateSealer.Create(SEALER_KEY);
  try
    var Token := Sealer.Seal(nil, 'tools/call', DIGEST_A, PRINCIPAL_A);
    for var Tampered in [Token + '-TAMPERED', Token.Substring(1), 'not.a.token', '', Token.Replace('.', '')] do
    begin
      Assert.WillRaise(
        procedure
        begin
          Sealer.Open(Tampered, 'tools/call', DIGEST_A, PRINCIPAL_A).Free;
        end, EMCPError, Tampered);
    end;
  finally
    Sealer.Free;
  end;
end;

procedure TRequestStateSealerTests.Open_OtherMethodOrDigestOrPrincipal_Fails;
begin
  var Sealer := TMCPRequestStateSealer.Create(SEALER_KEY);
  try
    var Token := Sealer.Seal(nil, 'tools/call', DIGEST_A, PRINCIPAL_A);
    Assert.WillRaise(
      procedure
      begin
        Sealer.Open(Token, 'prompts/get', DIGEST_A, PRINCIPAL_A).Free;
      end, EMCPError, 'method');
    Assert.WillRaise(
      procedure
      begin
        Sealer.Open(Token, 'tools/call', 'digest-b', PRINCIPAL_A).Free;
      end, EMCPError, 'digest');
    Assert.WillRaise(
      procedure
      begin
        Sealer.Open(Token, 'tools/call', DIGEST_A, 'bob').Free;
      end, EMCPError, 'principal');
  finally
    Sealer.Free;
  end;
end;

procedure TRequestStateSealerTests.Open_Expired_Fails;
begin
  var Sealer := TMCPRequestStateSealer.Create(SEALER_KEY, -5);
  try
    var Token := Sealer.Seal(nil, 'tools/call', DIGEST_A, PRINCIPAL_A);
    Assert.WillRaise(
      procedure
      begin
        Sealer.Open(Token, 'tools/call', DIGEST_A, PRINCIPAL_A).Free;
      end, EMCPError);
  finally
    Sealer.Free;
  end;
end;

procedure TRequestStateSealerTests.Open_OtherKey_Fails;
begin
  var Sealer := TMCPRequestStateSealer.Create(SEALER_KEY);
  var Other := TMCPRequestStateSealer.Create('another-key');
  try
    var Token := Sealer.Seal(nil, 'tools/call', DIGEST_A, PRINCIPAL_A);
    Assert.WillRaise(
      procedure
      begin
        Other.Open(Token, 'tools/call', DIGEST_A, PRINCIPAL_A).Free;
      end, EMCPError);
  finally
    Other.Free;
    Sealer.Free;
  end;
end;

procedure TRequestStateSealerTests.DigestOf_IgnoresMetaInputResponsesAndRequestState;
begin
  var Plain := TJSONObject.ParseJSONValue('{"name":"t","arguments":{"b":1,"a":[1,2]}}') as TJSONObject;
  var Reordered := TJSONObject.ParseJSONValue(
    '{"arguments":{"a":[1,2],"b":1},"name":"t","_meta":{"x":1},"inputResponses":{"k":{}},"requestState":"s"}') as TJSONObject;
  var Different := TJSONObject.ParseJSONValue('{"name":"t","arguments":{"b":2,"a":[1,2]}}') as TJSONObject;
  try
    Assert.AreEqual(TMCPRequestStateSealer.DigestOf(Plain), TMCPRequestStateSealer.DigestOf(Reordered));
    Assert.AreNotEqual(TMCPRequestStateSealer.DigestOf(Plain), TMCPRequestStateSealer.DigestOf(Different));
    Assert.AreEqual(TMCPRequestStateSealer.DigestOf(nil), TMCPRequestStateSealer.DigestOf(nil));
  finally
    Plain.Free;
    Reordered.Free;
    Different.Free;
  end;
end;

procedure TRequestStateSealerTests.EmptyKey_IsEphemeral;
begin
  var Sealer := TMCPRequestStateSealer.Create('');
  var Fixed := TMCPRequestStateSealer.Create(SEALER_KEY);
  try
    Assert.IsTrue(Sealer.KeyIsEphemeral);
    Assert.IsFalse(Fixed.KeyIsEphemeral);
    var Token := Sealer.Seal(nil, 'tools/call', DIGEST_A, PRINCIPAL_A);
    Sealer.Open(Token, 'tools/call', DIGEST_A, PRINCIPAL_A).Free;
  finally
    Fixed.Free;
    Sealer.Free;
  end;
end;

{ TInputRequestsTests }

procedure TInputRequestsTests.ToJson_HasMethodAndParamsPerKey;
begin
  var Requests := TMCPInputRequests.Create
    .AddElicitation('who', 'Who?', TMCPInputRequests.FieldSchema('name'))
    .AddSampling('what', 'What?', 10, 'Be brief')
    .AddListRoots('roots');
  try
    Assert.AreEqual(3, Requests.Count);
    Assert.AreEqual(3, Integer(Length(Requests.Methods)));
    var Json := Requests.ToJson;
    try
      Assert.AreEqual('elicitation/create', Json.GetValue<string>('who.method'));
      Assert.AreEqual('form', Json.GetValue<string>('who.params.mode'));
      Assert.AreEqual('Who?', Json.GetValue<string>('who.params.message'));
      Assert.AreEqual('string', Json.GetValue<string>('who.params.requestedSchema.properties.name.type'));
      Assert.AreEqual('sampling/createMessage', Json.GetValue<string>('what.method'));
      Assert.AreEqual('What?', Json.GetValue<string>('what.params.messages[0].content.text'));
      Assert.AreEqual('Be brief', Json.GetValue<string>('what.params.systemPrompt'));
      Assert.AreEqual(10, Json.GetValue<Integer>('what.params.maxTokens'));
      Assert.AreEqual('roots/list', Json.GetValue<string>('roots.method'));
      Assert.IsNotNull(Json.FindValue('roots.params'));
    finally
      Json.Free;
    end;
  finally
    Requests.Free;
  end;
end;

procedure TInputRequestsTests.RequiredCapability_PerMethod;
begin
  Assert.AreEqual('elicitation', TMCPInputRequests.RequiredCapability('elicitation/create'));
  Assert.AreEqual('sampling', TMCPInputRequests.RequiredCapability('sampling/createMessage'));
  Assert.AreEqual('roots', TMCPInputRequests.RequiredCapability('roots/list'));
  Assert.AreEqual('', TMCPInputRequests.RequiredCapability('tools/call'));
end;

procedure TInputRequestsTests.FieldSchema_IsObjectWithRequiredField;
begin
  var Schema := TMCPInputRequests.FieldSchema('ok', 'boolean');
  try
    Assert.AreEqual('object', Schema.GetValue<string>('type'));
    Assert.AreEqual('boolean', Schema.GetValue<string>('properties.ok.type'));
    Assert.AreEqual('ok', Schema.GetValue<string>('required[0]'));
  finally
    Schema.Free;
  end;
end;

procedure TInputRequestsTests.InputResponse_Readers;
begin
  var Accepted := TJSONObject.ParseJSONValue('{"action":"accept","content":{"name":"Alice","ok":true}}') as TJSONObject;
  var Declined := TJSONObject.ParseJSONValue('{"action":"decline"}') as TJSONObject;
  var Sampled := TJSONObject.ParseJSONValue('{"role":"assistant","content":{"type":"text","text":"Paris"}}') as TJSONObject;
  var Roots := TJSONObject.ParseJSONValue('{"roots":[{"uri":"file:///r"}]}') as TJSONObject;
  try
    Assert.AreEqual('Alice', TMCPInputResponse.ElicitationField(Accepted, 'name'));
    Assert.AreEqual('true', TMCPInputResponse.ElicitationField(Accepted, 'ok'));
    Assert.AreEqual('', TMCPInputResponse.ElicitationField(Accepted, 'missing'));
    Assert.IsNull(TMCPInputResponse.ElicitationContent(Declined));
    Assert.AreEqual('', TMCPInputResponse.ElicitationField(nil, 'name'));
    Assert.AreEqual('Paris', TMCPInputResponse.SamplingText(Sampled));
    Assert.AreEqual('', TMCPInputResponse.SamplingText(Accepted));
    Assert.AreEqual(1, TMCPInputResponse.Roots(Roots).Count);
    Assert.IsNull(TMCPInputResponse.Roots(Sampled));
  finally
    Accepted.Free;
    Declined.Free;
    Sampled.Free;
    Roots.Free;
  end;
end;

{ TInputRequiredFlowTests }

procedure TInputRequiredFlowTests.Setup;
begin
  FHarness := TMCPTestHarness.Create;
  FHarness.Settings.RequestStateKey := SEALER_KEY;
  FProcessor := TMCPJsonRpcProcessor.Create(FHarness.ManagerRegistry, FHarness.Settings);
end;

procedure TInputRequiredFlowTests.TearDown;
begin
  FProcessor.Free;
  FHarness.Free;
end;

function TInputRequiredFlowTests.Call(const Method, ParamsJson: string; const Capabilities: string): TJSONObject;
begin
  var Meta := Format('"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":%s}',
    [Capabilities]);
  var Params := ParamsJson;
  if Params = '' then
    Params := Meta
  else
    Params := Params + ',' + Meta;
  var Body := Format('{"jsonrpc":"2.0","id":7,"method":"%s","params":{%s}}', [Method, Params]);
  var Outcome := FProcessor.ProcessRequestEx(Body, TMCPTransportHints.None);
  Result := TJSONObject.ParseJSONValue(Outcome.Body) as TJSONObject;
  Assert.IsNotNull(Result, 'response is not a JSON object: ' + Outcome.Body);
  Result.AddPair('httpStatus', TJSONNumber.Create(Outcome.HttpStatus));
end;

function TInputRequiredFlowTests.CallTool(const Name, ExtraParams: string; const Capabilities: string): TJSONObject;
begin
  var Params := Format('"name":"%s","arguments":{}', [Name]);
  if ExtraParams <> '' then
    Params := Params + ',' + ExtraParams;
  Result := Call('tools/call', Params, Capabilities);
end;

function TInputRequiredFlowTests.CallLegacy(const Name: string): TJSONObject;
begin
  var Body := Format('{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"%s","arguments":{}}}', [Name]);
  var Outcome := FProcessor.ProcessRequestEx(Body, TMCPTransportHints.ForHttp(True, '2025-11-25'));
  Result := TJSONObject.ParseJSONValue(Outcome.Body) as TJSONObject;
  Assert.IsNotNull(Result, 'response is not a JSON object: ' + Outcome.Body);
end;

function TInputRequiredFlowTests.ResultText(const Response: TJSONObject): string;
begin
  Result := Response.GetValue<string>('result.content[0].text', '');
end;

procedure TInputRequiredFlowTests.Elicitation_RoundOne_IsInputRequired_WithResultType;
begin
  var Response := CallTool('test_input_required_result_elicitation', '');
  try
    Assert.AreEqual(200, Response.GetValue<Integer>('httpStatus'));
    Assert.AreEqual('input_required', Response.GetValue<string>('result.resultType'));
    Assert.AreEqual('elicitation/create', Response.GetValue<string>('result.inputRequests.user_name.method'));
    Assert.AreEqual('What is your name?', Response.GetValue<string>('result.inputRequests.user_name.params.message'));
    Assert.AreEqual('name', Response.GetValue<string>('result.inputRequests.user_name.params.requestedSchema.required[0]'));
    Assert.IsNull(Response.FindValue('result.requestState'));
    Assert.IsNull(Response.FindValue('result.ttlMs'), 'cache hints only on complete results');
    Assert.IsNotNull((Response.FindValue('result._meta') as TJSONObject).GetValue(MCP_META_SERVER_INFO));
  finally
    Response.Free;
  end;
end;

procedure TInputRequiredFlowTests.Elicitation_RoundTwo_Completes;
begin
  var Response := CallTool('test_input_required_result_elicitation',
    '"inputResponses":{"user_name":{"action":"accept","content":{"name":"Alice"}}}');
  try
    Assert.AreEqual('complete', Response.GetValue<string>('result.resultType'));
    Assert.AreEqual('Hello, Alice!', ResultText(Response));
  finally
    Response.Free;
  end;
end;

procedure TInputRequiredFlowTests.Elicitation_WrongKey_ReRequests;
begin
  var Response := CallTool('test_input_required_result_elicitation',
    '"inputResponses":{"wrong_key":{"action":"accept","content":{"data":"wrong"}}}');
  try
    Assert.AreEqual('input_required', Response.GetValue<string>('result.resultType'));
    Assert.IsNotNull(Response.FindValue('result.inputRequests.user_name'));
  finally
    Response.Free;
  end;
end;

procedure TInputRequiredFlowTests.Elicitation_ExtraKeys_AreIgnored;
begin
  var Response := CallTool('test_input_required_result_elicitation',
    '"inputResponses":{"user_name":{"action":"accept","content":{"name":"Alice"}},"unknown_extra_key":{"action":"accept","content":{}}}');
  try
    Assert.AreEqual('Hello, Alice!', ResultText(Response));
  finally
    Response.Free;
  end;
end;

procedure TInputRequiredFlowTests.InputResponses_NotObject_IsInvalidParams;
begin
  var Response := CallTool('test_input_required_result_elicitation', '"inputResponses":null');
  try
    Assert.AreEqual(JSONRPC_INVALID_PARAMS, Response.GetValue<Integer>('error.code'));
  finally
    Response.Free;
  end;
end;

procedure TInputRequiredFlowTests.InputResponses_ValueNotObject_IsInvalidParams;
begin
  var Response := CallTool('test_input_required_result_elicitation', '"inputResponses":{"user_name":12345}');
  try
    Assert.AreEqual(JSONRPC_INVALID_PARAMS, Response.GetValue<Integer>('error.code'));
  finally
    Response.Free;
  end;
end;

procedure TInputRequiredFlowTests.Sampling_RoundTrip;
begin
  var First := CallTool('test_input_required_result_sampling', '');
  try
    Assert.AreEqual('sampling/createMessage', First.GetValue<string>('result.inputRequests.capital_question.method'));
    Assert.AreEqual('What is the capital of France?',
      First.GetValue<string>('result.inputRequests.capital_question.params.messages[0].content.text'));
    Assert.AreEqual(100, First.GetValue<Integer>('result.inputRequests.capital_question.params.maxTokens'));
  finally
    First.Free;
  end;

  var Second := CallTool('test_input_required_result_sampling',
    '"inputResponses":{"capital_question":{"role":"assistant","content":{"type":"text","text":"Paris"},"model":"m","stopReason":"endTurn"}}');
  try
    Assert.AreEqual('LLM response: Paris', ResultText(Second));
  finally
    Second.Free;
  end;
end;

procedure TInputRequiredFlowTests.ListRoots_RoundTrip;
begin
  var First := CallTool('test_input_required_result_list_roots', '');
  try
    Assert.AreEqual('roots/list', First.GetValue<string>('result.inputRequests.client_roots.method'));
  finally
    First.Free;
  end;

  var Second := CallTool('test_input_required_result_list_roots',
    '"inputResponses":{"client_roots":{"roots":[{"uri":"file:///test/root","name":"Test Root"}]}}');
  try
    Assert.AreEqual('Roots: file:///test/root', ResultText(Second));
  finally
    Second.Free;
  end;
end;

procedure TInputRequiredFlowTests.RequestState_RoundTrip_MentionsStateOk;
begin
  var First := CallTool('test_input_required_result_request_state', '');
  var Token := '';
  try
    Assert.AreEqual('elicitation/create', First.GetValue<string>('result.inputRequests.confirm.method'));
    Assert.AreEqual('boolean', First.GetValue<string>('result.inputRequests.confirm.params.requestedSchema.properties.ok.type'));
    Token := First.GetValue<string>('result.requestState');
    Assert.IsTrue(Token <> '');
  finally
    First.Free;
  end;

  var Second := CallTool('test_input_required_result_request_state',
    Format('"inputResponses":{"confirm":{"action":"accept","content":{"ok":true}}},"requestState":"%s"', [Token]));
  try
    Assert.AreEqual('complete', Second.GetValue<string>('result.resultType'));
    Assert.IsTrue(ResultText(Second).Contains('state-ok'), ResultText(Second));
  finally
    Second.Free;
  end;
end;

procedure TInputRequiredFlowTests.RequestState_Tampered_IsInvalidParams;
begin
  var First := CallTool('test_input_required_result_tampered_state', '');
  var Token := '';
  try
    Token := First.GetValue<string>('result.requestState');
  finally
    First.Free;
  end;

  var Second := CallTool('test_input_required_result_tampered_state',
    Format('"inputResponses":{"confirm":{"action":"accept","content":{"ok":true}}},"requestState":"%s-TAMPERED"', [Token]));
  try
    Assert.AreEqual(JSONRPC_INVALID_PARAMS, Second.GetValue<Integer>('error.code'));
    Assert.AreEqual(200, Second.GetValue<Integer>('httpStatus'));
  finally
    Second.Free;
  end;

  var Third := CallTool('test_input_required_result_tampered_state',
    '"inputResponses":{"confirm":{"action":"accept","content":{"ok":true}}},"requestState":42');
  try
    Assert.AreEqual(JSONRPC_INVALID_PARAMS, Third.GetValue<Integer>('error.code'));
  finally
    Third.Free;
  end;
end;

procedure TInputRequiredFlowTests.RequestState_OtherTool_IsInvalidParams;
begin
  var First := CallTool('test_input_required_result_request_state', '');
  var Token := '';
  try
    Token := First.GetValue<string>('result.requestState');
  finally
    First.Free;
  end;

  var Second := CallTool('test_input_required_result_tampered_state',
    Format('"inputResponses":{"confirm":{"action":"accept","content":{"ok":true}}},"requestState":"%s"', [Token]));
  try
    Assert.AreEqual(JSONRPC_INVALID_PARAMS, Second.GetValue<Integer>('error.code'));
  finally
    Second.Free;
  end;
end;

procedure TInputRequiredFlowTests.MultipleInputs_RoundTrip;
begin
  var First := CallTool('test_input_required_result_multiple_inputs', '');
  var Token := '';
  try
    Assert.AreEqual('elicitation/create', First.GetValue<string>('result.inputRequests.user_name.method'));
    Assert.AreEqual('sampling/createMessage', First.GetValue<string>('result.inputRequests.greeting.method'));
    Assert.AreEqual('roots/list', First.GetValue<string>('result.inputRequests.client_roots.method'));
    Token := First.GetValue<string>('result.requestState');
    Assert.IsTrue(Token <> '');
  finally
    First.Free;
  end;

  var Second := CallTool('test_input_required_result_multiple_inputs', Format(
    '"inputResponses":{"user_name":{"action":"accept","content":{"name":"Alice"}},'
    + '"greeting":{"role":"assistant","content":{"type":"text","text":"Hello there"}},'
    + '"client_roots":{"roots":[{"uri":"file:///test/root"}]}},"requestState":"%s"', [Token]));
  try
    Assert.AreEqual('Hello there, Alice! Roots: file:///test/root', ResultText(Second));
  finally
    Second.Free;
  end;
end;

procedure TInputRequiredFlowTests.MultiRound_StateChangesPerRound;
begin
  var First := CallTool('test_input_required_result_multi_round', '');
  var Token1 := '';
  try
    Assert.IsNotNull(First.FindValue('result.inputRequests.step1'));
    Token1 := First.GetValue<string>('result.requestState');
  finally
    First.Free;
  end;

  var Second := CallTool('test_input_required_result_multi_round',
    Format('"inputResponses":{"step1":{"action":"accept","content":{"name":"Alice"}}},"requestState":"%s"', [Token1]));
  var Token2 := '';
  try
    Assert.AreEqual('input_required', Second.GetValue<string>('result.resultType'));
    Assert.IsNotNull(Second.FindValue('result.inputRequests.step2'));
    Assert.IsNull(Second.FindValue('result.inputRequests.step1'));
    Token2 := Second.GetValue<string>('result.requestState');
    Assert.AreNotEqual(Token1, Token2);
  finally
    Second.Free;
  end;

  var Third := CallTool('test_input_required_result_multi_round',
    Format('"inputResponses":{"step2":{"action":"accept","content":{"color":"blue"}}},"requestState":"%s"', [Token2]));
  try
    Assert.AreEqual('Hello, Alice! Your favorite color is blue.', ResultText(Third));
  finally
    Third.Free;
  end;
end;

procedure TInputRequiredFlowTests.Capabilities_OnlyDeclaredKinds;
begin
  var Response := CallTool('test_input_required_result_capabilities', '', '{"sampling":{}}');
  try
    Assert.AreEqual('input_required', Response.GetValue<string>('result.resultType'));
    Assert.IsNotNull(Response.FindValue('result.inputRequests.capital_question'));
    Assert.IsNull(Response.FindValue('result.inputRequests.user_name'));
    Assert.IsNull(Response.FindValue('result.inputRequests.client_roots'));
  finally
    Response.Free;
  end;

  var None := CallTool('test_input_required_result_capabilities', '', '{}');
  try
    Assert.AreEqual('complete', None.GetValue<string>('result.resultType'));
  finally
    None.Free;
  end;
end;

procedure TInputRequiredFlowTests.Capabilities_UndeclaredKind_Is32021;
begin
  var Response := CallTool('test_input_required_result_elicitation', '', '{"sampling":{}}');
  try
    Assert.AreEqual(MCP_ERROR_MISSING_REQUIRED_CLIENT_CAPABILITY, Response.GetValue<Integer>('error.code'));
    Assert.AreEqual(400, Response.GetValue<Integer>('httpStatus'));
    Assert.IsNotNull(Response.FindValue('error.data.requiredCapabilities.elicitation'));
  finally
    Response.Free;
  end;
end;

procedure TInputRequiredFlowTests.MissingCapabilityTool_Is32021_WithRequiredCapabilities;
begin
  var Response := CallTool('test_missing_capability', '', '{"elicitation":{}}');
  try
    Assert.AreEqual(MCP_ERROR_MISSING_REQUIRED_CLIENT_CAPABILITY, Response.GetValue<Integer>('error.code'));
    Assert.AreEqual(400, Response.GetValue<Integer>('httpStatus'));
    Assert.IsTrue(Response.FindValue('error.data.requiredCapabilities.sampling') is TJSONObject);
  finally
    Response.Free;
  end;

  var Declared := CallTool('test_missing_capability', '', '{"sampling":{}}');
  try
    Assert.AreEqual('complete', Declared.GetValue<string>('result.resultType'));
  finally
    Declared.Free;
  end;
end;

procedure TInputRequiredFlowTests.Legacy_IsInternalError;
begin
  var Response := CallLegacy('test_input_required_result_elicitation');
  try
    Assert.AreEqual(JSONRPC_INTERNAL_ERROR, Response.GetValue<Integer>('error.code'));
    Assert.IsTrue(Response.GetValue<string>('error.message').Contains('2025-11-25'));
  finally
    Response.Free;
  end;
end;

procedure TInputRequiredFlowTests.Prompt_RoundTrip;
begin
  var First := Call('prompts/get', '"name":"test_input_required_result_prompt"');
  try
    Assert.AreEqual('input_required', First.GetValue<string>('result.resultType'));
    Assert.AreEqual('elicitation/create', First.GetValue<string>('result.inputRequests.user_context.method'));
    Assert.AreEqual('context', First.GetValue<string>('result.inputRequests.user_context.params.requestedSchema.required[0]'));
  finally
    First.Free;
  end;

  var Second := Call('prompts/get',
    '"name":"test_input_required_result_prompt","inputResponses":{"user_context":{"action":"accept","content":{"context":"test context"}}}');
  try
    Assert.AreEqual('complete', Second.GetValue<string>('result.resultType'));
    Assert.AreEqual('Use this context: test context', Second.GetValue<string>('result.messages[0].content.text'));
  finally
    Second.Free;
  end;
end;

procedure TInputRequiredFlowTests.ToolsList_IsNeverInputRequired;
begin
  var Response := Call('tools/list', '"inputResponses":{"x":{}},"requestState":"ignored"');
  try
    Assert.AreEqual('complete', Response.GetValue<string>('result.resultType'));
  finally
    Response.Free;
  end;
end;

end.
