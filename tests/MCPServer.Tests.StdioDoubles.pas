unit MCPServer.Tests.StdioDoubles;

interface

uses
  System.SysUtils,
  System.Rtti,
  System.SyncObjs,
  System.JSON,
  MCPServer.Types,
  MCPServer.Settings,
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

  TArgumentlessTool = class(TMCPToolBase)
  protected
    function BuildSchema: TJSONObject; override;
  end;

  TStubbornTool = class(TArgumentlessTool)
  strict private
    FGate: IStubbornGate;

  protected
    function DoExecute(const Arguments: TJSONObject): TValue; override;
    function Finish: TValue; virtual;

  public
    constructor Create(const Gate: IStubbornGate); reintroduce;
  end;

  TStubbornAskingTool = class(TStubbornTool)
  protected
    function Finish: TValue; override;
  end;

  TSelfCancellingTool = class(TArgumentlessTool)
  protected
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

  TPoisonedSettings = class(TMCPSettings)
  strict private
    const POISON = $FF;
    class var FPoisonedBlocks: TArray<Pointer>;

  public
    procedure FreeInstance; override;
    class procedure ReleasePoisonedMemory; static;
  end;

implementation

uses
  MCPServer.Errors,
  MCPServer.Mrtr;

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

{ TArgumentlessTool }

function TArgumentlessTool.BuildSchema: TJSONObject;
begin
  Result := TJSONObject.ParseJSONValue(EMPTY_OBJECT_SCHEMA) as TJSONObject;
end;

{ TStubbornTool }

constructor TStubbornTool.Create(const Gate: IStubbornGate);
begin
  inherited Create;
  FName        := STUBBORN_TOOL_NAME;
  FDescription := 'A tool that never looks at its cancellation';
  FGate        := Gate;
end;

function TStubbornTool.DoExecute(const Arguments: TJSONObject): TValue;
begin
  FGate.Pass;
  Result := Finish;
end;

function TStubbornTool.Finish: TValue;
begin
  Result := TValue.From<string>('finished late');
end;

{ TStubbornAskingTool }

function TStubbornAskingTool.Finish: TValue;
begin
  const Requests = TMCPInputRequests.Create;
  const State = TJSONObject.Create;
  raise EMCPInputRequired.Create(Requests, State);
end;

{ TSelfCancellingTool }

constructor TSelfCancellingTool.Create;
begin
  inherited Create;
  FName        := SELF_CANCELLING_TOOL_NAME;
  FDescription := 'A tool that reports itself cancelled while nobody cancelled it';
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

{ TPoisonedSettings }

procedure TPoisonedSettings.FreeInstance;
begin
  CleanupInstance;
  {$WARN UNSAFE_CAST OFF}
  const Block = Pointer(Self);
  {$WARN UNSAFE_CAST ON}
  FillChar(Block^, InstanceSize, POISON);
  FPoisonedBlocks := FPoisonedBlocks + [Block];
end;

class procedure TPoisonedSettings.ReleasePoisonedMemory;
begin
  for var Block in FPoisonedBlocks do
  begin
    FreeMem(Block);
  end;
  FPoisonedBlocks := nil;
end;

end.
