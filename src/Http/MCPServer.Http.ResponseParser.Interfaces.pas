unit MCPServer.Http.ResponseParser.Interfaces;

interface

uses
  System.JSON,
  MCPServer.Http.Response.Interfaces;

type
  IResponseParser = interface
    ['{C3D4E5F6-A7B8-4901-CDEF-012345678901}']
    function ParseSuccess(const Response: IHttpResponse): TJSONObject;
    function CreateErrorResponse(const StatusCode: Integer; const Message: string): TJSONObject;
  end;

implementation

end.
