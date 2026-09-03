# Implementation plan: MCP specification 2026-07-28 (dual-era)

Status: proposal, 2026-09-03. Target repository: `GDKsoftware/delphi-mcp-server` (currently MCP 2025-06-18).

This plan upgrades the Delphi MCP Server to the newest protocol revision, **2026-07-28**, while keeping it
backwards compatible on two fronts:

1. **Wire compatibility.** Clients that still use the `initialize` handshake (revisions 2025-06-18 and 2025-11-25,
   which is every shipping end-user client today) keep working unchanged. The spec calls this a *dual-era server*
   and explicitly allows it (`basic/versioning.mdx`, "Backward Compatibility with Initialization-Based Versions").
2. **Library compatibility.** Projects that embed this repository (custom `TMCPToolBase<T>` tools,
   `TMCPResourceBase<T>` resources, `IMCPCapabilityManager` managers, `TMCPRegistry`, `TMCPIdHTTPServer`,
   `TMCPStdioTransport`) keep compiling and behaving. Every extension is a new interface probed with `Supports()`,
   a new overload, a new unit, a new protected field with a safe default, or a new ini key with a compatible default.

The plan is split into eight independently releasable phases (roughly 50 to 65 senior-Delphi developer days in
total). Phases 0 to 3 alone (about 25 days) already let 2026-07-28 clients talk to the server on both transports.

Supporting material (machine-generated, not curated):

- `docs/analysis/mcp-2026-07-28-gaps.md`: 129 gaps found by comparing the code against the spec text, per area,
  with file/line references and suggested changes. Gap ids (`GAP-BP-01` etc.) in this plan refer to that file.
- `docs/analysis/mcp-2026-07-28-gap-analysis.json`: the same data plus four candidate plans and two judge reports.

---

## 1. Summary and recommendation

- Implement 2026-07-28 as the **modern** era and keep 2025-06-18 / 2025-11-25 as the **legacy** era on the same
  endpoint and the same stdio process. The era is decided **per request** (see section 4), never per connection.
- Make the transport-independent `TMCPJsonRpcProcessor` the single place that detects the era, validates `_meta`
  and HTTP headers, dispatches, decorates results (`resultType`, `_meta.serverInfo`, `ttlMs`/`cacheScope`) and
  decides the HTTP status. Both transports become thin.
- Add the new MUSTs first (`server/discover`, per-request `_meta`, `resultType`, cache hints, header validation,
  error codes, Origin validation), then the modern features that matter for tool authors (progress, cancellation,
  elicitation via Multi Round-Trip Requests), then optional capabilities (prompts, completion, templates,
  `subscriptions/listen`) and an opt-in authorization hook.
- Do **not** add features the spec deprecated in 2026-07-28 (logging capability, roots, sampling, HTTP+SSE 2024-11-05
  transport, Dynamic Client Registration). Do not implement the Tasks extension in this round.
- Build the test safety net (DUnitX + golden files + the official conformance CLI + MCP Inspector) before
  changing behaviour; the repository has no tests today.

Order of phases and the effort ranges:

| Phase | Content | Days | Release |
|---|---|---|---|
| 0 | Test harness, legacy golden files, constants, thread-safety hygiene | 3–4 | 1.0.1 |
| 1 | Protocol core: typed errors, request context, era detection, `server/discover`, result envelope | 7–9 | 1.1.0 |
| 2 | Dual-era Streamable HTTP: headers, status codes, Origin, 202/405, no sessions, bind, TLS, limits | 6–8 | 2.0.0 |
| 3 | Tools and resources: schema-valid modern results, error codes, content builders, schema generator | 7–9 | 2.1.0 |
| 4 | stdio: UTF-8 framing, reader/worker/writer, cancellation, progress, shutdown | 5–7 | 2.2.0 |
| 5 | Prompts, completion, resource templates, schema validation | 6–8 | 2.3.0 |
| 6 | Incremental SSE in Indy, MRTR/elicitation, `requestState` HMAC, minimal `subscriptions/listen` | 9–12 | 2.4.0 |
| 7 | Authorization hook (resource-server role), hardening, docs, conformance baseline | 5–7 | 2.5.0 |

Phase 2 is the first release with runtime-visible default changes (security defaults), hence the 2.0.0 label.

---

## 2. Where the server stands today

Implemented (claimed 2025-06-18): `initialize` / `notifications/initialized` / `ping`, `tools/list`, `tools/call`
(text content, `structuredContent`, `isError`), `resources/list`, `resources/read`, `resources/templates/list`
(always empty); Streamable HTTP over Indy (POST answered as JSON or a single-event SSE body, GET, OPTIONS, CORS,
`Mcp-Session-Id` echo), stdio (one JSON line per message), RTTI schema generation, TLS via TaurusTLS.

Most important deviations found (full list in `docs/analysis/mcp-2026-07-28-gaps.md`):

| Area | Finding | Where |
|---|---|---|
| Lifecycle | `params._meta` is never read, so a 2026-07-28 request is silently served with legacy semantics | `MCPServer.JsonRpcProcessor.pas` |
| Lifecycle | `server/discover` (a modern MUST) answers `-32601`, so a modern or dual-era client concludes "legacy server" | `MCPServer.CoreManager.pas` |
| Lifecycle | `initialize` ignores the requested version and always answers `2025-06-18`; capabilities use non-schema keys (`supportsProgress`, `supportsCancellation`) and a non-standard `sessionId` body field | `MCPServer.CoreManager.pas:101-126` |
| Lifecycle | `FSessionID` is one field shared by all clients and written from Indy worker threads | `MCPServer.CoreManager.pas:97` |
| Errors | Error code is guessed from the exception text (`'not found'` → `-32601`, else `-32603`); `error.data` cannot be sent; `-32602`, `-32020/21/22` cannot be expressed | `MCPServer.JsonRpcProcessor.pas:209-217` |
| HTTP | HTTP status is always 200; `MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name` are never read; Origin is only checked when CORS is enabled and the list is not `*`; 202 responses get Indy's default HTML body; GET returns a custom JSON info body; server binds to all interfaces; TLS 1.0/1.1 enabled on the non-Taurus path | `MCPServer.IdHTTPServer.pas` |
| HTTP | SSE is not streamed (one string assigned to `ContentText`), so progress notifications and long-lived streams are impossible | `MCPServer.IdHTTPServer.pas:488-501` |
| stdio | Blocking single-threaded loop (a long tool call blocks `ping` and `notifications/cancelled`); Text I/O uses the ANSI code page for input on Windows; SIGTERM is not honoured; an uncorrelated `id: null` error may be written to stdout | `MCPServer.StdioTransport.pas`, `MCPServer.dpr` |
| Tools | Unknown tool and malformed params return an `isError` text result instead of `-32602`; `tools/call` without `arguments` dereferences nil; `TMCPToolBase<T,R>` results lack the required `content` array; `Integer` maps to `"number"`; nested objects and arrays have no shape; list order is hash order | `MCPServer.ToolsManager.pas`, `MCPServer.Schema.Generator.pas` |
| Resources | Resource not found and read errors are returned as successful text content; no blob contents; no templates | `MCPServer.ResourcesManager.pas:134-170` |
| Other | No prompts, completion, pagination, progress, cancellation, authorization; no tests; Windows-only build script | repository |

---

## 3. What changed in the specification (server-relevant)

