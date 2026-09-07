# Coding rules

The code in this repository follows a house style: inline variables, `const`
parameters, named constants, small units, no comments, and zero compiler hints
or warnings. This file records the conventions that a reader might otherwise
take for mistakes, and the places where the library deliberately keeps a
pattern that a stricter reading would reject.

## Conventions

### Constants are `UPPER_CASE`

Protocol values carry the names the MCP specification uses
(`MCP_PROTOCOL_VERSION_2026_07_28`, `JSONRPC_INVALID_PARAMS`), and the rest of
the code follows the same shape (`READ_CHUNK_BYTES`,
`DEFAULT_KEEP_ALIVE_INTERVAL_MS`). One convention across the repository is
worth more than matching a general preference for `PascalCase`.

### Registration in `initialization` sections

Tools, prompts, resources and resource templates register themselves in the
`initialization` section of their own unit. Consumers add a unit to their
project's `uses` clause and the item is available; that is the public contract
of the library and the reason no central registration list exists. New tool,
prompt and resource units follow the same pattern. Nothing else uses
`initialization` or `finalization`: state that outlives a call lives in a
`class var` with a `class constructor`.

### One unit per concept, not per type

A unit holds the types that belong to one mechanism: the subscriptions manager
with its filter and its subscription, the stdio transport with its tracker and
its worker, the exception classes together, the sample tools per theme.
`MCPServer.Types` is the umbrella every consumer puts in its `uses` clause, so
its interfaces, attributes and records stay in one place.

### System.Generics.Collections

The library has no third-party dependencies so that it can be dropped into any
Delphi project. `System.Generics.Collections` is used instead of Spring4D
collections.

### Public global functions

`MCPServer.Types` exposes `IsJsonString` and `MCPServer.StdioChannel` exposes
`StandardInputStream` and `StandardOutputStream`, because they are part of the
public API and cannot live on a type. Operating-system imports are declared
where they are used (`BCryptGenRandom` in `MCPServer.RequestState`). Every
other routine belongs to a class or a record.

### Parameter names in attributes and exceptions

Schema attributes and exception classes keep the `A` prefix on constructor
parameters where the parameter would otherwise shadow a property of the same
class (`Code`, `Message`, `Description`). Elsewhere parameters carry no prefix.

### Framework callback signatures

Indy event handlers keep the signature Indy declares, including `var`
parameters (`OnQuerySSLPort`, `OnCreatePostStream`, `OnParseAuthentication`).

### DUnitX fixtures

The test runner uses RTTI discovery. Test units have no `initialization`
section, and every fixture carries `[TestFixture]`.

### Class section markers

The `{ TClassName }` markers the IDE generates in the implementation section
are kept. No other comments are used; behaviour is documented in the README,
the CHANGELOG and the migration guide.
