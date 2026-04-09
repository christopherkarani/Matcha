import Foundation

public struct MatchaEncoder: Sendable {
  public var options: MatchaEncoderOptions

  public init(options: MatchaEncoderOptions = .init()) {
    self.options = options
  }

  public func encode(_ value: MatchaValue) throws -> String {
    var output = ""
    var isFirstLine = true
    try encodeLines(value) { line in
      if !isFirstLine {
        output.append("\n")
      }
      output.append(line)
      isFirstLine = false
    }
    return output
  }

  public func encode<T: Encodable>(_ value: T) throws -> String {
    try encode(MatchaJSONBridge.normalize(value))
  }

  public func encodeLines(_ value: MatchaValue) throws -> [String] {
    guard options.indent >= 0 else {
      throw MatchaError(.invalidArgument, "Indent must be zero or positive")
    }
    var lines: [String] = []
    try encodeValue(value, depth: 0) { line in
      lines.append(line)
    }
    return lines
  }

  public func encodeLines(_ value: MatchaValue, onLine: @escaping (String) throws -> Void) throws {
    guard options.indent >= 0 else {
      throw MatchaError(.invalidArgument, "Indent must be zero or positive")
    }
    try encodeValue(value, depth: 0, onLine: onLine)
  }

  private func encodeValue(_ value: MatchaValue, depth: Int, onLine: @escaping (String) throws -> Void) throws {
    switch value {
    case let .string(value):
      try onLine(encodeStringLiteral(value, delimiter: options.delimiter))
    case let .number(value):
      try onLine(value.rawValue)
    case let .bool(value):
      try onLine(value ? "true" : "false")
    case .null:
      try onLine("null")
    case let .array(value):
      try encodeArray(key: nil, value: value, depth: depth, onLine: onLine)
    case let .object(value):
      try encodeObject(
        value,
        depth: depth,
        rootLiteralKeys: nil,
        pathPrefix: nil,
        remainingDepth: nil,
        onLine: onLine
      )
    }
  }

  private func encodeObject(
    _ object: MatchaObject,
    depth: Int,
    rootLiteralKeys: Set<String>?,
    pathPrefix: String?,
    remainingDepth: Int?,
    onLine: @escaping (String) throws -> Void
  ) throws {
    let localRootLiteralKeys: Set<String>
    if depth == 0, rootLiteralKeys == nil {
      localRootLiteralKeys = Set(object.entries.map(\.key).filter { $0.contains(".") })
    } else {
      localRootLiteralKeys = rootLiteralKeys ?? []
    }

    let siblings = object.entries.map(\.key)
    let effectiveFlattenDepth = remainingDepth ?? options.flattenDepth

    for entry in object.entries {
      let currentPath = pathPrefix.map { "\($0).\(entry.key)" } ?? entry.key
      if options.keyFolding == .safe,
         let folded = tryFoldKeyChain(
           key: entry.key,
           value: entry.value,
           siblings: siblings,
           rootLiteralKeys: localRootLiteralKeys,
           pathPrefix: pathPrefix,
           flattenDepth: effectiveFlattenDepth
         ) {
        let encodedFoldedKey = encodeKey(folded.foldedKey)
        if let remainder = folded.remainder, case let .object(tail) = remainder {
          try onLine(indented(depth, "\(encodedFoldedKey):", width: options.indent))
          try encodeObject(
            tail,
            depth: depth + 1,
            rootLiteralKeys: localRootLiteralKeys,
            pathPrefix: pathPrefix.map { "\($0).\(folded.foldedKey)" } ?? folded.foldedKey,
            remainingDepth: max(effectiveFlattenDepth - folded.segmentCount, 0),
            onLine: onLine
          )
          continue
        }

        switch folded.leafValue {
        case let .array(array):
          try encodeArray(key: folded.foldedKey, value: array, depth: depth, onLine: onLine)
        case let .object(value):
          try onLine(indented(depth, "\(encodedFoldedKey):", width: options.indent))
          if !value.isEmpty {
            try encodeObject(
              value,
              depth: depth + 1,
              rootLiteralKeys: localRootLiteralKeys,
              pathPrefix: currentPath,
              remainingDepth: max(effectiveFlattenDepth - folded.segmentCount, 0),
              onLine: onLine
            )
          }
        default:
          try onLine(indented(depth, "\(encodedFoldedKey): \(encodePrimitive(folded.leafValue, delimiter: options.delimiter))", width: options.indent))
        }
        continue
      }

      let encodedKey = encodeKey(entry.key)
      switch entry.value {
      case .string, .number, .bool, .null:
        try onLine(indented(depth, "\(encodedKey): \(encodePrimitive(entry.value, delimiter: options.delimiter))", width: options.indent))
      case let .array(array):
        try encodeArray(key: entry.key, value: array, depth: depth, onLine: onLine)
      case let .object(value):
        try onLine(indented(depth, "\(encodedKey):", width: options.indent))
        if !value.isEmpty {
          try encodeObject(
            value,
            depth: depth + 1,
            rootLiteralKeys: localRootLiteralKeys,
            pathPrefix: currentPath,
            remainingDepth: effectiveFlattenDepth,
            onLine: onLine
          )
        }
      }
    }
  }

  private func encodeArray(key: String?, value: [MatchaValue], depth: Int, onLine: @escaping (String) throws -> Void) throws {
    if value.isEmpty {
      try onLine(indented(depth, formatHeader(length: 0, key: key, fields: nil, delimiter: options.delimiter), width: options.indent))
      return
    }

    if value.allSatisfy(\.isPrimitive) {
      let header = formatHeader(length: value.count, key: key, fields: nil, delimiter: options.delimiter)
      let joined = value.map { encodePrimitive($0, delimiter: options.delimiter) }.joined(separator: String(options.delimiter.rawValue))
      try onLine(indented(depth, "\(header) \(joined)", width: options.indent))
      return
    }

    if value.allSatisfy({
      if case let .array(items) = $0 {
        return items.allSatisfy(\.isPrimitive)
      }
      return false
    }) {
      try onLine(indented(depth, formatHeader(length: value.count, key: key, fields: nil, delimiter: options.delimiter), width: options.indent))
      for item in value {
        guard case let .array(items) = item else { continue }
        let nestedHeader = formatHeader(length: items.count, key: nil, fields: nil, delimiter: options.delimiter)
        let joined = items.map { encodePrimitive($0, delimiter: options.delimiter) }.joined(separator: String(options.delimiter.rawValue))
        try onLine(indented(depth + 1, "- \(nestedHeader)\(items.isEmpty ? "" : " \(joined)")", width: options.indent))
      }
      return
    }

    if let headerFields = tabularHeader(for: value) {
      try onLine(indented(depth, formatHeader(length: value.count, key: key, fields: headerFields, delimiter: options.delimiter), width: options.indent))
      for item in value {
        guard case let .object(object) = item else { continue }
        let row = headerFields.compactMap { field in
          object.entries.first(where: { $0.key == field })?.value
        }
        try onLine(indented(depth + 1, row.map { encodePrimitive($0, delimiter: options.delimiter) }.joined(separator: String(options.delimiter.rawValue)), width: options.indent))
      }
      return
    }

    try onLine(indented(depth, formatHeader(length: value.count, key: key, fields: nil, delimiter: options.delimiter), width: options.indent))
    for item in value {
      try encodeListItemValue(item, depth: depth + 1, onLine: onLine)
    }
  }

  private func encodeListItemValue(_ value: MatchaValue, depth: Int, onLine: @escaping (String) throws -> Void) throws {
    switch value {
    case .string, .number, .bool, .null:
      try onLine(indented(depth, "- \(encodePrimitive(value, delimiter: options.delimiter))", width: options.indent))
    case let .array(items):
      if items.isEmpty || items.allSatisfy(\.isPrimitive) {
        try onLine(indented(depth, "- \(encodeInlineArrayLine(items, delimiter: options.delimiter, prefix: nil))", width: options.indent))
      } else {
        try onLine(indented(depth, "- \(formatHeader(length: items.count, key: nil, fields: nil, delimiter: options.delimiter))", width: options.indent))
        for item in items {
          try encodeListItemValue(item, depth: depth + 1, onLine: onLine)
        }
      }
    case let .object(object):
      try encodeObjectAsListItem(object, depth: depth, onLine: onLine)
    }
  }