**2025-06-18 → 2025-11-25** (still handshake-based, "legacy" in this plan): icons on tools/resources/prompts,
`Implementation.description`, tool naming guidance (1–128 chars, `[A-Za-z0-9_.-]`), input-validation errors as
tool errors (`isError`, SEP-1303), JSON Schema 2020-12 as default dialect, HTTP 403 on invalid Origin, SSE polling,
experimental tasks, elicitation enum/URL-mode changes, OAuth discovery updates.

**2025-11-25 → 2026-07-28** ("modern"):

| Change | Consequence for this server |
|---|---|
| No `initialize` handshake, no protocol sessions (`Mcp-Session-Id` gone). Every request carries `_meta.io.modelcontextprotocol/protocolVersion` (required), `clientCapabilities` (required), `clientInfo` (SHOULD), `logLevel` (optional) | Per-request context; reject missing fields with `-32602` (HTTP 400) |
| `server/discover` MUST be implemented (supportedVersions, capabilities, `_meta.serverInfo`, `instructions`, `ttlMs`, `cacheScope`) | New core method; also the stdio "era probe" for clients |
| Every result MUST carry `resultType` (`"complete"` or `"input_required"`); results SHOULD carry `_meta.io.modelcontextprotocol/serverInfo` | Central result decoration |
| `tools/list`, `prompts/list`, `resources/list`, `resources/templates/list`, `resources/read`, `server/discover` MUST carry `ttlMs` (≥ 0) and `cacheScope` (`public`/`private`); `tools/list` SHOULD be deterministic | Cache hints and registration-order lists |
| Streamable HTTP: `MCP-Protocol-Version`, `Mcp-Method` on every POST, `Mcp-Name` on `tools/call`/`resources/read`/`prompts/get`; values must match the body (Base64 sentinel `=?base64?…?=` allowed); mismatch or missing → 400 + `-32020`; unsupported version → 400 + `-32022` with `data.supported`/`requested`; unknown method → 404 + `-32601`; GET/DELETE → 405; `Last-Event-ID`/SSE ids removed; closing the stream = cancellation | HTTP pipeline rewrite; status codes are era-gated |
| Servers MUST NOT send JSON-RPC requests to the client. Elicitation/sampling/roots go through **MRTR**: the server answers `tools/call`, `resources/read` or `prompts/get` with `resultType: "input_required"` + `inputRequests` (+ opaque, integrity-protected `requestState`), the client retries with `inputResponses` | New authoring API for elicitation; HMAC-protected state |
| `subscriptions/listen` replaces the GET stream and `resources/subscribe`; server must acknowledge first and tag notifications with `_meta.io.modelcontextprotocol/subscriptionId` | Optional, only needed once `listChanged`/`subscribe` are advertised |
| `ping`, `logging/setLevel`, `notifications/roots/list_changed` removed from the modern era; log level per request via `_meta.logLevel` | Legacy-only method gate |
| Error-code policy: `-32020` HeaderMismatch, `-32021` MissingRequiredClientCapability, `-32022` UnsupportedProtocolVersion; resource not found is `-32602` (modern) instead of `-32002` (legacy) | Typed error model |
| Tool `inputSchema`/`outputSchema` may use any JSON Schema 2020-12 keyword; `structuredContent` may be any JSON value; optional `x-mcp-header` mirroring into `Mcp-Param-*` headers | Schema generator fixes |
| Extensions framework (`capabilities.extensions`); Tasks moved to the `io.modelcontextprotocol/tasks` extension | Out of scope this round |
| Deprecated (12-month window): roots, sampling, logging, HTTP+SSE transport, Dynamic Client Registration | Do not add |

