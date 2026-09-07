unit MCPServer.Tests.SchemaValidator;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TSchemaValidatorTests = class
  public
    [Test] procedure Type_Mismatch_Fails;
    [Test] procedure Type_Array_AcceptsEitherAlternative;
    [Test] procedure Integer_RejectsFraction;
    [Test] procedure Required_MissingProperty_Fails;
    [Test] procedure Properties_RecurseIntoNestedObject;
    [Test] procedure AdditionalProperties_False_RejectsExtraKey;
    [Test] procedure Items_RecurseIntoArrayElements;
    [Test] procedure MinimumMaximum_OutOfRange_Fails;
    [Test] procedure MinLengthMaxLengthPattern_Fail;
    [Test] procedure Enum_RejectsValueNotListed;
    [Test] procedure Const_RejectsDifferentValue;
    [Test] procedure Ref_ResolvesSameDocumentDefs;
    [Test] procedure Ref_UnsupportedShape_IsAnError;
    [Test] procedure Valid_Instance_HasNoErrors;
    [Test] procedure ExcessiveNesting_IsAnError;
  end;

implementation

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Schema.Validator;

{ TSchemaValidatorTests }

procedure TSchemaValidatorTests.Type_Mismatch_Fails;
begin
  var Schema := TJSONObject.ParseJSONValue('{"type":"string"}') as TJSONObject;
  var Instance := TJSONNumber.Create(1);
  try
    var Errors: TArray<string>;
    Assert.IsFalse(TMCPSchemaValidator.TryValidate(Schema, Instance, Errors));
    Assert.AreEqual(1, Integer(Length(Errors)));
    Assert.IsTrue(Errors[0].Contains('expected string'));
  finally
    Schema.Free;
    Instance.Free;
  end;
end;

procedure TSchemaValidatorTests.Type_Array_AcceptsEitherAlternative;
begin
  var Schema := TJSONObject.ParseJSONValue('{"type":["string","null"]}') as TJSONObject;
  var TextInstance := TJSONString.Create('x');
  var NullInstance := TJSONNull.Create;
  var NumberInstance := TJSONNumber.Create(1);
  try
    var Errors: TArray<string>;
    Assert.IsTrue(TMCPSchemaValidator.TryValidate(Schema, TextInstance, Errors));
    Assert.IsTrue(TMCPSchemaValidator.TryValidate(Schema, NullInstance, Errors));
    Assert.IsFalse(TMCPSchemaValidator.TryValidate(Schema, NumberInstance, Errors));
  finally
    Schema.Free;
    TextInstance.Free;
    NullInstance.Free;
    NumberInstance.Free;
  end;
end;

procedure TSchemaValidatorTests.Integer_RejectsFraction;
begin
  var Schema := TJSONObject.ParseJSONValue('{"type":"integer"}') as TJSONObject;
  var WholeInstance := TJSONNumber.Create(3);
  var FractionInstance := TJSONNumber.Create(3.5);
  try
    var Errors: TArray<string>;
    Assert.IsTrue(TMCPSchemaValidator.TryValidate(Schema, WholeInstance, Errors));
    Assert.IsFalse(TMCPSchemaValidator.TryValidate(Schema, FractionInstance, Errors));
  finally
    Schema.Free;
    WholeInstance.Free;
    FractionInstance.Free;
  end;
end;

procedure TSchemaValidatorTests.Required_MissingProperty_Fails;
begin
  var Schema := TJSONObject.ParseJSONValue('{"type":"object","required":["a"]}') as TJSONObject;
  var Instance := TJSONObject.ParseJSONValue('{}') as TJSONObject;
  try
    var Errors: TArray<string>;
    Assert.IsFalse(TMCPSchemaValidator.TryValidate(Schema, Instance, Errors));
    Assert.IsTrue(Errors[0].Contains('missing required property "a"'));
  finally
    Schema.Free;
    Instance.Free;
  end;
end;

