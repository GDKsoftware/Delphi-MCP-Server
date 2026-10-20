unit MCPServer.Serializer;

interface

uses
  System.SysUtils,
  System.Classes,
  System.Rtti,
  System.TypInfo,
  System.Generics.Collections,
  System.JSON;

type
  TMCPSerializer = class
  private
    class var FContext: TRttiContext;

    class procedure DeserializeObject(Instance: TObject; const Json: TJSONObject);
    class function DeserializeArray(RttiType: TRttiType; const JsonArray: TJSONArray): TValue;

    class function ConvertJsonToValue(const JsonValue: TJSONValue; const RttiType: TRttiType): TValue;
    class function ConvertJsonToInteger(const JsonValue: TJSONValue; const RttiType: TRttiType): TValue;
    class function ConvertJsonToFloat(const JsonValue: TJSONValue; const RttiType: TRttiType): TValue;
    class function ConvertJsonToClass(const JsonValue: TJSONValue; const RttiType: TRttiType): TValue;
    class function ConvertJsonToRecord(const JsonValue: TJSONValue; const RttiType: TRttiType): TValue;
    class function ConvertJsonToGuid(const JsonValue: TJSONValue): TValue;
    class procedure FillRecordFields(const Json: TJSONObject; const RttiType: TRttiType;
      const Data: Pointer);
    class procedure FreeRecordObjects(const Value: TValue; const RttiType: TRttiType);
    class function ConvertJsonToEnum(const JsonValue: TJSONValue; const RttiType: TRttiType): TValue;
    class function GetEnumValueNames(const EnumType: TRttiEnumerationType): string;
    class function ConvertValueToJson(const Value: TValue; const RttiType: TRttiType): TJSONValue;
    class function ConvertRecordToJson(const Value: TValue; const RttiType: TRttiType): TJSONValue;
    class function ConvertGuidToJson(const Value: TValue): TJSONValue;
    class function TrySerializeList(Obj: TObject; out Json: TJSONValue): Boolean;
    class function CreateInstanceFromType(const RttiType: TRttiType): TObject;
    class function IsGuid(const RttiType: TRttiType): Boolean;
    class function IsWireField(const RttiField: TRttiField): Boolean;
    class function HasWireFields(const RttiType: TRttiType): Boolean;
    class procedure GuardKnownKeys(const Json: TJSONObject; const KnownNorms: TStringList);
    class procedure GuardRecordKeys(const Json: TJSONObject; const RttiType: TRttiType);
    class procedure GuardFieldHasType(const RttiType: TRttiType; const RttiField: TRttiField);

    class function DeserializeDynamicArray(const DynArrayType: TRttiDynamicArrayType; const JsonArray: TJSONArray): TValue;
    class function DeserializeGenericList(const ListType: TRttiInstanceType; const JsonArray: TJSONArray): TValue;
    class function FindAddMethod(const ListType: TRttiInstanceType): TRttiMethod;

    class function GetJsonValueCaseInsensitive(const Json: TJSONObject; const PropName: string): TJSONValue;

    class function NormalizeKey(const Name: string): string; inline;
    class function IsRequiredMember(const Member: TRttiNamedObject): Boolean;

    class procedure CollectCreatedObjects(const Value: TValue; const RttiType: TRttiType;
      const Owned: TList<TObject>);
    class procedure CollectFromArray(const Value: TValue; const ElementType: TRttiType;
      const Owned: TList<TObject>);
    class procedure CollectFromRecord(const Value: TValue; const RttiType: TRttiType;
      const Owned: TList<TObject>);
  public
    class constructor Create;
    class destructor Destroy;

    class function GetWireName(const Member: TRttiNamedObject): string;

    class function Deserialize<T: class, constructor>(const Json: TJSONObject): T;
    class procedure Serialize(Obj: TObject; Json: TJSONObject);

    class function JsonToValue(const JsonValue: TJSONValue; const RttiType: TRttiType;
      const Owned: TList<TObject>): TValue;
    class function ValueToJson(const Value: TValue; const RttiType: TRttiType): TJSONValue;

    class function SerializeToString(Obj: TObject): string;
  end;

