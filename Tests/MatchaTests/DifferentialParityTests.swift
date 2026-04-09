import Foundation
import Testing
@testable import Matcha

@Test func typeScriptReferenceParityCorpus() async throws {
  guard let harness = try DifferentialHarness.makeIfEnabled() else { return }

  let encodeCases = try makeEncodeParityCases()
  let decodeCases = try makeDecodeParityCases()
  let eventCases = try makeEventParityCases(from: decodeCases)

  let swiftEncode = try encodeCases.map(harness.runSwiftEncode(_:))
  let tsEncode = try harness.runTSEncode(encodeCases)
  try assertParity(label: "encode", swiftEncode, tsEncode)

  let swiftDecode = try decodeCases.map(harness.runSwiftDecode(_:))
  let tsDecode = try harness.runTSDecode(decodeCases)
  try assertParity(label: "decode", swiftDecode, tsDecode)

  let swiftEvents = try eventCases.map(harness.runSwiftEvents(_:))
  let tsEvents = try harness.runTSEvents(eventCases)
  try assertParity(label: "events-sync", swiftEvents, tsEvents)

  let swiftAsyncEvents = try await harness.runSwiftAsyncEvents(eventCases)
  let tsAsyncEvents = try harness.runTSAsyncEvents(eventCases)
  try assertParity(label: "events-async", swiftAsyncEvents, tsAsyncEvents)
}

@Test func typeScriptReferenceParityCliAndPropertyCorpus() async throws {
  guard let harness = try DifferentialHarness.makeIfEnabled() else { return }

  let propertyCases = makeRandomEncodeCases(count: 75, seed: 0x5EED_F00D)
  let swiftPropertyEncode = try propertyCases.map(harness.runSwiftEncode(_:))
  let tsPropertyEncode = try harness.runTSEncode(propertyCases)
  try assertParity(label: "encode-property", swiftPropertyEncode, tsPropertyEncode)

  let propertyDecodeCases = propertyCases.compactMap { testCase -> DecodeParityCase? in
    guard let encoded = try? harness.runSwiftEncode(testCase), encoded.ok, let output = encoded.output else {
      return nil
    }
    return DecodeParityCase(
      name: "roundtrip-\(testCase.name)",
      inputTOON: output,
      options: .init(indent: testCase.options.indent, strict: true, expandPaths: "off"),
      shouldError: false
    )
  }
  let swiftPropertyDecode = try propertyDecodeCases.map(harness.runSwiftDecode(_:))
  let tsPropertyDecode = try harness.runTSDecode(propertyDecodeCases)
  try assertParity(label: "decode-property", swiftPropertyDecode, tsPropertyDecode)

  let cliCases = try makeCLIParityCases()
  let mismatches = try cliCases.compactMap { testCase in
    let swift = try harness.runSwiftCLI(testCase)
    let ts = try harness.runTSCLI(testCase)
    return normalizeCLIResult(swift) == normalizeCLIResult(ts)
      ? nil
      : """
      [cli] \(testCase.name)
      swift: \(normalizeCLIResult(swift))
      typescript: \(normalizeCLIResult(ts))
      """
  }
  if !mismatches.isEmpty {
    Issue.record(Comment(rawValue: mismatches.joined(separator: "\n\n")))
  }
}

private struct DifferentialHarness {
  let packageRoot: URL
  let tsWorkspace: URL
  let tsModule: URL
  let tsCLI: URL
  let swiftCLI: URL
  let runnerScript: URL

  static func makeIfEnabled() throws -> DifferentialHarness? {
    guard ProcessInfo.processInfo.environment["TOON_RUN_TS_PARITY"] == "1" else {
      return nil
    }

    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let tsWorkspace = packageRoot.appendingPathComponent(".build/compat/ts-reference", isDirectory: true)
    let tsModule = tsWorkspace.appendingPathComponent("packages/toon/dist/index.mjs")
    let tsCLI = tsWorkspace.appendingPathComponent("packages/cli/bin/toon.mjs")
    let swiftCLI = packageRoot.appendingPathComponent(".build/debug/matcha")
    let runnerDirectory = packageRoot.appendingPathComponent(".build/compat/runner", isDirectory: true)

    try ensureReferenceWorkspace(packageRoot: packageRoot, tsWorkspace: tsWorkspace, tsModule: tsModule)
    try ensureSwiftCLI(packageRoot: packageRoot, swiftCLI: swiftCLI)
    try FileManager.default.createDirectory(at: runnerDirectory, withIntermediateDirectories: true)
    let runnerScript = runnerDirectory.appendingPathComponent("ts-parity-runner.mjs")
    try runnerSource.write(to: runnerScript, atomically: true, encoding: .utf8)

    return DifferentialHarness(
      packageRoot: packageRoot,
      tsWorkspace: tsWorkspace,
      tsModule: tsModule,
      tsCLI: tsCLI,
      swiftCLI: swiftCLI,
      runnerScript: runnerScript
    )
  }

