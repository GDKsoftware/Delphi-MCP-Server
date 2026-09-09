unit MCPServer.Tests.SchemaFromMethod;

interface

uses
  DUnitX.TestFramework,
  System.Rtti,
  System.JSON,
  System.Generics.Collections,
  MCPServer.Types;

type
  TShipMode = (Standard, Express);

  TMoney = record
    Amount: Double;
  end;

  TOrderLine = class
  private
    FSku: string;
    FQuantity: Integer;
  public
    property Sku: string read FSku write FSku;
    property Quantity: Integer read FQuantity write FQuantity;
  end;

  [SchemaDialect('https://json-schema.org/draft/2020-12/schema')]
  TDialectFilter = class
  private
    FName: string;
  public
    property Name: string read FName write FName;
  end;

  TOrderFilter = class
  private
    FCustomer: string;
    FLimit: Integer;
  public
    [SchemaDescription('Customer code')]
    property Customer: string read FCustomer write FCustomer;
    [Optional]
    property Limit: Integer read FLimit write FLimit;
  end;

  TSampleService = class
  public
    procedure NoParameters;
    procedure Primitives(const Name: string; const Count: Integer; const Ratio: Double;
      const Flag: Boolean);
    procedure Scheduled(const When: TDateTime; const Mode: TShipMode);
    procedure WithFilter(const Filter: TOrderFilter);
    procedure WithSkus(const Skus: TArray<string>);
    procedure WithLines(const Lines: TArray<TOrderLine>);
    procedure WithLineList(const Lines: TList<TOrderLine>);
    procedure WithOptionalLimit(const Customer: string; [Optional] const Limit: Integer);
    procedure Annotated(
      [SchemaDescription('How many')] [SchemaMinimum(1)] [SchemaMaximum(10)] const Count: Integer;
      [SchemaName('colour_tag')] [SchemaPattern('^[a-z]+$')] const Tag: string);
    procedure MixedCase(const CustomerCode: string);
    procedure Untyped(var Anything);
    procedure OutParameter(out Total: Integer);
    procedure VarParameter(var Total: Integer);
    procedure WithDialect(const Filter: TDialectFilter);
    function CountOrders: Integer;
    function DescribeOrder: string;
    function FindLine: TOrderLine;
    function FindLines: TArray<TOrderLine>;
    function Total: TMoney;
    function MakeDialect: TDialectFilter;
  end;

  [TestFixture]
  TSchemaFromMethodTests = class
  private
    FContext: TRttiContext;
    function MethodOf(const MethodName: string): TRttiMethod;
    function SchemaOf(const MethodName: string): TJSONObject;
    function ResultSchemaOf(const MethodName: string): TJSONObject;
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    [Test]
    procedure NoParameters_GivesAnEmptyObjectSchema;

    [Test]
    procedure Primitives_MapToJsonTypes;

    [Test]
    procedure DateTime_IsStringWithFormat;

    [Test]
    procedure Enumeration_IsStringWithItsNames;

    [Test]
    procedure ClassParameter_DelegatesToGenerateSchema;

    [Test]
    procedure ArrayParameter_IsArrayWithItems;

    [Test]
    procedure ClassArrayParameter_ItemsAreTheDtoSchema;

    [Test]
    procedure ListParameter_IsArrayWithItems;

    [Test]
    procedure Optional_KeepsAParameterOutOfRequired;

    [Test]
    procedure EveryOtherParameter_IsRequiredInDeclarationOrder;

    [Test]
    procedure SchemaName_OverridesTheWireName;

    [Test]
    procedure WireName_IsTheLowerCasedParameterName;

    [Test]
    procedure ParameterAttributes_AreApplied;

    [Test]
    procedure MethodSchema_ForbidsAdditionalProperties;

    [Test]
    procedure UntypedParameter_IsRejected;

    [Test]
    procedure OutParameter_IsRejected_NamingTheParameter;

    [Test]
    procedure VarParameter_IsRejected_NamingTheParameter;

    [Test]
    procedure Dialect_IsNotCopiedIntoAParameterSchema;

    [Test]
    procedure Dialect_IsNotCopiedIntoAResultSchema;

    [Test]
    procedure Dialect_StaysOnTheSchemaOfTheClassItself;

    [Test]
    procedure Procedure_HasNoResultSchema;

    [Test]
    procedure IntegerResult_IsWrappedInRequiredResult;

    [Test]
    procedure StringResult_IsAString;

    [Test]
    procedure ClassResult_IsTheDtoSchema;

    [Test]
    procedure ClassArrayResult_IsAnArrayOfTheDtoSchema;

    [Test]
    procedure RecordResult_HasNoResultSchema;

    [Test]
    procedure SchemaFromType_DescribesAPrimitiveAnArrayAndAClass;

    [Test]
    procedure SchemaFromType_GivesNilForNoType;
  end;

