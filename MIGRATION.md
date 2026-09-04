# Migration notes

Behaviour changes that can affect an existing deployment or a project that
uses this repository as a library, with what to do about them. Everything
else in the CHANGELOG is additive.

## HTTP transport

**The server binds to loopback when `Host` is `localhost`.** It used to listen
on every interface. A server that must be reachable from other machines needs
either a `Host` that is not loopback (then it listens on every interface) or an
explicit `[Server] BindAddress`, for example `BindAddress=0.0.0.0`.

**The `Origin` header is validated on every request**, also when CORS is
disabled. Loopback origins (`localhost`, `127.0.0.1`, `[::1]`, any port) always
pass; other origins must be listed in `[Security] AllowedOrigins` or, when that
is empty, in `[CORS] AllowedOrigins`. A rejected origin gets `403` with a
JSON-RPC error body. Browser front-ends on another host must be added to the
list (`https://app.example` or `https://app.example:*`).

**GET and DELETE on the MCP endpoint answer `405`.** The old GET answered a
small JSON document with the endpoint URL; configure `[Server] EndpointInfoPath`
(for example `/info`) to keep such a document on a path of its own.

**Notifications get `202` with an empty body**, no longer an HTML body.

**Modern requests (MCP 2026-07-28) get real HTTP status codes**: `400` for
malformed `_meta`, an unsupported protocol version or a header that does not
match the body, `404` for an unknown method. Requests from `initialize`-based
clients keep `200` for every JSON-RPC error, except a `400` for an
`MCP-Protocol-Version` header naming an unknown revision.

**Modern POSTs must carry `Mcp-Method`** and, for `tools/call`,
`resources/read` and `prompts/get`, **`Mcp-Name`** (Base64 sentinel encoding
accepted). A missing or different header is `400` with error `-32020`.

**Request limits**: bodies above `[Server] MaxRequestBodyBytes` (4 MB) get
`413`, JSON nested deeper than `[Server] MaxJsonDepth` (64) gets `400`.

**No `Mcp-Session-Id` is minted.** The `initialize` result no longer carries a
`sessionId`; an `Mcp-Session-Id` a legacy client sends is echoed back.

**SSE responses have no `id:` lines** and no duplicate `Connection` header.

**Responses stream when a tool sends notifications.** A request that accepts
`text/event-stream` and whose tool reports progress or logs (see
`IMCPRequestContext.ReportProgress` and `Log`) is answered with a chunked SSE
stream: the notifications first, the JSON-RPC response as the last event.
Such a stream is `200` even when the request ends in a JSON-RPC error,
because the status line has already been sent. Requests that send no
notification, and requests without `text/event-stream` in `Accept`, are
answered as before (single JSON object, or one SSE event, with a
`Content-Length`). Closing the stream cancels the request.

**TLS 1.0 and 1.1 are disabled** on the OpenSSL 1.0.2 handler (the build
without `USE_TAURUS_TLS`).

**Request and response bodies are logged at Debug level**, with `_meta`,
`requestState`, `inputResponses` and token-like members redacted. Lower
`TLogger.MinLogLevel` to see them.

## Tools and resources

**An unknown tool is a JSON-RPC error.** `tools/call` with a name that is not
registered answers `-32602` with `data.name`; it used to answer an `isError`
result with the text "Tool not found". A missing or empty `name`, or an
`arguments` that is not an object, is `-32602` too. Modern clients get HTTP
`400` with it, initialize-based clients `200`.

**An unknown resource is a JSON-RPC error.** `resources/read` answers `-32002`
with `data.uri` for initialize-based clients and `-32602` with `data.uri` for
modern clients; it used to answer a text content "Error: Resource not found".
A read that raises is `-32603`.

**Arguments are checked against the schema.** A missing required parameter, a
wrong JSON type (a string for a number, a fraction for an integer, a string
for a boolean) or an unknown enumeration name is an `isError` result naming
the parameter, before the tool runs. A parameter that may be absent needs the
`[Optional]` attribute; without it the old behaviour (silently defaulting)
is gone. `null` counts as absent.

**Generated schemas changed.** Integer properties are `integer` (they were
`number`), `TDateTime` is a `string` with `format: date-time`, enumerations
and sets list their names, and a tool without parameters declares
`additionalProperties: false`. Clients that validate arguments against the
schema now reject `1.5` for an integer.

**Result and resource JSON changed.** Enumerations are written by name (they
were booleans), sets and dynamic arrays as arrays, `nil` objects as `null`
and `TDateTime` as an ISO 8601 string. The `logs://recent` timestamps and the
`server://status` times are strings now.

**Tools and resources are listed in registration order.** Anything that
depended on the previous dictionary order should use the names instead.

**A typed tool result also gets a text block.** `TMCPToolBase<T, R>` results
carry `structuredContent` and a text block with the same JSON; `content` is
never empty.

