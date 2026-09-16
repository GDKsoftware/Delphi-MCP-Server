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
    class var FContext: TRttiContext;
    class function GetJsonName(const Member: TRttiNamedObject): string;
    class function IsRequired(const Member: TRttiNamedObject): Boolean;
    class function IsGuid(const RttiType: TRttiType): Boolean;
    class function IsSchemaField(const RttiField: TRttiField): Boolean;
    class function HasSchemaFields(const RttiType: TRttiType): Boolean;
    class function IsOpaqueRecord(const RttiType: TRttiType): Boolean;
    class function CreateEnumValuesArray(RttiType: TRttiType): TJSONArray;
    class function ListItemType(RttiType: TRttiType): TRttiType;
    class function TypeSchema(RttiType: TRttiType; Depth: Integer): TJSONObject;
    class function SimpleSchema(const JsonType: string): TJSONObject;
    class function GuidSchema: TJSONObject;
    class function ItemsSchema(const Site: string; const ElementType: TRttiType; Depth: Integer): TJSONObject;
    class procedure DescribeFloat(RttiType: TRttiType; const Schema: TJSONObject);
    class procedure DescribeSet(RttiType: TRttiType; const Schema: TJSONObject);
    class function ClassSchema(RttiType: TRttiType; Depth: Integer): TJSONObject;
    class function RecordSchema(RttiType: TRttiType; Depth: Integer): TJSONObject;
    class function ObjectSchema(RttiType: TRttiType; Depth: Integer; const IsRoot: Boolean): TJSONObject;
    class procedure DescribeProperties(RttiType: TRttiType; Depth: Integer;
                                       const Properties: TJSONObject; const RequiredArray: TJSONArray);
    class procedure DescribeFields(RttiType: TRttiType; Depth: Integer;
                                   const Properties: TJSONObject; const RequiredArray: TJSONArray);
    class function NumberValue(const Value: Double): TJSONNumber;
    class procedure ApplyAttributes(const Member: TRttiNamedObject; const MemberSchema: TJSONObject);
    class procedure GuardMemberHasType(const Site: string; const RttiType: TRttiType);
    class procedure GuardParameterHasSchema(const Method: TRttiMethod; const Param: TRttiParameter);
    class procedure GuardParameterRecordHasFields(const Method: TRttiMethod; const Param: TRttiParameter);
  public
    class constructor Create;
    class destructor Destroy;
    class function GenerateSchema(Cls: TClass): TJSONObject;
    class function GenerateSchemaFromInstance(Instance: TObject): TJSONObject;
    class function GenerateSchemaFromType(const RttiType: TRttiType): TJSONObject;
    class function GenerateSchemaFromMethod(const Method: TRttiMethod): TJSONObject;
    class function GenerateSchemaFromMethodResult(const Method: TRttiMethod): TJSONObject;
  end;

implementation

uses
  System.Generics.Collections,
  MCPServer.Types;

const
  SCHEMA_KEY_ADDITIONAL_PROPERTIES = 'additionalProperties';
  SCHEMA_TYPE_STRING = 'string';
  SCHEMA_TYPE_ARRAY = 'array';
  SCHEMA_TYPE_OBJECT = 'object';
  SCHEMA_TYPE_INTEGER = 'integer';
  SCHEMA_TYPE_NUMBER = 'number';
  SCHEMA_TYPE_BOOLEAN = 'boolean';
  SCHEMA_KEY_FORMAT = 'format';
  SCHEMA_KEY_ENUM = 'enum';
  SCHEMA_KEY_ITEMS = 'items';
  SCHEMA_KEY_PROPERTIES = 'properties';
  SCHEMA_KEY_REQUIRED = 'required';
  SCHEMA_KEY_RESULT = 'result';
  SCHEMA_FORMAT_UUID = 'uuid';

  DEPTH_ABOVE_ROOT = -1;

  UNDESCRIBABLE_KINDS = [tkUnknown, tkPointer, tkProcedure, tkMethod, tkClassRef,
    tkInterface, tkVariant];

  RECORD_KINDS = [tkRecord, tkMRecord];


