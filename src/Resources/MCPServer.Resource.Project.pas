unit MCPServer.Resource.Project;

interface

uses
  System.SysUtils,
  System.IOUtils,
  System.Generics.Collections,
  MCPServer.Resource.Base;

type
  TProjectInfo = class
  private
    FName: string;
    FVersion: string;
    FDescription: string;
    FLanguage: string;
    FFramework: string;
    FProtocol: string;
    FTransport: string;
    FAuthor: string;
    FRepository: string;
    FFeatures: TList<string>;
  public
    constructor Create;
    destructor Destroy; override;
    
    property Name: string read FName write FName;
    property Version: string read FVersion write FVersion;
    property Description: string read FDescription write FDescription;
    property Language: string read FLanguage write FLanguage;
    property Framework: string read FFramework write FFramework;
    property Protocol: string read FProtocol write FProtocol;
    property Transport: string read FTransport write FTransport;
    property Author: string read FAuthor write FAuthor;
    property Repository: string read FRepository write FRepository;
    property Features: TList<string> read FFeatures write FFeatures;
  end;

  TTextContent = class
  private
    FContent: string;
  public
    property Content: string read FContent write FContent;
  end;

  TProjectInfoResource = class(TMCPResourceBase<TProjectInfo>)
  protected
    function GetResourceData: TProjectInfo; override;
  public
    constructor Create; override;
  end;

  TProjectReadmeResource = class(TMCPResourceBase<TTextContent>)
  protected
    function GetResourceData: TTextContent; override;
  public
    constructor Create; override;
  end;


implementation

uses
  MCPServer.Registration;

{ TProjectInfo }

constructor TProjectInfo.Create;
begin
  inherited;
  FFeatures := TList<string>.Create;
end;

destructor TProjectInfo.Destroy;
begin
  FFeatures.Free;
  inherited;
end;

{ TProjectInfoResource }

constructor TProjectInfoResource.Create;
begin
  inherited;
  FURI := 'project://info';
  FName := 'Project Information';
  FDescription := 'Basic information about the Delphi MCP Server project';
  FMimeType := 'application/json';
end;

function TProjectInfoResource.GetResourceData: TProjectInfo;
begin
  Result := TProjectInfo.Create;
  Result.Name := 'delphi-mcp-server';
  Result.Version := '1.0.0';
  Result.Description := 'A Model Context Protocol (MCP) server implementation in Delphi';
  Result.Language := 'Delphi';
  Result.Framework := 'Indy HTTP Server (TIdHTTPServer)';
  Result.Protocol := 'MCP 2025-03-26';
  Result.Transport := 'Streamable HTTP';
  Result.Author := 'GDK Software';
  Result.Repository := 'https://github.com/GDKsoftware/delphi-mcp-server';
  Result.Features.Add('Tools capability');
  Result.Features.Add('Resources capability');
  Result.Features.Add('JSON-RPC 2.0 support');
  Result.Features.Add('CORS support');
end;

{ TProjectReadmeResource }

constructor TProjectReadmeResource.Create;
begin
  inherited;
  FURI := 'project://readme';
  FName := 'Project README';
  FDescription := 'README.md file contents';
  FMimeType := 'text/markdown';
end;

function TProjectReadmeResource.GetResourceData: TTextContent;
begin
  Result := TTextContent.Create;

  Result.Content := '''
# Delphi MCP Server

A Model Context Protocol (MCP) server implementation in Delphi using Indy HTTP Server.

## Features
- Tools capability with automatic schema generation
- Resources capability for read-only data access
- JSON-RPC 2.0 protocol support
- CORS support for cross-origin requests

## Building
```bash
build.bat
```

## Running
```bash
Win32\Debug\MCPServer.exe
```

## Testing
```bash
npx @wong2/mcp-cli --url http://localhost:8080/mcp
```
''';
end;


initialization
  TMCPRegistry.RegisterResource('project://info',
    function: IMCPResource
    begin
      Result := TProjectInfoResource.Create;
    end
  );
  
  TMCPRegistry.RegisterResource('project://readme',
    function: IMCPResource
    begin
      Result := TProjectReadmeResource.Create;
    end
  );
  

end.