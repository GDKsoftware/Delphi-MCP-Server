# Delphi MCP Server

![Delphi](https://img.shields.io/badge/Delphi-12%2B-red)
![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20Linux-lightgrey)
![License](https://img.shields.io/badge/license-MIT-blue)
![MCP](https://img.shields.io/badge/MCP-2025--03--26-green)

A Model Context Protocol (MCP) server implementation in Delphi, designed to integrate with Claude Code and other MCP-compatible clients for AI-powered Delphi development workflows.

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Using as a Library](#using-as-a-library)
- [Integration with Claude Code](#integration-with-claude-code)
- [Testing with MCP Inspector](#testing-with-mcp-inspector)
- [Available Example Tools](#available-example-tools)
- [Available Example Resources](#available-example-resources)
- [Configuration](#configuration)
- [License](#license)
- [Contributing](#contributing)
- [About GDK Software](#about-gdk-software)
- [Support](#support)

## Features

- **Full MCP Protocol Support**: Implements the Model Context Protocol specification for seamless AI integration
- **Tool System**: Extensible tool system with RTTI-based discovery and execution
- **Resource Management**: Modular resource system supporting various content types
- **JSON-RPC 2.0**: Standards-compliant JSON-RPC implementation
- **Security**: Built-in security features including CORS configuration
- **High Performance**: Native implementation using Indy HTTP Server
- **Optional Parameters**: Support for optional tool parameters using custom attributes
- **Cross-Platform**: Supports Windows (Win32/Win64) and Linux (x64)

## Requirements

- Delphi 12 Athens or later
- Windows (Win32/Win64) or Linux (x64)
- No external dependencies (all required libraries included)

## Installation

### For Standalone Usage

1. Clone the repository:
```bash
git clone https://github.com/GDKsoftware/delphi-mcp-server.git
cd delphi-mcp-server
```

2. Build the project:

#### Windows Build
```bash
build.bat
```

Or specify configuration and platform:
```bash
build.bat Debug Win32
build.bat Release Win64
```

#### Linux Build

**Prerequisites:**
- Delphi Enterprise with Linux platform support
- PAServer running on Linux target machine
- Linux SDK configured in RAD Studio

From the batch file:
```bash
build.bat Release Linux64
```

Or from RAD Studio IDE:
1. Open MCPServer.dproj
2. Select Linux64 platform
3. Build

## Using as a Library

The Delphi MCP Server is designed to be used both as a standalone application and as a library for your own MCP server implementations. This section covers how to integrate it into your existing Delphi projects.

### Project Setup for Library Usage

#### Option 1: Git Submodule (Recommended)

```bash
# Add MCPServer as a submodule to your project
git submodule add https://github.com/GDKsoftware/delphi-mcp-server.git lib/mcpserver
git submodule update --init --recursive
```

#### Option 2: Direct Source Inclusion

Copy the `src` folder from MCPServer into your project and add the units to your uses clauses.

#### Delphi Project Configuration

1. **Search Paths**: Add the MCPServer source directories to your project search path:
   - `lib\mcpserver\src\Core`
   - `lib\mcpserver\src\Managers` 
   - `lib\mcpserver\src\Protocol`
   - `lib\mcpserver\src\Server`
   - `lib\mcpserver\src\Tools`
   - `lib\mcpserver\src\Resources`

2. **Required Units**: Include these core units in your project:
   ```pascal
   MCPServer.Types,
   MCPServer.Settings,
   MCPServer.Registration,
   MCPServer.ManagerRegistry,
   MCPServer.IdHTTPServer
   ```

### Library Integration

Once you have the project setup complete, the simplest way to add MCP capabilities to your application:

```pascal
program YourMCPServer;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  MCPServer.Types in 'lib\mcpserver\src\Protocol\MCPServer.Types.pas',
  MCPServer.IdHTTPServer in 'lib\mcpserver\src\Server\MCPServer.IdHTTPServer.pas',
  MCPServer.Settings in 'lib\mcpserver\src\Core\MCPServer.Settings.pas',
  MCPServer.ManagerRegistry in 'lib\mcpserver\src\Core\MCPServer.ManagerRegistry.pas',
  MCPServer.CoreManager in 'lib\mcpserver\src\Managers\MCPServer.CoreManager.pas',
  MCPServer.ToolsManager in 'lib\mcpserver\src\Managers\MCPServer.ToolsManager.pas',
  MCPServer.ResourcesManager in 'lib\mcpserver\src\Managers\MCPServer.ResourcesManager.pas';

var
  Server: TMCPIdHTTPServer;
  Settings: TMCPSettings;
  ManagerRegistry: IMCPManagerRegistry;
  
begin
  Settings := TMCPSettings.Create;
  try
    ManagerRegistry := TMCPManagerRegistry.Create;
    ManagerRegistry.RegisterManager(TMCPCoreManager.Create(Settings));
    ManagerRegistry.RegisterManager(TMCPToolsManager.Create);
    ManagerRegistry.RegisterManager(TMCPResourcesManager.Create);
    
    Server := TMCPIdHTTPServer.Create(nil);
    try
      Server.Settings := Settings;
      Server.ManagerRegistry := ManagerRegistry;
      Server.Start;
      
      Writeln('MCP Server running on port ', Settings.Port);
      Readln; // Keep running
      
      Server.Stop;
    finally
      Server.Free;
    end;
  finally
    Settings.Free;
  end;
end.
```

### Creating Custom Tools

```pascal
unit YourProject.Tool.Custom;

interface

uses
  MCPServer.Tool.Base,
  MCPServer.Types,
  MCPServer.Registration;

type
  TCustomToolParams = class
  private
    FInput: string;
    FCount: Integer;
  public
    [SchemaDescription('Text input to process')]
    property Input: string read FInput write FInput;
    
    [Optional]
    [SchemaDescription('Number of times to repeat (default: 1)')]
    property Count: Integer read FCount write FCount;
  end;

  TCustomTool = class(TMCPToolBase<TCustomToolParams>)
  protected
    function ExecuteWithParams(const AParams: TCustomToolParams): string; override;
  public
    constructor Create; override;
  end;

implementation

constructor TCustomTool.Create;
begin
  inherited;
  FName := 'custom_tool';
  FDescription := 'A custom tool that processes input';
end;

function TCustomTool.ExecuteWithParams(const AParams: TCustomToolParams): string;
var
  I: Integer;
  Output: string;
begin
  Output := '';
  for I := 1 to AParams.Count do
    Output := Output + AParams.Input + #13#10;
  Result := 'Processed: ' + Output;
end;

initialization
  TMCPRegistry.RegisterTool('custom_tool',
    function: IMCPTool
    begin
      Result := TCustomTool.Create;
    end
  );

end.
```

### Creating Custom Resources

```pascal
unit YourProject.Resource.Custom;

interface

uses
  System.SysUtils,
  MCPServer.Resource.Base,
  MCPServer.Registration;

type
  TCustomData = class
  private
    FMessage: string;
    FTimestamp: TDateTime;
  public
    property Message: string read FMessage write FMessage;
    property Timestamp: TDateTime read FTimestamp write FTimestamp;
  end;

  TCustomResource = class(TMCPResourceBase<TCustomData>)
  protected
    function GetResourceData: TCustomData; override;
  public
    constructor Create; override;
  end;

implementation

constructor TCustomResource.Create;
begin
  inherited;
  FURI := 'custom://data';
  FName := 'Custom Data';
  FDescription := 'Custom resource data';
  FMimeType := 'application/json';
end;

function TCustomResource.GetResourceData: TCustomData;
begin
  Result := TCustomData.Create;
  Result.Message := 'Hello from custom resource';
  Result.Timestamp := Now;
end;

initialization
  TMCPRegistry.RegisterResource('custom://data',
    function: IMCPResource
    begin
      Result := TCustomResource.Create;
    end
  );

end.
```

## Integration with Claude Code

Configure using the Streamable HTTP transport:

```bash
# Basic configuration
claude mcp add --transport http delphi-mcp-server http://localhost:3000/mcp

# With authentication (if configured)
claude mcp add --transport http delphi-mcp-server http://localhost:3000/mcp --header "Authorization: Bearer your-token"
```

Make sure the server is running before connecting Claude Code.

### HTTPS/SSL Configuration

The server supports HTTPS connections when configured with SSL certificates:

1. **Generate SSL Certificates**:
   ```bash
   # Generate self-signed certificates (for development)
   generate-ssl-cert.bat
   ```
   This creates certificates in the `certs` directory.

2. **Configure SSL in settings.ini**:
   ```ini
   [SSL]
   Enabled=1  ; Use 1 (true) or 0 (false)
   CertFile=C:\path\to\server.crt
   KeyFile=C:\path\to\server.key
   RootCertFile=C:\path\to\ca.crt  ; Optional
   ```

3. **Start the server**:
   The server will automatically use HTTPS when SSL is enabled.

**Note**: For production, use certificates from a trusted Certificate Authority (CA) instead of self-signed certificates.

## Testing with MCP Inspector

The easiest way to test and debug your MCP server is using the official MCP Inspector:

1. **Start the server**:
   ```bash
   # Build and run the server
   build.bat
   Win32\Debug\MCPServer.exe
   ```

2. **Run MCP Inspector**:
   ```bash
   # Install and run the MCP Inspector
   npx @modelcontextprotocol/inspector
   ```

3. **Connect to your server**:
   - **Transport**: HTTP
   - **URL**: `http://localhost:3000/mcp`
   - Click **Connect**

4. **Test functionality**:
   - Browse available tools and resources
   - Execute tools like `echo`, `get_time`, `calculate`
   - View resources like `project://info`, `server://status`
   - Monitor request/response JSON-RPC messages

The Inspector provides a web interface to interact with your MCP server, making it perfect for development and debugging.

## Available Example tools

- **echo**: Echo a message back to the user
- **get_time**: Get the current server time
- **list_files**: List files in a directory
- **calculate**: Perform basic arithmetic calculations

## Available Example resources

The server provides four essential resources accessible via URIs:

- **project://info** - Project information (JSON metadata with collections)
- **project://readme** - This README file (markdown content) 
- **logs://recent** - Recent log entries from all categories (with thread safety)
- **server://status** - Current server status and health information

## Configuration

The server supports configuration through `settings.ini` files. A default `settings.ini.example` is provided in the repository.

### SSL/TLS Configuration

The Delphi MCP Server supports two SSL/TLS implementations:

1. **Standard Indy SSL** - Uses OpenSSL 1.0.2 (default if TaurusTLS not available)
2. **TaurusTLS** - Uses OpenSSL 3.x with modern cipher support (recommended)

#### Installing TaurusTLS

TaurusTLS provides OpenSSL 3.x support with modern ECDHE cipher suites required by services like Cloudflare.

**Via GetIt Package Manager (Easiest):**
1. Open Delphi IDE
2. Go to Tools > GetIt Package Manager
3. Search for "TaurusTLS"
4. Click Install

**Manual Installation:**
1. Clone from https://github.com/JPeterMugaas/TaurusTLS
2. Open `TaurusTLS\Packages\d12\TaurusAll.groupproj`
3. Compile `TaurusTLS_RT`
4. Compile and install `TaurusTLS_DT`

#### Switching Between SSL Implementations

Edit `src\Server\MCPServer.IdHTTPServer.pas`:

```pascal
// To use TaurusTLS (OpenSSL 3.x):
{$DEFINE USE_TAURUS_TLS}  // Keep this line uncommented

// To use Standard Indy SSL (OpenSSL 1.0.2):
// {$DEFINE USE_TAURUS_TLS}  // Comment out this line
```

#### OpenSSL DLL Requirements

**For TaurusTLS:**

*Windows:*
- Requires OpenSSL 3.x DLLs:
  - Win32: `libcrypto-3.dll`, `libssl-3.dll`
  - Win64: `libcrypto-3-x64.dll`, `libssl-3-x64.dll`
- Pre-compiled binaries:
  - https://github.com/JPeterMugaas/OpenSSL-Distribution/tree/main/binaries/Windows
  - https://github.com/TurboPack/OpenSSL-Distribution/tree/main/binaries/Windows
- Current versions: 3.0.17, 3.2.5, 3.3.4, 3.4.2, 3.5.1, 3.5.2
- Place DLLs in the same directory as your executable

*Linux:*
- OpenSSL is usually installed by default
- Update if needed: `sudo apt-get install libssl-dev` (Debian/Ubuntu) or `sudo yum install openssl-devel` (RHEL/CentOS)
- Build scripts available: https://github.com/TurboPack/OpenSSL-Distribution/tree/main/build-scripts

*macOS:*
- Use static libraries (.a files) for OpenSSL 3.x
- Install via Homebrew: `brew install openssl@3`
- Or use pre-compiled libraries from TaurusTLS distributions
- Build scripts available: https://github.com/TurboPack/OpenSSL-Distribution/tree/main/build-scripts

**For Standard Indy:**
- Requires OpenSSL 1.0.2 DLLs (`libeay32.dll`, `ssleay32.dll`)
- Limited cipher support, not recommended for modern clients

#### Known Issues & Solutions

- **Cloudflare Tunnel**: Standard Indy SSL lacks ECDHE cipher support. Use TaurusTLS or run Cloudflare Tunnel with HTTP: `cloudflared tunnel --url http://localhost:8080`
- **Self-Signed Certificates**: Claude Desktop doesn't accept self-signed certificates. Use Cloudflare Tunnel or a valid certificate from a trusted CA
- **"No shared cipher" error**: Install and enable TaurusTLS for modern cipher support

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Contributing

We welcome contributions! Here's how to help:

### Reporting Issues
- Use [GitHub Issues](https://github.com/GDKsoftware/delphi-mcp-server/issues) for bugs and feature requests
- Include Delphi version, platform, and reproduction steps

### Pull Requests
1. Fork the repository
2. Create a feature branch: `git checkout -b feature/my-feature`
3. Follow existing code style (inline vars, named constants)
4. Test your changes
5. Submit a pull request

### Development Setup
- Requires Delphi 12+ 
- Open `MCPServer.dproj` or build with `build.bat`
- Test with `npx @modelcontextprotocol/inspector` or Claude Code or similar

## About GDK Software

[GDK Software](https://www.gdksoftware.com) is a software company specializing in Delphi development, upgrades, and migrations. We provide Delphi development, upgrades, maintenance, and modernization of application services. GDK Software also offers consulting and training related to Delphi and low-code development with Codolex. We have a global presence with offices in the Netherlands, UK, USA, and Brazil.

## Support

- Create an issue on [GitHub](https://github.com/GDKsoftware/delphi-mcp-server/issues)
- Visit our website at [www.gdksoftware.com](https://www.gdksoftware.com)
- Contact us for commercial support