  func runSwiftEncode(_ testCase: EncodeParityCase) throws -> ParityResult {
    do {
      let value = try MatchaValue.parseJSON(testCase.inputJSON)
      let encoder = MatchaEncoder(options: testCase.options.toSwiftEncodeOptions())
      return .init(name: testCase.name, ok: true, output: try encoder.encode(value), error: nil, events: nil)
    } catch {
      return .init(name: testCase.name, ok: false, output: nil, error: normalizeSwiftError(error), events: nil)
    }
  }

  func runSwiftDecode(_ testCase: DecodeParityCase) throws -> ParityResult {
    do {
      let decoder = MatchaDecoder(options: testCase.options.toSwiftDecodeOptions())
      let value = try decoder.decode(testCase.inputTOON)
      return .init(name: testCase.name, ok: true, output: value.jsonString(indentedBy: 0), error: nil, events: nil)
    } catch {
      return .init(name: testCase.name, ok: false, output: nil, error: normalizeSwiftError(error), events: nil)
    }
  }

  func runSwiftEvents(_ testCase: EventParityCase) throws -> ParityResult {
    do {
      let decoder = MatchaDecoder(options: testCase.options.toSwiftDecodeOptions())
      let lines = splitLinesPreservingEmpty(testCase.inputTOON)
      let events = try decoder.decodeEvents(lines).map(NormalizedEvent.init)
      return .init(name: testCase.name, ok: true, output: nil, error: nil, events: events)
    } catch {
      return .init(name: testCase.name, ok: false, output: nil, error: normalizeSwiftError(error), events: nil)
    }
  }

  func runSwiftAsyncEvents(_ testCases: [EventParityCase]) async throws -> [ParityResult] {
    var results: [ParityResult] = []
    for testCase in testCases {
      do {
        let decoder = MatchaDecoder(options: testCase.options.toSwiftDecodeOptions())
        let collector = AsyncNormalizedEventCollector()
        let stream = AsyncStream<String> { continuation in
          for line in splitLinesPreservingEmpty(testCase.inputTOON) {
            continuation.yield(line)
          }
          continuation.finish()
        }
        try await decoder.decodeEvents(stream) { event in
          await collector.append(.init(event))
        }
        results.append(.init(name: testCase.name, ok: true, output: nil, error: nil, events: await collector.events))
      } catch {
        results.append(.init(name: testCase.name, ok: false, output: nil, error: normalizeSwiftError(error), events: nil))
      }
    }
    return results
  }

  func runTSEncode(_ testCases: [EncodeParityCase]) throws -> [ParityResult] {
    try runTSBatch(action: "encode", payload: testCases)
  }

  func runTSDecode(_ testCases: [DecodeParityCase]) throws -> [ParityResult] {
    try runTSBatch(action: "decode", payload: testCases)
  }

  func runTSEvents(_ testCases: [EventParityCase]) throws -> [ParityResult] {
    try runTSBatchPerCase(action: "events", payload: testCases)
  }

  func runTSAsyncEvents(_ testCases: [EventParityCase]) throws -> [ParityResult] {
    try runTSBatchPerCase(action: "eventsAsync", payload: testCases)
  }

  func runSwiftCLI(_ testCase: CLIParityCase) throws -> CLIResult {
    try runCLI(executable: swiftCLI, executableArgumentsPrefix: [], testCase: testCase)
  }

  func runTSCLI(_ testCase: CLIParityCase) throws -> CLIResult {
    try runCLI(executable: URL(fileURLWithPath: "/usr/bin/env"), executableArgumentsPrefix: ["node", tsCLI.path], testCase: testCase)
  }

  private func runTSBatch<Input: Encodable>(action: String, payload: [Input]) throws -> [ParityResult] {
    let temporaryDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let corpusURL = temporaryDirectory.appendingPathComponent("corpus.json")
    let data = try JSONEncoder().encode(payload)
    try data.write(to: corpusURL)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
      "node",
      runnerScript.path,
      action,
      tsModule.path,
      corpusURL.path,
    ]
    process.currentDirectoryURL = packageRoot

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()

