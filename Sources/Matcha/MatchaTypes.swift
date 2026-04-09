import Foundation

public enum MatchaDelimiter: Character, CaseIterable, Sendable {
  case comma = ","
  case tab = "\t"
  case pipe = "|"

  public static let `default`: MatchaDelimiter = .comma
}

public enum MatchaKeyFolding: String, Sendable {
  case off
  case safe
}

public enum MatchaPathExpansion: String, Sendable {
  case off
  case safe
}

public struct MatchaEncoderOptions: Sendable, Equatable {
  public var indent: Int
  public var delimiter: MatchaDelimiter
  public var keyFolding: MatchaKeyFolding
  public var flattenDepth: Int

  public init(
    indent: Int = 2,
    delimiter: MatchaDelimiter = .default,
    keyFolding: MatchaKeyFolding = .off,
    flattenDepth: Int = .max
  ) {
    self.indent = indent
    self.delimiter = delimiter
    self.keyFolding = keyFolding
    self.flattenDepth = flattenDepth
  }
}

public struct MatchaDecoderOptions: Sendable, Equatable {
  public var indent: Int
  public var strict: Bool
  public var expandPaths: MatchaPathExpansion

  public init(
    indent: Int = 2,
    strict: Bool = true,
    expandPaths: MatchaPathExpansion = .off
  ) {
    self.indent = indent
    self.strict = strict
    self.expandPaths = expandPaths
  }
}

public struct MatchaNumber: RawRepresentable, LosslessStringConvertible, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, Sendable, Equatable, Hashable {
  public let rawValue: String

  public init?(rawValue: String) {
    let value = Self.canonicalize(rawValue)
    guard Self.isNumericLiteral(value) else {
      return nil
    }
    self.rawValue = value
  }

  public init?(_ description: String) {
    self.init(rawValue: description)
  }

  public init(integerLiteral value: Int) {
    self.rawValue = String(value)
  }

  public init(floatLiteral value: Double) {
    if value == 0 {
      self.rawValue = "0"
    } else {
      self.rawValue = MatchaNumber.canonicalize(String(value))
    }
  }

  public var description: String {
    rawValue
  }

  public static func canonicalize(_ value: String) -> String {
    canonicalizeNumericString(value)
  }

  public static func isNumericLiteral(_ value: String) -> Bool {
    let pattern = #"^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?$"#
    return value.range(of: pattern, options: .regularExpression) != nil
  }
}

public struct MatchaObject: Sendable, Equatable, ExpressibleByDictionaryLiteral {
  public struct Entry: Sendable, Equatable {
    public var key: String
    public var value: MatchaValue
    public var wasQuoted: Bool

    public init(key: String, value: MatchaValue, wasQuoted: Bool = false) {
      self.key = key
      self.value = value
      self.wasQuoted = wasQuoted
    }
  }

  public var entries: [Entry]

  public init(entries: [Entry] = []) {
    self.entries = entries
  }

  public init(dictionaryLiteral elements: (String, MatchaValue)...) {
    self.entries = elements.map { Entry(key: $0.0, value: $0.1) }
  }

  public var isEmpty: Bool {
    entries.isEmpty
  }

  public var keys: [String] {
    entries.map(\.key)
  }

  public subscript(_ key: String) -> MatchaValue? {
    get { entries.last(where: { $0.key == key })?.value }
    set {
      if let index = entries.lastIndex(where: { $0.key == key }) {
        if let newValue {
          entries[index].value = newValue
        } else {
          entries.remove(at: index)
        }
      } else if let newValue {
        entries.append(.init(key: key, value: newValue))
      }
    }
  }
}

public enum MatchaValue: Sendable, Equatable {
  case object(MatchaObject)
  case array([MatchaValue])
  case string(String)
  case number(MatchaNumber)
  case bool(Bool)
  case null

  public var isPrimitive: Bool {
    switch self {
    case .object, .array:
      return false
    case .string, .number, .bool, .null:
      return true
    }
  }
}

public enum MatchaEvent: Sendable, Equatable {
  case startObject
  case endObject
  case startArray(length: Int)
  case endArray
  case key(String, wasQuoted: Bool)
  case primitive(MatchaValue)
}

public struct MatchaDiagnostic: Sendable, Equatable {
  public var line: Int?
  public var column: Int?
  public var context: String?

  public init(line: Int? = nil, column: Int? = nil, context: String? = nil) {
    self.line = line
    self.column = column
    self.context = context
  }
}

public struct MatchaError: Error, Sendable, Equatable, CustomStringConvertible {
  public enum Code: String, Sendable {
    case invalidIndent
    case invalidSyntax
    case invalidEscape
    case missingColon
    case invalidHeader
    case countMismatch
    case pathExpansionConflict
    case unsupportedOption
    case invalidArgument
    case invalidJSON
  }

