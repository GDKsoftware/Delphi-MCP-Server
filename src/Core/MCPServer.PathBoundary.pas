unit MCPServer.PathBoundary;

interface

type
  TPathBoundary = class
  public
    class function IsWithin(const Path: string; const BasePath: string): Boolean; static;
  end;

implementation

uses
  System.SysUtils,
  System.IOUtils;

class function TPathBoundary.IsWithin(const Path: string; const BasePath: string): Boolean;
begin
  const NormalizedPath = ExcludeTrailingPathDelimiter(TPath.GetFullPath(Path));
  const NormalizedBase = ExcludeTrailingPathDelimiter(TPath.GetFullPath(BasePath));

  const IsBaseItself = SameText(NormalizedPath, NormalizedBase);
  const IsInsideBase = NormalizedPath.StartsWith(IncludeTrailingPathDelimiter(NormalizedBase), True);
  Result := (IsBaseItself or IsInsideBase);
end;

end.