implementation

uses
  System.Math,
  System.DateUtils,
  MCPServer.Types;

const
  MESSAGE_EXPECTED_INTEGER = 'expected an integer';
  MESSAGE_EXPECTED_OBJECT = 'expected an object';
  MESSAGE_EXPECTED_UUID = 'expected a UUID string';

  OWNERSHIP_BEARING_KINDS = [tkClass, tkDynArray, tkRecord, tkMRecord];


{ TMCPSerializer }

class constructor TMCPSerializer.Create;
begin
  FContext := TRttiContext.Create;
end;

class destructor TMCPSerializer.Destroy;
begin
  FContext.Free;
end;

class function TMCPSerializer.Deserialize<T>(const Json: TJSONObject): T;
begin
  Result := T.Create;
  try
    DeserializeObject(Result, Json);
  except
    Result.Free;
    raise;
  end;
end;

class function TMCPSerializer.NormalizeKey(const Name: string): string;
begin
  Result := LowerCase(Name).Replace('_', '', [rfReplaceAll]);
end;

class function TMCPSerializer.GetJsonValueCaseInsensitive(const Json: TJSONObject; const PropName: string): TJSONValue;
var
  Pair: TJSONPair;
  PropNorm: string;
begin
  Result := Json.GetValue(PropName);
  if Assigned(Result) then
    Exit;

  PropNorm := NormalizeKey(PropName);
  for Pair in Json do
    if NormalizeKey(Pair.JsonString.Value) = PropNorm then
      Exit(Pair.JsonValue);
end;

class procedure TMCPSerializer.DeserializeObject(Instance: TObject; const Json: TJSONObject);
var
  JsonValue: TJSONValue;
  KnownNorms: TStringList;
  PropValue: TValue;
  RttiProp: TRttiProperty;
  RttiType: TRttiType;
begin
  RttiType := FContext.GetType(Instance.ClassType);

  KnownNorms := TStringList.Create;
  try
    for RttiProp in RttiType.GetProperties do
      if RttiProp.IsWritable then
        KnownNorms.Add(NormalizeKey(GetWireName(RttiProp)));

    GuardKnownKeys(Json, KnownNorms);
  finally
    KnownNorms.Free;
  end;

  for RttiProp in RttiType.GetProperties do
  begin
    if not RttiProp.IsWritable then
      Continue;

    JsonValue := GetJsonValueCaseInsensitive(Json, GetWireName(RttiProp));

    if not Assigned(JsonValue) or (JsonValue is TJSONNull) then
    begin
      if IsRequiredMember(RttiProp) then
        raise EArgumentException.CreateFmt('Missing required parameter "%s"', [GetWireName(RttiProp)]);
      Continue;
    end;

    try
      PropValue := ConvertJsonToValue(JsonValue, RttiProp.PropertyType);
    except
      on E: EArgumentException do
        raise EArgumentException.CreateFmt('Parameter "%s": %s', [GetWireName(RttiProp), E.Message]);
    end;

    if not PropValue.IsEmpty then
    begin
      {$WARN UNSAFE_CAST OFF}
      RttiProp.SetValue(Instance, PropValue);
      {$WARN UNSAFE_CAST ON}
    end;
  end;
end;

class function TMCPSerializer.IsRequiredMember(const Member: TRttiNamedObject): Boolean;
begin
  for var Attr in Member.GetAttributes do
    if Attr is OptionalAttribute then
      Exit(False);
  Result := True;
end;

class function TMCPSerializer.GetWireName(const Member: TRttiNamedObject): string;
begin
  for var Attr in Member.GetAttributes do
    if Attr is SchemaNameAttribute then
      begin
        Result := SchemaNameAttribute(Attr).Name;
        Exit;
      end;
  Result := LowerCase(Member.Name);