implementation

uses
  System.SysUtils,
  MCPServer.Schema.Generator;

{ TSampleService }

procedure TSampleService.NoParameters;
begin
end;

procedure TSampleService.Primitives(const Name: string; const Count: Integer; const Ratio: Double;
  const Flag: Boolean);
begin
end;

procedure TSampleService.Scheduled(const When: TDateTime; const Mode: TShipMode);
begin
end;

procedure TSampleService.WithFilter(const Filter: TOrderFilter);
begin
end;

procedure TSampleService.WithSkus(const Skus: TArray<string>);
begin
end;

procedure TSampleService.WithLines(const Lines: TArray<TOrderLine>);
begin
end;

procedure TSampleService.WithLineList(const Lines: TList<TOrderLine>);
begin
end;

procedure TSampleService.WithOptionalLimit(const Customer: string; const Limit: Integer);
begin
end;

procedure TSampleService.Annotated(const Count: Integer; const Tag: string);
begin
end;

procedure TSampleService.MixedCase(const CustomerCode: string);
begin
end;

procedure TSampleService.Untyped(var Anything);
begin
end;

procedure TSampleService.OutParameter(out Total: Integer);
begin
  Total := 0;
end;

procedure TSampleService.VarParameter(var Total: Integer);
begin
  Total := 0;
end;

procedure TSampleService.WithDialect(const Filter: TDialectFilter);
begin
end;

function TSampleService.CountOrders: Integer;
begin
  Result := 0;
end;

function TSampleService.DescribeOrder: string;
begin
  Result := '';
end;

function TSampleService.FindLine: TOrderLine;
begin
  Result := nil;
end;

function TSampleService.FindLines: TArray<TOrderLine>;
begin
  Result := nil;
end;

function TSampleService.Total: TMoney;
begin
  Result := Default(TMoney);
end;

function TSampleService.MakeDialect: TDialectFilter;
begin
  Result := nil;
end;

{ TSchemaFromMethodTests }

procedure TSchemaFromMethodTests.Setup;
begin
  FContext := TRttiContext.Create;
end;

procedure TSchemaFromMethodTests.TearDown;
begin
  FContext.Free;
end;

function TSchemaFromMethodTests.MethodOf(const MethodName: string): TRttiMethod;
begin
  Result := FContext.GetType(TSampleService).GetMethod(MethodName);
  Assert.IsNotNull(Result, 'TSampleService.' + MethodName + ' has no method RTTI');
end;

function TSchemaFromMethodTests.SchemaOf(const MethodName: string): TJSONObject;
begin
  Result := TMCPSchemaGenerator.GenerateSchemaFromMethod(MethodOf(MethodName));
end;

function TSchemaFromMethodTests.ResultSchemaOf(const MethodName: string): TJSONObject;
begin
  Result := TMCPSchemaGenerator.GenerateSchemaFromMethodResult(MethodOf(MethodName));
end;

procedure TSchemaFromMethodTests.NoParameters_GivesAnEmptyObjectSchema;
begin
  var Schema := SchemaOf('NoParameters');
  try
    Assert.AreEqual('object', Schema.GetValue<string>('type'));
    Assert.AreEqual(0, (Schema.GetValue('properties') as TJSONObject).Count);
    Assert.IsNull(Schema.GetValue('required'));
    Assert.IsFalse(Schema.GetValue<Boolean>('additionalProperties'));
  finally
    Schema.Free;
  end;
