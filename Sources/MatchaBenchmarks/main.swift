import Foundation
import Matcha

struct BenchmarkOptions {
  enum Scenario: String {
    case synthetic
    case swarmArtifacts = "swarm-artifacts"
  }

  var loops = 1_000
  var scale = 250
  var scenario: Scenario = .synthetic
}

let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))

switch options.scenario {
case .synthetic:
  try runSyntheticBenchmark(options: options)
case .swarmArtifacts:
  try runSwarmArtifactBenchmark(options: options)
}

private func runSyntheticBenchmark(options: BenchmarkOptions) throws {
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
  print("scenario: synthetic")
  print("loops: \(options.loops)")
  print("scale: \(options.scale) rows")
  print("payload: \(payloadBytes) bytes")
  print("encode \(options.loops)x: \(String(format: "%.2f", encodeElapsed)) ms (\(String(format: "%.2f", encodeThroughput)) MiB/s)")
  print("stream encode \(options.loops)x: \(String(format: "%.2f", streamEncodeElapsed)) ms (\(String(format: "%.2f", streamEncodeThroughput)) MiB/s)")
  print("decode \(options.loops)x: \(String(format: "%.2f", decodeElapsed)) ms (\(String(format: "%.2f", decodeThroughput)) MiB/s)")
  print("event decode \(options.loops)x: \(String(format: "%.2f", eventDecodeElapsed)) ms (\(String(format: "%.2f", eventDecodeThroughput)) MiB/s, last run \(eventCount) events)")
}

private func runSwarmArtifactBenchmark(options: BenchmarkOptions) throws {
  let encoder = MatchaEncoder()
  let decoder = MatchaDecoder()
  let jsonEncoder = JSONEncoder()
  jsonEncoder.outputFormatting = [.sortedKeys]
  let jsonDecoder = JSONDecoder()

  let artifacts: [ArtifactCase] = [
    .init(name: "WebSearchEvidenceRecord", encode: { try jsonEncoder.encode(makeEvidenceRecord()) }, matchaEncode: { try encoder.encode(makeEvidenceRecord()) }, matchaDecode: { input in _ = try decoder.decode(WebSearchEvidenceRecord.self, from: input) }, jsonDecode: { data in _ = try jsonDecoder.decode(WebSearchEvidenceRecord.self, from: data) }),
    .init(name: "EvidenceBundleRecord", encode: { try jsonEncoder.encode(makeEvidenceBundle()) }, matchaEncode: { try encoder.encode(makeEvidenceBundle()) }, matchaDecode: { input in _ = try decoder.decode(EvidenceBundleRecord.self, from: input) }, jsonDecode: { data in _ = try jsonDecoder.decode(EvidenceBundleRecord.self, from: data) }),
    .init(name: "WebSearchEnvelope", encode: { try jsonEncoder.encode(makeEnvelope()) }, matchaEncode: { try encoder.encode(makeEnvelope()) }, matchaDecode: { input in _ = try decoder.decode(WebSearchEnvelope.self, from: input) }, jsonDecode: { data in _ = try jsonDecoder.decode(WebSearchEnvelope.self, from: data) }),
  ]

  print("TOON Swift benchmark")
  print("scenario: swarm-artifacts")
  print("loops: \(options.loops)")
  print("")
  print("+-------------------------+-----------+-------------+------------------+--------------------+")
  print("| Artifact                | JSON bytes| Matcha bytes| JSON enc/dec ms  | Matcha enc/dec ms  |")
  print("+-------------------------+-----------+-------------+------------------+--------------------+")

  for artifact in artifacts {
    let jsonData = try artifact.encode()
    let matcha = try artifact.matchaEncode()

    let jsonEncodeMs = try measureMilliseconds(loops: options.loops) {
      _ = try artifact.encode()
    }
    let jsonDecodeMs = try measureMilliseconds(loops: options.loops) {
      try artifact.jsonDecode(jsonData)
    }
    let matchaEncodeMs = try measureMilliseconds(loops: options.loops) {
      _ = try artifact.matchaEncode()
    }
    let matchaDecodeMs = try measureMilliseconds(loops: options.loops) {
      try artifact.matchaDecode(matcha)
    }

    print(
      "| \(pad(artifact.name, to: 23)) | \(pad(String(jsonData.count), to: 9, left: true)) | \(pad(String(matcha.utf8.count), to: 11, left: true)) | \(pad(String(format: "%.2f / %.2f", jsonEncodeMs, jsonDecodeMs), to: 16, left: true)) | \(pad(String(format: "%.2f / %.2f", matchaEncodeMs, matchaDecodeMs), to: 18, left: true)) |"
    )
  }
  print("+-------------------------+-----------+-------------+------------------+--------------------+")
}

