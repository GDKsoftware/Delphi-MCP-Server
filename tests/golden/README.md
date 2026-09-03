# Golden files

The golden files pin the wire behaviour of the server so that every later change
can prove "no regression for existing clients". They were recorded from the
unchanged 2025-06-18 code before the MCP 2026-07-28 work started. After that
recording the only differences allowed on the legacy wire are the items in the
allow-list of `docs/mcp-2026-07-28-implementation-plan.md`, section 4.3. Anything
else that changes a golden file is a bug.

## Layout

| Directory | Layer | Recorded by | Verified by |
|---|---|---|---|
| `legacy/` | JSON-RPC processor (`TMCPJsonRpcProcessor.ProcessRequest`) with the same registry as `MCPServer.dpr` | `scripts\run-tests.ps1 -Record` | `scripts\run-tests.ps1` (DUnitX fixture `TLegacyGoldenTests`) |
| `http/` | Streamable HTTP transport (`TMCPIdHTTPServer`) of the built executable, captured with curl | `scripts\capture-http-goldens.ps1 -Record` | `scripts\capture-http-goldens.ps1` |

Later phases add `modern/` for 2026-07-28 requests.

## Legacy case files

One JSON file per case in `legacy/`:

```json
{
  "request": { "jsonrpc": "2.0", "id": 1, "method": "ping" },
  "mask": ["result.sessionId"],
  "shape": ["result.contents[0].text"],
  "workingDirectory": "fixtures",
  "expected": { "jsonrpc": "2.0", "id": 1, "result": {} }
}
```

- `request` is sent as the request body. Use `requestText` instead for input that
  is not JSON (parse errors, empty body, arrays).
- `mask` lists paths whose value is replaced by `"<masked>"` before comparing
  (session ids, timestamps, exception text with addresses).
- `shape` lists paths whose value is replaced by its shape: every leaf becomes
  its JSON type name. A string that contains a JSON document is parsed first, so
  resource contents such as `logs://recent` are compared structurally.
- Paths are dotted member paths with array indexes; `[*]` matches any index.
  A path must end at an object member.
- `workingDirectory` (relative to `tests/`) is made current while the request
  runs; `list_files` restricts itself to the current directory.
- `expected` holds the normalised response. `expectedText` is used when the
  response is empty (notification) or not JSON.

The tests compare the formatted JSON text of the normalised response with the
formatted `expected` value, so key order and array order matter.

## Recording procedure

1. Check out the commit whose behaviour must be pinned.
2. `build.bat Debug Win64` and `build-tests.bat Debug Win64`.
3. `.\scripts\run-tests.ps1 -Record -NoBuild` rewrites the `expected` sections
   in `legacy/`.
4. `.\scripts\capture-http-goldens.ps1 -Record` starts `Win64\Debug\MCPServer.exe`
   on port 3939 and writes `http/*.txt`.
5. Review the diff. Only the intended cases may change, and only within the
   allow-list.
6. `.\scripts\run-tests.ps1` and `.\scripts\capture-http-goldens.ps1` must be
   green before committing.

## Notes on the recorded behaviour

- Six cases were re-recorded after defects found during the first recording
  were fixed in the same branch (see CHANGELOG): `resources-list` and
  `resources-read-server-status` (`server://status` was never registered by
  the executable), `resources-read-logs-recent` (the entries were freed twice
  and the read failed), `resources-read-project-info` and again
  `resources-read-logs-recent` (lists were serialised as an object with
  `count` and `capacity`), `resources-read-without-params` and
  `tools-call-missing-arguments` (nil dereferences). Every other legacy case
  is byte-identical to the 2025-06-18 code.
- `server://status` and `logs://recent` contain timestamps, counters and log
  text, so their `text` field is compared by shape.
- `tools/call` with `id: null` is treated as a notification and gets no
  response.
- HTTP responses are normalised: `Date` and `Server` headers are dropped, GUIDs
  become `<guid>`, SSE `id:` lines become `id: <n>`, line endings are LF.