end;

class function TMCPSerializer.IsGuid(const RttiType: TRttiType): Boolean;
begin
  Result := (RttiType.Handle = TypeInfo(TGUID));
end;

class function TMCPSerializer.IsWireField(const RttiField: TRttiField): Boolean;
begin
  Result := (RttiField.Visibility in SCHEMA_FIELD_VISIBILITIES);
end;

class function TMCPSerializer.HasWireFields(const RttiType: TRttiType): Boolean;
begin
  for var RttiField in RttiType.GetFields do
    if IsWireField(RttiField) then
      Exit(True);
  Result := False;
end;

class procedure TMCPSerializer.GuardKnownKeys(const Json: TJSONObject; const KnownNorms: TStringList);
begin
  for var Pair in Json do
  begin
    const KeyName = Pair.JsonString.Value;
    if KnownNorms.IndexOf(NormalizeKey(KeyName)) < 0 then
      raise EArgumentException.CreateFmt(
        'Unknown parameter "%s". Valid parameters: %s.',
        [KeyName, String.Join(', ', KnownNorms.ToStringArray)]);
  end;
end;

class procedure TMCPSerializer.GuardRecordKeys(const Json: TJSONObject; const RttiType: TRttiType);
begin
  const KnownNorms = TStringList.Create;
  try
    for var RttiField in RttiType.GetFields do
      if IsWireField(RttiField) then
        KnownNorms.Add(NormalizeKey(GetWireName(RttiField)));

    GuardKnownKeys(Json, KnownNorms);
  finally
    KnownNorms.Free;
  end;
end;

class procedure TMCPSerializer.GuardFieldHasType(const RttiType: TRttiType;
  const RttiField: TRttiField);
begin
  if not Assigned(RttiField.FieldType) then
    raise EArgumentException.CreateFmt('Field %s.%s has no type RTTI, so it has no JSON value',
      [RttiType.Name, RttiField.Name]);
end;

class procedure TMCPSerializer.Serialize(Obj: TObject; Json: TJSONObject);
var
  JsonValue: TJSONValue;
  PropName: string;
  PropValue: TValue;
  RttiProp: TRttiProperty;
  RttiType: TRttiType;
begin
  RttiType := FContext.GetType(Obj.ClassType);

  for RttiProp in RttiType.GetProperties do
  begin
    if not RttiProp.IsReadable then
      Continue;

    PropName := GetWireName(RttiProp);
    {$WARN UNSAFE_CAST OFF}
    PropValue := RttiProp.GetValue(Obj);
    {$WARN UNSAFE_CAST ON}

    JsonValue := ConvertValueToJson(PropValue, RttiProp.PropertyType);

    if Assigned(JsonValue) then
      Json.AddPair(PropName, JsonValue);
  end;
end;

class procedure TMCPSerializer.CollectCreatedObjects(const Value: TValue; const RttiType: TRttiType;
  const Owned: TList<TObject>);
begin
  if not Assigned(Owned) or not Assigned(RttiType) or Value.IsEmpty then
    Exit;

  case RttiType.TypeKind of
    tkClass:
      if Value.IsObject and (Value.AsObject <> nil) then
        Owned.Add(Value.AsObject);

    tkDynArray:
      CollectFromArray(Value, TRttiDynamicArrayType(RttiType).ElementType, Owned);

    tkRecord, tkMRecord:
      CollectFromRecord(Value, RttiType, Owned);
  end;
end;

class procedure TMCPSerializer.CollectFromArray(const Value: TValue; const ElementType: TRttiType;
  const Owned: TList<TObject>);
begin
  const CarriesOwnership = Assigned(ElementType) and (ElementType.TypeKind in OWNERSHIP_BEARING_KINDS);
  if not CarriesOwnership then
    Exit;

  for var Index := 0 to Value.GetArrayLength - 1 do
  begin
    CollectCreatedObjects(Value.GetArrayElement(Index), ElementType, Owned);
  end;
