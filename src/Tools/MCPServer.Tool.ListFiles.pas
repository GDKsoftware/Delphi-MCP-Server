unit MCPServer.Tool.ListFiles;

interface

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.Types,
  System.JSON,
  MCPServer.Tool.Base,
  MCPServer.Types;

type
  TListFilesParams = class
  private
    FPath: string;
    FIncludeHidden: Boolean;
  public
    [SchemaDescription('Directory path to list files from')]
    property Path: string read FPath write FPath;
    
    [Optional]
    [SchemaDescription('Include hidden files in the listing')]
    property IncludeHidden: Boolean read FIncludeHidden write FIncludeHidden;
  end;

  TListFilesTool = class(TMCPToolBase<TListFilesParams>)
  protected
    function ExecuteWithParams(const Params: TListFilesParams): string; override;
  public
    constructor Create; override;
  end;

implementation

uses
  MCPServer.Registration;

{ TListFilesTool }

constructor TListFilesTool.Create;
begin
  inherited;
  FName := 'list_files';
  FDescription := 'List files in a directory';
end;

function TListFilesTool.ExecuteWithParams(const Params: TListFilesParams): string;
var
  Files: TStringList;
  FileArray: TStringDynArray;
  FileName: string;
  NormalizedPath: string;
  AllowedBasePath: string;
begin
  Files := TStringList.Create;
  try
    NormalizedPath := TPath.GetFullPath(Params.Path);
    AllowedBasePath := TPath.GetFullPath(GetCurrentDir);
    
    if not NormalizedPath.StartsWith(AllowedBasePath, True) then
    begin
      Result := 'Error: Access denied - path outside allowed directory';
      Exit;
    end;
    
    if TDirectory.Exists(NormalizedPath) then
    begin
      FileArray := TDirectory.GetFiles(NormalizedPath);
      for FileName in FileArray do
      begin
        {$IFDEF MSWINDOWS}
        if (not Params.IncludeHidden) then
        begin
          var Attrs := TFile.GetAttributes(FileName);
          {$WARN SYMBOL_PLATFORM OFF}
          if (TFileAttribute.faHidden in Attrs) then
            Continue;
          {$WARN SYMBOL_PLATFORM ON}
        end;
        {$ENDIF}
          
        Files.Add(ExtractFileName(FileName));
      end;
      Result := 'Files in ' + NormalizedPath + ':' + sLineBreak + Files.Text;
    end
    else
      Result := 'Error: Directory not found: ' + NormalizedPath;
  finally
    Files.Free;
  end;
end;

initialization
  TMCPRegistry.RegisterTool('list_files',
    function: IMCPTool
    begin
      Result := TListFilesTool.Create;
    end
  );

end.