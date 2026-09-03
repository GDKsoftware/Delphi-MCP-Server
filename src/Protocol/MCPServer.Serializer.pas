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

    // Extracted type conversion methods
    class function ConvertJsonToValue(const JsonValue: TJSONValue; const RttiType: TRttiType): TValue;
    class function ConvertJsonToEnum(const JsonValue: TJSONValue; const RttiType: TRttiType): TValue;
    class function GetEnumValueNames(const EnumType: TRttiEnumerationType): string;
    class function ConvertValueToJson(const Value: TValue; const RttiType: TRttiType): TJSONValue;
    class function TrySerializeList(Obj: TObject; out Json: TJSONValue): Boolean;
    class function CreateInstanceFromType(const RttiType: TRttiType): TObject;

    // Array deserialization helpers
    class function DeserializeDynamicArray(const DynArrayType: TRttiDynamicArrayType; const JsonArray: TJSONArray): TValue;
    class function DeserializeGenericList(const ListType: TRttiInstanceType; const JsonArray: TJSONArray): TValue;
    class function FindAddMethod(const ListType: TRttiInstanceType): TRttiMethod;

    // Case-insensitive JSON value lookup
    class function GetJsonValueCaseInsensitive(const Json: TJSONObject; const PropName: string): TJSONValue;

    // Single normalization rule shared by lookup and validation
    class function NormalizeKey(const Name: string): string; inline;
    class function IsRequiredProperty(const Prop: TRttiProperty): Boolean;
  public
    class constructor Create;
    class destructor Destroy;

    class function Deserialize<T: class, constructor>(const Json: TJSONObject): T;
    class procedure Serialize(Obj: TObject; Json: TJSONObject);

    class function SerializeToString(Obj: TObject): string;
  end;

implementation

uses
  System.Math,
  System.DateUtils,
  MCPServer.Types;

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
  KeyName: string;
  KnownNorms: TStringList;
  Pair: TJSONPair;
  PropValue: TValue;
  RttiProp: TRttiProperty;
  RttiType: TRttiType;
begin
  RttiType := FContext.GetType(Instance.ClassType);

  KnownNorms := TStringList.Create;
  try
    for RttiProp in RttiType.GetProperties do
      if RttiProp.IsWritable then
        KnownNorms.Add(NormalizeKey(RttiProp.Name));

    for Pair in Json do
    begin
      KeyName := Pair.JsonString.Value;
      if KnownNorms.IndexOf(NormalizeKey(KeyName)) < 0 then
        raise EArgumentException.CreateFmt(
          'Unknown parameter "%s". Valid parameters: %s.',
          [KeyName, String.Join(', ', KnownNorms.ToStringArray)]);
    end;
  finally
    KnownNorms.Free;
  end;

  for RttiProp in RttiType.GetProperties do
  begin
    if not RttiProp.IsWritable then
      Continue;

    JsonValue := GetJsonValueCaseInsensitive(Json, RttiProp.Name);

    // Absent and null both mean "not given"; a required parameter must be given.
    if not Assigned(JsonValue) or (JsonValue is TJSONNull) then
    begin
      if IsRequiredProperty(RttiProp) then
        raise EArgumentException.CreateFmt('Missing required parameter "%s"', [LowerCase(RttiProp.Name)]);
      Continue;
    end;

    try
      PropValue := ConvertJsonToValue(JsonValue, RttiProp.PropertyType);
    except
      on E: EArgumentException do
        raise EArgumentException.CreateFmt('Parameter "%s": %s', [LowerCase(RttiProp.Name), E.Message]);
    end;

    if not PropValue.IsEmpty then
    begin
      {$WARN UNSAFE_CAST OFF}
      RttiProp.SetValue(Instance, PropValue);
      {$WARN UNSAFE_CAST ON}
    end;
  end;
end;

class function TMCPSerializer.IsRequiredProperty(const Prop: TRttiProperty): Boolean;
begin
  for var Attr in Prop.GetAttributes do
    if Attr is OptionalAttribute then
      Exit(False);
  Result := True;
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

    PropName := LowerCase(RttiProp.Name);
    {$WARN UNSAFE_CAST OFF}
    PropValue := RttiProp.GetValue(Obj);
    {$WARN UNSAFE_CAST ON}
    
    JsonValue := ConvertValueToJson(PropValue, RttiProp.PropertyType);
    
    if Assigned(JsonValue) then
      Json.AddPair(PropName, JsonValue);
  end;
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

