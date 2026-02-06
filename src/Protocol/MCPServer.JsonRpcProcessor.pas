unit MCPServer.JsonRpcProcessor;

interface

uses
  System.SysUtils,
  System.JSON,
  System.Rtti,
  MCPServer.Types,
  MCPServer.Logger;

type
  TMCPJsonRpcProcessor = class
  private
    FManagerRegistry: IMCPManagerRegistry;
    class function ParseJSONRequest(const RequestBody: string): TJSONObject;
    class function ExtractRequestID(JSONRequest: TJSONObject): TValue;
    class function CreateJSONResponse(const RequestID: TValue): TJSONObject;
    class procedure AddRequestIDToResponse(Response: TJSONObject; const RequestID: TValue);
    class function ExecuteMethodCall(ManagerRegistry: IMCPManagerRegistry; const MethodName: string; Params: TJSONObject): TValue;
    class function CreateErrorResponse(const RequestID: TValue; ErrorCode: Integer; const ErrorMessage: string): string;
  public
    constructor Create(ManagerRegistry: IMCPManagerRegistry);
    function ProcessRequest(const RequestBody: string; const SessionID: string): string;
  end;

const
  JSONRPC_PARSE_ERROR = -32700;
  JSONRPC_INVALID_REQUEST = -32600;
  JSONRPC_METHOD_NOT_FOUND = -32601;
  JSONRPC_INVALID_PARAMS = -32602;
  JSONRPC_INTERNAL_ERROR = -32603;

implementation

{ TMCPJsonRpcProcessor }

constructor TMCPJsonRpcProcessor.Create(ManagerRegistry: IMCPManagerRegistry);
begin
  inherited Create;
  FManagerRegistry := ManagerRegistry;
end;

class function TMCPJsonRpcProcessor.ParseJSONRequest(const RequestBody: string): TJSONObject;
begin
  var ParsedValue := TJSONObject.ParseJSONValue(RequestBody);
  if not Assigned(ParsedValue) then
    raise Exception.Create('Invalid JSON');

  if not (ParsedValue is TJSONObject) then
  begin
    ParsedValue.Free;
    raise Exception.Create('JSON-RPC request must be an object');
  end;

  Result := ParsedValue as TJSONObject;
end;

class function TMCPJsonRpcProcessor.ExtractRequestID(JSONRequest: TJSONObject): TValue;
begin
  var IdValue := JSONRequest.GetValue('id');
  if not Assigned(IdValue) then
  begin
    Result := TValue.Empty;
    Exit;
  end;

  if IdValue is TJSONNumber then
    Result := TValue.From<Int64>((IdValue as TJSONNumber).AsInt64)
  else if IdValue is TJSONString then
    Result := TValue.From<string>((IdValue as TJSONString).Value)
  else
    Result := TValue.Empty;
end;

class function TMCPJsonRpcProcessor.CreateJSONResponse(const RequestID: TValue): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('jsonrpc', '2.0');
  AddRequestIDToResponse(Result, RequestID);
end;

class procedure TMCPJsonRpcProcessor.AddRequestIDToResponse(Response: TJSONObject; const RequestID: TValue);
begin
  if RequestID.IsEmpty then
  begin
    Response.AddPair('id', TJSONNull.Create);
    Exit;
  end;

  if RequestID.Kind in [tkString, tkUString, tkWString, tkLString] then
    Response.AddPair('id', RequestID.AsString)
  else if RequestID.Kind in [tkInteger, tkInt64] then
    Response.AddPair('id', TJSONNumber.Create(RequestID.AsInt64))
  else
    Response.AddPair('id', TJSONNull.Create);
end;

class function TMCPJsonRpcProcessor.ExecuteMethodCall(ManagerRegistry: IMCPManagerRegistry;
  const MethodName: string; Params: TJSONObject): TValue;
begin
  if not Assigned(ManagerRegistry) then
    raise Exception.Create('Manager registry not initialized');

  var Manager := ManagerRegistry.GetManagerForMethod(MethodName);
  if not Assigned(Manager) then
    raise Exception.CreateFmt('Method [%s] not found. The method does not exist or is not available.', [MethodName]);

  Result := Manager.ExecuteMethod(MethodName, Params);
end;

class function TMCPJsonRpcProcessor.CreateErrorResponse(const RequestID: TValue;
  ErrorCode: Integer; const ErrorMessage: string): string;
begin
  var JSONResponse := CreateJSONResponse(RequestID);
  try
    var ErrorObj := TJSONObject.Create;
    JSONResponse.AddPair('error', ErrorObj);
    ErrorObj.AddPair('code', TJSONNumber.Create(ErrorCode));
    ErrorObj.AddPair('message', ErrorMessage);
    Result := JSONResponse.ToJSON;
  finally
    JSONResponse.Free;
  end;
end;

function TMCPJsonRpcProcessor.ProcessRequest(const RequestBody: string; const SessionID: string): string;
begin
  Result := '';
  var JSONRequest: TJSONObject := nil;
  var JSONResponse: TJSONObject := nil;

  try
    try
      JSONRequest := ParseJSONRequest(RequestBody);

      var RequestID := ExtractRequestID(JSONRequest);

      var MethodValue := JSONRequest.GetValue('method');
      var MethodName := '';
      if Assigned(MethodValue) then
        MethodName := MethodValue.Value;

      // Notifications (requests without id) should not have a response
      if RequestID.IsEmpty then
      begin
        if MethodName = 'initialized' then
          TLogger.Info('MCP Initialized notification received')
        else
          TLogger.Info('Notification received: ' + MethodName);
        Exit;
      end;

      JSONResponse := CreateJSONResponse(RequestID);

      var ParamsValue := JSONRequest.GetValue('params');
      var Params: TJSONObject := nil;
      if Assigned(ParamsValue) and (ParamsValue is TJSONObject) then
        Params := ParamsValue as TJSONObject;

      var ExecuteResult := ExecuteMethodCall(FManagerRegistry, MethodName, Params);

      if not ExecuteResult.IsEmpty then
      begin
        if ExecuteResult.IsType<TJSONObject> then
          JSONResponse.AddPair('result', ExecuteResult.AsType<TJSONObject>)
        else if ExecuteResult.IsType<string> then
          JSONResponse.AddPair('result', ExecuteResult.AsString)
        else
          JSONResponse.AddPair('result', ExecuteResult.ToString);
      end;

      Result := JSONResponse.ToJSON;

    except
      on E: Exception do
      begin
        TLogger.Error('Error processing request: ' + E.Message);

        var ErrorCode := JSONRPC_INTERNAL_ERROR;
        if Pos('not found', E.Message) > 0 then
          ErrorCode := JSONRPC_METHOD_NOT_FOUND;

        Result := CreateErrorResponse(ExtractRequestID(JSONRequest), ErrorCode, E.Message);
      end;
    end;
  finally
    JSONRequest.Free;
    JSONResponse.Free;
  end;
end;

end.