  private func encodeObjectAsListItem(_ object: MatchaObject, depth: Int, onLine: @escaping (String) throws -> Void) throws {
    if object.entries.isEmpty {
      try onLine(indented(depth, "-", width: options.indent))
      return
    }

    let first = object.entries[0]
    let rest = MatchaObject(entries: Array(object.entries.dropFirst()))

    if case let .array(firstArray) = first.value,
       !firstArray.isEmpty,
       firstArray.allSatisfy({
         if case let .object(candidate) = $0 {
           return !candidate.entries.isEmpty
             && candidate.entries.allSatisfy { $0.value.isPrimitive }
         }
         return false
       }),
       let header = tabularHeader(for: firstArray) {
      let formattedHeader = formatHeader(length: firstArray.count, key: first.key, fields: header, delimiter: options.delimiter)
      try onLine(indented(depth, "- \(formattedHeader)", width: options.indent))
      for item in firstArray {
        guard case let .object(row) = item else { continue }
        let values = header.compactMap { field in
          row.entries.first(where: { $0.key == field })?.value
        }
        try onLine(indented(depth + 2, values.map { encodePrimitive($0, delimiter: options.delimiter) }.joined(separator: String(options.delimiter.rawValue)), width: options.indent))
      }

      if !rest.isEmpty {
        try encodeObject(rest, depth: depth + 1, rootLiteralKeys: nil, pathPrefix: nil, remainingDepth: nil, onLine: onLine)
      }
      return
    }

    switch first.value {
    case .string, .number, .bool, .null:
      try onLine(indented(depth, "- \(encodeKey(first.key)): \(encodePrimitive(first.value, delimiter: options.delimiter))", width: options.indent))
    case let .array(items):
      if items.isEmpty || items.allSatisfy(\.isPrimitive) {
        try onLine(indented(depth, "- \(encodeKey(first.key))\(encodeInlineArrayLine(items, delimiter: options.delimiter, prefix: nil))", width: options.indent))
      } else {
        try onLine(indented(depth, "- \(encodeKey(first.key))\(formatHeader(length: items.count, key: nil, fields: nil, delimiter: options.delimiter))", width: options.indent))
        for item in items {
          try encodeListItemValue(item, depth: depth + 2, onLine: onLine)
        }
      }
    case let .object(nestedObject):
      try onLine(indented(depth, "- \(encodeKey(first.key)):", width: options.indent))
      if !nestedObject.isEmpty {
        try encodeObject(nestedObject, depth: depth + 2, rootLiteralKeys: nil, pathPrefix: nil, remainingDepth: nil, onLine: onLine)
      }
    }

    if !rest.isEmpty {
      try encodeObject(rest, depth: depth + 1, rootLiteralKeys: nil, pathPrefix: nil, remainingDepth: nil, onLine: onLine)
    }
  }

  private func tryFoldKeyChain(
    key: String,
    value: MatchaValue,
    siblings: [String],
    rootLiteralKeys: Set<String>,
    pathPrefix: String?,
    flattenDepth: Int
  ) -> (foldedKey: String, remainder: MatchaValue?, leafValue: MatchaValue, segmentCount: Int)? {
    guard flattenDepth > 1 else { return nil }
    guard case let .object(object) = value else { return nil }

    var segments = [key]
    var current: MatchaValue = .object(object)
    while segments.count < flattenDepth {
      guard case let .object(candidate) = current else { break }
      guard candidate.entries.count == 1 else { break }
      let next = candidate.entries[0]
      segments.append(next.key)
      current = next.value
    }

    guard segments.count >= 2 else { return nil }
    guard segments.allSatisfy(isIdentifierSegment(_:)) else { return nil }

    let foldedKey = segments.joined(separator: ".")
    let absolutePath = pathPrefix.map { "\($0).\(foldedKey)" } ?? foldedKey
    if siblings.contains(foldedKey) || rootLiteralKeys.contains(absolutePath) {
      return nil
    }

    if case let .object(remainder) = current, !remainder.isEmpty {
      return (foldedKey, .object(remainder), .object(remainder), segments.count)
    }

    return (foldedKey, nil, current, segments.count)
  }

  private func tabularHeader(for values: [MatchaValue]) -> [String]? {
    guard case let .object(firstObject) = values.first else { return nil }
    let header = firstObject.entries.map(\.key)
    guard !header.isEmpty else { return nil }

    for item in values {
      guard case let .object(object) = item else { return nil }
      let keys = object.entries.map(\.key)
      guard keys.count == header.count else { return nil }
      for key in header {
        guard let value = object.entries.first(where: { $0.key == key })?.value, value.isPrimitive else {
          return nil
        }
      }
    }

    return header
  }
}

public struct MatchaDecoder: Sendable {
  public var options: MatchaDecoderOptions

  public init(options: MatchaDecoderOptions = .init()) {
    self.options = options
  }

  public func decode(_ input: String) throws -> MatchaValue {
    let parsed = try parseLines(from: input, options: options)
    let parser = DecoderParser(lines: parsed.lines, blankLines: parsed.blankLines, options: options)
    let decoded = try parser.parse()
    if options.expandPaths == .safe {
      return try expandPaths(decoded, strict: options.strict)
    }
    return decoded
  }

  public func decode<T: Decodable>(_ type: T.Type, from input: String) throws -> T {
    try MatchaJSONBridge.decode(type, from: decode(input))
  }

  public func decodeLines<S: Sequence>(_ lines: S) throws -> MatchaValue where S.Element == String {
    try decode(lines.joined(separator: "\n"))
  }

  public func decodeEvents<S: Sequence>(_ lines: S) throws -> [MatchaEvent] where S.Element == String {
    var events: [MatchaEvent] = []
    try decodeEvents(lines) { event in
      events.append(event)
    }
    return events
  }

  public func decodeEvents<S: Sequence>(_ lines: S, onEvent: @escaping (MatchaEvent) throws -> Void) throws where S.Element == String {
    guard options.expandPaths == .off else {
      throw MatchaError(.unsupportedOption, "Path expansion is not available for event streaming")
    }
    let parser = StreamingEventParser(lines: lines, options: options, onEvent: onEvent)
    try parser.parse()
  }

  @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
  public func decodeEvents<S: AsyncSequence>(_ lines: S) async throws -> [MatchaEvent] where S.Element == String {
    let collector = AsyncEventCollector()
    try await decodeEvents(lines) { event in
      await collector.append(event)
    }
    return await collector.events
  }

  @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
  public func decodeEvents<S: AsyncSequence>(_ lines: S, onEvent: @escaping @Sendable (MatchaEvent) async throws -> Void) async throws where S.Element == String {
    guard options.expandPaths == .off else {
      throw MatchaError(.unsupportedOption, "Path expansion is not available for event streaming")
    }
    let parser = AsyncStreamingEventParser(lines: lines, options: options, onEvent: onEvent)
    try await parser.parse()
  }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
private actor AsyncEventCollector {
  private(set) var events: [MatchaEvent] = []

  func append(_ event: MatchaEvent) {
    events.append(event)
  }
}

private struct ParsedLine {
  let lineNumber: Int
  let depth: Int
  let content: String
}

private struct ArrayHeader {
  let key: String?
  let keyWasQuoted: Bool
  let length: Int
  let delimiter: MatchaDelimiter
  let fields: [String]?
}

private final class DecoderParser {
  let lines: [ParsedLine]
  let blankLines: [Int]
  let options: MatchaDecoderOptions
  var index: Int = 0

  init(lines: [ParsedLine], blankLines: [Int], options: MatchaDecoderOptions) {
    self.lines = lines
    self.blankLines = blankLines
    self.options = options
  }

