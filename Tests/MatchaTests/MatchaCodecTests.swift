import Foundation
import Testing
@testable import Matcha

@Test func encodeSimpleObject() throws {
  let value: MatchaValue = .object(["name": "Ada", "age": 37, "active": true])
  let output = try MatchaEncoder().encode(value)

  #expect(output.contains("name: Ada"))
  #expect(output.contains("age: 37"))
  #expect(output.contains("active: true"))
}

@Test func encodeTabularArray() throws {
  let value: MatchaValue = .object(["users": .array([
    .object(["id": 1, "name": "Ada"]),
    .object(["id": 2, "name": "Grace"]),
  ])])

  let output = try MatchaEncoder().encode(value)
  #expect(output.contains("users[2]{id,name}:"))
  #expect(output.contains("1,Ada"))
  #expect(output.contains("2,Grace"))
}

@Test func decodeSimpleObject() throws {
  let input = """
  name: Ada
  age: 37
  active: true
  """

  let decoded = try MatchaDecoder().decode(input)
  #expect(decoded == .object(MatchaObject(entries: [
    .init(key: "name", value: "Ada"),
    .init(key: "age", value: .number(MatchaNumber(rawValue: "37")!)),
    .init(key: "active", value: .bool(true)),
  ])))
}

@Test func decodeRootArray() throws {
  let input = """
  [3]: Ada,Grace,Linus
  """

  let decoded = try MatchaDecoder().decode(input)
  #expect(decoded == .array(["Ada", "Grace", "Linus"]))
}

@Test func decodeTabularArray() throws {
  let input = """
  users[2]{id,name}:
    1,Ada
    2,Grace
  """

  let decoded = try MatchaDecoder().decode(input)
  #expect(decoded == .object(MatchaObject(entries: [
    .init(key: "users", value: .array([
      .object(["id": 1, "name": "Ada"]),
      .object(["id": 2, "name": "Grace"]),
    ])),
  ])))
}

@Test func keyFoldingAndExpansionRoundTrip() throws {
  let value: MatchaValue = .object(["data": .object(["metadata": .object(["items": .array(["a", "b"])])])])
  let encoded = try MatchaEncoder(options: .init(keyFolding: .safe)).encode(value)
  #expect(encoded.contains("data.metadata.items[2]: a,b"))

  let decoded = try MatchaDecoder(options: .init(expandPaths: .safe)).decode(encoded)
  #expect(decoded == value)
}

@Test func encodableRoundTrip() throws {
  struct Payload: Codable, Equatable {
    var name: String
    var count: Int
  }

  let encoder = MatchaEncoder()
  let input = Payload(name: "Ada", count: 3)
  let encoded = try encoder.encode(input)
  let decoded = try MatchaDecoder().decode(Payload.self, from: encoded)

  #expect(decoded == input)
}

@Test func encoderRespectsIndentOption() throws {
  let value: MatchaValue = .object(["outer": .object(["inner": "value"])])
  let output = try MatchaEncoder(options: .init(indent: 4)).encode(value)

  #expect(output.contains("\n    inner: value"))
}