{ TMCPSchemaGenerator }

class constructor TMCPSchemaGenerator.Create;
begin
  FContext := TRttiContext.Create;
end;

class destructor TMCPSchemaGenerator.Destroy;
begin
  FContext.Free;
end;

class function TMCPSchemaGenerator.GenerateSchema(Cls: TClass): TJSONObject;
begin
  Result := ObjectSchema(FContext.GetType(Cls), 0, True);
end;

class function TMCPSchemaGenerator.GenerateSchemaFromInstance(Instance: TObject): TJSONObject;
begin
  Result := GenerateSchema(Instance.ClassType);
end;

class function TMCPSchemaGenerator.GenerateSchemaFromType(const RttiType: TRttiType): TJSONObject;
begin
  if not Assigned(RttiType) then
    Exit(nil);

  const DescribesItsOwnMembers = (RttiType.TypeKind = tkClass) or (RttiType.TypeKind in RECORD_KINDS);
  if DescribesItsOwnMembers then
    Exit(TypeSchema(RttiType, DEPTH_ABOVE_ROOT));

  Result := TypeSchema(RttiType, 0);
end;

class function TMCPSchemaGenerator.GenerateSchemaFromMethod(const Method: TRttiMethod): TJSONObject;
begin
  Result := TJSONObject.Create;
  try
    Result.AddPair(MCP_KEY_TYPE, SCHEMA_TYPE_OBJECT);

    const Properties = TJSONObject.Create;
    Result.AddPair(SCHEMA_KEY_PROPERTIES, Properties);

    const RequiredArray = TJSONArray.Create;
    try
      for var Param in Method.GetParameters do
      begin
        GuardParameterHasSchema(Method, Param);

        const WireName = GetJsonName(Param);
        const ParamSchema = GenerateSchemaFromType(Param.ParamType);
        Properties.AddPair(WireName, ParamSchema);
        ApplyAttributes(Param, ParamSchema);

        if IsRequired(Param) then
          RequiredArray.Add(WireName);
      end;
    except
      RequiredArray.Free;
      raise;
    end;

    const HasRequiredArray = (RequiredArray.Count > 0);
    if HasRequiredArray then
      Result.AddPair(SCHEMA_KEY_REQUIRED, RequiredArray)
    else
      RequiredArray.Free;

    Result.AddPair(SCHEMA_KEY_ADDITIONAL_PROPERTIES, TJSONBool.Create(False));
  except
    Result.Free;
    raise;
  end;
end;

class function TMCPSchemaGenerator.GenerateSchemaFromMethodResult(const Method: TRttiMethod): TJSONObject;
begin
  const ReturnType = Method.ReturnType;
  if not Assigned(ReturnType) or (ReturnType.TypeKind in UNDESCRIBABLE_KINDS) then
    Exit(nil);

  if IsOpaqueRecord(ReturnType) then
    Exit(nil);

  Result := TJSONObject.Create;
  try
    Result.AddPair(MCP_KEY_TYPE, SCHEMA_TYPE_OBJECT);

    const Properties = TJSONObject.Create;
    Result.AddPair(SCHEMA_KEY_PROPERTIES, Properties);
    Properties.AddPair(SCHEMA_KEY_RESULT, GenerateSchemaFromType(ReturnType));

    const RequiredArray = TJSONArray.Create;
    Result.AddPair(SCHEMA_KEY_REQUIRED, RequiredArray);
    RequiredArray.Add(SCHEMA_KEY_RESULT);

    Result.AddPair(SCHEMA_KEY_ADDITIONAL_PROPERTIES, TJSONBool.Create(False));
  except
    Result.Free;
    raise;
  end;
end;

class procedure TMCPSchemaGenerator.GuardParameterHasSchema(const Method: TRttiMethod;
  const Param: TRttiParameter);