  func parse() throws -> MatchaValue {
    guard let first = lines.first else {
      return .object(MatchaObject())
    }

    if let rootHeader = try parseArrayHeaderLine(first.content), rootHeader.key == nil {
      index = 1
      return try parseArray(header: rootHeader, inlineValues: inlineValues(after: first.content), baseDepth: 0)
    }

    if lines.count == 1, !isKeyValueContent(first.content) {
      index = 1
      return try parsePrimitiveToken(first.content)
    }

    return .object(try parseObject(baseDepth: 0))
  }

  private func parseObject(baseDepth: Int) throws -> MatchaObject {
    var entries: [MatchaObject.Entry] = []
    var expectedDepth: Int?

    while index < lines.count {
      let line = lines[index]
      if line.depth < baseDepth {
        break
      }

      if expectedDepth == nil {
        expectedDepth = line.depth
      }

      guard line.depth == expectedDepth else { break }
      entries.append(try parseKeyValue(from: line.content, currentDepth: line.depth))
    }

    return MatchaObject(entries: entries)
  }

  private func parseKeyValue(from content: String, currentDepth: Int) throws -> MatchaObject.Entry {
    if let header = try parseArrayHeaderLine(content), let key = header.key {
      index += 1
      let array = try parseArray(header: header, inlineValues: inlineValues(after: content), baseDepth: currentDepth)
      return .init(key: key, value: array, wasQuoted: header.keyWasQuoted)
    }

    let keyToken = try parseKeyToken(content)
    index += 1
    let rest = content.dropFirst(keyToken.end).trimmingCharacters(in: .whitespaces)
    if rest.isEmpty {
      if index < lines.count, lines[index].depth > currentDepth {
        return .init(key: keyToken.key, value: .object(try parseObject(baseDepth: currentDepth + 1)), wasQuoted: keyToken.wasQuoted)
      }
      return .init(key: keyToken.key, value: .object(MatchaObject()), wasQuoted: keyToken.wasQuoted)
    }

    return .init(key: keyToken.key, value: try parsePrimitiveToken(String(rest)), wasQuoted: keyToken.wasQuoted)
  }

  private func parseArray(header: ArrayHeader, inlineValues: String?, baseDepth: Int) throws -> MatchaValue {
    if let inlineValues, !inlineValues.isEmpty {
      let parts = parseDelimitedValues(inlineValues, delimiter: header.delimiter)
      if options.strict, parts.count != header.length {
        throw MatchaError(.countMismatch, "Expected \(header.length) inline array items, found \(parts.count)")
      }
      return .array(try parts.map(parsePrimitiveToken(_:)))
    }

    if let fields = header.fields, !fields.isEmpty {
      var rows: [MatchaValue] = []
      let rowDepth = baseDepth + 1
      var firstLineNumber: Int?
      var lastLineNumber: Int?
      while index < lines.count, lines[index].depth == rowDepth {
        firstLineNumber = firstLineNumber ?? lines[index].lineNumber
        lastLineNumber = lines[index].lineNumber
        let parts = parseDelimitedValues(lines[index].content, delimiter: header.delimiter)
        if options.strict, parts.count != fields.count {
          throw MatchaError(.countMismatch, "Expected \(fields.count) tabular row values, found \(parts.count)", diagnostic: .init(line: lines[index].lineNumber))
        }
        let entries = try zip(fields, parts).map { field, raw in
          MatchaObject.Entry(key: field, value: try parsePrimitiveToken(raw))
        }
        rows.append(.object(MatchaObject(entries: entries)))
        index += 1
      }
      if options.strict, rows.count != header.length {
        if rows.count > header.length {
          throw MatchaError(.countMismatch, "Expected \(header.length) tabular rows, but found more")
        }
        throw MatchaError(.countMismatch, "Expected \(header.length) tabular rows, found \(rows.count)")
      }
      try validateNoBlankLines(first: firstLineNumber, last: lastLineNumber, context: "tabular array")
      return .array(rows)
    }

    var values: [MatchaValue] = []
    let itemDepth = baseDepth + 1
    var firstLineNumber: Int?
    var lastLineNumber: Int?
    while index < lines.count, lines[index].depth == itemDepth, isListItem(lines[index].content) {
      firstLineNumber = firstLineNumber ?? lines[index].lineNumber
      values.append(try parseListItem(itemDepth: itemDepth))
      lastLineNumber = lines[max(index - 1, 0)].lineNumber
    }
    if options.strict, values.count != header.length {
      if values.count > header.length {
        throw MatchaError(.countMismatch, "Expected \(header.length) list array items, but found more")
      }
      throw MatchaError(.countMismatch, "Expected \(header.length) list array items, but got \(values.count)")
    }
    try validateNoBlankLines(first: firstLineNumber, last: lastLineNumber, context: "list array")
    return .array(values)
  }

  private func parseListItem(itemDepth: Int) throws -> MatchaValue {
    let line = lines[index]
    index += 1

    if line.content == "-" {
      return .object(MatchaObject())
    }

    let afterHyphen = String(line.content.dropFirst(2))
    if afterHyphen.trimmingCharacters(in: .whitespaces).isEmpty {
      return .object(MatchaObject())
    }

    if let header = try parseArrayHeaderLine(afterHyphen), header.key == nil {
      return try parseArray(header: header, inlineValues: inlineValues(after: afterHyphen), baseDepth: itemDepth)
    }

    if let header = try parseArrayHeaderLine(afterHyphen), let key = header.key {
      var entries = [MatchaObject.Entry(key: key, value: try parseArray(header: header, inlineValues: inlineValues(after: afterHyphen), baseDepth: itemDepth + 1), wasQuoted: header.keyWasQuoted)]
      while index < lines.count, lines[index].depth == itemDepth + 1, !isListItem(lines[index].content) {
        entries.append(try parseKeyValue(from: lines[index].content, currentDepth: itemDepth + 1))
      }
      return .object(MatchaObject(entries: entries))
    }

    if isKeyValueContent(afterHyphen) {
      let first = try parseInlineKeyValue(from: afterHyphen, currentDepth: itemDepth + 1)
      var entries = [first]
      while index < lines.count, lines[index].depth == itemDepth + 1, !isListItem(lines[index].content) {
        entries.append(try parseKeyValue(from: lines[index].content, currentDepth: itemDepth + 1))
      }
      return .object(MatchaObject(entries: entries))
    }

    return try parsePrimitiveToken(afterHyphen)
  }

  private func parseInlineKeyValue(from content: String, currentDepth: Int) throws -> MatchaObject.Entry {
    if let header = try parseArrayHeaderLine(content), let key = header.key {
      return .init(key: key, value: try parseArray(header: header, inlineValues: inlineValues(after: content), baseDepth: currentDepth), wasQuoted: header.keyWasQuoted)
    }

    let token = try parseKeyToken(content)
    let rest = content.dropFirst(token.end).trimmingCharacters(in: .whitespaces)
    if rest.isEmpty {
      if index < lines.count, lines[index].depth > currentDepth {
        return .init(key: token.key, value: .object(try parseObject(baseDepth: currentDepth + 1)), wasQuoted: token.wasQuoted)
      }
      return .init(key: token.key, value: .object(MatchaObject()), wasQuoted: token.wasQuoted)
    }
    return .init(key: token.key, value: try parsePrimitiveToken(String(rest)), wasQuoted: token.wasQuoted)
  }

  private func validateNoBlankLines(first: Int?, last: Int?, context: String) throws {
    guard options.strict, let first, let last else { return }
    if blankLines.contains(where: { $0 > first && $0 < last }) {
      throw MatchaError(.invalidSyntax, "Blank lines inside \(context) are not allowed")
    }
  }
}

private final class StreamingLineReader<Lines: Sequence> where Lines.Element == String {
  private var iterator: Lines.Iterator
  private let options: MatchaDecoderOptions
  private var lineNumber = 0
  private var buffered: ParsedLine?
  private var reachedEnd = false
  private var pendingBlankLines: [Int] = []

  init(lines: Lines, options: MatchaDecoderOptions) {
    self.iterator = lines.makeIterator()
    self.options = options
  }

  func peek() throws -> ParsedLine? {
    try loadNextIfNeeded()
    return buffered
  }

