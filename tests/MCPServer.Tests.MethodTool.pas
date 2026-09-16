unit MCPServer.Tests.MethodTool;

interface

uses
  DUnitX.TestFramework,
  System.Rtti,
  System.JSON,
  System.Generics.Collections,
  MCPServer.Types,
  MCPServer.Tool.Base,
  MCPServer.Tool.Method;

type
  TCountedFilter = class
  private
    FCustomer: string;
    FLimit: Integer;
  public
    class var DestroyCount: Integer;
    destructor Destroy; override;
    property Customer: string read FCustomer write FCustomer;
    [Optional]
    property Limit: Integer read FLimit write FLimit;
  end;

  TCountedLine = class
  private
    FSku: string;
    FQuantity: Integer;
  public
    class var DestroyCount: Integer;
    destructor Destroy; override;
    property Sku: string read FSku write FSku;
    property Quantity: Integer read FQuantity write FQuantity;
  end;

  TSampleBox = record
    Width: Integer;
    Height: Integer;
  end;

  TSampleLabelled = record
    Caption: string;
    Box: TSampleBox;
    [Optional]
    Note: string;
  end;

  TSampleTarget = class
  private
    FSeen: string;
    FKept: TCountedFilter;
  public
    destructor Destroy; override;
    procedure Ping;
    procedure Remember(const Note: string);
    function Add(const Left, Right: Integer): Integer;
    function Greet(const Person: string): string;
    function Describe(const Filter: TCountedFilter): string;
    function JoinSkus(const Skus: TArray<string>): string;
    function CountLines(const Lines: TArray<TCountedLine>): Integer;
    function MakeLine: TCountedLine;
    function MakeLines: TArray<TCountedLine>;
    function Tagged([SchemaName('colour_tag')] const Tag: string): string;
    function WithOptional(const Base: string; [Optional] const Suffix: string): string;
    function Keep(const Filter: TCountedFilter): string;
    function Area(const Box: TSampleBox): Integer;
    function Grow(const Box: TSampleBox): TSampleBox;
    function Caption(const Labelled: TSampleLabelled): string;
    property Seen: string read FSeen;
    property Kept: TCountedFilter read FKept;
  end;

  TEnvelopeTool = class(TMCPMethodTool)
  protected
    function ResultToJson(const Value: TValue; const ResultType: TRttiType): TJSONValue; override;
  public
    function GetOutputSchema: TJSONObject; override;
  end;

  TMismatchedTool = class(TMCPMethodTool)
  protected
    function ResultToJson(const Value: TValue; const ResultType: TRttiType): TJSONValue; override;
  end;

  TKeepingTool = class(TMCPMethodTool)
  protected
    procedure ReleaseResult(const Value: TValue; const ResultType: TRttiType); override;
  public
    Kept: TObject;
  end;

  TAdoptingTool = class(TMCPMethodTool)
  protected
    procedure ReleaseArguments(const Owned: TList<TObject>); override;
  end;

  [TestFixture]
  TMethodToolTests = class
  private
    FContext: TRttiContext;
    FTarget: TSampleTarget;
    function MethodOf(const MethodName: string): TRttiMethod;
    function ToolFor(const MethodName: string): IMCPTool;
    function Run(const Tool: IMCPTool; const ArgumentsJson: string): TJSONObject;
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    [Test]
    procedure Procedure_ReturnsOk;

    [Test]
    procedure Procedure_PassesItsArgument;

    [Test]
    procedure Function_ReturnsTheResultMember;

    [Test]
    procedure StringFunction_ReturnsAStringResult;

    [Test]
    procedure DtoParameter_IsMarshalledAndFreed;

    [Test]
    procedure ArrayParameter_IsMarshalled;

    [Test]
    procedure ObjectArrayParameter_IsMarshalledAndEveryElementFreed;

    [Test]
    procedure MissingRequiredArgument_RaisesArgumentException;

    [Test]
    procedure WrongArgumentType_RaisesArgumentException;

    [Test]
    procedure UnknownArgument_RaisesArgumentException;

    [Test]
    procedure OptionalArgument_MayBeOmitted;

    [Test]
    procedure SchemaName_IsAlsoTheArgumentName;

    [Test]
    procedure OverriddenResultToJson_ReplacesTheWholeObject;

    [Test]
    procedure ReturnedObject_IsFreedExactlyOnce;

    [Test]
    procedure ReturnedObjectArray_IsFreedElementByElement;

    [Test]
    procedure OverriddenReleaseResult_KeepsTheReturnedObject;

    [Test]
    procedure OverriddenReleaseArguments_LeavesTheArgumentToTheMethod;

    [Test]
    procedure GetInputSchema_ReturnsAFreshInstanceEveryCall;

    [Test]
    procedure FreeingAnInputSchema_LeavesTheToolUsable;

    [Test]
    procedure GetOutputSchema_ReturnsAFreshInstanceEveryCall;

    [Test]
    procedure Procedure_HasNoOutputSchema;

    [Test]
    procedure OutputSchema_ValidatesTheDefaultFunctionResult;

    [Test]
    procedure OutputSchema_ValidatesADtoArrayResult;

    [Test]
    procedure Title_FallsBackToTheName;

    [Test]
    procedure MarkReadOnly_PublishesTheHints;

    [Test]
    procedure ThroughTheManager_LogsNoOutputSchemaMismatch;

    [Test]
    procedure ThroughTheManager_ReportsAnEnvelopeWithoutItsOutputSchema;

    [Test]
    procedure RecordParameter_IsMarshalled;

    [Test]
    procedure RecordResult_IsTheResultMember;

    [Test]
    procedure RecordResult_ValidatesAgainstItsOutputSchema;

    [Test]
    procedure RecordParameter_IsPublishedAsAnObjectInTheInputSchema;

    [Test]
    procedure NestedRecordParameter_IsMarshalled;

    [Test]
    procedure RecordParameter_OptionalFieldMayBeOmitted;

    [Test]
    procedure RecordParameter_MissingFieldRaisesArgumentException;

    [Test]
    procedure RecordParameter_WrongFieldTypeRaisesArgumentException;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  MCPServer.Logger,
  MCPServer.Schema.Validator,
  MCPServer.ToolsManager;

