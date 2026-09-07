unit MCPServer.Resource.Base;

interface

uses
  System.SysUtils,
  System.Rtti,
  System.JSON,
  System.Generics.Collections,
  System.RegularExpressions,
  System.SyncObjs,
  MCPServer.Types;

type
  IMCPResource = interface
    ['{A7B8C9D0-E1F2-3456-7890-BCDEF1234567}']
    function GetURI: string;
    function GetName: string;
    function GetDescription: string;
    function GetMimeType: string;
    function Read: string;

    property URI: string read GetURI;
    property Name: string read GetName;
    property Description: string read GetDescription;
    property MimeType: string read GetMimeType;
  end;

  TMCPResourceBase<T: class, constructor> = class(TInterfacedObject, IMCPResource,
    IMCPResourceMetadata, IMCPCacheableResource)
  protected
    FURI: string;
    FName: string;
    FDescription: string;
    FMimeType: string;
    FTitle: string;
    FSize: Int64;
    FAnnotations: TJSONObject;
    FTtlMs: Integer;
    FCacheScope: string;
    function GetResourceData: T; virtual; abstract;
  public
    constructor Create; virtual;
    destructor Destroy; override;

    function GetURI: string;
    function GetName: string;
    function GetDescription: string;
    function GetMimeType: string;
    function GetTitle: string;
    function GetSize: Int64;
    function GetAnnotations: TJSONObject;
    function GetTtlMs: Integer;
    function GetCacheScope: string;
    function Read: string;
  end;

  TResourceContent = class
  private
    FURI: string;
    FMimeType: string;
    FText: string;
  public
    property URI: string read FURI write FURI;
    property MimeType: string read FMimeType write FMimeType;
    property Text: string read FText write FText;
  end;

  TMCPTemplateVars = TDictionary<string, string>;

  IMCPResourceTemplate = interface
    ['{3A5C7E91-8042-4A5B-B6C7-D8E9F0A1B2C3}']
    function GetUriTemplate: string;
    function GetName: string;
    function GetTitle: string;
    function GetDescription: string;
    function GetMimeType: string;
    function Matches(const URI: string; Vars: TMCPTemplateVars): Boolean;
    function CreateResource(const URI: string; Vars: TMCPTemplateVars): IMCPResource;

    property UriTemplate: string read GetUriTemplate;
    property Name: string read GetName;
    property Title: string read GetTitle;
    property Description: string read GetDescription;
    property MimeType: string read GetMimeType;
  end;

  TMCPResourceTemplateBase = class(TInterfacedObject, IMCPResourceTemplate)
  strict private
    FPattern: string;
    FVariableNames: TArray<string>;
    FCompiled: Boolean;
    FCompileLock: TCriticalSection;
    procedure EnsureCompiled;
    class function PercentDecode(const Text: string): string; static;
    class function CompilePattern(const UriTemplate: string; out VariableNames: TArray<string>): string; static;
  protected
    FUriTemplate: string;
    FName: string;
    FTitle: string;
    FDescription: string;
    FMimeType: string;
  public
    constructor Create; virtual;
    destructor Destroy; override;

    function GetUriTemplate: string;
    function GetName: string;
    function GetTitle: string;
    function GetDescription: string;
    function GetMimeType: string;
    function Matches(const URI: string; Vars: TMCPTemplateVars): Boolean;
    function CreateResource(const URI: string; Vars: TMCPTemplateVars): IMCPResource; virtual; abstract;
  end;

implementation

uses
  MCPServer.Serializer;

{ TMCPResourceBase<T> }

constructor TMCPResourceBase<T>.Create;
begin
  inherited;
  FSize := -1;
  FTtlMs := 0;
  FCacheScope := MCP_CACHE_SCOPE_PRIVATE;
end;

destructor TMCPResourceBase<T>.Destroy;
begin
  FAnnotations.Free;
  inherited;
end;

function TMCPResourceBase<T>.GetURI: string;
begin
  Result := FURI;
end;

function TMCPResourceBase<T>.GetName: string;
begin
  Result := FName;
end;

function TMCPResourceBase<T>.GetDescription: string;
begin
  Result := FDescription;
end;

function TMCPResourceBase<T>.GetMimeType: string;
begin
  Result := FMimeType;
end;

function TMCPResourceBase<T>.GetTitle: string;
begin
  Result := FTitle;
end;

function TMCPResourceBase<T>.GetSize: Int64;
begin
  Result := FSize;
end;

function TMCPResourceBase<T>.GetAnnotations: TJSONObject;
begin
  Result := FAnnotations;
end;

function TMCPResourceBase<T>.GetTtlMs: Integer;
begin
  Result := FTtlMs;
end;

function TMCPResourceBase<T>.GetCacheScope: string;
begin
  Result := FCacheScope;
end;

function TMCPResourceBase<T>.Read: string;
var
  Ctx: TRttiContext;
  JSONObj: TJSONObject;
  Prop: TRttiProperty;
  ResourceData: T;
  Typ: TRttiType;
