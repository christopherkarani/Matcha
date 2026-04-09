# Matcha

Pure Swift implementation of TOON (Token-Oriented Object Notation), including:

- `Matcha`: the Swift library
- `matcha`: a native Swift CLI
- `MatchaBenchmarks`: a benchmark executable
- official spec-fixture conformance tests vendored into the Swift test suite

The repo is SwiftPM-only. There is no Node, npm, pnpm, or JavaScript runtime/tooling in this implementation.

## Quick start

```bash
swift build
swift test
swift run matcha --help
```

## Features

- Pure Swift encoder, decoder, CLI, tests, benchmarks, and CI
- Ordered object model through `MatchaObject`
- Strict decode validation by default
- Key folding and path expansion options
- Streaming-oriented APIs:
  - `MatchaEncoder.encodeLines(_:onLine:)`
  - `MatchaDecoder.decodeEvents(_:onEvent:)`
  - async `MatchaDecoder.decodeEvents(_:onEvent:)` for `AsyncSequence<String>`
- `Codable` bridge for Swift model types
- Official TOON fixture coverage under `Tests/MatchaTests/Fixtures`

## Encode

```bash
printf '{"name":"Ada","age":37}' | swift run matcha --encode
```

## Decode

```bash
printf 'name: Ada\nage: 37\n' | swift run matcha --decode
```

## Swift API

```swift
import Matcha

let value: MatchaValue = .object([
  "name": "Ada",
  "age": 37,
  "friends": ["Grace", "Linus"],
])

let matcha = try MatchaEncoder().encode(value)
let roundTrip = try MatchaDecoder().decode(matcha)
```

## Streaming APIs

```swift
import Matcha

let encoder = MatchaEncoder()
try encoder.encodeLines(["swift", "toon"]) { line in
  print(line)
}

let decoder = MatchaDecoder()
try decoder.decodeEvents([
  "user:",
  "  name: Ada",
]) { event in
  print(event)
}
```

## CLI

```bash
swift run matcha --help
swift run matcha sample.json --encode
swift run matcha sample.toon --decode
swift run matcha sample.json --encode --stats
```

Without `--encode` or `--decode`, the CLI infers mode from the input path: `.toon` decodes, everything else encodes. Omitting the input path reads from stdin.
`--stats` reports exact byte savings and an explicitly approximate token estimate derived from UTF-8 size.

## Benchmarks

```bash
swift run MatchaBenchmarks
swift run MatchaBenchmarks --loops 200 --scale 1000
```

## Specification

The canonical spec lives in `toon-format/spec`:

- [SPEC.md](https://github.com/toon-format/spec/blob/main/SPEC.md)
- [Conformance fixtures](https://github.com/toon-format/spec/tree/main/tests)