const
  MISMATCH_WARNING = 'structuredContent does not match its outputSchema';

{ TCountedFilter }

destructor TCountedFilter.Destroy;
begin
  Inc(DestroyCount);
  inherited;
end;

{ TCountedLine }

destructor TCountedLine.Destroy;
begin
  Inc(DestroyCount);
  inherited;
end;

{ TSampleTarget }

procedure TSampleTarget.Ping;
begin
  FSeen := 'ping';
end;

procedure TSampleTarget.Remember(const Note: string);
begin
  FSeen := Note;
end;

function TSampleTarget.Add(const Left, Right: Integer): Integer;
begin
  Result := Left + Right;
end;

function TSampleTarget.Greet(const Person: string): string;
begin
  Result := 'Hello, ' + Person;
end;

function TSampleTarget.Describe(const Filter: TCountedFilter): string;
begin
  Result := Format('%s/%d', [Filter.Customer, Filter.Limit]);
end;

function TSampleTarget.JoinSkus(const Skus: TArray<string>): string;
begin
  Result := string.Join('|', Skus);
end;

function TSampleTarget.CountLines(const Lines: TArray<TCountedLine>): Integer;
begin
  Result := 0;
  for var Line in Lines do
    Inc(Result, Line.Quantity);
end;

function TSampleTarget.MakeLine: TCountedLine;
begin
  Result := TCountedLine.Create;
  Result.Sku := 'SKU-1';
  Result.Quantity := 3;
end;

function TSampleTarget.MakeLines: TArray<TCountedLine>;
const
  LineCount = 2;
begin
  SetLength(Result, LineCount);
  for var Index: Integer := 0 to LineCount - 1 do
  begin
    Result[Index] := TCountedLine.Create;
    Result[Index].Sku := 'SKU-' + (Index + 1).ToString;
    Result[Index].Quantity := Index + 1;
  end;
end;

function TSampleTarget.Tagged(const Tag: string): string;
begin
  Result := '#' + Tag;
end;

function TSampleTarget.WithOptional(const Base: string; const Suffix: string): string;
begin
  Result := Base + Suffix;
end;

function TSampleTarget.Keep(const Filter: TCountedFilter): string;
begin
  FKept.Free;
  FKept := Filter;
  Result := Filter.Customer;
