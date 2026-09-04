unit MCPServer.HttpStream;

interface

uses
  System.SysUtils,
  System.SyncObjs,
  IdContext,
  IdCustomHTTPServer,
  MCPServer.Types;

type
  TMCPHttpResponseStream = class(TInterfacedObject, IMCPMessageSink, IMCPRequestTracker, IMCPKeepAlive)
  public
    const MEDIA_TYPE_EVENT_STREAM = 'text/event-stream';
  strict private
    FConnection: TIdContext;
    FResponseInfo: TIdHTTPResponseInfo;
    FLock: TCriticalSection;
    FOpened: Boolean;
    FBroken: Boolean;
    FRequest: IMCPRequestContext;
    procedure OpenStream;
    procedure WriteChunk(const Text: string);
    procedure WriteEvent(const Json: string);
    procedure MarkBroken(const Reason: string);
  public
    constructor Create(const Connection: TIdContext; const ResponseInfo: TIdHTTPResponseInfo);
    destructor Destroy; override;

    procedure Send(const Json: string);
    procedure KeepAlive;
    procedure Track(const Context: IMCPRequestContext);
    procedure Untrack(const Context: IMCPRequestContext);
    function TryCancel(const RequestId: TMCPRequestId; const Reason: string): Boolean;
    procedure Finish(const FinalJson: string);

    class function EventText(const Json: string): string; static;

    property Opened: Boolean read FOpened;
    property Broken: Boolean read FBroken;
  end;

implementation

uses
  IdGlobal,
  MCPServer.Errors,
  MCPServer.Logger;

const
  SSE_EVENT_PREFIX = 'event: message'#10'data: ';
  SSE_EVENT_SUFFIX = #10#10;
  CHUNK_TERMINATOR = '0'#13#10#13#10;
  SSE_KEEP_ALIVE_COMMENT = ': keep-alive'#10#10;
  CHARSET_UTF8 = 'utf-8';
  HTTP_STATUS_OK = 200;

{ TMCPHttpResponseStream }

constructor TMCPHttpResponseStream.Create(const Connection: TIdContext; const ResponseInfo: TIdHTTPResponseInfo);
begin
  inherited Create;
  FConnection := Connection;
  FResponseInfo := ResponseInfo;
  FLock := TCriticalSection.Create;
end;

destructor TMCPHttpResponseStream.Destroy;
begin
  FLock.Free;
  inherited;
end;

class function TMCPHttpResponseStream.EventText(const Json: string): string;
begin
  Result := SSE_EVENT_PREFIX + Json + SSE_EVENT_SUFFIX;
end;

procedure TMCPHttpResponseStream.OpenStream;
begin
  FResponseInfo.ResponseNo := HTTP_STATUS_OK;
  FResponseInfo.ContentType := MEDIA_TYPE_EVENT_STREAM;
  FResponseInfo.CharSet := CHARSET_UTF8;
  FResponseInfo.ContentLength := -1;
  FResponseInfo.TransferEncoding := 'chunked';
  FResponseInfo.CustomHeaders.Values['Cache-Control'] := 'no-cache';
  FResponseInfo.CustomHeaders.Values['X-Accel-Buffering'] := 'no';
  FResponseInfo.WriteHeader;
  FOpened := True;
end;

procedure TMCPHttpResponseStream.WriteChunk(const Text: string);
begin
  var Bytes := TEncoding.UTF8.GetBytes(Text);
  var IOHandler := FConnection.Connection.IOHandler;
  IOHandler.WriteLn(IntToHex(Length(Bytes), 1));
  IOHandler.Write(TIdBytes(Bytes));
  IOHandler.WriteLn;
end;

procedure TMCPHttpResponseStream.WriteEvent(const Json: string);
begin
  WriteChunk(EventText(Json));
end;

procedure TMCPHttpResponseStream.MarkBroken(const Reason: string);
begin
  FBroken := True;
  TLogger.Info(Format('HTTP response stream closed by the client: %s', [Reason]));
  var Request := FRequest;
  if Assigned(Request) then
    Request.Cancel;
end;

procedure TMCPHttpResponseStream.Send(const Json: string);
begin
  FLock.Enter;
  try
    if FBroken then
      Exit;
    try
      if not FOpened then
        OpenStream;
      WriteEvent(Json);
    except
      on E: Exception do
        MarkBroken(E.Message);
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TMCPHttpResponseStream.KeepAlive;
begin
  FLock.Enter;
  try
    if FBroken or not FOpened then
      Exit;
    try
      if not FConnection.Connection.Connected then
        raise EMCPTransportError.Create('connection closed');
      WriteChunk(SSE_KEEP_ALIVE_COMMENT);
    except
      on E: Exception do
        MarkBroken(E.Message);
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TMCPHttpResponseStream.Track(const Context: IMCPRequestContext);
begin
  FLock.Enter;
  try
    FRequest := Context;
  finally
    FLock.Leave;
  end;
end;

procedure TMCPHttpResponseStream.Untrack(const Context: IMCPRequestContext);
begin
  FLock.Enter;
  try
    FRequest := nil;
  finally
    FLock.Leave;
  end;
end;

function TMCPHttpResponseStream.TryCancel(const RequestId: TMCPRequestId; const Reason: string): Boolean;
begin
  Result := False;
end;

procedure TMCPHttpResponseStream.Finish(const FinalJson: string);
begin
  FLock.Enter;
  try
    if not FOpened or FBroken then
      Exit;
    try
      if FinalJson <> '' then
        WriteEvent(FinalJson);
      FConnection.Connection.IOHandler.Write(CHUNK_TERMINATOR);
    except
      on E: Exception do
        MarkBroken(E.Message);
    end;
  finally
    FLock.Leave;
  end;
end;

end.
