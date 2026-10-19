unit MCPServer.Tests.Support;

interface

uses
  System.SysUtils,
  System.SyncObjs,
  System.JSON;

type
  TMCPTestMeta = record
  public const
    MODERN_FIELDS = '{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}';
    MODERN_MEMBER = '"_meta":' + MODERN_FIELDS;
  end;

  TMCPTestJson = record
  public
    class function ParseObject(const Text: string): TJSONObject; static;
  end;

  TMCPTestWait = record
  public const
    DEFAULT_TIMEOUT_MS = 2000;
    STEP_MS = 5;
  public
    class function UntilTrue(const Condition: TFunc<Boolean>;
      const TimeoutMs: Cardinal = DEFAULT_TIMEOUT_MS): Boolean; static;
  end;

  TMCPTestLogWatch = class
  strict private
    FFragment: string;
    FMatchCount: Integer;
    FMatched: TEvent;
    procedure Observe(const Message: string);

  public
    constructor Create(const Fragment: string);
    destructor Destroy; override;

    function WaitForMatch(const TimeoutMs: Cardinal = TMCPTestWait.DEFAULT_TIMEOUT_MS): Boolean;
    function MatchCount: Integer;
  end;

implementation

uses
  System.Classes,
  DUnitX.TestFramework,
  MCPServer.Logger;

{ TMCPTestJson }

class function TMCPTestJson.ParseObject(const Text: string): TJSONObject;
begin
  const Value = TJSONObject.ParseJSONValue(Text);
  const IsObject = (Value is TJSONObject);
  if not IsObject then
  begin
    Value.Free;
    Assert.Fail('expected a JSON object but got: ' + Text);
  end;
  Result := TJSONObject(Value);
end;

{ TMCPTestWait }

class function TMCPTestWait.UntilTrue(const Condition: TFunc<Boolean>;
  const TimeoutMs: Cardinal): Boolean;
begin
  const Deadline = TThread.GetTickCount64 + TimeoutMs;
  Result := Condition;
  while not Result and (TThread.GetTickCount64 < Deadline) do
  begin
    TThread.Sleep(STEP_MS);
    Result := Condition;
  end;
end;

{ TMCPTestLogWatch }

constructor TMCPTestLogWatch.Create(const Fragment: string);
begin
  inherited Create;
  FFragment := Fragment;
  FMatched  := TEvent.Create(nil, True, False, '');
  TLogger.OnLogMessage := Observe;
end;

destructor TMCPTestLogWatch.Destroy;
begin
  TLogger.OnLogMessage := nil;
  FMatched.Free;
  inherited;
end;

function TMCPTestLogWatch.WaitForMatch(const TimeoutMs: Cardinal): Boolean;
begin
  const Outcome = FMatched.WaitFor(TimeoutMs);
  Result := (Outcome = TWaitResult.wrSignaled);
end;

function TMCPTestLogWatch.MatchCount: Integer;
begin
  Result := AtomicCmpExchange(FMatchCount, 0, 0);
end;

procedure TMCPTestLogWatch.Observe(const Message: string);
begin
  const IsMatch = Message.Contains(FFragment);
  if not IsMatch then
    Exit;

  AtomicIncrement(FMatchCount);
  FMatched.SetEvent;
end;

end.