    let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
      throw ParityHarnessError.nodeRunnerFailed(stderrText)
    }

    let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
    return try JSONDecoder().decode([ParityResult].self, from: outputData)
  }

  private func runTSBatchPerCase(action: String, payload: [EventParityCase]) throws -> [ParityResult] {
    try payload.map { testCase in
      let results = try runTSBatchWithTimeout(action: action, payload: [testCase], timeout: 5)
      guard let result = results.first else {
        throw ParityHarnessError.nodeRunnerFailed("Runner returned no results for \(action)")
      }
      return result
    }
  }

  private func runTSBatchWithTimeout(action: String, payload: [EventParityCase], timeout: TimeInterval) throws -> [ParityResult] {
    let temporaryDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let corpusURL = temporaryDirectory.appendingPathComponent("corpus.json")
    let data = try JSONEncoder().encode(payload)
    try data.write(to: corpusURL)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
      "node",
      runnerScript.path,
      action,
      tsModule.path,
      corpusURL.path,
    ]
    process.currentDirectoryURL = packageRoot

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()

    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }

    guard !process.isRunning else {
      process.terminate()
      process.waitUntilExit()
      return [.init(name: payload.first?.name ?? "unknown-case", ok: false, output: nil, error: "timeout", events: nil)]
    }

    let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
      throw ParityHarnessError.nodeRunnerFailed(stderrText)
    }

    let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
    return try JSONDecoder().decode([ParityResult].self, from: outputData)
  }

  private func runCLI(executable: URL, executableArgumentsPrefix: [String], testCase: CLIParityCase) throws -> CLIResult {
    let tempDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    let inputURL = tempDirectory.appendingPathComponent("input.\(testCase.inputExtension)")
    let outputURL = tempDirectory.appendingPathComponent("output.\(testCase.outputExtension)")
    if let fileInput = testCase.fileInput {
      try fileInput.write(to: inputURL, atomically: true, encoding: .utf8)
    }

    let process = Process()
    process.executableURL = executable
    process.arguments = executableArgumentsPrefix + testCase.arguments(inputURL: inputURL, outputURL: outputURL)
    process.currentDirectoryURL = packageRoot

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    if let stdin = testCase.stdin {
      let stdinPipe = Pipe()
      process.standardInput = stdinPipe
      try process.run()
      stdinPipe.fileHandleForWriting.write(Data(stdin.utf8))
      try stdinPipe.fileHandleForWriting.close()
    } else {
      try process.run()
    }

    process.waitUntilExit()

    let writtenOutput = FileManager.default.fileExists(atPath: outputURL.path)
      ? (try? String(contentsOf: outputURL, encoding: .utf8))
      : nil

    return CLIResult(
      exitCode: process.terminationStatus,
      stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
      stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
      fileOutput: writtenOutput
    )
  }
}

private struct EncodeParityCase: Codable {
  var name: String
  var inputJSON: String
  var options: EncodeOptionsPayload
}

private struct DecodeParityCase: Codable {
  var name: String
  var inputTOON: String
  var options: DecodeOptionsPayload
  var shouldError: Bool = false
}

private struct EventParityCase: Codable {
  var name: String
  var inputTOON: String
  var options: DecodeOptionsPayload
}

private struct EncodeOptionsPayload: Codable {
  var indent: Int = 2
  var delimiter: String? = nil
  var keyFolding: String? = nil
  var flattenDepth: Int? = nil

  func toSwiftEncodeOptions() -> MatchaEncoderOptions {
    MatchaEncoderOptions(
      indent: indent,
      delimiter: parseDelimiter(delimiter),
      keyFolding: MatchaKeyFolding(rawValue: keyFolding ?? "off") ?? .off,
      flattenDepth: flattenDepth ?? .max
    )
  }
}

private struct DecodeOptionsPayload: Codable {
  var indent: Int = 2
  var strict: Bool = true
  var expandPaths: String? = nil

  func toSwiftDecodeOptions() -> MatchaDecoderOptions {
    MatchaDecoderOptions(
      indent: indent,
      strict: strict,
      expandPaths: MatchaPathExpansion(rawValue: expandPaths ?? "off") ?? .off
    )
  }
}

private struct ParityResult: Codable, Equatable {
  var name: String
  var ok: Bool
  var output: String?
  var error: String?
  var events: [NormalizedEvent]?
}

private struct NormalizedEvent: Codable, Equatable {
  var type: String
  var key: String?
  var wasQuoted: Bool?
  var length: Int?
  var valueJSON: String?

  init(type: String, key: String?, wasQuoted: Bool?, length: Int?, valueJSON: String?) {
    self.type = type
    self.key = key
    self.wasQuoted = wasQuoted
    self.length = length
    self.valueJSON = valueJSON
  }

  init(_ event: MatchaEvent) {
    switch event {
    case .startObject:
      self = .init(type: "startObject", key: nil, wasQuoted: nil, length: nil, valueJSON: nil)
    case .endObject:
      self = .init(type: "endObject", key: nil, wasQuoted: nil, length: nil, valueJSON: nil)
    case let .startArray(length):
      self = .init(type: "startArray", key: nil, wasQuoted: nil, length: length, valueJSON: nil)
    case .endArray:
      self = .init(type: "endArray", key: nil, wasQuoted: nil, length: nil, valueJSON: nil)
    case let .key(key, _):
      self = .init(type: "key", key: key, wasQuoted: nil, length: nil, valueJSON: nil)
    case let .primitive(value):
      self = .init(type: "primitive", key: nil, wasQuoted: nil, length: nil, valueJSON: value.jsonString(indentedBy: 0))
    }
  }
}

private struct CLIParityCase {
  enum Mode {
    case stdin
    case file
  }

  var name: String
  var mode: Mode
  var inputExtension: String
  var outputExtension: String
  var flags: [String]
  var stdin: String?
  var fileInput: String?

  func arguments(inputURL: URL, outputURL: URL) -> [String] {
    var arguments: [String] = []
    switch mode {
    case .stdin:
      break
    case .file:
      arguments.append(inputURL.path)
    }
    arguments.append(contentsOf: flags.map { $0 == "__OUTPUT__" ? outputURL.path : $0 })
    return arguments
  }
}