## stdio transport

**Non-ASCII input is no longer mangled.** stdin and stdout are read and
written as UTF-8 byte streams now instead of Text I/O; a message with `é` or
an emoji comes back unchanged. A client that worked around the old mangling
should remove that workaround.

**Requests are answered one at a time by default, still in arrival order.**
Set `[Server] MaxConcurrentRequests` above 1 for a client that issues several
requests before waiting for a reply and wants them handled in parallel.

**`notifications/cancelled` now does something.** Sending it for a request
still in flight stops that request and it gets no response, matching the
specification; previously the notification was accepted but ignored.

**A request with `_meta.progressToken` gets `notifications/progress`** from
tools that report progress (`test_tool_with_progress` is the example); this
is new traffic on stdout a client that does not expect it should tolerate,
since it was already required by the specification.

**The server exits promptly when stdin closes**, even with a request still
running: it waits `[Server] MaxConcurrentRequests`-many workers up to 2
seconds (configurable via `TMCPStdioTransport.ShutdownDrainMs` for a library
consumer), then cancels what is left rather than blocking forever.

**A duplicate request id while the first is still in flight is `-32600`**,
answered immediately, instead of being silently queued behind it.

## Prompts, resource templates and completion

**New capabilities, off unless you register the managers.** A registry that
never registers `TMCPPromptsManager` or `TMCPCompletionManager` behaves
exactly as before; the built-in `MCPServer.dpr`/stdio server registers both,
so the shipped executable now advertises `prompts` and `completions` and
answers `prompts/list`, `prompts/get`, `resources/templates/list` (with real
entries instead of an empty array) and `completion/complete`.

**A hand-written tool (`TMCPToolBase`) now validates its arguments.**
Override `DoExecute` instead of `Execute`; the base class validates
`Arguments` against `BuildSchema` first and raises `EArgumentException` (an
`isError` result) on a mismatch. `TMCPToolBase<T>` and `TMCPToolBase<T, R>`
tools are unaffected.

## Multi round-trip requests

**Server-initiated requests are replaced by `InputRequiredResult`.** A tool,
resource or prompt that needs something from the client (`elicitation/create`,
`sampling/createMessage`, `roots/list`) raises `EMCPInputRequired`
(`MCPServer.Mrtr`) with the input requests and optional state; the modern
client retries with `inputResponses` and `requestState`, which the request
context exposes as `InputResponses`, `TryGetInputResponse` and
`RequestState`. Nothing changes for tools that never ask the client for
input. A legacy client (2025-06-18, 2025-11-25) gets `-32603` from such a
request, because those revisions delivered the same thing as server-to-client
requests that this server does not send.

**`requestState` is signed.** Set `[Security] RequestStateKey` when more than
one instance serves the same clients or when tokens must survive a restart;
without it every process signs with its own random key and logs a warning
at startup. `RequestStateTtlSeconds` bounds the replay window (600 s).

**Two new settings keys** (`RequestStateKey`, `RequestStateTtlSeconds`) and
nine new example tools plus one example prompt ship with the executable;
they are only registered when their units are in the project.

## Library use

- `TMCPJsonRpcProcessor.ProcessRequest` and the manager interfaces are
  unchanged. `ProcessRequestEx` returns the HTTP status your own transport
  should answer with.
- `TMCPToolBase<T>` gains `ExecuteWithContext(Params, Context): TValue`;
  override it to return a `TMCPToolResult` (images, audio, embedded
  resources, resource links, `_meta`) or to read the request context.
  `ExecuteWithParams` keeps working as before. Raise `EMCPToolError` for a
  failure the model should see as an `isError` result; any other exception
  is reported the same way with its message.
- `TMCPResourceBase<T>` has `FTitle`, `FSize`, `FAnnotations`, `FTtlMs` and
  `FCacheScope` for the list and read results; implement `IMCPBinaryResource`
  for a `blob` resource.
- `TMCPToolsManager.CallTool` raises `EMCPError` (-32602) for an unknown tool
  instead of returning an error result; `TMCPResourcesManager.ReadResource`
  raises `EMCPError` for an unknown URI. Both have era-aware overloads.
- `TMCPCoreManager.SessionID` returns an empty string.
- `initialize` answers the requested revision (`2025-06-18` or `2025-11-25`)
  and its `capabilities` come from the registered managers; a registry with
  only a tools manager no longer advertises resources.
- Batch arrays, `id: null`, a missing `method` or `jsonrpc` are answered with
  `-32600`; a non-object `params` with `-32602`.
- `TMCPStdioTransport.Create` forces stderr logging.
- `USE_TAURUS_TLS` moved from `MCPServer.IdHTTPServer.pas` to
  `src\MCPServer.inc`; add `src` to your include path.
