unit MCPServer.Tests.Golden;

interface

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  System.JSON;

type
  EGoldenError = class(Exception);

  TGoldenFiles = class
  public
    const RECORD_ENVIRONMENT_VARIABLE = 'MCP_GOLDEN_RECORD';
    const GOLDEN_DIR_ENVIRONMENT_VARIABLE = 'MCP_GOLDEN_DIR';
    const GOLDEN_DIRECTORY_NAME = 'golden';
    const LEGACY_SUITE = 'legacy';
    const MODERN_SUITE = 'modern';

    class function GoldenRoot: string;
    class function TestsRoot: string;
    class function CaseFile(const Suite, CaseName: string): string;
    class function RecordMode: Boolean;
  end;

  TGoldenNormalizer = class
  private
    class function ReplaceIndexes(const Segment: string): string;
    class function SegmentMatches(const Segment, Pattern: string): Boolean;
    class function ShapeOfString(const Value: string): TJSONValue;
    class procedure NormalizeObject(const Obj: TJSONObject; const Path: string;
      const MaskPaths, ShapePaths: TArray<string>);
    class procedure NormalizeArray(const Arr: TJSONArray; const Path: string;
      const MaskPaths, ShapePaths: TArray<string>);
  public
    const MASK_PLACEHOLDER = '<masked>';

    class function PathMatches(const Path, Pattern: string): Boolean;
    class function MatchesAny(const Path: string; const Patterns: TArray<string>): Boolean;
    class function Shape(const Value: TJSONValue): TJSONValue;
    class procedure Normalize(const Root: TJSONValue; const MaskPaths, ShapePaths: TArray<string>);
  end;

  TGoldenCase = class
  private
    FFileName: string;
    FDocument: TJSONObject;
    function ReadStringArray(const Name: string): TArray<string>;
    function GetRequestBody: string;
    function GetWorkingDirectory: string;
    function GetHasExpected: Boolean;
    procedure RemoveExpected;
    procedure Save;
  public
    const INDENTATION = 2;

    constructor Create(const AFileName: string);
    destructor Destroy; override;

    function NormalizeResponse(const ResponseBody: string): string;
    function ExpectedText: string;
    procedure RecordExpected(const ResponseBody: string);

    property FileName: string read FFileName;
    property RequestBody: string read GetRequestBody;
    property WorkingDirectory: string read GetWorkingDirectory;
    property HasExpected: Boolean read GetHasExpected;
  end;

  TGoldenProcessFunc = reference to function(const RequestBody: string): string;

  TGoldenRunner = class
  public
    class procedure Check(const Suite, CaseName: string; const Process: TGoldenProcessFunc);
  end;

implementation

uses
  System.IOUtils;

const
  MAX_PARENT_LEVELS = 6;

{ TGoldenFiles }

class function TGoldenFiles.GoldenRoot: string;
begin
  Result := GetEnvironmentVariable(GOLDEN_DIR_ENVIRONMENT_VARIABLE);
  if Result <> '' then
    Exit(TPath.GetFullPath(Result));

  var Dir := ExtractFilePath(ParamStr(0));
  for var Level := 0 to MAX_PARENT_LEVELS do
  begin
    var Candidate := TPath.Combine(Dir, GOLDEN_DIRECTORY_NAME);
    if TDirectory.Exists(TPath.Combine(Candidate, LEGACY_SUITE)) then
      Exit(Candidate);
    Dir := TPath.GetFullPath(TPath.Combine(Dir, '..'));
  end;

  raise EGoldenError.CreateFmt('Golden directory not found above %s (set %s)',
    [ExtractFilePath(ParamStr(0)), GOLDEN_DIR_ENVIRONMENT_VARIABLE]);
end;

class function TGoldenFiles.TestsRoot: string;
begin
  Result := TPath.GetFullPath(TPath.Combine(GoldenRoot, '..'));
end;

class function TGoldenFiles.CaseFile(const Suite, CaseName: string): string;
begin
  Result := TPath.Combine(TPath.Combine(GoldenRoot, Suite), CaseName + '.json');
end;

class function TGoldenFiles.RecordMode: Boolean;
begin
  Result := GetEnvironmentVariable(RECORD_ENVIRONMENT_VARIABLE) = '1';
end;

{ TGoldenNormalizer }

class function TGoldenNormalizer.ReplaceIndexes(const Segment: string): string;
begin
  Result := '';
  var I := 1;
  while I <= Length(Segment) do
  begin
    if Segment[I] = '[' then
    begin
      Result := Result + '[*';
      Inc(I);
      while (I <= Length(Segment)) and CharInSet(Segment[I], ['0'..'9']) do
        Inc(I);
    end
    else
    begin
      Result := Result + Segment[I];
      Inc(I);
    end;
  end;
end;