end;

class procedure TMCPSerializer.CollectFromRecord(const Value: TValue; const RttiType: TRttiType;
  const Owned: TList<TObject>);
begin
  if IsGuid(RttiType) then
    Exit;

  const Data = Value.GetReferenceToRawData;
  for var RttiField in RttiType.GetFields do
  begin
    const HoldsAValue = (IsWireField(RttiField) and Assigned(RttiField.FieldType));
    if HoldsAValue then
      CollectCreatedObjects(RttiField.GetValue(Data), RttiField.FieldType, Owned);
  end;
end;

class function TMCPSerializer.JsonToValue(const JsonValue: TJSONValue; const RttiType: TRttiType;
  const Owned: TList<TObject>): TValue;
begin
  Result := TValue.Empty;
  if not Assigned(RttiType) then
    Exit;

  Result := ConvertJsonToValue(JsonValue, RttiType);
  CollectCreatedObjects(Result, RttiType, Owned);
end;

class function TMCPSerializer.ValueToJson(const Value: TValue; const RttiType: TRttiType): TJSONValue;
begin
  Result := nil;
  if not Assigned(RttiType) then
    Exit;

  Result := ConvertValueToJson(Value, RttiType);
end;

class function TMCPSerializer.SerializeToString(Obj: TObject): string;
var
  Json: TJSONObject;
begin
  Json := TJSONObject.Create;
  try
    Serialize(Obj, Json);
    Result := Json.ToJSON;
  finally
    Json.Free;
  end;
end;

class function TMCPSerializer.ConvertJsonToInteger(const JsonValue: TJSONValue; const RttiType: TRttiType): TValue;
begin
  if not (JsonValue is TJSONNumber) then
    raise EArgumentException.Create(MESSAGE_EXPECTED_INTEGER);

  const Number = TJSONNumber(JsonValue);
  const IsWhole = (Frac(Number.AsDouble) = 0);
  if not IsWhole then
    raise EArgumentException.Create(MESSAGE_EXPECTED_INTEGER);

  if RttiType.TypeKind = tkInt64 then
    Exit(Number.AsInt64);

  const Ordinal = TRttiOrdinalType(RttiType);
  const InRange = ((Number.AsInt64 >= Ordinal.MinValue) and (Number.AsInt64 <= Ordinal.MaxValue));
  if not InRange then
    raise EArgumentException.CreateFmt('%d is outside the range of %s', [Number.AsInt64, RttiType.Name]);
  Result := TValue.FromOrdinal(RttiType.Handle, Number.AsInt64);
end;

class function TMCPSerializer.ConvertJsonToFloat(const JsonValue: TJSONValue; const RttiType: TRttiType): TValue;
begin
  const IsDateTime = (RttiType.Handle = TypeInfo(TDateTime));
  if not IsDateTime then
  begin
    if not (JsonValue is TJSONNumber) then
      raise EArgumentException.Create('expected a number');
    begin
      Result := TJSONNumber(JsonValue).AsDouble;
      Exit;
    end;
  end;

  if not IsJsonString(JsonValue) then
    raise EArgumentException.Create('expected a date-time string');
  try
    Result := TValue.From<TDateTime>(ISO8601ToDate(JsonValue.Value, False));
  except
    on E: EConvertError do
      raise EArgumentException.Create('expected an ISO 8601 date-time');
    on E: EDateTimeException do
      raise EArgumentException.Create('expected an ISO 8601 date-time');
  end;
end;

class function TMCPSerializer.ConvertJsonToClass(const JsonValue: TJSONValue; const RttiType: TRttiType): TValue;
begin
  Result := TValue.Empty;
  if JsonValue is TJSONArray then
    begin
      Result := DeserializeArray(RttiType, TJSONArray(JsonValue));
      Exit;
    end;
  if not (JsonValue is TJSONObject) then
    raise EArgumentException.Create(MESSAGE_EXPECTED_OBJECT);

  const NestedInstance = CreateInstanceFromType(RttiType);
  if not Assigned(NestedInstance) then
    Exit;

  try
    DeserializeObject(NestedInstance, TJSONObject(JsonValue));
  except
    NestedInstance.Free;
    raise;
  end;
  Result := NestedInstance;
