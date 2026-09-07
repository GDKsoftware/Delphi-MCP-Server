unit MCPServer.Tests.Prompt;

interface

uses
  DUnitX.TestFramework,
  System.SysUtils,
  System.JSON,
  System.Generics.Collections,
  MCPServer.Types,
  MCPServer.Prompt.Base;

type
  TGreetingParams = class
  private
    FName: string;
    FTone: string;
  public
    [SchemaDescription('Who to greet')]
    property Name: string read FName write FName;
    [Optional]
    [SchemaDescription('Tone of voice')]
    property Tone: string read FTone write FTone;
  end;

  TGreetingPrompt = class(TMCPPromptBase<TGreetingParams>)
  protected
    function ExecuteWithParams(const Params: TGreetingParams; Messages: TMCPPromptMessages): string; override;
  public
    constructor Create; override;
  end;

  [TestFixture]
  TPromptMessagesTests = class
  public
    [Test] procedure AddText_ProducesOneMessage;
    [Test] procedure ContentIsASingleObject_NotAnArray;
    [Test] procedure Image_Audio_ResourceLink_Embedded_Blocks;
    [Test] procedure WithAnnotations_AttachesToLastMessage;
    [Test] procedure WithAnnotations_BeforeAnyMessage_AttachesToTheNextMessage;
    [Test] procedure ToJson_ReturnsAClone;
  end;

  [TestFixture]
  TPromptBaseTests = class
  public
    [Test] procedure Arguments_DerivedFromRttiWithDescriptionAndRequired;
    [Test] procedure Get_BuildsMessages_AndReturnsDescription;
    [Test] procedure Get_MissingRequiredArgument_Raises;
  end;

implementation

{ TGreetingPrompt }

constructor TGreetingPrompt.Create;
begin
  inherited;
  FName := 'greeting';
  FDescription := 'Greets someone';
end;

function TGreetingPrompt.ExecuteWithParams(const Params: TGreetingParams; Messages: TMCPPromptMessages): string;
begin
  var Tone := Params.Tone;
  if Tone = '' then
    Tone := 'friendly';
  Messages.AddText('user', Format('Write a %s greeting for %s.', [Tone, Params.Name]));
  Result := 'Greeting request';
end;

{ TPromptMessagesTests }

procedure TPromptMessagesTests.AddText_ProducesOneMessage;
begin
  var Messages := TMCPPromptMessages.Create.AddText('user', 'hello');
  var Json := Messages.ToJson;
  try
    Assert.AreEqual(1, Json.Count);
    Assert.AreEqual('user', Json.Items[0].GetValue<string>('role'));
    Assert.AreEqual('text', Json.Items[0].GetValue<string>('content.type'));
    Assert.AreEqual('hello', Json.Items[0].GetValue<string>('content.text'));
  finally
    Json.Free;
    Messages.Free;
  end;
end;

procedure TPromptMessagesTests.ContentIsASingleObject_NotAnArray;
begin
  var Messages := TMCPPromptMessages.Create.AddText('user', 'hi');
  var Json := Messages.ToJson;
  try
    Assert.IsTrue((Json.Items[0] as TJSONObject).GetValue('content') is TJSONObject,
      'prompts/get content is one object per message, not an array');
  finally
    Json.Free;
    Messages.Free;
  end;
end;

procedure TPromptMessagesTests.Image_Audio_ResourceLink_Embedded_Blocks;
begin
  var Messages := TMCPPromptMessages.Create
    .AddImage('user', TEncoding.UTF8.GetBytes('png'), 'image/png')
    .AddAudio('assistant', 'AAAA', 'audio/wav')
    .AddResourceLink('user', 'file:///a.txt', 'a.txt', 'A file', 'text/plain')
    .AddEmbeddedText('user', 'test://x', 'text/plain', 'body');
  var Json := Messages.ToJson;
  try
    Assert.AreEqual(4, Json.Count);
    Assert.AreEqual('image', Json.Items[0].GetValue<string>('content.type'));
    Assert.AreEqual('cG5n', Json.Items[0].GetValue<string>('content.data'));
    Assert.AreEqual('assistant', Json.Items[1].GetValue<string>('role'));
    Assert.AreEqual('audio', Json.Items[1].GetValue<string>('content.type'));
    Assert.AreEqual('resource_link', Json.Items[2].GetValue<string>('content.type'));
    Assert.AreEqual('A file', Json.Items[2].GetValue<string>('content.description'));
    Assert.AreEqual('resource', Json.Items[3].GetValue<string>('content.type'));
    Assert.AreEqual('body', Json.Items[3].GetValue<string>('content.resource.text'));
  finally
    Json.Free;
    Messages.Free;
  end;
