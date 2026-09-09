unit MCPServer.Tool.Method;

interface

uses
  System.Rtti,
  System.JSON,
  System.Generics.Collections,
  MCPServer.Types,
  MCPServer.Tool.Base;

type
  TMCPMethodTool = class(TInterfacedObject, IMCPTool, IMCPToolMetadata)
  protected
    FContext: TRttiContext;
    FInstance: TValue;
    FMethod: TRttiMethod;
    FName: string;
    FTitle: string;
    FDescription: string;
    FAnnotations: TJSONObject;
    FIcons: TJSONArray;
    FInputSchema: TJSONObject;

    function MarshalArgument(const Param: TRttiParameter; const Arguments: TJSONObject;
      const Owned: TList<TObject>): TValue; virtual;
    function ResultToJson(const Value: TValue; const ResultType: TRttiType): TJSONValue; virtual;
    procedure ReleaseResult(const Value: TValue; const ResultType: TRttiType); virtual;
    procedure ReleaseArguments(const Owned: TList<TObject>); virtual;

    procedure ValidateArguments(const Arguments: TJSONObject);
    function MarshalArguments(const Arguments: TJSONObject;
      const Owned: TList<TObject>): TArray<TValue>;
    function InvokeToJson(const Arguments: TJSONObject): TJSONValue;
  public
    constructor Create(const Instance: TValue; const Method: TRttiMethod;
      const Name, Description: string);
    destructor Destroy; override;

    function GetName: string;
    function GetTitle: string;
    function GetDescription: string;
    function GetInputSchema: TJSONObject;
    function GetOutputSchema: TJSONObject; virtual;
    function Execute(const Arguments: TJSONObject): TValue;

    function GetAnnotations: TJSONObject;
    function GetIcons: TJSONArray;

    procedure MarkReadOnly(const OpenWorld: Boolean = False);
  end;

implementation

uses
  System.SysUtils,
  System.TypInfo,
  MCPServer.Schema.Generator,
  MCPServer.Schema.Validator,
  MCPServer.Serializer;

const
  RESULT_KEY_OK = 'ok';

function ParameterWireName(const Param: TRttiParameter): string;
begin
  for var Attr in Param.GetAttributes do
    if Attr is SchemaNameAttribute then
      Exit(SchemaNameAttribute(Attr).Name);

  Result := LowerCase(Param.Name);
end;

function IsObjectElementArray(const RttiType: TRttiType): Boolean;
begin
  if RttiType.TypeKind <> tkDynArray then
    Exit(False);

  const ElementType = TRttiDynamicArrayType(RttiType).ElementType;
  Result := Assigned(ElementType) and (ElementType.TypeKind = tkClass);
end;

{ TMCPMethodTool }

constructor TMCPMethodTool.Create(const Instance: TValue; const Method: TRttiMethod;
  const Name, Description: string);
begin
  inherited Create;

  if not Assigned(Method) then
    raise EArgumentNilException.Create('A method tool needs a method');

  FContext := TRttiContext.Create;
  FContext.GetType(TypeInfo(TObject));

  FInstance := Instance;
  FMethod := Method;
  FName := Name;
  FDescription := Description;
  FInputSchema := TMCPSchemaGenerator.GenerateSchemaFromMethod(Method);
end;

destructor TMCPMethodTool.Destroy;
begin
  FInputSchema.Free;
  FAnnotations.Free;
  FIcons.Free;
  FContext.Free;
  inherited;
end;

function TMCPMethodTool.GetName: string;
begin
  Result := FName;
end;

function TMCPMethodTool.GetTitle: string;
begin
  if FTitle <> '' then
    Result := FTitle
  else
    Result := FName;
end;

function TMCPMethodTool.GetDescription: string;
begin
  Result := FDescription;
end;

function TMCPMethodTool.GetInputSchema: TJSONObject;
begin
  Result := TJSONObject(FInputSchema.Clone);
end;

function TMCPMethodTool.GetOutputSchema: TJSONObject;
begin
  Result := TMCPSchemaGenerator.GenerateSchemaFromMethodResult(FMethod);
end;

function TMCPMethodTool.GetAnnotations: TJSONObject;
begin
  Result := FAnnotations;
end;

function TMCPMethodTool.GetIcons: TJSONArray;
begin
  Result := FIcons;
end;

