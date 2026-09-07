# Delphi MCP Server

![Delphi](https://img.shields.io/badge/Delphi-12%2B-red)
![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20Linux-lightgrey)
![License](https://img.shields.io/badge/license-MIT-blue)
![MCP](https://img.shields.io/badge/MCP-2026--07--28%20(dual--era)-green)

A Model Context Protocol (MCP) server implementation in Delphi, designed to integrate with Claude Code, Codex, and other MCP-compatible clients for AI-powered Delphi development workflows.

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Transport Modes](#transport-modes)
- [Protocol Versions and Dual-Era Behaviour](#protocol-versions-and-dual-era-behaviour)
- [Using as a Library](#using-as-a-library)
- [Integration with Claude Code](#integration-with-claude-code)
- [Integration with Codex](#integration-with-codex)
- [Testing with MCP Inspector](#testing-with-mcp-inspector)
- [Available Example Tools](#available-example-tools)
- [Available Example Prompts](#available-example-prompts)
- [Available Example Resources](#available-example-resources)
- [Configuration](#configuration)
- [Authentication](#authentication)
- [Network and Security](#network-and-security)
- [License](#license)
- [Contributing](#contributing)
- [About GDK Software](#about-gdk-software)
- [Support](#support)

## Features

- **Dual-era MCP**: Serves MCP 2026-07-28 (per-request `_meta`, `server/discover`) and the initialize-based revisions 2025-06-18 and 2025-11-25 on the same endpoint and the same stdio process; see [Protocol versions](#protocol-versions-and-dual-era-behaviour)
- **Dual Transport Support**: HTTP (Streamable HTTP with SSE) and STDIO (stdin/stdout)
- **Dual Response Mode**: Supports both JSON-RPC and Server-Sent Events in the same server
- **Tool System**: Extensible tool system with RTTI-based discovery and execution
- **Resource Management**: Modular resource system supporting various content types
- **Security**: `Origin` and `Host` validation against DNS rebinding on every request, loopback binding by default, CORS headers for browser clients, request size and nesting limits, opt-in bearer authentication with OAuth 2.1 resource-server discovery
- **Multi round-trip requests, streaming and subscriptions**: `InputRequiredResult` with signed `requestState`, progress and log notifications on the response stream, `subscriptions/listen` for change notifications
- **High Performance**: Native implementation using Indy HTTP Server with keep-alive support
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

The script picks up the highest TaurusTLS version installed in the CatalogRepository of the Studio release that `DELPHI_PATH` points at. To build against a copy somewhere else, set `TAURUS_PATH` to its `Source` directory first:
```bash
set TAURUS_PATH=C:\path\to\TaurusTLS\Source
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

## Transport Modes

The server supports two transport modes:

### HTTP Transport (Default)

Start the server without arguments for HTTP transport with Server-Sent Events (SSE):

```bash
Win32\Debug\MCPServer.exe
```

The server will listen on `http://localhost:3000/mcp` by default (configurable via settings.ini).

**Use HTTP transport for:**
- Claude Code (SSE support)
- MCP Inspector
- Web-based clients
- Remote connections

### STDIO Transport

Start the server with `--stdio` flag for stdin/stdout communication:

```bash
Win32\Debug\MCPServer.exe --stdio
```

The server will:
- Read JSON-RPC messages from stdin, UTF-8, one per line, no byte-order mark
- Write JSON-RPC messages to stdout the same way
- Log diagnostic messages to stderr, never to stdout
- Answer `notifications/cancelled` by stopping the named request; it gets no response
- Send `notifications/progress` for a request that carries `_meta.progressToken`, before its response
- Exit within `[Server] MaxConcurrentRequests` worker threads' drain time (2 seconds by default) once stdin closes

**Use STDIO transport for:**
- Codex (OpenAI)
- Local MCP clients that use process spawning
- Automated testing and scripting

**Supported flag variants:** `--stdio`, `-stdio`, `/stdio`

By default requests are answered one at a time, in the order they arrive.
`[Server] MaxConcurrentRequests` in `settings.ini` raises the number of worker
threads for a client that issues concurrent requests over the same process; a
stdio server never writes `settings.ini` on its own, so this and the other
`[Server]` limits still need explicit configuration when they should differ
from the defaults.

A tool sees the request it is answering through `TMCPRequestContext.Current`:
`CheckCancelled` raises once the client cancels, `ReportProgress` sends a
`notifications/progress` when the request carries a progress token, and
`Log` sends a `notifications/message` when the request carries
`_meta.io.modelcontextprotocol/logLevel` and the message's level is at or
above it. See `test_tool_with_progress` and `test_logging_tool` in
`MCPServer.Tool.ContentSamples` for worked examples.

Over HTTP the same notifications reach the client on the response: when the
request accepts `text/event-stream` and a tool sends one, the response turns
into an SSE stream (chunked, `X-Accel-Buffering: no`) that carries the
notifications first and the JSON-RPC response as its last event. A request
that sends none is answered as before. A client that closes the stream
cancels the request.

### Change notifications (`subscriptions/listen`)

A modern client that wants to hear about changes opens a long-lived
`subscriptions/listen` request with a `notifications` filter
(`toolsListChanged`, `promptsListChanged`, `resourcesListChanged`,
`resourceSubscriptions`: a list of URIs). `TMCPSubscriptionsManager`
(`MCPServer.SubscriptionsManager`) answers with
`notifications/subscriptions/acknowledged` carrying the honoured filter and
keeps the stream open: over HTTP as an SSE response with a keep-alive comment
every 15 seconds, over stdio on a thread of its own so the worker threads stay
free. Every message on the subscription carries
`_meta.io.modelcontextprotocol/subscriptionId`, the JSON-RPC id of the
`subscriptions/listen` request. Closing the SSE stream, or sending
`notifications/cancelled` for that id over stdio, ends the subscription;
when the server stops (or stdin closes) it answers the request with a
completion result first.

Assign the manager as `ChangeNotifier` of the tools, prompts and resources
managers, as `MCPServer.dpr` does, and the `tools`, `prompts` and `resources`
capabilities announce `listChanged` (and `resources.subscribe`) to modern
clients. `AddTool`, `RemoveTool`, `AddPrompt`, `RemovePrompt`, `AddResource`,
`RemoveResource` and `AddResourceTemplate` then notify the subscribed clients,
and `TMCPResourcesManager.ResourceUpdated(Uri)` reports a changed resource to
the clients that subscribed to that URI. Without a `ChangeNotifier` nothing is
announced and nothing is sent.

## Protocol Versions and Dual-Era Behaviour

The server decides per request which protocol era it is speaking; nothing is negotiated per connection and no session is minted.

| Request | Era | Served as |
|---|---|---|
| `params._meta` with `io.modelcontextprotocol/protocolVersion` | modern | `2026-07-28`. `clientCapabilities` is required (`-32602`); an unknown revision gets `-32022` with the supported list; `initialize`, `ping`, `logging/setLevel` and `resources/subscribe` do not exist in this era (`-32601`). |
| `initialize` without modern `_meta` | legacy | The requested revision when it is `2025-06-18` or `2025-11-25`, otherwise `2025-11-25`. The result carries `capabilities` and `serverInfo` only. |
| `server/discover` without `_meta` | modern, malformed | `-32602` |
| Anything else | legacy | The revision negotiated by `initialize` on this stdio process, the `MCP-Protocol-Version` header on HTTP, or `2025-11-25` when nothing is known. |

Modern results carry `resultType`, `_meta.io.modelcontextprotocol/serverInfo` and, on `server/discover`, `tools/list`, `resources/list`, `resources/templates/list` and `resources/read`, the cache hints `ttlMs` and `cacheScope`. Legacy results are unchanged. Client responses (`result` or `error` without `method`) are ignored.

Over HTTP, modern requests must carry `MCP-Protocol-Version`, `Mcp-Method` and, for `tools/call`, `resources/read` and `prompts/get`, `Mcp-Name` (Base64 sentinel encoding accepted); a missing or different header is `400` with `-32020`. Modern protocol errors get `400`, an unknown method `404`; legacy requests get `200` for every JSON-RPC error, except `400` for an unknown `MCP-Protocol-Version` header. Notifications get `202` with an empty body. Every 4xx to a modern request carries a JSON-RPC error body, so dual-era clients can tell a modern server from a legacy one.

Handlers can read the era, the negotiated revision and the client's declared capabilities through `TMCPRequestContext.Current` (`MCPServer.RequestContext`) or by implementing `IMCPCapabilityManagerEx`, and can raise `EMCPError` (`MCPServer.Errors`) to send a specific JSON-RPC error code.

`settings.ini` keys: `[Server] Title`, `Description`, `WebsiteUrl` and `Instructions` fill `serverInfo` and `instructions`; `[Protocol] LenientModernPing` answers `ping` in the modern era anyway, `DiscoverListsLegacyVersions` also lists the legacy revisions in `server/discover`, and `DiscoverTtlMs` is the cache hint on `server/discover`.

`2025-03-26` is accepted on `initialize` but answered with `2025-11-25`; JSON-RPC batch arrays are rejected with `-32600`.

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
   - `lib\mcpserver\src\Prompts`

2. **Required Units**: Include these core units in your project:
   ```pascal
   MCPServer.Types,
   MCPServer.Settings,
   MCPServer.Registration,
   MCPServer.ManagerRegistry,
   MCPServer.IdHTTPServer,      // For HTTP transport
   MCPServer.StdioTransport,    // For STDIO transport
   MCPServer.JsonRpcProcessor   // Shared JSON-RPC processing
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

#### Library checklist

- **Register before you start.** `TMCPToolsManager.Create` and `TMCPResourcesManager.Create` read `TMCPRegistry` once. Register your tools and resources (normally from unit `initialization` sections) before the managers are created, which means before `TMCPIdHTTPServer.Start` or `TMCPStdioTransport.Run`. Later registrations are not picked up.
- **STDIO: keep stdout clean.** Everything on stdout must be an MCP message. `TMCPStdioTransport.Create` forces `TLogger.UseStdErr := True` and sets `TLogger.StdoutReserved`, so console logging goes to stderr and an attempt to switch it back is refused with a one-time warning. Never `Writeln` from tools, managers or resources; log through `TLogger`.
- **`server://status` is registered by default** by the unit initialization of `MCPServer.Resource.Server`. `TServerStatusResource.SetNamePrefix('myapp_')` renames it to `server://myapp_status`; call it before the managers are created.
- **Error codes and protocol constants** live in `MCPServer.Types` (`JSONRPC_*`, `MCP_ERROR_*`, `MCP_PROTOCOL_VERSION_*`, `MCP_META_*`). The `JSONRPC_*` names in `MCPServer.JsonRpcProcessor` remain as aliases.
- **Prompts and completion are optional managers**, registered the same way as tools and resources: `ManagerRegistry.RegisterManager(TMCPPromptsManager.Create)` and, if you want argument completion, `ManagerRegistry.RegisterManager(TMCPCompletionManager.Create(PromptsManager, ResourcesManager))` (it needs the concrete manager instances, not the `IMCPCapabilityManager` interface, to look prompts and resource templates up by name). The `prompts` and `completions` capabilities are only advertised when these managers are registered.

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

Arguments are validated against the generated schema before the tool runs: a
missing property without `[Optional]`, a value of the wrong JSON type or an
unknown enumeration name is answered as an `isError` result that names the
parameter. Integer properties are published as `integer`, `TDateTime` as a
`string` with `format: date-time`, enumerations and sets with their names;
`[SchemaTitle]`, `[SchemaFormat]`, `[SchemaMinimum]` and `[SchemaMaximum]`
add the corresponding keywords.

A tool that returns more than text overrides `ExecuteWithContext` and builds
a `TMCPToolResult` (`MCPServer.Tool.Result`):

```pascal
function TChartTool.ExecuteWithContext(const AParams: TChartParams;
  const Context: IMCPRequestContext): TValue;
begin
  Result := TMCPToolResult.Create
    .AddText('Chart for ' + AParams.Series)
    .AddImage(RenderPng(AParams), 'image/png')
    .AddResourceLink('chart://' + AParams.Series, AParams.Series, '', 'image/png');
end;
```

The builder also has `AddAudio`, `AddEmbeddedText`, `AddEmbeddedBlob`,
`WithAnnotations` (for the last block), `SetStructuredContent`, `SetMeta` and
`SetError`. Raise `EMCPToolError` for a failure the model should see as an
`isError` result; the request context gives the protocol era and the
client's `_meta`. Tools that inherit from `TMCPToolBase<T, R>` return an
object that becomes `structuredContent` plus a text block with the same
JSON. Set `FAnnotations` (for example `readOnlyHint`) or `FIcons` in the
constructor to publish them in `tools/list`. `MCPServer.Tool.ContentSamples`
has one small example per content type.

### Asking the client for input (multi round-trip requests)

MCP 2026-07-28 replaced server-initiated requests (`elicitation/create`,
`sampling/createMessage`, `roots/list`) with multi round-trip requests: the
server answers `tools/call`, `resources/read` or `prompts/get` with an
`InputRequiredResult` that lists what it needs, the client gathers the
answers and retries the same request with `inputResponses` (and the
server's opaque `requestState`). A tool, resource or prompt that needs input
raises `EMCPInputRequired` (`MCPServer.Mrtr`); the request context carries
the answers on the retry:

```pascal
function TGreetTool.ExecuteWithContext(const Params: TNoParams;
  const Context: IMCPRequestContext): TValue;
var
  Response: TJSONObject;
begin
  var Name := '';
  if Context.TryGetInputResponse('user_name', Response) then
    Name := TMCPInputResponse.ElicitationField(Response, 'name');
  if Name = '' then
    raise EMCPInputRequired.Create(TMCPInputRequests.Create
      .AddElicitation('user_name', 'What is your name?', TMCPInputRequests.FieldSchema('name')));

  Result := TMCPToolResult.Text(Format('Hello, %s!', [Name]));
end;
```

`TMCPInputRequests` builds the `inputRequests` map (`AddElicitation`,
`AddSampling`, `AddListRoots`); `TMCPInputResponse` reads the answers
(`ElicitationContent`, `ElicitationField`, `SamplingText`, `Roots`). The
processor only sends input requests the client declared a capability for
(`elicitation`, `sampling`, `roots`) and answers `-32021` otherwise, so a
tool can check `Context.HasClientCapability` first and ask for what the
client can deliver. Missing or wrong answers are handled by raising again:
the client gets a fresh `InputRequiredResult`.

State that must survive the round trip goes into the second constructor
argument: `EMCPInputRequired.Create(Requests, State)` with a `TJSONObject`.
The processor seals it into `requestState` (HMAC-SHA256 over the state, the
method, a digest of the request parameters, the principal and an expiry)
and opens it on the retry into `Context.RequestState`; a tampered, expired
or foreign token is `-32602`. `[Security] RequestStateKey` in `settings.ini`
is the signing secret (set the same value on every instance behind a load
balancer; empty means a random key per process) and
`RequestStateTtlSeconds` the token lifetime (600 by default).

Clients on the 2025 revisions cannot answer input requests, so a request
that raises `EMCPInputRequired` in the legacy era is answered with
`-32603`. `MCPServer.Tool.InputRequiredSamples` and
`test_input_required_result_prompt` are the examples the conformance suite
exercises.

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

`FTitle`, `FSize` and `FAnnotations` are published in `resources/list`;
`FTtlMs` and `FCacheScope` (`private` unless set) are the cache hints modern
clients get on `resources/read`. A binary resource implements
`IMCPBinaryResource.ReadBinary` and is delivered as a `blob`;
`MCPServer.Resource.Samples` shows a text and a binary example. A URI that is
not registered is answered with a JSON-RPC error (`-32002` for
initialize-based clients, `-32602` for modern clients), a read that raises
with `-32603`.

### Resource Templates

A template matches a family of URIs and resolves the actual resource from
the captured variables. It supports RFC 6570 level 1 (`{var}`, one path
segment) and a level 2 subset (`{+var}`, the rest of the URI including
`/`); `{/var}` and `{?var}` are not implemented.

```pascal
unit YourProject.Resource.CustomTemplate;

interface

uses
  MCPServer.Resource.Base,
  MCPServer.Registration;

type
  TCustomTemplate = class(TMCPResourceTemplateBase)
  public
    constructor Create; override;
    function CreateResource(const URI: string; Vars: TMCPTemplateVars): IMCPResource; override;
  end;

implementation

constructor TCustomTemplate.Create;
begin
  inherited;
  FUriTemplate := 'custom://{id}';
  FName := 'Custom item';
  FMimeType := 'application/json';
end;

function TCustomTemplate.CreateResource(const URI: string; Vars: TMCPTemplateVars): IMCPResource;
begin
  Result := TCustomResource.CreateForId(URI, Vars['id']);
end;

initialization
  TMCPRegistry.RegisterResourceTemplate('custom://{id}',
    function: IMCPResourceTemplate
    begin
      Result := TCustomTemplate.Create;
    end
  );

end.
```

`CreateResource` gets the actual requested URI (not the template) and the
captured variables, and returns an ordinary `IMCPResource` (typically a
`TMCPResourceBase<T>` with a constructor of your own choosing, since the
registry never constructs a template's resources itself); `resources/read`
tries an exact match first, then each registered template in order. See
`MCPServer.Resource.Samples` (`test://template/{id}/data`) and
`MCPServer.Resource.Logs` (`logs://{level}`, reusing the existing log
filtering) for worked examples.

### Creating Custom Prompts

```pascal
unit YourProject.Prompt.Custom;

interface

uses
  MCPServer.Types,
  MCPServer.Prompt.Base,
  MCPServer.Registration;

type
  TCustomPromptParams = class
  private
    FTopic: string;
  public
    [SchemaDescription('What to write about')]
    property Topic: string read FTopic write FTopic;
  end;

  TCustomPrompt = class(TMCPPromptBase<TCustomPromptParams>)
  protected
    function ExecuteWithParams(const Params: TCustomPromptParams;
      Messages: TMCPPromptMessages): string; override;
  public
    constructor Create; override;
  end;

implementation

constructor TCustomPrompt.Create;
begin
  inherited;
  FName := 'custom_prompt';
  FDescription := 'Asks the model to write about a topic';
end;

function TCustomPrompt.ExecuteWithParams(const Params: TCustomPromptParams;
  Messages: TMCPPromptMessages): string;
begin
  Messages.AddText('user', 'Write a short paragraph about ' + Params.Topic + '.');
  Result := 'Writing prompt';
end;

initialization
  TMCPRegistry.RegisterPrompt('custom_prompt',
    function: IMCPPrompt
    begin
      Result := TCustomPrompt.Create;
    end
  );

end.
```

The argument list in `prompts/list` comes from `T`'s string properties, the
same `[SchemaDescription]`/`[Optional]` attributes tools use; a required
argument missing from `arguments` is `-32602`, since `prompts/get` has no
`isError` result to report it through instead. `TMCPPromptMessages` builds
the messages: `AddText`, `AddImage`, `AddAudio`, `AddResourceLink`,
`AddEmbeddedText`, `AddEmbeddedBlob`, `AddEmbeddedResource` (wraps an
existing `IMCPResource`) and `WithAnnotations` for the last message added.
For a prompt with no natural parameter class, derive from the non-generic
`TMCPPromptBase` instead and set `FArguments` directly. `MCPServer.Prompt.SummarizeLogs`
and `MCPServer.Prompt.ContentSamples` show both content and templates in use.

A prompt or resource template that wants to offer argument completion
implements `IMCPCompletable` (`function Complete(const ArgumentName, Value: string;
const Context: TArray<TPair<string, string>>): TMCPCompletion`); a target
that does not implement it answers `completion/complete` with an empty
`values` array rather than an error, since not offering completion is a
valid choice.

## Integration with Claude Code

Configure using the Streamable HTTP transport:

```bash
# Basic configuration
claude mcp add --transport http delphi-mcp-server http://localhost:3000/mcp

# With authentication (if configured)
claude mcp add --transport http delphi-mcp-server http://localhost:3000/mcp --header "Authorization: Bearer your-token"
```

Make sure the server is running before connecting Claude Code.

## Integration with Codex

Configure Codex to use the STDIO transport. Edit your Codex configuration file (`~/.codex/config.toml`):

```toml
[mcp_servers.delphi-mcp-server]
command = 'C:\path\to\MCPServer.exe'
args = ["--stdio"]
```

Or on Linux/macOS:

```toml
[mcp_servers.delphi-mcp-server]
command = '/path/to/MCPServer'
args = ["--stdio"]
```

**Important**: The server must be compiled and the executable path must be absolute.

After configuration:
1. Restart Codex
2. Use `/mcp` command to verify the server is connected
3. Available tools will appear in the Codex interface

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
- **test_simple_text**, **test_image_content**, **test_audio_content**,
  **test_embedded_resource**, **test_multiple_content_types**,
  **test_error_handling**, **test_tool_with_progress**, **test_logging_tool**:
  one small tool per content type, one that fails, one that reports progress
  and honours cancellation, and one that logs at every level, from
  `MCPServer.Tool.ContentSamples`; the conformance suite calls these by name
- **json_schema_2020_12_tool**: a hand-written schema exercising `$schema`,
  `$defs`, `$anchor`, `$ref`, `allOf`/`anyOf` and `if`/`then`/`else`, for the
  conformance suite's schema-preservation check
- **test_input_required_result_elicitation**, **..._sampling**,
  **..._list_roots**, **..._request_state**, **..._multiple_inputs**,
  **..._multi_round**, **..._tampered_state**, **..._capabilities**: multi
  round-trip requests, one per kind of client input plus signed request
  state across one or two round trips, from
  `MCPServer.Tool.InputRequiredSamples`; **test_missing_capability**
  requires the `sampling` client capability and answers `-32021` without it,
  **test_streaming_elicitation** logs to the response stream and then asks
  for a confirmation
- **test_trigger_tool_change**, **test_trigger_prompt_change**,
  **test_trigger_resource_change**: add or remove `test_dynamic_tool` and
  `test_dynamic_prompt`, or report `test://static-text` as updated, so that
  clients on `subscriptions/listen` receive the change notifications, from
  `MCPServer.Tool.SubscriptionSamples`

## Available Example prompts

- **summarize_logs**: summarizes the server's recent log entries, optionally
  filtered by level (argument completion suggests the levels actually
  present in the log buffer)
- **test_simple_prompt**, **test_prompt_with_arguments**,
  **test_prompt_with_embedded_resource**, **test_prompt_with_image**: one
  prompt per content type, from `MCPServer.Prompt.ContentSamples`; the
  conformance suite calls these by name
- **test_input_required_result_prompt**: asks the client for a context
  through an elicitation input request before it renders

## Available Example resources

The server provides six resources and two resource templates, accessible via URIs:

- **server://status** - Current server status and health information (request and connection counters)
- **project://info** - Project information (JSON metadata with collections)
- **project://readme** - This README file (markdown content)
- **logs://recent** - Recent log entries from all categories (with thread safety)
- **logs://{level}** - Recent log entries at one level, e.g. `logs://WARNING`
- **test://template/{id}/data** - A template resource for the conformance suite
- **test://static-text** - A fixed text resource
- **test://static-binary** - A fixed PNG image, delivered as a `blob`

## Configuration

The server supports configuration through `settings.ini` files. A default `settings.ini.example` is provided in the repository.

### Authentication

The HTTP endpoint is open by default, which is fine for a loopback-only
server. A server that other machines can reach should require a token:

- `[Auth] BearerTokens`: comma-separated pre-shared tokens. With this set the
  executable installs `TMCPStaticBearerAuthorizer`; every request except
  `OPTIONS` and the protected resource metadata must carry
  `Authorization: Bearer <token>`. A missing token is `401` with a
  `WWW-Authenticate: Bearer` challenge, an unknown token `401` with
  `error="invalid_token"`, another scheme `400` with `error="invalid_request"`.
  Tokens are compared in constant time and never logged.
- `[Auth] AuthorizationServers`: issuer URLs of the OAuth 2.1 authorization
  servers, published in `GET /.well-known/oauth-protected-resource` and
  `/.well-known/oauth-protected-resource<Endpoint>` (RFC 9728) and referenced
  by the `resource_metadata` parameter of every challenge, so clients can
  discover where to obtain a token. `ResourceUri` is the canonical URI of this
  server that the tokens must name as their audience (default
  `<Protocol>://<Host>:<Port><Endpoint>`); `ScopesSupported` lists the scopes
  clients may request (`offline_access` is never advertised).

A library that hosts `TMCPIdHTTPServer` assigns its own `Authorizer`
(`MCPServer.Authorization`):

- `TMCPStaticBearerAuthorizer.Create(Tokens, Scopes)`: the pre-shared tokens,
  optionally limited to a set of scopes (all scopes by default).
- `TMCPOAuthResourceServerAuthorizer`: the base for token validation against
  an authorization server. Override `ValidateToken(Token, out Claims)`; the
  base class then requires the `aud` claim to name `ExpectedAudience`, the
  `exp` claim to lie in the future, and the `RequiredScopes` to be present in
  `scope` or `scp`, answering `401 invalid_token` or `403 insufficient_scope`
  otherwise. `TMCPIntrospectionAuthorizer` implements `ValidateToken` with an
  RFC 7662 token introspection request (client credentials over HTTP basic
  authentication). Signed-JWT validation is not built in: the RTL has no JOSE
  library, so a deployment that validates JWTs locally supplies its own
  `ValidateToken` on top of its JWT library of choice.
- `[RequiresScope('name')]` on a tool class makes `tools/call` answer `403`
  with `WWW-Authenticate: Bearer error="insufficient_scope", scope="name"`
  unless the caller's token grants that scope. On an open server, and over
  stdio, nobody holds a scope, so such a tool is unusable there.

Tools see the authenticated caller as `Context.Principal` and
`Context.HasScope`. The inbound token is bound to this server: a tool that
calls an upstream API must obtain its own credentials and must never forward
the `Authorization` header it was called with. Authentication is an HTTP
concern; the stdio transport trusts the process that spawned it and never
consults an authorizer.

### Network and Security

- `[Server] BindAddress`: the interface to listen on. Empty (default) derives it from `Host`: a loopback `Host` binds `127.0.0.1` and `::1`, any other `Host` binds every interface. Set `0.0.0.0` to listen everywhere explicitly.
- `[Security] AllowedOrigins`: origins that pass the `Origin` check next to the loopback origins (`localhost`, `127.0.0.1`, `[::1]`, any port). Comma-separated `scheme://host[:port]`; `:*` allows any port; `*` allows everything. Falls back to `[CORS] AllowedOrigins`. A rejected origin gets `403` with a JSON-RPC error body, also when CORS is disabled.
- `[Security] AllowedHosts`: `Host` header values the server answers, comma-separated `host[:port]` (an entry without a port matches any port, `*` matches everything). Empty means any host. Set it when the server is reachable through a public name, so that a rebinding DNS name cannot reach it; a rejected host gets `403`.
- `[Server] ExposeDiagnosticsResources`: `1` (default) registers `logs://recent`, `logs://{level}` and `server://status`; set `0` on a server that strangers can reach, the log buffer and the status counters are diagnostics.
- `[CORS] Enabled`: adds the CORS response headers for browser clients; the `Origin` check runs regardless.
- `[Server] EndpointInfoPath`: optional GET path (for example `/info`) that answers a JSON document with the endpoint URL and the protocol versions. The MCP endpoint itself only accepts POST; GET and DELETE get `405`.
- `[Server] MaxRequestBodyBytes` (4 MB) and `MaxJsonDepth` (64): larger or deeper requests get `413` or `400`; `MaxConnections`: Indy connection limit, `0` = unlimited.

### SSL/TLS Configuration

The Delphi MCP Server supports two SSL/TLS implementations:

1. **Standard Indy SSL** - Uses OpenSSL 1.0.2 (default if TaurusTLS not available)
2. **TaurusTLS** - Uses OpenSSL 3.x or 4.x with modern cipher support (recommended)

#### Installing TaurusTLS

TaurusTLS provides OpenSSL 3.x and 4.x support with modern ECDHE cipher suites required by services like Cloudflare.

**Via a package manager (easiest):**
- **GetIt** (RAD Studio): Tools > GetIt Package Manager, search for "TaurusTLS", click Install
- **DPM**: `dpm install TaurusTLS_Developers.TaurusTLS`
- **TMS Smart Setup**: `tms install taurustls_developers.taurustls`

**Manual Installation:**
1. Clone from https://github.com/TaurusTLS-Developers/TaurusTLS
2. Open `TaurusTLS\Packages\d12\TaurusAll.groupproj`
3. Compile `TaurusTLS_RT`
4. Compile and install `TaurusTLS_DT`

All installation options are documented at https://taurustls.org/download.xhtml

#### Switching Between SSL Implementations

Edit `src\Server\MCPServer.IdHTTPServer.pas`:

```pascal
// To use TaurusTLS (OpenSSL 3.x/4.x):
{$DEFINE USE_TAURUS_TLS}  // Keep this line uncommented

// To use Standard Indy SSL (OpenSSL 1.0.2):
// {$DEFINE USE_TAURUS_TLS}  // Comment out this line
```

#### OpenSSL Requirements

**For TaurusTLS:**

TaurusTLS runs on OpenSSL 3.x and 4.x. Pre-compiled binaries for every supported platform, including Windows on ARM64, are published at https://github.com/TaurusTLS-Developers/OpenSSL-Distribution/releases. Full deployment instructions: https://taurustls.org/deployapps.xhtml

> **OpenSSL 4.x requires TaurusTLS 1.0.5.42 or newer.** Earlier releases only look for the 3.x, 1.1 and 1.0 library names, so a build linked against them fails at startup with `ETaurusTLSCouldNotLoadSSLLibrary: Could not load SSL library` when only 4.x libraries are present. Check `DefaultLibVersions` in `TaurusTLSConsts.pas` if you are unsure which version you have.

*Windows (dynamic linking):*

Ship the OpenSSL DLLs and `LICENSE.txt` alongside your executable:

| Target | OpenSSL 3.x | OpenSSL 4.x |
|--------|-------------|-------------|
| Win32 | `libcrypto-3.dll`, `libssl-3.dll` | `libcrypto-4.dll`, `libssl-4.dll` |
| Win64 | `libcrypto-3-x64.dll`, `libssl-3-x64.dll` | `libcrypto-4-x64.dll`, `libssl-4-x64.dll` |
| Windows ARM64EC | `libcrypto-3-arm64.dll`, `libssl-3-arm64.dll` | `libcrypto-4-arm64.dll`, `libssl-4-arm64.dll` |

Instead of copying DLLs by hand, the OpenSSL-Distribution releases also ship automated installers you can run yourself or chain from your own installer:

- **InnoSetup installer** (`openssl-<version>-Windows-installer.exe`) - one setup covering x86, x64 and ARM64EC, picking the matching runtime by CPU detection. Silent install:
  ```
  openssl-<version>-Windows-installer.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART
  ```
- **MSIX framework packages** (`openssl-<version>-Windows-x64.msix`, `-x86.msix`, `-arm64ec.msix`) - reference them from your own `AppxManifest.xml` as a `PackageDependency` on `TaurusTLS.OpenSSL`.

*Linux (dynamic linking):*
- OpenSSL is usually installed by default; document the dependency for your end users
- Update if needed: `sudo apt-get install libssl-dev` (Debian/Ubuntu) or `sudo yum install openssl-devel` (RHEL/CentOS)
- To pin a specific version, redistribute the Linux package from the OpenSSL-Distribution releases

*macOS, iOS and Android (static linking):*
- OpenSSL is compiled into the application binary; build against the `.a` files in the `lib\static` folder of the platform archive (for example `openssl-<version>-macOS-arm64.zip`)
- Nothing to redistribute besides your application package and `LICENSE.txt`

**For Standard Indy:**
- Requires OpenSSL 1.0.2 DLLs (`libeay32.dll`, `ssleay32.dll`)
- Limited cipher support, not recommended for modern clients

#### Known Issues & Solutions

- **Cloudflare Tunnel**: Standard Indy SSL lacks ECDHE cipher support. Use TaurusTLS or run Cloudflare Tunnel with HTTP: `cloudflared tunnel --url http://localhost:8080`
- **Self-Signed Certificates**: Claude Desktop doesn't accept self-signed certificates. Use Cloudflare Tunnel or a valid certificate from a trusted CA
- **"No shared cipher" error**: Install and enable TaurusTLS for modern cipher support
- **`Could not load SSL library`**: no OpenSSL library TaurusTLS recognises was found. Either the libraries are not where the platform looks for them, or your TaurusTLS version predates 4.x support (see above)
- **The wrong OpenSSL gets loaded**: TaurusTLS asks the OS for the libraries by name, trying the version suffixes newest first, and takes the first hit anywhere on the platform's library search path. Another OpenSSL installation can therefore win over the one you shipped, and your application runs on a version you never tested. Set the `OPENSSL_LIBRARY_PATH` environment variable to an absolute directory to pin the choice; it applies on every platform

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
3. Follow the existing code style (inline vars, named constants, no comments in code); `coding-rules.md` in the repository root lists the conventions this library keeps on purpose
4. Test your changes
5. Submit a pull request

### Development Setup
- Requires Delphi 12+ 
- Open `MCPServer.dproj` or build with `build.bat`
- Test with `npx @modelcontextprotocol/inspector` or Claude Code or similar

### Automated tests

The `tests` folder holds a DUnitX project that drives the JSON-RPC layer, the HTTP transport and the stdio transport in-process and pins the wire behaviour with golden files (`tests\golden`, see the README there).

```bat
build-tests.bat Debug Win64
tests\Win64\Debug\MCPServerTests.exe
```

`build-tests.bat [Config] [Platform]` compiles `tests\MCPServerTests.dpr` for Win32 or Win64; the program takes the usual DUnitX switches (`-xml:<file>` for an NUnit report, `-run:<test>` for a selection). Set the environment variable `MCP_GOLDEN_RECORD=1` for one run to re-record the golden expectations, then review the diff.

## About GDK Software

[GDK Software](https://www.gdksoftware.com) is a Delphi specialist: we build, upgrade and maintain Delphi applications worldwide, and offer Delphi and AI consultancy and AI training.

## Support

- Create an issue on [GitHub](https://github.com/GDKsoftware/delphi-mcp-server/issues)
- Visit our website at [www.gdksoftware.com](https://www.gdksoftware.com)

## Commercial Support

This library is MIT licensed and free to use. For companies that depend on it commercially we offer support and maintenance agreements with guaranteed response times, and sponsored development of features you need, such as upcoming MCP specification revisions. Contact us at [gdksoftware.com/contact-us](https://gdksoftware.com/contact-us) or open an issue to get in touch.