end;

function TSampleTarget.Area(const Box: TSampleBox): Integer;
begin
  Result := Box.Width * Box.Height;
end;

function TSampleTarget.Grow(const Box: TSampleBox): TSampleBox;
begin
  Result.Width := Box.Width * 2;
  Result.Height := Box.Height * 2;
end;

function TSampleTarget.Caption(const Labelled: TSampleLabelled): string;
begin
  Result := Format('%s %dx%d%s',
    [Labelled.Caption, Labelled.Box.Width, Labelled.Box.Height, Labelled.Note]);
end;

destructor TSampleTarget.Destroy;
begin
  FKept.Free;
  inherited;
end;

{ TEnvelopeTool }

function TEnvelopeTool.ResultToJson(const Value: TValue; const ResultType: TRttiType): TJSONValue;
begin
  const Envelope = TJSONObject.Create;
  Envelope.AddPair('columns', TJSONArray.Create.Add('total'));
  Envelope.AddPair('rows', TJSONArray.Create.Add(Value.AsInteger));
  Result := Envelope;
end;

function TEnvelopeTool.GetOutputSchema: TJSONObject;
begin
  Result := nil;
end;

{ TMismatchedTool }

function TMismatchedTool.ResultToJson(const Value: TValue; const ResultType: TRttiType): TJSONValue;
begin
  const Envelope = TJSONObject.Create;
  Envelope.AddPair('columns', TJSONArray.Create.Add('total'));
  Result := Envelope;
end;

{ TAdoptingTool }

procedure TAdoptingTool.ReleaseArguments(const Owned: TList<TObject>);
begin
end;

{ TKeepingTool }

procedure TKeepingTool.ReleaseResult(const Value: TValue; const ResultType: TRttiType);
begin
  if Value.IsObject then
    Kept := Value.AsObject;
end;

{ TMethodToolTests }

procedure TMethodToolTests.Setup;
begin
  FContext := TRttiContext.Create;
  FTarget := TSampleTarget.Create;
  TCountedFilter.DestroyCount := 0;
  TCountedLine.DestroyCount := 0;
end;

procedure TMethodToolTests.TearDown;
begin
  FTarget.Free;
  FContext.Free;
end;

function TMethodToolTests.MethodOf(const MethodName: string): TRttiMethod;
begin
  Result := FContext.GetType(TSampleTarget).GetMethod(MethodName);
  Assert.IsNotNull(Result, 'TSampleTarget.' + MethodName + ' has no method RTTI');
end;

function TMethodToolTests.ToolFor(const MethodName: string): IMCPTool;
begin
  Result := TMCPMethodTool.Create(TValue.From<TSampleTarget>(FTarget), MethodOf(MethodName),
    'sample_' + LowerCase(MethodName), 'The ' + MethodName + ' sample');
end;

function TMethodToolTests.Run(const Tool: IMCPTool; const ArgumentsJson: string): TJSONObject;
begin
  const Arguments = TJSONObject.ParseJSONValue(ArgumentsJson) as TJSONObject;
  try
    Result := Tool.Execute(Arguments).AsType<TJSONObject>;
  finally
    Arguments.Free;
  end;
end;

procedure TMethodToolTests.Procedure_ReturnsOk;
begin
  const Json = Run(ToolFor('Ping'), '{}');
  try
    Assert.IsTrue(Json.GetValue<Boolean>('ok'), 'a procedure reports {"ok": true}');
    Assert.AreEqual(1, Json.Count, 'nothing else is in the envelope');
  finally
    Json.Free;
  end;
end;

procedure TMethodToolTests.Procedure_PassesItsArgument;
begin
  Run(ToolFor('Remember'), '{"note":"written down"}').Free;

  Assert.AreEqual('written down', FTarget.Seen);
end;

procedure TMethodToolTests.Function_ReturnsTheResultMember;
begin
  const Json = Run(ToolFor('Add'), '{"left":2,"right":40}');
  try
    Assert.AreEqual(42, Json.GetValue<Integer>('result'));
    Assert.AreEqual(1, Json.Count, 'the default envelope carries only the result');
  finally
    Json.Free;
  end;
end;

