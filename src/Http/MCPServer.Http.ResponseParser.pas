unit MCPServer.Http.ResponseParser;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Http.Response.Interfaces,
  MCPServer.Http.ResponseParser.Interfaces;

type
  TJsonResponseParser = class(TInterfacedObject, IResponseParser)
  public
    function ParseSuccess(const Response: IHttpResponse): TJSONObject;
    function CreateErrorResponse(const StatusCode: Integer; const Message: string): TJSONObject;
  end;

implementation

function TJsonResponseParser.ParseSuccess(const Response: IHttpResponse): TJSONObject;
begin
  if Response.StatusCode = 204 then
  begin
    Result := TJSONObject.Create;
    Result.AddPair('success', TJSONBool.Create(True));
    Exit;
  end;

  var ResponseText := Response.Content;
  if not ResponseText.Trim.IsEmpty then
  begin
    var ParsedValue := TJSONObject.ParseJSONValue(ResponseText);
    if ParsedValue is TJSONObject then
      Result := TJSONObject(ParsedValue)
    else if ParsedValue is TJSONArray then
    begin
      Result := TJSONObject.Create;
      Result.AddPair('items', ParsedValue);
    end
    else
    begin
      Result := TJSONObject.Create;
      Result.AddPair('success', TJSONBool.Create(True));
      ParsedValue.Free;
    end;
  end
  else
  begin
    Result := TJSONObject.Create;
    Result.AddPair('success', TJSONBool.Create(True));
  end;
end;

function TJsonResponseParser.CreateErrorResponse(const StatusCode: Integer; const Message: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('error', Format('HTTP %d: %s', [StatusCode, Message]));
end;

end.
