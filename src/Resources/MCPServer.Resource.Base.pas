unit MCPServer.Resource.Base;

interface

uses
  System.SysUtils,
  System.Rtti,
  System.JSON,
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

end.