begin
  if not Assigned(Param.ParamType) then
    raise EArgumentException.CreateFmt('Parameter "%s" of %s is untyped, so it has no schema',
      [Param.Name, Method.Name]);

  const AnswersThroughTheArgument = (([pfVar, pfOut] * Param.Flags) <> []);
  if AnswersThroughTheArgument then
    raise EArgumentException.CreateFmt(
      'Parameter "%s" of %s is a var or out parameter, so it has no schema: a tool answers with its result',
      [Param.Name, Method.Name]);

  const HasNoJsonShape = (Param.ParamType.TypeKind in UNDESCRIBABLE_KINDS);
  if HasNoJsonShape then
    raise EArgumentException.CreateFmt(
      'Parameter "%s" of %s is of type %s, which has no JSON schema',
      [Param.Name, Method.Name, Param.ParamType.Name]);

  GuardParameterRecordHasFields(Method, Param);
end;

class procedure TMCPSchemaGenerator.GuardParameterRecordHasFields(const Method: TRttiMethod;
  const Param: TRttiParameter);
begin
  if not IsOpaqueRecord(Param.ParamType) then
    Exit;

  raise EArgumentException.CreateFmt(
    'Parameter "%s" of %s is record %s, which publishes no field RTTI, so it has no schema. ' +
    'Declare it in a unit whose field RTTI covers its public fields, for example ' +
    '{$RTTI EXPLICIT FIELDS([vcPublic])}.',
    [Param.Name, Method.Name, Param.ParamType.Name]);
end;

class procedure TMCPSchemaGenerator.GuardMemberHasType(const Site: string; const RttiType: TRttiType);
begin
  if not Assigned(RttiType) then
    raise EArgumentException.CreateFmt('%s has no type RTTI, so it has no schema', [Site]);
end;

class function TMCPSchemaGenerator.GetJsonName(const Member: TRttiNamedObject): string;
begin
  for var Attr in Member.GetAttributes do
    if Attr is SchemaNameAttribute then
      begin
        Result := SchemaNameAttribute(Attr).Name;
        Exit;
      end;
  Result := LowerCase(Member.Name);
end;

class function TMCPSchemaGenerator.IsRequired(const Member: TRttiNamedObject): Boolean;
begin
  for var Attr in Member.GetAttributes do
    if Attr is OptionalAttribute then
      Exit(False);
  Result := True;
end;

class function TMCPSchemaGenerator.IsGuid(const RttiType: TRttiType): Boolean;
begin
  Result := (RttiType.Handle = TypeInfo(TGUID));
end;

class function TMCPSchemaGenerator.IsSchemaField(const RttiField: TRttiField): Boolean;
begin
  Result := (RttiField.Visibility in SCHEMA_FIELD_VISIBILITIES);
end;

class function TMCPSchemaGenerator.HasSchemaFields(const RttiType: TRttiType): Boolean;
begin
  for var RttiField in RttiType.GetFields do
    if IsSchemaField(RttiField) then
      Exit(True);
  Result := False;
end;

class function TMCPSchemaGenerator.IsOpaqueRecord(const RttiType: TRttiType): Boolean;
begin
  Result := ((RttiType.TypeKind in RECORD_KINDS) and not IsGuid(RttiType) and
             not HasSchemaFields(RttiType));
end;

class function TMCPSchemaGenerator.CreateEnumValuesArray(RttiType: TRttiType): TJSONArray;
begin
  Result := nil;
  if not (RttiType is TRttiEnumerationType) or (RttiType.Handle = TypeInfo(Boolean)) then
    Exit;

  var EnumType := TRttiEnumerationType(RttiType);
  Result := TJSONArray.Create;
  for var Ordinal := EnumType.MinValue to EnumType.MaxValue do
  begin
    Result.Add(GetEnumName(RttiType.Handle, Ordinal));
  end;
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

