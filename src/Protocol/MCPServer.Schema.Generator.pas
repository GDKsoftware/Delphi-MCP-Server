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
    class function GetJsonTypeFromRttiType(RttiType: TRttiType): string;
    class function GetPropertyJsonName(Prop: TRttiProperty; RType: TRttiType): string;
    class function IsRequiredProperty(Prop: TRttiProperty): Boolean;
  public
    class function GenerateSchema(Cls: TClass): TJSONObject;
    class function GenerateSchemaFromInstance(Instance: TObject): TJSONObject;
  end;

implementation

uses
  System.Generics.Collections,
  MCPServer.Types;

{ TMCPSchemaGenerator }

class function TMCPSchemaGenerator.GenerateSchema(Cls: TClass): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  
  var Properties := TJSONObject.Create;
  Result.AddPair('properties', Properties);
  var RequiredArray := TJSONArray.Create;
  Result.AddPair('required', RequiredArray);
  
  var RttiContext := TRttiContext.Create;
  try
    var RttiType := RttiContext.GetType(Cls);
    
    for var RttiProp in RttiType.GetProperties do
    begin
      if RttiProp.IsReadable and RttiProp.IsWritable then
      begin
        var JsonName := GetPropertyJsonName(RttiProp, RttiType);
        
        var PropSchema := TJSONObject.Create;
        Properties.AddPair(JsonName, PropSchema);
        PropSchema.AddPair('type', GetJsonTypeFromRttiType(RttiProp.PropertyType));
        
        for var Attr in RttiProp.GetAttributes do
        begin
          if Attr is SchemaDescriptionAttribute then
          begin
            PropSchema.AddPair('description', SchemaDescriptionAttribute(Attr).Description);
          end
          else if Attr is SchemaEnumAttribute then
          begin
            var EnumArray := TJSONArray.Create;
            for var Value in SchemaEnumAttribute(Attr).Values do
              EnumArray.Add(Value);
            PropSchema.AddPair('enum', EnumArray);
          end;
        end;
        
        if IsRequiredProperty(RttiProp) then
          RequiredArray.Add(JsonName);
      end;
    end;
  finally
    RttiContext.Free;
  end;
end;

class function TMCPSchemaGenerator.GenerateSchemaFromInstance(Instance: TObject): TJSONObject;
begin
  Result := GenerateSchema(Instance.ClassType);
end;

class function TMCPSchemaGenerator.GetJsonTypeFromRttiType(RttiType: TRttiType): string;
begin
  case RttiType.TypeKind of
    tkInteger, tkInt64: Result := 'number';
    tkFloat: Result := 'number';
    tkString, tkLString, tkWString, tkUString: Result := 'string';
    tkEnumeration:
      if RttiType.Name = 'Boolean' then
        Result := 'boolean'
      else
        Result := 'string';
    tkSet: Result := 'array';
    tkClass: Result := 'object';
    tkArray, tkDynArray: Result := 'array';
  else
    Result := 'string';
  end;
end;

class function TMCPSchemaGenerator.GetPropertyJsonName(Prop: TRttiProperty; RType: TRttiType): string;
begin
  Result := LowerCase(Prop.Name);
end;

class function TMCPSchemaGenerator.IsRequiredProperty(Prop: TRttiProperty): Boolean;
begin
  for var Attr in Prop.GetAttributes do
  begin
    if Attr is OptionalAttribute then
      Exit(False);
  end;
  Result := True;
end;

end.