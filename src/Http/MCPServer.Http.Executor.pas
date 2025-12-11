unit MCPServer.Http.Executor;

interface

uses
  System.SysUtils,
  System.Classes,
  System.Net.HttpClient,
  System.Net.URLClient,
  MCPServer.Http.Config,
  MCPServer.Http.Response.Interfaces,
  MCPServer.Http.Executor.Interfaces;

type
  THttpExecutor = class(TInterfacedObject, IHttpExecutor)
  private
    FHttpClient: THTTPClient;

    function CreateResponse(const Response: IHTTPResponse): IHttpResponse;
  public
    constructor Create(const Config: THttpClientConfig);
    destructor Destroy; override;

    function Get(const Url: string; const Headers: TArray<TNetHeader>): IHttpResponse;
    function Post(const Url: string; const Body: string; const Headers: TArray<TNetHeader>): IHttpResponse; overload;
    function Post(const Url: string; const Body: TStream; const Headers: TArray<TNetHeader>): IHttpResponse; overload;
    function Put(const Url: string; const Body: string; const Headers: TArray<TNetHeader>): IHttpResponse;
    function Patch(const Url: string; const Body: string; const Headers: TArray<TNetHeader>): IHttpResponse;
    function Delete(const Url: string; const Headers: TArray<TNetHeader>): IHttpResponse;
  end;

implementation

uses
  MCPServer.Http.Response;

constructor THttpExecutor.Create(const Config: THttpClientConfig);
begin
  inherited Create;
  FHttpClient := THTTPClient.Create;
  FHttpClient.ConnectionTimeout := Config.ConnectionTimeout;
  FHttpClient.ResponseTimeout := Config.ResponseTimeout;
  FHttpClient.SendTimeout := Config.SendTimeout;
end;

destructor THttpExecutor.Destroy;
begin
  FHttpClient.Free;
  inherited Destroy;
end;

function THttpExecutor.CreateResponse(const Response: IHTTPResponse): IHttpResponse;
begin
  Result := THttpResponse.Create(Response.StatusCode, Response.ContentAsString(TEncoding.UTF8));
end;

function THttpExecutor.Get(const Url: string; const Headers: TArray<TNetHeader>): IHttpResponse;
begin
  var Response := FHttpClient.Get(Url, nil, Headers);
  Result := CreateResponse(Response);
end;

function THttpExecutor.Post(const Url: string; const Body: string; const Headers: TArray<TNetHeader>): IHttpResponse;
begin
  var Content: TStringStream := nil;
  if not Body.IsEmpty then
    Content := TStringStream.Create(Body, TEncoding.UTF8);
  try
    var Response := FHttpClient.Post(Url, Content, nil, Headers);
    Result := CreateResponse(Response);
  finally
    Content.Free;
  end;
end;

function THttpExecutor.Post(const Url: string; const Body: TStream; const Headers: TArray<TNetHeader>): IHttpResponse;
begin
  var Response := FHttpClient.Post(Url, Body, nil, Headers);
  Result := CreateResponse(Response);
end;

function THttpExecutor.Put(const Url: string; const Body: string; const Headers: TArray<TNetHeader>): IHttpResponse;
begin
  var Content: TStringStream := nil;
  if not Body.IsEmpty then
    Content := TStringStream.Create(Body, TEncoding.UTF8);
  try
    var Response := FHttpClient.Put(Url, Content, nil, Headers);
    Result := CreateResponse(Response);
  finally
    Content.Free;
  end;
end;

function THttpExecutor.Patch(const Url: string; const Body: string; const Headers: TArray<TNetHeader>): IHttpResponse;
begin
  var Content: TStringStream := nil;
  if not Body.IsEmpty then
    Content := TStringStream.Create(Body, TEncoding.UTF8);
  try
    var Response := FHttpClient.Patch(Url, Content, nil, Headers);
    Result := CreateResponse(Response);
  finally
    Content.Free;
  end;
end;

function THttpExecutor.Delete(const Url: string; const Headers: TArray<TNetHeader>): IHttpResponse;
begin
  var Response := FHttpClient.Delete(Url, nil, Headers);
  Result := CreateResponse(Response);
end;

end.
