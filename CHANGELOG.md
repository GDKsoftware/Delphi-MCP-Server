# Changelog

All notable changes to this project are documented in this file. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Prompts: `MCPServer.Prompt.Base` (`IMCPPrompt`, `TMCPPromptBase`,
  `TMCPPromptBase<T>` with RTTI-derived arguments, `TMCPPromptMessages` for
  text/image/audio/resource-link/embedded-resource content) and
  `MCPServer.PromptsManager` (`prompts/list` with pagination and modern cache
  hints, `prompts/get` with `-32602` for an unknown prompt or a missing
  required argument). `MCPServer.Prompt.SummarizeLogs` (an example that
  embeds `logs://recent` and offers level completion) and
  `MCPServer.Prompt.ContentSamples` (`test_simple_prompt` and friends, the
  conformance fixtures for prompts).
- Resource templates: `IMCPResourceTemplate`, `TMCPResourceTemplateBase`
  (RFC 6570 level 1 and a level 2 subset, `{var}` and `{+var}`),
  `TMCPRegistry.RegisterResourceTemplate`; `resources/templates/list` lists
  them and `resources/read` resolves a URI against them when no exact
  resource matches. `logs://{level}` (`MCPServer.Resource.Logs`) and
  `test://template/{id}/data` (`MCPServer.Resource.Samples`, the conformance
  fixture) are the examples.
- Completion: `MCPServer.CompletionManager` (`completion/complete` for
  `ref/prompt` and `ref/resource`, capped at 100 values with `hasMore`),
  `IMCPCompletable` and `TMCPCompletion`, implemented optionally by a prompt
  or resource template; a target without it answers an empty `values` array.
- `MCPServer.Schema.Validator`: a JSON Schema 2020-12 subset validator (type,
  enum, const, required, properties, items, additionalProperties, minimum,
  maximum, minLength, maxLength, pattern, a same-document `$ref`, a depth
  cap) used by `TMCPToolBase`'s own argument validation and, in DEBUG builds,
  to warn when a tool's `structuredContent` does not match its
  `outputSchema`.
- Schema attributes `SchemaMinLength`, `SchemaMaxLength`, `SchemaPattern`,
  `SchemaDefault`, `SchemaName` (overrides the wire name, honoured by the
  serializer too) and the class-level `SchemaAdditionalProperties` and
  `SchemaDialect` (root schema only).
- `json_schema_2020_12_tool`: a hand-written schema exercising `$schema`,
  `$defs`, `$anchor`, `$ref`, `allOf`/`anyOf` and `if`/`then`/`else`, the
  conformance fixture for schema-keyword preservation.
- `MCPServer.ContentBlocks`: the text/image/audio/resource-link/embedded-
  resource block builders shared by `TMCPToolResult` and
  `TMCPPromptMessages`, so both produce byte-identical content blocks.
- Rewritten stdio transport (`MCPServer.StdioTransport`, `MCPServer.StdioChannel`):
  UTF-8 byte framing on the standard handles instead of Text I/O (`é` and
  other non-ASCII input used to come back mangled), a reader thread that
  answers notifications, client responses and legacy `ping` inline, and
  `[Server] MaxConcurrentRequests` (default 1) worker threads for everything
  else, so responses keep arriving in request order by default.
- `notifications/cancelled` over stdio: the named request stops and gets no
  response (`IMCPRequestContext.IsCancelled`, `CheckCancelled`, `Cancel`,
  `IMCPRequestTracker`). `_meta.progressToken` on a request gets
  `notifications/progress` before its response
  (`IMCPRequestContext.ReportProgress`, monotonic and throttled to one every
  50 ms except the notification that reaches the total).
  `test_tool_with_progress` (`MCPServer.Tool.ContentSamples`) exercises both.
- On EOF, stdin closing drains in-flight work for `ShutdownDrainMs` (2 s
  default) before cancelling what is left; the process no longer waits on a
  request that never finishes.
- A stdio server never writes `settings.ini` next to the executable; the
  Windows console-control handler and the POSIX `SIGINT`/`SIGTERM` handlers,
  and the debug memory-leak report, are skipped in stdio mode.
- Streamable HTTP for both eras in `MCPServer.IdHTTPServer`: the processor's
  HTTP status is answered (400 for modern protocol errors, 404 for an unknown
  method in the modern era, 200 for every legacy JSON-RPC error); `Mcp-Method`
  and `Mcp-Name` are validated against the body for modern requests
  (`MCPServer.HttpHeaders`: strict Base64 sentinel decoding, Accept parsing,
  Origin policy, JSON depth scanner); every 4xx carries a JSON-RPC error body.
- `settings.ini`: `[Server] BindAddress`, `EndpointInfoPath`,
  `MaxRequestBodyBytes`, `MaxJsonDepth`, `MaxConnections`;
  `[Security] AllowedOrigins`.
- `TMCPIdHTTPServer.BoundAddresses`; a `Port` of 0 lets the system choose.
- `TLogger.RedactJson`; request and response bodies are logged at Debug level
  with `_meta`, `requestState`, `inputResponses` and token-like members
  redacted.
