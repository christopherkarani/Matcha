import Foundation
import Matcha

struct BenchmarkOptions {
  var loops = 1_000
  var scale = 250
}

let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
let sample = makeSample(scale: options.scale)
let encoder = MatchaEncoder()
let decoder = MatchaDecoder()

let encodeStart = DispatchTime.now().uptimeNanoseconds
var encoded = ""
for _ in 0..<options.loops {
  encoded = try encoder.encode(sample)
}
let encodeElapsed = Double(DispatchTime.now().uptimeNanoseconds - encodeStart) / 1_000_000

let streamEncodeStart = DispatchTime.now().uptimeNanoseconds
var streamedBytes = 0
for _ in 0..<options.loops {
  streamedBytes = 0
  try encoder.encodeLines(sample) { line in
    streamedBytes += line.utf8.count + 1
  }
}
let streamEncodeElapsed = Double(DispatchTime.now().uptimeNanoseconds - streamEncodeStart) / 1_000_000

let decodeStart = DispatchTime.now().uptimeNanoseconds
for _ in 0..<options.loops {
  _ = try decoder.decode(encoded)
}
let decodeElapsed = Double(DispatchTime.now().uptimeNanoseconds - decodeStart) / 1_000_000

let eventDecodeStart = DispatchTime.now().uptimeNanoseconds
let encodedLines = encoded.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
var eventCount = 0
for _ in 0..<options.loops {
  eventCount = 0
  try decoder.decodeEvents(encodedLines) { _ in
    eventCount += 1
  }
}
let eventDecodeElapsed = Double(DispatchTime.now().uptimeNanoseconds - eventDecodeStart) / 1_000_000

let payloadBytes = encoded.utf8.count
let encodeThroughput = throughputMiBPerSecond(bytes: payloadBytes * options.loops, elapsedMilliseconds: encodeElapsed)
let streamEncodeThroughput = throughputMiBPerSecond(bytes: payloadBytes * options.loops, elapsedMilliseconds: streamEncodeElapsed)
let decodeThroughput = throughputMiBPerSecond(bytes: payloadBytes * options.loops, elapsedMilliseconds: decodeElapsed)
let eventDecodeThroughput = throughputMiBPerSecond(bytes: payloadBytes * options.loops, elapsedMilliseconds: eventDecodeElapsed)

print("TOON Swift benchmark")
print("loops: \(options.loops)")
print("scale: \(options.scale) rows")
print("payload: \(payloadBytes) bytes")
print("encode \(options.loops)x: \(String(format: "%.2f", encodeElapsed)) ms (\(String(format: "%.2f", encodeThroughput)) MiB/s)")
print("stream encode \(options.loops)x: \(String(format: "%.2f", streamEncodeElapsed)) ms (\(String(format: "%.2f", streamEncodeThroughput)) MiB/s)")
print("decode \(options.loops)x: \(String(format: "%.2f", decodeElapsed)) ms (\(String(format: "%.2f", decodeThroughput)) MiB/s)")
print("event decode \(options.loops)x: \(String(format: "%.2f", eventDecodeElapsed)) ms (\(String(format: "%.2f", eventDecodeThroughput)) MiB/s, last run \(eventCount) events)")

private func parseOptions(_ arguments: [String]) throws -> BenchmarkOptions {
  var options = BenchmarkOptions()
  var index = 0

  while index < arguments.count {
    switch arguments[index] {
    case "--loops":
      index += 1
      guard index < arguments.count, let loops = Int(arguments[index]), loops > 0 else {
        throw MatchaError(.invalidArgument, "Benchmark loops must be a positive integer")
      }
      options.loops = loops
    case "--scale":
      index += 1
      guard index < arguments.count, let scale = Int(arguments[index]), scale > 0 else {
        throw MatchaError(.invalidArgument, "Benchmark scale must be a positive integer")
      }
      options.scale = scale
    case "-h", "--help":
      print("""
      MatchaBenchmarks

      Options:
        --loops <n>   Number of encode/decode iterations (default: 1000)
        --scale <n>   Number of synthetic rows in the sample payload (default: 250)
      """)
      Foundation.exit(0)
    default:
      throw MatchaError(.invalidArgument, "Unknown benchmark argument '\(arguments[index])'")
    }
    index += 1
  }

  return options
}

private func makeSample(scale: Int) -> MatchaValue {
  let context = MatchaObject(entries: [
    .init(key: "task", value: "favorite hikes"),
    .init(key: "location", value: "Boulder"),
    .init(key: "season", value: "spring_2025"),
    .init(key: "generator", value: "swift_benchmark"),
  ])
  let companions = ["ana", "luis", "sam", "mei"]
  let hikes: [MatchaValue] = (0..<scale).map { index in
    let distance = MatchaNumber(rawValue: String(format: "%.1f", 5.0 + Double(index) * 0.1))!
    let row = MatchaObject(entries: [
      .init(key: "id", value: .number(MatchaNumber(rawValue: String(index + 1))!)),
      .init(key: "name", value: .string("Trail \(index + 1)")),
      .init(key: "distanceKm", value: .number(distance)),
      .init(key: "companion", value: .string(companions[index % companions.count])),
    ])
    return .object(row)
  }

  let root = MatchaObject(entries: [
    .init(key: "context", value: .object(context)),
    .init(key: "friends", value: .array(companions.map(MatchaValue.string))),
    .init(key: "hikes", value: .array(hikes)),
  ])
  return .object(root)
}

private func throughputMiBPerSecond(bytes: Int, elapsedMilliseconds: Double) -> Double {
  guard elapsedMilliseconds > 0 else { return 0 }
  let seconds = elapsedMilliseconds / 1_000
  return Double(bytes) / (1024 * 1024) / seconds
}