end;

class function TMCPSerializer.ConvertJsonToValue(const JsonValue: TJSONValue; const RttiType: TRttiType): TValue;
begin
  Result := TValue.Empty;
  if not Assigned(JsonValue) then
    Exit;

  case RttiType.TypeKind of
    tkInteger, tkInt64:
      Result := ConvertJsonToInteger(JsonValue, RttiType);

    tkFloat:
      Result := ConvertJsonToFloat(JsonValue, RttiType);

    tkString, tkLString, tkWString, tkUString:
      begin
        if not IsJsonString(JsonValue) then
          raise EArgumentException.Create('expected a string');
        Result := JsonValue.Value;
      end;

    tkEnumeration:
      if RttiType.Handle = TypeInfo(Boolean) then
      begin
        if not (JsonValue is TJSONBool) then
          raise EArgumentException.Create('expected a boolean');
        Result := TJSONBool(JsonValue).AsBoolean;
      end
      else
        Result := ConvertJsonToEnum(JsonValue, RttiType);

    tkClass:
      Result := ConvertJsonToClass(JsonValue, RttiType);

    tkRecord, tkMRecord:
      Result := ConvertJsonToRecord(JsonValue, RttiType);

    tkDynArray:
      begin
        if not (JsonValue is TJSONArray) then
          raise EArgumentException.Create('expected an array');
        Result := DeserializeArray(RttiType, TJSONArray(JsonValue));
      end;
  else
    Result := TValue.Empty;
  end;
end;

class function TMCPSerializer.ConvertJsonToRecord(const JsonValue: TJSONValue;
  const RttiType: TRttiType): TValue;
begin
  if IsGuid(RttiType) then
    Exit(ConvertJsonToGuid(JsonValue));

  if not HasWireFields(RttiType) then
    Exit(TValue.Empty);

  if not (JsonValue is TJSONObject) then
    raise EArgumentException.Create(MESSAGE_EXPECTED_OBJECT);

  const Json = TJSONObject(JsonValue);
  GuardRecordKeys(Json, RttiType);

  TValue.Make(nil, RttiType.Handle, Result);
  try
    FillRecordFields(Json, RttiType, Result.GetReferenceToRawData);
  except
    FreeRecordObjects(Result, RttiType);
    raise;
  end;
end;

class function TMCPSerializer.ConvertJsonToGuid(const JsonValue: TJSONValue): TValue;
begin
  if not IsJsonString(JsonValue) then
    raise EArgumentException.Create(MESSAGE_EXPECTED_UUID);

  const Text = JsonValue.Value.Trim;
  const IsBraced = Text.StartsWith('{');
  var Braced := Text;
  if not IsBraced then
    Braced := Format('{%s}', [Text]);

  try
    Result := TValue.From<TGUID>(StringToGUID(Braced));
  except
    on E: EConvertError do
      raise EArgumentException.Create(MESSAGE_EXPECTED_UUID);
  end;
end;

class procedure TMCPSerializer.FillRecordFields(const Json: TJSONObject; const RttiType: TRttiType;
  const Data: Pointer);
begin
  for var RttiField in RttiType.GetFields do
  begin
    if not IsWireField(RttiField) then
      Continue;

    GuardFieldHasType(RttiType, RttiField);

    const WireName = GetWireName(RttiField);
    const Member = GetJsonValueCaseInsensitive(Json, WireName);

    const IsAbsent = (not Assigned(Member) or (Member is TJSONNull));
    if IsAbsent then
    begin
      if IsRequiredMember(RttiField) then
        raise EArgumentException.CreateFmt('Missing required parameter "%s"', [WireName]);
      Continue;
    end;

    var FieldValue: TValue;
    try
      FieldValue := ConvertJsonToValue(Member, RttiField.FieldType);
    except
      on E: EArgumentException do
        raise EArgumentException.CreateFmt('Parameter "%s": %s', [WireName, E.Message]);
    end;

    if not FieldValue.IsEmpty then
      RttiField.SetValue(Data, FieldValue);
  end;
