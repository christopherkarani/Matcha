import Foundation

public func decodableFromMatchaValue<T: Decodable>(_ type: T.Type, from value: MatchaValue) throws -> T {
  let decoder = _MatchaValueDecoder(value: value, codingPath: [])
  return try T(from: decoder)
}

private final class _MatchaValueDecoder: Decoder {
  let value: MatchaValue
  let codingPath: [any CodingKey]
  var userInfo: [CodingUserInfoKey: Any] { [:] }

  init(value: MatchaValue, codingPath: [any CodingKey]) {
    self.value = value
    self.codingPath = codingPath
  }

  func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
    guard case let .object(object) = value else {
      throw DecodingError.typeMismatch(
        MatchaObject.self,
        .init(codingPath: codingPath, debugDescription: "Expected object but found \(typeDescription(value))")
      )
    }
    return KeyedDecodingContainer(_MatchaKeyedDecodingContainer<Key>(object: object, codingPath: codingPath))
  }

  func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
    guard case let .array(array) = value else {
      throw DecodingError.typeMismatch(
        [MatchaValue].self,
        .init(codingPath: codingPath, debugDescription: "Expected array but found \(typeDescription(value))")
      )
    }
    return _MatchaUnkeyedDecodingContainer(array: array, codingPath: codingPath)
  }

  func singleValueContainer() throws -> any SingleValueDecodingContainer {
    _MatchaSingleValueDecodingContainer(value: value, codingPath: codingPath)
  }
}

// MARK: - Keyed Container

private struct _MatchaKeyedDecodingContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
  let object: MatchaObject
  let codingPath: [any CodingKey]

  var allKeys: [Key] {
    object.entries.compactMap { Key(stringValue: $0.key) }
  }

  func contains(_ key: Key) -> Bool {
    object[key.stringValue] != nil
  }

  private func value(for key: Key) throws -> MatchaValue {
    guard let value = object[key.stringValue] else {
      throw DecodingError.keyNotFound(
        key,
        .init(codingPath: codingPath, debugDescription: "No value associated with key '\(key.stringValue)'")
      )
    }
    return value
  }

  func decodeNil(forKey key: Key) throws -> Bool {
    guard let val = object[key.stringValue] else { return true }
    return val == .null
  }

  func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
    try decodePrimitive(forKey: key)
  }

  func decode(_ type: String.Type, forKey key: Key) throws -> String {
    try decodePrimitive(forKey: key)
  }

  func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
    try decodePrimitive(forKey: key)
  }

  func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
    try decodePrimitive(forKey: key)
  }

  func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
    try decodePrimitive(forKey: key)
  }

  func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 {
    try decodePrimitive(forKey: key)
  }

  func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 {
    try decodePrimitive(forKey: key)
  }

  func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 {
    try decodePrimitive(forKey: key)
  }

  func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 {
    try decodePrimitive(forKey: key)
  }

  func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt {
    try decodePrimitive(forKey: key)
  }

  func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 {
    try decodePrimitive(forKey: key)
  }

  func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 {
    try decodePrimitive(forKey: key)
  }

  func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 {
    try decodePrimitive(forKey: key)
  }

  func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 {
    try decodePrimitive(forKey: key)
  }

  func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
    let val = try value(for: key)
    let decoder = _MatchaValueDecoder(value: val, codingPath: codingPath + [key])
    return try T(from: decoder)
  }

  func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
    let val = try value(for: key)
    let decoder = _MatchaValueDecoder(value: val, codingPath: codingPath + [key])
    return try decoder.container(keyedBy: type)
  }

  func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
    let val = try value(for: key)
    let decoder = _MatchaValueDecoder(value: val, codingPath: codingPath + [key])
    return try decoder.unkeyedContainer()
  }

  func superDecoder() throws -> any Decoder {
    let superKey = _MatchaSuperKey()
    let val = object[superKey.stringValue] ?? .null
    return _MatchaValueDecoder(value: val, codingPath: codingPath + [superKey])
  }

  func superDecoder(forKey key: Key) throws -> any Decoder {
    let val = try value(for: key)
    return _MatchaValueDecoder(value: val, codingPath: codingPath + [key])
  }

  private func decodePrimitive<P: _MatchaPrimitive>(forKey key: Key) throws -> P {
    let val = try value(for: key)
    let path = codingPath + [key]
    return try P._decode(from: val, codingPath: path)
  }
}

