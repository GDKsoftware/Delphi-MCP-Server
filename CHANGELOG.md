# Changelog

All notable changes to this project are documented in this file. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

Safety net for the MCP 2026-07-28 work: the legacy wire behaviour is pinned
before any protocol change lands. No client-visible protocol change.

### Added

- DUnitX test project `tests\MCPServer.Tests.dpr` (Win32 and Win64) with an
  in-process harness that builds the same registry as `MCPServer.dpr` and
  drives `TMCPJsonRpcProcessor.ProcessRequest`.
- Golden files that pin today's responses: 37 JSON-RPC cases in
  `tests\golden\legacy` and 26 HTTP transport cases (status line, headers,
  body) in `tests\golden\http`, recorded from the unchanged 2025-06-18 code.
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

### Changed

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
- README: library checklist (register before start, stdout rules for stdio,
  `server://status` is opt-in), automated-tests section, resource list matches
  what the executable registers.

### Fixed

- `TServerStatusResource` request and connection counters and the SSE event-id
  counter are updated atomically; they were plain increments shared by all
  Indy connection threads.
