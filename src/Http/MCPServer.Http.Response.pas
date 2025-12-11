unit MCPServer.Http.Response;

interface

uses
  System.Net.URLClient,
  MCPServer.Http.Response.Interfaces;

type
  THttpResponse = class(TInterfacedObject, IHttpResponse)
  private
    FStatusCode: Integer;
    FContent: string;
    FHeaders: TArray<TNetHeader>;

    function GetStatusCode: Integer;
    function GetContent: string;
    function GetIsSuccess: Boolean;
    function GetHeader(const Name: string): string;
  public
    constructor Create(const StatusCode: Integer; const Content: string); overload;
    constructor Create(const StatusCode: Integer; const Content: string;
      const Headers: TArray<TNetHeader>); overload;

    property StatusCode: Integer read GetStatusCode;
    property Content: string read GetContent;
    property IsSuccess: Boolean read GetIsSuccess;
  end;

implementation

uses
  System.SysUtils;

constructor THttpResponse.Create(const StatusCode: Integer; const Content: string);
begin
  inherited Create;
  FStatusCode := StatusCode;
  FContent := Content;
  FHeaders := [];
end;

constructor THttpResponse.Create(const StatusCode: Integer; const Content: string;
  const Headers: TArray<TNetHeader>);
begin
  inherited Create;
  FStatusCode := StatusCode;
  FContent := Content;
  FHeaders := Headers;
end;

function THttpResponse.GetStatusCode: Integer;
begin
  Result := FStatusCode;
end;

function THttpResponse.GetContent: string;
begin
  Result := FContent;
end;

function THttpResponse.GetIsSuccess: Boolean;
begin
  Result := (FStatusCode >= 200) and (FStatusCode < 300);
end;

function THttpResponse.GetHeader(const Name: string): string;
begin
  Result := '';
  for var Header in FHeaders do
  begin
    if SameText(Header.Name, Name) then
    begin
      Result := Header.Value;
      Exit;
    end;
  end;
end;

end.
