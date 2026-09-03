unit MCPServer.Tests.Serializer;

interface

uses
  DUnitX.TestFramework,
  System.Generics.Collections,
  MCPServer.Types;

type
  TColour = (Red, Green, Blue);
  TColours = set of TColour;

  TNested = class
  private
    FLabel: string;
  public
    property Label_: string read FLabel write FLabel;
  end;

  TSampleParams = class
  private
    FName: string;
    FCount: Integer;
    FRatio: Double;
    FEnabled: Boolean;
    FColour: TColour;
    FWhen: TDateTime;
    FTags: TArray<string>;
    FNested: TNested;
    FNote: string;
  public
    destructor Destroy; override;
    property Name: string read FName write FName;
    property Count: Integer read FCount write FCount;
    [Optional] property Ratio: Double read FRatio write FRatio;
    [Optional] property Enabled: Boolean read FEnabled write FEnabled;
    [Optional] property Colour: TColour read FColour write FColour;
    [Optional] property When: TDateTime read FWhen write FWhen;
    [Optional] property Tags: TArray<string> read FTags write FTags;
    [Optional] property Nested: TNested read FNested write FNested;
    [Optional] property Note: string read FNote write FNote;
  end;

  TSampleResult = class
  private
    FColour: TColour;
    FColours: TColours;
    FValues: TArray<Integer>;
    FChild: TNested;
    FStamp: TDateTime;
  public
    property Colour: TColour read FColour write FColour;
    property Colours: TColours read FColours write FColours;
    property Values: TArray<Integer> read FValues write FValues;
    property Child: TNested read FChild write FChild;
    property Stamp: TDateTime read FStamp write FStamp;
  end;

  [TestFixture]
  TSerializerTests = class
  private
    function Deserialize(const Json: string): TSampleParams;
    procedure ExpectArgumentError(const Json, Fragment: string);
  public
    [Test] procedure Deserialize_AllTypes;
    [Test] procedure MissingRequired_Raises;
    [Test] procedure Null_CountsAsAbsent;
    [Test] procedure WrongType_String_Raises;
    [Test] procedure WrongType_Integer_Raises;
    [Test] procedure Fraction_ForInteger_Raises;
    [Test] procedure WrongType_Boolean_Raises;
    [Test] procedure UnknownParameter_Raises;
    [Test] procedure Enum_ByName_AndInvalidRaises;
    [Test] procedure Serialize_Enum_Set_Array_DateTime;
    [Test] procedure Serialize_NilObject_IsNull;
  end;

implementation

uses
  System.SysUtils,
  System.DateUtils,
  System.JSON,
  MCPServer.Serializer;

{ TSampleParams }

destructor TSampleParams.Destroy;
begin
  FNested.Free;
  inherited;
end;

{ TSerializerTests }

function TSerializerTests.Deserialize(const Json: string): TSampleParams;
begin
  var Obj := TJSONObject.ParseJSONValue(Json) as TJSONObject;
  try
    Result := TMCPSerializer.Deserialize<TSampleParams>(Obj);
  finally
    Obj.Free;
  end;
end;

procedure TSerializerTests.ExpectArgumentError(const Json, Fragment: string);
begin
  try
    Deserialize(Json).Free;
    Assert.Fail('expected EArgumentException for ' + Json);
  except
    on E: EArgumentException do
      Assert.IsTrue(E.Message.Contains(Fragment), E.Message + ' does not mention ' + Fragment);
  end;
end;

procedure TSerializerTests.Deserialize_AllTypes;
begin
  var Params := Deserialize('{"name":"n","count":3,"ratio":1.5,"enabled":true,"colour":"Green",'
    + '"when":"2026-09-03T10:00:00Z","tags":["a","b"],"nested":{"label_":"x"}}');
  try
    Assert.AreEqual('n', Params.Name);
    Assert.AreEqual(3, Params.Count);
    Assert.AreEqual(1.5, Params.Ratio, 0.0001);
    Assert.IsTrue(Params.Enabled);
    Assert.AreEqual(Green, Params.Colour);
    Assert.AreEqual(2026, YearOf(Params.When));
    Assert.AreEqual(2, Integer(Length(Params.Tags)));
    Assert.AreEqual('x', Params.Nested.Label_);
  finally
    Params.Free;
  end;
