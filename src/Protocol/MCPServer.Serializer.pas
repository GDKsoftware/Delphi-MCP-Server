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

class procedure TMCPSerializer.DeserializeObject(Instance: TObject; const Json: TJSONObject);
begin
  var RttiType := FContext.GetType(Instance.ClassType);

  for var RttiProp in RttiType.GetProperties do
  begin
    if not RttiProp.IsWritable then
      Continue;
      
    var PropName := LowerCase(RttiProp.Name);
    var JsonValue := Json.GetValue(PropName);
    
    if not Assigned(JsonValue) then
      Continue;
      
    var PropValue := ConvertJsonToValue(JsonValue, RttiProp.PropertyType);
    
    if not PropValue.IsEmpty then
    begin
      {$WARN UNSAFE_CAST OFF}
      RttiProp.SetValue(Instance, PropValue);
      {$WARN UNSAFE_CAST ON}
    end;
  end;
end;

class procedure TMCPSerializer.Serialize(Obj: TObject; Json: TJSONObject);
begin
  var RttiType := FContext.GetType(Obj.ClassType);
  
  for var RttiProp in RttiType.GetProperties do
  begin
    if not RttiProp.IsReadable then
      Continue;
      
    var PropName := LowerCase(RttiProp.Name);
    {$WARN UNSAFE_CAST OFF}
    var PropValue := RttiProp.GetValue(Obj);
    {$WARN UNSAFE_CAST ON}
    
    var JsonValue := ConvertValueToJson(PropValue, RttiProp.PropertyType);
    
    if Assigned(JsonValue) then
      Json.AddPair(PropName, JsonValue);
  end;
end;

class function TMCPSerializer.SerializeToString(Obj: TObject): string;
begin
  var Json := TJSONObject.Create;
  try
    Serialize(Obj, Json);
    Result := Json.ToJSON;
  finally
    Json.Free;
  end;
end;

class function TMCPSerializer.ConvertJsonToValue(const JsonValue: TJSONValue; const RttiType: TRttiType): TValue;
begin
  Result := TValue.Empty;
  
  if not Assigned(JsonValue) then
    Exit;
    
  case RttiType.TypeKind of
    tkInteger, tkInt64:
      if JsonValue is TJSONNumber then
        Result := (JsonValue as TJSONNumber).AsInt64
      else
        Result := StrToInt64Def(JsonValue.Value, 0);
        
    tkFloat:
      if JsonValue is TJSONNumber then
        Result := (JsonValue as TJSONNumber).AsDouble
      else
        Result := StrToFloatDef(JsonValue.Value, 0, FormatSettings.Invariant);
        
    tkString, tkLString, tkWString, tkUString:
      Result := JsonValue.Value;
      
    tkEnumeration:
      if RttiType.Handle = TypeInfo(Boolean) then
      begin
        if JsonValue is TJSONBool then
          Result := (JsonValue as TJSONBool).AsBoolean
        else
          Result := LowerCase(JsonValue.Value) = 'true';
      end
      else
      begin
        if JsonValue is TJSONNumber then
          Result := TValue.FromOrdinal(RttiType.Handle, (JsonValue as TJSONNumber).AsInt)
        else
          Result := TValue.FromOrdinal(RttiType.Handle, StrToIntDef(JsonValue.Value, 0));
      end;
      
    tkClass:
      if JsonValue is TJSONObject then
      begin
        var NestedInstance := CreateInstanceFromType(RttiType);
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
begin
  Result := nil;
  
  if RttiType is TRttiInstanceType then
  begin
    var InstanceType := TRttiInstanceType(RttiType);
    var MetaClass := InstanceType.MetaclassType;
    
    if Assigned(MetaClass) then
      Result := MetaClass.Create;
  end;
end;

class function TMCPSerializer.ConvertValueToJson(const Value: TValue; const RttiType: TRttiType): TJSONValue;
begin
  Result := nil;
  
  if Value.IsEmpty then
    Exit;
    
  case RttiType.TypeKind of
    tkInteger, tkInt64:
      Result := TJSONNumber.Create(Value.AsInt64);
      
    tkFloat:
      Result := TJSONNumber.Create(Value.AsExtended);
      
    tkString, tkLString, tkWString, tkUString:
      Result := TJSONString.Create(Value.AsString);
      
    tkEnumeration:
      if RttiType.Handle = TypeInfo(Boolean) then
        Result := TJSONBool.Create(Value.AsBoolean)
      else
        Result := TJSONNumber.Create(Value.AsOrdinal);
        
    tkClass:
      if Value.IsObject and (Value.AsObject <> nil) then
      begin
        var ChildJson := TJSONObject.Create;
        Serialize(Value.AsObject, ChildJson);
        Result := ChildJson;
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
begin
  var ElementType := DynArrayType.ElementType;
  var ArrayLength := JsonArray.Count;
  
  Result := TValue.Empty;
  TValue.Make(nil, DynArrayType.Handle, Result);
  DynArraySetLength(PPointer(Result.GetReferenceToRawData)^, Result.TypeInfo, 1, @ArrayLength);
  
  for var I := 0 to ArrayLength - 1 do
  begin
    var JsonElement := JsonArray.Items[I];
    var ElementValue := ConvertJsonToValue(JsonElement, ElementType);
    
    if not ElementValue.IsEmpty then
      Result.SetArrayElement(I, ElementValue);
  end;
end;

class function TMCPSerializer.DeserializeGenericList(const ListType: TRttiInstanceType; const JsonArray: TJSONArray): TValue;
begin
  var ListInstance := ListType.MetaclassType.Create;
  
  var AddMethod := FindAddMethod(ListType);
  if not Assigned(AddMethod) then
  begin
    ListInstance.Free;
    Exit(TValue.Empty);
  end;
  
  var ParamType := AddMethod.GetParameters[0].ParamType;
  
  for var I := 0 to JsonArray.Count - 1 do
  begin
    var JsonElement := JsonArray.Items[I];
    var ElementValue := ConvertJsonToValue(JsonElement, ParamType);
    
    if not ElementValue.IsEmpty then
      AddMethod.Invoke(ListInstance, [ElementValue]);
  end;
  
  Result := ListInstance;
end;

class function TMCPSerializer.FindAddMethod(const ListType: TRttiInstanceType): TRttiMethod;
begin
  Result := nil;
  
  for var Method in ListType.GetMethods do
  begin
    if SameText(Method.Name, 'Add') and (Length(Method.GetParameters) = 1) then
    begin
      Result := Method;
      Break;
    end;
  end;
end;

end.