end;

procedure TSchemaFromMethodTests.Primitives_MapToJsonTypes;
begin
  var Schema := SchemaOf('Primitives');
  try
    Assert.AreEqual('string', Schema.GetValue<string>('properties.name.type'));
    Assert.AreEqual('integer', Schema.GetValue<string>('properties.count.type'));
    Assert.AreEqual('number', Schema.GetValue<string>('properties.ratio.type'));
    Assert.AreEqual('boolean', Schema.GetValue<string>('properties.flag.type'));
  finally
    Schema.Free;
  end;
end;

procedure TSchemaFromMethodTests.DateTime_IsStringWithFormat;
begin
  var Schema := SchemaOf('Scheduled');
  try
    Assert.AreEqual('string', Schema.GetValue<string>('properties.when.type'));
    Assert.AreEqual('date-time', Schema.GetValue<string>('properties.when.format'));
  finally
    Schema.Free;
  end;
end;

procedure TSchemaFromMethodTests.Enumeration_IsStringWithItsNames;
begin
  var Schema := SchemaOf('Scheduled');
  try
    Assert.AreEqual('string', Schema.GetValue<string>('properties.mode.type'));
    Assert.AreEqual('Standard', Schema.GetValue<string>('properties.mode.enum[0]'));
    Assert.AreEqual('Express', Schema.GetValue<string>('properties.mode.enum[1]'));
  finally
    Schema.Free;
  end;
end;

procedure TSchemaFromMethodTests.ClassParameter_DelegatesToGenerateSchema;
begin
  var Schema := SchemaOf('WithFilter');
  try
    var Expected := TMCPSchemaGenerator.GenerateSchema(TOrderFilter);
    try
      Assert.AreEqual(Expected.ToJSON, (Schema.FindValue('properties.filter') as TJSONObject).ToJSON);
    finally
      Expected.Free;
    end;
  finally
    Schema.Free;
  end;
end;

procedure TSchemaFromMethodTests.ArrayParameter_IsArrayWithItems;
begin
  var Schema := SchemaOf('WithSkus');
  try
    Assert.AreEqual('array', Schema.GetValue<string>('properties.skus.type'));
    Assert.AreEqual('string', Schema.GetValue<string>('properties.skus.items.type'));
  finally
    Schema.Free;
  end;
end;

procedure TSchemaFromMethodTests.ClassArrayParameter_ItemsAreTheDtoSchema;
begin
  var Schema := SchemaOf('WithLines');
  try
    Assert.AreEqual('array', Schema.GetValue<string>('properties.lines.type'));
    Assert.AreEqual('object', Schema.GetValue<string>('properties.lines.items.type'));
    Assert.AreEqual('string', Schema.GetValue<string>('properties.lines.items.properties.sku.type'));
    Assert.AreEqual('integer', Schema.GetValue<string>('properties.lines.items.properties.quantity.type'));
  finally
    Schema.Free;
  end;
end;

procedure TSchemaFromMethodTests.ListParameter_IsArrayWithItems;
begin
  var Schema := SchemaOf('WithLineList');
  try
    Assert.AreEqual('array', Schema.GetValue<string>('properties.lines.type'));
    Assert.AreEqual('object', Schema.GetValue<string>('properties.lines.items.type'));
    Assert.AreEqual('string', Schema.GetValue<string>('properties.lines.items.properties.sku.type'));
  finally
    Schema.Free;
  end;
end;

procedure TSchemaFromMethodTests.Optional_KeepsAParameterOutOfRequired;
begin
  var Schema := SchemaOf('WithOptionalLimit');
  try
    Assert.AreEqual('integer', Schema.GetValue<string>('properties.limit.type'));

    var Required := Schema.GetValue('required') as TJSONArray;
    Assert.AreEqual(1, Required.Count);
    Assert.AreEqual('customer', Required.Items[0].Value);
  finally
    Schema.Free;
  end;
end;