  func take() throws -> ParsedLine? {
    let line = try peek()
    buffered = nil
    return line
  }

  func consumePendingBlankLines() -> [Int] {
    defer { pendingBlankLines.removeAll() }
    return pendingBlankLines
  }

  var hasPendingBlankLines: Bool {
    !pendingBlankLines.isEmpty
  }

  private func loadNextIfNeeded() throws {
    guard buffered == nil, !reachedEnd else { return }

    while let rawLine = iterator.next() {
      lineNumber += 1
      if rawLine.isEmpty || rawLine.trimmingCharacters(in: .whitespaces).isEmpty {
        pendingBlankLines.append(lineNumber)
        continue
      }

      var spaces = 0
      var sawTabInIndent = false
      for character in rawLine {
        if character == " " {
          spaces += 1
        } else if character == "\t" {
          sawTabInIndent = true
          break
        } else {
          break
        }
      }

      if options.strict, sawTabInIndent {
        throw MatchaError(.invalidIndent, "Tabs are not allowed in indentation", diagnostic: .init(line: lineNumber, column: spaces + 1))
      }

      if options.indent <= 0 {
        if spaces > 0 {
          throw MatchaError(.invalidIndent, "Indent must be greater than zero when using nested content", diagnostic: .init(line: lineNumber))
        }
      } else if options.strict, spaces % options.indent != 0 {
        throw MatchaError(.invalidIndent, "Indentation must be a multiple of \(options.indent), but found \(spaces) spaces", diagnostic: .init(line: lineNumber, column: spaces + 1))
      }

      let content = String(rawLine.dropFirst(spaces))
      buffered = .init(
        lineNumber: lineNumber,
        depth: options.indent == 0 ? 0 : spaces / max(options.indent, 1),
        content: content
      )
      return
    }

    reachedEnd = true
  }
}

private final class StreamingEventParser<Lines: Sequence> where Lines.Element == String {
  private let reader: StreamingLineReader<Lines>
  private let options: MatchaDecoderOptions
  private let onEvent: (MatchaEvent) throws -> Void

  init(lines: Lines, options: MatchaDecoderOptions, onEvent: @escaping (MatchaEvent) throws -> Void) {
    self.reader = StreamingLineReader(lines: lines, options: options)
    self.options = options
    self.onEvent = onEvent
  }

  func parse() throws {
    guard let first = try reader.peek() else {
      try emit(.startObject)
      try emit(.endObject)
      return
    }

    if let rootHeader = try parseArrayHeaderLine(first.content), rootHeader.key == nil {
      _ = try reader.take()
      try emit(.startArray(length: rootHeader.length))
      try parseArray(header: rootHeader, inlineValues: inlineValues(after: first.content), baseDepth: 0)
      try emit(.endArray)
      return
    }

    if !isKeyValueContent(first.content) {
      _ = try reader.take()
      if try reader.peek() != nil {
        throw MatchaError(.missingColon, "Missing colon after key", diagnostic: .init(line: first.lineNumber))
      }
      try emit(.primitive(try parsePrimitiveToken(first.content)))
      return
    }

    try emit(.startObject)
    try parseObject(baseDepth: 0)
    try emit(.endObject)
  }

  private func emit(_ event: MatchaEvent) throws {
    try onEvent(event)
  }

  private func parseObject(baseDepth: Int) throws {
    var expectedDepth: Int?

    while let line = try reader.peek() {
      if line.depth < baseDepth {
        break
      }

      if expectedDepth == nil {
        expectedDepth = line.depth
      }

      guard line.depth == expectedDepth else { break }
      try parseKeyValue(from: line.content, currentDepth: line.depth)
    }
  }

  private func parseKeyValue(from content: String, currentDepth: Int) throws {
    if let header = try parseArrayHeaderLine(content), let key = header.key {
      _ = try reader.take()
      try emit(.key(key, wasQuoted: header.keyWasQuoted))
      try emit(.startArray(length: header.length))
      try parseArray(header: header, inlineValues: inlineValues(after: content), baseDepth: currentDepth)
      try emit(.endArray)
      return
    }

    let keyToken = try parseKeyToken(content)
    _ = try reader.take()
    try emit(.key(keyToken.key, wasQuoted: keyToken.wasQuoted))

    let rest = content.dropFirst(keyToken.end).trimmingCharacters(in: .whitespaces)
    if rest.isEmpty {
      if let next = try reader.peek(), next.depth > currentDepth {
        try emit(.startObject)
        try parseObject(baseDepth: currentDepth + 1)
        try emit(.endObject)
      } else {
        try emit(.startObject)
        try emit(.endObject)
      }
      return
    }

    try emit(.primitive(try parsePrimitiveToken(String(rest))))
  }

  private func parseArray(header: ArrayHeader, inlineValues: String?, baseDepth: Int) throws {
    if let inlineValues, !inlineValues.isEmpty {
      let parts = parseDelimitedValues(inlineValues, delimiter: header.delimiter)
      if options.strict, parts.count != header.length {
        throw MatchaError(.countMismatch, "Expected \(header.length) inline array items, found \(parts.count)")
      }
      for part in parts {
        try emit(.primitive(try parsePrimitiveToken(part)))
      }
      return
    }

    if let fields = header.fields, !fields.isEmpty {
      var rowCount = 0
      let rowDepth = baseDepth + 1

      while let line = try reader.peek(), line.depth == rowDepth {
        if rowCount > 0, options.strict, reader.hasPendingBlankLines {
        throw MatchaError(.invalidSyntax, "Blank lines inside tabular array are not allowed")
        }
        _ = reader.consumePendingBlankLines()
        let current = try requireLine(reader.take())
        let parts = parseDelimitedValues(current.content, delimiter: header.delimiter)
        if options.strict, parts.count != fields.count {
          throw MatchaError(.countMismatch, "Expected \(fields.count) tabular row values, found \(parts.count)", diagnostic: .init(line: current.lineNumber))
        }

        try emit(.startObject)
        for (field, raw) in zip(fields, parts) {
          try emit(.key(field, wasQuoted: false))
          try emit(.primitive(try parsePrimitiveToken(raw)))
        }
        try emit(.endObject)
        rowCount += 1
      }

      if options.strict, rowCount != header.length {
        if rowCount > header.length {
          throw MatchaError(.countMismatch, "Expected \(header.length) tabular rows, but found more")
        }
        throw MatchaError(.countMismatch, "Expected \(header.length) tabular rows, found \(rowCount)")
      }
      return
    }

    var itemCount = 0
    let itemDepth = baseDepth + 1
    while let line = try reader.peek(), line.depth == itemDepth, isListItem(line.content) {
      if itemCount > 0, options.strict, reader.hasPendingBlankLines {
        throw MatchaError(.invalidSyntax, "Blank lines inside list array are not allowed")
      }
      _ = reader.consumePendingBlankLines()
      try parseListItem(itemDepth: itemDepth)
      itemCount += 1
    }

    if options.strict, itemCount != header.length {
      if itemCount > header.length {
        throw MatchaError(.countMismatch, "Expected \(header.length) list array items, but found more")
      }
      throw MatchaError(.countMismatch, "Expected \(header.length) list array items, but got \(itemCount)")
    }
  }

