unit MCPServer.Tests.Schema;

interface

uses
  DUnitX.TestFramework,
  System.Generics.Collections,
  MCPServer.Types;

type
  TLevel = (Low, Mid, High);
  TLevels = set of TLevel;

  TPoint = class
  private
    FX: Integer;
    FY: Integer;
  public
    property X: Integer read FX write FX;
    property Y: Integer read FY write FY;
  end;

  TSchemaParams = class
  private
    FCount: Integer;
    FBig: Int64;
    FRatio: Double;
    FWhen: TDateTime;
    FFlag: Boolean;
    FLevel: TLevel;
    FLevels: TLevels;
    FNames: TArray<string>;
    FPoints: TList<TPoint>;
    FOrigin: TPoint;
    FCode: string;
    FScore: Integer;
    FTag: string;
  public
    [SchemaDescription('How many')]
    [SchemaMinimum(1)]
    [SchemaMaximum(10)]
    property Count: Integer read FCount write FCount;
    property Big: Int64 read FBig write FBig;
    property Ratio: Double read FRatio write FRatio;
    [SchemaTitle('When it happened')]
    property When: TDateTime read FWhen write FWhen;
    property Flag: Boolean read FFlag write FFlag;
    property Level: TLevel read FLevel write FLevel;
    property Levels: TLevels read FLevels write FLevels;
    property Names: TArray<string> read FNames write FNames;
    property Points: TList<TPoint> read FPoints write FPoints;
    property Origin: TPoint read FOrigin write FOrigin;
    [Optional]
    [SchemaFormat('uri')]
    property Code: string read FCode write FCode;
    [SchemaEnum('one', 'two')]
    property Score: Integer read FScore write FScore;
    [SchemaMinLength(2)]
    [SchemaMaxLength(5)]
    [SchemaPattern('^[a-z]+$')]
    [SchemaDefault('"blue"')]
    [SchemaName('colour_tag')]
    property Tag: string read FTag write FTag;
  end;

  TEmptyParams = class
  end;

  [SchemaAdditionalProperties(False)]
  [SchemaDialect('https://json-schema.org/draft/2020-12/schema')]
  TStrictParams = class
  private
    FName: string;
  public
    property Name: string read FName write FName;
  end;

  TWrapperParams = class
  private
    FStrict: TStrictParams;
  public
    property Strict: TStrictParams read FStrict write FStrict;
  end;

  [TestFixture]
  TSchemaGeneratorTests = class
  public
    [Test] procedure Integers_AreInteger_FloatsAreNumber;
    [Test] procedure DateTime_IsStringWithFormat;
    [Test] procedure Boolean_And_Enum;
    [Test] procedure Set_IsArrayOfEnumNames;
    [Test] procedure DynArray_And_List_HaveItems;
    [Test] procedure NestedObject_HasProperties;
    [Test] procedure Attributes_AreApplied;
    [Test] procedure Optional_IsNotRequired;
    [Test] procedure NoParameters_ForbidsAdditionalProperties;
    [Test] procedure StringConstraints_AreApplied;
    [Test] procedure SchemaName_OverridesPropertyName;
    [Test] procedure ClassAttributes_AdditionalPropertiesAndDialect;
    [Test] procedure Dialect_OnlyAppliesAtRoot;
  end;

implementation

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Schema.Generator;

{ TSchemaGeneratorTests }

procedure TSchemaGeneratorTests.Integers_AreInteger_FloatsAreNumber;
begin
  var Schema := TMCPSchemaGenerator.GenerateSchema(TSchemaParams);
  try
    Assert.AreEqual('integer', Schema.GetValue<string>('properties.count.type'));
    Assert.AreEqual('integer', Schema.GetValue<string>('properties.big.type'));
    Assert.AreEqual('number', Schema.GetValue<string>('properties.ratio.type'));
  finally
    Schema.Free;
  end;
end;

procedure TSchemaGeneratorTests.DateTime_IsStringWithFormat;
begin
  var Schema := TMCPSchemaGenerator.GenerateSchema(TSchemaParams);
  try
    Assert.AreEqual('string', Schema.GetValue<string>('properties.when.type'));
    Assert.AreEqual('date-time', Schema.GetValue<string>('properties.when.format'));
  finally
    Schema.Free;
  end;
end;

procedure TSchemaGeneratorTests.Boolean_And_Enum;
begin
  var Schema := TMCPSchemaGenerator.GenerateSchema(TSchemaParams);
  try
    Assert.AreEqual('boolean', Schema.GetValue<string>('properties.flag.type'));
    Assert.AreEqual('string', Schema.GetValue<string>('properties.level.type'));
    Assert.AreEqual('Mid', Schema.GetValue<string>('properties.level.enum[1]'));
  finally
    Schema.Free;
  end;
end;

procedure TSchemaGeneratorTests.Set_IsArrayOfEnumNames;
begin
  var Schema := TMCPSchemaGenerator.GenerateSchema(TSchemaParams);
  try
    Assert.AreEqual('array', Schema.GetValue<string>('properties.levels.type'));
    Assert.AreEqual('string', Schema.GetValue<string>('properties.levels.items.type'));
    Assert.AreEqual('High', Schema.GetValue<string>('properties.levels.items.enum[2]'));
  finally
    Schema.Free;
  end;
