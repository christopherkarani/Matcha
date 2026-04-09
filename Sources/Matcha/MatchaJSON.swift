import Foundation

enum MatchaJSONBridge {
  static func normalize<T: Encodable>(_ value: T) throws -> MatchaValue {
    let data = try JSONEncoder().encode(value)
    guard let json = String(data: data, encoding: .utf8) else {
      throw MatchaError(.invalidJSON, "Encoded JSON was not valid UTF-8")
    }
    return try MatchaValue.parseJSON(json)
  }

  static func decode<T: Decodable>(_ type: T.Type, from value: MatchaValue) throws -> T {
    let data = try JSONSerialization.data(withJSONObject: value.toJSONObject(), options: [])
    return try JSONDecoder().decode(type, from: data)
  }
}

public extension MatchaValue {
  static func parseJSON(_ json: String) throws -> MatchaValue {
    var parser = JSONValueParser(source: json)
    return try parser.parse()
  }

  func toJSONObject() throws -> Any {
    switch self {
    case .null:
      return NSNull()
    case let .bool(value):
      return value
    case let .string(value):
      return value
    case let .number(value):
      if value.rawValue.contains(".") || value.rawValue.contains("e") || value.rawValue.contains("E") {
        return NSDecimalNumber(string: value.rawValue)
      }
      return NSNumber(value: Int64(value.rawValue) ?? 0)
    case let .array(values):
      return try values.map { try $0.toJSONObject() }
    case let .object(object):
      return try Dictionary(uniqueKeysWithValues: object.entries.map { ($0.key, try $0.value.toJSONObject()) })
    }
  }

  func jsonString(indentedBy indent: Int = 2) -> String {
    renderJSON(self, depth: 0, indent: indent)
  }
}

private struct JSONValueParser {
  let source: String
  let characters: [Character]
  var index: Int = 0

  init(source: String) {
    self.source = source
    self.characters = Array(source)
  }

  mutating func parse() throws -> MatchaValue {
    skipWhitespace()
    let value = try parseValue()
    skipWhitespace()
    if index != characters.count {
      throw error(.invalidJSON, "Unexpected trailing characters")
    }
    return value
  }

  private mutating func parseValue() throws -> MatchaValue {
    guard index < characters.count else {
      throw error(.invalidJSON, "Unexpected end of JSON input")
    }

    switch characters[index] {
    case "{":
      return try parseObject()
    case "[":
      return try parseArray()
    case "\"":
      return .string(try parseString())
    case "t":
      try expectLiteral("true")
      return .bool(true)
    case "f":
      try expectLiteral("false")
      return .bool(false)
    case "n":
      try expectLiteral("null")
      return .null
    case "-", "0"..."9":
      return .number(try parseNumber())
    default:
      throw error(.invalidJSON, "Unexpected character '\(characters[index])'")
    }
  }

  private mutating func parseObject() throws -> MatchaValue {
    try expect("{")
    skipWhitespace()
    var entries: [MatchaObject.Entry] = []

    if consume("}") {
      return .object(MatchaObject(entries: entries))
    }

    while true {
      skipWhitespace()
      guard current == "\"" else {
        throw error(.invalidJSON, "Expected string key")
      }
      let key = try parseString()
      skipWhitespace()
      try expect(":")
      skipWhitespace()
      let value = try parseValue()
      entries.append(.init(key: key, value: value))
      skipWhitespace()
      if consume("}") {
        break
      }
      try expect(",")
      skipWhitespace()
    }

    return .object(MatchaObject(entries: entries))
  }

  private mutating func parseArray() throws -> MatchaValue {
    try expect("[")
    skipWhitespace()
    var items: [MatchaValue] = []

    if consume("]") {
      return .array(items)
    }

    while true {
      skipWhitespace()
      items.append(try parseValue())
      skipWhitespace()
      if consume("]") {
        break
      }
      try expect(",")
      skipWhitespace()
    }

    return .array(items)
  }

  private mutating func parseString() throws -> String {
    try expect("\"")
    var result = ""

    while index < characters.count {
      let character = characters[index]
      if character == "\"" {
        index += 1
        return result
      }

      if character == "\\" {
        index += 1
        guard index < characters.count else {
          throw error(.invalidEscape, "Unexpected end of escape sequence")
        }

        switch characters[index] {
        case "\"":
          result.append("\"")
        case "\\":
          result.append("\\")
        case "/":
          result.append("/")
        case "b":
          result.append("\u{08}")
        case "f":
          result.append("\u{0C}")
        case "n":
          result.append("\n")
        case "r":
          result.append("\r")
        case "t":
          result.append("\t")
        case "u":
          let unicode = try parseUnicodeEscape()
          result.append(unicode)
          continue
        default:
          throw error(.invalidEscape, "Invalid JSON escape sequence")
        }

        index += 1
        continue
      }

      result.append(character)
      index += 1
    }

    throw error(.invalidJSON, "Unterminated string literal")
  }

