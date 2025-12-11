unit MCPServer.Http.Config;

interface

type
  THttpClientConfig = record
    ConnectionTimeout: Integer;
    ResponseTimeout: Integer;
    SendTimeout: Integer;

    class function Default: THttpClientConfig; static;
  end;

implementation

class function THttpClientConfig.Default: THttpClientConfig;
begin
  Result.ConnectionTimeout := 30000;
  Result.ResponseTimeout := 120000;
  Result.SendTimeout := 30000;
end;

end.
