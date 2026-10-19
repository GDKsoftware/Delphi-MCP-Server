unit MCPServer.Tests.StdioDoubles;

interface

uses
  System.SysUtils,
  System.Rtti,
  System.SyncObjs,
  System.JSON,
  MCPServer.Types,
  MCPServer.Tool.Base;

const
  STUBBORN_TOOL_NAME        = 'test_stubborn_tool';
  SELF_CANCELLING_TOOL_NAME = 'test_self_cancelling_tool';
  LATE_ANSWER_LOG_FRAGMENT  = 'was answered or cancelled already';

type
  IStubbornGate = interface
    ['{989D9C0D-1889-4F7E-A59B-E1251FD5700E}']
    procedure Pass;
    procedure Release;
    function WaitUntilReturned: Boolean;
  end;

  TStubbornGate = class(TInterfacedObject, IStubbornGate)
  strict private
    const WAIT_MS = 10000;
    var
      FReleased: TEvent;
      FReturned: TEvent;

  public
    constructor Create;
    destructor Destroy; override;

    procedure Pass;
    procedure Release;
    function WaitUntilReturned: Boolean;
  end;

  TStubbornTool = class(TMCPToolBase)
  strict private
    FGate: IStubbornGate;

  protected
    function BuildSchema: TJSONObject; override;
    function DoExecute(const Arguments: TJSONObject): TValue; override;

  public
    constructor Create(const Gate: IStubbornGate); reintroduce;
  end;

  TSelfCancellingTool = class(TMCPToolBase)
  protected
    function BuildSchema: TJSONObject; override;
    function DoExecute(const Arguments: TJSONObject): TValue; override;

  public
    constructor Create; override;
  end;

  TStubbornListenManager = class(TInterfacedObject, IMCPCapabilityManager)
  strict private
    FGate: IStubbornGate;

  public
    constructor Create(const Gate: IStubbornGate);

    function GetCapabilityName: string;
    function HandlesMethod(const Method: string): Boolean;
    function ExecuteMethod(const Method: string; const Params: TJSONObject): TValue;
  end;

implementation

uses
  MCPServer.Errors;

const
  EMPTY_OBJECT_SCHEMA = '{"type":"object","properties":{},"additionalProperties":false}';

{ TStubbornGate }

constructor TStubbornGate.Create;
begin
  inherited Create;
  FReleased := TEvent.Create(nil, True, False, '');
  FReturned := TEvent.Create(nil, True, False, '');
end;

destructor TStubbornGate.Destroy;
begin
  FReturned.Free;
  FReleased.Free;
  inherited;
end;

procedure TStubbornGate.Pass;
begin
  FReleased.WaitFor(WAIT_MS);
  FReturned.SetEvent;
end;

procedure TStubbornGate.Release;
begin
  FReleased.SetEvent;
end;

function TStubbornGate.WaitUntilReturned: Boolean;
begin
  const Outcome = FReturned.WaitFor(WAIT_MS);
  Result := (Outcome = TWaitResult.wrSignaled);
end;

{ TStubbornTool }

constructor TStubbornTool.Create(const Gate: IStubbornGate);
begin
  inherited Create;
  FName        := STUBBORN_TOOL_NAME;
  FDescription := 'A tool that never looks at its cancellation';
  FGate        := Gate;
end;

function TStubbornTool.BuildSchema: TJSONObject;
begin
  Result := TJSONObject.ParseJSONValue(EMPTY_OBJECT_SCHEMA) as TJSONObject;
end;

function TStubbornTool.DoExecute(const Arguments: TJSONObject): TValue;
begin
  FGate.Pass;
  Result := TValue.From<string>('finished late');
end;

{ TSelfCancellingTool }

constructor TSelfCancellingTool.Create;
begin
  inherited Create;
  FName        := SELF_CANCELLING_TOOL_NAME;
  FDescription := 'A tool that reports itself cancelled while nobody cancelled it';
end;

function TSelfCancellingTool.BuildSchema: TJSONObject;
begin
  Result := TJSONObject.ParseJSONValue(EMPTY_OBJECT_SCHEMA) as TJSONObject;
end;

function TSelfCancellingTool.DoExecute(const Arguments: TJSONObject): TValue;
begin
  raise EMCPRequestCancelled.Create('The tool gave up on its own');
end;

{ TStubbornListenManager }

constructor TStubbornListenManager.Create(const Gate: IStubbornGate);
begin
  inherited Create;
  FGate := Gate;
end;

function TStubbornListenManager.GetCapabilityName: string;
begin
  Result := 'stubborn subscriptions';
end;

function TStubbornListenManager.HandlesMethod(const Method: string): Boolean;
begin
  Result := (Method = MCP_METHOD_SUBSCRIPTIONS_LISTEN);
end;

function TStubbornListenManager.ExecuteMethod(const Method: string; const Params: TJSONObject): TValue;
begin
  FGate.Pass;
  Result := TValue.From<TJSONObject>(TJSONObject.Create);
end;

end.
