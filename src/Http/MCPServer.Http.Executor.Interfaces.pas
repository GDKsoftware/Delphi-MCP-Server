unit MCPServer.Http.Executor.Interfaces;

interface

uses
  System.Classes,
  System.Net.URLClient,
  MCPServer.Http.Response.Interfaces;

type
  IHttpExecutor = interface
    ['{B2C3D4E5-F6A7-4890-BCDE-F01234567890}']
    function Get(const Url: string; const Headers: TArray<TNetHeader>): IHttpResponse;
    function Post(const Url: string; const Body: string; const Headers: TArray<TNetHeader>): IHttpResponse; overload;
    function Post(const Url: string; const Body: TStream; const Headers: TArray<TNetHeader>): IHttpResponse; overload;
    function PostToStream(const Url: string; const DestStream: TStream; const Headers: TArray<TNetHeader>): IHttpResponse;
    function Put(const Url: string; const Body: string; const Headers: TArray<TNetHeader>): IHttpResponse;
    function Patch(const Url: string; const Body: string; const Headers: TArray<TNetHeader>): IHttpResponse;
    function Delete(const Url: string; const Headers: TArray<TNetHeader>): IHttpResponse;
  end;

implementation

end.