  private func parseListItem(itemDepth: Int) throws {
    let line = try requireLine(reader.take())
    let lineNumber = line.lineNumber

    if line.content == "-" {
      try emit(.startObject)
      try emit(.endObject)
      return
    }

    let afterHyphen = String(line.content.dropFirst(2))
    if afterHyphen.trimmingCharacters(in: .whitespaces).isEmpty {
      try emit(.startObject)
      try emit(.endObject)
      return
    }

    if let header = try parseArrayHeaderLine(afterHyphen), header.key == nil {
      try emit(.startArray(length: header.length))
      try parseArray(header: header, inlineValues: inlineValues(after: afterHyphen), baseDepth: itemDepth)
      try emit(.endArray)
      return
    }

    if let header = try parseArrayHeaderLine(afterHyphen), let key = header.key {
      try emit(.startObject)
      try emit(.key(key, wasQuoted: header.keyWasQuoted))
      try emit(.startArray(length: header.length))
      try parseArray(header: header, inlineValues: inlineValues(after: afterHyphen), baseDepth: itemDepth + 1)
      try emit(.endArray)
      while let next = try reader.peek(), next.depth == itemDepth + 1, !isListItem(next.content) {
        try parseKeyValue(from: next.content, currentDepth: itemDepth + 1)
      }
      try emit(.endObject)
      return
    }

    if isKeyValueContent(afterHyphen) {
      try emit(.startObject)
      try parseInlineKeyValue(from: afterHyphen, currentDepth: itemDepth + 1, sourceLine: lineNumber)
      while let next = try reader.peek(), next.depth == itemDepth + 1, !isListItem(next.content) {
        try parseKeyValue(from: next.content, currentDepth: itemDepth + 1)
      }
      try emit(.endObject)
      return
    }

    try emit(.primitive(try parsePrimitiveToken(afterHyphen)))
  }

  private func parseInlineKeyValue(from content: String, currentDepth: Int, sourceLine: Int) throws {
    if let header = try parseArrayHeaderLine(content), let key = header.key {
      try emit(.key(key, wasQuoted: header.keyWasQuoted))
      try emit(.startArray(length: header.length))
      try parseArray(header: header, inlineValues: inlineValues(after: content), baseDepth: currentDepth)
      try emit(.endArray)
      return
    }

    let token = try parseKeyToken(content)
    try emit(.key(token.key, wasQuoted: token.wasQuoted))
    let rest = content.dropFirst(token.end).trimmingCharacters(in: .whitespaces)
    if rest.isEmpty {
      if let next = try reader.peek(), next.depth > currentDepth {
        try emit(.startObject)
        try parseObject(baseDepth: currentDepth + 1)
        try emit(.endObject)
      } else {
        try emit(.startObject)
        try emit(.endObject)
      }
      return
    }

    do {
      try emit(.primitive(try parsePrimitiveToken(String(rest))))
    } catch {
      throw MatchaError(.invalidSyntax, error.localizedDescription, diagnostic: .init(line: sourceLine))
    }
  }

  private func requireLine(_ line: ParsedLine?) throws -> ParsedLine {
    guard let line else {
      throw MatchaError(.invalidSyntax, "Unexpected end of input")
    }
    return line
  }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
private final class AsyncStreamingLineReader<Lines: AsyncSequence> where Lines.Element == String {
  private var iterator: Lines.AsyncIterator
  private let options: MatchaDecoderOptions
  private var lineNumber = 0
  private var buffered: ParsedLine?
  private var reachedEnd = false
  private var pendingBlankLines: [Int] = []

  init(lines: Lines, options: MatchaDecoderOptions) {
    self.iterator = lines.makeAsyncIterator()
    self.options = options
  }

  func peek() async throws -> ParsedLine? {
    try await loadNextIfNeeded()
    return buffered
  }

  func take() async throws -> ParsedLine? {
    let line = try await peek()
    buffered = nil
    return line
  }

  func consumePendingBlankLines() -> [Int] {
    defer { pendingBlankLines.removeAll() }
    return pendingBlankLines
  }

  var hasPendingBlankLines: Bool {
    !pendingBlankLines.isEmpty
  }

  private func loadNextIfNeeded() async throws {
    guard buffered == nil, !reachedEnd else { return }

    while let rawLine = try await iterator.next() {
      lineNumber += 1
      if rawLine.isEmpty || rawLine.trimmingCharacters(in: .whitespaces).isEmpty {
        pendingBlankLines.append(lineNumber)
        continue
      }

      var spaces = 0
      var sawTabInIndent = false
      for character in rawLine {
        if character == " " {
          spaces += 1
        } else if character == "\t" {
          sawTabInIndent = true
          break
        } else {
          break
        }
      }

      if options.strict, sawTabInIndent {
        throw MatchaError(.invalidIndent, "Tabs are not allowed in indentation", diagnostic: .init(line: lineNumber, column: spaces + 1))
      }

      if options.indent <= 0 {
        if spaces > 0 {
          throw MatchaError(.invalidIndent, "Indent must be greater than zero when using nested content", diagnostic: .init(line: lineNumber))
        }
      } else if options.strict, spaces % options.indent != 0 {
        throw MatchaError(.invalidIndent, "Indentation must be a multiple of \(options.indent), but found \(spaces) spaces", diagnostic: .init(line: lineNumber, column: spaces + 1))
      }

      let content = String(rawLine.dropFirst(spaces))
      buffered = .init(
        lineNumber: lineNumber,
        depth: options.indent == 0 ? 0 : spaces / max(options.indent, 1),
        content: content
      )
      return
    }

    reachedEnd = true
  }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
private final class AsyncStreamingEventParser<Lines: AsyncSequence> where Lines.Element == String {
  private let reader: AsyncStreamingLineReader<Lines>
  private let options: MatchaDecoderOptions
  private let onEvent: @Sendable (MatchaEvent) async throws -> Void

  init(lines: Lines, options: MatchaDecoderOptions, onEvent: @escaping @Sendable (MatchaEvent) async throws -> Void) {
    self.reader = AsyncStreamingLineReader(lines: lines, options: options)
    self.options = options
    self.onEvent = onEvent
  }

  func parse() async throws {
    guard let first = try await reader.peek() else {
      try await emit(.startObject)
      try await emit(.endObject)
      return
    }

    if let rootHeader = try parseArrayHeaderLine(first.content), rootHeader.key == nil {
      _ = try await reader.take()
      try await emit(.startArray(length: rootHeader.length))
      try await parseArray(header: rootHeader, inlineValues: inlineValues(after: first.content), baseDepth: 0)
      try await emit(.endArray)
      return
    }

    if !isKeyValueContent(first.content) {
      _ = try await reader.take()
      if try await reader.peek() != nil {
        throw MatchaError(.missingColon, "Missing colon after key", diagnostic: .init(line: first.lineNumber))
      }
      try await emit(.primitive(try parsePrimitiveToken(first.content)))
      return
    }

    try await emit(.startObject)
    try await parseObject(baseDepth: 0)
    try await emit(.endObject)
  }

  private func emit(_ event: MatchaEvent) async throws {
    try await onEvent(event)
  }

  private func parseObject(baseDepth: Int) async throws {
    var expectedDepth: Int?

    while let line = try await reader.peek() {
      if line.depth < baseDepth {
        break
      }

      if expectedDepth == nil {
        expectedDepth = line.depth
      }

      guard line.depth == expectedDepth else { break }
      try await parseKeyValue(from: line.content, currentDepth: line.depth)
    }
  }

  private func parseKeyValue(from content: String, currentDepth: Int) async throws {
    if let header = try parseArrayHeaderLine(content), let key = header.key {
      _ = try await reader.take()
      try await emit(.key(key, wasQuoted: header.keyWasQuoted))
      try await emit(.startArray(length: header.length))
      try await parseArray(header: header, inlineValues: inlineValues(after: content), baseDepth: currentDepth)
      try await emit(.endArray)
      return
    }

    let keyToken = try parseKeyToken(content)
    _ = try await reader.take()
    try await emit(.key(keyToken.key, wasQuoted: keyToken.wasQuoted))

    let rest = content.dropFirst(keyToken.end).trimmingCharacters(in: .whitespaces)
    if rest.isEmpty {
      if let next = try await reader.peek(), next.depth > currentDepth {
        try await emit(.startObject)
        try await parseObject(baseDepth: currentDepth + 1)
        try await emit(.endObject)
      } else {
        try await emit(.startObject)
        try await emit(.endObject)
      }
      return
    }

    try await emit(.primitive(try parsePrimitiveToken(String(rest))))
  }

