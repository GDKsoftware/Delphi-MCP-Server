unit MCPServer.Prompt.ContentSamples;

interface

uses
  System.SysUtils,
  MCPServer.Types,
  MCPServer.Prompt.Base,
  MCPServer.Tool.ContentSamples;

type
  TArgumentsPromptParams = class
  private
    FArg1: string;
    FArg2: string;
  public
    [SchemaDescription('First test argument')]
    property Arg1: string read FArg1 write FArg1;
    [SchemaDescription('Second test argument')]
    property Arg2: string read FArg2 write FArg2;
  end;

  TEmbeddedResourcePromptParams = class
  private
    FResourceUri: string;
  public
    [SchemaName('resourceUri')]
    [SchemaDescription('URI of the resource to embed')]
    property ResourceUri: string read FResourceUri write FResourceUri;
  end;

  TSimplePrompt = class(TMCPPromptBase<TNoParams>)
  protected
    function ExecuteWithParams(const Params: TNoParams; Messages: TMCPPromptMessages): string; override;
  public
    constructor Create; override;
  end;

  TArgumentsPrompt = class(TMCPPromptBase<TArgumentsPromptParams>)
  protected
    function ExecuteWithParams(const Params: TArgumentsPromptParams; Messages: TMCPPromptMessages): string; override;
  public
    constructor Create; override;
  end;

  TEmbeddedResourcePrompt = class(TMCPPromptBase<TEmbeddedResourcePromptParams>)
  protected
    function ExecuteWithParams(const Params: TEmbeddedResourcePromptParams; Messages: TMCPPromptMessages): string; override;
  public
    constructor Create; override;
  end;

  TImagePrompt = class(TMCPPromptBase<TNoParams>)
  protected
    function ExecuteWithParams(const Params: TNoParams; Messages: TMCPPromptMessages): string; override;
  public
    constructor Create; override;
  end;

  TInputRequiredPrompt = class(TMCPPromptBase<TNoParams>)
  protected
    function ExecuteWithParams(const Params: TNoParams; Messages: TMCPPromptMessages): string; override;
  public
    constructor Create; override;
  end;

implementation

uses
  System.JSON,
  MCPServer.Mrtr,
  MCPServer.RequestContext,
  MCPServer.Registration;

const
  KEY_USER_CONTEXT = 'user_context';
  FIELD_CONTEXT = 'context';

{ TSimplePrompt }

constructor TSimplePrompt.Create;
begin
  inherited;
  FName := 'test_simple_prompt';
  FDescription := 'A simple prompt with no arguments';
end;

function TSimplePrompt.ExecuteWithParams(const Params: TNoParams; Messages: TMCPPromptMessages): string;
begin
  Messages.AddText('user', 'This is a simple prompt for testing.');
  Result := 'Simple prompt';
end;

{ TArgumentsPrompt }

constructor TArgumentsPrompt.Create;
begin
  inherited;
  FName := 'test_prompt_with_arguments';
  FDescription := 'A prompt that substitutes its arguments into the message';
end;

function TArgumentsPrompt.ExecuteWithParams(const Params: TArgumentsPromptParams;
  Messages: TMCPPromptMessages): string;
begin
  Messages.AddText('user', Format('Prompt with arguments: arg1=''%s'', arg2=''%s''', [Params.Arg1, Params.Arg2]));
  Result := 'Prompt with arguments';
end;

{ TEmbeddedResourcePrompt }

constructor TEmbeddedResourcePrompt.Create;
begin
  inherited;
  FName := 'test_prompt_with_embedded_resource';
  FDescription := 'A prompt that embeds the resource named by its argument';
end;

function TEmbeddedResourcePrompt.ExecuteWithParams(const Params: TEmbeddedResourcePromptParams;
  Messages: TMCPPromptMessages): string;
begin
  Messages.AddEmbeddedText('user', Params.ResourceUri, 'text/plain', 'Embedded resource content for testing.');
  Messages.AddText('user', 'Please process the embedded resource above.');
  Result := 'Prompt with embedded resource';
end;

{ TImagePrompt }

constructor TImagePrompt.Create;
begin
  inherited;
  FName := 'test_prompt_with_image';
  FDescription := 'A prompt that returns an image content block';
end;

function TImagePrompt.ExecuteWithParams(const Params: TNoParams; Messages: TMCPPromptMessages): string;
begin
  Messages.AddImage('user', SAMPLE_PNG_BASE64, 'image/png');
  Messages.AddText('user', 'Please analyze the image above.');
  Result := 'Prompt with image';
end;

{ TInputRequiredPrompt }

constructor TInputRequiredPrompt.Create;
begin
  inherited;
  FName := 'test_input_required_result_prompt';
  FDescription := 'Asks the client which context to use before it renders';
end;

function TInputRequiredPrompt.ExecuteWithParams(const Params: TNoParams; Messages: TMCPPromptMessages): string;
var
  Response: TJSONObject;
begin
  var UserContext := '';
  var Context := TMCPRequestContext.Current;
  if Assigned(Context) and Context.TryGetInputResponse(KEY_USER_CONTEXT, Response) then
    UserContext := TMCPInputResponse.ElicitationField(Response, FIELD_CONTEXT);
  if UserContext = '' then
    raise EMCPInputRequired.Create(TMCPInputRequests.Create.AddElicitation(KEY_USER_CONTEXT,
      'What context should the prompt use?', TMCPInputRequests.FieldSchema(FIELD_CONTEXT)));

  Messages.AddText('user', Format('Use this context: %s', [UserContext]));
  Result := 'Prompt with client-provided context';
end;

initialization
  TMCPRegistry.RegisterPrompt('test_simple_prompt',
    function: IMCPPrompt
    begin
      Result := TSimplePrompt.Create;
    end);
  TMCPRegistry.RegisterPrompt('test_prompt_with_arguments',
    function: IMCPPrompt
    begin
      Result := TArgumentsPrompt.Create;
    end);
  TMCPRegistry.RegisterPrompt('test_prompt_with_embedded_resource',
    function: IMCPPrompt
    begin
      Result := TEmbeddedResourcePrompt.Create;
    end);
  TMCPRegistry.RegisterPrompt('test_prompt_with_image',
    function: IMCPPrompt
    begin
      Result := TImagePrompt.Create;
    end);
  TMCPRegistry.RegisterPrompt('test_input_required_result_prompt',
    function: IMCPPrompt
    begin
      Result := TInputRequiredPrompt.Create;
    end);

end.