  public var code: Code
  public var message: String
  public var diagnostic: MatchaDiagnostic

  public init(_ code: Code, _ message: String, diagnostic: MatchaDiagnostic = .init()) {
    self.code = code
    self.message = message
    self.diagnostic = diagnostic
  }

  public var description: String {
    var prefix = code.rawValue
    if let line = diagnostic.line {
      prefix += " at line \(line)"
      if let column = diagnostic.column {
        prefix += ":\(column)"
      }
    }
    return "\(prefix): \(message)"
  }
}

extension MatchaValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, ExpressibleByNilLiteral, ExpressibleByArrayLiteral {
  public init(stringLiteral value: StringLiteralType) {
    self = .string(value)
  }

  public init(integerLiteral value: Int) {
    self = .number(MatchaNumber(integerLiteral: value))
  }

  public init(floatLiteral value: Double) {
    self = .number(MatchaNumber(floatLiteral: value))
  }

  public init(booleanLiteral value: BooleanLiteralType) {
    self = .bool(value)
  }

  public init(nilLiteral: ()) {
    self = .null
  }

  public init(arrayLiteral elements: MatchaValue...) {
    self = .array(elements)
  }
}

extension MatchaValue {
  public static func from(any value: Any) -> MatchaValue {
    switch value {
    case let object as MatchaValue:
      return object
    case is NSNull:
      return .null
    case let value as String:
      return .string(value)
    case let value as NSNumber:
      if CFGetTypeID(value) == CFBooleanGetTypeID() {
        return .bool(value.boolValue)
      }
      return .number(MatchaNumber(rawValue: canonicalJSONStringNumber(value)) ?? MatchaNumber(integerLiteral: value.intValue))
    case let value as [Any]:
      return .array(value.map(Self.from(any:)))
    case let value as [String: Any]:
      let ordered = value.map { MatchaObject.Entry(key: $0.key, value: Self.from(any: $0.value)) }
      return .object(MatchaObject(entries: ordered))
    default:
      return .null
    }
  }
}

private func canonicalJSONStringNumber(_ number: NSNumber) -> String {
  if number.doubleValue == 0 {
    return "0"
  }
  return number.stringValue
}

func canonicalizeNumericString(_ rawValue: String) -> String {
  let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return trimmed }

  var sign = ""
  var raw = trimmed
  if raw.first == "-" {
    sign = "-"
    raw.removeFirst()
  } else if raw.first == "+" {
    raw.removeFirst()
  }

  let exponentParts = raw.split(separator: "e", maxSplits: 1, omittingEmptySubsequences: false)
  let exponentAwareParts = exponentParts.count == 1 ? raw.split(separator: "E", maxSplits: 1, omittingEmptySubsequences: false) : exponentParts

  let mantissa = String(exponentAwareParts[0])
  let exponent = exponentAwareParts.count == 2 ? Int(exponentAwareParts[1]) ?? 0 : 0

  let mantissaParts = mantissa.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
  let integerPart = String(mantissaParts[0])
  let fractionPart = mantissaParts.count == 2 ? String(mantissaParts[1]) : ""
  let digits = integerPart + fractionPart
  let decimalIndex = integerPart.count
  let shiftedIndex = decimalIndex + exponent

  let expanded: String
  if exponentAwareParts.count == 1 {
    expanded = mantissa
  } else if shiftedIndex <= 0 {
    expanded = "0." + String(repeating: "0", count: -shiftedIndex) + digits
  } else if shiftedIndex >= digits.count {
    expanded = digits + String(repeating: "0", count: shiftedIndex - digits.count)
  } else {
    let splitIndex = digits.index(digits.startIndex, offsetBy: shiftedIndex)
    expanded = String(digits[..<splitIndex]) + "." + String(digits[splitIndex...])
  }

  var normalized = expanded
  if normalized.contains(".") {
    while normalized.last == "0" {
      normalized.removeLast()
    }
    if normalized.last == "." {
      normalized.removeLast()
    }
  }

  if normalized.contains(".") {
    let parts = normalized.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
    var integer = String(parts[0])
    let fraction = String(parts[1])
    while integer.count > 1, integer.first == "0" {
      integer.removeFirst()
    }
    normalized = integer.isEmpty ? "0.\(fraction)" : "\(integer).\(fraction)"
  } else {
    while normalized.count > 1, normalized.first == "0" {
      normalized.removeFirst()
    }
  }

  if normalized.isEmpty || normalized == "0" {
    return "0"
  }

  return sign + normalized
}