begin
  ResourceData := GetResourceData;
  try
    if FMimeType = 'application/json' then
    begin
      JSONObj := TJSONObject.Create;
      try
        {$WARN UNSAFE_CAST OFF}
        TMCPSerializer.Serialize(TObject(ResourceData), JSONObj);
        {$WARN UNSAFE_CAST ON}
        Result := JSONObj.ToJSON;
      finally
        JSONObj.Free;
      end;
    end
    else
    begin
      Ctx := TRttiContext.Create;
      try
        Typ := Ctx.GetType(ResourceData.ClassType);
        Prop := Typ.GetProperty('Content');
        if Assigned(Prop) then
        begin
          {$WARN UNSAFE_CAST OFF}
          Result := Prop.GetValue(TObject(ResourceData)).AsString;
          {$WARN UNSAFE_CAST ON}
        end
        else
          Result := '';
      finally
        Ctx.Free;
      end;
    end;
  finally
    ResourceData.Free;
  end;
end;

{ TMCPResourceTemplateBase }

constructor TMCPResourceTemplateBase.Create;
begin
  inherited Create;
  FMimeType := '';
  FCompileLock := TCriticalSection.Create;
end;

destructor TMCPResourceTemplateBase.Destroy;
begin
  FCompileLock.Free;
  inherited;
end;

class function TMCPResourceTemplateBase.PercentDecode(const Text: string): string;
begin
  var Bytes: TBytes := nil;
  var Utf8 := TEncoding.UTF8.GetBytes(Text);
  var I := 0;
  while I < Length(Utf8) do
  begin
    if (Utf8[I] = Ord('%')) and (I + 2 < Length(Utf8)) then
    begin
      var Hex := Char(Utf8[I + 1]) + Char(Utf8[I + 2]);
      var Value := StrToIntDef('$' + Hex, -1);
      if Value >= 0 then
      begin
        Bytes := Bytes + [Byte(Value)];
        Inc(I, 3);
        Continue;
      end;
    end;
    Bytes := Bytes + [Utf8[I]];
    Inc(I);
  end;
  Result := TEncoding.UTF8.GetString(Bytes);
end;

class function TMCPResourceTemplateBase.CompilePattern(const UriTemplate: string;
  out VariableNames: TArray<string>): string;
var
  Names: TList<string>;
  Position: Integer;
  CloseBrace: Integer;
  Expr, VarName, LiteralRun: string;
begin
  Names := TList<string>.Create;
  try
    Result := '';
    Position := 1;
    while Position <= Length(UriTemplate) do
    begin
      if UriTemplate[Position] = '{' then
      begin
        CloseBrace := System.Pos('}', UriTemplate, Position);
        if CloseBrace = 0 then
          raise EArgumentException.CreateFmt('Unterminated "{" in URI template "%s"', [UriTemplate]);

        Expr := Copy(UriTemplate, Position + 1, CloseBrace - Position - 1);
        if (Expr <> '') and (Expr[1] = '+') then
        begin
          VarName := Copy(Expr, 2, MaxInt);
          Result := Result + Format('(?<%s>.+)', [VarName]);
        end
        else
        begin
          VarName := Expr;
          Result := Result + Format('(?<%s>[^/]+)', [VarName]);
        end;
        if VarName = '' then
          raise EArgumentException.CreateFmt('Empty variable name in URI template "%s"', [UriTemplate]);
        for var C in VarName do
          if not CharInSet(C, ['A'..'Z', 'a'..'z', '0'..'9', '_']) then
            raise EArgumentException.CreateFmt('Variable name "%s" in URI template "%s" may only contain letters, digits and underscores',
              [VarName, UriTemplate]);

        if Names.IndexOf(VarName) >= 0 then
          raise EArgumentException.CreateFmt('URI template %s uses the variable %s more than once',
            [UriTemplate, VarName]);
        Names.Add(VarName);
        Position := CloseBrace + 1;
      end
      else
      begin
        var LiteralStart := Position;
        while (Position <= Length(UriTemplate)) and (UriTemplate[Position] <> '{') do
          Inc(Position);
        LiteralRun := Copy(UriTemplate, LiteralStart, Position - LiteralStart);
        Result := Result + TRegEx.Escape(LiteralRun);
      end;
    end;
    Result := '^' + Result + '$';
    VariableNames := Names.ToArray;
  finally
    Names.Free;
  end;
end;

procedure TMCPResourceTemplateBase.EnsureCompiled;
begin
  FCompileLock.Enter;
  try
    if not FCompiled then
    begin
      FPattern := CompilePattern(FUriTemplate, FVariableNames);
      FCompiled := True;
    end;
  finally
    FCompileLock.Leave;
  end;
end;

function TMCPResourceTemplateBase.GetUriTemplate: string;
begin
  Result := FUriTemplate;
end;

function TMCPResourceTemplateBase.GetName: string;
begin
  Result := FName;
end;

function TMCPResourceTemplateBase.GetTitle: string;
begin
  Result := FTitle;
end;

function TMCPResourceTemplateBase.GetDescription: string;
begin
  Result := FDescription;
end;

function TMCPResourceTemplateBase.GetMimeType: string;
begin
  Result := FMimeType;
end;

function TMCPResourceTemplateBase.Matches(const URI: string; Vars: TMCPTemplateVars): Boolean;
begin
  EnsureCompiled;
  var Match := TRegEx.Match(URI, FPattern);
  Result := Match.Success;
  if Result then
    for var VarName in FVariableNames do
      Vars.AddOrSetValue(VarName, PercentDecode(Match.Groups[VarName].Value));
end;

end.
