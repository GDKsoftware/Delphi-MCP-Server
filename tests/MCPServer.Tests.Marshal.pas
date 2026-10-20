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

  TMarshalStamp = record
    When: TDateTime;
    Colour: TMarshalColour;
  end;

  TMarshalCoordinate = record
    X: Integer;
    Y: Integer;
  end;

  TMarshalRegion = record
  private
    FInternal: Integer;
  public
    Name: string;
    Corner: TMarshalCoordinate;
    Tags: TArray<string>;
    [Optional]
    Note: string;
    [SchemaName('anchor_point')]
    Anchor: TMarshalCoordinate;

    function Internal: Integer;
  end;

  TMarshalPlacement = record
    Label_: string;
    [Optional]
    Pin: TMarshalPoint;
  end;

  TMarshalCountedPin = class
  private
    FX: Integer;
    FY: Integer;
  public
    class var DestroyCount: Integer;
    destructor Destroy; override;
    property X: Integer read FX write FX;
    property Y: Integer read FY write FY;
  end;

  TMarshalPinned = record
    Pin: TMarshalCountedPin;
    Count: Integer;
  end;

  TMarshalTagged = record
    Id: TGUID;
    Name: string;
  end;

  TMarshalBoxed = class
  private
    FCorner: TMarshalCoordinate;
  public
    property Corner: TMarshalCoordinate read FCorner write FCorner;
  end;

  TMarshalCoordinateArray = TArray<TMarshalCoordinate>;
  TMarshalPlacementArray = TArray<TMarshalPlacement>;
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

    [Test]
    procedure Record_RoundTripIsExact;

    [Test]
    procedure Record_NotAnObject_Raises;

    [Test]
    procedure NestedRecord_RoundTrip;

    [Test]
    procedure RecordWithEnumAndDateTime_RoundTrip;

    [Test]
    procedure RecordArray_RoundTrip;

    [Test]
    procedure ClassHoldingARecord_RoundTrip;

    [Test]
    procedure OptionalRecordField_AbsentKeepsItsDefault;

    [Test]
    procedure MissingRequiredRecordField_Raises;

    [Test]
    procedure UnknownRecordMember_Raises;

    [Test]
    procedure WrongRecordMemberType_NamesTheField;

    [Test]
    procedure SchemaNameOnARecordField_IsTheWireName;

    [Test]
    procedure PrivateRecordField_IsNeitherReadNorWritten;

    [Test]
    procedure RecordHoldingAnObject_OwnedHoldsThatObject;

    [Test]
    procedure RecordArrayHoldingObjects_OwnedHoldsEveryOne;

    [Test]
    procedure Record_OwnedGainsNothingForAValueOnlyRecord;

    [Test]
    procedure RecordMemberFails_FreesTheObjectTheRecordAlreadyHolds;

    [Test]
    procedure Guid_RoundTripIsExact;

    [Test]
    procedure Guid_AcceptsBracesAndRejectsAnythingElse;
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

{ TMarshalCountedPin }

destructor TMarshalCountedPin.Destroy;
begin
  Inc(DestroyCount);
  inherited;
end;

{ TMarshalRegion }

function TMarshalRegion.Internal: Integer;
begin
  Result := FInternal;
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

procedure TMarshalTests.Record_RoundTripIsExact;
begin
  const CoordinateType = RttiTypeOf(TypeInfo(TMarshalCoordinate));
  const Text = '{"x":3,"y":4}';

  const Value = FromJson(Text, CoordinateType);
  const Coordinate = Value.AsType<TMarshalCoordinate>;
  Assert.AreEqual(3, Coordinate.X);
  Assert.AreEqual(4, Coordinate.Y);

  Assert.AreEqual(Text, ToJsonText(Value, CoordinateType));
end;

procedure TMarshalTests.Record_NotAnObject_Raises;
begin
  ExpectArgumentError('5', RttiTypeOf(TypeInfo(TMarshalCoordinate)), 'expected an object');
end;

procedure TMarshalTests.NestedRecord_RoundTrip;
begin
  const RegionType = RttiTypeOf(TypeInfo(TMarshalRegion));
  const Text = '{"name":"north","corner":{"x":1,"y":2},"tags":["a","b"],"note":"seen",' +
               '"anchor_point":{"x":5,"y":6}}';

  const Value = FromJson(Text, RegionType);
  const Region = Value.AsType<TMarshalRegion>;
  Assert.AreEqual('north', Region.Name);
  Assert.AreEqual(1, Region.Corner.X);
  Assert.AreEqual(2, Region.Corner.Y);
  Assert.AreEqual(2, Integer(Length(Region.Tags)));
  Assert.AreEqual('b', Region.Tags[1]);
  Assert.AreEqual('seen', Region.Note);
  Assert.AreEqual(5, Region.Anchor.X);

  Assert.AreEqual(Text, ToJsonText(Value, RegionType));
