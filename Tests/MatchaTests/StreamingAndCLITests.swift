import Foundation
import Testing
@testable import Matcha

@Test func streamingEncodeCallbackMatchesStringEncoding() throws {
  let value: MatchaValue = .object([
    "meta": .object([
      "name": "Ada",
      "tags": ["swift", "toon"],
    ]),
    "count": 2,
  ])
  let encoder = MatchaEncoder(options: .init(keyFolding: .safe))

  let expected = try encoder.encode(value)
  var streamedLines: [String] = []
  try encoder.encodeLines(value) { line in
    streamedLines.append(line)
  }

  #expect(streamedLines.joined(separator: "\n") == expected)
}

@Test func streamingDecodeEmitsExpectedEvents() throws {
  let input = [
    "user:",
    "  name: Ada",
    "  tags[2]: swift,toon",
  ]
  let decoder = MatchaDecoder()
  var events: [MatchaEvent] = []

  try decoder.decodeEvents(input) { event in
    events.append(event)
  }

  #expect(events == [
    .startObject,
    .key("user", wasQuoted: false),
    .startObject,
    .key("name", wasQuoted: false),
    .primitive("Ada"),
    .key("tags", wasQuoted: false),
    .startArray(length: 2),
    .primitive("swift"),
    .primitive("toon"),
    .endArray,
    .endObject,
    .endObject,
  ])
}

@Test func eventStreamingRejectsPathExpansion() throws {
  let decoder = MatchaDecoder(options: .init(expandPaths: .safe))

  #expect(throws: MatchaError.self) {
    try decoder.decodeEvents(["a.b: 1"]) { _ in }
  }
}

@Test func asyncStreamingDecodeEmitsExpectedEvents() async throws {
  let decoder = MatchaDecoder()
  let input = AsyncStream<String> { continuation in
    continuation.yield("user:")
    continuation.yield("  enabled: true")
    continuation.yield("  tags[2]: swift,toon")
    continuation.finish()
  }
  let collector = AsyncEventTestCollector()

  try await decoder.decodeEvents(input) { event in
    await collector.append(event)
  }

  let events = await collector.events
  #expect(events == [
    .startObject,
    .key("user", wasQuoted: false),
    .startObject,
    .key("enabled", wasQuoted: false),
    .primitive(.bool(true)),
    .key("tags", wasQuoted: false),
    .startArray(length: 2),
    .primitive("swift"),
    .primitive("toon"),
    .endArray,
    .endObject,
    .endObject,
  ])
}

@Test func asyncStreamingRejectsPathExpansion() async throws {
  let decoder = MatchaDecoder(options: .init(expandPaths: .safe))
  let input = AsyncStream<String> { continuation in
    continuation.yield("a.b: 1")
    continuation.finish()
  }

  do {
    try await decoder.decodeEvents(input) { _ in }
    Issue.record("Expected async event streaming with path expansion to fail")
  } catch let error as MatchaError {
    #expect(error.code == .unsupportedOption)
  }
}

@Test func cliHelpPrintsUsage() throws {
  let result = try runCLI(arguments: ["--help"])

  #expect(result.exitCode == 0)
  #expect(result.stdout.contains("Usage:"))
  #expect(result.stdout.contains("--encode"))
}

@Test func cliEncodeReadsStdin() throws {
  let result = try runCLI(arguments: ["--encode"], stdin: #"{"name":"Ada","age":37}"#)

  #expect(result.exitCode == 0)
  #expect(result.stdout.contains("name: Ada"))
  #expect(result.stdout.contains("age: 37"))
}

@Test func cliStatsOutputIsExplicitlyApproximate() throws {
  let result = try runCLI(arguments: ["--encode", "--stats"], stdin: #"{"name":"Ada","age":37}"#)

  #expect(result.exitCode == 0)
  #expect(result.stderr.contains("JSON bytes:"))
  #expect(result.stderr.contains("Approx. token estimate:"))
}

@Test func cliDecodeWritesOutputFile() throws {
  let temporaryDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

  let inputURL = temporaryDirectory.appendingPathComponent("sample.toon")
  let outputURL = temporaryDirectory.appendingPathComponent("sample.json")
  try "name: Ada\nage: 37\n".write(to: inputURL, atomically: true, encoding: .utf8)

  let result = try runCLI(arguments: [inputURL.path, "--decode", "--output", outputURL.path])
  let written = try String(contentsOf: outputURL, encoding: .utf8)

  #expect(result.exitCode == 0)
  #expect(written.contains(#""name": "Ada""#))
  #expect(written.contains(#""age": 37"#))
}

@Test func cliReturnsNonZeroForInvalidInput() throws {
  let result = try runCLI(arguments: ["--decode"], stdin: "items[2]: only-one\n")

  #expect(result.exitCode != 0)
  #expect(result.stderr.contains("countMismatch"))
}

private struct CLIRunResult {
  var exitCode: Int32
  var stdout: String
  var stderr: String
}

private func runCLI(arguments: [String], stdin: String? = nil) throws -> CLIRunResult {
  let executableURL = try cliExecutableURL()

  let process = Process()
  process.executableURL = executableURL
  process.arguments = arguments
  process.currentDirectoryURL = packageRootURL()

  let stdoutPipe = Pipe()
  let stderrPipe = Pipe()
  process.standardOutput = stdoutPipe
  process.standardError = stderrPipe

  if stdin != nil {
    let stdinPipe = Pipe()
    process.standardInput = stdinPipe
    try process.run()
    if let stdin {
      stdinPipe.fileHandleForWriting.write(Data(stdin.utf8))
    }
    try stdinPipe.fileHandleForWriting.close()
  } else {
    try process.run()
  }

  process.waitUntilExit()

  let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
  let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
  return CLIRunResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
}

private func cliExecutableURL() throws -> URL {
  let executableURL = packageRootURL().appendingPathComponent(".build/debug/matcha")
  if FileManager.default.isExecutableFile(atPath: executableURL.path) {
    return executableURL
  }

  let build = Process()
  build.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  build.arguments = ["swift", "build", "--product", "matcha"]
  build.currentDirectoryURL = packageRootURL()

  let stderrPipe = Pipe()
  build.standardError = stderrPipe
  try build.run()
  build.waitUntilExit()
  if build.terminationStatus != 0 {
    let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    throw CLIHarnessError.buildFailed(stderr)
  }

  guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
    throw CLIHarnessError.missingExecutable(executableURL.path)
  }
  return executableURL
}

private func packageRootURL() -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
}

private enum CLIHarnessError: Error {
  case buildFailed(String)
  case missingExecutable(String)
}

private actor AsyncEventTestCollector {
  private(set) var events: [MatchaEvent] = []

  func append(_ event: MatchaEvent) {
    events.append(event)
  }
}
