# Golden files

The golden files pin the wire behaviour of the server. A change in a golden
file is a deliberate change of what clients receive and belongs in the
CHANGELOG; an unintended change is a regression.

## Layout

| Directory | Layer | Verified by |
|---|---|---|
| `legacy/` | JSON-RPC processor (`TMCPJsonRpcProcessor.ProcessRequest`) with the same registry as `MCPServer.dpr`, initialize-based protocol revisions | DUnitX fixture `TLegacyGoldenTests` |
| `modern/` | The same layer for requests that carry per-request `_meta` (MCP 2026-07-28), including the rejected shapes | DUnitX fixture `TModernGoldenTests` |

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

1. `build-tests.bat Debug Win64` (the test program is `tests\MCPServerTests.dpr`).
2. Run `tests\Win64\Debug\MCPServerTests.exe` once with the environment
   variable `MCP_GOLDEN_RECORD=1`; this rewrites the `expected` sections.
   Use `-run:` with fully qualified test names to re-record single cases.
3. Review the diff: only the cases whose behaviour changed on purpose may
   differ.
4. The test program must be green without the variable before committing.

## Notes on the recorded behaviour

- `logs://recent` and `server://status` contain timestamps, counters and log
  text, so their `text` field is compared by shape.
- A request with `id: null` is treated as a notification and gets no
  response.
