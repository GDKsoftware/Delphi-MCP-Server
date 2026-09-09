unit MCPServer.Schema.Validator;

interface

uses
  System.SysUtils,
  System.Classes,
  System.JSON;

type
  TMCPSchemaValidator = class
  public
    const MAX_DEPTH = 32;

    class function TryValidate(const Schema: TJSONObject; const Instance: TJSONValue;
      out Errors: TArray<string>): Boolean;
  private
    class function ValidateNode(const Schema: TJSONObject; const Instance: TJSONValue;
      const Path: string; Depth: Integer; const RootSchema: TJSONObject; Errors: TStrings): Boolean;
    class function TryResolveRef(const RootSchema: TJSONObject; const Ref: string;
      out Resolved: TJSONObject): Boolean;
    class function MatchesType(const Instance: TJSONValue; const TypeName: string): Boolean;
    class function ValidateConstAndEnum(const Schema: TJSONObject; const Instance: TJSONValue;
      const Path: string; Errors: TStrings): Boolean;
    class function ValidateString(const Schema: TJSONObject; const Text: string;
      const Path: string; Errors: TStrings): Boolean;
    class function ValidateNumber(const Schema: TJSONObject; const Value: Double;
      const Path: string; Errors: TStrings): Boolean;
    class function ValidateObject(const Schema: TJSONObject; const Instance: TJSONObject;
      const Path: string; Depth: Integer; const RootSchema: TJSONObject; Errors: TStrings): Boolean;
    class function ValidateArray(const Schema: TJSONObject; const Instance: TJSONArray;
      const Path: string; Depth: Integer; const RootSchema: TJSONObject; Errors: TStrings): Boolean;
    class function TryCheckType(const Schema: TJSONObject; const Instance: TJSONValue;
      out ErrorMessage: string): Boolean;
    class function JsonEquals(A, B: TJSONValue): Boolean;
    class procedure AddError(Errors: TStrings; const Path, Message: string);
  end;

implementation

uses
  System.Generics.Collections,
  System.RegularExpressions,
  System.RegularExpressionsCore,
  MCPServer.Types;

const
  SCHEMA_KEY_REQUIRED = 'required';
  SCHEMA_KEY_PROPERTIES = 'properties';
  SCHEMA_KEY_ITEMS = 'items';
  SCHEMA_KEY_ADDITIONAL_PROPERTIES = 'additionalProperties';


{ TMCPSchemaValidator }

class procedure TMCPSchemaValidator.AddError(Errors: TStrings; const Path, Message: string);
begin
  if Path = '' then
    Errors.Add(Message)
  else
    Errors.Add(Path + ': ' + Message);
end;

class function TMCPSchemaValidator.MatchesType(const Instance: TJSONValue; const TypeName: string): Boolean;
begin
  if TypeName = 'null' then
    Result := not Assigned(Instance) or (Instance is TJSONNull)
  else if TypeName = 'boolean' then
    Result := Instance is TJSONBool
  else if TypeName = 'integer' then
    Result := (Instance is TJSONNumber) and (Frac(TJSONNumber(Instance).AsDouble) = 0)
  else if TypeName = 'number' then
    Result := Instance is TJSONNumber
  else if TypeName = 'string' then
    Result := (Instance is TJSONString) and not (Instance is TJSONNumber)
  else if TypeName = 'object' then
    Result := Instance is TJSONObject
  else if TypeName = 'array' then
    Result := Instance is TJSONArray
  else
    Result := False;
end;

class function TMCPSchemaValidator.TryCheckType(const Schema: TJSONObject; const Instance: TJSONValue;
  out ErrorMessage: string): Boolean;
begin
  Result := True;
  ErrorMessage := '';
  var TypeValue := Schema.GetValue(MCP_KEY_TYPE);
  if not Assigned(TypeValue) then
    Exit;

  if (TypeValue is TJSONString) and not (TypeValue is TJSONNumber) then
  begin
    Result := MatchesType(Instance, TJSONString(TypeValue).Value);
    if not Result then
      ErrorMessage := 'expected ' + TJSONString(TypeValue).Value;
    Exit;
  end;

  if TypeValue is TJSONArray then
  begin
    var Names := TStringList.Create;
    try
      for var Item in TJSONArray(TypeValue) do
        if (Item is TJSONString) and not (Item is TJSONNumber) then
        begin
          Names.Add(TJSONString(Item).Value);
          if MatchesType(Instance, TJSONString(Item).Value) then
            Exit(True);
        end;
      Result := False;
      ErrorMessage := 'expected one of: ' + Names.CommaText;
    finally
      Names.Free;
    end;
  end;
end;