procedure TMethodToolTests.StringFunction_ReturnsAStringResult;
begin
  const Json = Run(ToolFor('Greet'), '{"person":"Ada"}');
  try
    Assert.AreEqual('Hello, Ada', Json.GetValue<string>('result'));
  finally
    Json.Free;
  end;
end;

procedure TMethodToolTests.DtoParameter_IsMarshalledAndFreed;
begin
  const Json = Run(ToolFor('Describe'), '{"filter":{"customer":"ALFKI","limit":5}}');
  try
    Assert.AreEqual('ALFKI/5', Json.GetValue<string>('result'));
  finally
    Json.Free;
  end;

  Assert.AreEqual(1, TCountedFilter.DestroyCount, 'the marshalled DTO is freed exactly once');
end;

procedure TMethodToolTests.ArrayParameter_IsMarshalled;
begin
  const Json = Run(ToolFor('JoinSkus'), '{"skus":["a","b","c"]}');
  try
    Assert.AreEqual('a|b|c', Json.GetValue<string>('result'));
  finally
    Json.Free;
  end;
end;

procedure TMethodToolTests.ObjectArrayParameter_IsMarshalledAndEveryElementFreed;
begin
  const Json = Run(ToolFor('CountLines'),
    '{"lines":[{"sku":"a","quantity":2},{"sku":"b","quantity":5}]}');
  try
    Assert.AreEqual(7, Json.GetValue<Integer>('result'));
  finally
    Json.Free;
  end;

  Assert.AreEqual(2, TCountedLine.DestroyCount, 'every marshalled element is freed');
end;

procedure TMethodToolTests.MissingRequiredArgument_RaisesArgumentException;
begin
  var Tool := ToolFor('Add');
  Assert.WillRaise(
    procedure
    begin
      Run(Tool, '{"left":1}').Free;
    end,
    EArgumentException);
end;

procedure TMethodToolTests.WrongArgumentType_RaisesArgumentException;
begin
  var Tool := ToolFor('Add');
  Assert.WillRaise(
    procedure
    begin
      Run(Tool, '{"left":"two","right":40}').Free;
    end,
    EArgumentException);
end;

procedure TMethodToolTests.UnknownArgument_RaisesArgumentException;
begin
  var Tool := ToolFor('Add');
  Assert.WillRaise(
    procedure
    begin
      Run(Tool, '{"left":1,"right":2,"sideways":3}').Free;
    end,
    EArgumentException);
end;

procedure TMethodToolTests.OptionalArgument_MayBeOmitted;
begin
  const Tool = ToolFor('WithOptional');

  var Json := Run(Tool, '{"base":"core"}');
  try
    Assert.AreEqual('core', Json.GetValue<string>('result'), 'an omitted parameter is its default');
  finally
    Json.Free;
  end;

  Json := Run(Tool, '{"base":"core","suffix":"-plus"}');
  try
    Assert.AreEqual('core-plus', Json.GetValue<string>('result'));
  finally
    Json.Free;
  end;
end;

procedure TMethodToolTests.SchemaName_IsAlsoTheArgumentName;
begin
  const Tool = ToolFor('Tagged');

  const Schema = Tool.GetInputSchema;
  try
    const Properties = Schema.GetValue('properties') as TJSONObject;
    Assert.IsNotNull(Properties.GetValue('colour_tag'), 'the schema uses the [SchemaName]');
    Assert.IsNull(Properties.GetValue('tag'), 'and not the lower-cased parameter name');
  finally
    Schema.Free;
  end;

  const Json = Run(Tool, '{"colour_tag":"amber"}');
  try
    Assert.AreEqual('#amber', Json.GetValue<string>('result'), 'the marshal reads the same name');
  finally
    Json.Free;
  end;
end;

procedure TMethodToolTests.OverriddenResultToJson_ReplacesTheWholeObject;
begin
  const Tool: IMCPTool = TEnvelopeTool.Create(TValue.From<TSampleTarget>(FTarget), MethodOf('Add'),
    'sample_envelope', 'An envelope tool');

  const Json = Run(Tool, '{"left":1,"right":2}');
  try
    Assert.IsNull(Json.GetValue('result'), 'the override is not nested under "result"');
    Assert.AreEqual('total', (Json.GetValue('columns') as TJSONArray).Items[0].Value);
    Assert.AreEqual(3, ((Json.GetValue('rows') as TJSONArray).Items[0] as TJSONNumber).AsInt);
  finally
    Json.Free;
  end;