procedure TSchemaFromMethodTests.EveryOtherParameter_IsRequiredInDeclarationOrder;
begin
  var Schema := SchemaOf('Primitives');
  try
    var Required := Schema.GetValue('required') as TJSONArray;
    Assert.AreEqual(4, Required.Count);
    Assert.AreEqual('name', Required.Items[0].Value);
    Assert.AreEqual('count', Required.Items[1].Value);
    Assert.AreEqual('ratio', Required.Items[2].Value);
    Assert.AreEqual('flag', Required.Items[3].Value);
  finally
    Schema.Free;
  end;
end;

procedure TSchemaFromMethodTests.SchemaName_OverridesTheWireName;
begin
  var Schema := SchemaOf('Annotated');
  try
    Assert.AreEqual('string', Schema.GetValue<string>('properties.colour_tag.type'));
    Assert.IsNull(Schema.GetValue('properties.tag'));

    var Required := Schema.GetValue('required') as TJSONArray;
    Assert.AreEqual('colour_tag', Required.Items[1].Value);
  finally
    Schema.Free;
  end;
end;

procedure TSchemaFromMethodTests.WireName_IsTheLowerCasedParameterName;
begin
  var Schema := SchemaOf('MixedCase');
  try
    Assert.AreEqual('string', Schema.GetValue<string>('properties.customercode.type'));
  finally
    Schema.Free;
  end;
end;

procedure TSchemaFromMethodTests.ParameterAttributes_AreApplied;
begin
  var Schema := SchemaOf('Annotated');
  try
    Assert.AreEqual('How many', Schema.GetValue<string>('properties.count.description'));
    Assert.AreEqual(1, Schema.GetValue<Integer>('properties.count.minimum'));
    Assert.AreEqual(10, Schema.GetValue<Integer>('properties.count.maximum'));
    Assert.AreEqual('^[a-z]+$', Schema.GetValue<string>('properties.colour_tag.pattern'));
  finally
    Schema.Free;
  end;
end;

procedure TSchemaFromMethodTests.MethodSchema_ForbidsAdditionalProperties;
begin
  var Schema := SchemaOf('Primitives');
  try
    Assert.AreEqual('object', Schema.GetValue<string>('type'));
    Assert.IsFalse(Schema.GetValue<Boolean>('additionalProperties'));
  finally
    Schema.Free;
  end;
end;

procedure TSchemaFromMethodTests.UntypedParameter_IsRejected;
begin
  const Method = MethodOf('Untyped');
  Assert.WillRaise(
    procedure
    begin
      TMCPSchemaGenerator.GenerateSchemaFromMethod(Method).Free;
    end,
    EArgumentException);
end;

procedure TSchemaFromMethodTests.Procedure_HasNoResultSchema;
begin
  Assert.IsNull(ResultSchemaOf('NoParameters'));
end;

procedure TSchemaFromMethodTests.IntegerResult_IsWrappedInRequiredResult;
begin
  var Schema := ResultSchemaOf('CountOrders');
  try
    Assert.AreEqual('object', Schema.GetValue<string>('type'));
    Assert.AreEqual('integer', Schema.GetValue<string>('properties.result.type'));

    var Required := Schema.GetValue('required') as TJSONArray;
    Assert.AreEqual(1, Required.Count);
    Assert.AreEqual('result', Required.Items[0].Value);
    Assert.IsFalse(Schema.GetValue<Boolean>('additionalProperties'));
  finally
    Schema.Free;
  end;
end;

procedure TSchemaFromMethodTests.StringResult_IsAString;
begin
  var Schema := ResultSchemaOf('DescribeOrder');
  try
    Assert.AreEqual('string', Schema.GetValue<string>('properties.result.type'));
  finally
    Schema.Free;
  end;
end;

procedure TSchemaFromMethodTests.ClassResult_IsTheDtoSchema;
begin
  var Schema := ResultSchemaOf('FindLine');
  try
    var Expected := TMCPSchemaGenerator.GenerateSchema(TOrderLine);
    try
      Assert.AreEqual(Expected.ToJSON, (Schema.FindValue('properties.result') as TJSONObject).ToJSON);
    finally
      Expected.Free;
    end;
  finally
    Schema.Free;
  end;
end;