end;

procedure TSerializerTests.MissingRequired_Raises;
begin
  ExpectArgumentError('{"name":"n"}', 'Missing required parameter "count"');
  ExpectArgumentError('{}', 'Missing required parameter "name"');
end;

procedure TSerializerTests.Null_CountsAsAbsent;
begin
  ExpectArgumentError('{"name":null,"count":1}', 'Missing required parameter "name"');
  var Params := Deserialize('{"name":"n","count":1,"note":null}');
  try
    Assert.AreEqual('', Params.Note);
  finally
    Params.Free;
  end;
end;

procedure TSerializerTests.WrongType_String_Raises;
begin
  ExpectArgumentError('{"name":5,"count":1}', 'Parameter "name": expected a string');
end;

procedure TSerializerTests.WrongType_Integer_Raises;
begin
  ExpectArgumentError('{"name":"n","count":"two"}', 'Parameter "count": expected an integer');
end;

procedure TSerializerTests.Fraction_ForInteger_Raises;
begin
  ExpectArgumentError('{"name":"n","count":1.5}', 'expected an integer');
end;

procedure TSerializerTests.WrongType_Boolean_Raises;
begin
  ExpectArgumentError('{"name":"n","count":1,"enabled":"yes"}', 'expected a boolean');
end;

procedure TSerializerTests.UnknownParameter_Raises;
begin
  ExpectArgumentError('{"name":"n","count":1,"bogus":1}', 'Unknown parameter "bogus"');
end;

procedure TSerializerTests.Enum_ByName_AndInvalidRaises;
begin
  var Params := Deserialize('{"name":"n","count":1,"colour":"Blue"}');
  try
    Assert.AreEqual(Blue, Params.Colour);
  finally
    Params.Free;
  end;
  ExpectArgumentError('{"name":"n","count":1,"colour":"Purple"}', 'Valid values: Red, Green, Blue');
end;

procedure TSerializerTests.Serialize_Enum_Set_Array_DateTime;
begin
  var Value := TSampleResult.Create;
  var Json := TJSONObject.Create;
  try
    Value.Colour := Blue;
    Value.Colours := [Red, Blue];
    Value.Values := [1, 2, 3];
    Value.Child := TNested.Create;
    Value.Child.Label_ := 'c';
    Value.Stamp := EncodeDateTime(2026, 9, 3, 10, 30, 0, 0);
    TMCPSerializer.Serialize(Value, Json);

    Assert.AreEqual('Blue', Json.GetValue<string>('colour'));
    Assert.AreEqual('Red', Json.GetValue<string>('colours[0]'));
    Assert.AreEqual('Blue', Json.GetValue<string>('colours[1]'));
    Assert.AreEqual(3, (Json.GetValue('values') as TJSONArray).Count);
    Assert.AreEqual('c', Json.GetValue<string>('child.label_'));
    Assert.IsTrue(Json.GetValue<string>('stamp').StartsWith('2026-09-03T10:30:00'));
  finally
    Value.Child.Free;
    Value.Free;
    Json.Free;
  end;
end;

procedure TSerializerTests.Serialize_NilObject_IsNull;
begin
  var Value := TSampleResult.Create;
  var Json := TJSONObject.Create;
  try
    TMCPSerializer.Serialize(Value, Json);
    Assert.IsTrue(Json.GetValue('child') is TJSONNull);
    Assert.AreEqual(0, (Json.GetValue('values') as TJSONArray).Count);
  finally
    Value.Free;
    Json.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TSerializerTests);

end.
