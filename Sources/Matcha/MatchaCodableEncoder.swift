import Foundation

public func matchaValueFromEncodable<T: Encodable>(_ value: T) throws -> MatchaValue {
  let storage = _Storage()
  let encoder = _MatchaValueEncoder(storage: storage, codingPath: [])
  try value.encode(to: encoder)
  return storage.resolve()
}

// MARK: - Storage

// These classes are only used within the synchronous scope of matchaValueFromEncodable
// and never cross isolation boundaries.
private final class _Storage: @unchecked Sendable {
  enum Backing {
    case value(MatchaValue)
    case keyed(_KeyedBacking)
    case unkeyed(_UnkeyedBacking)
  }

  var backing: Backing = .value(.null)

  func resolve() -> MatchaValue {
    switch backing {
    case let .value(v):
      return v
    case let .keyed(k):
      return k.resolve()
    case let .unkeyed(u):
      return u.resolve()
    }
  }
}

private final class _KeyedBacking: @unchecked Sendable {
  private var entries: [MatchaObject.Entry] = []
  private var pendingStorages: [(index: Int, storage: _Storage)] = []

  func appendValue(key: String, value: MatchaValue) {
    entries.append(.init(key: key, value: value))
  }

  func appendStorage(key: String, storage: _Storage) {
    let idx = entries.count
    entries.append(.init(key: key, value: .null))
    pendingStorages.append((idx, storage))
  }

  func resolve() -> MatchaValue {
    for (index, storage) in pendingStorages {
      entries[index].value = storage.resolve()
    }
    return .object(MatchaObject(entries: entries))
  }
}

private final class _UnkeyedBacking: @unchecked Sendable {
  private var values: [MatchaValue] = []
  private var pendingStorages: [(index: Int, storage: _Storage)] = []

  var count: Int { values.count }

  func appendValue(_ value: MatchaValue) {
    values.append(value)
  }

  func appendStorage(_ storage: _Storage) {
    let idx = values.count
    values.append(.null)
    pendingStorages.append((idx, storage))
  }

  func resolve() -> MatchaValue {
    for (index, storage) in pendingStorages {
      values[index] = storage.resolve()
    }
    return .array(values)
  }
}

// MARK: - Encoder

private final class _MatchaValueEncoder: Encoder {
  let storage: _Storage
  let codingPath: [any CodingKey]
  let userInfo: [CodingUserInfoKey: Any] = [:]

  init(storage: _Storage, codingPath: [any CodingKey]) {
    self.storage = storage
    self.codingPath = codingPath
  }

  func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
    let keyed = _KeyedBacking()
    storage.backing = .keyed(keyed)
    return KeyedEncodingContainer(
      _MatchaKeyedEncodingContainer<Key>(keyed: keyed, codingPath: codingPath)
    )
  }

  func unkeyedContainer() -> any UnkeyedEncodingContainer {
    let unkeyed = _UnkeyedBacking()
    storage.backing = .unkeyed(unkeyed)
    return _MatchaUnkeyedEncodingContainer(unkeyed: unkeyed, codingPath: codingPath)
  }

  func singleValueContainer() -> any SingleValueEncodingContainer {
    _MatchaSingleValueEncodingContainer(storage: storage, codingPath: codingPath)
  }
}

// MARK: - Keyed Container

private struct _MatchaKeyedEncodingContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
  let keyed: _KeyedBacking
  let codingPath: [any CodingKey]

  mutating func encodeNil(forKey key: Key) throws {
    keyed.appendValue(key: key.stringValue, value: .null)
  }

  mutating func encode(_ value: Bool, forKey key: Key) throws {
    keyed.appendValue(key: key.stringValue, value: .bool(value))
  }

  mutating func encode(_ value: String, forKey key: Key) throws {
    keyed.appendValue(key: key.stringValue, value: .string(value))
  }

  mutating func encode(_ value: Int, forKey key: Key) throws {
    keyed.appendValue(key: key.stringValue, value: .number(MatchaNumber(integerLiteral: value)))
  }

  mutating func encode(_ value: Int8, forKey key: Key) throws {
    keyed.appendValue(key: key.stringValue, value: .number(MatchaNumber(rawValue: String(value))!))
  }

  mutating func encode(_ value: Int16, forKey key: Key) throws {
    keyed.appendValue(key: key.stringValue, value: .number(MatchaNumber(rawValue: String(value))!))
  }

  mutating func encode(_ value: Int32, forKey key: Key) throws {
    keyed.appendValue(key: key.stringValue, value: .number(MatchaNumber(rawValue: String(value))!))
  }

  mutating func encode(_ value: Int64, forKey key: Key) throws {
    keyed.appendValue(key: key.stringValue, value: .number(MatchaNumber(rawValue: String(value))!))
  }

  mutating func encode(_ value: UInt, forKey key: Key) throws {
    keyed.appendValue(key: key.stringValue, value: .number(MatchaNumber(rawValue: String(value))!))
  }

  mutating func encode(_ value: UInt8, forKey key: Key) throws {
    keyed.appendValue(key: key.stringValue, value: .number(MatchaNumber(rawValue: String(value))!))
  }

  mutating func encode(_ value: UInt16, forKey key: Key) throws {
    keyed.appendValue(key: key.stringValue, value: .number(MatchaNumber(rawValue: String(value))!))
  }

  mutating func encode(_ value: UInt32, forKey key: Key) throws {
    keyed.appendValue(key: key.stringValue, value: .number(MatchaNumber(rawValue: String(value))!))
  }

  mutating func encode(_ value: UInt64, forKey key: Key) throws {
    keyed.appendValue(key: key.stringValue, value: .number(MatchaNumber(rawValue: String(value))!))
  }

  mutating func encode(_ value: Float, forKey key: Key) throws {
    keyed.appendValue(key: key.stringValue, value: .number(MatchaNumber(floatLiteral: Double(value))))
  }

  mutating func encode(_ value: Double, forKey key: Key) throws {
    keyed.appendValue(key: key.stringValue, value: .number(MatchaNumber(floatLiteral: value)))
  }

  mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
    let childStorage = _Storage()
    if !_tryEncodeSpecialType(value, into: childStorage) {
      let childEncoder = _MatchaValueEncoder(storage: childStorage, codingPath: codingPath + [key])
      try value.encode(to: childEncoder)
    }
    keyed.appendStorage(key: key.stringValue, storage: childStorage)
  }

  mutating func nestedContainer<NestedKey: CodingKey>(
    keyedBy keyType: NestedKey.Type,
    forKey key: Key
  ) -> KeyedEncodingContainer<NestedKey> {
    let childStorage = _Storage()
    let nestedKeyed = _KeyedBacking()
    childStorage.backing = .keyed(nestedKeyed)
    keyed.appendStorage(key: key.stringValue, storage: childStorage)
    return KeyedEncodingContainer(
      _MatchaKeyedEncodingContainer<NestedKey>(keyed: nestedKeyed, codingPath: codingPath + [key])
    )
  }

  mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
    let childStorage = _Storage()
    let nestedUnkeyed = _UnkeyedBacking()
    childStorage.backing = .unkeyed(nestedUnkeyed)
    keyed.appendStorage(key: key.stringValue, storage: childStorage)
    return _MatchaUnkeyedEncodingContainer(unkeyed: nestedUnkeyed, codingPath: codingPath + [key])
  }

  mutating func superEncoder() -> any Encoder {
    let childStorage = _Storage()
    keyed.appendStorage(key: "super", storage: childStorage)
    return _MatchaValueEncoder(storage: childStorage, codingPath: codingPath)
  }

  mutating func superEncoder(forKey key: Key) -> any Encoder {
    let childStorage = _Storage()
    keyed.appendStorage(key: key.stringValue, storage: childStorage)
    return _MatchaValueEncoder(storage: childStorage, codingPath: codingPath + [key])
  }
}

// MARK: - Unkeyed Container

private struct _MatchaUnkeyedEncodingContainer: UnkeyedEncodingContainer {
  let unkeyed: _UnkeyedBacking
  let codingPath: [any CodingKey]

  var count: Int { unkeyed.count }

  private var currentCodingPath: [any CodingKey] {
    codingPath + [_MatchaIndexKey(intValue: count)]
  }

  mutating func encodeNil() throws { unkeyed.appendValue(.null) }
  mutating func encode(_ value: Bool) throws { unkeyed.appendValue(.bool(value)) }
  mutating func encode(_ value: String) throws { unkeyed.appendValue(.string(value)) }
  mutating func encode(_ value: Int) throws { unkeyed.appendValue(.number(MatchaNumber(integerLiteral: value))) }
  mutating func encode(_ value: Int8) throws { unkeyed.appendValue(.number(MatchaNumber(rawValue: String(value))!)) }
  mutating func encode(_ value: Int16) throws { unkeyed.appendValue(.number(MatchaNumber(rawValue: String(value))!)) }
  mutating func encode(_ value: Int32) throws { unkeyed.appendValue(.number(MatchaNumber(rawValue: String(value))!)) }
  mutating func encode(_ value: Int64) throws { unkeyed.appendValue(.number(MatchaNumber(rawValue: String(value))!)) }
  mutating func encode(_ value: UInt) throws { unkeyed.appendValue(.number(MatchaNumber(rawValue: String(value))!)) }
  mutating func encode(_ value: UInt8) throws { unkeyed.appendValue(.number(MatchaNumber(rawValue: String(value))!)) }
  mutating func encode(_ value: UInt16) throws { unkeyed.appendValue(.number(MatchaNumber(rawValue: String(value))!)) }
  mutating func encode(_ value: UInt32) throws { unkeyed.appendValue(.number(MatchaNumber(rawValue: String(value))!)) }
  mutating func encode(_ value: UInt64) throws { unkeyed.appendValue(.number(MatchaNumber(rawValue: String(value))!)) }
  mutating func encode(_ value: Float) throws { unkeyed.appendValue(.number(MatchaNumber(floatLiteral: Double(value)))) }
  mutating func encode(_ value: Double) throws { unkeyed.appendValue(.number(MatchaNumber(floatLiteral: value))) }

