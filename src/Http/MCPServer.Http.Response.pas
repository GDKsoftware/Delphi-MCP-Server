unit MCPServer.Http.Response;

interface

uses
  MCPServer.Http.Response.Interfaces;

type
  THttpResponse = class(TInterfacedObject, IHttpResponse)
  private
    FStatusCode: Integer;
    FContent: string;

    function GetStatusCode: Integer;
    function GetContent: string;
    function GetIsSuccess: Boolean;
  public
    constructor Create(const StatusCode: Integer; const Content: string);

    property StatusCode: Integer read GetStatusCode;
    property Content: string read GetContent;
    property IsSuccess: Boolean read GetIsSuccess;
  end;

implementation

constructor THttpResponse.Create(const StatusCode: Integer; const Content: string);
begin
  inherited Create;
  FStatusCode := StatusCode;
  FContent := Content;
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

end.