procedure TSchemaFromMethodTests.ClassArrayResult_IsAnArrayOfTheDtoSchema;
begin
  var Schema := ResultSchemaOf('FindLines');
  try
    Assert.AreEqual('array', Schema.GetValue<string>('properties.result.type'));
    Assert.AreEqual('object', Schema.GetValue<string>('properties.result.items.type'));
    Assert.AreEqual('string', Schema.GetValue<string>('properties.result.items.properties.sku.type'));
  finally
    Schema.Free;
  end;
end;

procedure TSchemaFromMethodTests.RecordResult_HasNoResultSchema;
begin
  Assert.IsNull(ResultSchemaOf('Total'));
end;

procedure TSchemaFromMethodTests.SchemaFromType_DescribesAPrimitiveAnArrayAndAClass;
begin
  const Method = MethodOf('WithLines');
  const Parameters = Method.GetParameters;

  var ArraySchema := TMCPSchemaGenerator.GenerateSchemaFromType(Parameters[0].ParamType);
  try
    Assert.AreEqual('array', ArraySchema.GetValue<string>('type'));
  finally
    ArraySchema.Free;
  end;

  var IntegerSchema := TMCPSchemaGenerator.GenerateSchemaFromType(MethodOf('CountOrders').ReturnType);
  try
    Assert.AreEqual('integer', IntegerSchema.GetValue<string>('type'));
  finally
    IntegerSchema.Free;
  end;

  var DtoSchema := TMCPSchemaGenerator.GenerateSchemaFromType(MethodOf('FindLine').ReturnType);
  try
    Assert.AreEqual('object', DtoSchema.GetValue<string>('type'));
    Assert.AreEqual('integer', DtoSchema.GetValue<string>('properties.quantity.type'));
  finally
    DtoSchema.Free;
  end;
end;

procedure TSchemaFromMethodTests.SchemaFromType_GivesNilForNoType;
begin
  Assert.IsNull(TMCPSchemaGenerator.GenerateSchemaFromType(nil));
end;

procedure TSchemaFromMethodTests.OutParameter_IsRejected_NamingTheParameter;
begin
  const Method = MethodOf('OutParameter');
  try
    TMCPSchemaGenerator.GenerateSchemaFromMethod(Method).Free;
    Assert.Fail('an out parameter is published as an input and its value is dropped, so it must be refused');
  except
    on E: EArgumentException do
      Assert.IsTrue(E.Message.Contains('Total'), 'the refusal does not name the parameter: ' + E.Message);
  end;
end;

procedure TSchemaFromMethodTests.VarParameter_IsRejected_NamingTheParameter;
begin
  const Method = MethodOf('VarParameter');
  try
    TMCPSchemaGenerator.GenerateSchemaFromMethod(Method).Free;
    Assert.Fail('a var parameter is published as an input and its value is dropped, so it must be refused');
  except
    on E: EArgumentException do
      Assert.IsTrue(E.Message.Contains('Total'), 'the refusal does not name the parameter: ' + E.Message);
  end;
end;

procedure TSchemaFromMethodTests.Dialect_IsNotCopiedIntoAParameterSchema;
begin
  var Schema := SchemaOf('WithDialect');
  try
    Assert.AreEqual('object', Schema.GetValue<string>('properties.filter.type'));
    Assert.IsNull(Schema.FindValue('properties.filter.$schema'), '$schema is a root-only keyword');
  finally
    Schema.Free;
  end;
end;

procedure TSchemaFromMethodTests.Dialect_IsNotCopiedIntoAResultSchema;
begin
  var Schema := ResultSchemaOf('MakeDialect');
  try
    Assert.AreEqual('object', Schema.GetValue<string>('properties.result.type'));
    Assert.IsNull(Schema.FindValue('properties.result.$schema'), '$schema is a root-only keyword');
  finally
    Schema.Free;
  end;
end;

procedure TSchemaFromMethodTests.Dialect_StaysOnTheSchemaOfTheClassItself;
begin
  var Schema := TMCPSchemaGenerator.GenerateSchema(TDialectFilter);
  try
    Assert.AreEqual('https://json-schema.org/draft/2020-12/schema', Schema.GetValue<string>('$schema'));
  finally
    Schema.Free;
  end;
end;

end.
