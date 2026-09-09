unit MCPServer.Tests.Marshal;

interface

uses
  System.Rtti,
  System.TypInfo,
  System.Generics.Collections,
  DUnitX.TestFramework,
  MCPServer.Types;

type
  TMarshalColour = (mcRed, mcGreen, mcBlue);

  TMarshalPoint = class
  private
    FX: Integer;
    FY: Integer;
  public
    property X: Integer read FX write FX;
    property Y: Integer read FY write FY;
  end;

  TMarshalLine = class
  private
    FName: string;
    FOrigin: TMarshalPoint;
  public
    destructor Destroy; override;
    property Name: string read FName write FName;
    [Optional]
    property Origin: TMarshalPoint read FOrigin write FOrigin;
  end;

  TMarshalIntegerArray = TArray<Integer>;
  TMarshalStringArray = TArray<string>;
  TMarshalPointArray = TArray<TMarshalPoint>;
  TMarshalIntegerList = TList<Integer>;
  TMarshalPointList = TObjectList<TMarshalPoint>;

  [TestFixture]
  TMarshalTests = class
  private
    FContext: TRttiContext;
    FOwned: TList<TObject>;

    function RttiTypeOf(const Info: PTypeInfo): TRttiType;
    function FromJson(const Json: string; const RttiType: TRttiType): TValue;
    function FromJsonUnowned(const Json: string; const RttiType: TRttiType): TValue;
    function ToJsonText(const Value: TValue; const RttiType: TRttiType): string;
    procedure ExpectArgumentError(const Json: string; const RttiType: TRttiType; const Fragment: string);
  public
    [Setup]
    procedure Setup;

    [TearDown]
    procedure TearDown;

    [Test]
    procedure Integer_RoundTrip;

    [Test]
    procedure Int64_RoundTrip;

    [Test]
    procedure String_RoundTrip;

    [Test]
    procedure Float_RoundTrip;

    [Test]
    procedure Boolean_RoundTrip;

    [Test]
    procedure Enum_ByName_RoundTrip;

    [Test]
    procedure Enum_UnknownName_Raises;

    [Test]
    procedure DateTime_Iso8601_RoundTrip;

    [Test]
    procedure WrongType_MessagesKeepTheirShape;

    [Test]
    procedure NestedClass_JsonToValue;

    [Test]
    procedure NestedClass_ValueToJson;

    [Test]
    procedure NestedClass_ErrorNamesTheParameter;

    [Test]
    procedure StringArray_RoundTrip;

    [Test]
    procedure IntegerArray_ValueToJson;

    [Test]
    procedure ObjectArray_OwnedHoldsEveryElement;

    [Test]
    procedure PrimitiveArray_OwnedStaysEmpty;

    [Test]
    procedure Owned_HoldsOnlyTheRootOfANestedClass;

    [Test]
    procedure Owned_Nil_LeavesTheObjectToTheCaller;

    [Test]
    procedure List_ValueToJson;

    [Test]
    procedure ObjectList_ValueToJson;

    [Test]
    procedure EmptyValue_IsNullForAClassAndEmptyForAnArray;

    [Test]
    procedure NoType_IsSafe;
  end;

implementation

uses
  System.SysUtils,
  System.DateUtils,
  System.JSON,
  MCPServer.Serializer;

{ TMarshalLine }

destructor TMarshalLine.Destroy;
begin
  FOrigin.Free;
  inherited;
end;

{ TMarshalTests }

procedure TMarshalTests.Setup;
begin
  FOwned := TList<TObject>.Create;
end;

procedure TMarshalTests.TearDown;
begin
  for var Obj in FOwned do
    Obj.Free;
  FOwned.Free;
end;

function TMarshalTests.RttiTypeOf(const Info: PTypeInfo): TRttiType;
begin
  Result := FContext.GetType(Info);
end;