Ecosystem status (from the spec repository blog, 2026-07-28 and 2026-06-29 posts): the four Tier-1 SDKs
(TypeScript, Python, Go, C#) speak 2026-07-28; Python v2 and the TypeScript handler serve both eras from one
endpoint; modern clients fall back to `initialize` when they meet a legacy server. The spec repository does not
document which end-user clients (Claude Code, Codex, Claude Desktop, Cursor) already send modern requests, so the
legacy path must be treated as the primary product for at least the deprecation window. The official conformance
suite (`npx @modelcontextprotocol/conformance`) has frozen server requirement sets for both 2025-11-25 and
2026-07-28, and MCP Inspector can be pinned to `legacy`, `auto` or `modern` era per server.

---

## 4. Compatibility strategy

### 4.1 Era model

The era is a property of each JSON-RPC message and is decided in exactly one function
(`TMCPJsonRpcProcessor.BuildRequestContext`), used by both transports:

1. `method = "initialize"` → **legacy**, always (even if `_meta` is present).
   Version negotiation: if `params.protocolVersion` is `2025-11-25` or `2025-06-18`, echo it; otherwise answer
   `2025-11-25` (the latest served legacy version, as the legacy lifecycle text prescribes). `2025-03-26` is
   accepted on `initialize` but not served as such (see decision D1). On stdio the negotiated version is stored in
   a per-process side slot; it never becomes a one-way latch (an `initialize` may follow modern messages and
   vice versa, and `server/discover` must keep answering after an `initialize`).
2. `params._meta["io.modelcontextprotocol/protocolVersion"]` is a string → **modern**. Validation order:
   1. HTTP only: `MCP-Protocol-Version` header missing or different from the `_meta` value → `-32020` / 400.
   2. Version not in the modern set (`2026-07-28`) → `-32022` / 400 with `data.supported` and `data.requested`.
   3. HTTP only: `Mcp-Method` must equal `method`; `Mcp-Name` must equal `params.name` / `params.uri` for
      `tools/call`, `resources/read`, `prompts/get` (after strict Base64-sentinel decoding) → else `-32020` / 400.
   4. `clientCapabilities` missing or not an object → `-32602` / 400. `logLevel` present but invalid → `-32602`.
   5. Method is legacy-only (`ping`, `initialize`, `logging/setLevel`, `resources/subscribe`,
      `resources/unsubscribe`) → `-32601` / 404 (setting `LenientModernPing` may exempt `ping`).
3. Method name is unambiguously modern (`server/discover`, `subscriptions/listen`) but `_meta` is absent →
   treat as a malformed modern request → `-32602` / 400. (Serving it as legacy would violate the spec.)
4. HTTP only: header names a modern version but the body has no `_meta` → `-32602` / 400. Header value that is
   in neither version set → 400 with a `-32600` body (legacy transport rule). Header absent and no `_meta` →
   legacy.
5. Otherwise → **legacy**, served with the negotiated version (stdio), the header version (HTTP), or
   `2025-11-25` semantics when nothing is known. The spec allows treating header-less requests as `2025-03-26`;
   because this server does not serve `2025-03-26` (D1) it serves them with the latest legacy semantics and says
   so in the README.

### 4.2 What each era gets

| Aspect | Legacy request | Modern request |
|---|---|---|
| Result decoration | untouched (byte-identical to today, except the allow-list below) | `resultType`, `_meta.serverInfo`, `ttlMs`/`cacheScope` on the six cacheable methods |
| JSON-RPC errors over HTTP | always HTTP 200 (404 means "session terminated" to legacy clients and must never be used) | 400 for `-32700`, `-32600`, `-32020`, `-32021`, `-32022` and `_meta`-level `-32602`; 404 for `-32601`; 200 for application-level `-32602` (unknown tool, resource not found, bad cursor) |
| Unknown tool / resource | `-32602` / `-32002` errors (spec-required in the legacy revisions too) | `-32602` with `data.uri` / `data.name` |
| `ping` | works | `-32601` (removed in 2026-07-28) |
| Sessions | `Mcp-Session-Id` never minted; an incoming one is echoed back only if it is visible ASCII | header ignored |
| Elicitation | tool gets an `isError` text explaining that interactive input needs MCP 2026-07-28 | `InputRequiredResult` (MRTR) |
| Disconnect of an SSE response | logged only | cancellation of the request |

Every 4xx returned to a modern request carries a JSON-RPC error body; dual-era clients use that body to decide
that the server is modern rather than falling back to `initialize`.

### 4.3 Legacy wire changes that are deliberately allowed

The Phase 0 golden files pin today's legacy responses. Only the following differences are permitted afterwards,
and the golden runner enforces the allow-list:

1. `initialize` echoes the negotiated `protocolVersion` (today always `2025-06-18`).
2. `initialize` result loses the non-standard `sessionId` and the non-schema `tools.supportsProgress` /
   `tools.supportsCancellation` keys; `tools.listChanged: false` is added.
3. Unknown tool / malformed `tools/call` params → JSON-RPC `-32602`; resource not found → `-32002`;
   resource read exception → `-32603` (all spec-required).
4. `tools/call` results with `structuredContent` also carry a `content` text block (required by the schema).
5. `tools/list` / `resources/list` return registration order; schema text changes (`integer`, nested shapes,
   `additionalProperties: false` for parameter-less tools). Valid in every revision; consumers with snapshot
   tests must refresh them.
6. HTTP: GET/DELETE → 405; Origin validated even when CORS is disabled; loopback bind; TLS ≥ 1.2. Each has a
   one-line ini opt-out.

### 4.4 Library compatibility rules

- `IMCPCapabilityManager`, `IMCPManagerRegistry`, `IMCPTool`, `IMCPResource` keep their GUIDs and members.
  New behaviour is reached through new interfaces (`IMCPCapabilityManagerEx`, `IMCPCapabilityProvider`,
  `IMCPContextAwareTool`, `IMCPToolMetadata`, `IMCPCacheableResource`, `IMCPResourceReader`,
  `IMCPResourceMetadata`, `IMCPResourceTemplate`, `IMCPPrompt`, `IMCPCompletable`, `IMCPAuthorizer`,
  `IMCPMessageSink`) probed with `Supports()`; the shipped base classes implement them, so subclasses inherit them.
- Unchanged tools and managers still see the request (era, capabilities, progress, cancellation) through a
  thread-local `TMCPRequestContext.Current` (Indy runs one connection per thread; stdio workers clear it in
  `finally`; store the reference in a `Pointer` threadvar with manual `_AddRef`/`_Release` to avoid the managed-
  threadvar leak).
- `TMCPToolBase<T>.ExecuteWithParams(const Params: T): string` stays the documented override. The context-aware
  virtual gets a distinct name (`ExecuteWithContext`) so existing subclasses never hit overload/hiding errors.
- `TMCPJsonRpcProcessor.Create(Registry)` and `ProcessRequest(Body, SessionID): string` remain; the new
  `ProcessRequestEx(Body, Hints): TMCPProcessResult` is an addition. `TMCPStdioTransport.Create(Registry, CoreManager)`,
  `TMCPIdHTTPServer.Start/Stop/ManagerRegistry/CoreManager/Settings/Port`, `TMCPRegistry.*` and the
  `JSONRPC_*` / `MCP_PROTOCOL_VERSION` constants remain (constants re-exported as aliases).
- Every new ini key has a default that reproduces today's behaviour, except the three documented security
  defaults (Origin always validated, loopback bind, TLS ≥ 1.2).
- A `MIGRATION.md` lists every behaviour change with its escape hatch.

---

## 5. Target architecture

New or changed units (paths under `src/`):

| Unit | Purpose |
|---|---|
| `Protocol/MCPServer.Types.pas` | Version tables (`MCP_LATEST_PROTOCOL_VERSION`, modern/legacy sets), `_meta` key constants, error-code constants (`-32020/21/22`, legacy `-32002`), cacheable-method list, new interfaces. `MCP_PROTOCOL_VERSION` kept as the legacy default alias |
| `Protocol/MCPServer.Errors.pas` (new) | `EMCPError` (Code, owned `Data`, optional `HttpStatus`) with factories `MethodNotFound`, `InvalidParams`, `InvalidRequest`, `UnsupportedProtocolVersion`, `MissingRequiredClientCapability`, `HeaderMismatch`, `ResourceNotFound(Uri, Era)`; `EMCPToolError` (→ `isError` result); `EMCPInputRequired` (Phase 6) |
| `Protocol/MCPServer.RequestContext.pas` (new) | `TMCPProtocolEra`, `TMCPRequestId` (absent/null/string/number/invalid), `TMCPTransportHints` (header layer, session side slot as a class reference, remote address), `IMCPRequestContext` (era, version, method, id, client capabilities/info, log level, progress token, `inputResponses`, `requestState`, principal, `IsCancelled`/`CheckCancelled`, `ReportProgress`, `HasClientCapability`/`RequireClientCapability`, sink), thread-local `Current` |
| `Protocol/MCPServer.JsonRpcProcessor.pas` | Pipeline: parse → shape validation (`jsonrpc`, `method`, id rules, params object) → notification dispatch → `BuildRequestContext` (section 4.1) → dispatch via `IMCPCapabilityManagerEx` or `ExecuteMethod` → modern envelope → status policy. Accepts an already-parsed `TJSONValue` so the transport parses once |
| `Protocol/MCPServer.Capabilities.pas` (new) | `TMCPCapabilityBuilder.Build(Registry, Era)`: derives `capabilities` from registered managers (`IMCPCapabilityProvider`), never emits `logging`, emits `extensions` only when non-empty and modern |
| `Managers/MCPServer.CoreManager.pas` | `server/discover`, legacy `initialize` negotiation, `ping` (legacy only), no session state, deprecation warning when a client declares roots/sampling |
| `Server/MCPServer.HttpHeaders.pas` (new, no Indy dependency) | Strict Base64-sentinel decoder (alphabet, padding, length mod 4 validated before decoding; `System.NetEncoding` is lenient), `Mcp-Method`/`Mcp-Name`/`Mcp-Param-*` comparison, RFC-compliant `Accept` parsing over all header lines |
| `Server/MCPServer.IdHTTPServer.pas` | Order: Origin (403) → CORS headers → authorizer (Phase 7) → endpoint (404) → OPTIONS 204 → GET/DELETE 405 + `Allow` → POST: body limit → parse once → notification (202, empty `ContentStream`) or request (`ProcessRequestEx`, status from result, JSON or SSE). Removes manual `Connection` headers, SSE `id:` lines, session minting and body scraping. `Bindings` set from `BindAddress` |
| `Server/MCPServer.SseWriter.pas` (new, Phase 6) | Incremental SSE over `Context.Connection.IOHandler` (`WriteHeader`, `ContentLength := -1`, `CloseConnection := True` because Indy does not chunk-encode raw writes), keep-alive comment lines, disconnect detection |
| `Server/MCPServer.StdioTransport.pas` | UTF-8 byte streams, LF framing, locked writer, reader thread that handles `notifications/cancelled` and legacy `ping` inline and hands other requests to a bounded worker pool (`MaxConcurrentRequests`, default 1), `Stop`/`RequestShutdown`, EOF/SIGTERM handling |
| `Server/MCPServer.InflightRegistry.pas` (new) | In-flight request contexts keyed by id text; duplicate in-flight id → `-32600`; cancellation lookup; subscription streams (Phase 6) |
| `Managers/MCPServer.ToolsManager.pas`, `Tools/MCPServer.Tool.Base.pas`, `Tools/MCPServer.Tool.Result.pas` (new) | Typed errors, `content` builders (text/image/audio/resource_link/embedded resource, per-era shaping), annotations/icons/`_meta` via `IMCPToolMetadata`, cache hints, deterministic order, cursors, optional `[SchemaHeader]` (x-mcp-header), `OnBeforeCallTool`/`OnAfterCallTool` hooks |
| `Protocol/MCPServer.Schema.Generator.pas`, `Protocol/MCPServer.Serializer.pas`, `Protocol/MCPServer.Schema.Validator.pas` (new) | `integer`, `TDateTime` as `date-time`, recursive nested objects/arrays/`TList<T>`/sets, extra attributes (`SchemaTitle`, `SchemaFormat`, `SchemaMinimum`…); strict required/type validation; array/enum/nil serialisation; subset validator with same-document `$ref` only and a depth cap |
| `Managers/MCPServer.ResourcesManager.pas`, `Resources/MCPServer.Resource.Base.pas`, `Protocol/MCPServer.Pagination.pas`, `Protocol/MCPServer.Uri.pas` (new) | Typed errors by era, blob contents, metadata, cache hints, templates (RFC 6570 level 1–2), opaque cursors (`-32602` for anything the server did not issue), URI validation |
| `Prompts/MCPServer.Prompt.Base.pas`, `Managers/MCPServer.PromptsManager.pas`, `Managers/MCPServer.CompletionManager.pas` (new, Phase 5) | Prompts mirror the tools design (`TMCPPromptBase<T>` derives arguments from RTTI); completion with `hasMore`/`total` |
| `Protocol/MCPServer.Mrtr.pas`, `Protocol/MCPServer.Elicitation.pas`, `Core/MCPServer.RequestState.pas` (new, Phase 6) | `TMCPInputRequests` builders (form/URL elicitation; sampling/roots marked deprecated), `EMCPInputRequired`, `inputResponses` parsing, HMAC-SHA256 `requestState` codec (principal, expiry, method + argument digest; key from settings with per-process fallback and warning; optional single-use store hook) |
| `Managers/MCPServer.SubscriptionsManager.pas` (new, Phase 6) | `subscriptions/listen` (modern only): acknowledge the honoured subset first, tag every message with `subscriptionId`, keep-alives, graceful close |
| `Core/MCPServer.Authorization.pas` (new, Phase 7) | `IMCPAuthorizer`, static bearer authorizer (constant-time compare), abstract OAuth resource-server base (audience + expiry mandatory, RFC 7662 introspection helper), `WWW-Authenticate` challenge builder, RFC 9728 protected-resource metadata document, `[RequiresScope]` attribute, scope hierarchy |
| `Core/MCPServer.Settings.pas`, `settings.ini.example` | New keys with compatible defaults (section 8) |
| `Core/MCPServer.Logger.pas` | `RedactJson` (blanks `_meta`, `requestState`, `inputResponses`, token-like keys); bodies logged at Debug; `StdoutReserved` guard for stdio |
| `tests/` (new) | DUnitX project, golden files for both eras, in-process HTTP tests, stdio process tests, conformance/Inspector scripts |

---

## 6. Phases

Each phase lists its goal, the main steps, the gap ids it closes, effort, and exit criteria. Phases never depend
on a later one to be releasable.

### Phase 0 – Safety net and hygiene (3–4 days, release 1.0.1)

Goal: pin today's legacy wire behaviour and land zero-risk clean-ups so every later phase can prove
"no legacy regression".

1. `tests/MCPServer.Tests.dproj` (DUnitX) with a harness that builds the same registry as `MCPServer.dpr` and
   drives `TMCPJsonRpcProcessor.ProcessRequest`.
2. Capture golden files **from the current binary, before any behaviour change**: `initialize` for each requested
   version, `ping`, `tools/list`, `tools/call` (valid, missing arguments, unknown tool, invalid params), all
   built-in resources, `resources/templates/list`, unknown method, unparseable body, `id: null`, batch array.
   Normalise only known-volatile fields (timestamps, uptime, memory, log lines).
3. Move `JSONRPC_*` constants to `MCPServer.Types` (aliases kept), add the `MCP_ERROR_*`, version and `_meta`
   constants; delete the duplicate block in `MCPServer.IdHTTPServer.pas`.
4. `AtomicIncrement`/`AtomicDecrement` for the `TServerStatusResource` counters; eager dictionary creation in
   `TMCPRegistry` (class constructor); document "register before `Start`/`Run`" and reconcile
   `TServerStatusResource.SetNamePrefix` (runtime re-registration is only honoured before managers are built).
5. `TMCPStdioTransport.Create` forces `TLogger.UseStdErr := True` and sets a `StdoutReserved` guard.
6. Scripts: `scripts/run-conformance.ps1` (build, start, run the conformance CLI for both requirement sets, record
   results) and `scripts/run-inspector-smoke.ps1`; commit the current failures as the first
   `conformance-baseline.yml`; add `CHANGELOG.md`.

Closes: GAP-BP-17, GAP-BP-19, GAP-HTTP-14, GAP-ST-04, GAP-ECO-01 (harness part).
Exit: legacy golden suite green on the unchanged code; conformance baseline recorded.

### Phase 1 – Protocol core (7–9 days, release 1.1.0)

Goal: dual-era at the JSON-RPC layer on both transports. After this phase a 2026-07-28 client works on stdio and
on the HTTP happy path; legacy clients are served as before.

1. Add `MCPServer.Errors.pas`, `MCPServer.RequestContext.pas`, the new interfaces in `MCPServer.Types.pas`, and
   `IMCPManagerEnumerator` on `TMCPManagerRegistry` (the `IMCPManagerRegistry` interface itself is not changed).
2. `ProcessRequestEx` with message-shape validation (`-32700`; `-32600` for arrays, missing `jsonrpc`/`method`,
   `id` null/bool/object/fraction; non-object `params` → `-32602`) and `ProcessNotification` (dispatch to the
   owning manager, never answered).
3. `BuildRequestContext` exactly as in section 4.1, table-driven unit tests for every branch.
4. Dispatch through `IMCPCapabilityManagerEx` when supported, else `ExecuteMethod`; set/clear
   `TMCPRequestContext.Current` around the call; catch `EMCPError` (code/message/data), map other exceptions to
   `-32603`. The `'not found'` text heuristic is kept for **legacy** requests only.
5. Modern envelope: coerce the result to an object, add `resultType: "complete"` if absent, add
   `_meta.io.modelcontextprotocol/serverInfo` (name, version, title, description, websiteUrl from settings) if
   absent, and for the six cacheable methods add `ttlMs: 0` / `cacheScope: "private"` if absent (safety net for
   third-party managers; built-ins set real values in Phase 3).
6. Status policy inside the processor (section 4.2). Phase 2 wires it to Indy.
7. `TMCPCoreManager`: `server/discover` (`supportedVersions: ["2026-07-28"]` by default, capabilities from
   `TMCPCapabilityBuilder`, `instructions`, `ttlMs` from settings, `cacheScope: "public"`, `_meta.serverInfo`;
   requires `_meta` like every modern method); `initialize` negotiates as in section 4.1, stores the version in
   the stdio side slot, drops `FSessionID` and the `sessionId` body field, warns when the client declares roots
   or sampling.
8. `MCPServer.Capabilities.pas`; `tools: {listChanged:false}`, `resources: {subscribe:false, listChanged:false}`.
9. Wire both transports to the new overloads (HTTP still answers 200 for everything until Phase 2).
10. Tests: legacy goldens unchanged except allow-list items 1–2; modern goldens for `server/discover` (before and
    after an `initialize`), `tools/list`/`tools/call` with `_meta`, missing `clientCapabilities`, unknown
    version, invalid `logLevel`, modern `ping`, `id: null`, missing `jsonrpc`, 50 concurrent `initialize` calls.
11. README: badge "MCP 2026-07-28 (dual-era)" and a "Protocol versions and dual-era behaviour" section.

Closes: GAP-BP-01…04, 06…14, 16, 20, 21; GAP-DE-01, GAP-DE-02; GAP-ST-06; GAP-CTX-01; GAP-ERR-01; GAP-LG-01,
GAP-LG-02; GAP-XC-02; GAP-RS-01; GAP-TL-02; GAP-SEC-09 (processor side).
Exit: an official 2026-07-28 SDK client (TypeScript or Python) completes `server/discover`, `tools/list` and
`tools/call` over stdio; MCP Inspector in `legacy` era behaves as before.

### Phase 2 – Dual-era Streamable HTTP and hardening (6–8 days, release 2.0.0)

Goal: `TMCPIdHTTPServer` conformant for both eras and safe by default.

1. Split `VerifyAndSetCORSHeaders` into `ValidateOrigin` (always runs; `[Security] AllowedOrigins` with
   scheme+host match and `:*` port wildcard; loopback origins on any port allowed by default; absent Origin
   allowed, `null` denied; 403 with an id-less JSON-RPC error body and `Vary: Origin`) and `ApplyCorsHeaders`
   (only when CORS is enabled; `Allow-Headers` adds `Authorization, MCP-Protocol-Version, Mcp-Method, Mcp-Name`
   and reflects `Access-Control-Request-Headers` on preflight so `Mcp-Param-*` pass; `Allow-Methods: POST, OPTIONS`;
   `Expose-Headers: Mcp-Session-Id, WWW-Authenticate`).
2. Read `MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name`, `Mcp-Param-*` into `TMCPTransportHints`; add
   `MCPServer.HttpHeaders.pas` with the strict sentinel decoder and `Accept` parser; unit-test the SEP-2243 edge
   table (case-insensitive names, `TOOLS/CALL` rejected, whitespace trimmed, bad padding → `-32020`, UTF-8 names).
3. `HandlePostRequest`: parse once, pass the parsed value to the processor; `ResponseNo := Res.HttpStatus`; JSON
   body for every non-200; SSE only when the client accepts it and streaming is needed (Phase 6); remove SSE
   `id:` lines and the event counter; never mint `Mcp-Session-Id`, echo an incoming one only for legacy requests
   after validating it is visible ASCII.
4. Notifications: dispatch, then 202 with an **empty `ContentStream`** (`TMemoryStream`, `FreeContentStream`) so
   Indy never emits its default HTML body; remove the manual `Connection: keep-alive` custom headers everywhere
   (Indy manages `Connection`). Client-sent JSON-RPC responses: 400 + `-32600` (modern), 202 (legacy).
   Array bodies: 400/`-32600` (modern), 200/`-32600` (legacy).
5. GET and DELETE (and any other verb) → 405 with `Allow: POST, OPTIONS`; `[Protocol] LegacyGetStream=1` restores
   the immediately-closed SSE stream for legacy `Accept: text/event-stream` GETs; the endpoint-info JSON moves
   to an optional `[Server] EndpointInfoPath`.
6. Limits: `[Server] MaxRequestBodyBytes` (default 4 MB, 413 above), JSON nesting depth cap, `MaxConnections`,
   per-remote cap on open streams (Phase 6 uses it).
7. `Start`: `Bindings.Clear` + explicit binding to `BindAddress` (default derived from `Host`: `localhost` →
   `127.0.0.1` and `::1`); `0.0.0.0` logs a warning.
8. `ConfigureSSL`: TLS 1.2+ only on the OpenSSL 1.0.2 path; move `USE_TAURUS_TLS` to `src/MCPServer.inc`.
9. Log bodies at Debug through `TLogger.RedactJson`; never log header values.
10. Tests: in-process `TMCPIdHTTPServer` on an ephemeral port driven by `TIdHTTP` (Origin 403 with CORS off,
    loopback port accepted, 202 `Content-Length: 0`, 405 + `Allow`, modern 404 vs legacy 200 for `-32601`,
    400 bodies for `-32020/-32022/-32602`, header-less + `_meta` → `-32020`, modern header without `_meta` →
    `-32602`, unknown header version → 400, bind to loopback only). Verify the Indy assumptions on Windows with
    `curl -i` (they could not be verified in the analysis environment).

Closes: GAP-BP-05, 15, 22; GAP-HTTP-01…06, 08…11, 13 (error part), 15, 17 (settings); GAP-XC-01; GAP-SEC-01…05,
08; GAP-SUB-03.
Exit: conformance `dns-rebinding-protection` and the header scenarios pass; Claude Code (`claude mcp add
--transport http …`) still connects; curl error matrix recorded.

### Phase 3 – Tools and resources (7–9 days, release 2.1.0)

Goal: schema-valid `tools/*` and `resources/*` results in the modern era, spec-correct errors in both eras,
better authoring API, no change to legacy success paths beyond the allow-list.

1. `TMCPToolsManager`: `-32602` for malformed params and unknown tool; absent `arguments` → empty object;
   `EMCPToolError` → `isError` result; every result has `content` (text fallback next to `structuredContent`,
   compact JSON); `ttlMs`/`cacheScope` on `tools/list` (modern only; sample server public/300000, library default
   0/private); registration order; cursor handling; `IMCPCapabilityProvider`.
2. Strict argument validation **on by default**: missing required or type-mismatched parameters produce an
   `isError` tool result (SEP-1303, so the model can self-correct), never a protocol error;
   `TMCPSerializer.StrictRequired := False` / `[Protocol] StrictArguments=0` restores the lenient behaviour.
3. Schema generator: `integer`, `TDateTime` → `string` + `format: date-time`, Boolean via `TypeInfo`, recursive
   nested objects/arrays/`TList<T>`/sets with a depth cap, `additionalProperties: false` for parameter-less
   tools, new optional attributes. Serializer: arrays, lists, sets, enums, nil → `null`, so
   `structuredContent` conforms to the generated `outputSchema`.
4. `MCPServer.Tool.Result.pas`: `TMCPToolResult` builders (text, image, audio, resource link, embedded
   resource, annotations, `_meta`, `SetStructuredContent`) with per-era shaping (2025-06-18/11-25 drop non-object
   `structuredContent`); `IMCPToolMetadata` (annotations, icons); `ExecuteWithContext` virtuals on the three base
   classes; one sample tool returning an image block, one with `readOnlyHint`.
5. Optional (1 day): `[SchemaHeader('Region')]` → `x-mcp-header` in the schema with registration-time constraint
   checks, and `Mcp-Param-*` validation in `MCPServer.HttpHeaders` (numeric comparison, null/absent → header not
   expected).
6. `TMCPResourcesManager`: `-32602` for missing/invalid `uri`, `EMCPError.ResourceNotFound(Uri, Era)`
   (`-32602` + `data.uri` modern, `-32002` legacy), `-32603` on read failure, optional fields omitted when empty,
   registration order, cursors, `ttlMs`/`cacheScope` (modern only), blob contents via `IMCPResourceReader`
   (single-line Base64), `IMCPResourceMetadata`; built-ins: `project://*` 3600000/public, `logs://recent` and
   `server://status` 0/private (drop the access-log side effect of `logs://recent`); `project://info` reports the
   supported version list.
7. Complete `TMCPCapabilityBuilder` (registry-derived; a consumer registering only tools no longer advertises
   resources); tool-name validation warnings (`StrictNames` raises).
8. Tests: unit tests per item; conformance `tools-call-image/audio/embedded-resource/mixed-content/error`,
   `resources-read-binary`, `sep-2164-resource-not-found`, `caching`.

Closes: GAP-TL-01, 03…17, 21, 23, 24; GAP-CA-01; GAP-RS-02…08, 10; GAP-PG-01 (lists); GAP-BP-08 (completed);
GAP-SUB-02; GAP-EXT-01; optionally GAP-HTTP-12 / GAP-TL-18.
Exit: modern `tools/list` and `resources/read` validate against `schema/2026-07-28/schema.json` (a small
Node/ajv script can check the golden files without a Delphi compiler).

### Phase 4 – stdio robustness (5–7 days, release 2.2.0)

Goal: spec-correct stdio on Windows and Linux, responsive to cancellation and legacy `ping`, able to emit
request-scoped notifications, default dispatch order unchanged.

1. Replace Text I/O with UTF-8 byte streams (`THandleStream` over the standard handles), LF-only framing, no BOM.
   Note: responses built with `TJSONObject.ToJSON` are already `\u`-escaped ASCII; the real defect is input
   decoding and raw exception text. Test with `é` and an emoji on Windows.
2. Reader thread + locked writer (`IMCPMessageSink`) + bounded worker pool. `notifications/cancelled` and legacy
   `ping` are handled inline on the reader thread; other requests are queued. `MaxConcurrentRequests` default 1
   (today's order preserved); duplicate in-flight ids → `-32600`.
3. `progressToken` → context; `ReportProgress` emits `notifications/progress` (monotonic, throttled) before the
   response.
4. Shutdown: `RequestShutdown`/`ShutdownEvent`; no SIGTERM/SIGINT override in stdio mode (or route it to
   `RequestShutdown` and close stdin); drain in-flight work with a 2 s bound on EOF; `ReportMemoryLeaksOnShutdown`
   only in DEBUG and never in stdio mode; the outer exception handler never writes to stdout.
5. `TMCPSettings`: stdio mode passes `ACreateFile = False` so the server never writes `settings.ini` next to the
   executable as a side effect; document the same for library use.
6. Tests: spawn the executable with `--stdio` over pipes (handshake, UTF-8 round trip, cancel during a slow test
   tool, `ping` during the slow tool, progress before the response, EOF exit < 2 s, SIGTERM on Linux).

Closes: GAP-ST-01, 02, 03, 05 (decision), GAP-CN-01, GAP-SD-01, GAP-PG-01 (stdio), GAP-BP-18 (decision),
GAP-TL-20 (stdio side).
Exit: Codex over stdio unchanged; an official SDK client interleaves modern requests on one process.

### Phase 5 – Prompts, completion, resource templates, schema validation (6–8 days, release 2.3.0)

Goal: the optional server features exercised by the frozen conformance sets, as purely additive units.

1. `MCPServer.Prompt.Base.pas` (`IMCPPrompt`, `TMCPPromptBase`, `TMCPPromptBase<T>` with RTTI-derived
   arguments and `[SchemaDescription]`/`[Optional]` reuse, message builders) and `TMCPPromptsManager`
   (`prompts/list` with pagination and modern cache hints; `prompts/get` with `-32602` for unknown prompt or
   missing required argument; `GetPromptResult` carries no cache hints). Register in `MCPServer.dpr`; add
   `src\Prompts` to `build.bat` and the `.dproj`.
2. `IMCPResourceTemplate` / `TMCPResourceTemplateBase` (RFC 6570 level 1–2 via `TRegEx`), templates in
   `resources/templates/list` and template resolution in `resources/read`.
3. `TMCPCompletionManager` (`completion/complete`, `ref/prompt` and `ref/resource`, `IMCPCompletable`, values
   capped at 100 with `hasMore`/`total`, capability advertised only when registered).
4. `MCPServer.Schema.Validator.pas` (2020-12 subset, same-document `$ref` only, depth cap; network `$ref` is
   forbidden by the spec) used for hand-written schemas; DEBUG self-check of `structuredContent` against
   `outputSchema`.
5. Tests and conformance: `prompts-*`, `completion-complete`, `resources-templates-read`.

Closes: GAP-PR-01, GAP-CO-01, GAP-RT-01, GAP-TL-07 (validator), GAP-TL-24 (remaining attributes).

### Phase 6 – Streaming, MRTR/elicitation, `requestState`, minimal `subscriptions/listen` (9–12 days, release 2.4.0)

Goal: the headline 2026-07-28 features for tool authors, and long-lived streams in Indy.

1. `MCPServer.SseWriter.pas`; pass `TIdContext` into the POST handlers; decide JSON-or-SSE lazily (buffer until
   the first notification, then write headers and stream); keep-alive comments every 15–30 s; disconnect during a
   modern request marks the context cancelled; `Stop` drains open streams before deactivating.
2. `MCPServer.Mrtr.pas`, `MCPServer.Elicitation.pas`, `MCPServer.RequestState.pas`; integrate
   `EMCPInputRequired` into `tools/call`, `resources/read`, `prompts/get` only (any other method → `-32603`);
   check every `inputRequests` entry against the client's declared capabilities (`-32021` / 400 otherwise);
   modern → `InputRequiredResult` (no cache hints); legacy → `isError` text (tools) or `-32603`.
   `requestState` is HMAC-SHA256 protected (`System.Hash`), bound to principal, method, argument digest and expiry;
   key from `[Security] RequestStateKey`, per-process random fallback with a loud warning (breaks MRTR across
   restarts and load-balanced instances); `IMCPRequestStateStore` hook for single-use enforcement.
3. Sample tool with a form elicitation (confirm before deleting) and README "Elicitation (MCP 2026-07-28)" with
   the security rules (no secrets via form mode, never pre-authenticated URLs).
4. `TMCPSubscriptionsManager`: `subscriptions/listen` (modern only) acknowledges the honoured subset (empty until
   dynamic registration or resource subscriptions exist), keeps the stream open, honours client cancellation, and
   closes gracefully. Teardown decision (spec texts disagree): on stdio send `notifications/cancelled` for the
   listen id and then the completion result; on HTTP send the completion result and close. Record this
   interpretation in the README. If the client's `Accept` lacks `text/event-stream`, answer `-32600` (cannot
   stream). On stdio the listen request does not occupy a worker slot.
5. Tests: MRTR round trip, tampered/expired/foreign-principal state → `-32602`, missing capability → `-32021`,
   legacy fallback, progress over SSE, disconnect → cancelled, ack-first and graceful close on both transports;
   conformance `input-required-result-*`, `tools-call-with-progress`, `server-sse-multiple-streams`.

Closes: GAP-HTTP-07, GAP-TL-19, GAP-TL-20 (HTTP), GAP-MRTR-01…06, GAP-EL-01, GAP-RS-09, GAP-SUB-01, GAP-ST-07,
GAP-SEC-06.
Exit: MCP Inspector in `modern` era completes an elicitation flow with the sample tool and its Subscribe button
receives the acknowledgment.

### Phase 7 – Authorization hook, hardening, documentation, baseline (5–7 days, release 2.5.0)

Goal: opt-in, spec-shaped authentication for HTTP deployments (resource-server role only) and the release
deliverables.

1. `MCPServer.Authorization.pas`; `TMCPIdHTTPServer.Authorizer` (nil = open as today); token read only from the
   `Authorization: Bearer` header; 401/403 with `WWW-Authenticate: Bearer resource_metadata="…"[, scope=…][,
   error="insufficient_scope"]` and an id-less JSON-RPC body; `GET /.well-known/oauth-protected-resource[/mcp]`
   served without a token; `[RequiresScope]` on tools; optional token bucket (429); never wired into stdio.
   JWT verification is a documented sample only (no JOSE in the RTL); RFC 7662 introspection helper shipped.
2. Optional `[Security] AllowedHosts` allow-list.
3. Final `conformance-baseline.yml`, `ci-servers.json` (Inspector `legacy`/`auto`/`modern` + stdio + auth), and a
   documented self-hosted Windows runner recipe (`build.bat` + DUnitX + conformance + Inspector smoke).
4. README overhaul (badge, dual-era section with era table, status table and curl examples, library checklist,
   authoring guide for tools/prompts/resources/elicitation, security section, testing section);
   `MIGRATION.md`; `settings.ini.example`.
5. Manual acceptance matrix recorded in `docs/acceptance-<version>.md`: Claude Code over HTTP (legacy), Codex
   over stdio (legacy), Inspector in the three eras, one official 2026-07-28 SDK client over HTTP and stdio,
   curl error matrix.

Closes: GAP-AUTH-01…07, GAP-SEC-10, GAP-TL-22, GAP-ECO-01 (completed), GAP-ECO-02, GAP-HTTP-16, GAP-HTTP-17,
GAP-TL-25.

---

## 7. Public API changes

| Item | Breaking | Mitigation |
|---|---|---|
| `TMCPJsonRpcProcessor.ProcessRequestEx`, `Create(Registry, Settings)` overload, parsed-value overload | no | old `Create`/`ProcessRequest` remain and delegate |
| New units (`Errors`, `RequestContext`, `Capabilities`, `HttpHeaders`, `SseWriter`, `InflightRegistry`, `Tool.Result`, `Pagination`, `Uri`, `Prompt.Base`, `PromptsManager`, `CompletionManager`, `SubscriptionsManager`, `Mrtr`, `Elicitation`, `RequestState`, `Authorization`, `Schema.Validator`) | no | opt-in |
| New interfaces probed with `Supports()` | no | existing interfaces keep GUIDs and members |
| `TMCPToolBase<T>.ExecuteWithContext` (new virtual, distinct name) | no | default wraps `ExecuteWithParams` |
| Protected fields with defaults on the base classes (`FAnnotations`, `FIcons`, `FMeta`, `FTtlMs`, `FCacheScope`, `FTitle`, `FSize`) | no | defaults reproduce today's output; names documented |
| Constants moved to `MCPServer.Types` with aliases; `MCP_PROTOCOL_VERSION` kept as legacy alias | no | aliases |
| `initialize` result: `sessionId` and `supportsProgress`/`supportsCancellation` removed, `listChanged` added; `TMCPCoreManager.SessionID` returns `''` | yes (wire) | no client reads them; documented |
| Unknown tool / bad params → `-32602`; resource not found → `-32602`/`-32002`; read exception → `-32603` | yes (error paths) | spec-required in both eras; before/after JSON in CHANGELOG |
| Strict argument validation on by default (as `isError` results) | yes (tool results) | `StrictArguments=0` opt-out |
| HTTP: Origin always validated, loopback bind, GET/DELETE 405, TLS ≥ 1.2, no session minting, no SSE `id:` lines | yes (runtime defaults) | one-line ini opt-outs; CHANGELOG + MIGRATION.md |
| Modern-era HTTP statuses 400/404 | no | modern requests only |
| stdio: UTF-8/LF, forced stderr logging, no null-id error on stdout, `Stop`/`MaxConcurrentRequests` | no | signatures unchanged; default sequential |
| Schema text changes (`integer`, nested shapes, `additionalProperties: false`) | no | still valid; refresh snapshot tests |
| `TMCPRegistry`: registration-order enumeration, prompt/template registration, name warnings | no | existing signatures unchanged |
| `TMCPSettings`, `TMCPIdHTTPServer`, managers gain properties/ini keys | no | compatible defaults |
| Bodies logged at Debug (redacted) | no | lower `MinLogLevel` to see them |

---

## 8. Decisions for the repository owner

Each decision has a recommended default that the phases above assume.

| # | Decision | Recommended default | Alternative |
|---|---|---|---|
| D1 | Serve `2025-03-26`? (requires JSON-RPC batch receiving) | No. Accept its `initialize` but answer `2025-11-25`; reject array bodies with `-32600`; state in the README that 2025-03-26 is not served. Every current MCP client is ≥ 2025-06-18 | `[Protocol] LegacyBatch2025_03_26=1` (echo the version and process batches element by element, about 1 day) |
| D2 | `supportedVersions` / `error.data.supported` contents | `["2026-07-28"]` only (legacy revisions are reachable only through `initialize`; listing them makes modern clients retry with a legacy version in `_meta` and loop on `-32022`) | `[Protocol] DiscoverListsLegacyVersions=1` |
| D3 | Legacy HTTP sessions | Stateless in both eras (never mint `Mcp-Session-Id`; echo an incoming valid one for legacy requests) | per-session store in the transport (only if session-scoped legacy state is ever needed) |
| D4 | Default bind address | Derived from `Host` (`localhost` → loopback); `BindAddress=0.0.0.0` opt-in with a warning | keep all interfaces (violates a spec SHOULD) |
| D5 | `[CORS] AllowedOrigins=*` | keep as explicit allow-all opt-out with a startup warning; `[Security] AllowedOrigins` becomes the canonical key | deprecate `*` |
| D6 | Strict argument validation | on by default, surfaced as `isError` tool results; `StrictArguments=0` opt-out | off in 2.x, on in 3.0 |
| D7 | Modern `ping` | strict `-32601`/404 (removed in 2026-07-28); `LenientModernPing=1` for transitional clients | lenient by default |
| D8 | stdio concurrency | `MaxConcurrentRequests=1` with `ping`/`notifications/cancelled` handled inline | 4 (only if consumer tools are thread-safe) |
| D9 | Scope of optional features | Phases 5 and 6 included (needed for full conformance scores and for the MRTR value) | ship Phases 0–4 as 2.0 and the rest later |
| D10 | `subscriptions/listen` | minimal conformant implementation (ack, keep-alives, graceful close) | leave at `-32601`/404 (also conformant while no `listChanged`/`subscribe` is advertised) |
| D11 | Authorization depth in core | pluggable `IMCPAuthorizer`, static bearer, abstract OAuth resource-server base with introspection; JWT as sample | hook + documentation only |
| D12 | Built-in `logs://recent` / `server://status` | keep registered, declare 0/private, `[Server] ExposeDiagnosticsResources=0` to disable, hide when an authorizer is configured unless explicitly enabled | unregister by default |
| D13 | Modern-only emission of `resultType`/cache hints/`serverInfo` | modern only (legacy stays byte-identical) | always emit (legacy schemas tolerate it) |
| D14 | `RequestStateKey` | configured key required for multi-instance or restart-resilient MRTR; per-process random fallback with warning | always random |
| D15 | CI | committed PowerShell scripts run on a Windows machine per release; self-hosted Windows runner when available (no Delphi on hosted runners) | manual checklist only |
| D16 | Final version numbering | 1.0.1 → 1.1.0 → 2.0.0 (Phase 2) → 2.1 … 2.5 | single 2.0.0 at the end |

---

## 9. Testing and acceptance

1. **Unit tests (DUnitX)** on the transport-independent processor: era-detection matrix, `_meta` validation,
   envelope injection, status policy, id/`jsonrpc`/params validation, notification dispatch, capability builder,
   cursor codec, header sentinel decoder (SEP-2243 table), `Accept` parser, schema generator snapshots,
   serializer round trips, `TMCPToolResult` per era, `requestState` codec (tamper, expiry, wrong principal, wrong
   method), elicitation schema builder, authorizer decisions and challenge formatting.
2. **Golden protocol tests** for both eras (`tests/golden/legacy/*.json` captured from the current binary in
   Phase 0; `tests/golden/modern/*.json` added per phase), re-run in every phase with the allow-list of section
   4.3. Modern goldens additionally validated against `schema/2026-07-28/schema.json` with a Node/ajv script.
3. **In-process HTTP tests** (`TMCPIdHTTPServer` on an ephemeral port, driven by `TIdHTTP`) and **stdio process
   tests** (spawn the executable over pipes).
4. **Official tooling**: `npx @modelcontextprotocol/conformance server --url http://127.0.0.1:3000/mcp
   --requirements 2026-07-28` (and `2025-11-25`) with `--expected-failures conformance-baseline.yml`; MCP Inspector
   CLI (`--cli --config ci-servers.json --server <name> --method tools/list`) for `legacy`, `auto`, `modern` and
   stdio entries. Targets: no failures in the 2026-07-28 required set (tasks scenarios are not scored); the
   2025-11-25 set passes except the scenarios for deprecated features deliberately not implemented
   (`logging/setLevel`, legacy server-initiated sampling/elicitation), which are listed in the baseline. Flag
   names and scenario ids must be re-verified against the conformance repository when Phase 0 starts; they were
   read from its README, not from a local clone.
5. **Manual matrix per release**: Claude Code over HTTP, Codex over stdio, Claude Desktop (optional), Inspector
   in three eras (Subscribe button, `logLevel=debug` tolerated, elicitation flow), one official 2026-07-28 SDK
   client over HTTP and stdio, curl error matrix, 50 concurrent `initialize`/`tools/call` under FastMM full
   debug mode.

---

## 10. Risks and unverified assumptions

- **No Delphi toolchain in the analysis environment.** All Indy and RTL claims below must be verified on a Windows
  build before the corresponding phase is finalised: default HTML body on empty 202/204 responses, `Bindings`
  default, `RawHeaders.Values` case-insensitivity and handling of repeated `Accept` lines, one connection per
  thread under the default scheduler, no chunked encoding for raw `IOHandler` writes, Text I/O code page on input.
- **Era misdetection** is the highest-impact failure mode; the algorithm lives in one function with exhaustive
  table tests, and `server/discover` never depends on process state.
- **HTTP 404 has opposite meanings across eras** (modern: method not found; legacy: session terminated). The status
  policy is era-gated and tested so a legacy client can never receive 404 for a JSON-RPC error.
- **Every 4xx to a modern request must carry a JSON-RPC body**, otherwise dual-era clients fall back to
  `initialize`.
- **Long-lived SSE streams pin Indy worker threads**; `MaxConnections`, the per-remote stream cap and `Stop`
  draining must be tuned before advertising subscriptions.
- **Security defaults change runtime behaviour** for a minority of deployments (remote hosts with `Host=localhost`,
  CORS-disabled setups); each has an opt-out and a CHANGELOG entry.
- **Legacy error-path changes** (`-32602` unknown tool, `-32002` resource not found) can break consumer integration
  tests that asserted the old text results.
- **`requestState` keys generated per process** break MRTR across restarts or load-balanced instances; a configured
  key is documented as mandatory there.
- **Conformance scenario names and CLI flags** are taken from the conformance README, not verified against a
  local clone; some legacy scenarios cover deprecated features this plan does not implement.
- **Spec tension on listen teardown** (`cancellation.mdx` MUST vs `subscriptions.mdx` completion result) is resolved
  by an interpretation (section 6, Phase 6) that a future conformance scenario could disagree with.
- **Effort**: the winning candidate plan estimated 42 days; the judges considered that optimistic for Indy streaming,
  MRTR and prompts/completion. The ranges in section 1 add 20–50 % contingency.

---

## 11. Out of scope

- Acting as an OAuth authorization server, Dynamic Client Registration, CIMD, DPoP, consent pages for
  confused-deputy proxies (the spec limits the MCP server to the resource-server role).
- The Tasks extension (`io.modelcontextprotocol/tasks`): extensions are off by default and a server that never
  returns a task handle is fully compliant. Candidate for a later release.
- Deprecated features: `logging` capability / `logging/setLevel` / `notifications/message`, server-side use of
  roots and sampling, the HTTP+SSE 2024-11-05 transport. Only `logLevel` validation, a deprecation warning and
  deprecated-marked MRTR builders are provided.
- SSE resumability (`Last-Event-ID`, event ids): removed in 2026-07-28, never implemented, deleted.
- Legacy server-initiated requests over the SSE stream (in-stream elicitation/sampling for 2025-xx clients):
  needs per-session correlation and blocks Indy threads; legacy clients get an `isError` explanation instead.
- A full JSON Schema 2020-12 validator (composition/conditional keywords, external `$ref`).
- OpenTelemetry exporters (reserved `_meta` keys are passed through untouched).
- Windows service packaging, Docker images, installers.

---

## 12. Reference

- Specification (cloned for the analysis): `docs/specification/2026-07-28/{changelog,basic/index,basic/versioning,
  basic/transports/streamable-http,basic/transports/stdio,basic/patterns/mrtr,basic/patterns/subscriptions,
  server/discover,server/tools,server/resources,server/prompts,server/utilities/caching}.mdx` and
  `schema/2026-07-28/schema.ts` in `github.com/modelcontextprotocol/modelcontextprotocol`.
- Legacy revisions: `docs/specification/2025-11-25/{basic/lifecycle,basic/transports}.mdx`,
  `docs/specification/2025-06-18/...`.
- Conformance suite: `github.com/modelcontextprotocol/conformance` (`npx @modelcontextprotocol/conformance`).
- MCP Inspector: `npx @modelcontextprotocol/inspector` (per-server `protocolEra`: `legacy`, `auto`, `modern`).
- Gap analysis: `docs/analysis/mcp-2026-07-28-gaps.md`, `docs/analysis/mcp-2026-07-28-gap-analysis.json`.