// MARK: - Unkeyed Container

private struct _MatchaUnkeyedDecodingContainer: UnkeyedDecodingContainer {
  let array: [MatchaValue]
  let codingPath: [any CodingKey]
  private(set) var currentIndex: Int = 0

  var count: Int? { array.count }
  var isAtEnd: Bool { currentIndex >= array.count }

  private var currentKey: CodingKey { _MatchaIndexKey(intValue: currentIndex) }

  private mutating func nextValue() throws -> MatchaValue {
    guard !isAtEnd else {
      throw DecodingError.valueNotFound(
        MatchaValue.self,
        .init(codingPath: codingPath + [currentKey], debugDescription: "Unkeyed container is at end (index \(currentIndex) of \(array.count))")
      )
    }
    let val = array[currentIndex]
    currentIndex += 1
    return val
  }

  mutating func decodeNil() throws -> Bool {
    guard !isAtEnd else { return false }
    if array[currentIndex] == .null {
      currentIndex += 1
      return true
    }
    return false
  }

  mutating func decode(_ type: Bool.Type) throws -> Bool { try decodePrimitive() }
  mutating func decode(_ type: String.Type) throws -> String { try decodePrimitive() }
  mutating func decode(_ type: Double.Type) throws -> Double { try decodePrimitive() }
  mutating func decode(_ type: Float.Type) throws -> Float { try decodePrimitive() }
  mutating func decode(_ type: Int.Type) throws -> Int { try decodePrimitive() }
  mutating func decode(_ type: Int8.Type) throws -> Int8 { try decodePrimitive() }
  mutating func decode(_ type: Int16.Type) throws -> Int16 { try decodePrimitive() }
  mutating func decode(_ type: Int32.Type) throws -> Int32 { try decodePrimitive() }
  mutating func decode(_ type: Int64.Type) throws -> Int64 { try decodePrimitive() }
  mutating func decode(_ type: UInt.Type) throws -> UInt { try decodePrimitive() }
  mutating func decode(_ type: UInt8.Type) throws -> UInt8 { try decodePrimitive() }
  mutating func decode(_ type: UInt16.Type) throws -> UInt16 { try decodePrimitive() }
  mutating func decode(_ type: UInt32.Type) throws -> UInt32 { try decodePrimitive() }
  mutating func decode(_ type: UInt64.Type) throws -> UInt64 { try decodePrimitive() }

  mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
    let val = try nextValue()
    let decoder = _MatchaValueDecoder(value: val, codingPath: codingPath + [_MatchaIndexKey(intValue: currentIndex - 1)])
    return try T(from: decoder)
  }

  mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
    let val = try nextValue()
    let decoder = _MatchaValueDecoder(value: val, codingPath: codingPath + [_MatchaIndexKey(intValue: currentIndex - 1)])
    return try decoder.container(keyedBy: type)
  }

  mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
    let val = try nextValue()
    let decoder = _MatchaValueDecoder(value: val, codingPath: codingPath + [_MatchaIndexKey(intValue: currentIndex - 1)])
    return try decoder.unkeyedContainer()
  }

  mutating func superDecoder() throws -> any Decoder {
    let val = try nextValue()
    return _MatchaValueDecoder(value: val, codingPath: codingPath + [_MatchaIndexKey(intValue: currentIndex - 1)])
  }

  private mutating func decodePrimitive<P: _MatchaPrimitive>() throws -> P {
    let index = currentIndex
    let val = try nextValue()
    return try P._decode(from: val, codingPath: codingPath + [_MatchaIndexKey(intValue: index)])
  }
}