function TMarshalTests.FromJson(const Json: string; const RttiType: TRttiType): TValue;
begin
  const Parsed = TJSONObject.ParseJSONValue(Json);
  Assert.IsNotNull(Parsed, 'the test json does not parse: ' + Json);
  try
    Result := TMCPSerializer.JsonToValue(Parsed, RttiType, FOwned);
  finally
    Parsed.Free;
  end;
end;

function TMarshalTests.FromJsonUnowned(const Json: string; const RttiType: TRttiType): TValue;
begin
  const Parsed = TJSONObject.ParseJSONValue(Json);
  Assert.IsNotNull(Parsed, 'the test json does not parse: ' + Json);
  try
    Result := TMCPSerializer.JsonToValue(Parsed, RttiType, nil);
  finally
    Parsed.Free;
  end;
end;

function TMarshalTests.ToJsonText(const Value: TValue; const RttiType: TRttiType): string;
begin
  const Json = TMCPSerializer.ValueToJson(Value, RttiType);
  Assert.IsNotNull(Json, 'ValueToJson returned nil');
  try
    Result := Json.ToJSON;
  finally
    Json.Free;
  end;
end;

procedure TMarshalTests.ExpectArgumentError(const Json: string; const RttiType: TRttiType; const Fragment: string);
begin
  try
    FromJson(Json, RttiType);
    Assert.Fail('expected EArgumentException for ' + Json);
  except
    on E: EArgumentException do
      Assert.IsTrue(E.Message.Contains(Fragment), E.Message + ' does not mention ' + Fragment);
  end;
end;

procedure TMarshalTests.Integer_RoundTrip;
begin
  const IntegerType = RttiTypeOf(TypeInfo(Integer));
  const Value = FromJson('42', IntegerType);
  Assert.AreEqual(42, Value.AsInteger);
  Assert.AreEqual('42', ToJsonText(Value, IntegerType));
end;

procedure TMarshalTests.Int64_RoundTrip;
begin
  const Int64Type = RttiTypeOf(TypeInfo(Int64));
  const Value = FromJson('9007199254740992', Int64Type);
  Assert.AreEqual(Int64(9007199254740992), Value.AsInt64);
  Assert.AreEqual('9007199254740992', ToJsonText(Value, Int64Type));
end;

procedure TMarshalTests.String_RoundTrip;
begin
  const StringType = RttiTypeOf(TypeInfo(string));
  const Value = FromJson('"hello"', StringType);
  Assert.AreEqual('hello', Value.AsString);
  Assert.AreEqual('"hello"', ToJsonText(Value, StringType));
end;

procedure TMarshalTests.Float_RoundTrip;
begin
  const FloatType = RttiTypeOf(TypeInfo(Double));
  const Value = FromJson('1.5', FloatType);
  Assert.AreEqual(1.5, Value.AsExtended, 0.0001);
  Assert.AreEqual('1.5', ToJsonText(Value, FloatType));
end;

procedure TMarshalTests.Boolean_RoundTrip;
begin
  const BooleanType = RttiTypeOf(TypeInfo(Boolean));
  Assert.IsTrue(FromJson('true', BooleanType).AsBoolean);
  Assert.IsFalse(FromJson('false', BooleanType).AsBoolean);
  Assert.AreEqual('true', ToJsonText(TValue.From<Boolean>(True), BooleanType));
  Assert.AreEqual('false', ToJsonText(TValue.From<Boolean>(False), BooleanType));
end;

procedure TMarshalTests.Enum_ByName_RoundTrip;
begin
  const ColourType = RttiTypeOf(TypeInfo(TMarshalColour));
  const Value = FromJson('"mcGreen"', ColourType);
  Assert.AreEqual(Ord(mcGreen), Integer(Value.AsOrdinal));
  Assert.AreEqual('"mcGreen"', ToJsonText(Value, ColourType));
end;