procedure TMCPMethodTool.MarkReadOnly(const OpenWorld: Boolean);
begin
  TMCPToolAnnotationWriter.ReadOnly(FAnnotations, OpenWorld);
end;

procedure TMCPMethodTool.ValidateArguments(const Arguments: TJSONObject);
begin
  var OwnedArguments: TJSONObject := nil;
  var Effective := Arguments;
  if not Assigned(Effective) then
  begin
    OwnedArguments := TJSONObject.Create;
    Effective := OwnedArguments;
  end;

  try
    var Errors: TArray<string>;
    if not TMCPSchemaValidator.TryValidate(FInputSchema, Effective, Errors) then
      raise EArgumentException.Create(string.Join('; ', Errors));
  finally
    OwnedArguments.Free;
  end;
end;

function TMCPMethodTool.MarshalArgument(const Param: TRttiParameter; const Arguments: TJSONObject;
  const Owned: TList<TObject>): TValue;
begin
  const WireName = ParameterWireName(Param);

  var JsonValue: TJSONValue := nil;
  if Assigned(Arguments) then
    JsonValue := Arguments.GetValue(WireName);

  const IsAbsent = not Assigned(JsonValue) or (JsonValue is TJSONNull);
  if IsAbsent then
  begin
    TValue.Make(nil, Param.ParamType.Handle, Result);
    Exit;
  end;

  try
    Result := TMCPSerializer.JsonToValue(JsonValue, Param.ParamType, Owned);
  except
    on E: EArgumentException do
      raise EArgumentException.CreateFmt('Parameter "%s": %s', [WireName, E.Message]);
  end;
end;

function TMCPMethodTool.MarshalArguments(const Arguments: TJSONObject;
  const Owned: TList<TObject>): TArray<TValue>;
begin
  const Parameters = FMethod.GetParameters;
  SetLength(Result, Length(Parameters));
  for var Index := 0 to High(Parameters) do
    Result[Index] := MarshalArgument(Parameters[Index], Arguments, Owned);
end;

function TMCPMethodTool.ResultToJson(const Value: TValue; const ResultType: TRttiType): TJSONValue;
begin
  Result := TJSONObject.Create;
  try
    if not Assigned(ResultType) then
    begin
      TJSONObject(Result).AddPair(RESULT_KEY_OK, TJSONBool.Create(True));
      Exit;
    end;

    var Converted := TMCPSerializer.ValueToJson(Value, ResultType);
    if not Assigned(Converted) then
      Converted := TJSONNull.Create;
    TJSONObject(Result).AddPair(MCP_KEY_RESULT, Converted);
  except
    Result.Free;
    raise;
  end;
end;

procedure TMCPMethodTool.ReleaseResult(const Value: TValue; const ResultType: TRttiType);
begin
  if not Assigned(ResultType) or Value.IsEmpty then
    Exit;

  if ResultType.TypeKind = tkClass then
  begin
    if Value.IsObject then
      Value.AsObject.Free;
    Exit;
  end;

  if not IsObjectElementArray(ResultType) then
    Exit;

  for var Index := 0 to Value.GetArrayLength - 1 do
  begin
    const Element = Value.GetArrayElement(Index);
    if Element.IsObject then
      Element.AsObject.Free;
  end;
end;

procedure TMCPMethodTool.ReleaseArguments(const Owned: TList<TObject>);
begin
  for var Item in Owned do
  begin
    Item.Free;
  end;
end;

function TMCPMethodTool.InvokeToJson(const Arguments: TJSONObject): TJSONValue;
begin
  const Owned = TList<TObject>.Create;
  try
    var Args := MarshalArguments(Arguments, Owned);
    const ReturnType = FMethod.ReturnType;
    var ReturnValue := FMethod.Invoke(FInstance, Args);
    try
      Result := ResultToJson(ReturnValue, ReturnType);
    finally
      ReleaseResult(ReturnValue, ReturnType);
    end;
  finally
    ReleaseArguments(Owned);
    Owned.Free;
  end;
end;

function TMCPMethodTool.Execute(const Arguments: TJSONObject): TValue;
begin
  ValidateArguments(Arguments);

  const Json = InvokeToJson(Arguments);
  if not (Json is TJSONObject) then
  begin
    Json.Free;
    raise EInvalidOpException.CreateFmt('%s.ResultToJson must return a TJSONObject', [ClassName]);
  end;

  Result := TValue.From<TJSONObject>(TJSONObject(Json));
end;

end.
