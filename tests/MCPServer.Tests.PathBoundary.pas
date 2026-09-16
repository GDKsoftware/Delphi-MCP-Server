unit MCPServer.Tests.PathBoundary;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TPathBoundaryTest = class
  private
    FBase: string;
  public
    [Setup]
    procedure Setup;

    [Test]
    procedure IsWithin_BaseItself_ReturnsTrue;

    [Test]
    procedure IsWithin_BaseWithTrailingDelimiter_ReturnsTrue;

    [Test]
    procedure IsWithin_ChildDirectory_ReturnsTrue;

    [Test]
    procedure IsWithin_SiblingWithSamePrefix_ReturnsFalse;

    [Test]
    procedure IsWithin_ParentTraversal_ReturnsFalse;

    [Test]
    procedure IsWithin_UnrelatedDirectory_ReturnsFalse;
  end;

implementation

uses
  System.SysUtils,
  System.IOUtils,
  MCPServer.PathBoundary;

procedure TPathBoundaryTest.Setup;
begin
  FBase := TPath.Combine(TPath.GetTempPath, 'mcp-server');
end;

procedure TPathBoundaryTest.IsWithin_BaseItself_ReturnsTrue;
begin
  Assert.IsTrue(TPathBoundary.IsWithin(FBase, FBase));
end;

procedure TPathBoundaryTest.IsWithin_BaseWithTrailingDelimiter_ReturnsTrue;
begin
  const PathWithDelimiter = IncludeTrailingPathDelimiter(FBase);

  Assert.IsTrue(TPathBoundary.IsWithin(PathWithDelimiter, FBase));
end;

procedure TPathBoundaryTest.IsWithin_ChildDirectory_ReturnsTrue;
begin
  const Child = TPath.Combine(FBase, 'data');

  Assert.IsTrue(TPathBoundary.IsWithin(Child, FBase));
end;

procedure TPathBoundaryTest.IsWithin_SiblingWithSamePrefix_ReturnsFalse;
begin
  const Sibling = FBase + '-secrets';

  Assert.IsFalse(TPathBoundary.IsWithin(Sibling, FBase), 'A sibling directory that shares the name prefix is outside the base');
end;

procedure TPathBoundaryTest.IsWithin_ParentTraversal_ReturnsFalse;
begin
  const Traversal = TPath.Combine(FBase, '..\other');

  Assert.IsFalse(TPathBoundary.IsWithin(Traversal, FBase));
end;

procedure TPathBoundaryTest.IsWithin_UnrelatedDirectory_ReturnsFalse;
begin
  const Unrelated = TPath.Combine(TPath.GetTempPath, 'elsewhere');

  Assert.IsFalse(TPathBoundary.IsWithin(Unrelated, FBase));
end;

end.