class function TMCPSchemaValidator.JsonEquals(A, B: TJSONValue): Boolean;
begin
  if not Assigned(A) or not Assigned(B) then
    begin
      Result := not Assigned(A) and not Assigned(B);
      Exit;
    end;
  if (A is TJSONNull) or (B is TJSONNull) then
    begin
      Result := (A is TJSONNull) and (B is TJSONNull);
      Exit;
    end;
  if (A is TJSONBool) or (B is TJSONBool) then
    begin
      Result := (A is TJSONBool) and (B is TJSONBool) and (TJSONBool(A).AsBoolean = TJSONBool(B).AsBoolean);
      Exit;
    end;
  if (A is TJSONNumber) or (B is TJSONNumber) then
    begin
      Result := (A is TJSONNumber) and (B is TJSONNumber) and (TJSONNumber(A).AsDouble = TJSONNumber(B).AsDouble);
      Exit;
    end;
  if (A is TJSONString) or (B is TJSONString) then
    begin
      Result := (A is TJSONString) and (B is TJSONString) and (TJSONString(A).Value = TJSONString(B).Value);
      Exit;
    end;
  Result := A.ToJSON = B.ToJSON;
end;

class function TMCPSchemaValidator.TryResolveRef(const RootSchema: TJSONObject; const Ref: string;
  out Resolved: TJSONObject): Boolean;
const
  DEFS_PREFIX = '#/$defs/';
  DEFINITIONS_PREFIX = '#/definitions/';
begin
  Resolved := nil;

  var DefsValue: TJSONValue;
  var Name := '';
  if Ref.StartsWith(DEFS_PREFIX) then
  begin
    Name := Copy(Ref, Length(DEFS_PREFIX) + 1, MaxInt);
    DefsValue := RootSchema.GetValue('$defs');
  end
  else if Ref.StartsWith(DEFINITIONS_PREFIX) then
  begin
    Name := Copy(Ref, Length(DEFINITIONS_PREFIX) + 1, MaxInt);
    DefsValue := RootSchema.GetValue('definitions');
  end
  else
    Exit(False);

  if not (DefsValue is TJSONObject) then
    Exit(False);
  var Entry := TJSONObject(DefsValue).GetValue(Name);
  if not (Entry is TJSONObject) then
    Exit(False);

  Resolved := TJSONObject(Entry);
  Result := True;
end;

class function TMCPSchemaValidator.ValidateConstAndEnum(const Schema: TJSONObject; const Instance: TJSONValue;
  const Path: string; Errors: TStrings): Boolean;
begin
  Result := True;
  const ConstValue = Schema.GetValue('const');
  const MatchesConst = (not Assigned(ConstValue) or JsonEquals(ConstValue, Instance));
  if not MatchesConst then
  begin
    AddError(Errors, Path, 'does not match const');
    Result := False;
  end;

  const EnumValue = Schema.GetValue('enum');
  if not (EnumValue is TJSONArray) then
    Exit;

  var Found := False;
  for var Item in TJSONArray(EnumValue) do
  begin
    if JsonEquals(Item, Instance) then
    begin
      Found := True;
      Break;
    end;
  end;
  if not Found then
  begin
    AddError(Errors, Path, 'not one of the allowed values');
    Result := False;
  end;
end;

class function TMCPSchemaValidator.ValidateString(const Schema: TJSONObject; const Text: string;
  const Path: string; Errors: TStrings): Boolean;
begin
  Result := True;
  const MinLengthValue = Schema.GetValue('minLength');
  const IsTooShort = ((MinLengthValue is TJSONNumber) and (Length(Text) < TJSONNumber(MinLengthValue).AsInt));
  if IsTooShort then
  begin
    AddError(Errors, Path, 'shorter than minLength');
    Result := False;
  end;

  const MaxLengthValue = Schema.GetValue('maxLength');
  const IsTooLong = ((MaxLengthValue is TJSONNumber) and (Length(Text) > TJSONNumber(MaxLengthValue).AsInt));
  if IsTooLong then
  begin
    AddError(Errors, Path, 'longer than maxLength');
    Result := False;
  end;

  const PatternValue = Schema.GetValue('pattern');
  if not IsJsonString(PatternValue) then
    Exit;

  var Matches: Boolean;
  try
    Matches := TRegEx.IsMatch(Text, TJSONString(PatternValue).Value);
  except
    on E: ERegularExpressionError do
    begin
      AddError(Errors, Path, 'has an unusable pattern');
      Exit(False);
    end;
  end;
  if not Matches then
  begin
    AddError(Errors, Path, 'does not match pattern');
    Result := False;
  end;
end;

class function TMCPSchemaValidator.ValidateNumber(const Schema: TJSONObject; const Value: Double;
  const Path: string; Errors: TStrings): Boolean;
begin
  Result := True;
  const MinimumValue = Schema.GetValue('minimum');
  const IsBelowMinimum = ((MinimumValue is TJSONNumber) and (Value < TJSONNumber(MinimumValue).AsDouble));
  if IsBelowMinimum then
  begin
    AddError(Errors, Path, 'less than minimum');
    Result := False;
  end;

  const MaximumValue = Schema.GetValue('maximum');
  const IsAboveMaximum = ((MaximumValue is TJSONNumber) and (Value > TJSONNumber(MaximumValue).AsDouble));
  if IsAboveMaximum then
  begin
    AddError(Errors, Path, 'greater than maximum');
    Result := False;
  end;
end;