procedure TMarshalTests.Enum_UnknownName_Raises;
begin
  ExpectArgumentError('"mcPurple"', RttiTypeOf(TypeInfo(TMarshalColour)),
    'Valid values: mcRed, mcGreen, mcBlue');
end;

procedure TMarshalTests.DateTime_Iso8601_RoundTrip;
begin
  const DateTimeType = RttiTypeOf(TypeInfo(TDateTime));
  const When = EncodeDateTime(2026, 9, 7, 10, 30, 0, 0);
  const Text = ToJsonText(TValue.From<TDateTime>(When), DateTimeType);
  Assert.IsTrue(Text.StartsWith('"2026-09-07T10:30:00'), Text);
  Assert.IsFalse(Text.Contains('Z'), 'the wire format is local time, not UTC: ' + Text);

  const Back = FromJson(Text, DateTimeType);
  Assert.AreEqual(Double(When), Double(Back.AsType<TDateTime>), 1.0 / SecsPerDay);
end;

procedure TMarshalTests.WrongType_MessagesKeepTheirShape;
begin
  ExpectArgumentError('"two"', RttiTypeOf(TypeInfo(Integer)), 'expected an integer');
  ExpectArgumentError('1.5', RttiTypeOf(TypeInfo(Integer)), 'expected an integer');
  ExpectArgumentError('"nope"', RttiTypeOf(TypeInfo(Double)), 'expected a number');
  ExpectArgumentError('5', RttiTypeOf(TypeInfo(string)), 'expected a string');
  ExpectArgumentError('5', RttiTypeOf(TypeInfo(Boolean)), 'expected a boolean');
  ExpectArgumentError('"not-a-date"', RttiTypeOf(TypeInfo(TDateTime)), 'expected an ISO 8601 date-time');
  ExpectArgumentError('5', FContext.GetType(TMarshalPoint), 'expected an object');
  ExpectArgumentError('5', RttiTypeOf(TypeInfo(TMarshalIntegerArray)), 'expected an array');
end;

procedure TMarshalTests.NestedClass_JsonToValue;
begin
  const Value = FromJson('{"name":"edge","origin":{"x":1,"y":2}}', FContext.GetType(TMarshalLine));
  const Line = Value.AsObject as TMarshalLine;
  Assert.AreEqual('edge', Line.Name);
  Assert.IsNotNull(Line.Origin);
  Assert.AreEqual(1, Line.Origin.X);
  Assert.AreEqual(2, Line.Origin.Y);
end;

procedure TMarshalTests.NestedClass_ValueToJson;
begin
  const LineType = FContext.GetType(TMarshalLine);
  const Line = TMarshalLine.Create;
  FOwned.Add(Line);
  Line.Name := 'edge';
  Line.Origin := TMarshalPoint.Create;
  Line.Origin.X := 1;
  Line.Origin.Y := 2;

  Assert.AreEqual('{"name":"edge","origin":{"x":1,"y":2}}', ToJsonText(Line, LineType));
end;

procedure TMarshalTests.NestedClass_ErrorNamesTheParameter;
begin
  ExpectArgumentError('{"name":"edge","origin":{"x":"nope","y":2}}', FContext.GetType(TMarshalLine),
    'Parameter "x": expected an integer');
end;

procedure TMarshalTests.StringArray_RoundTrip;
begin
  const ArrayType = RttiTypeOf(TypeInfo(TMarshalStringArray));
  const Value = FromJson('["a","b"]', ArrayType);
  Assert.AreEqual(2, Integer(Value.GetArrayLength));
  Assert.AreEqual('b', Value.GetArrayElement(1).AsString);
  Assert.AreEqual('["a","b"]', ToJsonText(Value, ArrayType));
end;

procedure TMarshalTests.IntegerArray_ValueToJson;
begin
  const ArrayType = RttiTypeOf(TypeInfo(TMarshalIntegerArray));
  const Numbers: TMarshalIntegerArray = [1, 2, 3];
  Assert.AreEqual('[1,2,3]', ToJsonText(TValue.From<TMarshalIntegerArray>(Numbers), ArrayType));
