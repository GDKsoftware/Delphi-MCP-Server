unit MCPServer.Schema.Generator;

interface

uses
  System.SysUtils,
  System.Rtti,
  System.TypInfo,
  System.JSON;

type
  TMCPSchemaGenerator = class
  private
    const MAX_NESTING_DEPTH = 8;
    class function GetPropertyJsonName(Prop: TRttiProperty): string;
    class function IsRequiredProperty(Prop: TRttiProperty): Boolean;
    class function CreateEnumValuesArray(RttiType: TRttiType): TJSONArray;
    class function ListItemType(RttiType: TRttiType): TRttiType;
    class function TypeSchema(RttiType: TRttiType; Depth: Integer): TJSONObject;
    class function ObjectSchema(RttiType: TRttiType; Depth: Integer): TJSONObject;
    class function NumberValue(const Value: Double): TJSONNumber;
    class procedure ApplyAttributes(Prop: TRttiProperty; const PropSchema: TJSONObject);
  public
    class function GenerateSchema(Cls: TClass): TJSONObject;
    class function GenerateSchemaFromInstance(Instance: TObject): TJSONObject;
  end;

implementation

uses
  System.Generics.Collections,
  MCPServer.Types;

var
  RttiContext: TRttiContext;

{ TMCPSchemaGenerator }

class function TMCPSchemaGenerator.GenerateSchema(Cls: TClass): TJSONObject;
begin
  Result := ObjectSchema(RttiContext.GetType(Cls), 0);
end;

class function TMCPSchemaGenerator.GenerateSchemaFromInstance(Instance: TObject): TJSONObject;
begin
  Result := GenerateSchema(Instance.ClassType);
end;

class function TMCPSchemaGenerator.GetPropertyJsonName(Prop: TRttiProperty): string;
begin
  for var Attr in Prop.GetAttributes do
    if Attr is SchemaNameAttribute then
      Exit(SchemaNameAttribute(Attr).Name);
  Result := LowerCase(Prop.Name);
end;

class function TMCPSchemaGenerator.IsRequiredProperty(Prop: TRttiProperty): Boolean;
begin
  for var Attr in Prop.GetAttributes do
    if Attr is OptionalAttribute then
      Exit(False);
  Result := True;
end;

class function TMCPSchemaGenerator.CreateEnumValuesArray(RttiType: TRttiType): TJSONArray;
begin
  Result := nil;
  if not (RttiType is TRttiEnumerationType) or (RttiType.Handle = TypeInfo(Boolean)) then
    Exit;

  var EnumType := TRttiEnumerationType(RttiType);
  Result := TJSONArray.Create;
  for var Ordinal := EnumType.MinValue to EnumType.MaxValue do
    Result.Add(GetEnumName(RttiType.Handle, Ordinal));
end;

class function TMCPSchemaGenerator.ListItemType(RttiType: TRttiType): TRttiType;
begin
  Result := nil;
  var ItemsProp := RttiType.GetIndexedProperty('Items');
  if not Assigned(ItemsProp) or not Assigned(ItemsProp.ReadMethod) then
    Exit;
  var Parameters := ItemsProp.ReadMethod.GetParameters;
  if (Length(Parameters) = 1) and (Parameters[0].ParamType.TypeKind in [tkInteger, tkInt64]) then
    Result := ItemsProp.PropertyType;
end;

class function TMCPSchemaGenerator.TypeSchema(RttiType: TRttiType; Depth: Integer): TJSONObject;
begin
  Result := TJSONObject.Create;
  try
    case RttiType.TypeKind of
      tkInteger, tkInt64:
        Result.AddPair('type', 'integer');

      tkFloat:
        if RttiType.Handle = TypeInfo(TDateTime) then
        begin
          Result.AddPair('type', 'string');
          Result.AddPair('format', 'date-time');
        end
        else if RttiType.Handle = TypeInfo(TDate) then
        begin
          Result.AddPair('type', 'string');
          Result.AddPair('format', 'date');
        end
        else if RttiType.Handle = TypeInfo(TTime) then
        begin
          Result.AddPair('type', 'string');
          Result.AddPair('format', 'time');
        end
        else
          Result.AddPair('type', 'number');

      tkString, tkLString, tkWString, tkUString, tkChar, tkWChar:
        Result.AddPair('type', 'string');

      tkEnumeration:
        if RttiType.Handle = TypeInfo(Boolean) then
          Result.AddPair('type', 'boolean')
        else
        begin
          Result.AddPair('type', 'string');
          Result.AddPair('enum', CreateEnumValuesArray(RttiType));
        end;

      tkSet:
        begin
          Result.AddPair('type', 'array');
          var Items := TJSONObject.Create;
          Result.AddPair('items', Items);
          Items.AddPair('type', 'string');
          var ElementType := TRttiSetType(RttiType).ElementType;
          var Names := CreateEnumValuesArray(ElementType);
          if Assigned(Names) then
            Items.AddPair('enum', Names);
        end;

      tkDynArray:
        begin
          Result.AddPair('type', 'array');
          Result.AddPair('items', TypeSchema(TRttiDynamicArrayType(RttiType).ElementType, Depth + 1));
        end;

      tkArray:
        begin
          Result.AddPair('type', 'array');
          Result.AddPair('items', TypeSchema(TRttiArrayType(RttiType).ElementType, Depth + 1));
        end;

      tkClass:
        begin
          var Metaclass := TRttiInstanceType(RttiType).MetaclassType;
          if Metaclass.InheritsFrom(TJSONArray) then
            Result.AddPair('type', 'array')
          else if Metaclass.InheritsFrom(TJSONValue) then
            Result.AddPair('type', 'object')
          else
          begin
            var ItemType := ListItemType(RttiType);
            if Assigned(ItemType) then
            begin
              Result.AddPair('type', 'array');
              Result.AddPair('items', TypeSchema(ItemType, Depth + 1));
            end
            else if Depth < MAX_NESTING_DEPTH then
            begin
              Result.Free;
              Result := ObjectSchema(RttiType, Depth + 1);
            end
            else
              Result.AddPair('type', 'object');
          end;
        end;
    else
      Result.AddPair('type', 'string');
    end;
  except
    Result.Free;
    raise;
  end;
