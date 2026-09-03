# Changelog

All notable changes to this project are documented in this file. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- MCP 2026-07-28 at the JSON-RPC layer, on both transports, next to the
  initialize-based revisions 2025-06-18 and 2025-11-25. The era is decided per
  request in `TMCPJsonRpcProcessor.BuildRequestContext`: `initialize` is always
  legacy, a `params._meta` with `io.modelcontextprotocol/protocolVersion` is
  modern, everything else is legacy.
- `server/discover` (`MCPServer.CoreManager`): supported versions,
  capabilities, `_meta.serverInfo`, optional `instructions`, `ttlMs` and
  `cacheScope: "public"`.
- Modern requests: `_meta` validation (`clientCapabilities` required,
  `logLevel` checked, `-32602`), `-32022` with `data.supported` and
  `data.requested` for an unknown revision, `-32020` when the HTTP header and
  the body disagree, `-32601` for the legacy-only methods `ping`,
  `logging/setLevel`, `resources/subscribe` and `resources/unsubscribe`.
- Modern results carry `resultType: "complete"`,
  `_meta.io.modelcontextprotocol/serverInfo` and, for the cacheable methods,
  `ttlMs` and `cacheScope` when the handler did not set them.
- `MCPServer.Errors` (`EMCPError` with code, data and HTTP status, plus
  factories), `MCPServer.RequestContext` (`IMCPRequestContext`, thread-local
  `TMCPRequestContext.Current`, `TMCPTransportHints`), `MCPServer.Capabilities`
  (`TMCPCapabilityBuilder` derives the capabilities from the registered
  managers), and the interfaces `IMCPCapabilityManagerEx`,
  `IMCPCapabilityProvider`, `IMCPManagerEnumerator` and `IMCPRegistryAware` in
  `MCPServer.Types`.
- `TMCPJsonRpcProcessor.ProcessRequestEx` returns body, HTTP status and era;
  `Create(Registry, Settings)` overload; `TMCPStdioTransport.Settings`.
- `settings.ini`: `[Server] Title`, `Description`, `WebsiteUrl`,
  `Instructions`; `[Protocol] LenientModernPing`,
  `DiscoverListsLegacyVersions`, `DiscoverTtlMs`.
- DUnitX test project `tests\MCPServer.Tests.dpr` (Win32 and Win64) with an
  in-process harness that builds the same registry as `MCPServer.dpr` and
  drives the JSON-RPC processor; era-detection, processor, capability-builder
  and concurrency tests.
- Golden files that pin the wire behaviour: JSON-RPC cases for the legacy and
  the modern era in `tests\golden\legacy` and `tests\golden\modern`, and HTTP
  transport cases (status line, headers, body) in `tests\golden\http`.
- `build-tests.bat` and `scripts\run-tests.ps1` (build and run, `-Record`
  to re-record goldens), `scripts\capture-http-goldens.ps1`.
- `scripts\run-conformance.ps1` for the official conformance CLI with one
  expected-failures baseline per requirement set
  (`conformance-baseline-2026-07-28.yml`, `conformance-baseline-2025-11-25.yml`),
  `scripts\run-inspector-smoke.ps1` with `ci-servers.json` (legacy, auto and
  modern eras plus stdio) and `scripts\run-stdio-smoke.ps1`.
- `package.json` pinning the Node tooling (`@modelcontextprotocol/conformance`
  0.2.0-alpha.11, `@modelcontextprotocol/inspector` 2.5.0).
- Protocol constants in `MCPServer.Types`: revision names and sets
  (`MCP_PROTOCOL_VERSION_*`, `MCP_LATEST_PROTOCOL_VERSION`,
  `MCP_LEGACY_PROTOCOL_VERSIONS`, `MCP_MODERN_PROTOCOL_VERSIONS`), the MCP
  error codes `MCP_ERROR_HEADER_MISMATCH` (-32020),
  `MCP_ERROR_MISSING_REQUIRED_CLIENT_CAPABILITY` (-32021),
  `MCP_ERROR_UNSUPPORTED_PROTOCOL_VERSION` (-32022) and
  `MCP_ERROR_RESOURCE_NOT_FOUND_LEGACY` (-32002), the reserved `_meta` keys
  (`MCP_META_*`) and `MCP_CACHEABLE_METHODS`.
- `TLogger.StdoutReserved`: while set, console logging always goes to stderr
  and `UseStdErr := False` is refused with a one-time warning.
- README sections "Protocol Versions and Dual-Era Behaviour", the library
  checklist and "Automated tests".

### Changed

- `initialize` answers the requested revision when it is `2025-06-18` or
  `2025-11-25`, otherwise `2025-11-25` (it always answered `2025-06-18`). The
  result no longer contains the non-standard `sessionId` and the
  `tools.supportsProgress` / `tools.supportsCancellation` keys;
  `tools.listChanged: false` is added. No `Mcp-Session-Id` header is minted;
  `TMCPCoreManager.SessionID` returns an empty string.
- Message-shape errors use the JSON-RPC codes: `-32600` for batch arrays,
  `id: null`, a missing or non-string `method` and a missing `jsonrpc`
  (batch arrays were `-32700`, `id: null` was treated as a notification and
  a missing `jsonrpc` was accepted); `-32602` for a `params` that is not an
  object. Client responses (`result` or `error` without `method`) are ignored.
- The `initialize` capabilities come from the registered managers
  (`IMCPCapabilityProvider`); a registry with only a tools manager no longer
  advertises resources.
- The `JSONRPC_*` error-code constants are defined once in `MCPServer.Types`.
  `MCPServer.JsonRpcProcessor` keeps them as aliases, so existing consumer
  code compiles unchanged; the unused duplicate block in
  `MCPServer.IdHTTPServer` is gone.
- `TMCPRegistry` creates its dictionaries in a class constructor. Registration
  must complete before the managers are created (before
  `TMCPIdHTTPServer.Start` or `TMCPStdioTransport.Run`); this was already the
  case and is now documented, also for `TServerStatusResource.SetNamePrefix`.
- `TMCPStdioTransport.Create` forces `TLogger.UseStdErr := True` and sets
  `TLogger.StdoutReserved`. Library consumers that create the transport with
  console logging enabled and never set `UseStdErr` now get their log lines on
  stderr instead of corrupting the MCP channel on stdout.

### Fixed

- `TServerStatusResource` request and connection counters and the SSE event-id
  counter are updated atomically; they were plain increments shared by all
  Indy connection threads.
- `logs://recent` answered "Error reading resource: Invalid pointer operation":
  the copied log entries were owned by two lists and freed twice.
- `TMCPSerializer` serialised `TList<T>` and `TObjectList<T>` properties as an
  object with `count` and `capacity` members. They are JSON arrays now, so
  `project://info` lists its features and `logs://recent` its entries.
- `server://status` was declared but never registered by the executable; the
  unit registers it by default now, and `SetNamePrefix` replaces that
  registration instead of adding a second URI (`TMCPRegistry.UnregisterResource`
  is new).
- `resources/read` without `params` raised an access violation (returned as
  `-32603`); it is now handled like a missing `uri`.
- `tools/call` without `arguments` raised an access violation inside the tool
  (returned as an `isError` result); the tool now receives an empty object.