class procedure TMCPSchemaGenerator.DescribeFloat(RttiType: TRttiType; const Schema: TJSONObject);
begin
  if RttiType.Handle = TypeInfo(TDateTime) then
  begin
    Schema.AddPair(MCP_KEY_TYPE, SCHEMA_TYPE_STRING);
    Schema.AddPair(SCHEMA_KEY_FORMAT, 'date-time');
  end
  else if RttiType.Handle = TypeInfo(TDate) then
  begin
    Schema.AddPair(MCP_KEY_TYPE, SCHEMA_TYPE_STRING);
    Schema.AddPair(SCHEMA_KEY_FORMAT, 'date');
  end
  else if RttiType.Handle = TypeInfo(TTime) then
  begin
    Schema.AddPair(MCP_KEY_TYPE, SCHEMA_TYPE_STRING);
    Schema.AddPair(SCHEMA_KEY_FORMAT, 'time');
  end
  else
  begin
    Schema.AddPair(MCP_KEY_TYPE, SCHEMA_TYPE_NUMBER);
  end;
end;

class procedure TMCPSchemaGenerator.DescribeSet(RttiType: TRttiType; const Schema: TJSONObject);
begin
  Schema.AddPair(MCP_KEY_TYPE, SCHEMA_TYPE_ARRAY);

  const Items = TJSONObject.Create;
  Schema.AddPair(SCHEMA_KEY_ITEMS, Items);
  Items.AddPair(MCP_KEY_TYPE, SCHEMA_TYPE_STRING);

  const ElementType = TRttiSetType(RttiType).ElementType;
  const Names = CreateEnumValuesArray(ElementType);
  if Assigned(Names) then
    Items.AddPair(SCHEMA_KEY_ENUM, Names);
end;