class function TMCPSchemaValidator.ValidateObject(const Schema: TJSONObject; const Instance: TJSONObject;
  const Path: string; Depth: Integer; const RootSchema: TJSONObject; Errors: TStrings): Boolean;
begin
  Result := True;
  const RequiredValue = Schema.GetValue(SCHEMA_KEY_REQUIRED);
  if RequiredValue is TJSONArray then
  begin
    for var Item in TJSONArray(RequiredValue) do
    begin
      const IsMissing = (IsJsonString(Item) and not Assigned(Instance.GetValue(TJSONString(Item).Value)));
      if IsMissing then
      begin
        AddError(Errors, Path, Format('missing required property "%s"', [TJSONString(Item).Value]));
        Result := False;
      end;
    end;
  end;

  var PropertySchemas: TJSONObject := nil;
  const PropertiesValue = Schema.GetValue(SCHEMA_KEY_PROPERTIES);
  if PropertiesValue is TJSONObject then
    PropertySchemas := TJSONObject(PropertiesValue);

  if Assigned(PropertySchemas) then
  begin
    for var Pair in Instance do
    begin
      const PropertySchema = PropertySchemas.GetValue(Pair.JsonString.Value);
      if not (PropertySchema is TJSONObject) then
        Continue;
      const MemberPath = Format('%s.%s', [Path, Pair.JsonString.Value]);
      if not ValidateNode(TJSONObject(PropertySchema), Pair.JsonValue, MemberPath, Depth + 1, RootSchema, Errors) then
        Result := False;
    end;
  end;

  const AdditionalValue = Schema.GetValue(SCHEMA_KEY_ADDITIONAL_PROPERTIES);
  const ForbidsExtras = ((AdditionalValue is TJSONBool) and not TJSONBool(AdditionalValue).AsBoolean);
  if not ForbidsExtras then
    Exit;

  for var Pair in Instance do
  begin
    const IsKnown = (Assigned(PropertySchemas) and Assigned(PropertySchemas.GetValue(Pair.JsonString.Value)));
    if not IsKnown then
    begin
      AddError(Errors, Path, Format('unexpected property "%s"', [Pair.JsonString.Value]));
      Result := False;
    end;
  end;
end;

class function TMCPSchemaValidator.ValidateArray(const Schema: TJSONObject; const Instance: TJSONArray;
  const Path: string; Depth: Integer; const RootSchema: TJSONObject; Errors: TStrings): Boolean;
begin
  Result := True;
  const ItemsValue = Schema.GetValue(SCHEMA_KEY_ITEMS);
  if not (ItemsValue is TJSONObject) then
    Exit;

  for var Index := 0 to Instance.Count - 1 do
  begin
    const ItemPath = Format('%s[%d]', [Path, Index]);
    if not ValidateNode(TJSONObject(ItemsValue), Instance.Items[Index], ItemPath, Depth + 1, RootSchema, Errors) then
      Result := False;
  end;
end;

class function TMCPSchemaValidator.ValidateNode(const Schema: TJSONObject; const Instance: TJSONValue;
  const Path: string; Depth: Integer; const RootSchema: TJSONObject; Errors: TStrings): Boolean;
begin
  if Depth > MAX_DEPTH then
  begin
    AddError(Errors, Path, 'schema nested too deeply');
    Exit(False);
  end;

  var ResolvedSchema := Schema;
  const RefValue = Schema.GetValue('$ref');
  if IsJsonString(RefValue) then
  begin
    if not TryResolveRef(RootSchema, TJSONString(RefValue).Value, ResolvedSchema) then
    begin
      AddError(Errors, Path, Format('unsupported $ref "%s"', [TJSONString(RefValue).Value]));
      Exit(False);
    end;
  end;

  Result := ValidateConstAndEnum(ResolvedSchema, Instance, Path, Errors);

  var TypeError: string;
  if not TryCheckType(ResolvedSchema, Instance, TypeError) then
  begin
    AddError(Errors, Path, TypeError);
    Exit(False);
  end;

  if IsJsonString(Instance) then
  begin
    if not ValidateString(ResolvedSchema, TJSONString(Instance).Value, Path, Errors) then
      Result := False;
  end
  else if Instance is TJSONNumber then
  begin
    if not ValidateNumber(ResolvedSchema, TJSONNumber(Instance).AsDouble, Path, Errors) then
      Result := False;
  end
  else if Instance is TJSONObject then
  begin
    if not ValidateObject(ResolvedSchema, TJSONObject(Instance), Path, Depth, RootSchema, Errors) then
      Result := False;
  end
  else if Instance is TJSONArray then
  begin
    if not ValidateArray(ResolvedSchema, TJSONArray(Instance), Path, Depth, RootSchema, Errors) then
      Result := False;
  end;
end;

class function TMCPSchemaValidator.TryValidate(const Schema: TJSONObject; const Instance: TJSONValue;
  out Errors: TArray<string>): Boolean;
begin
  var ErrorList := TStringList.Create;
  try
    Result := ValidateNode(Schema, Instance, 'value', 0, Schema, ErrorList);
    Errors := ErrorList.ToStringArray;
  finally
    ErrorList.Free;
  end;
end;

end.