end;

procedure TMarshalTests.ObjectArray_OwnedHoldsEveryElement;
begin
  const ArrayType = RttiTypeOf(TypeInfo(TMarshalPointArray));
  const Value = FromJson('[{"x":1,"y":2},{"x":3,"y":4}]', ArrayType);

  Assert.AreEqual(2, Integer(Value.GetArrayLength));
  Assert.AreEqual(2, Integer(FOwned.Count));
  Assert.AreSame(Value.GetArrayElement(0).AsObject, FOwned[0]);
  Assert.AreSame(Value.GetArrayElement(1).AsObject, FOwned[1]);
  Assert.AreEqual(3, (FOwned[1] as TMarshalPoint).X);
  Assert.AreEqual('[{"x":1,"y":2},{"x":3,"y":4}]', ToJsonText(Value, ArrayType));
end;

procedure TMarshalTests.PrimitiveArray_OwnedStaysEmpty;
begin
  const Value = FromJson('[1,2,3]', RttiTypeOf(TypeInfo(TMarshalIntegerArray)));
  Assert.AreEqual(3, Integer(Value.GetArrayLength));
  Assert.AreEqual(0, Integer(FOwned.Count));
end;

procedure TMarshalTests.Owned_HoldsOnlyTheRootOfANestedClass;
begin
  const Value = FromJson('{"name":"edge","origin":{"x":1,"y":2}}', FContext.GetType(TMarshalLine));

  Assert.AreEqual(1, Integer(FOwned.Count), 'the nested object belongs to the object that holds it');
  Assert.AreSame(Value.AsObject, FOwned[0]);
end;

procedure TMarshalTests.Owned_Nil_LeavesTheObjectToTheCaller;
begin
  const Value = FromJsonUnowned('{"x":1,"y":2}', FContext.GetType(TMarshalPoint));

  Assert.AreEqual(0, Integer(FOwned.Count));
  const Point = Value.AsObject as TMarshalPoint;
  try
    Assert.AreEqual(1, Point.X);
  finally
    Point.Free;
  end;
end;

procedure TMarshalTests.List_ValueToJson;
begin
  const ListType = FContext.GetType(TMarshalIntegerList);
  const List = TMarshalIntegerList.Create;
  FOwned.Add(List);
  List.Add(7);
  List.Add(8);

  Assert.AreEqual('[7,8]', ToJsonText(List, ListType));
end;

procedure TMarshalTests.ObjectList_ValueToJson;
begin
  const ListType = FContext.GetType(TMarshalPointList);
  const List = TMarshalPointList.Create;
  FOwned.Add(List);
  const Point = TMarshalPoint.Create;
  Point.X := 1;
  Point.Y := 2;
  List.Add(Point);

  Assert.AreEqual('[{"x":1,"y":2}]', ToJsonText(List, ListType));
end;

procedure TMarshalTests.EmptyValue_IsNullForAClassAndEmptyForAnArray;
begin
  Assert.AreEqual('null', ToJsonText(TValue.Empty, FContext.GetType(TMarshalPoint)));
  Assert.AreEqual('[]', ToJsonText(TValue.Empty, RttiTypeOf(TypeInfo(TMarshalIntegerArray))));
end;

procedure TMarshalTests.NoType_IsSafe;
begin
  const Parsed = TJSONObject.ParseJSONValue('42');
  try
    Assert.IsTrue(TMCPSerializer.JsonToValue(Parsed, nil, FOwned).IsEmpty);
  finally
    Parsed.Free;
  end;

  Assert.IsNull(TMCPSerializer.ValueToJson(TValue.From<Integer>(42), nil));
  Assert.IsTrue(TMCPSerializer.JsonToValue(nil, RttiTypeOf(TypeInfo(Integer)), FOwned).IsEmpty);
end;

end.