class function TGoldenNormalizer.SegmentMatches(const Segment, Pattern: string): Boolean;
begin
  Result := Segment = Pattern;
  if (not Result) and Pattern.Contains('[*]') then
    Result := ReplaceIndexes(Segment) = Pattern;
end;

class function TGoldenNormalizer.PathMatches(const Path, Pattern: string): Boolean;
begin
  var PathParts := Path.Split(['.']);
  var PatternParts := Pattern.Split(['.']);
  if Length(PathParts) <> Length(PatternParts) then
    Exit(False);

  for var I := 0 to High(PathParts) do
    if not SegmentMatches(PathParts[I], PatternParts[I]) then
      Exit(False);

  Result := True;
end;

class function TGoldenNormalizer.MatchesAny(const Path: string; const Patterns: TArray<string>): Boolean;
begin
  for var Pattern in Patterns do
    if PathMatches(Path, Pattern) then
      Exit(True);
  Result := False;
end;

class function TGoldenNormalizer.ShapeOfString(const Value: string): TJSONValue;
begin
  var Parsed := TJSONObject.ParseJSONValue(Value);
  try
    if (Parsed is TJSONObject) or (Parsed is TJSONArray) then
      Result := Shape(Parsed)
    else
      Result := TJSONString.Create('string');
  finally
    Parsed.Free;
  end;
end;

class function TGoldenNormalizer.Shape(const Value: TJSONValue): TJSONValue;
begin
  if Value is TJSONObject then
  begin
    var Obj := TJSONObject.Create;
    for var Pair in TJSONObject(Value) do
      Obj.AddPair(Pair.JsonString.Value, Shape(Pair.JsonValue));
    Result := Obj;
  end
  else if Value is TJSONArray then
  begin
    var Arr := TJSONArray.Create;
    for var Item in TJSONArray(Value) do
      Arr.AddElement(Shape(Item));
    Result := Arr;
  end
  else if Value is TJSONNull then
    Result := TJSONString.Create('null')
  else if Value is TJSONBool then
    Result := TJSONString.Create('boolean')
  else if Value is TJSONNumber then
    Result := TJSONString.Create('number')
  else if Value is TJSONString then
    Result := ShapeOfString(TJSONString(Value).Value)
  else
    Result := TJSONString.Create(Value.ClassName);
end;

class procedure TGoldenNormalizer.NormalizeObject(const Obj: TJSONObject; const Path: string;
  const MaskPaths, ShapePaths: TArray<string>);
begin
  for var Pair in Obj do
  begin
    var ChildPath := Pair.JsonString.Value;
    if Path <> '' then
      ChildPath := Path + '.' + ChildPath;

    if MatchesAny(ChildPath, MaskPaths) then
      Pair.JsonValue := TJSONString.Create(MASK_PLACEHOLDER)
    else if MatchesAny(ChildPath, ShapePaths) then
      Pair.JsonValue := Shape(Pair.JsonValue)
    else if Pair.JsonValue is TJSONObject then
      NormalizeObject(TJSONObject(Pair.JsonValue), ChildPath, MaskPaths, ShapePaths)
    else if Pair.JsonValue is TJSONArray then
      NormalizeArray(TJSONArray(Pair.JsonValue), ChildPath, MaskPaths, ShapePaths);
  end;
end;

class procedure TGoldenNormalizer.NormalizeArray(const Arr: TJSONArray; const Path: string;
  const MaskPaths, ShapePaths: TArray<string>);
begin
  for var I := 0 to Arr.Count - 1 do
  begin
    var ChildPath := Path + '[' + I.ToString + ']';
    var Item := Arr.Items[I];
    if Item is TJSONObject then
      NormalizeObject(TJSONObject(Item), ChildPath, MaskPaths, ShapePaths)
    else if Item is TJSONArray then
      NormalizeArray(TJSONArray(Item), ChildPath, MaskPaths, ShapePaths);
  end;
end;

class procedure TGoldenNormalizer.Normalize(const Root: TJSONValue; const MaskPaths, ShapePaths: TArray<string>);
begin
  if Root is TJSONObject then
    NormalizeObject(TJSONObject(Root), '', MaskPaths, ShapePaths)
  else if Root is TJSONArray then
    NormalizeArray(TJSONArray(Root), '', MaskPaths, ShapePaths);
end;

{ TGoldenCase }

constructor TGoldenCase.Create(const AFileName: string);
begin
  inherited Create;
  FFileName := AFileName;

  if not TFile.Exists(FFileName) then
    raise EGoldenError.CreateFmt('Golden file not found: %s', [FFileName]);

  var Parsed := TJSONObject.ParseJSONValue(TFile.ReadAllText(FFileName, TEncoding.UTF8));
  if not (Parsed is TJSONObject) then
  begin
    Parsed.Free;
    raise EGoldenError.CreateFmt('Golden file is not a JSON object: %s', [FFileName]);
  end;
  FDocument := TJSONObject(Parsed);