end;

procedure TMethodToolTests.ReturnedObject_IsFreedExactlyOnce;
begin
  const Json = Run(ToolFor('MakeLine'), '{}');
  try
    const Line = Json.GetValue('result') as TJSONObject;
    Assert.AreEqual('SKU-1', Line.GetValue<string>('sku'));
    Assert.AreEqual(3, Line.GetValue<Integer>('quantity'));
  finally
    Json.Free;
  end;

  Assert.AreEqual(1, TCountedLine.DestroyCount, 'the returned object is freed exactly once');
end;

procedure TMethodToolTests.ReturnedObjectArray_IsFreedElementByElement;
begin
  const Json = Run(ToolFor('MakeLines'), '{}');
  try
    Assert.AreEqual(2, (Json.GetValue('result') as TJSONArray).Count);
  finally
    Json.Free;
  end;

  Assert.AreEqual(2, TCountedLine.DestroyCount, 'every returned element is freed exactly once');
end;

procedure TMethodToolTests.OverriddenReleaseResult_KeepsTheReturnedObject;
begin
  var Keeper := TKeepingTool.Create(TValue.From<TSampleTarget>(FTarget), MethodOf('MakeLine'),
    'sample_keeping', 'A tool that keeps its result');
  const Tool: IMCPTool = Keeper;

  Run(Tool, '{}').Free;

  Assert.AreEqual(0, TCountedLine.DestroyCount, 'the override frees nothing');
  Assert.IsNotNull(Keeper.Kept, 'and sees the object the method returned');

  Keeper.Kept.Free;
  Assert.AreEqual(1, TCountedLine.DestroyCount);
end;

procedure TMethodToolTests.OverriddenReleaseArguments_LeavesTheArgumentToTheMethod;
begin
  const Tool: IMCPTool = TAdoptingTool.Create(TValue.From<TSampleTarget>(FTarget), MethodOf('Keep'),
    'sample_adopting', 'A tool whose method keeps what it is handed');

  const Json = Run(Tool, '{"filter":{"customer":"ALFKI","limit":5}}');
  try
    Assert.AreEqual('ALFKI', Json.GetValue<string>('result'));
  finally
    Json.Free;
  end;

  Assert.AreEqual(0, TCountedFilter.DestroyCount, 'the tool freed an argument its method kept');
  Assert.IsNotNull(FTarget.Kept, 'the method was handed nothing to keep');
  Assert.AreEqual('ALFKI', FTarget.Kept.Customer, 'the kept argument was freed underneath the method');
end;

procedure TMethodToolTests.GetInputSchema_ReturnsAFreshInstanceEveryCall;
begin
  const Tool = ToolFor('Add');

  const First = Tool.GetInputSchema;
  const Second = Tool.GetInputSchema;
  try
    Assert.IsFalse(First = Second, 'the caller owns each schema, so each call builds one');
    Assert.AreEqual(First.ToJSON, Second.ToJSON);
  finally
    First.Free;
    Second.Free;
  end;
end;

procedure TMethodToolTests.FreeingAnInputSchema_LeavesTheToolUsable;
begin
  const Tool = ToolFor('Add');

  Tool.GetInputSchema.Free;

  const Json = Run(Tool, '{"left":1,"right":1}');
  try
    Assert.AreEqual(2, Json.GetValue<Integer>('result'), 'validation still has its own schema');
  finally
    Json.Free;
  end;

  Tool.GetInputSchema.Free;
end;

procedure TMethodToolTests.GetOutputSchema_ReturnsAFreshInstanceEveryCall;
begin
  const Tool = ToolFor('Add');

  const First = Tool.GetOutputSchema;
  const Second = Tool.GetOutputSchema;
  try
    Assert.IsFalse(First = Second, 'the tools manager frees what GetOutputSchema hands it');
    Assert.AreEqual(First.ToJSON, Second.ToJSON);
  finally
    First.Free;
    Second.Free;
  end;
end;

procedure TMethodToolTests.Procedure_HasNoOutputSchema;
begin
  Assert.IsNull(ToolFor('Ping').GetOutputSchema, 'a procedure describes no structured result');
