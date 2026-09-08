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
    class function CreateEnumValuesArray(RttiType: TRttiType): TJSONArray;
    class function ListItemType(RttiType: TRttiType): TRttiType;
    class function TypeSchema(RttiType: TRttiType; Depth: Integer): TJSONObject;
    class procedure DescribeFloat(RttiType: TRttiType; const Schema: TJSONObject);
    class procedure DescribeSet(RttiType: TRttiType; const Schema: TJSONObject);
    class function ClassSchema(RttiType: TRttiType; Depth: Integer; const Schema: TJSONObject): TJSONObject;
    class function ObjectSchema(RttiType: TRttiType; Depth: Integer; const IsRoot: Boolean): TJSONObject;
    class function NumberValue(const Value: Double): TJSONNumber;
    class procedure ApplyAttributes(const Member: TRttiNamedObject; const MemberSchema: TJSONObject);
    class procedure GuardParameterHasSchema(const Method: TRttiMethod; const Param: TRttiParameter);
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

  DEPTH_ABOVE_ROOT = -1;

  UNDESCRIBABLE_RESULT_KINDS = [tkUnknown, tkPointer, tkProcedure, tkMethod, tkClassRef,
    tkInterface, tkRecord, tkMRecord];


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

  if RttiType.TypeKind = tkClass then
    Exit(ClassSchema(RttiType, DEPTH_ABOVE_ROOT, TJSONObject.Create));

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
  if not Assigned(ReturnType) or (ReturnType.TypeKind in UNDESCRIBABLE_RESULT_KINDS) then
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

class function TMCPSchemaGenerator.ClassSchema(RttiType: TRttiType; Depth: Integer;
  const Schema: TJSONObject): TJSONObject;
begin
  Result := Schema;
  const Metaclass = TRttiInstanceType(RttiType).MetaclassType;
  if Metaclass.InheritsFrom(TJSONArray) then
  begin
    Schema.AddPair(MCP_KEY_TYPE, SCHEMA_TYPE_ARRAY);
    Exit;
  end;
  if Metaclass.InheritsFrom(TJSONValue) then
  begin
    Schema.AddPair(MCP_KEY_TYPE, SCHEMA_TYPE_OBJECT);
    Exit;
  end;

  const ItemType = ListItemType(RttiType);
  if Assigned(ItemType) then
  begin
    Schema.AddPair(MCP_KEY_TYPE, SCHEMA_TYPE_ARRAY);
    Schema.AddPair(SCHEMA_KEY_ITEMS, TypeSchema(ItemType, Depth + 1));
    Exit;
  end;

  const FitsAnotherLevel = (Depth < MAX_NESTING_DEPTH);
  if not FitsAnotherLevel then
  begin
    Schema.AddPair(MCP_KEY_TYPE, SCHEMA_TYPE_OBJECT);
    Exit;
  end;

  Schema.Free;
  Result := ObjectSchema(RttiType, Depth + 1, False);
end;

class function TMCPSchemaGenerator.TypeSchema(RttiType: TRttiType; Depth: Integer): TJSONObject;
begin
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
          Result.AddPair(SCHEMA_KEY_ITEMS, TypeSchema(ElementType, Depth + 1));
        end;

      tkArray:
        begin
          Result.AddPair(MCP_KEY_TYPE, SCHEMA_TYPE_ARRAY);
          const ElementType = TRttiArrayType(RttiType).ElementType;
          Result.AddPair(SCHEMA_KEY_ITEMS, TypeSchema(ElementType, Depth + 1));
        end;

      tkClass:
        Result := ClassSchema(RttiType, Depth, Result);
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
    var Properties := TJSONObject.Create;
    Result.AddPair(SCHEMA_KEY_PROPERTIES, Properties);
    var RequiredArray := TJSONArray.Create;

    for var RttiProp in RttiType.GetProperties do
    begin
      if not (RttiProp.IsReadable and RttiProp.IsWritable) then
        Continue;

      var JsonName := GetJsonName(RttiProp);
      var PropSchema := TypeSchema(RttiProp.PropertyType, Depth);
      Properties.AddPair(JsonName, PropSchema);
      ApplyAttributes(RttiProp, PropSchema);

      if IsRequired(RttiProp) then
        RequiredArray.Add(JsonName);
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

end.