end;

class procedure TMCPSerializer.FreeRecordObjects(const Value: TValue; const RttiType: TRttiType);
begin
  const Held = TObjectList<TObject>.Create(True);
  try
    CollectFromRecord(Value, RttiType, Held);
  finally
    Held.Free;
  end;
end;

class function TMCPSerializer.ConvertJsonToEnum(const JsonValue: TJSONValue; const RttiType: TRttiType): TValue;
var
  EnumType: TRttiEnumerationType;
  Ordinal: Integer;
begin
  Result := TValue.Empty;

  if not (RttiType is TRttiEnumerationType) then
    Exit;

  EnumType := TRttiEnumerationType(RttiType);

  if JsonValue is TJSONNumber then
    Ordinal := (JsonValue as TJSONNumber).AsInt
  else
  begin
    if JsonValue.Value = '' then
      Exit;

    Ordinal := GetEnumValue(RttiType.Handle, JsonValue.Value);
    if Ordinal < 0 then
      Ordinal := StrToIntDef(JsonValue.Value, -1);
  end;

  if (Ordinal < EnumType.MinValue) or (Ordinal > EnumType.MaxValue) then
    raise EArgumentException.CreateFmt(
      'Invalid value "%s". Valid values: %s.',
      [JsonValue.Value, GetEnumValueNames(EnumType)]);

  Result := TValue.FromOrdinal(RttiType.Handle, Ordinal);
end;

class function TMCPSerializer.GetEnumValueNames(const EnumType: TRttiEnumerationType): string;
var
  Names: TArray<string>;
  Ordinal: Integer;
begin
  SetLength(Names, EnumType.MaxValue - EnumType.MinValue + 1);

  for Ordinal := EnumType.MinValue to EnumType.MaxValue do
  begin
    Names[Ordinal - EnumType.MinValue] := GetEnumName(EnumType.Handle, Ordinal);
  end;

  Result := String.Join(', ', Names);
end;

class function TMCPSerializer.CreateInstanceFromType(const RttiType: TRttiType): TObject;
var
  InstanceType: TRttiInstanceType;
  MetaClass: TClass;
begin
  Result := nil;

  if RttiType is TRttiInstanceType then
  begin
    InstanceType := TRttiInstanceType(RttiType);
    MetaClass := InstanceType.MetaclassType;

    if Assigned(MetaClass) then
      Result := MetaClass.Create;
  end;
end;

class function TMCPSerializer.ConvertValueToJson(const Value: TValue; const RttiType: TRttiType): TJSONValue;
var
  ChildJson: TJSONObject;
  Obj: TObject;