- `MIGRATION.md` with the behaviour changes and how to configure them.
- In-process HTTP transport tests (`TIdHTTP` against an ephemeral port) and
  header tests; HTTP golden cases for the modern requests.

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
- DUnitX test project `tests\MCPServerTests.dpr` (Win32 and Win64) with an
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
- `TMCPToolResult` (`MCPServer.Tool.Result`): a builder for tool results with
  text, image, audio, embedded resource and resource link content blocks,
  `structuredContent`, `_meta`, per-block annotations and `isError`;
  `EncodeBase64Blob` encodes without line breaks.
- `TMCPToolBase<T>.ExecuteWithContext(Params, Context)` returning a `TValue`
  (a string, a `TMCPToolResult`, a `TJSONObject` for structured content or a
  ready-made `TJSONArray` of content blocks) next to `ExecuteWithParams`;
  `EMCPToolError` for a failure the tool wants reported as an `isError` result.
- Tool metadata through `IMCPToolMetadata` (`annotations`, `icons`) on every
  tool base; resource metadata through `IMCPResourceMetadata` (`title`, `size`,
  `annotations`), `IMCPBinaryResource` (`blob` contents) and
  `IMCPCacheableResource` (`ttlMs`, `cacheScope`) on `TMCPResourceBase<T>`.
- `TMCPToolsManager` and `TMCPResourcesManager`: `AddTool` / `AddResource`
  for instances outside `TMCPRegistry`, `ListTtlMs` and `ListCacheScope` for
  the modern list results.
- Schema attributes `SchemaTitle`, `SchemaFormat`, `SchemaMinimum` and
  `SchemaMaximum`.
- Example tools `test_simple_text`, `test_image_content`, `test_audio_content`,
  `test_embedded_resource`, `test_multiple_content_types` and
  `test_error_handling` (`MCPServer.Tool.ContentSamples`) and the resources
  `test://static-text` and `test://static-binary`
  (`MCPServer.Resource.Samples`): one example per content type, and the
  fixtures the conformance suite calls.
- `EMCPError.UnknownTool` and `EMCPError.ResourceNotFound(Uri, Era)`;
  `MCP_CACHE_SCOPE_PUBLIC` and `MCP_CACHE_SCOPE_PRIVATE`.
- Tests for the tool result builder, the serializer, the schema generator and
  the tools and resources managers in both eras.
- Multi round-trip requests (MCP 2026-07-28): `EMCPInputRequired`,
  `TMCPInputRequests` and `TMCPInputResponse` in `MCPServer.Mrtr`; the
  processor answers `tools/call`, `resources/read` and `prompts/get` with an
  `InputRequiredResult` (`resultType: input_required`, `inputRequests`,
  `requestState`), validates `inputResponses` on the retry (`-32602` when
  not an object of objects), only sends input requests the client declared
  a capability for (`-32021` otherwise) and answers `-32603` to legacy
  clients. `IMCPRequestContext` gains `InputResponses`, `RequestState` and
  `TryGetInputResponse`.
- `TMCPRequestStateSealer` (`MCPServer.RequestState`): HMAC-SHA256 sealed
  `requestState` tokens bound to the method, a digest of the request
  parameters, the principal and an expiry; `[Security] RequestStateKey` and
  `RequestStateTtlSeconds` in `settings.ini`.
- Example tools `test_input_required_result_elicitation`, `_sampling`,
  `_list_roots`, `_request_state`, `_multiple_inputs`, `_multi_round`,
  `_tampered_state`, `_capabilities` and `test_missing_capability`
  (`MCPServer.Tool.InputRequiredSamples`) and the prompt
  `test_input_required_result_prompt`: the multi round-trip fixtures of the
  conformance suite.

### Changed

- `TMCPToolBase` (the non-generic, hand-written-schema base) now validates
  its arguments against `BuildSchema` before calling the tool: the abstract
  method a descendant overrides is `DoExecute`, not `Execute`, which is now
  a concrete template method. Tools deriving from `TMCPToolBase` previously
  got no argument validation at all; `TMCPToolBase<T>` and
  `TMCPToolBase<T, R>` are unaffected (their arguments already go through
  `TMCPSerializer`).
- The property name a tool or prompt parameter class publishes on the wire
  is looked up the same way in both directions: `TMCPSerializer` honours
  `[SchemaName]` for deserializing and serializing, not only the schema
  generator.
- Non-ASCII input over stdio is decoded and echoed back unchanged; Text I/O
  decoded stdin with the console code page, corrupting characters outside it
  (a Windows console defaults to an ANSI code page, not UTF-8).
- A duplicate request id on stdio while the first is still in flight is
  `-32600`, answered at once, instead of being queued behind it.
- `settings.ini`: `[Server] MaxConcurrentRequests` (default 1).
- The server binds to loopback (`127.0.0.1` and `::1`) when `Host` is
  `localhost`; it listened on every interface. A non-loopback `Host` or an
  explicit `BindAddress` binds elsewhere.
- The `Origin` header is validated on every request, also with CORS disabled
  (it was only checked when CORS was on): loopback origins on any port pass,
  other origins must be in `[Security] AllowedOrigins` or `[CORS]
  AllowedOrigins`, `null` is refused; a rejected origin gets `403` with a
  JSON-RPC error body and `Vary: Origin`.
