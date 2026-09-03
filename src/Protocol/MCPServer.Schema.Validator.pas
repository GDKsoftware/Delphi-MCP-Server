unit MCPServer.Schema.Validator;

/// A JSON Schema (2020-12) subset validator for hand-written schemas and for
/// checking a tool's structuredContent against its outputSchema.
///
/// Covers: type (string or array, including "null"), enum, const, required,
/// properties (recursive), additionalProperties (boolean), items
/// (recursive), minimum/maximum, minLength/maxLength, pattern. A same-
/// document "$ref" ("#/$defs/Name" or "#/definitions/Name") is resolved;
/// anything else (a network reference, "#/properties/..." and similar) is a
/// validation error rather than a crash or a silent no-op, since the
/// specification forbids network references. Nesting deeper than
/// MAX_DEPTH is a validation error, not a stack overflow.

interface

uses
  System.SysUtils,
  System.Classes,
  System.JSON;

type
  TMCPSchemaValidator = class
  public
    const MAX_DEPTH = 32;

    /// True when Instance satisfies Schema; Errors lists every violation
    /// found (empty when Result is True).
    class function Validate(const Schema: TJSONObject; const Instance: TJSONValue;
      out Errors: TArray<string>): Boolean;
  private
    class function ValidateNode(const Schema: TJSONObject; const Instance: TJSONValue;
      const Path: string; Depth: Integer; const RootSchema: TJSONObject; Errors: TStrings): Boolean;
    class function ResolveRef(const RootSchema: TJSONObject; const Ref: string;
      out Resolved: TJSONObject): Boolean;
    class function MatchesType(const Instance: TJSONValue; const TypeName: string): Boolean;
    class function CheckType(const Schema: TJSONObject; const Instance: TJSONValue;
      out ErrorMessage: string): Boolean;
    class function JsonEquals(A, B: TJSONValue): Boolean;
    class procedure AddError(Errors: TStrings; const Path, Message: string);
  end;

implementation

uses
  System.Generics.Collections,
  System.RegularExpressions;

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
  // TJSONNumber descends from TJSONString, so "string" must exclude it
  // explicitly and "integer"/"number" must be checked before it.
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

class function TMCPSchemaValidator.CheckType(const Schema: TJSONObject; const Instance: TJSONValue;
  out ErrorMessage: string): Boolean;
begin
  Result := True;
  ErrorMessage := '';
  var TypeValue := Schema.GetValue('type');
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
    Exit(not Assigned(A) and not Assigned(B));
  if (A is TJSONNull) or (B is TJSONNull) then
    Exit((A is TJSONNull) and (B is TJSONNull));
  if (A is TJSONBool) or (B is TJSONBool) then
    Exit((A is TJSONBool) and (B is TJSONBool) and (TJSONBool(A).AsBoolean = TJSONBool(B).AsBoolean));
  if (A is TJSONNumber) or (B is TJSONNumber) then
    Exit((A is TJSONNumber) and (B is TJSONNumber) and (TJSONNumber(A).AsDouble = TJSONNumber(B).AsDouble));
  if (A is TJSONString) or (B is TJSONString) then
    Exit((A is TJSONString) and (B is TJSONString) and (TJSONString(A).Value = TJSONString(B).Value));
  // Objects and arrays: canonical text is good enough for the schemas this
  // server generates or ships with.
  Result := A.ToJSON = B.ToJSON;
end;

