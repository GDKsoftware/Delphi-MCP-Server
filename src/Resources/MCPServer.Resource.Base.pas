unit MCPServer.Resource.Base;

interface

uses
  System.SysUtils,
  System.Rtti,
  System.JSON,
  System.Generics.Collections,
  System.RegularExpressions,
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

  /// Resource whose data is a class T serialised as JSON (mime type
  /// application/json) or, for other mime types, the string in T's Content
  /// property.
  ///
  /// The protected fields FTitle, FSize (-1 = unknown), FAnnotations (nil),
  /// FTtlMs (0) and FCacheScope ('private') have safe defaults; set them in
  /// the constructor of a descendant.
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

  /// Variables captured from a URI matched against a template.
  TMCPTemplateVars = TDictionary<string, string>;

  IMCPResourceTemplate = interface
    ['{3A5C7E91-8042-4A5B-B6C7-D8E9F0A1B2C3}']
    function GetUriTemplate: string;
    function GetName: string;
    function GetTitle: string;
    function GetDescription: string;
    function GetMimeType: string;
    /// True when URI matches the template; the captured variables
    /// (percent-decoded) are added to Vars.
    function Matches(const URI: string; Vars: TMCPTemplateVars): Boolean;
    /// Builds the resource for a URI already confirmed to match, with its
    /// captured variables.
    function CreateResource(const URI: string; Vars: TMCPTemplateVars): IMCPResource;

    property UriTemplate: string read GetUriTemplate;
    property Name: string read GetName;
    property Title: string read GetTitle;
    property Description: string read GetDescription;
    property MimeType: string read GetMimeType;
  end;

  /// Resource template matched by URI, RFC 6570 level 1 (simple string
  /// expansion, "{var}", one path segment) and a level 2 subset (reserved
  /// expansion, "{+var}", matches the rest of the URI including "/").
  /// "{/var}" and "{?var}" are not supported.
  ///
  /// Set FUriTemplate, FName and the optional FTitle/FDescription/FMimeType
  /// in the constructor of a descendant, as with TMCPResourceBase<T>.
  TMCPResourceTemplateBase = class(TInterfacedObject, IMCPResourceTemplate)
  strict private
    FRegex: TRegEx;
    FVariableNames: TArray<string>;
    FCompiled: Boolean;
    procedure EnsureCompiled;
    class function CompilePattern(const UriTemplate: string; out VariableNames: TArray<string>): string; static;
  protected
    FUriTemplate: string;
    FName: string;
    FTitle: string;
    FDescription: string;
    FMimeType: string;
  public
    constructor Create; virtual;

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
  System.NetEncoding,
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
  if FCompiled then
    Exit;
  FRegex := TRegEx.Create(CompilePattern(FUriTemplate, FVariableNames));
  FCompiled := True;
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
  var Match := FRegex.Match(URI);
  Result := Match.Success;
  if Result then
    for var VarName in FVariableNames do
      Vars.AddOrSetValue(VarName, TNetEncoding.URL.Decode(Match.Groups[VarName].Value));
end;

end.