begin
  Result := nil;

  if Value.IsEmpty then
  begin
    case RttiType.TypeKind of
      tkClass:
        Result := TJSONNull.Create;
      tkDynArray:
        Result := TJSONArray.Create;
    end;
    Exit;
  end;

  case RttiType.TypeKind of
    tkInteger:
      Result := TJSONNumber.Create(Value.AsInteger);

    tkInt64:
      Result := TJSONNumber.Create(Value.AsInt64);

    tkFloat:
      if RttiType.Handle = TypeInfo(TDateTime) then
        Result := TJSONString.Create(DateToISO8601(Value.AsType<TDateTime>, False))
      else
        Result := TJSONNumber.Create(Value.AsExtended);

    tkString, tkLString, tkWString, tkUString, tkChar, tkWChar:
      Result := TJSONString.Create(Value.AsString);

    tkEnumeration:
      if RttiType.Handle = TypeInfo(Boolean) then
        Result := TJSONBool.Create(Value.AsBoolean)
      else
        Result := TJSONString.Create(GetEnumName(RttiType.Handle, Integer(Value.AsOrdinal)));

    tkSet:
      begin
        const Names = TJSONArray.Create;
        const ElementType = TRttiEnumerationType(TRttiSetType(RttiType).ElementType);
        const Bytes = PByte(Value.GetReferenceToRawData);
        const FirstBit = ElementType.MinValue and not 7;
        for var Ordinal := ElementType.MinValue to ElementType.MaxValue do
        begin
          const BitIndex = Ordinal - FirstBit;
          const ByteIndex = BitIndex div 8;
          const IsMember = ((ByteIndex < Value.DataSize) and ((Bytes[ByteIndex] and (1 shl (BitIndex mod 8))) <> 0));
          if IsMember then
            Names.Add(GetEnumName(ElementType.Handle, Ordinal));
        end;
        Result := Names;
      end;

    tkDynArray:
      begin
        var Items := TJSONArray.Create;
        var ElementType := TRttiDynamicArrayType(RttiType).ElementType;
        for var I := 0 to Value.GetArrayLength - 1 do
        begin
          var Item := ConvertValueToJson(Value.GetArrayElement(I), ElementType);
          if Assigned(Item) then
            Items.AddElement(Item)
          else
            Items.AddElement(TJSONNull.Create);
        end;
        Result := Items;
      end;

    tkClass:
      if Value.IsObject and (Value.AsObject <> nil) then
      begin
        Obj := Value.AsObject;

        if Obj is TJSONValue then
        begin
          Result := TJSONValue(Obj).Clone as TJSONValue;
        end
        else if not TrySerializeList(Obj, Result) then
        begin
          ChildJson := TJSONObject.Create;
          Serialize(Obj, ChildJson);
          Result := ChildJson;
        end;
      end
      else
        Result := TJSONNull.Create;

    tkRecord, tkMRecord:
      Result := ConvertRecordToJson(Value, RttiType);
  end;
end;

class function TMCPSerializer.ConvertRecordToJson(const Value: TValue;
  const RttiType: TRttiType): TJSONValue;
begin
  if IsGuid(RttiType) then
    Exit(ConvertGuidToJson(Value));

  if not HasWireFields(RttiType) then
    Exit(nil);

  const Json = TJSONObject.Create;
  try
    const Data = Value.GetReferenceToRawData;
    for var RttiField in RttiType.GetFields do
    begin
      if not IsWireField(RttiField) then
        Continue;

      GuardFieldHasType(RttiType, RttiField);

      const Member = ConvertValueToJson(RttiField.GetValue(Data), RttiField.FieldType);
      if Assigned(Member) then
        Json.AddPair(GetWireName(RttiField), Member);
    end;
  except
    Json.Free;
    raise;
  end;

  Result := Json;
end;

class function TMCPSerializer.ConvertGuidToJson(const Value: TValue): TJSONValue;
begin
  const Braced = GUIDToString(Value.AsType<TGUID>);
  const Bare = Braced.Trim(['{', '}']);
  Result := TJSONString.Create(LowerCase(Bare));
end;

class function TMCPSerializer.TrySerializeList(Obj: TObject; out Json: TJSONValue): Boolean;
var
  ListType: TRttiType;
  CountProp: TRttiProperty;
  ItemsProp: TRttiIndexedProperty;
  IndexParams: TArray<TRttiParameter>;
  Items: TJSONArray;
  Item: TJSONValue;
  Count: Integer;
  I: Integer;
