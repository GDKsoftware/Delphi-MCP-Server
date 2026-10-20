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
  public const
    FIRST_TEXT_PATH = 'result.content[0].text';
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
    FLock: TCriticalSection;
    FLines: TArray<string>;
    procedure Observe(const Message: string);

  public
    constructor Create;
    destructor Destroy; override;

    function CountOf(const Fragment: string): Integer;
    function WaitFor(const Fragment: string; const TimeoutMs: Cardinal = TMCPTestWait.DEFAULT_TIMEOUT_MS): Boolean;
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

constructor TMCPTestLogWatch.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  TLogger.OnLogMessage := Observe;
end;

destructor TMCPTestLogWatch.Destroy;
begin
  TLogger.OnLogMessage := nil;
  FLock.Free;
  inherited;
end;

function TMCPTestLogWatch.CountOf(const Fragment: string): Integer;
begin
  Result := 0;
  FLock.Enter;
  try
    for var Line in FLines do
    begin
      const IsMatch = Line.Contains(Fragment);
      if IsMatch then
        Inc(Result);
    end;
  finally
    FLock.Leave;
  end;
end;

function TMCPTestLogWatch.WaitFor(const Fragment: string; const TimeoutMs: Cardinal): Boolean;
begin
  Result := TMCPTestWait.UntilTrue(
    function: Boolean
    begin
      const Matches = CountOf(Fragment);
      Result := (Matches > 0);
    end,
    TimeoutMs);
end;

procedure TMCPTestLogWatch.Observe(const Message: string);
begin
  FLock.Enter;
  try
    FLines := FLines + [Message];
  finally
    FLock.Leave;
  end;
end;

end.