procedure TSchemaValidatorTests.Properties_RecurseIntoNestedObject;
begin
  var Schema := TJSONObject.ParseJSONValue(
    '{"type":"object","properties":{"child":{"type":"object","required":["x"]}}}') as TJSONObject;
  var Instance := TJSONObject.ParseJSONValue('{"child":{}}') as TJSONObject;
  try
    var Errors: TArray<string>;
    Assert.IsFalse(TMCPSchemaValidator.TryValidate(Schema, Instance, Errors));
    Assert.IsTrue(Errors[0].Contains('value.child'));
  finally
    Schema.Free;
    Instance.Free;
  end;
end;

procedure TSchemaValidatorTests.AdditionalProperties_False_RejectsExtraKey;
begin
  var Schema := TJSONObject.ParseJSONValue(
    '{"type":"object","properties":{"a":{"type":"string"}},"additionalProperties":false}') as TJSONObject;
  var Instance := TJSONObject.ParseJSONValue('{"a":"x","b":1}') as TJSONObject;
  try
    var Errors: TArray<string>;
    Assert.IsFalse(TMCPSchemaValidator.TryValidate(Schema, Instance, Errors));
    Assert.IsTrue(Errors[0].Contains('unexpected property "b"'));
  finally
    Schema.Free;
    Instance.Free;
  end;
end;

procedure TSchemaValidatorTests.Items_RecurseIntoArrayElements;
begin
  var Schema := TJSONObject.ParseJSONValue('{"type":"array","items":{"type":"integer"}}') as TJSONObject;
  var Instance := TJSONObject.ParseJSONValue('[1,2,"x"]') as TJSONArray;
  try
    var Errors: TArray<string>;
    Assert.IsFalse(TMCPSchemaValidator.TryValidate(Schema, Instance, Errors));
    Assert.IsTrue(Errors[0].Contains('value[2]'));
  finally
    Schema.Free;
    Instance.Free;
  end;
end;

procedure TSchemaValidatorTests.MinimumMaximum_OutOfRange_Fails;
begin
  var Schema := TJSONObject.ParseJSONValue('{"type":"number","minimum":0,"maximum":10}') as TJSONObject;
  var InRange := TJSONNumber.Create(5);
  var BelowRange := TJSONNumber.Create(-1);
  var AboveRange := TJSONNumber.Create(11);
  try
    var Errors: TArray<string>;
    Assert.IsTrue(TMCPSchemaValidator.TryValidate(Schema, InRange, Errors));
    Assert.IsFalse(TMCPSchemaValidator.TryValidate(Schema, BelowRange, Errors));
    Assert.IsFalse(TMCPSchemaValidator.TryValidate(Schema, AboveRange, Errors));
  finally
    Schema.Free;
    InRange.Free;
    BelowRange.Free;
    AboveRange.Free;
  end;
end;

procedure TSchemaValidatorTests.MinLengthMaxLengthPattern_Fail;
begin
  var Schema := TJSONObject.ParseJSONValue(
    '{"type":"string","minLength":2,"maxLength":4,"pattern":"^[a-z]+$"}') as TJSONObject;
  var Ok := TJSONString.Create('abc');
  var TooShort := TJSONString.Create('a');
  var TooLong := TJSONString.Create('abcde');
  var WrongPattern := TJSONString.Create('AB');
  try
    var Errors: TArray<string>;
    Assert.IsTrue(TMCPSchemaValidator.TryValidate(Schema, Ok, Errors));
    Assert.IsFalse(TMCPSchemaValidator.TryValidate(Schema, TooShort, Errors));
    Assert.IsFalse(TMCPSchemaValidator.TryValidate(Schema, TooLong, Errors));
    Assert.IsFalse(TMCPSchemaValidator.TryValidate(Schema, WrongPattern, Errors));
  finally
    Schema.Free;
    Ok.Free;
    TooShort.Free;
    TooLong.Free;
    WrongPattern.Free;
  end;
end;

procedure TSchemaValidatorTests.Enum_RejectsValueNotListed;
begin
  var Schema := TJSONObject.ParseJSONValue('{"enum":["a","b"]}') as TJSONObject;
  var Allowed := TJSONString.Create('a');
  var NotAllowed := TJSONString.Create('c');
  try
    var Errors: TArray<string>;
    Assert.IsTrue(TMCPSchemaValidator.TryValidate(Schema, Allowed, Errors));
    Assert.IsFalse(TMCPSchemaValidator.TryValidate(Schema, NotAllowed, Errors));
  finally
    Schema.Free;
    Allowed.Free;
    NotAllowed.Free;
  end;