end;

destructor TGoldenCase.Destroy;
begin
  FDocument.Free;
  inherited;
end;

function TGoldenCase.ReadStringArray(const Name: string): TArray<string>;
begin
  Result := nil;
  var Value := FDocument.GetValue(Name);
  if not (Value is TJSONArray) then
    Exit;

  var Arr := TJSONArray(Value);
  SetLength(Result, Arr.Count);
  for var I := 0 to Arr.Count - 1 do
    Result[I] := Arr.Items[I].Value;
end;

function TGoldenCase.GetRequestBody: string;
begin
  var Request := FDocument.GetValue('request');
  if Assigned(Request) then
    Exit(Request.ToJSON);

  var RequestText := FDocument.GetValue('requestText');
  if Assigned(RequestText) then
    Exit(RequestText.Value);

  raise EGoldenError.CreateFmt('Golden file has neither "request" nor "requestText": %s', [FFileName]);
end;

function TGoldenCase.GetWorkingDirectory: string;
begin
  var Value := FDocument.GetValue('workingDirectory');
  if Assigned(Value) and (Value.Value <> '') then
    Result := TPath.GetFullPath(TPath.Combine(TGoldenFiles.TestsRoot, Value.Value))
  else
    Result := '';
end;

function TGoldenCase.GetHasExpected: Boolean;
begin
  Result := Assigned(FDocument.GetValue('expected')) or Assigned(FDocument.GetValue('expectedText'));
end;

function TGoldenCase.NormalizeResponse(const ResponseBody: string): string;
begin
  if ResponseBody.Trim = '' then
    Exit(ResponseBody);

  var Parsed := TJSONObject.ParseJSONValue(ResponseBody);
  if not Assigned(Parsed) then
    Exit(ResponseBody);

  try
    TGoldenNormalizer.Normalize(Parsed, ReadStringArray('mask'), ReadStringArray('shape'));
    Result := Parsed.Format(INDENTATION);
  finally
    Parsed.Free;
  end;
end;

function TGoldenCase.ExpectedText: string;
begin
  var Expected := FDocument.GetValue('expected');
  if Assigned(Expected) then
    Exit(Expected.Format(INDENTATION));

  var ExpectedText := FDocument.GetValue('expectedText');
  if Assigned(ExpectedText) then
    Exit(ExpectedText.Value);

  raise EGoldenError.CreateFmt('No expectation recorded in %s (run once with %s=1)',
    [FFileName, TGoldenFiles.RECORD_ENVIRONMENT_VARIABLE]);
end;

procedure TGoldenCase.RemoveExpected;
begin
  FDocument.RemovePair('expected').Free;
  FDocument.RemovePair('expectedText').Free;
end;

procedure TGoldenCase.RecordExpected(const ResponseBody: string);
begin
  RemoveExpected;

  var Parsed: TJSONValue := nil;
  if ResponseBody.Trim <> '' then
    Parsed := TJSONObject.ParseJSONValue(ResponseBody);

  if Assigned(Parsed) then
  begin
    TGoldenNormalizer.Normalize(Parsed, ReadStringArray('mask'), ReadStringArray('shape'));
    FDocument.AddPair('expected', Parsed);
  end
  else
    FDocument.AddPair('expectedText', ResponseBody);

  Save;
end;

procedure TGoldenCase.Save;
begin
  var Text := FDocument.Format(INDENTATION) + sLineBreak;
  TFile.WriteAllBytes(FFileName, TEncoding.UTF8.GetBytes(Text));
end;

{ TGoldenRunner }

class procedure TGoldenRunner.Check(const Suite, CaseName: string; const Process: TGoldenProcessFunc);
begin
  var GoldenCase := TGoldenCase.Create(TGoldenFiles.CaseFile(Suite, CaseName));
  try
    var Response: string;
    var SavedDirectory := GetCurrentDir;
    if GoldenCase.WorkingDirectory <> '' then
      SetCurrentDir(GoldenCase.WorkingDirectory);
    try
      Response := Process(GoldenCase.RequestBody);
    finally
      SetCurrentDir(SavedDirectory);
    end;

    if TGoldenFiles.RecordMode then
    begin
      GoldenCase.RecordExpected(Response);
      Exit;
    end;

    var Expected := GoldenCase.ExpectedText;
    var Actual := GoldenCase.NormalizeResponse(Response);
    if Expected <> Actual then
      raise EGoldenError.CreateFmt('Golden mismatch for %s/%s'#13#10'--- expected ---'#13#10'%s'#13#10'--- actual ---'#13#10'%s',
        [Suite, CaseName, Expected, Actual]);
  finally
    GoldenCase.Free;
  end;
end;

end.