class function TMCPSchemaValidator.ResolveRef(const RootSchema: TJSONObject; const Ref: string;
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

class function TMCPSchemaValidator.ValidateNode(const Schema: TJSONObject; const Instance: TJSONValue;
  const Path: string; Depth: Integer; const RootSchema: TJSONObject; Errors: TStrings): Boolean;
begin
  Result := True;
  if Depth > MAX_DEPTH then
  begin
    AddError(Errors, Path, 'schema nested too deeply');
    Exit(False);
  end;

  var ResolvedSchema := Schema;
  var RefValue := Schema.GetValue('$ref');
  if (RefValue is TJSONString) and not (RefValue is TJSONNumber) then
  begin
    if not ResolveRef(RootSchema, TJSONString(RefValue).Value, ResolvedSchema) then
    begin
      AddError(Errors, Path, 'unsupported $ref "' + TJSONString(RefValue).Value + '"');
      Exit(False);
    end;
  end;

  var ConstValue := ResolvedSchema.GetValue('const');
  if Assigned(ConstValue) and not JsonEquals(ConstValue, Instance) then
  begin
    AddError(Errors, Path, 'does not match const');
    Result := False;
  end;

  var EnumValue := ResolvedSchema.GetValue('enum');
  if EnumValue is TJSONArray then
  begin
    var Found := False;
    for var Item in TJSONArray(EnumValue) do
      if JsonEquals(Item, Instance) then
      begin
        Found := True;
        Break;
      end;
    if not Found then
    begin
      AddError(Errors, Path, 'not one of the allowed values');
      Result := False;
    end;
  end;

  var TypeError: string;
  if not CheckType(ResolvedSchema, Instance, TypeError) then
  begin
    AddError(Errors, Path, TypeError);
    // The wrong JSON kind makes structural checks below meaningless.
    Exit(False);
  end;

  if (Instance is TJSONString) and not (Instance is TJSONNumber) then
  begin
    var Text := TJSONString(Instance).Value;
    var MinLengthValue := ResolvedSchema.GetValue('minLength');
    if (MinLengthValue is TJSONNumber) and (Length(Text) < TJSONNumber(MinLengthValue).AsInt) then
    begin
      AddError(Errors, Path, 'shorter than minLength');
      Result := False;
    end;
    var MaxLengthValue := ResolvedSchema.GetValue('maxLength');
    if (MaxLengthValue is TJSONNumber) and (Length(Text) > TJSONNumber(MaxLengthValue).AsInt) then
    begin
      AddError(Errors, Path, 'longer than maxLength');
      Result := False;
    end;
    var PatternValue := ResolvedSchema.GetValue('pattern');
    if (PatternValue is TJSONString) and not (PatternValue is TJSONNumber)
      and not TRegEx.IsMatch(Text, TJSONString(PatternValue).Value) then
    begin
      AddError(Errors, Path, 'does not match pattern');
      Result := False;
    end;
  end;

  if Instance is TJSONNumber then
  begin
    var NumberValue := TJSONNumber(Instance).AsDouble;
    var MinimumValue := ResolvedSchema.GetValue('minimum');
    if (MinimumValue is TJSONNumber) and (NumberValue < TJSONNumber(MinimumValue).AsDouble) then
    begin
      AddError(Errors, Path, 'less than minimum');
      Result := False;
    end;
    var MaximumValue := ResolvedSchema.GetValue('maximum');
    if (MaximumValue is TJSONNumber) and (NumberValue > TJSONNumber(MaximumValue).AsDouble) then
    begin
      AddError(Errors, Path, 'greater than maximum');
      Result := False;
    end;
  end;

  if Instance is TJSONObject then
  begin
    var Obj := TJSONObject(Instance);

    var RequiredValue := ResolvedSchema.GetValue('required');
    if RequiredValue is TJSONArray then
      for var Item in TJSONArray(RequiredValue) do
        if (Item is TJSONString) and not (Item is TJSONNumber)
          and not Assigned(Obj.GetValue(TJSONString(Item).Value)) then
        begin
          AddError(Errors, Path, 'missing required property "' + TJSONString(Item).Value + '"');
          Result := False;
        end;

    var PropSchemas: TJSONObject := nil;
    var PropertiesValue := ResolvedSchema.GetValue('properties');
    if PropertiesValue is TJSONObject then
      PropSchemas := TJSONObject(PropertiesValue);

    if Assigned(PropSchemas) then
      for var Pair in Obj do
      begin
        var PropSchemaValue := PropSchemas.GetValue(Pair.JsonString.Value);
        if PropSchemaValue is TJSONObject then
          if not ValidateNode(TJSONObject(PropSchemaValue), Pair.JsonValue, Path + '.' + Pair.JsonString.Value,
            Depth + 1, RootSchema, Errors) then
            Result := False;
      end;

    var AdditionalValue := ResolvedSchema.GetValue('additionalProperties');
    if (AdditionalValue is TJSONBool) and not TJSONBool(AdditionalValue).AsBoolean then
      for var Pair in Obj do
        if not (Assigned(PropSchemas) and Assigned(PropSchemas.GetValue(Pair.JsonString.Value))) then
        begin
          AddError(Errors, Path, 'unexpected property "' + Pair.JsonString.Value + '"');
          Result := False;
        end;
  end;

  if Instance is TJSONArray then
  begin
    var ItemsValue := ResolvedSchema.GetValue('items');
    if ItemsValue is TJSONObject then
      for var I := 0 to TJSONArray(Instance).Count - 1 do
        if not ValidateNode(TJSONObject(ItemsValue), TJSONArray(Instance).Items[I], Format('%s[%d]', [Path, I]),
          Depth + 1, RootSchema, Errors) then
          Result := False;
  end;
end;

class function TMCPSchemaValidator.Validate(const Schema: TJSONObject; const Instance: TJSONValue;
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
