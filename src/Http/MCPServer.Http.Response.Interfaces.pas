unit MCPServer.Http.Response.Interfaces;

interface

type
  IHttpResponse = interface
    ['{A1B2C3D4-E5F6-4789-ABCD-EF0123456789}']
    function GetStatusCode: Integer;
    function GetContent: string;
    function GetIsSuccess: Boolean;
    function GetHeader(const Name: string): string;

    property StatusCode: Integer read GetStatusCode;
    property Content: string read GetContent;
    property IsSuccess: Boolean read GetIsSuccess;
  end;

implementation

end.
