unit MCPServer.Tests.ServerStatus;

interface

uses
  DUnitX.TestFramework;

type
  TServerCounters = record
    RequestCount: Int64;
    ActiveConnections: Integer;
  end;

  [TestFixture]
  TServerStatusResourceTests = class
  private
    function ReadCounters: TServerCounters;
  public
    [Setup]
    procedure Setup;

    [Test]
    procedure Counters_StartAtZero;

    [Test]
    procedure Counters_AreExactUnderConcurrentUpdates;

    [Test]
    procedure ConnectionClosed_NeverGoesBelowZero;

    [Test]
    procedure Read_ProducesJsonWithStatusFields;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
  System.Threading,
  MCPServer.Resource.Base,
  MCPServer.Resource.Server;

const
  THREAD_COUNT = 8;
  ITERATIONS_PER_THREAD = 20000;

{ TServerStatusResourceTests }

procedure TServerStatusResourceTests.Setup;
begin
  TServerStatusResource.Initialize;
end;

function TServerStatusResourceTests.ReadCounters: TServerCounters;
begin
  Result := Default(TServerCounters);
  var Resource: IMCPResource := TServerStatusResource.Create;
  const Status = TJSONObject.ParseJSONValue(Resource.Read) as TJSONObject;
  try
    Assert.IsNotNull(Status, 'server://status must return a JSON object');
    Result.RequestCount := Status.GetValue<Int64>('requestcount');
    Result.ActiveConnections := Status.GetValue<Integer>('activeconnections');
  finally
    Status.Free;
  end;
end;

procedure TServerStatusResourceTests.Counters_StartAtZero;
begin
  const Counters = ReadCounters;

  Assert.AreEqual(Int64(0), Counters.RequestCount);
  Assert.AreEqual(0, Counters.ActiveConnections);
end;

procedure TServerStatusResourceTests.Counters_AreExactUnderConcurrentUpdates;
begin
  var Tasks: TArray<ITask>;
  SetLength(Tasks, THREAD_COUNT);
  for var I := 0 to High(Tasks) do
    Tasks[I] := TTask.Run(
      procedure
      begin
        for var J := 1 to ITERATIONS_PER_THREAD do
        begin
          TServerStatusResource.ConnectionOpened;
          TServerStatusResource.IncrementRequestCount;
          TServerStatusResource.ConnectionClosed;
        end;
      end);
  TTask.WaitForAll(Tasks);

  const Counters = ReadCounters;

  Assert.AreEqual(Int64(THREAD_COUNT) * ITERATIONS_PER_THREAD, Counters.RequestCount, 'lost request increments');
  Assert.AreEqual(0, Counters.ActiveConnections, 'every opened connection was closed');
end;

procedure TServerStatusResourceTests.ConnectionClosed_NeverGoesBelowZero;
begin
  TServerStatusResource.ConnectionClosed;
  TServerStatusResource.ConnectionClosed;
  TServerStatusResource.ConnectionOpened;
  TServerStatusResource.ConnectionClosed;
  TServerStatusResource.ConnectionClosed;

  const Counters = ReadCounters;

  Assert.AreEqual(0, Counters.ActiveConnections);
end;

procedure TServerStatusResourceTests.Read_ProducesJsonWithStatusFields;
begin
  var Resource: IMCPResource := TServerStatusResource.Create;
  Assert.AreEqual('server://status', Resource.URI);
  Assert.AreEqual('application/json', Resource.MimeType);

  var Status := TJSONObject.ParseJSONValue(Resource.Read) as TJSONObject;
  try
    Assert.IsNotNull(Status);
    Assert.AreEqual('running', Status.GetValue<string>('status'));
    Assert.IsNotNull(Status.GetValue('uptime'));
    Assert.IsNotNull(Status.GetValue('memoryused'));
  finally
    Status.Free;
  end;
end;

end.
