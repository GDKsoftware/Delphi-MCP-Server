unit MCPServer.Tests.ServerStatus;

interface

uses
  DUnitX.TestFramework;

type
  /// The counters behind server://status are updated from every Indy
  /// connection thread; these tests guard the atomic implementation.
  [TestFixture]
  TServerStatusResourceTests = class
  private
    procedure ReadCounters(out RequestCount: Int64; out ActiveConnections: Integer);
  public
    [Setup]
    procedure Setup;

    [Test] procedure Counters_StartAtZero;
    [Test] procedure Counters_AreExactUnderConcurrentUpdates;
    [Test] procedure ConnectionClosed_NeverGoesBelowZero;
    [Test] procedure Read_ProducesJsonWithStatusFields;
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

procedure TServerStatusResourceTests.ReadCounters(out RequestCount: Int64; out ActiveConnections: Integer);
begin
  var Resource: IMCPResource := TServerStatusResource.Create;
  var Status := TJSONObject.ParseJSONValue(Resource.Read) as TJSONObject;
  try
    Assert.IsNotNull(Status, 'server://status must return a JSON object');
    RequestCount := Status.GetValue<Int64>('requestcount');
    ActiveConnections := Status.GetValue<Integer>('activeconnections');
  finally
    Status.Free;
  end;
end;

procedure TServerStatusResourceTests.Counters_StartAtZero;
begin
  var RequestCount: Int64;
  var ActiveConnections: Integer;
  ReadCounters(RequestCount, ActiveConnections);

  Assert.AreEqual(Int64(0), RequestCount);
  Assert.AreEqual(0, ActiveConnections);
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

  var RequestCount: Int64;
  var ActiveConnections: Integer;
  ReadCounters(RequestCount, ActiveConnections);

  Assert.AreEqual(Int64(THREAD_COUNT) * ITERATIONS_PER_THREAD, RequestCount, 'lost request increments');
  Assert.AreEqual(0, ActiveConnections, 'every opened connection was closed');
end;

procedure TServerStatusResourceTests.ConnectionClosed_NeverGoesBelowZero;
begin
  TServerStatusResource.ConnectionClosed;
  TServerStatusResource.ConnectionClosed;
  TServerStatusResource.ConnectionOpened;
  TServerStatusResource.ConnectionClosed;
  TServerStatusResource.ConnectionClosed;

  var RequestCount: Int64;
  var ActiveConnections: Integer;
  ReadCounters(RequestCount, ActiveConnections);

  Assert.AreEqual(0, ActiveConnections);
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

initialization
  TDUnitX.RegisterTestFixture(TServerStatusResourceTests);

end.
