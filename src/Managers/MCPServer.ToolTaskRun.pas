unit MCPServer.ToolTaskRun;

interface

uses
  System.SysUtils,
  System.JSON,
  MCPServer.Types,
  MCPServer.Mrtr,
  MCPServer.Task.Types;

type
  TMCPToolExecution = reference to function(const Arguments: TJSONObject): TJSONObject;

  IMCPToolTaskRun = interface
    ['{5C7E9A1B-3D5F-4B7A-9C1E-7A9C1E3B5D68}']
    procedure Execute(const Task: IMCPTaskHandle);
    procedure Resume(const Task: IMCPTaskHandle; const Answers: TJSONObject);
  end;

  TMCPToolTaskRun = class(TInterfacedObject, IMCPToolTaskRun)
  private
    FService: IMCPTaskService;
    FOrigin: IMCPRequestContext;
    FArguments: TJSONObject;
    FExecution: TMCPToolExecution;
    FInputResponses: TJSONObject;
    FRequestState: TJSONObject;
    procedure Complete(const RunContext: IMCPRequestContext; const Task: IMCPTaskHandle);
    procedure AwaitInput(const Required: EMCPInputRequired; const Task: IMCPTaskHandle);
    procedure AddAnswers(const Answers: TJSONObject);
    function RequestStateOrNil: TJSONObject;
    class procedure ReplaceContents(const Target, Source: TJSONObject); static;

  public
    constructor Create(const Service: IMCPTaskService; const Origin: IMCPRequestContext;
                       const Arguments: TJSONObject; const Execution: TMCPToolExecution);
    destructor Destroy; override;

    procedure Execute(const Task: IMCPTaskHandle);
    procedure Resume(const Task: IMCPTaskHandle; const Answers: TJSONObject);
  end;

implementation

uses
  System.Generics.Collections,
  MCPServer.RequestContext;

{ TMCPToolTaskRun }

constructor TMCPToolTaskRun.Create(const Service: IMCPTaskService; const Origin: IMCPRequestContext;
                                   const Arguments: TJSONObject; const Execution: TMCPToolExecution);
begin
  inherited Create;
  FService := Service;
  FOrigin := Origin;
  FArguments := Arguments;
  FExecution := Execution;
  FInputResponses := TJSONObject.Create;
  FRequestState := TJSONObject.Create;
end;

destructor TMCPToolTaskRun.Destroy;
begin
  FArguments.Free;
  FInputResponses.Free;
  FRequestState.Free;
  inherited;
end;

procedure TMCPToolTaskRun.Execute(const Task: IMCPTaskHandle);
begin
  if Task.IsCancelled then
    Exit;

  const State = RequestStateOrNil;
  const RunContext = TMCPRequestContext.ForTask(FOrigin, Task.TaskId, FInputResponses, State);
  Task.BindCancellation(RunContext);
  try
    Complete(RunContext, Task);
  except
    on E: EMCPInputRequired do
      AwaitInput(E, Task);
  end;
end;

procedure TMCPToolTaskRun.Resume(const Task: IMCPTaskHandle; const Answers: TJSONObject);
begin
  try
    AddAnswers(Answers);
  finally
    Answers.Free;
  end;

  const Run: IMCPToolTaskRun = Self;
  FService.ResumeTask(Task,
    procedure(ResumedTask: IMCPTaskHandle)
    begin
      Run.Execute(ResumedTask);
    end);
end;

procedure TMCPToolTaskRun.Complete(const RunContext: IMCPRequestContext; const Task: IMCPTaskHandle);
begin
  const Previous = TMCPRequestContext.SetCurrent(RunContext);
  try
    const ToolResult = FExecution(FArguments);
    try
      Task.Complete(ToolResult);
    finally
      ToolResult.Free;
    end;
  finally
    TMCPRequestContext.SetCurrent(Previous);
  end;
end;

procedure TMCPToolTaskRun.AwaitInput(const Required: EMCPInputRequired; const Task: IMCPTaskHandle);
begin
  Required.Requests.RequireClientCapabilities(FOrigin);
  ReplaceContents(FRequestState, Required.State);

  const Run: IMCPToolTaskRun = Self;
  const Requests = Required.Requests.ToJson;
  try
    Task.RequestInput(Requests,
      procedure(Answers: TJSONObject)
      begin
        Run.Resume(Task, Answers);
      end);
  finally
    Requests.Free;
  end;
end;

procedure TMCPToolTaskRun.AddAnswers(const Answers: TJSONObject);
begin
  for var Answer in Answers do
  begin
    const AnswerCopy = TJSONPair(Answer.Clone);
    FInputResponses.AddPair(AnswerCopy);
  end;
end;

function TMCPToolTaskRun.RequestStateOrNil: TJSONObject;
begin
  const IsEmpty = (FRequestState.Count = 0);
  if IsEmpty then
    Result := nil
  else
    Result := FRequestState;
end;

class procedure TMCPToolTaskRun.ReplaceContents(const Target, Source: TJSONObject);
begin
  while Target.Count > 0 do
  begin
    const Key = Target.Pairs[0].JsonString.Value;
    const Removed = Target.RemovePair(Key);
    Removed.Free;
  end;

  if not Assigned(Source) then
    Exit;

  for var Pair in Source do
  begin
    const PairCopy = TJSONPair(Pair.Clone);
    Target.AddPair(PairCopy);
  end;
end;

end.