  private func parseArray(header: ArrayHeader, inlineValues: String?, baseDepth: Int) async throws {
    if let inlineValues, !inlineValues.isEmpty {
      let parts = parseDelimitedValues(inlineValues, delimiter: header.delimiter)
      if options.strict, parts.count != header.length {
        throw MatchaError(.countMismatch, "Expected \(header.length) inline array items, found \(parts.count)")
      }
      for part in parts {
        try await emit(.primitive(try parsePrimitiveToken(part)))
      }
      return
    }

    if let fields = header.fields, !fields.isEmpty {
      var rowCount = 0
      let rowDepth = baseDepth + 1

      while let line = try await reader.peek(), line.depth == rowDepth {
        if rowCount > 0, options.strict, reader.hasPendingBlankLines {
        throw MatchaError(.invalidSyntax, "Blank lines inside tabular array are not allowed")
        }
        _ = reader.consumePendingBlankLines()
        let current = try await requireLine(reader.take())
        let parts = parseDelimitedValues(current.content, delimiter: header.delimiter)
        if options.strict, parts.count != fields.count {
          throw MatchaError(.countMismatch, "Expected \(fields.count) tabular row values, found \(parts.count)", diagnostic: .init(line: current.lineNumber))
        }

        try await emit(.startObject)
        for (field, raw) in zip(fields, parts) {
          try await emit(.key(field, wasQuoted: false))
          try await emit(.primitive(try parsePrimitiveToken(raw)))
        }
        try await emit(.endObject)
        rowCount += 1
      }

      if options.strict, rowCount != header.length {
        if rowCount > header.length {
          throw MatchaError(.countMismatch, "Expected \(header.length) tabular rows, but found more")
        }
        throw MatchaError(.countMismatch, "Expected \(header.length) tabular rows, found \(rowCount)")
      }
      return
    }

    var itemCount = 0
    let itemDepth = baseDepth + 1
    while let line = try await reader.peek(), line.depth == itemDepth, isListItem(line.content) {
      if itemCount > 0, options.strict, reader.hasPendingBlankLines {
        throw MatchaError(.invalidSyntax, "Blank lines inside list array are not allowed")
      }
      _ = reader.consumePendingBlankLines()
      try await parseListItem(itemDepth: itemDepth)
      itemCount += 1
    }

    if options.strict, itemCount != header.length {
      if itemCount > header.length {
        throw MatchaError(.countMismatch, "Expected \(header.length) list array items, but found more")
      }
      throw MatchaError(.countMismatch, "Expected \(header.length) list array items, but got \(itemCount)")
    }
  }

  private func parseListItem(itemDepth: Int) async throws {
    let line = try await requireLine(reader.take())
    let lineNumber = line.lineNumber

    if line.content == "-" {
      try await emit(.startObject)
      try await emit(.endObject)
      return
    }

    let afterHyphen = String(line.content.dropFirst(2))
    if afterHyphen.trimmingCharacters(in: .whitespaces).isEmpty {
      try await emit(.startObject)
      try await emit(.endObject)
      return
    }

    if let header = try parseArrayHeaderLine(afterHyphen), header.key == nil {
      try await emit(.startArray(length: header.length))
      try await parseArray(header: header, inlineValues: inlineValues(after: afterHyphen), baseDepth: itemDepth)
      try await emit(.endArray)
      return
    }

    if let header = try parseArrayHeaderLine(afterHyphen), let key = header.key {
      try await emit(.startObject)
      try await emit(.key(key, wasQuoted: header.keyWasQuoted))
      try await emit(.startArray(length: header.length))
      try await parseArray(header: header, inlineValues: inlineValues(after: afterHyphen), baseDepth: itemDepth + 1)
      try await emit(.endArray)
      while let next = try await reader.peek(), next.depth == itemDepth + 1, !isListItem(next.content) {
        try await parseKeyValue(from: next.content, currentDepth: itemDepth + 1)
      }
      try await emit(.endObject)
      return
    }

    if isKeyValueContent(afterHyphen) {
      try await emit(.startObject)
      try await parseInlineKeyValue(from: afterHyphen, currentDepth: itemDepth + 1, sourceLine: lineNumber)
      while let next = try await reader.peek(), next.depth == itemDepth + 1, !isListItem(next.content) {
        try await parseKeyValue(from: next.content, currentDepth: itemDepth + 1)
      }
      try await emit(.endObject)
      return
    }

    try await emit(.primitive(try parsePrimitiveToken(afterHyphen)))
  }

  private func parseInlineKeyValue(from content: String, currentDepth: Int, sourceLine: Int) async throws {
    if let header = try parseArrayHeaderLine(content), let key = header.key {
      try await emit(.key(key, wasQuoted: header.keyWasQuoted))
      try await emit(.startArray(length: header.length))
      try await parseArray(header: header, inlineValues: inlineValues(after: content), baseDepth: currentDepth)
      try await emit(.endArray)
      return
    }

    let token = try parseKeyToken(content)
    try await emit(.key(token.key, wasQuoted: token.wasQuoted))
    let rest = content.dropFirst(token.end).trimmingCharacters(in: .whitespaces)
    if rest.isEmpty {
      if let next = try await reader.peek(), next.depth > currentDepth {
        try await emit(.startObject)
        try await parseObject(baseDepth: currentDepth + 1)
        try await emit(.endObject)
      } else {
        try await emit(.startObject)
        try await emit(.endObject)
      }
      return
    }

    do {
      try await emit(.primitive(try parsePrimitiveToken(String(rest))))
    } catch {
      throw MatchaError(.invalidSyntax, error.localizedDescription, diagnostic: .init(line: sourceLine))
    }
  }

