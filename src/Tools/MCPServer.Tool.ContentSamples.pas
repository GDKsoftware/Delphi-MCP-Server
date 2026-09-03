unit MCPServer.Tool.ContentSamples;

interface

uses
  System.SysUtils,
  System.Rtti,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Base;

type
  TNoParams = class
  end;

  /// Plain text result. The names of these sample tools follow the official
  /// conformance suite, which calls them by name.
  TSimpleTextTool = class(TMCPToolBase<TNoParams>)
  protected
    function ExecuteWithParams(const Params: TNoParams): string; override;
  public
    constructor Create; override;
  end;

  /// One image block (a 1x1 PNG).
  TImageContentTool = class(TMCPToolBase<TNoParams>)
  protected
    function ExecuteWithContext(const Params: TNoParams; const Context: IMCPRequestContext): TValue; override;
  public
    constructor Create; override;
  end;

  /// One audio block (a silent WAV).
  TAudioContentTool = class(TMCPToolBase<TNoParams>)
  protected
    function ExecuteWithContext(const Params: TNoParams; const Context: IMCPRequestContext): TValue; override;
  public
    constructor Create; override;
  end;

  /// An embedded text resource.
  TEmbeddedResourceTool = class(TMCPToolBase<TNoParams>)
  protected
    function ExecuteWithContext(const Params: TNoParams; const Context: IMCPRequestContext): TValue; override;
  public
    constructor Create; override;
  end;

  /// Text, image and an embedded resource in one result.
  TMultipleContentTypesTool = class(TMCPToolBase<TNoParams>)
  protected
    function ExecuteWithContext(const Params: TNoParams; const Context: IMCPRequestContext): TValue; override;
  public
    constructor Create; override;
  end;

  /// Always fails with a tool execution error (isError: true).
  TProgressToolParams = class
  private
    FSteps: Integer;
    FStepMs: Integer;
  public
    [Optional]
    [SchemaDescription('Number of steps to report (default 5)')]
    property Steps: Integer read FSteps write FSteps;
    [Optional]
    [SchemaDescription('Pause per step in milliseconds (default 100)')]
    property StepMs: Integer read FStepMs write FStepMs;
  end;

  /// Reports progress for every step and stops when the client cancels.
  TProgressTool = class(TMCPToolBase<TProgressToolParams>)
  public
    const DEFAULT_STEPS = 5;
    const DEFAULT_STEP_MS = 100;
    const MAX_STEPS = 1000;
    const MAX_STEP_MS = 10000;
  protected
    function ExecuteWithContext(const Params: TProgressToolParams;
      const Context: IMCPRequestContext): TValue; override;
  public
    constructor Create; override;
  end;

  TErrorHandlingTool = class(TMCPToolBase<TNoParams>)
  protected
    function ExecuteWithParams(const Params: TNoParams): string; override;
  public
    constructor Create; override;
  end;

  /// A hand-written schema exercising the JSON Schema 2020-12 keywords the
  /// conformance suite checks for verbatim preservation: $schema, $defs,
  /// $anchor, $ref, allOf/anyOf, if/then/else and additionalProperties.
  TJsonSchema202012Tool = class(TMCPToolBase)
  protected
    function BuildSchema: TJSONObject; override;
    function DoExecute(const Arguments: TJSONObject): TValue; override;
  public
    constructor Create; override;
  end;

const
  SAMPLE_TEXT_RESOURCE_URI = 'test://static-text';
  SAMPLE_TEXT_RESOURCE_CONTENT = 'This is the content of the static text resource.';
  /// A 1x1 transparent PNG.
  SAMPLE_PNG_BASE64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';
  /// A WAV header for 8 kHz mono 8-bit audio with no samples.
  SAMPLE_WAV_BASE64 = 'UklGRiQAAABXQVZFZm10IBAAAAABAAEAQB8AAEAfAAABAAgAZGF0YQAAAAA=';

implementation

uses
  MCPServer.Errors,
  MCPServer.Registration,
  MCPServer.Tool.Result;

{ TSimpleTextTool }

constructor TSimpleTextTool.Create;
begin
  inherited;
  FName := 'test_simple_text';
  FDescription := 'Returns a plain text result';
  FAnnotations := TJSONObject.Create;
  FAnnotations.AddPair('readOnlyHint', TJSONBool.Create(True));
end;

function TSimpleTextTool.ExecuteWithParams(const Params: TNoParams): string;
begin
  Result := 'This is a simple text response';
end;

{ TImageContentTool }

constructor TImageContentTool.Create;
begin
  inherited;
  FName := 'test_image_content';
  FDescription := 'Returns an image content block';
end;

function TImageContentTool.ExecuteWithContext(const Params: TNoParams; const Context: IMCPRequestContext): TValue;
begin
  Result := TMCPToolResult.Create.AddImage(SAMPLE_PNG_BASE64, 'image/png');
end;

{ TAudioContentTool }

constructor TAudioContentTool.Create;
begin
  inherited;
  FName := 'test_audio_content';
  FDescription := 'Returns an audio content block';
end;

function TAudioContentTool.ExecuteWithContext(const Params: TNoParams; const Context: IMCPRequestContext): TValue;
begin
  Result := TMCPToolResult.Create.AddAudio(SAMPLE_WAV_BASE64, 'audio/wav');
end;

{ TEmbeddedResourceTool }