end;

procedure TMethodToolTests.OutputSchema_ValidatesTheDefaultFunctionResult;
begin
  const Tool = ToolFor('Add');

  const Schema = Tool.GetOutputSchema;
  try
    const Json = Run(Tool, '{"left":2,"right":3}');
    try
      var Errors: TArray<string>;
      Assert.IsTrue(TMCPSchemaValidator.TryValidate(Schema, Json, Errors),
        string.Join('; ', Errors));
    finally
      Json.Free;
    end;
  finally
    Schema.Free;
  end;
end;

procedure TMethodToolTests.OutputSchema_ValidatesADtoArrayResult;
begin
  const Tool = ToolFor('MakeLines');

  const Schema = Tool.GetOutputSchema;
  try
    const Json = Run(Tool, '{}');
    try
      var Errors: TArray<string>;
      Assert.IsTrue(TMCPSchemaValidator.TryValidate(Schema, Json, Errors),
        string.Join('; ', Errors));
    finally
      Json.Free;
    end;
  finally
    Schema.Free;
  end;
end;

procedure TMethodToolTests.Title_FallsBackToTheName;
begin
  const Tool = ToolFor('Ping');

  Assert.AreEqual('sample_ping', Tool.GetName);
  Assert.AreEqual('sample_ping', Tool.GetTitle);
  Assert.AreEqual('The Ping sample', Tool.GetDescription);
end;

procedure TMethodToolTests.MarkReadOnly_PublishesTheHints;
begin
  const Tool = TMCPMethodTool.Create(TValue.From<TSampleTarget>(FTarget), MethodOf('Add'), 'sample_readonly',
    'A read-only tool');
  const AsInterface: IMCPTool = Tool;

  var Metadata: IMCPToolMetadata;
  Assert.IsTrue(Supports(AsInterface, IMCPToolMetadata, Metadata));
  Assert.IsNull(Metadata.Annotations, 'nothing is published before MarkReadOnly');

  Tool.MarkReadOnly;

  Assert.IsTrue(Metadata.Annotations.GetValue<Boolean>('readOnlyHint'));
  Assert.IsFalse(Metadata.Annotations.GetValue<Boolean>('openWorldHint'));
end;

procedure TMethodToolTests.ThroughTheManager_LogsNoOutputSchemaMismatch;
const
  CALLS: array [0 .. 2] of string = (
    '{"name":"sample_add","arguments":{"left":1,"right":2}}',
    '{"name":"sample_makelines","arguments":{}}',
    '{"name":"sample_ping","arguments":{}}');
begin
  const Warnings = TStringList.Create;
  const Manager: IMCPCapabilityManager = TMCPToolsManager.Create;
  const Tools = Manager as TMCPToolsManager;
  const OriginalLevel = TLogger.MinLogLevel;
  try
    Tools.AddTool(ToolFor('Add'));
    Tools.AddTool(ToolFor('MakeLines'));
    Tools.AddTool(ToolFor('Ping'));

    TLogger.MinLogLevel := TLogLevel.Debug;
    TLogger.OnLogMessage :=
      procedure(const Message: string)
      begin
        if Message.Contains(MISMATCH_WARNING) then
          Warnings.Add(Message);
      end;

    for var Call in CALLS do
    begin
      const Params = TJSONObject.ParseJSONValue(Call) as TJSONObject;
      try
        Tools.CallTool(Params, TMCPProtocolEra.Modern).AsType<TJSONObject>.Free;
      finally
        Params.Free;
      end;
    end;

    Assert.AreEqual(0, Warnings.Count, string.Join('; ', Warnings.ToStringArray));
  finally
    TLogger.OnLogMessage := nil;
    TLogger.MinLogLevel := OriginalLevel;
    Warnings.Free;
  end;
end;