class function TMCPSerializer.ConvertJsonToValue(const JsonValue: TJSONValue; const RttiType: TRttiType): TValue;
var
  NestedInstance: TObject;
begin
  Result := TValue.Empty;
  
  if not Assigned(JsonValue) then
    Exit;
    
  // Values must have the JSON type the schema advertises; a mismatch is an
  // argument error the tool reports as isError, so the model can correct it.
  case RttiType.TypeKind of
    tkInteger, tkInt64:
      begin
        if not (JsonValue is TJSONNumber) then
          raise EArgumentException.Create('expected an integer');
        var Number := TJSONNumber(JsonValue);
        if Frac(Number.AsDouble) <> 0 then
          raise EArgumentException.Create('expected an integer');
        if RttiType.TypeKind = tkInt64 then
          Result := Number.AsInt64
        else
          Result := TValue.FromOrdinal(RttiType.Handle, Number.AsInt64);
      end;

    tkFloat:
      if RttiType.Handle = TypeInfo(TDateTime) then
      begin
        if not (JsonValue is TJSONString) then
          raise EArgumentException.Create('expected a date-time string');
        try
          Result := TValue.From<TDateTime>(ISO8601ToDate(JsonValue.Value, False));
        except
          raise EArgumentException.Create('expected an ISO 8601 date-time');
        end;
      end
      else
      begin
        if not (JsonValue is TJSONNumber) then
          raise EArgumentException.Create('expected a number');
        Result := TJSONNumber(JsonValue).AsDouble;
      end;

    tkString, tkLString, tkWString, tkUString:
      begin
        if not (JsonValue is TJSONString) or (JsonValue is TJSONNumber) then
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
      if JsonValue is TJSONObject then
      begin
        NestedInstance := CreateInstanceFromType(RttiType);
        if Assigned(NestedInstance) then
        begin
          try
            DeserializeObject(NestedInstance, JsonValue as TJSONObject);
          except
            NestedInstance.Free;
            raise;
          end;
          Result := NestedInstance;
        end;
      end
      else if JsonValue is TJSONArray then
        Result := DeserializeArray(RttiType, JsonValue as TJSONArray)
      else
        raise EArgumentException.Create('expected an object');

    tkDynArray:
      begin
        if not (JsonValue is TJSONArray) then
          raise EArgumentException.Create('expected an array');
        Result := DeserializeArray(RttiType, JsonValue as TJSONArray);
      end;
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
    Names[Ordinal - EnumType.MinValue] := GetEnumName(EnumType.Handle, Ordinal);

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

  // Empty means nil for objects and [] for dynamic arrays; both are worth
  // writing so the JSON has the property the schema advertises.
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
        Result := TJSONString.Create(GetEnumName(RttiType.Handle, Value.AsOrdinal));

    tkSet:
      begin
        // Every included element by its enum name.
        var Names := TJSONArray.Create;
        var ElementType := TRttiEnumerationType(TRttiSetType(RttiType).ElementType);
        // A set is stored from the byte that holds its lowest element.
        var SetBits: Int64 := 0;
        Move(Value.GetReferenceToRawData^, SetBits, Min(Value.DataSize, SizeOf(SetBits)));
        var FirstBit := ElementType.MinValue and not 7;
        for var Ordinal := ElementType.MinValue to ElementType.MaxValue do
          if (SetBits and (Int64(1) shl (Ordinal - FirstBit))) <> 0 then
            Names.Add(GetEnumName(ElementType.Handle, Ordinal));
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
  end;
end;

// Serialises TList<T> and TObjectList<T> (anything with an integer-indexed
// Items property and a Count) as a JSON array of their elements. Without
// this a list came out as an object with count and capacity members.
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
  if not Assigned(CountProp) or not Assigned(ItemsProp) or not ItemsProp.IsReadable
    or not Assigned(ItemsProp.ReadMethod) then
    Exit;

  // Only integer indexes: TDictionary<TKey, TValue> also has Count and Items.
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