// MARK: - Single Value Container

private struct _MatchaSingleValueDecodingContainer: SingleValueDecodingContainer {
  let value: MatchaValue
  let codingPath: [any CodingKey]

  func decodeNil() -> Bool { value == .null }
  func decode(_ type: Bool.Type) throws -> Bool { try Bool._decode(from: value, codingPath: codingPath) }
  func decode(_ type: String.Type) throws -> String { try String._decode(from: value, codingPath: codingPath) }
  func decode(_ type: Double.Type) throws -> Double { try Double._decode(from: value, codingPath: codingPath) }
  func decode(_ type: Float.Type) throws -> Float { try Float._decode(from: value, codingPath: codingPath) }
  func decode(_ type: Int.Type) throws -> Int { try Int._decode(from: value, codingPath: codingPath) }
  func decode(_ type: Int8.Type) throws -> Int8 { try Int8._decode(from: value, codingPath: codingPath) }
  func decode(_ type: Int16.Type) throws -> Int16 { try Int16._decode(from: value, codingPath: codingPath) }
  func decode(_ type: Int32.Type) throws -> Int32 { try Int32._decode(from: value, codingPath: codingPath) }
  func decode(_ type: Int64.Type) throws -> Int64 { try Int64._decode(from: value, codingPath: codingPath) }
  func decode(_ type: UInt.Type) throws -> UInt { try UInt._decode(from: value, codingPath: codingPath) }
  func decode(_ type: UInt8.Type) throws -> UInt8 { try UInt8._decode(from: value, codingPath: codingPath) }
  func decode(_ type: UInt16.Type) throws -> UInt16 { try UInt16._decode(from: value, codingPath: codingPath) }
  func decode(_ type: UInt32.Type) throws -> UInt32 { try UInt32._decode(from: value, codingPath: codingPath) }
  func decode(_ type: UInt64.Type) throws -> UInt64 { try UInt64._decode(from: value, codingPath: codingPath) }

  func decode<T: Decodable>(_ type: T.Type) throws -> T {
    let decoder = _MatchaValueDecoder(value: value, codingPath: codingPath)
    return try T(from: decoder)
  }
}

// MARK: - Index Key

private struct _MatchaIndexKey: CodingKey {
  let intValue: Int?
  let stringValue: String

  init(intValue: Int) {
    self.intValue = intValue
    self.stringValue = "Index \(intValue)"
  }

  init?(stringValue: String) {
    guard let int = Int(stringValue) else { return nil }
    self.intValue = int
    self.stringValue = stringValue
  }
}

private struct _MatchaSuperKey: CodingKey {
  var stringValue: String { "super" }
  var intValue: Int? { nil }
  init() {}
  init?(stringValue: String) { self.init() }
  init?(intValue: Int) { nil }
}

// MARK: - Primitive Decoding Protocol

private protocol _MatchaPrimitive {
  static func _decode(from value: MatchaValue, codingPath: [any CodingKey]) throws -> Self
}

extension Bool: _MatchaPrimitive {
  fileprivate static func _decode(from value: MatchaValue, codingPath: [any CodingKey]) throws -> Bool {
    guard case let .bool(b) = value else {
      throw DecodingError.typeMismatch(Bool.self, .init(codingPath: codingPath, debugDescription: "Expected bool but found \(typeDescription(value))"))
    }
    return b
  }
}

extension String: _MatchaPrimitive {
  fileprivate static func _decode(from value: MatchaValue, codingPath: [any CodingKey]) throws -> String {
    guard case let .string(s) = value else {
      throw DecodingError.typeMismatch(String.self, .init(codingPath: codingPath, debugDescription: "Expected string but found \(typeDescription(value))"))
    }
    return s
  }
}

extension Double: _MatchaPrimitive {
  fileprivate static func _decode(from value: MatchaValue, codingPath: [any CodingKey]) throws -> Double {
    try decodeFloatingPoint(from: value, codingPath: codingPath)
  }
}

