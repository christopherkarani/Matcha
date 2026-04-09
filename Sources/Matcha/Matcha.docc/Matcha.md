# ``Matcha``

Pure Swift TOON encoding and decoding.

## Overview

`Matcha` provides:

- `MatchaEncoder` for TOON output
- `MatchaDecoder` for TOON parsing
- `MatchaValue` for a Swift-native intermediate representation
- `matcha` for command-line conversion between JSON and TOON

The library is built for SwiftPM-first usage and keeps the entire implementation stack in Swift, including the CLI, tests, benchmarks, and CI integration.

## Core Types

- ``MatchaValue`` models TOON values while preserving ordered object entries through ``MatchaObject``.
- ``MatchaEncoderOptions`` controls delimiter selection, indentation, key folding, and flatten depth.
- ``MatchaDecoderOptions`` controls indentation rules, strict validation, and path expansion.
- ``MatchaEvent`` exposes a streaming-friendly event model for incremental consumers.

## Encoding

Use ``MatchaEncoder`` when you want a complete TOON string:

```swift
import Matcha

let payload: MatchaValue = .object([
  "name": "Ada",
  "skills": ["swift", "compilers"],
])

let matcha = try MatchaEncoder().encode(payload)
```

For incremental output, use the callback-based line emitter:

```swift
let encoder = MatchaEncoder()
try encoder.encodeLines(payload) { line in
  print(line)
}
```

## Decoding

Use ``MatchaDecoder`` to parse TOON into ``MatchaValue`` or into `Decodable` Swift types:

```swift
let decoder = MatchaDecoder()
let value = try decoder.decode("name: Ada")
```

For event-driven consumers, stream parse events directly:

```swift
try decoder.decodeEvents([
  "user:",
  "  name: Ada",
]) { event in
  print(event)
}
```

Event streaming does not apply path expansion. Use full-value decoding when you need `expandPaths`.
Async overloads accept `AsyncSequence<String>` and now parse incrementally rather than buffering the entire input first.

## Conformance

The test suite vendors the official TOON encode/decode fixtures from the spec repository and exercises them with `swift test`. That makes this package suitable as a Swift-native reference implementation of the published TOON behavior, while the canonical language spec remains in `toon-format/spec`.