- GET and DELETE on the MCP endpoint answer `405` with `Allow: POST, OPTIONS`
  (GET answered an endpoint document or an immediately closed stream);
  OPTIONS answers `204`; an unknown path `404` without a body.
- Notifications and client responses get `202` with an empty body instead of
  Indy's HTML body; SSE responses lose the `id:` line and the duplicate
  `Connection` header; the CORS headers list `POST, OPTIONS`, the modern
  request headers and `WWW-Authenticate`, and reflect a preflight's
  `Access-Control-Request-Headers`.
- A legacy request whose `MCP-Protocol-Version` header names an unknown
  revision gets `400` (it got `200`).
- TLS 1.0 and 1.1 are no longer offered on the OpenSSL 1.0.2 handler.
- `USE_TAURUS_TLS` is defined in `src\MCPServer.inc`; the build scripts pass
  `-Isrc`. The test program is `tests\MCPServerTests.dpr`.
- An `initialize` request that carries modern `_meta` is a modern request and
  therefore an unknown method (`-32601`, HTTP 404), as a modern client probing
  the server expects; only an `initialize` without modern `_meta` is legacy.
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
- `tools/call` with an unknown tool answers `-32602` with `data.name` (it
  answered an `isError` result "Tool not found"); a missing or empty `name`
  and an `arguments` that is not an object are `-32602` as well (they were an
  `isError` result "Invalid tool parameters").
- `resources/read` for an unknown URI answers `-32002` with `data.uri` for
  initialize-based clients and `-32602` with `data.uri` for modern clients (it
  answered a text content "Error: Resource not found"); a missing `uri` is
  `-32602`, a read that raises is `-32603`.
- Tool arguments are checked against the schema before the tool runs: a
  missing required parameter, a value of the wrong JSON type, a fraction for an
  integer or an unknown enumeration name is an `isError` result that names the
  parameter. Missing parameters were silently defaulted and wrong types
  coerced.
- Every `tools/call` result has a `content` array; a typed result
  (`TMCPToolBase<T, R>`) gets a text block with the compact JSON next to
  `structuredContent`, so clients without structured-content support see it.
- Tools and resources are listed in registration order (they were listed in
  dictionary order).
- Generated schemas: integer properties are `integer` (they were `number`),
  `TDateTime` is a `string` with `format: date-time`, enumerations, sets,
  dynamic arrays, `TList<T>` and nested classes get typed schemas, and a tool
  without parameters gets `additionalProperties: false`.
- Serialisation of results and resource data: enumerations by name (they were
  written as booleans), sets and dynamic arrays as arrays, `nil` objects as
  `null`, `TDateTime` as an ISO 8601 string (the `logs://recent` timestamps and
  the `server://status` times were floating-point day numbers).
- `resources/list` carries `title`, `size` and `annotations` when the resource
  provides them and omits an empty `description` or `mimeType`. Modern
  `tools/list`, `resources/list`, `resources/templates/list` and
  `resources/read` results carry `ttlMs` and `cacheScope` from the manager or
  the resource.
- `logs://recent` no longer writes an access-log entry on every read;
  `project://info` reports `MCP 2026-07-28 (initialize-based: 2025-11-25,
  2025-06-18)` and is cacheable for an hour (`cacheScope: public`).

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
- The result object of a `TMCPToolBase<T, R>` tool was cloned into
  `structuredContent` and never freed; every call leaked it.
- Enumeration properties of a result were serialised as booleans.
- Resource templates compiled their pattern into one shared `TRegEx` and
  matched on it from every Indy thread at once; matching is thread-safe now.
  Template variables are percent-decoded only: a `+` in a URI stays a `+`.
- The stdio worker threads could still be running when the transport was
  freed after the drain timeout; the transport now leaves the shared objects
  in place for them instead of freeing them under a running thread.
- The stdio line reader read a line longer than the limit into memory before
  rejecting it; it now discards such a line chunk by chunk up to its newline.
- `TMCPLegacySession` was read and written by several threads without a
  lock.
- Origin allow-list entries without a port did not match an `Origin` header
  that spelled out the default port (`https://app.example:443`), and the
  other way round.
- `jsonrpc`, `method`, `protocolVersion`, `MCP-Name` and the cancel `reason`
  were accepted when they were numbers, because `TJSONNumber` descends from
  `TJSONString`; `IsJsonString` in `MCPServer.Types` tells them apart.
- `completion/complete` for an unknown `ref/resource` answers `-32002` to a
  legacy client (`-32602` stays for a modern one).
- `TMCPCompletionManager` did not hold a reference to the prompts and
  resources managers it was given as interfaces.
- The `/info` endpoint listed the protocol versions in a fixed string; it
  now derives them from the supported version lists, newest first.
- An invalid JSON literal in a `[SchemaDefault]` attribute raises
  `EArgumentException` instead of being silently dropped.
- A tool result that fails to serialise no longer leaks the partial JSON
  object; the DEBUG `outputSchema` check no longer leaks the schema.
