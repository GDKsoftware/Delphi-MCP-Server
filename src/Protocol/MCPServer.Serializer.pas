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
    class function ConvertValueToJson(const Value: TValue; const RttiType: TRttiType): TJSONValue;
    class function CreateInstanceFromType(const RttiType: TRttiType): TObject;

    // Array deserialization helpers
    class function DeserializeDynamicArray(const DynArrayType: TRttiDynamicArrayType; const JsonArray: TJSONArray): TValue;
    class function DeserializeGenericList(const ListType: TRttiInstanceType; const JsonArray: TJSONArray): TValue;
    class function FindAddMethod(const ListType: TRttiInstanceType): TRttiMethod;

    // Case-insensitive JSON value lookup
    class function GetJsonValueCaseInsensitive(const Json: TJSONObject; const PropName: string): TJSONValue;

    // Single normalization rule shared by lookup and validation
    class function NormalizeKey(const Name: string): string; inline;
  public
    class constructor Create;
    class destructor Destroy;

    class function Deserialize<T: class, constructor>(const Json: TJSONObject): T;
    class procedure Serialize(Obj: TObject; Json: TJSONObject);

    class function SerializeToString(Obj: TObject): string;
  end;

implementation

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

    if not Assigned(JsonValue) then
      Continue;

    PropValue := ConvertJsonToValue(JsonValue, RttiProp.PropertyType);

    if not PropValue.IsEmpty then
    begin
      {$WARN UNSAFE_CAST OFF}
      RttiProp.SetValue(Instance, PropValue);
      {$WARN UNSAFE_CAST ON}
    end;
  end;
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
  EnumValue: Integer;
  NestedInstance: TObject;
begin
  Result := TValue.Empty;
  
  if not Assigned(JsonValue) then
    Exit;
    
  case RttiType.TypeKind of
    tkInteger:
      if JsonValue is TJSONNumber then
        Result := (JsonValue as TJSONNumber).AsInt
      else
        Result := StrToIntDef(JsonValue.Value, 0);

    tkInt64:
      if JsonValue is TJSONNumber then
        Result := (JsonValue as TJSONNumber).AsInt64
      else
        Result := StrToInt64Def(JsonValue.Value, 0);
        
    tkFloat:
      if JsonValue is TJSONNumber then
        Result := (JsonValue as TJSONNumber).AsDouble
      else
{$IF COMPILERVERSION <= 28}
        Result := StrToFloatDef(JsonValue.Value, 0, TFormatSettings.Create('en-US'));
{$ELSE}
        Result := StrToFloatDef(JsonValue.Value, 0, FormatSettings.Invariant);
{$ENDIF}

    tkString, tkLString, tkWString, tkUString:
      Result := JsonValue.Value;
      
    tkEnumeration:
      if RttiType.Handle = TypeInfo(Boolean) then
      begin
{$IF COMPILERVERSION <= 29}
        if (JsonValue is TJSONTrue) or (JsonValue is TJSONFalse) then
          Result := JsonValue is TJSONTrue
{$ELSE}
        if JsonValue is TJSONBool then
          Result := (JsonValue as TJSONBool).AsBoolean
{$ENDIF}
        else
          Result := LowerCase(JsonValue.Value) = 'true';
      end
      else
      begin
        if JsonValue is TJSONNumber then
          Result := TValue.FromOrdinal(RttiType.Handle, (JsonValue as TJSONNumber).AsInt)
        else
        begin
          EnumValue := GetEnumValue(RttiType.Handle, JsonValue.Value);
          if EnumValue >= 0 then
            Result := TValue.FromOrdinal(RttiType.Handle, EnumValue)
          else
            Result := TValue.FromOrdinal(RttiType.Handle, StrToIntDef(JsonValue.Value, 0));
        end;
      end;
      
    tkClass:
      if JsonValue is TJSONObject then
      begin
        NestedInstance := CreateInstanceFromType(RttiType);
        if Assigned(NestedInstance) then
        begin
          DeserializeObject(NestedInstance, JsonValue as TJSONObject);
          Result := NestedInstance;
        end;
      end
      else if JsonValue is TJSONArray then
        Result := DeserializeArray(RttiType, JsonValue as TJSONArray);
        
    tkDynArray:
      if JsonValue is TJSONArray then
        Result := DeserializeArray(RttiType, JsonValue as TJSONArray);
  end;
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
    Exit;
    
  case RttiType.TypeKind of
    tkInteger:
      Result := TJSONNumber.Create(Value.AsInteger);

    tkInt64:
      Result := TJSONNumber.Create(Value.AsInt64);
      
    tkFloat:
      Result := TJSONNumber.Create(Value.AsExtended);
      
    tkString, tkLString, tkWString, tkUString:
      Result := TJSONString.Create(Value.AsString);
      
    tkEnumeration:
      begin
{$IF COMPILERVERSION <= 29}
        if Value.AsBoolean then
          Result := TJSONTrue.Create
        else
          Result := TJSONFalse.Create;
{$ELSE}
        Result := TJSONBool.Create(Value.AsBoolean);
{$ENDIF}
      end;

    tkClass:
      if Value.IsObject and (Value.AsObject <> nil) then
      begin
        Obj := Value.AsObject;

        if Obj is TJSONValue then
        begin
          Result := TJSONValue(Obj).Clone as TJSONValue;
        end
        else
        begin
          ChildJson := TJSONObject.Create;
          Serialize(Obj, ChildJson);
          Result := ChildJson;
        end;
      end;
  end;
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