procedure TMethodToolTests.ThroughTheManager_ReportsAnEnvelopeWithoutItsOutputSchema;
begin
  const Warnings = TStringList.Create;
  const Manager: IMCPCapabilityManager = TMCPToolsManager.Create;
  const Tools = Manager as TMCPToolsManager;
  const OriginalLevel = TLogger.MinLogLevel;
  try
    Tools.AddTool(TMismatchedTool.Create(TValue.From<TSampleTarget>(FTarget), MethodOf('Add'),
      'sample_mismatch', 'An envelope that forgot its output schema'));

    TLogger.MinLogLevel := TLogLevel.Debug;
    TLogger.OnLogMessage :=
      procedure(const Message: string)
      begin
        if Message.Contains(MISMATCH_WARNING) then
          Warnings.Add(Message);
      end;

    const Params = TJSONObject.ParseJSONValue(
      '{"name":"sample_mismatch","arguments":{"left":1,"right":2}}') as TJSONObject;
    try
      Tools.CallTool(Params, TMCPProtocolEra.Modern).AsType<TJSONObject>.Free;
    finally
      Params.Free;
    end;

    {$IFDEF DEBUG}
    Assert.AreEqual(1, Warnings.Count, 'a DEBUG build reports the mismatch, so the quiet test above means something');
    {$ELSE}
    Assert.AreEqual(0, Warnings.Count, 'only a DEBUG build validates structuredContent');
    {$ENDIF}
  finally
    TLogger.OnLogMessage := nil;
    TLogger.MinLogLevel := OriginalLevel;
    Warnings.Free;
  end;
end;

procedure TMethodToolTests.RecordParameter_IsMarshalled;
begin
  const Json = Run(ToolFor('Area'), '{"box":{"width":3,"height":4}}');
  try
    Assert.AreEqual(12, Json.GetValue<Integer>('result'));
  finally
    Json.Free;
  end;
end;

procedure TMethodToolTests.RecordResult_IsTheResultMember;
begin
  const Json = Run(ToolFor('Grow'), '{"box":{"width":3,"height":4}}');
  try
    Assert.AreEqual('{"result":{"width":6,"height":8}}', Json.ToJSON);
  finally
    Json.Free;
  end;
end;

procedure TMethodToolTests.RecordResult_ValidatesAgainstItsOutputSchema;
begin
  const Tool = ToolFor('Grow');

  const Schema = Tool.GetOutputSchema;
  try
    Assert.IsNotNull(Schema, 'a record result describes itself');

    const Json = Run(Tool, '{"box":{"width":1,"height":2}}');
    try
      var Errors: TArray<string>;
      Assert.IsTrue(TMCPSchemaValidator.TryValidate(Schema, Json, Errors),
        string.Join('; ', Errors));
    finally
      Json.Free;
    end;
  finally
    Schema.Free;
  end;
end;

procedure TMethodToolTests.RecordParameter_IsPublishedAsAnObjectInTheInputSchema;
begin
  const Schema = ToolFor('Area').GetInputSchema;
  try
    Assert.AreEqual('object', Schema.GetValue<string>('properties.box.type'));
    Assert.AreEqual('integer', Schema.GetValue<string>('properties.box.properties.width.type'));
    Assert.AreEqual('integer', Schema.GetValue<string>('properties.box.properties.height.type'));
  finally
    Schema.Free;
  end;
end;

procedure TMethodToolTests.NestedRecordParameter_IsMarshalled;
begin
  const Json = Run(ToolFor('Caption'),
    '{"labelled":{"caption":"tile","box":{"width":2,"height":5},"note":"!"}}');
  try
    Assert.AreEqual('tile 2x5!', Json.GetValue<string>('result'));
  finally
    Json.Free;
  end;
end;

procedure TMethodToolTests.RecordParameter_OptionalFieldMayBeOmitted;
begin
  const Json = Run(ToolFor('Caption'), '{"labelled":{"caption":"tile","box":{"width":2,"height":5}}}');
  try
    Assert.AreEqual('tile 2x5', Json.GetValue<string>('result'));
  finally
    Json.Free;
  end;
end;

procedure TMethodToolTests.RecordParameter_MissingFieldRaisesArgumentException;
begin
  const Tool = ToolFor('Area');
  Assert.WillRaise(
    procedure
    begin
      Run(Tool, '{"box":{"width":3}}').Free;
    end,
    EArgumentException);
end;

procedure TMethodToolTests.RecordParameter_WrongFieldTypeRaisesArgumentException;
begin
  const Tool = ToolFor('Area');
  Assert.WillRaise(
    procedure
    begin
      Run(Tool, '{"box":{"width":"three","height":4}}').Free;
    end,
    EArgumentException);
end;

end.