  private func requireLine(_ line: ParsedLine?) async throws -> ParsedLine {
    guard let line else {
      throw MatchaError(.invalidSyntax, "Unexpected end of input")
    }
    return line
  }
}

private struct ParsedDocument {
  let lines: [ParsedLine]
  let blankLines: [Int]
}

private func parseLines(from input: String, options: MatchaDecoderOptions) throws -> ParsedDocument {
  let rawLines = input.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
  var parsed: [ParsedLine] = []
  var blankLines: [Int] = []

  for (offset, rawLine) in rawLines.enumerated() {
    if rawLine.isEmpty || rawLine.trimmingCharacters(in: .whitespaces).isEmpty {
      blankLines.append(offset + 1)
      continue
    }

    var spaces = 0
    var sawTabInIndent = false
    for character in rawLine {
      if character == " " {
        spaces += 1
      } else if character == "\t" {
        sawTabInIndent = true
        break
      } else {
        break
      }
    }

    if options.strict, sawTabInIndent {
      throw MatchaError(.invalidIndent, "Tabs are not allowed in indentation", diagnostic: .init(line: offset + 1, column: spaces + 1))
    }

    if options.indent <= 0 {
      if spaces > 0 {
        throw MatchaError(.invalidIndent, "Indent must be greater than zero when using nested content", diagnostic: .init(line: offset + 1))
      }
    } else if options.strict, spaces % options.indent != 0 {
      throw MatchaError(.invalidIndent, "Indentation must be a multiple of \(options.indent), but found \(spaces) spaces", diagnostic: .init(line: offset + 1, column: spaces + 1))
    }

    let content = String(rawLine.dropFirst(spaces))
    parsed.append(.init(lineNumber: offset + 1, depth: options.indent == 0 ? 0 : spaces / max(options.indent, 1), content: content))
  }

  return ParsedDocument(lines: parsed, blankLines: blankLines)
}

private func isListItem(_ content: String) -> Bool {
  content == "-" || content.hasPrefix("- ")
}

private func inlineValues(after content: String) -> String? {
  guard let colonIndex = findUnquotedChar(in: content, char: ":") else { return nil }
  let rest = content[content.index(content.startIndex, offsetBy: colonIndex + 1)...].trimmingCharacters(in: .whitespaces)
  return rest.isEmpty ? nil : rest
}

private func parseArrayHeaderLine(_ content: String) throws -> ArrayHeader? {
  guard let colonIndex = findUnquotedChar(in: content, char: ":") else { return nil }
  let prefix = String(content[..<content.index(content.startIndex, offsetBy: colonIndex)])
  guard let bracketStart = findUnquotedChar(in: prefix, char: "["),
        let bracketEnd = prefix[braceIndex(prefix, offset: bracketStart)...].firstIndex(of: "]") else {
    return nil
  }

  let keyPart = String(prefix[..<prefix.index(prefix.startIndex, offsetBy: bracketStart)]).trimmingCharacters(in: .whitespaces)
  let bracketContent = String(prefix[prefix.index(prefix.startIndex, offsetBy: bracketStart + 1)..<bracketEnd])
  let remainder = String(prefix[prefix.index(after: bracketEnd)...])

  let keyToken = try parseOptionalKeyToken(keyPart)
  guard let parsedBracket = try? parseBracketSegment(bracketContent) else {
    return nil
  }

  let trimmedRemainder = remainder.trimmingCharacters(in: .whitespaces)
  let fields: [String]?
  if trimmedRemainder.isEmpty {
    fields = nil
  } else if trimmedRemainder.first == "{", trimmedRemainder.last == "}" {
    let inner = String(trimmedRemainder.dropFirst().dropLast())
    fields = try parseDelimitedValues(inner, delimiter: parsedBracket.delimiter).map(parseFieldToken(_:))
  } else {
    return nil
  }

  return ArrayHeader(
    key: keyToken?.key,
    keyWasQuoted: keyToken?.wasQuoted ?? false,
    length: parsedBracket.length,
    delimiter: parsedBracket.delimiter,
    fields: fields
  )
}

private func braceIndex(_ value: String, offset: Int) -> String.Index {
  value.index(value.startIndex, offsetBy: offset)
}

private func parseBracketSegment(_ content: String) throws -> (length: Int, delimiter: MatchaDelimiter) {
  var raw = content
  var delimiter = MatchaDelimiter.default
  if raw.hasSuffix(String(MatchaDelimiter.tab.rawValue)) {
    delimiter = .tab
    raw.removeLast()
  } else if raw.hasSuffix(String(MatchaDelimiter.pipe.rawValue)) {
    delimiter = .pipe
    raw.removeLast()
  }

  guard let length = Int(raw) else {
    throw MatchaError(.invalidHeader, "Invalid array length '\(content)'")
  }
  return (length, delimiter)
}

private func parseDelimitedValues(_ input: String, delimiter: MatchaDelimiter) -> [String] {
  var values: [String] = []
  var buffer = ""
  var inQuotes = false
  let characters = Array(input)
  var index = 0

  while index < characters.count {
    let character = characters[index]
    if character == "\\", index + 1 < characters.count, inQuotes {
      buffer.append(character)
      buffer.append(characters[index + 1])
      index += 2
      continue
    }

    if character == "\"" {
      inQuotes.toggle()
      buffer.append(character)
      index += 1
      continue
    }

    if character == delimiter.rawValue, !inQuotes {
      values.append(buffer.trimmingCharacters(in: .whitespaces))
      buffer.removeAll(keepingCapacity: true)
      index += 1
      continue
    }

    buffer.append(character)
    index += 1
  }

  if !buffer.isEmpty || !values.isEmpty {
    values.append(buffer.trimmingCharacters(in: .whitespaces))
  }

  return values
}

private func parseOptionalKeyToken(_ content: String) throws -> (key: String, wasQuoted: Bool)? {
  let trimmed = content.trimmingCharacters(in: .whitespaces)
  guard !trimmed.isEmpty else { return nil }
  if trimmed.first == "\"" {
    return try (parseStringLiteral(trimmed), true)
  }
  return (trimmed, false)
}

private func parseFieldToken(_ token: String) throws -> String {
  let trimmed = token.trimmingCharacters(in: .whitespaces)
  if trimmed.first == "\"" {
    return try parseStringLiteral(trimmed)
  }
  return trimmed
}

private func parseKeyToken(_ content: String) throws -> (key: String, end: Int, wasQuoted: Bool) {
  let characters = Array(content)
  guard let first = characters.first else {
    throw MatchaError(.missingColon, "Expected key-value pair")
  }

  if first == "\"" {
    guard let closing = findClosingQuote(in: content, start: 0) else {
      throw MatchaError(.invalidSyntax, "Unterminated quoted key")
    }
    guard closing + 1 < characters.count, characters[closing + 1] == ":" else {
      throw MatchaError(.missingColon, "Missing colon after quoted key")
    }
    let key = try parseStringLiteral(String(characters[0...closing]))
    return (key, closing + 2, true)
  }

  guard let colon = findUnquotedChar(in: content, char: ":") else {
    throw MatchaError(.missingColon, "Missing colon after key")
  }
  let key = String(characters[0..<colon]).trimmingCharacters(in: .whitespaces)
  return (key, colon + 1, false)
}

private func isKeyValueContent(_ content: String) -> Bool {
  findUnquotedChar(in: content, char: ":") != nil
}

private func parsePrimitiveToken(_ token: String) throws -> MatchaValue {
  let trimmed = token.trimmingCharacters(in: .whitespaces)
  if trimmed.isEmpty {
    return .string("")
  }
  if trimmed.first == "\"" {
    return .string(try parseStringLiteral(trimmed))
  }
  switch trimmed {
  case "true":
    return .bool(true)
  case "false":
    return .bool(false)
  case "null":
    return .null
  default:
    if MatchaNumber.isNumericLiteral(trimmed), let number = MatchaNumber(rawValue: trimmed) {
      return .number(number)
    }
    return .string(trimmed)
  }
}

private func parseStringLiteral(_ token: String) throws -> String {
  let trimmed = token.trimmingCharacters(in: .whitespaces)
  let characters = Array(trimmed)
  guard characters.first == "\"" else { return trimmed }
  guard let closing = findClosingQuote(in: trimmed, start: 0) else {
    throw MatchaError(.invalidSyntax, "Unterminated string: missing closing quote")
  }
  guard closing == characters.count - 1 else {
    throw MatchaError(.invalidSyntax, "Unexpected characters after closing quote")
  }
  let content = String(characters[1..<closing])
  return try unescapeString(content)
}

private func findClosingQuote(in content: String, start: Int) -> Int? {
  let characters = Array(content)
  var index = start + 1
  while index < characters.count {
    if characters[index] == "\\", index + 1 < characters.count {
      index += 2
      continue
    }
    if characters[index] == "\"" {
      return index
    }
    index += 1
  }
  return nil
}

private func findUnquotedChar(in content: String, char: Character) -> Int? {
  let characters = Array(content)
  var index = 0
  var inQuotes = false
  while index < characters.count {
    if characters[index] == "\\", index + 1 < characters.count, inQuotes {
      index += 2
      continue
    }
    if characters[index] == "\"" {
      inQuotes.toggle()
      index += 1
      continue
    }
    if characters[index] == char, !inQuotes {
      return index
    }
    index += 1
  }
  return nil
}

private func unescapeString(_ content: String) throws -> String {
  let characters = Array(content)
  var result = ""
  var index = 0
  while index < characters.count {
    if characters[index] == "\\" {
      guard index + 1 < characters.count else {
        throw MatchaError(.invalidEscape, "Backslash at end of string")
      }
      switch characters[index + 1] {
      case "n":
        result.append("\n")
      case "r":
        result.append("\r")
      case "t":
        result.append("\t")
      case "\\":
        result.append("\\")
      case "\"":
        result.append("\"")
      default:
        throw MatchaError(.invalidEscape, "Invalid escape sequence: \\\(characters[index + 1])")
      }
      index += 2
      continue
    }
    result.append(characters[index])
    index += 1
  }
  return result
}

private func expandPaths(_ value: MatchaValue, strict: Bool) throws -> MatchaValue {
  switch value {
  case let .array(items):
    return .array(try items.map { try expandPaths($0, strict: strict) })
  case let .object(object):
    var expanded = MatchaObject()
    for entry in object.entries {
      let expandedValue = try expandPaths(entry.value, strict: strict)
      if entry.key.contains("."), !entry.wasQuoted {
        let segments = entry.key.split(separator: ".").map(String.init)
        if segments.allSatisfy(isIdentifierSegment(_:)) {
          try insertPath(into: &expanded, segments: segments, value: expandedValue, strict: strict)
          continue
        }
      }
      try mergeEntry(into: &expanded, entry: .init(key: entry.key, value: expandedValue, wasQuoted: entry.wasQuoted), strict: strict)
    }
    return .object(expanded)
  default:
    return value
  }
}

private func insertPath(into object: inout MatchaObject, segments: [String], value: MatchaValue, strict: Bool) throws {
  guard let first = segments.first else { return }
  if segments.count == 1 {
    try mergeEntry(into: &object, entry: .init(key: first, value: value), strict: strict)
    return
  }

  let tail = Array(segments.dropFirst())
  if let index = object.entries.lastIndex(where: { $0.key == first }) {
    switch object.entries[index].value {
    case var .object(child):
      try insertPath(into: &child, segments: tail, value: value, strict: strict)
      object.entries[index].value = .object(child)
    default:
      if strict {
        throw MatchaError(.pathExpansionConflict, "Path expansion conflict at segment \"\(first)\": expected object but found \(jsonTypeDescription(object.entries[index].value))")
      }
      var child = MatchaObject()
      try insertPath(into: &child, segments: tail, value: value, strict: strict)
      object.entries[index].value = .object(child)
    }
  } else {
    var child = MatchaObject()
    try insertPath(into: &child, segments: tail, value: value, strict: strict)
    object.entries.append(.init(key: first, value: .object(child)))
  }
}

private func mergeEntry(into object: inout MatchaObject, entry: MatchaObject.Entry, strict: Bool) throws {
  if let index = object.entries.lastIndex(where: { $0.key == entry.key }) {
    switch (object.entries[index].value, entry.value) {
    case let (.object(lhs), .object(rhs)):
      var merged = lhs
      for nested in rhs.entries {
        try mergeEntry(into: &merged, entry: nested, strict: strict)
      }
      object.entries[index].value = .object(merged)
    default:
      if strict {
        throw MatchaError(.pathExpansionConflict, "Path expansion conflict at key \"\(entry.key)\": cannot merge \(jsonTypeDescription(object.entries[index].value)) with \(jsonTypeDescription(entry.value))")
      }
      object.entries[index] = entry
    }
  } else {
    object.entries.append(entry)
  }
}

private func encodeInlineArrayLine(_ values: [MatchaValue], delimiter: MatchaDelimiter, prefix: String?) -> String {
  let header = formatHeader(length: values.count, key: prefix, fields: nil, delimiter: delimiter)
  guard !values.isEmpty else { return header }
  let joined = values.map { encodePrimitive($0, delimiter: delimiter) }.joined(separator: String(delimiter.rawValue))
  return "\(header) \(joined)"
}

private func jsonTypeDescription(_ value: MatchaValue) -> String {
  switch value {
  case .object, .array, .null:
    return "object"
  case .number:
    return "number"
  case .string:
    return "string"
  case .bool:
    return "boolean"
  }
}

private func encodePrimitive(_ value: MatchaValue, delimiter: MatchaDelimiter) -> String {
  switch value {
  case let .string(value):
    return encodeStringLiteral(value, delimiter: delimiter)
  case let .number(value):
    return value.rawValue
  case let .bool(value):
    return value ? "true" : "false"
  case .null:
    return "null"
  case .array, .object:
    return "null"
  }
}

private func encodeStringLiteral(_ value: String, delimiter: MatchaDelimiter) -> String {
  if isSafeUnquoted(value, delimiter: delimiter) {
    return value
  }
  return "\"\(escapeString(value))\""
}

private func encodeKey(_ key: String) -> String {
  if isValidUnquotedKey(key) {
    return key
  }
  return "\"\(escapeString(key))\""
}

private func escapeString(_ value: String) -> String {
  value
    .replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "\"", with: "\\\"")
    .replacingOccurrences(of: "\n", with: "\\n")
    .replacingOccurrences(of: "\r", with: "\\r")
    .replacingOccurrences(of: "\t", with: "\\t")
}

private func formatHeader(length: Int, key: String?, fields: [String]?, delimiter: MatchaDelimiter) -> String {
  var header = ""
  if let key {
    header += encodeKey(key)
  }
  header += "[\(length)\(delimiter == .comma ? "" : String(delimiter.rawValue))]"
  if let fields {
    header += "{\(fields.map(encodeKey(_:)).joined(separator: String(delimiter.rawValue)))}"
  }
  header += ":"
  return header
}

private func indented(_ depth: Int, _ content: String, width: Int) -> String {
  String(repeating: " ", count: max(depth, 0) * max(width, 0)) + content
}

private func isValidUnquotedKey(_ key: String) -> Bool {
  guard let first = key.utf8.first else { return false }
  guard isIdentifierStartASCII(first) else { return false }
  for byte in key.utf8.dropFirst() {
    guard isIdentifierBodyASCII(byte) || byte == asciiPeriod else { return false }
  }
  return true
}

private func isIdentifierSegment(_ key: String) -> Bool {
  guard let first = key.utf8.first else { return false }
  guard isIdentifierStartASCII(first) else { return false }
  for byte in key.utf8.dropFirst() {
    guard isIdentifierBodyASCII(byte) else { return false }
  }
  return true
}

private func isSafeUnquoted(_ value: String, delimiter: MatchaDelimiter) -> Bool {
  guard !value.isEmpty else { return false }
  guard value == value.trimmingCharacters(in: .whitespaces) else { return false }
  guard !["true", "false", "null"].contains(value) else { return false }
  guard !looksNumericLike(value) else { return false }
  guard !value.contains(":") else { return false }
  guard !value.contains("\""), !value.contains("\\") else { return false }
  guard !value.contains(where: { character in
    character == "[" || character == "]" || character == "{" || character == "}" || character == "\n" || character == "\r" || character == "\t"
  }) else { return false }
  guard !value.contains(delimiter.rawValue) else { return false }
  guard !value.hasPrefix("-") else { return false }
  return true
}

private func looksNumericLike(_ value: String) -> Bool {
  isNumericLiteralASCII(value)
    || hasLeadingZeroIntegerASCII(value)
}

private let asciiPeriod: UInt8 = 46
private let asciiUnderscore: UInt8 = 95

private func isIdentifierStartASCII(_ byte: UInt8) -> Bool {
  (65...90).contains(byte) || (97...122).contains(byte) || byte == asciiUnderscore
}

private func isIdentifierBodyASCII(_ byte: UInt8) -> Bool {
  isIdentifierStartASCII(byte) || (48...57).contains(byte)
}

private func isNumericLiteralASCII(_ value: String) -> Bool {
  let bytes = Array(value.utf8)
  guard !bytes.isEmpty else { return false }

  var index = 0
  if bytes[index] == 45 { // '-'
    index += 1
    guard index < bytes.count else { return false }
  }

  guard scanDigits(bytes, index: &index, requireAtLeastOne: true) else { return false }

  if index < bytes.count, bytes[index] == 46 { // '.'
    index += 1
    guard scanDigits(bytes, index: &index, requireAtLeastOne: true) else { return false }
  }

  if index < bytes.count, bytes[index] == 101 || bytes[index] == 69 { // e/E
    index += 1
    guard index < bytes.count else { return false }
    if bytes[index] == 43 || bytes[index] == 45 { // +/- 
      index += 1
      guard index < bytes.count else { return false }
    }
    guard scanDigits(bytes, index: &index, requireAtLeastOne: true) else { return false }
  }

  return index == bytes.count
}

private func hasLeadingZeroIntegerASCII(_ value: String) -> Bool {
  let bytes = Array(value.utf8)
  guard bytes.count >= 2 else { return false }

  var index = 0
  if bytes[index] == 45 { // '-'
    index += 1
  }
  guard index + 1 < bytes.count else { return false }
  guard bytes[index] == 48 else { return false }
  return bytes[(index + 1)...].allSatisfy { (48...57).contains($0) }
}

private func scanDigits(_ bytes: [UInt8], index: inout Int, requireAtLeastOne: Bool) -> Bool {
  let start = index
  while index < bytes.count, (48...57).contains(bytes[index]) {
    index += 1
  }
  return requireAtLeastOne ? index > start : true
}