end;

procedure TSchemaGeneratorTests.DynArray_And_List_HaveItems;
begin
  var Schema := TMCPSchemaGenerator.GenerateSchema(TSchemaParams);
  try
    Assert.AreEqual('array', Schema.GetValue<string>('properties.names.type'));
    Assert.AreEqual('string', Schema.GetValue<string>('properties.names.items.type'));
    Assert.AreEqual('array', Schema.GetValue<string>('properties.points.type'));
    Assert.AreEqual('object', Schema.GetValue<string>('properties.points.items.type'));
    Assert.AreEqual('integer', Schema.GetValue<string>('properties.points.items.properties.x.type'));
  finally
    Schema.Free;
  end;
end;

procedure TSchemaGeneratorTests.NestedObject_HasProperties;
begin
  var Schema := TMCPSchemaGenerator.GenerateSchema(TSchemaParams);
  try
    Assert.AreEqual('object', Schema.GetValue<string>('properties.origin.type'));
    Assert.AreEqual('integer', Schema.GetValue<string>('properties.origin.properties.y.type'));
    Assert.AreEqual('x', Schema.GetValue<string>('properties.origin.required[0]'));
  finally
    Schema.Free;
  end;
end;

procedure TSchemaGeneratorTests.Attributes_AreApplied;
begin
  var Schema := TMCPSchemaGenerator.GenerateSchema(TSchemaParams);
  try
    Assert.AreEqual('How many', Schema.GetValue<string>('properties.count.description'));
    Assert.AreEqual(1, Schema.GetValue<Integer>('properties.count.minimum'));
    Assert.AreEqual(10, Schema.GetValue<Integer>('properties.count.maximum'));
    Assert.AreEqual('When it happened', Schema.GetValue<string>('properties.when.title'));
    Assert.AreEqual('uri', Schema.GetValue<string>('properties.code.format'));
    Assert.AreEqual('one', Schema.GetValue<string>('properties.score.enum[0]'));
  finally
    Schema.Free;
  end;
end;

procedure TSchemaGeneratorTests.Optional_IsNotRequired;
begin
  var Schema := TMCPSchemaGenerator.GenerateSchema(TSchemaParams);
  try
    var Required := Schema.GetValue('required') as TJSONArray;
    for var Item in Required do
      Assert.AreNotEqual('code', Item.Value);
    Assert.AreEqual('count', Required.Items[0].Value);
  finally
    Schema.Free;
  end;
end;

procedure TSchemaGeneratorTests.NoParameters_ForbidsAdditionalProperties;
begin
  var Schema := TMCPSchemaGenerator.GenerateSchema(TEmptyParams);
  try
    Assert.AreEqual(0, (Schema.GetValue('properties') as TJSONObject).Count);
    Assert.IsFalse(Schema.GetValue<Boolean>('additionalProperties'));
    Assert.IsNull(Schema.GetValue('required'));
  finally
    Schema.Free;
  end;
end;

procedure TSchemaGeneratorTests.StringConstraints_AreApplied;
begin
  var Schema := TMCPSchemaGenerator.GenerateSchema(TSchemaParams);
  try
    Assert.AreEqual(2, Schema.GetValue<Integer>('properties.colour_tag.minLength'));
    Assert.AreEqual(5, Schema.GetValue<Integer>('properties.colour_tag.maxLength'));
    Assert.AreEqual('^[a-z]+$', Schema.GetValue<string>('properties.colour_tag.pattern'));
    Assert.AreEqual('blue', Schema.GetValue<string>('properties.colour_tag.default'));
  finally
    Schema.Free;
  end;
end;

procedure TSchemaGeneratorTests.SchemaName_OverridesPropertyName;
begin
  var Schema := TMCPSchemaGenerator.GenerateSchema(TSchemaParams);
  try
    Assert.IsNull(Schema.FindValue('properties.tag'), 'the Pascal name is not used on the wire');
    Assert.IsNotNull(Schema.FindValue('properties.colour_tag'));
  finally
    Schema.Free;
  end;
end;

procedure TSchemaGeneratorTests.ClassAttributes_AdditionalPropertiesAndDialect;
begin
  var Schema := TMCPSchemaGenerator.GenerateSchema(TStrictParams);
  try
    Assert.IsFalse(Schema.GetValue<Boolean>('additionalProperties'));
    Assert.AreEqual('https://json-schema.org/draft/2020-12/schema', Schema.GetValue<string>('$schema'));
  finally
    Schema.Free;
  end;
end;

procedure TSchemaGeneratorTests.Dialect_OnlyAppliesAtRoot;
begin
  var Schema := TMCPSchemaGenerator.GenerateSchema(TWrapperParams);
  try
    Assert.IsNull(Schema.GetValue('$schema'), 'the wrapper itself has no [SchemaDialect]');
    Assert.IsFalse(Schema.GetValue<Boolean>('properties.strict.additionalProperties'),
      'a class attribute applies wherever the class is used');
    Assert.IsNull(Schema.FindValue('properties.strict.$schema'), '$schema is a root-only keyword');
  finally
    Schema.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TSchemaGeneratorTests);

end.
