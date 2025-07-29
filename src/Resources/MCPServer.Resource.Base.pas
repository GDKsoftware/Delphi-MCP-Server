unit MCPServer.Resource.Base;

interface

uses
  System.SysUtils,
  System.Rtti,
  System.JSON;

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
  
  TMCPResourceBase<T: class, constructor> = class(TInterfacedObject, IMCPResource)
  protected
    FURI: string;
    FName: string;
    FDescription: string;
    FMimeType: string;
    function GetResourceData: T; virtual; abstract;
  public
    constructor Create; virtual;
    destructor Destroy; override;
    
    function GetURI: string;
    function GetName: string;
    function GetDescription: string;
    function GetMimeType: string;
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
end;

destructor TMCPResourceBase<T>.Destroy;
begin
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

function TMCPResourceBase<T>.Read: string;
var
  ResourceData: T;
  JSONObj: TJSONObject;
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
      var Ctx := TRttiContext.Create;
      try
        var Typ := Ctx.GetType(ResourceData.ClassType);
        var Prop := Typ.GetProperty('Content');
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