end;

procedure TMarshalTests.RecordWithEnumAndDateTime_RoundTrip;
begin
  const StampType = RttiTypeOf(TypeInfo(TMarshalStamp));
  const When = EncodeDateTime(2026, 9, 7, 10, 30, 0, 0);

  var Stamp: TMarshalStamp;
  Stamp.When := When;
  Stamp.Colour := mcBlue;

  const Text = ToJsonText(TValue.From<TMarshalStamp>(Stamp), StampType);
  Assert.IsTrue(Text.Contains('"2026-09-07T10:30:00'), Text);
  Assert.IsTrue(Text.Contains('"mcBlue"'), Text);

  const Back = FromJson(Text, StampType).AsType<TMarshalStamp>;
  Assert.AreEqual(Double(When), Double(Back.When), 1.0 / SecsPerDay);
  Assert.AreEqual(Ord(mcBlue), Ord(Back.Colour));
end;

procedure TMarshalTests.RecordArray_RoundTrip;
begin
  const ArrayType = RttiTypeOf(TypeInfo(TMarshalCoordinateArray));
  const Text = '[{"x":1,"y":2},{"x":3,"y":4}]';

  const Value = FromJson(Text, ArrayType);
  Assert.AreEqual(2, Integer(Value.GetArrayLength));
  Assert.AreEqual(3, Value.GetArrayElement(1).AsType<TMarshalCoordinate>.X);

  Assert.AreEqual(Text, ToJsonText(Value, ArrayType));
  Assert.AreEqual(0, Integer(FOwned.Count), 'a record is a value, so it owns nothing');
end;

procedure TMarshalTests.ClassHoldingARecord_RoundTrip;
begin
  const BoxedType = FContext.GetType(TMarshalBoxed);
  const Text = '{"corner":{"x":7,"y":8}}';

  const Value = FromJson(Text, BoxedType);
  const Boxed = Value.AsObject as TMarshalBoxed;
  Assert.AreEqual(7, Boxed.Corner.X);
  Assert.AreEqual(8, Boxed.Corner.Y);

  Assert.AreEqual(Text, ToJsonText(Value, BoxedType));
end;

procedure TMarshalTests.OptionalRecordField_AbsentKeepsItsDefault;
begin
  const RegionType = RttiTypeOf(TypeInfo(TMarshalRegion));
  const Value = FromJson('{"name":"north","corner":{"x":1,"y":2},"tags":[],"anchor_point":{"x":0,"y":0}}',
    RegionType);

  const Region = Value.AsType<TMarshalRegion>;
  Assert.AreEqual('north', Region.Name);
  Assert.AreEqual('', Region.Note, 'an absent optional field keeps the default of its type');
end;

procedure TMarshalTests.MissingRequiredRecordField_Raises;
begin
  ExpectArgumentError('{"x":1}', RttiTypeOf(TypeInfo(TMarshalCoordinate)),
    'Missing required parameter "y"');
end;

procedure TMarshalTests.UnknownRecordMember_Raises;
begin
  ExpectArgumentError('{"x":1,"y":2,"z":3}', RttiTypeOf(TypeInfo(TMarshalCoordinate)),
    'Unknown parameter "z"');
end;

procedure TMarshalTests.WrongRecordMemberType_NamesTheField;
begin
  ExpectArgumentError('{"x":"nope","y":2}', RttiTypeOf(TypeInfo(TMarshalCoordinate)),
    'Parameter "x": expected an integer');
end;

procedure TMarshalTests.SchemaNameOnARecordField_IsTheWireName;
begin
  const RegionType = RttiTypeOf(TypeInfo(TMarshalRegion));
  ExpectArgumentError('{"name":"north","corner":{"x":1,"y":2},"tags":[],"anchor":{"x":0,"y":0}}',
    RegionType, 'Unknown parameter "anchor"');
end;

procedure TMarshalTests.PrivateRecordField_IsNeitherReadNorWritten;
begin
  const RegionType = RttiTypeOf(TypeInfo(TMarshalRegion));
  const Text = ToJsonText(TValue.From<TMarshalRegion>(Default(TMarshalRegion)), RegionType);

  Assert.IsFalse(Text.Contains('finternal'), Text);
  ExpectArgumentError('{"name":"north","corner":{"x":1,"y":2},"tags":[],"anchor_point":{"x":0,"y":0},' +
    '"finternal":9}', RegionType, 'Unknown parameter "finternal"');