end;

procedure TSchemaValidatorTests.Const_RejectsDifferentValue;
begin
  var Schema := TJSONObject.ParseJSONValue('{"const":"fixed"}') as TJSONObject;
  var SameValue := TJSONString.Create('fixed');
  var DifferentValue := TJSONString.Create('other');
  try
    var Errors: TArray<string>;
    Assert.IsTrue(TMCPSchemaValidator.TryValidate(Schema, SameValue, Errors));
    Assert.IsFalse(TMCPSchemaValidator.TryValidate(Schema, DifferentValue, Errors));
  finally
    Schema.Free;
    SameValue.Free;
    DifferentValue.Free;
  end;
end;

procedure TSchemaValidatorTests.Ref_ResolvesSameDocumentDefs;
begin
  var Schema := TJSONObject.ParseJSONValue(
    '{"type":"object","properties":{"a":{"$ref":"#/$defs/Positive"}},' +
    '"$defs":{"Positive":{"type":"integer","minimum":1}}}') as TJSONObject;
  var Valid := TJSONObject.ParseJSONValue('{"a":5}') as TJSONObject;
  var Invalid := TJSONObject.ParseJSONValue('{"a":0}') as TJSONObject;
  try
    var Errors: TArray<string>;
    Assert.IsTrue(TMCPSchemaValidator.TryValidate(Schema, Valid, Errors));
    Assert.IsFalse(TMCPSchemaValidator.TryValidate(Schema, Invalid, Errors));
  finally
    Schema.Free;
    Valid.Free;
    Invalid.Free;
  end;
end;

procedure TSchemaValidatorTests.Ref_UnsupportedShape_IsAnError;
begin
  var Schema := TJSONObject.ParseJSONValue('{"$ref":"https://example.com/schema.json"}') as TJSONObject;
  var Instance := TJSONString.Create('x');
  try
    var Errors: TArray<string>;
    Assert.IsFalse(TMCPSchemaValidator.TryValidate(Schema, Instance, Errors));
    Assert.IsTrue(Errors[0].Contains('unsupported $ref'));
  finally
    Schema.Free;
    Instance.Free;
  end;
end;

procedure TSchemaValidatorTests.Valid_Instance_HasNoErrors;
begin
  var Schema := TJSONObject.ParseJSONValue(
    '{"type":"object","required":["name"],"properties":{"name":{"type":"string"},"age":{"type":"integer"}}}')
    as TJSONObject;
  var Instance := TJSONObject.ParseJSONValue('{"name":"a","age":3}') as TJSONObject;
  try
    var Errors: TArray<string>;
    Assert.IsTrue(TMCPSchemaValidator.TryValidate(Schema, Instance, Errors));
    Assert.AreEqual(0, Integer(Length(Errors)));
  finally
    Schema.Free;
    Instance.Free;
  end;
end;

procedure TSchemaValidatorTests.ExcessiveNesting_IsAnError;
begin
  var Schema := TJSONObject.Create;
  var Instance := TJSONObject.Create;
  try
    var CurrentSchema := Schema;
    var CurrentInstance := Instance;
    for var I := 1 to TMCPSchemaValidator.MAX_DEPTH + 5 do
    begin
      CurrentSchema.AddPair('type', 'object');
      var ChildSchema := TJSONObject.Create;
      var Properties := TJSONObject.Create;
      Properties.AddPair('child', ChildSchema);
      CurrentSchema.AddPair('properties', Properties);
      var ChildInstance := TJSONObject.Create;
      CurrentInstance.AddPair('child', ChildInstance);
      CurrentSchema := ChildSchema;
      CurrentInstance := ChildInstance;
    end;

    var Errors: TArray<string>;
    Assert.IsFalse(TMCPSchemaValidator.TryValidate(Schema, Instance, Errors));
    Assert.IsTrue(Errors[Length(Errors) - 1].Contains('nested too deeply'));
  finally
    Schema.Free;
    Instance.Free;
  end;
end;

end.
