# TOON Specification Notes

This repository is the pure Swift implementation of TOON. The canonical language-agnostic specification lives in the dedicated spec repository:

- [Full specification](https://github.com/toon-format/spec/blob/main/SPEC.md)
- [Changelog](https://github.com/toon-format/spec/blob/main/CHANGELOG.md)
- [Examples](https://github.com/toon-format/spec/tree/main/examples)
- [Conformance fixtures](https://github.com/toon-format/spec/tree/main/tests)

## Scope of this repository

`christopherkarani/Matcha` provides:

- `Matcha`, a Swift library for encoding and decoding TOON
- `matcha`, a native Swift CLI for JSON <-> TOON conversion
- `MatchaBenchmarks`, a Swift benchmark executable
- vendored conformance fixtures from the spec repository, exercised by `swift test`

This repository does not define the spec. It implements TOON v3.0 and treats `toon-format/spec` as the source of truth for syntax and observable behavior.

## Implementation expectations

The Swift implementation aims for:

- pure Swift tooling throughout the repo
- ordered object preservation through the `MatchaValue` / `MatchaObject` model
- strict decoding by default with explicit options for relaxed behavior
- streaming-oriented library APIs for line emission and event decoding
- compatibility with the official encode/decode fixture corpus

## Updating spec compatibility

When the TOON spec evolves:

1. update the vendored fixture files in `Tests/MatchaTests/Fixtures`
2. adjust the Swift implementation as needed
3. rerun `swift test`
4. document any intentional implementation divergence here and in `README.md`