class function TMCPSchemaGenerator.SimpleSchema(const JsonType: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair(MCP_KEY_TYPE, JsonType);
end;

class function TMCPSchemaGenerator.GuidSchema: TJSONObject;
begin
  Result := SimpleSchema(SCHEMA_TYPE_STRING);
  Result.AddPair(SCHEMA_KEY_FORMAT, SCHEMA_FORMAT_UUID);
end;

class function TMCPSchemaGenerator.ItemsSchema(const Site: string; const ElementType: TRttiType;
  Depth: Integer): TJSONObject;
begin
  GuardMemberHasType(Site, ElementType);

  Result := TypeSchema(ElementType, Depth + 1);
end;

class function TMCPSchemaGenerator.ClassSchema(RttiType: TRttiType; Depth: Integer): TJSONObject;
begin
  const Metaclass = TRttiInstanceType(RttiType).MetaclassType;
  if Metaclass.InheritsFrom(TJSONArray) then
    Exit(SimpleSchema(SCHEMA_TYPE_ARRAY));
  if Metaclass.InheritsFrom(TJSONValue) then
    Exit(SimpleSchema(SCHEMA_TYPE_OBJECT));

  const ItemType = ListItemType(RttiType);
  if Assigned(ItemType) then
  begin
    Result := SimpleSchema(SCHEMA_TYPE_ARRAY);
    try
      Result.AddPair(SCHEMA_KEY_ITEMS, TypeSchema(ItemType, Depth + 1));
    except
      Result.Free;
      raise;
    end;
    Exit;
  end;

  const FitsAnotherLevel = (Depth < MAX_NESTING_DEPTH);
  if not FitsAnotherLevel then
    Exit(SimpleSchema(SCHEMA_TYPE_OBJECT));

  Result := ObjectSchema(RttiType, Depth + 1, False);
end;

class function TMCPSchemaGenerator.RecordSchema(RttiType: TRttiType; Depth: Integer): TJSONObject;
begin
  if IsGuid(RttiType) then
    Exit(GuidSchema);

  if not HasSchemaFields(RttiType) then
    Exit(SimpleSchema(SCHEMA_TYPE_STRING));

  const FitsAnotherLevel = (Depth < MAX_NESTING_DEPTH);
  if not FitsAnotherLevel then
    Exit(SimpleSchema(SCHEMA_TYPE_OBJECT));

  Result := ObjectSchema(RttiType, Depth + 1, False);
end;

class function TMCPSchemaGenerator.TypeSchema(RttiType: TRttiType; Depth: Integer): TJSONObject;
begin
  if RttiType.TypeKind = tkClass then
    Exit(ClassSchema(RttiType, Depth));

  if RttiType.TypeKind in RECORD_KINDS then
    Exit(RecordSchema(RttiType, Depth));

  Result := TJSONObject.Create;
  try
    case RttiType.TypeKind of
      tkInteger, tkInt64:
        Result.AddPair(MCP_KEY_TYPE, SCHEMA_TYPE_INTEGER);

      tkFloat:
        DescribeFloat(RttiType, Result);

      tkString, tkLString, tkWString, tkUString, tkChar, tkWChar:
        Result.AddPair(MCP_KEY_TYPE, SCHEMA_TYPE_STRING);

      tkEnumeration:
        if RttiType.Handle = TypeInfo(Boolean) then
          Result.AddPair(MCP_KEY_TYPE, SCHEMA_TYPE_BOOLEAN)
        else
        begin
          Result.AddPair(MCP_KEY_TYPE, SCHEMA_TYPE_STRING);
          Result.AddPair(SCHEMA_KEY_ENUM, CreateEnumValuesArray(RttiType));
        end;

      tkSet:
        DescribeSet(RttiType, Result);

      tkDynArray:
        begin
          Result.AddPair(MCP_KEY_TYPE, SCHEMA_TYPE_ARRAY);
          const ElementType = TRttiDynamicArrayType(RttiType).ElementType;
          const ElementSite = Format('Element of %s', [RttiType.Name]);
          Result.AddPair(SCHEMA_KEY_ITEMS, ItemsSchema(ElementSite, ElementType, Depth));
        end;

      tkArray:
        begin
          Result.AddPair(MCP_KEY_TYPE, SCHEMA_TYPE_ARRAY);
          const ElementType = TRttiArrayType(RttiType).ElementType;
          const ElementSite = Format('Element of %s', [RttiType.Name]);
          Result.AddPair(SCHEMA_KEY_ITEMS, ItemsSchema(ElementSite, ElementType, Depth));
        end;
    else
      Result.AddPair(MCP_KEY_TYPE, SCHEMA_TYPE_STRING);
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

class procedure TMCPSchemaGenerator.ApplyAttributes(const Member: TRttiNamedObject;
  const MemberSchema: TJSONObject);
begin
  for var Attr in Member.GetAttributes do
  begin
    if Attr is SchemaDescriptionAttribute then
      MemberSchema.AddPair(MCP_KEY_DESCRIPTION, SchemaDescriptionAttribute(Attr).Description)
    else if Attr is SchemaTitleAttribute then
      MemberSchema.AddPair(MCP_KEY_TITLE, SchemaTitleAttribute(Attr).Title)
    else if Attr is SchemaFormatAttribute then
    begin
      MemberSchema.RemovePair(SCHEMA_KEY_FORMAT).Free;
      MemberSchema.AddPair(SCHEMA_KEY_FORMAT, SchemaFormatAttribute(Attr).Format);
    end
    else if Attr is SchemaMinimumAttribute then
      MemberSchema.AddPair('minimum', NumberValue(SchemaMinimumAttribute(Attr).Minimum))
    else if Attr is SchemaMaximumAttribute then
      MemberSchema.AddPair('maximum', NumberValue(SchemaMaximumAttribute(Attr).Maximum))
    else if Attr is SchemaEnumAttribute then
    begin
      MemberSchema.RemovePair(SCHEMA_KEY_ENUM).Free;
      var EnumArray := TJSONArray.Create;
      for var Value in SchemaEnumAttribute(Attr).Values do
      begin
        EnumArray.Add(Value);
      end;
      MemberSchema.AddPair(SCHEMA_KEY_ENUM, EnumArray);
    end
    else if Attr is SchemaMinLengthAttribute then
      MemberSchema.AddPair('minLength', TJSONNumber.Create(SchemaMinLengthAttribute(Attr).MinLength))
    else if Attr is SchemaMaxLengthAttribute then
      MemberSchema.AddPair('maxLength', TJSONNumber.Create(SchemaMaxLengthAttribute(Attr).MaxLength))
    else if Attr is SchemaPatternAttribute then
      MemberSchema.AddPair('pattern', SchemaPatternAttribute(Attr).Pattern)
    else if Attr is SchemaDefaultAttribute then
    begin
      var DefaultValue := TJSONObject.ParseJSONValue(SchemaDefaultAttribute(Attr).Json);
      if not Assigned(DefaultValue) then
        raise EArgumentException.CreateFmt('[SchemaDefault] on %s is not valid JSON: %s',
          [Member.Name, SchemaDefaultAttribute(Attr).Json]);
      MemberSchema.AddPair('default', DefaultValue);
    end;
  end;
end;

class function TMCPSchemaGenerator.ObjectSchema(RttiType: TRttiType; Depth: Integer;
  const IsRoot: Boolean): TJSONObject;
begin
  Result := TJSONObject.Create;
  try
    if IsRoot then
      for var Attr in RttiType.GetAttributes do
        if Attr is SchemaDialectAttribute then
          Result.AddPair('$schema', SchemaDialectAttribute(Attr).Uri);

    Result.AddPair(MCP_KEY_TYPE, SCHEMA_TYPE_OBJECT);
    const Properties = TJSONObject.Create;
    Result.AddPair(SCHEMA_KEY_PROPERTIES, Properties);
    const RequiredArray = TJSONArray.Create;
    try
      const DescribesItsFields = (RttiType.TypeKind in RECORD_KINDS);
      if DescribesItsFields then
        DescribeFields(RttiType, Depth, Properties, RequiredArray)
      else
        DescribeProperties(RttiType, Depth, Properties, RequiredArray);
    except
      RequiredArray.Free;
      raise;
    end;

    const HasRequiredArray = (RequiredArray.Count > 0);
    if HasRequiredArray then
      Result.AddPair(SCHEMA_KEY_REQUIRED, RequiredArray)
    else
      RequiredArray.Free;

    var ExplicitAdditionalProperties := False;
    for var Attr in RttiType.GetAttributes do
      if Attr is SchemaAdditionalPropertiesAttribute then
      begin
        Result.AddPair(SCHEMA_KEY_ADDITIONAL_PROPERTIES, TJSONBool.Create(SchemaAdditionalPropertiesAttribute(Attr).Allowed));
        ExplicitAdditionalProperties := True;
      end;

    if not ExplicitAdditionalProperties and (Properties.Count = 0) then
      Result.AddPair(SCHEMA_KEY_ADDITIONAL_PROPERTIES, TJSONBool.Create(False));
  except
    Result.Free;
    raise;
  end;
end;

class procedure TMCPSchemaGenerator.DescribeProperties(RttiType: TRttiType; Depth: Integer;
  const Properties: TJSONObject; const RequiredArray: TJSONArray);
begin
  for var RttiProp in RttiType.GetProperties do
  begin
    if not (RttiProp.IsReadable and RttiProp.IsWritable) then
      Continue;

    GuardMemberHasType(Format('Property %s.%s', [RttiType.Name, RttiProp.Name]),
      RttiProp.PropertyType);

    const JsonName = GetJsonName(RttiProp);
    const PropSchema = TypeSchema(RttiProp.PropertyType, Depth);
    Properties.AddPair(JsonName, PropSchema);
    ApplyAttributes(RttiProp, PropSchema);

    if IsRequired(RttiProp) then
      RequiredArray.Add(JsonName);
  end;
end;

class procedure TMCPSchemaGenerator.DescribeFields(RttiType: TRttiType; Depth: Integer;
  const Properties: TJSONObject; const RequiredArray: TJSONArray);
begin
  for var RttiField in RttiType.GetFields do
  begin
    if not IsSchemaField(RttiField) then
      Continue;

    GuardMemberHasType(Format('Field %s.%s', [RttiType.Name, RttiField.Name]),
      RttiField.FieldType);

    const JsonName = GetJsonName(RttiField);
    const FieldSchema = TypeSchema(RttiField.FieldType, Depth);
    Properties.AddPair(JsonName, FieldSchema);
    ApplyAttributes(RttiField, FieldSchema);

    if IsRequired(RttiField) then
      RequiredArray.Add(JsonName);
  end;
end;

end.