  mutating func encode<T: Encodable>(_ value: T) throws {
    let childStorage = _Storage()
    if !_tryEncodeSpecialType(value, into: childStorage) {
      let childEncoder = _MatchaValueEncoder(storage: childStorage, codingPath: currentCodingPath)
      try value.encode(to: childEncoder)
    }
    unkeyed.appendStorage(childStorage)
  }

  mutating func nestedContainer<NestedKey: CodingKey>(
    keyedBy keyType: NestedKey.Type
  ) -> KeyedEncodingContainer<NestedKey> {
    let childStorage = _Storage()
    let nestedKeyed = _KeyedBacking()
    childStorage.backing = .keyed(nestedKeyed)
    unkeyed.appendStorage(childStorage)
    return KeyedEncodingContainer(
      _MatchaKeyedEncodingContainer<NestedKey>(keyed: nestedKeyed, codingPath: currentCodingPath)
    )
  }

  mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
    let childStorage = _Storage()
    let nestedUnkeyed = _UnkeyedBacking()
    childStorage.backing = .unkeyed(nestedUnkeyed)
    unkeyed.appendStorage(childStorage)
    return _MatchaUnkeyedEncodingContainer(unkeyed: nestedUnkeyed, codingPath: currentCodingPath)
  }

  mutating func superEncoder() -> any Encoder {
    let childStorage = _Storage()
    unkeyed.appendStorage(childStorage)
    return _MatchaValueEncoder(storage: childStorage, codingPath: codingPath)
  }
}

// MARK: - Single Value Container

private struct _MatchaSingleValueEncodingContainer: SingleValueEncodingContainer {
  let storage: _Storage
  let codingPath: [any CodingKey]

  mutating func encodeNil() throws {
    storage.backing = .value(.null)
  }

  mutating func encode(_ value: Bool) throws {
    storage.backing = .value(.bool(value))
  }

  mutating func encode(_ value: String) throws {
    storage.backing = .value(.string(value))
  }

  mutating func encode(_ value: Int) throws {
    storage.backing = .value(.number(MatchaNumber(integerLiteral: value)))
  }

  mutating func encode(_ value: Int8) throws {
    storage.backing = .value(.number(MatchaNumber(rawValue: String(value))!))
  }

  mutating func encode(_ value: Int16) throws {
    storage.backing = .value(.number(MatchaNumber(rawValue: String(value))!))
  }

  mutating func encode(_ value: Int32) throws {
    storage.backing = .value(.number(MatchaNumber(rawValue: String(value))!))
  }

  mutating func encode(_ value: Int64) throws {
    storage.backing = .value(.number(MatchaNumber(rawValue: String(value))!))
  }

  mutating func encode(_ value: UInt) throws {
    storage.backing = .value(.number(MatchaNumber(rawValue: String(value))!))
  }

  mutating func encode(_ value: UInt8) throws {
    storage.backing = .value(.number(MatchaNumber(rawValue: String(value))!))
  }

  mutating func encode(_ value: UInt16) throws {
    storage.backing = .value(.number(MatchaNumber(rawValue: String(value))!))
  }

  mutating func encode(_ value: UInt32) throws {
    storage.backing = .value(.number(MatchaNumber(rawValue: String(value))!))
  }

  mutating func encode(_ value: UInt64) throws {
    storage.backing = .value(.number(MatchaNumber(rawValue: String(value))!))
  }

  mutating func encode(_ value: Float) throws {
    storage.backing = .value(.number(MatchaNumber(floatLiteral: Double(value))))
  }

  mutating func encode(_ value: Double) throws {
    storage.backing = .value(.number(MatchaNumber(floatLiteral: value)))
  }

  mutating func encode<T: Encodable>(_ value: T) throws {
    if !_tryEncodeSpecialType(value, into: storage) {
      let encoder = _MatchaValueEncoder(storage: storage, codingPath: codingPath)
      try value.encode(to: encoder)
    }
  }
}

// MARK: - Helpers

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

private func _tryEncodeSpecialType<T: Encodable>(_ value: T, into storage: _Storage) -> Bool {
  // Date uses timeIntervalSinceReferenceDate (matching JSONEncoder's .deferredToDate default).
  // Date.init(from:) decodes via singleValueContainer().decode(Double.self), so no
  // special-casing is needed on the decode side.
  if let date = value as? Date {
    storage.backing = .value(.number(MatchaNumber(floatLiteral: date.timeIntervalSinceReferenceDate)))
    return true
  }
  return false
}
