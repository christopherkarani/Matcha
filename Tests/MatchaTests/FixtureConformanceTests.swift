import Foundation
import Testing
@testable import Matcha

private struct FixtureFile {
  struct TestCase {
    struct Options {
      var delimiter: String?
      var indent: Int?
      var strict: Bool?
      var keyFolding: String?
      var flattenDepth: Int?
      var expandPaths: String?
    }

    var name: String
    var input: MatchaValue
    var expected: MatchaValue
    var shouldError: Bool
    var options: Options
  }

  var category: String
  var description: String
  var tests: [TestCase]
}

@Test func officialDecodeFixtures() throws {
  try runFixtureDirectory(named: "decode")
}

@Test func officialEncodeFixtures() throws {
  try runFixtureDirectory(named: "encode")
}

private func runFixtureDirectory(named directory: String) throws {
  let fixtureDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Fixtures/\(directory)", isDirectory: true)
  let files = try FileManager.default.contentsOfDirectory(at: fixtureDirectory, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "json" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

  for file in files {
    let raw = try String(contentsOf: file, encoding: .utf8)
    let fixture = try parseFixtureFile(raw)

    for testCase in fixture.tests {
      do {
        try runFixture(testCase, category: fixture.category, file: file.lastPathComponent)
      } catch {
        Issue.record("\(file.lastPathComponent): \(testCase.name) -> \(error)")
      }
    }
  }
}

private func runFixture(_ testCase: FixtureFile.TestCase, category: String, file: String) throws {
    let issueComment = "\(file): \(testCase.name)"

  switch category {
  case "decode":
    let input = try #require(testCase.input.stringValue, Comment(rawValue: issueComment))
    let options = MatchaDecoderOptions(
      indent: testCase.options.indent ?? 2,
      strict: testCase.options.strict ?? true,
      expandPaths: MatchaPathExpansion(rawValue: testCase.options.expandPaths ?? "off") ?? .off
    )
    let decoder = MatchaDecoder(options: options)

    if testCase.shouldError {
      #expect(throws: Error.self, Comment(rawValue: issueComment)) {
        _ = try decoder.decode(input)
      }
      return
    }

    let actual = try decoder.decode(input)
    #expect(normalize(actual) == normalize(testCase.expected), Comment(rawValue: issueComment))
  case "encode":
    let options = MatchaEncoderOptions(
      indent: testCase.options.indent ?? 2,
      delimiter: parseDelimiter(testCase.options.delimiter),
      keyFolding: MatchaKeyFolding(rawValue: testCase.options.keyFolding ?? "off") ?? .off,
      flattenDepth: testCase.options.flattenDepth ?? .max
    )
    let encoder = MatchaEncoder(options: options)

    if testCase.shouldError {
      #expect(throws: Error.self, Comment(rawValue: issueComment)) {
        _ = try encoder.encode(testCase.input)
      }
      return
    }

    let expected = try #require(testCase.expected.stringValue, Comment(rawValue: issueComment))
    let actual = try encoder.encode(testCase.input)
    #expect(actual == expected, Comment(rawValue: issueComment))
  default:
    Issue.record("Unknown fixture category \(category)")
  }
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

private func parseFixtureFile(_ raw: String) throws -> FixtureFile {
  guard case let .object(root) = try MatchaValue.parseJSON(raw) else {
    throw FixtureError.invalidRoot
  }

  let category = try requireString(in: root, key: "category")
  let description = try requireString(in: root, key: "description")
  let testsValue = try requireValue(in: root, key: "tests")
  guard case let .array(testValues) = testsValue else {
    throw FixtureError.invalidField("tests")
  }

  let tests = try testValues.map(parseFixtureCase(_:))
  return FixtureFile(category: category, description: description, tests: tests)
}

private func parseFixtureCase(_ value: MatchaValue) throws -> FixtureFile.TestCase {
  guard case let .object(object) = value else {
    throw FixtureError.invalidField("testCase")
  }

  let optionsValue = object["options"]
  return FixtureFile.TestCase(
    name: try requireString(in: object, key: "name"),
    input: try requireValue(in: object, key: "input"),
    expected: try requireValue(in: object, key: "expected"),
    shouldError: object["shouldError"]?.boolValue ?? false,
    options: try parseOptions(optionsValue)
  )
}

private func parseOptions(_ value: MatchaValue?) throws -> FixtureFile.TestCase.Options {
  guard let value else { return .init() }
  guard case let .object(object) = value else {
    throw FixtureError.invalidField("options")
  }

  return .init(
    delimiter: object["delimiter"]?.stringValue,
    indent: object["indent"]?.intValue,
    strict: object["strict"]?.boolValue,
    keyFolding: object["keyFolding"]?.stringValue,
    flattenDepth: object["flattenDepth"]?.intValue,
    expandPaths: object["expandPaths"]?.stringValue
  )
}

private func requireValue(in object: MatchaObject, key: String) throws -> MatchaValue {
  guard let value = object[key] else {
    throw FixtureError.missingField(key)
  }
  return value
}

private func requireString(in object: MatchaObject, key: String) throws -> String {
  guard let value = object[key]?.stringValue else {
    throw FixtureError.invalidField(key)
  }
  return value
}

private enum FixtureError: Error {
  case invalidRoot
  case missingField(String)
  case invalidField(String)
}

private extension MatchaValue {
  var stringValue: String? {
    switch self {
    case let .string(value):
      return value
    default:
      return nil
    }
  }

  var intValue: Int? {
    switch self {
    case let .number(value):
      return Int(value.rawValue)
    default:
      return nil
    }
  }

  var boolValue: Bool? {
    switch self {
    case let .bool(value):
      return value
    default:
      return nil
    }
  }
}

private func normalize(_ value: MatchaValue) -> MatchaValue {
  switch value {
  case let .array(items):
    return .array(items.map(normalize))
  case let .object(object):
    return .object(MatchaObject(entries: object.entries.map { entry in
      .init(key: entry.key, value: normalize(entry.value), wasQuoted: false)
    }))
  default:
    return value
  }
}
