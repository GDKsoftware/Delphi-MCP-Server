# Golden files

The golden files pin the wire behaviour of the server. A change in a golden
file is a deliberate change of what clients receive and belongs in the
CHANGELOG; an unintended change is a regression.

## Layout

| Directory | Layer | Recorded by | Verified by |
|---|---|---|---|
| `legacy/` | JSON-RPC processor (`TMCPJsonRpcProcessor.ProcessRequest`) with the same registry as `MCPServer.dpr`, initialize-based protocol revisions | `scripts\run-tests.ps1 -Record` | `scripts\run-tests.ps1` (DUnitX fixture `TLegacyGoldenTests`) |
| `http/` | Streamable HTTP transport (`TMCPIdHTTPServer`) of the built executable, captured with curl | `scripts\capture-http-goldens.ps1 -Record` | `scripts\capture-http-goldens.ps1` |

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
  (session ids, timestamps).
- `shape` lists paths whose value is replaced by its shape: every leaf becomes
  its JSON type name. A string that contains a JSON document is parsed first, so
  resource contents such as `logs://recent` and `server://status` are compared
  structurally.
- Paths are dotted member paths with array indexes; `[*]` matches any index.
  A path must end at an object member.
- `workingDirectory` (relative to `tests/`) is made current while the request
  runs; `list_files` restricts itself to the current directory.
- `expected` holds the normalised response. `expectedText` is used when the
  response is empty (notification) or not JSON.

The tests compare the formatted JSON text of the normalised response with the
formatted `expected` value, so key order and array order matter.

## Recording procedure

1. `build.bat Debug Win64` and `build-tests.bat Debug Win64`.
2. `.\scripts\run-tests.ps1 -Record -NoBuild` rewrites the `expected` sections
   in `legacy/`. Use `-Filter` with the fully qualified test names to
   re-record single cases.
3. `.\scripts\capture-http-goldens.ps1 -Record` starts `Win64\Debug\MCPServer.exe`
   on port 3939 and writes `http/*.txt`.
4. Review the diff: only the cases whose behaviour changed on purpose may
   differ.
5. `.\scripts\run-tests.ps1` and `.\scripts\capture-http-goldens.ps1` must be
   green before committing.

## Notes on the recorded behaviour

- `logs://recent` and `server://status` contain timestamps, counters and log
  text, so their `text` field is compared by shape.
- A request with `id: null` is treated as a notification and gets no
  response.
- HTTP responses are normalised: `Date` and `Server` headers are dropped, GUIDs
  become `<guid>`, SSE `id:` lines become `id: <n>`, line endings are LF and
  trailing newlines are trimmed.