end;

procedure TPromptMessagesTests.WithAnnotations_BeforeAnyMessage_AttachesToTheNextMessage;
begin
  var Annotations := TJSONObject.Create;
  Annotations.AddPair('priority', TJSONNumber.Create(0.5));
  var Messages := TMCPPromptMessages.Create.WithAnnotations(Annotations).AddText('user', 'first');
  Messages.AddText('user', 'second');
  var Json := Messages.ToJson;
  try
    Assert.AreEqual(0.5, Json.Items[0].GetValue<Double>('content.annotations.priority'), 0.0001);
    Assert.IsNull(Json.Items[1].FindValue('content.annotations'));
  finally
    Json.Free;
    Messages.Free;
  end;
end;

procedure TPromptMessagesTests.WithAnnotations_AttachesToLastMessage;
begin
  var Annotations := TJSONObject.Create;
  Annotations.AddPair('priority', TJSONNumber.Create(0.5));
  var Messages := TMCPPromptMessages.Create.AddText('user', 'first').AddText('user', 'second');
  Messages.WithAnnotations(Annotations);
  var Json := Messages.ToJson;
  try
    Assert.IsNull(Json.Items[0].FindValue('content.annotations'));
    Assert.AreEqual(0.5, Json.Items[1].GetValue<Double>('content.annotations.priority'), 0.0001);
  finally
    Json.Free;
    Messages.Free;
  end;
end;

procedure TPromptMessagesTests.ToJson_ReturnsAClone;
begin
  var Messages := TMCPPromptMessages.Create.AddText('user', 'hi');
  var First := Messages.ToJson;
  var Second := Messages.ToJson;
  try
    Assert.AreNotSame(First, Second);
  finally
    First.Free;
    Second.Free;
    Messages.Free;
  end;
end;

{ TPromptBaseTests }

procedure TPromptBaseTests.Arguments_DerivedFromRttiWithDescriptionAndRequired;
begin
  var Prompt: IMCPPrompt := TGreetingPrompt.Create;
  var Args := Prompt.Arguments;
  Assert.AreEqual(2, Integer(Length(Args)));
  var NameArg := Args[0];
  var ToneArg := Args[1];
  Assert.AreEqual('name', NameArg.Name);
  Assert.AreEqual('Who to greet', NameArg.Description);
  Assert.IsTrue(NameArg.Required);
  Assert.AreEqual('tone', ToneArg.Name);
  Assert.IsFalse(ToneArg.Required);
end;

procedure TPromptBaseTests.Get_BuildsMessages_AndReturnsDescription;
begin
  var Prompt: IMCPPrompt := TGreetingPrompt.Create;
  var Arguments := TJSONObject.ParseJSONValue('{"name":"Ada"}') as TJSONObject;
  var Messages := TMCPPromptMessages.Create;
  try
    var Description := Prompt.Get(Arguments, Messages);
    Assert.AreEqual('Greeting request', Description);
    var Json := Messages.ToJson;
    try
      Assert.AreEqual('Write a friendly greeting for Ada.', Json.Items[0].GetValue<string>('content.text'));
    finally
      Json.Free;
    end;
  finally
    Arguments.Free;
    Messages.Free;
  end;
end;

procedure TPromptBaseTests.Get_MissingRequiredArgument_Raises;
begin
  var Prompt: IMCPPrompt := TGreetingPrompt.Create;
  var Arguments := TJSONObject.Create;
  var Messages := TMCPPromptMessages.Create;
  try
    var Call: TProc := procedure begin Prompt.Get(Arguments, Messages) end;
    Assert.WillRaise(Call, EArgumentException);
  finally
    Arguments.Free;
    Messages.Free;
  end;
end;

end.