private struct CLIResult {
  var exitCode: Int32
  var stdout: String
  var stderr: String
  var fileOutput: String?
}

private actor AsyncNormalizedEventCollector {
  private(set) var events: [NormalizedEvent] = []

  func append(_ event: NormalizedEvent) {
    events.append(event)
  }
}

private func assertParity(label: String, _ swift: [ParityResult], _ ts: [ParityResult]) throws {
  let swiftByName = Dictionary(uniqueKeysWithValues: swift.map { ($0.name, $0) })
  let tsByName = Dictionary(uniqueKeysWithValues: ts.map { ($0.name, $0) })
  let names = Array(Set(swiftByName.keys).union(tsByName.keys)).sorted()

  var mismatches: [String] = []
  for name in names {
    guard let swift = swiftByName[name], let ts = tsByName[name] else {
      mismatches.append("[\(label)] missing case \(name)")
      continue
    }

    let outputsMatch: Bool
    if label.hasPrefix("decode") {
      outputsMatch = decodedOutputsSemanticallyMatch(swift.output, ts.output)
    } else {
      outputsMatch = swift.output == ts.output
    }

    let okMatch = swift.ok == ts.ok
    let errorsMatch = swift.error.map(normalizeErrorCore) == ts.error.map(normalizeErrorCore)
    let eventsMatch = eventsSemanticallyMatch(swift.events, ts.events)

    if !(okMatch && outputsMatch && errorsMatch && eventsMatch) {
      mismatches.append("""
      [\(label)] \(name)
      swift: \(swift)
      typescript: \(ts)
      """)
    }
  }

  if !mismatches.isEmpty {
    Issue.record(Comment(rawValue: mismatches.joined(separator: "\n\n")))
  }
}

private func makeEncodeParityCases() throws -> [EncodeParityCase] {
  let fixtureCases = try loadFixtureFiles(named: "encode").flatMap { fixture -> [EncodeParityCase] in
    fixture.tests.compactMap { testCase in
      guard !testCase.shouldError else { return nil }
      return EncodeParityCase(
        name: "fixture/\(fixture.file)/\(testCase.name)",
        inputJSON: testCase.input.jsonString(indentedBy: 0),
        options: testCase.options.encode
      )
    }
  }

  return fixtureCases + manualEncodeCases() + largeEncodeCases()
}

private func makeDecodeParityCases() throws -> [DecodeParityCase] {
  let fixtureCases = try loadFixtureFiles(named: "decode").flatMap { fixture -> [DecodeParityCase] in
    fixture.tests.compactMap { testCase in
      guard let input = testCase.input.stringValue else { return nil }
      return DecodeParityCase(
        name: "fixture/\(fixture.file)/\(testCase.name)",
        inputTOON: input,
        options: testCase.options.decode,
        shouldError: testCase.shouldError
      )
    }
  }

  return fixtureCases + manualDecodeCases() + largeDecodeCases()
}

private func makeEventParityCases(from decodeCases: [DecodeParityCase]) throws -> [EventParityCase] {
  let filtered = decodeCases.filter { !$0.shouldError && ($0.options.expandPaths ?? "off") == "off" }
  return filtered.map { testCase in
    EventParityCase(name: testCase.name, inputTOON: testCase.inputTOON, options: .init(indent: testCase.options.indent, strict: testCase.options.strict, expandPaths: nil))
  }
}