extension Float: _MatchaPrimitive {
  fileprivate static func _decode(from value: MatchaValue, codingPath: [any CodingKey]) throws -> Float {
    try decodeFloatingPoint(from: value, codingPath: codingPath)
  }
}

extension Int: _MatchaPrimitive {
  fileprivate static func _decode(from value: MatchaValue, codingPath: [any CodingKey]) throws -> Int {
    try decodeFixedWidthInteger(from: value, codingPath: codingPath)
  }
}

extension Int8: _MatchaPrimitive {
  fileprivate static func _decode(from value: MatchaValue, codingPath: [any CodingKey]) throws -> Int8 {
    try decodeFixedWidthInteger(from: value, codingPath: codingPath)
  }
}

extension Int16: _MatchaPrimitive {
  fileprivate static func _decode(from value: MatchaValue, codingPath: [any CodingKey]) throws -> Int16 {
    try decodeFixedWidthInteger(from: value, codingPath: codingPath)
  }
}

extension Int32: _MatchaPrimitive {
  fileprivate static func _decode(from value: MatchaValue, codingPath: [any CodingKey]) throws -> Int32 {
    try decodeFixedWidthInteger(from: value, codingPath: codingPath)
  }
}

extension Int64: _MatchaPrimitive {
  fileprivate static func _decode(from value: MatchaValue, codingPath: [any CodingKey]) throws -> Int64 {
    try decodeFixedWidthInteger(from: value, codingPath: codingPath)
  }
}

extension UInt: _MatchaPrimitive {
  fileprivate static func _decode(from value: MatchaValue, codingPath: [any CodingKey]) throws -> UInt {
    try decodeFixedWidthInteger(from: value, codingPath: codingPath)
  }
}

extension UInt8: _MatchaPrimitive {
  fileprivate static func _decode(from value: MatchaValue, codingPath: [any CodingKey]) throws -> UInt8 {
    try decodeFixedWidthInteger(from: value, codingPath: codingPath)
  }
}

extension UInt16: _MatchaPrimitive {
  fileprivate static func _decode(from value: MatchaValue, codingPath: [any CodingKey]) throws -> UInt16 {
    try decodeFixedWidthInteger(from: value, codingPath: codingPath)
  }
}

extension UInt32: _MatchaPrimitive {
  fileprivate static func _decode(from value: MatchaValue, codingPath: [any CodingKey]) throws -> UInt32 {
    try decodeFixedWidthInteger(from: value, codingPath: codingPath)
  }
}

extension UInt64: _MatchaPrimitive {
  fileprivate static func _decode(from value: MatchaValue, codingPath: [any CodingKey]) throws -> UInt64 {
    try decodeFixedWidthInteger(from: value, codingPath: codingPath)
  }
}

// MARK: - Number Parsing Helpers

private func decodeFixedWidthInteger<T: FixedWidthInteger>(from value: MatchaValue, codingPath: [any CodingKey]) throws -> T {
  guard case let .number(number) = value else {
    throw DecodingError.typeMismatch(T.self, .init(codingPath: codingPath, debugDescription: "Expected number but found \(typeDescription(value))"))
  }
  guard let parsed = T(number.rawValue) else {
    throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "Cannot parse '\(number.rawValue)' as \(T.self)"))
  }
  return parsed
}

private func decodeFloatingPoint<T: LosslessStringConvertible & BinaryFloatingPoint>(from value: MatchaValue, codingPath: [any CodingKey]) throws -> T {
  guard case let .number(number) = value else {
    throw DecodingError.typeMismatch(T.self, .init(codingPath: codingPath, debugDescription: "Expected number but found \(typeDescription(value))"))
  }
  guard let parsed = T(number.rawValue) else {
    throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "Cannot parse '\(number.rawValue)' as \(T.self)"))
  }
  return parsed
}

private func typeDescription(_ value: MatchaValue) -> String {
  switch value {
  case .object: "object"
  case .array: "array"
  case .string: "string"
  case .number: "number"
  case .bool: "bool"
  case .null: "null"
  }
}