  private mutating func parseUnicodeEscape() throws -> Character {
    var value = ""
    for _ in 0..<4 {
      index += 1
      guard index < characters.count else {
        throw error(.invalidEscape, "Incomplete unicode escape")
      }
      let digit = characters[index]
      guard digit.isHexDigit else {
        throw error(.invalidEscape, "Invalid unicode escape digit")
      }
      value.append(digit)
    }

    guard let scalarValue = UInt32(value, radix: 16), let scalar = UnicodeScalar(scalarValue) else {
      throw error(.invalidEscape, "Invalid unicode scalar")
    }

    index += 1
    return Character(scalar)
  }

  private mutating func parseNumber() throws -> MatchaNumber {
    let start = index
    if characters[index] == "-" {
      index += 1
    }

    try consumeDigits(allowLeadingZero: true)

    if index < characters.count, characters[index] == "." {
      index += 1
      try consumeDigits(allowLeadingZero: true, requireAtLeastOne: true)
    }

    if index < characters.count, characters[index] == "e" || characters[index] == "E" {
      index += 1
      if index < characters.count, characters[index] == "+" || characters[index] == "-" {
        index += 1
      }
      try consumeDigits(allowLeadingZero: true, requireAtLeastOne: true)
    }

    let raw = String(characters[start..<index])
    guard let number = MatchaNumber(rawValue: raw) else {
      throw error(.invalidJSON, "Invalid numeric literal '\(raw)'")
    }
    return number
  }

  private mutating func consumeDigits(allowLeadingZero: Bool, requireAtLeastOne: Bool = true) throws {
    let start = index
    while index < characters.count, characters[index].isNumber {
      index += 1
    }
    if requireAtLeastOne, start == index {
      throw error(.invalidJSON, "Expected digits")
    }
    if !allowLeadingZero, index - start > 1, characters[start] == "0" {
      throw error(.invalidJSON, "Leading zeros are not allowed")
    }
  }

  private mutating func expectLiteral(_ literal: String) throws {
    for character in literal {
      try expect(character)
    }
  }

  private mutating func expect(_ character: Character) throws {
    guard index < characters.count, characters[index] == character else {
      throw error(.invalidJSON, "Expected '\(character)'")
    }
    index += 1
  }

  @discardableResult
  private mutating func consume(_ character: Character) -> Bool {
    guard index < characters.count, characters[index] == character else {
      return false
    }
    index += 1
    return true
  }

  private mutating func skipWhitespace() {
    while index < characters.count, characters[index].isWhitespace {
      index += 1
    }
  }

  private var current: Character? {
    index < characters.count ? characters[index] : nil
  }

  private func error(_ code: MatchaError.Code, _ message: String) -> MatchaError {
    MatchaError(code, message)
  }
}

private func renderJSON(_ value: MatchaValue, depth: Int, indent: Int) -> String {
  switch value {
  case .null:
    return "null"
  case let .bool(value):
    return value ? "true" : "false"
  case let .string(value):
    return "\"\(escapeJSONString(value))\""
  case let .number(value):
    return value.rawValue
  case let .array(values):
    if values.isEmpty { return "[]" }
    if indent <= 0 {
      return "[" + values.map { renderJSON($0, depth: depth + 1, indent: indent) }.joined(separator: ",") + "]"
    }
    let inner = values.map { String(repeating: " ", count: (depth + 1) * indent) + renderJSON($0, depth: depth + 1, indent: indent) }.joined(separator: ",\n")
    return "[\n\(inner)\n\(String(repeating: " ", count: depth * indent))]"
  case let .object(object):
    if object.entries.isEmpty { return "{}" }
    if indent <= 0 {
      let inner = object.entries.map { "\"\(escapeJSONString($0.key))\":" + renderJSON($0.value, depth: depth + 1, indent: indent) }.joined(separator: ",")
      return "{\(inner)}"
    }
    let inner = object.entries.map {
      String(repeating: " ", count: (depth + 1) * indent)
      + "\"\(escapeJSONString($0.key))\": "
      + renderJSON($0.value, depth: depth + 1, indent: indent)
    }.joined(separator: ",\n")
    return "{\n\(inner)\n\(String(repeating: " ", count: depth * indent))}"
  }
}

private func escapeJSONString(_ value: String) -> String {
  value
    .replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "\"", with: "\\\"")
    .replacingOccurrences(of: "\n", with: "\\n")
    .replacingOccurrences(of: "\r", with: "\\r")
    .replacingOccurrences(of: "\t", with: "\\t")
}