private func makeCLIParityCases() throws -> [CLIParityCase] {
  [
    .init(name: "stdin-encode", mode: .stdin, inputExtension: "json", outputExtension: "toon", flags: ["--encode"], stdin: #"{"name":"Ada","age":37,"tags":["swift","toon"]}"#, fileInput: nil),
    .init(name: "stdin-decode", mode: .stdin, inputExtension: "toon", outputExtension: "json", flags: ["--decode"], stdin: "name: Ada\nage: 37\n", fileInput: nil),
    .init(name: "stdin-invalid-decode", mode: .stdin, inputExtension: "toon", outputExtension: "json", flags: ["--decode"], stdin: "items[2]: only-one\n", fileInput: nil),
    .init(name: "file-encode-output", mode: .file, inputExtension: "json", outputExtension: "toon", flags: ["--encode", "--output", "__OUTPUT__"], stdin: nil, fileInput: #"{"name":"Ada","meta":{"active":true,"score":9.5}}"#),
    .init(name: "file-decode-output", mode: .file, inputExtension: "toon", outputExtension: "json", flags: ["--decode", "--output", "__OUTPUT__"], stdin: nil, fileInput: "name: Ada\nmeta.active: true\nmeta.score: 9.5\n"),
  ]
}

private func manualEncodeCases() -> [EncodeParityCase] {
  [
    .init(name: "manual/dotted-literal-key", inputJSON: #"{"a.b":"literal","nested":{"x":{"y":[1,2,3]}}}"#, options: .init(indent: 2, delimiter: ",", keyFolding: "safe", flattenDepth: 3)),
    .init(name: "manual/string-quoting", inputJSON: #"{"items":["05","-01","true","contains,comma","contains:colon","has\"quote"]}"#, options: .init(indent: 2, delimiter: ",", keyFolding: "off", flattenDepth: nil)),
    .init(name: "manual/tabular", inputJSON: #"{"users":[{"id":1,"name":"Ada","role":"compiler"},{"id":2,"name":"Grace","role":"math"}]}"#, options: .init(indent: 2, delimiter: ",", keyFolding: "off", flattenDepth: nil)),
  ]
}

private func manualDecodeCases() -> [DecodeParityCase] {
  [
    .init(name: "manual/quoted-dotted-key", inputTOON: "\"a.b\": literal\n", options: .init(indent: 2, strict: true, expandPaths: "off")),
    .init(name: "manual/path-expansion", inputTOON: "meta.active: true\nmeta.score: 9.5\n", options: .init(indent: 2, strict: true, expandPaths: "safe")),
    .init(name: "manual/root-primitive", inputTOON: "true\n", options: .init(indent: 2, strict: true, expandPaths: "off")),
    .init(name: "manual/blank-line-error", inputTOON: "items[2]:\n  - one\n\n  - two\n", options: .init(indent: 2, strict: true, expandPaths: "off")),
    .init(name: "manual/tab-delimited", inputTOON: "rows[2\t]{id\tname}:\n  1\tAda\n  2\tGrace\n", options: .init(indent: 2, strict: true, expandPaths: "off")),
  ]
}

private func largeEncodeCases() -> [EncodeParityCase] {
  let benchmarkSample = makeLargeSample(scale: 120)
  let app = MatchaObject(entries: [
    .init(key: "name", value: "Paper Lantern"),
    .init(key: "version", value: "1.42.0"),
    .init(key: "region", value: "us-east-1"),
  ])
  let features: [MatchaValue] = [
    .object(["key": "search", "enabled": true, "rollout": 100]),
    .object(["key": "memory", "enabled": true, "rollout": 50]),
    .object(["key": "telemetry", "enabled": false, "rollout": 0]),
  ]
  let projects: [MatchaValue] = (0..<60).map { index in
    let id = MatchaValue.number(MatchaNumber(rawValue: String(index + 1))!)
    let name = MatchaValue.string("Project \(index + 1)")
    let active = MatchaValue.bool(index % 3 != 0)
    let object = MatchaObject(entries: [
      .init(key: "id", value: id),
      .init(key: "name", value: name),
      .init(key: "active", value: active),
    ])
    return .object(object)
  }
  let appState = MatchaValue.object(MatchaObject(entries: [
    .init(key: "app", value: .object(app)),
    .init(key: "features", value: .array(features)),
    .init(key: "projects", value: .array(projects)),
  ]))

  return [
    .init(name: "large/benchmark-sample", inputJSON: benchmarkSample.jsonString(indentedBy: 0), options: .init(indent: 2, delimiter: ",", keyFolding: "safe", flattenDepth: 4)),
    .init(name: "large/app-state", inputJSON: appState.jsonString(indentedBy: 0), options: .init(indent: 2, delimiter: ",", keyFolding: "safe", flattenDepth: 3)),
  ]
}

private func largeDecodeCases() -> [DecodeParityCase] {
  largeEncodeCases().compactMap { testCase in
    let encoder = MatchaEncoder(options: testCase.options.toSwiftEncodeOptions())
    guard let value = try? MatchaValue.parseJSON(testCase.inputJSON),
          let output = try? encoder.encode(value) else {
      return nil
    }
    return .init(name: testCase.name, inputTOON: output, options: .init(indent: testCase.options.indent, strict: true, expandPaths: "off"))
  }
}

private func makeRandomEncodeCases(count: Int, seed: UInt64) -> [EncodeParityCase] {
  var generator = RandomMatchaGenerator(state: seed)
  return (0..<count).map { index in
    let value = generator.makeValue(maxDepth: 4)
    return EncodeParityCase(
      name: "generated/\(index)",
      inputJSON: value.jsonString(indentedBy: 0),
      options: .init(
        indent: [2, 4][index % 2],
        delimiter: [",", "|", "\t"][index % 3],
        keyFolding: index.isMultiple(of: 2) ? "off" : "safe",
        flattenDepth: index.isMultiple(of: 5) ? 2 : 4
      )
    )
  }
}

private struct FixtureSuite {
  struct TestCase {
    var name: String
    var input: MatchaValue
    var shouldError: Bool
    var options: FixtureOptions
  }

  var file: String
  var tests: [TestCase]
}

private struct FixtureOptions {
  var encode: EncodeOptionsPayload
  var decode: DecodeOptionsPayload
}

private func loadFixtureFiles(named directory: String) throws -> [FixtureSuite] {
  let fixtureDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Fixtures/\(directory)", isDirectory: true)
  let files = try FileManager.default.contentsOfDirectory(at: fixtureDirectory, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "json" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

  return try files.map { file in
    let raw = try String(contentsOf: file, encoding: .utf8)
    guard case let .object(root) = try MatchaValue.parseJSON(raw),
          case let .array(testsValue) = try requireValue(in: root, key: "tests") else {
      throw ParityHarnessError.invalidFixture(file.lastPathComponent)
    }

    let tests = try testsValue.map { value -> FixtureSuite.TestCase in
      guard case let .object(object) = value else {
        throw ParityHarnessError.invalidFixture(file.lastPathComponent)
      }
      let optionsValue = object["options"]
      let options = try parseFixtureOptions(optionsValue)
      return .init(
        name: try requireString(in: object, key: "name"),
        input: try requireValue(in: object, key: "input"),
        shouldError: object["shouldError"]?.boolValue ?? false,
        options: options
      )
    }

    return FixtureSuite(file: file.lastPathComponent, tests: tests)
  }
}

private func parseFixtureOptions(_ value: MatchaValue?) throws -> FixtureOptions {
  guard let value else { return .init(encode: .init(), decode: .init()) }
  guard case let .object(object) = value else {
    throw ParityHarnessError.invalidFixture("options")
  }

  return .init(
    encode: .init(
      indent: object["indent"]?.intValue ?? 2,
      delimiter: object["delimiter"]?.stringValue,
      keyFolding: object["keyFolding"]?.stringValue,
      flattenDepth: object["flattenDepth"]?.intValue
    ),
    decode: .init(
      indent: object["indent"]?.intValue ?? 2,
      strict: object["strict"]?.boolValue ?? true,
      expandPaths: object["expandPaths"]?.stringValue
    )
  )
}

private func requireValue(in object: MatchaObject, key: String) throws -> MatchaValue {
  guard let value = object[key] else {
    throw ParityHarnessError.invalidFixture(key)
  }
  return value
}

private func requireString(in object: MatchaObject, key: String) throws -> String {
  guard let value = object[key]?.stringValue else {
    throw ParityHarnessError.invalidFixture(key)
  }
  return value
}

private func splitLinesPreservingEmpty(_ value: String) -> [String] {
  value.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
}

private func parseDelimiter(_ raw: String?) -> MatchaDelimiter {
  switch raw {
  case "\t":
    return .tab
  case "|":
    return .pipe
  default:
    return .comma
  }
}

private func normalizeSwiftError(_ error: Error) -> String {
  if let error = error as? MatchaError {
    return "\(error.code.rawValue): \(error.message)"
  }
  return String(describing: error)
}

private func normalizeErrorCore(_ value: String) -> String {
  let cleaned = stripANSI(value)
    .split(separator: "\n")
    .map { $0.trimmingCharacters(in: .whitespaces) }
    .first(where: { !$0.isEmpty && !$0.hasPrefix("at ") }) ?? value

  return cleaned
    .replacingOccurrences(of: #"^Line \d+:\s*"#, with: "", options: .regularExpression)
    .replacingOccurrences(of: #"^[a-z][A-Za-z0-9]*:\s*"#, with: "", options: .regularExpression)
    .replacingOccurrences(of: "ERROR  ", with: "")
    .replacingOccurrences(of: "Failed to decode TOON: ", with: "")
    .replacingOccurrences(of: "Failed to parse JSON: ", with: "")
    .replacingOccurrences(of: " in strict mode", with: "")
    .replacingOccurrences(of: "exact multiple of", with: "a multiple of")
    .replacingOccurrences(of: "Blank lines are not allowed inside list array", with: "Blank lines inside list array are not allowed")
    .replacingOccurrences(of: "Blank lines are not allowed inside tabular array", with: "Blank lines inside tabular array are not allowed")
    .replacingOccurrences(of: "list array items", with: "list items")
    .replacingOccurrences(of: ", but got ", with: ", found ")
    .replacingOccurrences(of: " but got ", with: " found ")
    .replacingOccurrences(of: "\"", with: "'")
}

private func normalizeCLIResult(_ result: CLIResult) -> String {
  let stdout = result.exitCode == 0 ? normalizeCLISuccess(stripANSI(result.stdout)) : ""
  let stderr = normalizeErrorCore(result.stderr)
  let fileOutput = result.fileOutput?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  return "exit=\(result.exitCode)|stdout=\(stdout)|stderr=\(stderr)|file=\(fileOutput)"
}

private func normalizeCLISuccess(_ value: String) -> String {
  let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
  if trimmed.contains("Encoded"), trimmed.contains("→") {
    return "encoded"
  }
  if trimmed.contains("Decoded"), trimmed.contains("→") {
    return "decoded"
  }
  return trimmed
}

private func stripANSI(_ value: String) -> String {
  value.replacingOccurrences(of: #"\u001B\[[0-9;]*m"#, with: "", options: .regularExpression)
}

private func decodedOutputsSemanticallyMatch(_ lhs: String?, _ rhs: String?) -> Bool {
  switch (lhs, rhs) {
  case (nil, nil):
    return true
  case let (lhs?, rhs?):
    guard let lhsValue = try? MatchaValue.parseJSON(lhs),
          let rhsValue = try? MatchaValue.parseJSON(rhs) else {
      return lhs == rhs
    }
    return semanticEqual(lhsValue, rhsValue)
  default:
    return false
  }
}

private func semanticEqual(_ lhs: MatchaValue, _ rhs: MatchaValue) -> Bool {
  switch (lhs, rhs) {
  case (.null, .null):
    return true
  case let (.bool(lhs), .bool(rhs)):
    return lhs == rhs
  case let (.string(lhs), .string(rhs)):
    return lhs == rhs
  case let (.number(lhs), .number(rhs)):
    return semanticEqual(lhs, rhs)
  case let (.array(lhs), .array(rhs)):
    return lhs.count == rhs.count && zip(lhs, rhs).allSatisfy(semanticEqual)
  case let (.object(lhs), .object(rhs)):
    let lhsKeys = Set(lhs.entries.map(\.key))
    let rhsKeys = Set(rhs.entries.map(\.key))
    guard lhsKeys == rhsKeys else { return false }
    return lhsKeys.allSatisfy { key in
      guard let lhsValue = lhs[key], let rhsValue = rhs[key] else { return false }
      return semanticEqual(lhsValue, rhsValue)
    }
  default:
    return false
  }
}

private func semanticEqual(_ lhs: MatchaNumber, _ rhs: MatchaNumber) -> Bool {
  if lhs.rawValue == rhs.rawValue {
    return true
  }

  let locale = Locale(identifier: "en_US_POSIX")
  if let lhsDecimal = Decimal(string: lhs.rawValue, locale: locale),
     let rhsDecimal = Decimal(string: rhs.rawValue, locale: locale) {
    return lhsDecimal == rhsDecimal
  }

  if let lhsDouble = Double(lhs.rawValue),
     let rhsDouble = Double(rhs.rawValue) {
    return lhsDouble == rhsDouble
  }

  return false
}

private func eventsSemanticallyMatch(_ lhs: [NormalizedEvent]?, _ rhs: [NormalizedEvent]?) -> Bool {
  switch (lhs, rhs) {
  case (nil, nil):
    return true
  case let (lhs?, rhs?):
    guard lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).allSatisfy { lhsEvent, rhsEvent in
      guard lhsEvent.type == rhsEvent.type,
            lhsEvent.key == rhsEvent.key,
            lhsEvent.length == rhsEvent.length else {
        return false
      }
      return decodedOutputsSemanticallyMatch(lhsEvent.valueJSON, rhsEvent.valueJSON)
    }
  default:
    return false
  }
}

private func makeTemporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func ensureReferenceWorkspace(packageRoot: URL, tsWorkspace: URL, tsModule: URL) throws {
  if !FileManager.default.fileExists(atPath: tsWorkspace.path) {
    try runProcess(
      executable: URL(fileURLWithPath: "/usr/bin/env"),
      arguments: ["git", "worktree", "add", "--detach", tsWorkspace.path, "e3458db"],
      currentDirectoryURL: packageRoot
    )
  }

  if !FileManager.default.fileExists(atPath: tsModule.path) {
    try runProcess(
      executable: URL(fileURLWithPath: "/usr/bin/env"),
      arguments: ["pnpm", "install", "--frozen-lockfile"],
      currentDirectoryURL: tsWorkspace
    )
    try runProcess(
      executable: URL(fileURLWithPath: "/usr/bin/env"),
      arguments: ["pnpm", "build"],
      currentDirectoryURL: tsWorkspace
    )
  }
}

private func ensureSwiftCLI(packageRoot: URL, swiftCLI: URL) throws {
  guard !FileManager.default.isExecutableFile(atPath: swiftCLI.path) else { return }
  try runProcess(
    executable: URL(fileURLWithPath: "/usr/bin/env"),
    arguments: ["swift", "build", "--product", "matcha"],
    currentDirectoryURL: packageRoot
  )
}

private func runProcess(executable: URL, arguments: [String], currentDirectoryURL: URL) throws {
  let process = Process()
  process.executableURL = executable
  process.arguments = arguments
  process.currentDirectoryURL = currentDirectoryURL

  let stdout = Pipe()
  let stderr = Pipe()
  process.standardOutput = stdout
  process.standardError = stderr
  try process.run()
  process.waitUntilExit()

  guard process.terminationStatus == 0 else {
    let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    throw ParityHarnessError.processFailed(arguments.joined(separator: " "), stderrText)
  }
}

private let runnerSource = """
import fs from 'node:fs/promises';
import { pathToFileURL } from 'node:url';

const [action, modulePath, corpusPath] = process.argv.slice(2);
const toon = await import(pathToFileURL(modulePath).href);
const corpus = JSON.parse(await fs.readFile(corpusPath, 'utf8'));

const splitLines = input => input.split('\\n');
const errorMessage = error => error instanceof Error ? error.message : String(error);
const normalizeEvents = events => events.map(event => {
  if (event.type === 'primitive')
    return { type: 'primitive', valueJSON: JSON.stringify(event.value) };
  if (event.type === 'key')
    return event.wasQuoted ? { type: 'key', key: event.key, wasQuoted: true } : { type: 'key', key: event.key };
  if (event.type === 'startArray')
    return { type: 'startArray', length: event.length };
  return { type: event.type };
});

async function runCase(testCase) {
  try {
    switch (action) {
      case 'encode': {
        const input = JSON.parse(testCase.inputJSON);
        return { name: testCase.name, ok: true, output: toon.encode(input, testCase.options) };
      }
      case 'decode': {
        const value = toon.decode(testCase.inputTOON, testCase.options);
        return { name: testCase.name, ok: true, output: JSON.stringify(value) };
      }
      case 'events': {
        const events = Array.from(toon.decodeStreamSync(splitLines(testCase.inputTOON), testCase.options));
        return { name: testCase.name, ok: true, events: normalizeEvents(events) };
      }
      case 'eventsAsync': {
        async function* makeSource(lines) {
          for (const line of lines)
            yield line;
        }
        const events = [];
        for await (const event of toon.decodeStream(makeSource(splitLines(testCase.inputTOON)), testCase.options))
          events.push(event);
        return { name: testCase.name, ok: true, events: normalizeEvents(events) };
      }
      default:
        throw new Error(`Unknown action: ${action}`);
    }
  }
  catch (error) {
    return { name: testCase.name, ok: false, error: errorMessage(error) };
  }
}

const results = [];
for (const testCase of corpus)
  results.push(await runCase(testCase));

process.stdout.write(JSON.stringify(results));
"""

private enum ParityHarnessError: Error {
  case invalidFixture(String)
  case processFailed(String, String)
  case nodeRunnerFailed(String)
}

private extension MatchaValue {
  var stringValue: String? {
    if case let .string(value) = self { return value }
    return nil
  }

  var intValue: Int? {
    if case let .number(value) = self { return Int(value.rawValue) }
    return nil
  }

  var boolValue: Bool? {
    if case let .bool(value) = self { return value }
    return nil
  }
}

private struct RandomMatchaGenerator {
  var state: UInt64

  mutating func makeValue(maxDepth: Int) -> MatchaValue {
    if maxDepth <= 0 {
      return makePrimitive()
    }

    switch nextInt(upperBound: 6) {
    case 0:
      return makePrimitive()
    case 1:
      return makePrimitive()
    case 2:
      return .array((0..<nextInt(upperBound: 4)).map { _ in makeValue(maxDepth: maxDepth - 1) })
    default:
      let count = nextInt(upperBound: 4)
      var usedKeys: Set<String> = []
      var entries: [MatchaObject.Entry] = []
      for _ in 0..<count {
        var key = makeKey()
        while usedKeys.contains(key) {
          key = makeKey()
        }
        usedKeys.insert(key)
        entries.append(.init(key: key, value: makeValue(maxDepth: maxDepth - 1)))
      }
      return .object(MatchaObject(entries: entries))
    }
  }

  mutating func makePrimitive() -> MatchaValue {
    switch nextInt(upperBound: 6) {
    case 0:
      return .null
    case 1:
      return .bool(nextInt(upperBound: 2) == 0)
    case 2:
      return .number(MatchaNumber(rawValue: String(nextInt(upperBound: 10_000)))!)
    case 3:
      return .number(MatchaNumber(rawValue: String(format: "%.2f", Double(nextInt(upperBound: 10_000)) / 37.0))!)
    default:
      return .string(makeString())
    }
  }

  mutating func makeKey() -> String {
    let base = ["alpha", "beta", "gamma", "delta", "omega", "path", "meta", "items"][nextInt(upperBound: 8)]
    return nextInt(upperBound: 4) == 0 ? "\(base).\(nextInt(upperBound: 5))" : "\(base)_\(nextInt(upperBound: 20))"
  }

  mutating func makeString() -> String {
    let samples = [
      "",
      "Ada",
      "swift",
      "05",
      "true",
      "contains,comma",
      "contains:colon",
      "line break\\nvalue",
      "quoted \\\"text\\\"",
      " spaced value ",
    ]
    return samples[nextInt(upperBound: samples.count)]
  }

  mutating func nextInt(upperBound: Int) -> Int {
    state = 2862933555777941757 &* state &+ 3037000493
    return Int(state % UInt64(upperBound))
  }
}

private func makeLargeSample(scale: Int) -> MatchaValue {
  let context = MatchaObject(entries: [
    .init(key: "task", value: "favorite hikes"),
    .init(key: "location", value: "Boulder"),
    .init(key: "season", value: "spring_2025"),
    .init(key: "generator", value: "swift_parity"),
  ])
  let companions = ["ana", "luis", "sam", "mei"]
  let hikes: [MatchaValue] = (0..<scale).map { index in
    let distance = MatchaNumber(rawValue: String(format: "%.1f", 5.0 + Double(index) * 0.1))!
    return .object(MatchaObject(entries: [
      .init(key: "id", value: .number(MatchaNumber(rawValue: String(index + 1))!)),
      .init(key: "name", value: .string("Trail \(index + 1)")),
      .init(key: "distanceKm", value: .number(distance)),
      .init(key: "companion", value: .string(companions[index % companions.count])),
    ]))
  }

  return .object(MatchaObject(entries: [
    .init(key: "context", value: .object(context)),
    .init(key: "friends", value: .array(companions.map(MatchaValue.string))),
    .init(key: "hikes", value: .array(hikes)),
  ]))
}