end;

class function TMCPSchemaGenerator.NumberValue(const Value: Double): TJSONNumber;
begin
  if Frac(Value) = 0 then
    Result := TJSONNumber.Create(Trunc(Value))
  else
    Result := TJSONNumber.Create(Value);
end;

class procedure TMCPSchemaGenerator.ApplyAttributes(Prop: TRttiProperty; const PropSchema: TJSONObject);
begin
  for var Attr in Prop.GetAttributes do
  begin
    if Attr is SchemaDescriptionAttribute then
      PropSchema.AddPair('description', SchemaDescriptionAttribute(Attr).Description)
    else if Attr is SchemaTitleAttribute then
      PropSchema.AddPair('title', SchemaTitleAttribute(Attr).Title)
    else if Attr is SchemaFormatAttribute then
    begin
      PropSchema.RemovePair('format').Free;
      PropSchema.AddPair('format', SchemaFormatAttribute(Attr).Format);
    end
    else if Attr is SchemaMinimumAttribute then
      PropSchema.AddPair('minimum', NumberValue(SchemaMinimumAttribute(Attr).Minimum))
    else if Attr is SchemaMaximumAttribute then
      PropSchema.AddPair('maximum', NumberValue(SchemaMaximumAttribute(Attr).Maximum))
    else if Attr is SchemaEnumAttribute then
    begin
      PropSchema.RemovePair('enum').Free;
      var EnumArray := TJSONArray.Create;
      for var Value in SchemaEnumAttribute(Attr).Values do
        EnumArray.Add(Value);
      PropSchema.AddPair('enum', EnumArray);
    end
    else if Attr is SchemaMinLengthAttribute then
      PropSchema.AddPair('minLength', TJSONNumber.Create(SchemaMinLengthAttribute(Attr).MinLength))
    else if Attr is SchemaMaxLengthAttribute then
      PropSchema.AddPair('maxLength', TJSONNumber.Create(SchemaMaxLengthAttribute(Attr).MaxLength))
    else if Attr is SchemaPatternAttribute then
      PropSchema.AddPair('pattern', SchemaPatternAttribute(Attr).Pattern)
    else if Attr is SchemaDefaultAttribute then
    begin
      var DefaultValue := TJSONObject.ParseJSONValue(SchemaDefaultAttribute(Attr).Json);
      if not Assigned(DefaultValue) then
        raise EArgumentException.CreateFmt('[SchemaDefault] on %s is not valid JSON: %s',
          [Prop.Name, SchemaDefaultAttribute(Attr).Json]);
      PropSchema.AddPair('default', DefaultValue);
    end;
  end;
end;

class function TMCPSchemaGenerator.ObjectSchema(RttiType: TRttiType; Depth: Integer): TJSONObject;
begin
  Result := TJSONObject.Create;
  try
    if Depth = 0 then
      for var Attr in RttiType.GetAttributes do
        if Attr is SchemaDialectAttribute then
          Result.AddPair('$schema', SchemaDialectAttribute(Attr).Uri);

    Result.AddPair('type', 'object');
    var Properties := TJSONObject.Create;
    Result.AddPair('properties', Properties);
    var RequiredArray := TJSONArray.Create;

    for var RttiProp in RttiType.GetProperties do
    begin
      if not (RttiProp.IsReadable and RttiProp.IsWritable) then
        Continue;

      var JsonName := GetPropertyJsonName(RttiProp);
      var PropSchema := TypeSchema(RttiProp.PropertyType, Depth);
      Properties.AddPair(JsonName, PropSchema);
      ApplyAttributes(RttiProp, PropSchema);

      if IsRequiredProperty(RttiProp) then
        RequiredArray.Add(JsonName);
    end;

    if RequiredArray.Count > 0 then
      Result.AddPair('required', RequiredArray)
    else
      RequiredArray.Free;

    var ExplicitAdditionalProperties := False;
    for var Attr in RttiType.GetAttributes do
      if Attr is SchemaAdditionalPropertiesAttribute then
      begin
        Result.AddPair('additionalProperties', TJSONBool.Create(SchemaAdditionalPropertiesAttribute(Attr).Allowed));
        ExplicitAdditionalProperties := True;
      end;

    if not ExplicitAdditionalProperties and (Properties.Count = 0) then
      Result.AddPair('additionalProperties', TJSONBool.Create(False));
  except
    Result.Free;
    raise;
  end;
end;

initialization
  RttiContext := TRttiContext.Create;

finalization
  RttiContext.Free;

end.