private struct ArtifactCase {
  let name: String
  let encode: () throws -> Data
  let matchaEncode: () throws -> String
  let matchaDecode: (String) throws -> Void
  let jsonDecode: (Data) throws -> Void
}

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
    case "--scenario":
      index += 1
      guard index < arguments.count, let scenario = BenchmarkOptions.Scenario(rawValue: arguments[index]) else {
        throw MatchaError(.invalidArgument, "Scenario must be 'synthetic' or 'swarm-artifacts'")
      }
      options.scenario = scenario
    case "-h", "--help":
      print("""
      MatchaBenchmarks

      Options:
        --loops <n>       Number of encode/decode iterations (default: 1000)
        --scale <n>       Number of synthetic rows in the sample payload (default: 250)
        --scenario <id>   synthetic | swarm-artifacts
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

private func measureMilliseconds(loops: Int, work: () throws -> Void) rethrows -> Double {
  let start = DispatchTime.now().uptimeNanoseconds
  for _ in 0..<loops {
    try work()
  }
  let elapsed = DispatchTime.now().uptimeNanoseconds - start
  return Double(elapsed) / 1_000_000
}

private func pad(_ value: String, to width: Int, left: Bool = false) -> String {
  if value.count >= width { return value }
  let padding = String(repeating: " ", count: width - value.count)
  return left ? padding + value : value + padding
}

private struct WebSearchEvidenceRecord: Codable {
  struct Hit: Codable {
    var title: String
    var url: String
    var snippet: String
    var domain: String
    var score: Double
  }

  var id: String
  var query: String
  var mode: String
  var summary: String
  var semanticCore: String?
  var primaryHit: Hit?
  var supportingHits: [Hit]
  var citations: [CitationRecord]
  var artifactRefs: [String]
  var bundleID: String?
  var createdAt: Date
  var rawPayloadRef: String?
}

private struct WebSearchHit: Codable {
  var id: String
  var title: String
  var url: String
  var snippet: String
  var score: Double
  var source: String
  var cached: Bool
  var artifactID: String?
}

private struct CitationRecord: Codable {
  var artifactID: String
  var sectionID: String
  var url: String
  var title: String
  var snippet: String
}

private struct WebSectionChunk: Codable {
  var id: String
  var artifactID: String
  var heading: String
  var text: String
  var index: Int
  var pageType: String
  var citations: [CitationRecord]
}

private struct WebArtifactRecord: Codable {
  var artifactID: String
  var canonicalURL: String
  var title: String
  var contentType: String
  var fetchedAt: Date
  var contentHash: String
  var etag: String?
  var lastModified: String?
  var pageType: String
  var hostTrust: String
  var freshnessScore: Double
  var rawArtifactRef: String
}

private struct NormalizedWebDocument: Codable {
  var artifactID: String
  var canonicalURL: String
  var title: String
  var summary: String
  var pageType: String
  var contentType: String
  var fetchedAt: Date
  var sections: [WebSectionChunk]
}

private struct GroundedEvidence: Codable {
  var query: String
  var answer: String
  var evidenceSections: [WebSectionChunk]
  var citations: [CitationRecord]
  var bundleID: String?
}

private struct EvidenceBundleRecord: Codable {
  var bundleID: String
  var query: String
  var artifactIDs: [String]
  var sectionIDs: [String]
  var summary: String
  var createdAt: Date
  var updatedAt: Date
}

private struct WebSearchEnvelope: Codable {
  var mode: String
  var summary: String
  var final4KAnswer: String
  var semanticCore: String?
  var hits: [WebSearchHit]
  var artifact: WebArtifactRecord?
  var normalizedDocument: NormalizedWebDocument?
  var sectionChunks: [WebSectionChunk]
  var groundedEvidence: GroundedEvidence?
  var citations: [CitationRecord]
  var artifactRefs: [String]
  var bundle: EvidenceBundleRecord?
  var cacheStatus: String
  var rawArtifactRef: String?
}

private func makeEvidenceRecord() -> WebSearchEvidenceRecord {
  let primary = WebSearchEvidenceRecord.Hit(
    title: "Managing the on-device foundation model's context window",
    url: "https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window",
    snippet: "Apple documents that LanguageModelSession throws exceededContextWindowSize when the active transcript grows past the system model budget and recommends breaking work into smaller grounded steps.",
    domain: "developer.apple.com",
    score: 0.98
  )

  let supportOne = WebSearchEvidenceRecord.Hit(
    title: "LanguageModelSession",
    url: "https://developer.apple.com/documentation/foundationmodels/languagemodelsession",
    snippet: "The session API supports guided generation, tool calling, and transcript-driven continuation for app-scale tasks on device.",
    domain: "developer.apple.com",
    score: 0.93
  )

  let supportTwo = WebSearchEvidenceRecord.Hit(
    title: "Introducing Apple Foundation Models",
    url: "https://machinelearning.apple.com/research/introducing-apple-foundation-models",
    snippet: "Apple frames the on-device model as a three-billion-parameter system optimized for device-scale tasks rather than frontier world knowledge.",
    domain: "machinelearning.apple.com",
    score: 0.88
  )

  return WebSearchEvidenceRecord(
    id: "evidence-apple-context-window",
    query: "Apple Foundation Models context window",
    mode: "search",
    summary: "The most relevant source is Apple's context-window technote, backed by Foundation Models session docs and Apple ML background material.",
    semanticCore: "Foundation Models has a hard context window, tool loops should be decomposed, and grounded evidence should be preserved outside the active prompt.",
    primaryHit: primary,
    supportingHits: [supportOne, supportTwo],
    citations: makeCitations(),
    artifactRefs: ["artifact-tn3193", "artifact-lmsession", "artifact-intro"],
    bundleID: "bundle-foundation-models-context",
    createdAt: makeDate(),
    rawPayloadRef: "raw-websearch-payload-apple-context"
  )
}

private func makeEvidenceBundle() -> EvidenceBundleRecord {
  EvidenceBundleRecord(
    bundleID: "bundle-ronaldo-research-career",
    query: "Cristiano Ronaldo club career records and milestones",
    artifactIDs: [
      "artifact-britannica-ronaldo",
      "artifact-uefa-ronaldo-records",
      "artifact-fifa-ronaldo-profile",
      "artifact-guinness-ronaldo",
    ],
    sectionIDs: [
      "section-early-life",
      "section-united-and-madrid",
      "section-juventus-and-return",
      "section-saudi-era",
    ],
    summary: "Bundle covers Ronaldo's progression from Sporting CP to Manchester United, Real Madrid, Juventus, and Al Nassr, with milestone and record references suitable for a grounded long-form profile.",
    createdAt: makeDate(),
    updatedAt: makeDate()
  )
}

private func makeEnvelope() -> WebSearchEnvelope {
  let citations = makeCitations()
  let sections = makeSections(citations: citations)
  let artifact = WebArtifactRecord(
    artifactID: "artifact-tn3193",
    canonicalURL: "https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window",
    title: "Managing the on-device foundation model's context window",
    contentType: "text/html",
    fetchedAt: makeDate(),
    contentHash: "sha256:foundation-models-context-window",
    etag: "W/tn3193",
    lastModified: "Wed, 09 Apr 2026 10:00:00 GMT",
    pageType: "docs",
    hostTrust: "officialDocs",
    freshnessScore: 0.97,
    rawArtifactRef: "raw-tn3193"
  )

  let document = NormalizedWebDocument(
    artifactID: artifact.artifactID,
    canonicalURL: artifact.canonicalURL,
    title: artifact.title,
    summary: "Apple explains the system model context window, the exceededContextWindowSize failure mode, and the need to break multi-step work into smaller grounded tasks.",
    pageType: "docs",
    contentType: artifact.contentType,
    fetchedAt: artifact.fetchedAt,
    sections: sections
  )

  let grounded = GroundedEvidence(
    query: "How can Swarm keep Foundation Models alive across many websearch calls?",
    answer: "Keep raw search payloads out of the live prompt, store durable evidence separately, and repack only answer-critical evidence into the strict4k working window.",
    evidenceSections: sections,
    citations: citations,
    bundleID: "bundle-foundation-models-context"
  )

  return WebSearchEnvelope(
    mode: "search",
    summary: "Apple's docs establish the hard context-window limit while the session docs describe the structured generation primitives Swarm can build on.",
    final4KAnswer: "Foundation Models has a hard 4K class budget, so long tool loops require durable evidence storage, overlap-aware context packing, and aggressive prompt compaction.",
    semanticCore: "Membrane should keep tool payloads compact; ContextCore should repack answer-critical evidence; Wax should persist raw artifacts and recall them later.",
    hits: [
      WebSearchHit(
        id: "hit-tn3193",
        title: artifact.title,
        url: artifact.canonicalURL,
        snippet: "Apple explicitly documents exceededContextWindowSize and recommends smaller tasks and structured continuation.",
        score: 0.98,
        source: "tavily",
        cached: false,
        artifactID: artifact.artifactID
      ),
      WebSearchHit(
        id: "hit-lmsession",
        title: "LanguageModelSession",
        url: "https://developer.apple.com/documentation/foundationmodels/languagemodelsession",
        snippet: "The session API provides guided generation and tool calling for on-device workflows.",
        score: 0.94,
        source: "tavily",
        cached: true,
        artifactID: "artifact-lmsession"
      ),
      WebSearchHit(
        id: "hit-intro",
        title: "Introducing Apple Foundation Models",
        url: "https://machinelearning.apple.com/research/introducing-apple-foundation-models",
        snippet: "Apple positions the 3B on-device model as optimized for device-scale generation tasks.",
        score: 0.89,
        source: "tavily",
        cached: true,
        artifactID: "artifact-intro"
      ),
    ],
    artifact: artifact,
    normalizedDocument: document,
    sectionChunks: sections,
    groundedEvidence: grounded,
    citations: citations,
    artifactRefs: [
      "artifact-tn3193",
      "artifact-lmsession",
      "artifact-intro",
    ],
    bundle: makeEvidenceBundle(),
    cacheStatus: "mixed",
    rawArtifactRef: artifact.rawArtifactRef
  )
}

private func makeCitations() -> [CitationRecord] {
  [
    CitationRecord(
      artifactID: "artifact-tn3193",
      sectionID: "section-context-limit",
      url: "https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window",
      title: "Managing the on-device foundation model's context window",
      snippet: "LanguageModelSession throws exceededContextWindowSize when the transcript exceeds the model budget."
    ),
    CitationRecord(
      artifactID: "artifact-lmsession",
      sectionID: "section-languagemodelsession",
      url: "https://developer.apple.com/documentation/foundationmodels/languagemodelsession",
      title: "LanguageModelSession",
      snippet: "Foundation Models sessions expose tool calling and transcript continuation APIs."
    ),
    CitationRecord(
      artifactID: "artifact-intro",
      sectionID: "section-apple-ml",
      url: "https://machinelearning.apple.com/research/introducing-apple-foundation-models",
      title: "Introducing Apple Foundation Models",
      snippet: "Apple describes the system model as a three-billion-parameter on-device model."
    ),
  ]
}

private func makeSections(citations: [CitationRecord]) -> [WebSectionChunk] {
  [
    WebSectionChunk(
      id: "section-context-limit",
      artifactID: "artifact-tn3193",
      heading: "Context Window Limits",
      text: "Apple's technote describes how Foundation Models sessions can exceed the active context window and recommends narrowing tasks, tightening prompts, and decomposing work into grounded steps rather than replaying large transcripts.",
      index: 0,
      pageType: "docs",
      citations: [citations[0]]
    ),
    WebSectionChunk(
      id: "section-languagemodelsession",
      artifactID: "artifact-lmsession",
      heading: "Session and Tool Continuation",
      text: "LanguageModelSession provides the structured runtime surface for guided generation, transcript handling, and tool calling. These APIs are strong primitives, but they do not by themselves solve long-horizon evidence retention under a 4K-style budget.",
      index: 1,
      pageType: "apiReference",
      citations: [citations[1]]
    ),
    WebSectionChunk(
      id: "section-apple-ml",
      artifactID: "artifact-intro",
      heading: "Model Scope",
      text: "Apple frames the model as optimized for device-scale tasks rather than general world knowledge. That makes external retrieval and evidence curation mandatory for serious research use cases.",
      index: 2,
      pageType: "docs",
      citations: [citations[2]]
    ),
  ]
}

private func makeDate() -> Date {
  Date(timeIntervalSince1970: 1_775_728_800)
}