constructor TEmbeddedResourceTool.Create;
begin
  inherited;
  FName := 'test_embedded_resource';
  FDescription := 'Returns an embedded resource content block';
end;

function TEmbeddedResourceTool.ExecuteWithContext(const Params: TNoParams; const Context: IMCPRequestContext): TValue;
begin
  Result := TMCPToolResult.Create.AddEmbeddedText(SAMPLE_TEXT_RESOURCE_URI, 'text/plain', SAMPLE_TEXT_RESOURCE_CONTENT);
end;

{ TMultipleContentTypesTool }

constructor TMultipleContentTypesTool.Create;
begin
  inherited;
  FName := 'test_multiple_content_types';
  FDescription := 'Returns text, image and embedded resource content in one result';
end;

function TMultipleContentTypesTool.ExecuteWithContext(const Params: TNoParams; const Context: IMCPRequestContext): TValue;
begin
  Result := TMCPToolResult.Create
    .AddText('Multiple content types example')
    .AddImage(SAMPLE_PNG_BASE64, 'image/png')
    .AddEmbeddedText(SAMPLE_TEXT_RESOURCE_URI, 'text/plain', SAMPLE_TEXT_RESOURCE_CONTENT);
end;

{ TErrorHandlingTool }

constructor TErrorHandlingTool.Create;
begin
  inherited;
  FName := 'test_error_handling';
  FDescription := 'Always fails with a tool execution error';
end;

function TErrorHandlingTool.ExecuteWithParams(const Params: TNoParams): string;
begin
  raise EMCPToolError.Create('This tool always fails, as an example of a tool execution error');
end;

{ TProgressTool }

constructor TProgressTool.Create;
begin
  inherited;
  FName := 'test_tool_with_progress';
  FDescription := 'Runs a few steps and reports progress for each; honours cancellation';
end;

function TProgressTool.ExecuteWithContext(const Params: TProgressToolParams;
  const Context: IMCPRequestContext): TValue;
begin
  var Steps := Params.Steps;
  if (Steps <= 0) or (Steps > MAX_STEPS) then
    Steps := DEFAULT_STEPS;
  var StepMs := Params.StepMs;
  if (StepMs <= 0) or (StepMs > MAX_STEP_MS) then
    StepMs := DEFAULT_STEP_MS;

  for var Step := 1 to Steps do
  begin
    if Assigned(Context) then
    begin
      Context.CheckCancelled;
      Context.ReportProgress(Step - 1, Steps, Format('Step %d of %d', [Step, Steps]));
    end;
    Sleep(StepMs);
  end;
  if Assigned(Context) then
    Context.ReportProgress(Steps, Steps, 'Done');

  Result := Format('Completed %d steps', [Steps]);
end;

{ TJsonSchema202012Tool }

constructor TJsonSchema202012Tool.Create;
begin
  inherited;
  FName := 'json_schema_2020_12_tool';
  FDescription := 'Tool with JSON Schema 2020-12 features';
end;

function TJsonSchema202012Tool.BuildSchema: TJSONObject;
begin
  Result := TJSONObject.ParseJSONValue(
    '{'+
    '"$schema":"https://json-schema.org/draft/2020-12/schema",'+
    '"type":"object",'+
    '"$defs":{"address":{"$anchor":"addressDef","type":"object",'+
      '"properties":{"street":{"type":"string"},"city":{"type":"string"}}}},'+
    '"properties":{'+
      '"name":{"type":"string"},'+
      '"address":{"$ref":"#/$defs/address"},'+
      '"contactMethod":{"type":"string","enum":["phone","email"]},'+
      '"phone":{"type":"string"},'+
      '"email":{"type":"string"}'+
    '},'+
    '"allOf":[{"anyOf":[{"required":["phone"]},{"required":["email"]}]}],'+
    '"if":{"properties":{"contactMethod":{"const":"phone"}},"required":["contactMethod"]},'+
    '"then":{"required":["phone"]},'+
    '"else":{"required":["email"]},'+
    '"additionalProperties":false'+
    '}') as TJSONObject;
end;

function TJsonSchema202012Tool.DoExecute(const Arguments: TJSONObject): TValue;
begin
  Result := TValue.From<string>('ok');
end;

initialization
  TMCPRegistry.RegisterTool('test_simple_text',
    function: IMCPTool
    begin
      Result := TSimpleTextTool.Create;
    end);
  TMCPRegistry.RegisterTool('test_image_content',
    function: IMCPTool
    begin
      Result := TImageContentTool.Create;
    end);
  TMCPRegistry.RegisterTool('test_audio_content',
    function: IMCPTool
    begin
      Result := TAudioContentTool.Create;
    end);
  TMCPRegistry.RegisterTool('test_embedded_resource',
    function: IMCPTool
    begin
      Result := TEmbeddedResourceTool.Create;
    end);
  TMCPRegistry.RegisterTool('test_multiple_content_types',
    function: IMCPTool
    begin
      Result := TMultipleContentTypesTool.Create;
    end);
  TMCPRegistry.RegisterTool('test_tool_with_progress',
    function: IMCPTool
    begin
      Result := TProgressTool.Create;
    end);
  TMCPRegistry.RegisterTool('test_error_handling',
    function: IMCPTool
    begin
      Result := TErrorHandlingTool.Create;
    end);
  TMCPRegistry.RegisterTool('json_schema_2020_12_tool',
    function: IMCPTool
    begin
      Result := TJsonSchema202012Tool.Create;
    end);

end.
