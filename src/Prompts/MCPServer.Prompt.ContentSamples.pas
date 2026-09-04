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

implementation

uses
  MCPServer.Registration;

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

end.
