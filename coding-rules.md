# Coding rules

This file records where this repository deviates from the GDK Delphi coding standard and why. Everything not listed here follows that standard.

## Exceptions

### Registration in `initialization` sections

Tools, prompts, resources and resource templates register themselves in the `initialization` section of their own unit. Consumers add a unit to their project's `uses` clause and the item is available; that is the public contract of the library and the reason no central registration list exists. New tool, prompt and resource units follow the same pattern.

### System.Generics.Collections

The library has no third-party dependencies so that it can be dropped into any Delphi project. `System.Generics.Collections` is used instead of Spring4D collections.

### Public global functions

`MCPServer.Types` and a few other units expose global functions (`IsJsonString`, `StandardInputStream`, `StandardOutputStream`) because they are part of the public API and because attribute or record helpers cannot host them. Internal helpers still belong in classes or records.

### Constructor parameter names in attributes

Schema attributes and exception classes keep the `A` prefix on constructor parameters where the parameter would otherwise shadow a property of the same class (`Code`, `Message`, `Description`). Elsewhere parameters carry no prefix.

### Framework callback signatures

Indy event handlers keep the signature Indy declares, including `var` parameters (for example `OnQuerySSLPort`).

### DUnitX fixtures

The test runner uses RTTI discovery (`UseRTTI := True`). Test units have no `initialization` section.

### Class section markers

The `{ TClassName }` markers the IDE generates in the implementation section are kept. No other comments are used; behaviour is documented in the README, CHANGELOG and MIGRATION guide.