end;

procedure TMarshalTests.RecordHoldingAnObject_OwnedHoldsThatObject;
begin
  const PlacementType = RttiTypeOf(TypeInfo(TMarshalPlacement));
  const Text = '{"label_":"pin","pin":{"x":1,"y":2}}';

  const Value = FromJson(Text, PlacementType);
  const Placement = Value.AsType<TMarshalPlacement>;
  Assert.IsNotNull(Placement.Pin);
  Assert.AreEqual(1, Placement.Pin.X);

  Assert.AreEqual(1, Integer(FOwned.Count), 'a record owns nothing, so the object it holds needs an owner');
  Assert.AreSame(TObject(Placement.Pin), FOwned[0]);

  Assert.AreEqual(Text, ToJsonText(Value, PlacementType));
end;

procedure TMarshalTests.RecordArrayHoldingObjects_OwnedHoldsEveryOne;
begin
  const ArrayType = RttiTypeOf(TypeInfo(TMarshalPlacementArray));
  const Text = '[{"label_":"a","pin":{"x":1,"y":2}},{"label_":"b","pin":{"x":3,"y":4}}]';

  const Value = FromJson(Text, ArrayType);
  Assert.AreEqual(2, Integer(Value.GetArrayLength));
  Assert.AreEqual(2, Integer(FOwned.Count));
  Assert.AreSame(TObject(Value.GetArrayElement(1).AsType<TMarshalPlacement>.Pin), FOwned[1]);

  Assert.AreEqual(Text, ToJsonText(Value, ArrayType));
end;

procedure TMarshalTests.Record_OwnedGainsNothingForAValueOnlyRecord;
begin
  FromJson('{"name":"north","corner":{"x":1,"y":2},"tags":["a"],"anchor_point":{"x":0,"y":0}}',
    RttiTypeOf(TypeInfo(TMarshalRegion)));
  Assert.AreEqual(0, Integer(FOwned.Count), 'a record made of values owns nothing');

  const Value = FromJson('{"label_":"pin"}', RttiTypeOf(TypeInfo(TMarshalPlacement)));
  Assert.IsNull(Value.AsType<TMarshalPlacement>.Pin, 'an absent optional object field stays nil');
  Assert.AreEqual(0, Integer(FOwned.Count), 'and nothing nil is put up for freeing');
end;

procedure TMarshalTests.RecordMemberFails_FreesTheObjectTheRecordAlreadyHolds;
begin
  TMarshalCountedPin.DestroyCount := 0;

  ExpectArgumentError('{"pin":{"x":1,"y":2},"count":"x"}', RttiTypeOf(TypeInfo(TMarshalPinned)),
    'Parameter "count": expected an integer');

  Assert.AreEqual(0, Integer(FOwned.Count),
    'a record that never finished converting hands nothing to the caller to free');
  Assert.AreEqual(1, TMarshalCountedPin.DestroyCount,
    'the object the half-built record already held is freed on the way out');
end;

procedure TMarshalTests.Guid_RoundTripIsExact;
begin
  const TaggedType = RttiTypeOf(TypeInfo(TMarshalTagged));
  const Text = '{"id":"f81d4fae-7dec-11d0-a765-00a0c91e6bf6","name":"crate"}';

  const Value = FromJson(Text, TaggedType);
  const Tagged = Value.AsType<TMarshalTagged>;
  Assert.AreEqual('{F81D4FAE-7DEC-11D0-A765-00A0C91E6BF6}', GUIDToString(Tagged.Id));
  Assert.AreEqual('crate', Tagged.Name);
  Assert.AreEqual(0, Integer(FOwned.Count), 'a GUID is a value and owns nothing');

  Assert.AreEqual(Text, ToJsonText(Value, TaggedType));
end;

procedure TMarshalTests.Guid_AcceptsBracesAndRejectsAnythingElse;
begin
  const TaggedType = RttiTypeOf(TypeInfo(TMarshalTagged));

  const Value = FromJson('{"id":"{F81D4FAE-7DEC-11D0-A765-00A0C91E6BF6}","name":"crate"}', TaggedType);
  Assert.AreEqual('{F81D4FAE-7DEC-11D0-A765-00A0C91E6BF6}', GUIDToString(Value.AsType<TMarshalTagged>.Id));

  ExpectArgumentError('{"id":"not-a-uuid","name":"crate"}', TaggedType,
    'Parameter "id": expected a UUID string');
  ExpectArgumentError('{"id":7,"name":"crate"}', TaggedType,
    'Parameter "id": expected a UUID string');
end;

end.