begin
  Result := False;
  Json := nil;

  ListType := FContext.GetType(Obj.ClassType);
  CountProp := ListType.GetProperty('Count');
  ItemsProp := ListType.GetIndexedProperty('Items');
  if not Assigned(CountProp) or not Assigned(ItemsProp) or not ItemsProp.IsReadable or
    not Assigned(ItemsProp.ReadMethod) then
    Exit;

  IndexParams := ItemsProp.ReadMethod.GetParameters;
  if (Length(IndexParams) <> 1) or not (IndexParams[0].ParamType.TypeKind in [tkInteger, tkInt64]) then
    Exit;

  {$WARN UNSAFE_CAST OFF}
  Count := Integer(CountProp.GetValue(Obj).AsInt64);
  {$WARN UNSAFE_CAST ON}
  Items := TJSONArray.Create;
  for I := 0 to Count - 1 do
  begin
    {$WARN UNSAFE_CAST OFF}
    Item := ConvertValueToJson(ItemsProp.GetValue(Obj, [I]), ItemsProp.PropertyType);
    {$WARN UNSAFE_CAST ON}
    if Assigned(Item) then
      Items.AddElement(Item)
    else
      Items.AddElement(TJSONNull.Create);
  end;

  Json := Items;
  Result := True;
end;

class function TMCPSerializer.DeserializeArray(RttiType: TRttiType; const JsonArray: TJSONArray): TValue;
begin
  Result := TValue.Empty;

  if RttiType is TRttiDynamicArrayType then
    Result := DeserializeDynamicArray(TRttiDynamicArrayType(RttiType), JsonArray)
  else if (RttiType is TRttiInstanceType) and
          (TRttiInstanceType(RttiType).MetaclassType.InheritsFrom(TList)) then
    Result := DeserializeGenericList(TRttiInstanceType(RttiType), JsonArray);
end;

class function TMCPSerializer.DeserializeDynamicArray(const DynArrayType: TRttiDynamicArrayType; const JsonArray: TJSONArray): TValue;
var
  ArrayLength: NativeInt;
  ElementType: TRttiType;
  ElementValue: TValue;
  I: NativeInt;
  JsonElement: TJSONValue;
begin
  ElementType := DynArrayType.ElementType;
  ArrayLength := JsonArray.Count;

  Result := TValue.Empty;
  TValue.Make(nil, DynArrayType.Handle, Result);
  DynArraySetLength(PPointer(Result.GetReferenceToRawData)^, Result.TypeInfo, 1, @ArrayLength);

  for I := 0 to ArrayLength - 1 do
  begin
    JsonElement := JsonArray.Items[Integer(I)];
    ElementValue := ConvertJsonToValue(JsonElement, ElementType);

    if not ElementValue.IsEmpty then
      Result.SetArrayElement(I, ElementValue);
  end;
end;

class function TMCPSerializer.DeserializeGenericList(const ListType: TRttiInstanceType; const JsonArray: TJSONArray): TValue;
var
  AddMethod: TRttiMethod;
  ElementValue: TValue;
  I: Integer;
  JsonElement: TJSONValue;
  ListInstance: TObject;
  ParamType: TRttiType;
begin
  ListInstance := ListType.MetaclassType.Create;

  AddMethod := FindAddMethod(ListType);
  if not Assigned(AddMethod) then
  begin
    ListInstance.Free;
    Exit(TValue.Empty);
  end;

  ParamType := AddMethod.GetParameters[0].ParamType;

  for I := 0 to JsonArray.Count - 1 do
  begin
    JsonElement := JsonArray.Items[I];
    ElementValue := ConvertJsonToValue(JsonElement, ParamType);

    if not ElementValue.IsEmpty then
      AddMethod.Invoke(ListInstance, [ElementValue]);
  end;

  Result := ListInstance;
end;

class function TMCPSerializer.FindAddMethod(const ListType: TRttiInstanceType): TRttiMethod;
var
  Method: TRttiMethod;
begin
  Result := nil;

  for Method in ListType.GetMethods do
  begin
    if SameText(Method.Name, 'Add') and (Length(Method.GetParameters) = 1) then
    begin
      Result := Method;
      Break;
    end;
  end;
end;

end.