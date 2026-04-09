import Foundation
import Matcha

private enum Mode {
  case encode
  case decode
}

private struct CLIOptions {
  var inputPath: String?
  var outputPath: String?
  var encode = false
  var decode = false
  var delimiter: MatchaDelimiter = .default
  var indent = 2
  var strict = true
  var keyFolding: MatchaKeyFolding = .off
  var flattenDepth = Int.max
  var expandPaths: MatchaPathExpansion = .off
  var stats = false
}

@main
struct MatchaCLI {
  static func main() {
    do {
      let options = try parseArguments(Array(CommandLine.arguments.dropFirst()))
      try run(options)
    } catch {
      fputs("\(error)\n", stderr)
      Foundation.exit(1)
    }
  }

  private static func run(_ options: CLIOptions) throws {
    let mode = detectMode(options)
    switch mode {
    case .encode:
      let input = try readInput(from: options.inputPath)
      let value = try MatchaValue.parseJSON(input)
      let encoder = MatchaEncoder(options: .init(
        indent: options.indent,
        delimiter: options.delimiter,
        keyFolding: options.keyFolding,
        flattenDepth: options.flattenDepth
      ))
      let outputBytes = try writeEncodedOutput(encoder: encoder, value: value, to: options.outputPath)
      if let outputPath = options.outputPath, let inputPath = options.inputPath {
        print("✔ Encoded \(inputPath) → \(outputPath)")
      }
      if options.stats {
        let inputBytes = input.utf8.count
        let jsonTokens = estimateTokenCount(input)
        let toonTokens = estimateTokenCount(fromUTF8ByteCount: outputBytes)
        let saved = jsonTokens - toonTokens
        let byteSavings = inputBytes - outputBytes
        let percent = jsonTokens == 0 ? 0 : (Double(saved) / Double(jsonTokens)) * 100
        let bytePercent = inputBytes == 0 ? 0 : (Double(byteSavings) / Double(inputBytes)) * 100
        fputs("\nJSON bytes: \(inputBytes) -> TOON bytes: \(outputBytes)\n", stderr)
        fputs("Saved \(byteSavings) bytes (\(String(format: "%.1f", bytePercent))%)\n", stderr)
        fputs("Approx. token estimate: ~\(jsonTokens) -> ~\(toonTokens), saved ~\(saved) (\(String(format: "%.1f", percent))%)\n", stderr)
      }
    case .decode:
      let input = try readInput(from: options.inputPath)
      let decoder = MatchaDecoder(options: .init(
        indent: options.indent,
        strict: options.strict,
        expandPaths: options.expandPaths
      ))
      let value = try decoder.decode(input)
      try writeOutput(value.jsonString(indentedBy: options.indent), to: options.outputPath)
      if let outputPath = options.outputPath, let inputPath = options.inputPath {
        print("✔ Decoded \(inputPath) → \(outputPath)")
      }
    }
  }

  private static func parseArguments(_ arguments: [String]) throws -> CLIOptions {
    var options = CLIOptions()
    var index = 0

    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "-h", "--help":
        printHelp()
        Foundation.exit(0)
      case "-o", "--output":
        index += 1
        guard index < arguments.count else {
          throw MatchaError(.invalidArgument, "Missing output path")
        }
        options.outputPath = arguments[index]
      case "-e", "--encode":
        options.encode = true
      case "-d", "--decode":
        options.decode = true
      case "--delimiter":
        index += 1
        guard index < arguments.count else {
          throw MatchaError(.invalidArgument, "Missing delimiter value")
        }
        options.delimiter = try parseDelimiter(arguments[index])
      case "--indent":
        index += 1
        guard index < arguments.count, let indent = Int(arguments[index]) else {
          throw MatchaError(.invalidArgument, "Indent must be an integer")
        }
        options.indent = indent
      case "--stats":
        options.stats = true
      case "--no-strict":
        options.strict = false
      case "--keyFolding":
        index += 1
        guard index < arguments.count, let mode = MatchaKeyFolding(rawValue: arguments[index]) else {
          throw MatchaError(.invalidArgument, "keyFolding must be 'off' or 'safe'")
        }
        options.keyFolding = mode
      case "--flattenDepth":
        index += 1
        guard index < arguments.count, let depth = Int(arguments[index]) else {
          throw MatchaError(.invalidArgument, "flattenDepth must be an integer")
        }
        options.flattenDepth = depth
      case "--expandPaths":
        index += 1
        guard index < arguments.count, let mode = MatchaPathExpansion(rawValue: arguments[index]) else {
          throw MatchaError(.invalidArgument, "expandPaths must be 'off' or 'safe'")
        }
        options.expandPaths = mode
      default:
        if options.inputPath == nil {
          options.inputPath = argument == "-" ? nil : argument
        } else {
          throw MatchaError(.invalidArgument, "Unexpected argument '\(argument)'")
        }
      }
      index += 1
    }

    if options.encode && options.decode {
      throw MatchaError(.invalidArgument, "Choose either --encode or --decode, not both")
    }

    return options
  }

  private static func detectMode(_ options: CLIOptions) -> Mode {
    if options.encode { return .encode }
    if options.decode { return .decode }
    guard let input = options.inputPath else { return .encode }
    return input.hasSuffix(".toon") ? .decode : .encode
  }

  private static func parseDelimiter(_ raw: String) throws -> MatchaDelimiter {
    switch raw {
    case ",":
      return .comma
    case "\\t", "\t":
      return .tab
    case "|":
      return .pipe
    default:
      throw MatchaError(.invalidArgument, "Delimiter must be ',', '\\t', or '|'")
    }
  }

  private static func readInput(from path: String?) throws -> String {
    if let path {
      return try String(contentsOfFile: path, encoding: .utf8)
    }
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let text = String(data: data, encoding: .utf8) else {
      throw MatchaError(.invalidArgument, "Input must be UTF-8")
    }
    return text
  }

  private static func writeOutput(_ output: String, to path: String?) throws {
    if let path {
      try output.write(toFile: path, atomically: true, encoding: .utf8)
    } else {
      FileHandle.standardOutput.write(Data((output + "\n").utf8))
    }
  }

  @discardableResult
  private static func writeEncodedOutput(encoder: MatchaEncoder, value: MatchaValue, to path: String?) throws -> Int {
    let handle: FileHandle
    let shouldClose: Bool

    if let path {
      FileManager.default.createFile(atPath: path, contents: nil)
      guard let fileHandle = FileHandle(forWritingAtPath: path) else {
        throw MatchaError(.invalidArgument, "Unable to open output path '\(path)' for writing")
      }
      handle = fileHandle
      shouldClose = true
    } else {
      handle = FileHandle.standardOutput
      shouldClose = false
    }

    defer {
      if shouldClose {
        handle.closeFile()
      }
    }

    var isFirstLine = true
    var outputBytes = 0
    try encoder.encodeLines(value) { line in
      let prefix = isFirstLine ? "" : "\n"
      let chunk = prefix + line
      outputBytes += chunk.utf8.count
      handle.write(Data(chunk.utf8))
      isFirstLine = false
    }

    handle.write(Data("\n".utf8))
    return outputBytes
  }

  private static func estimateTokenCount(_ text: String) -> Int {
    estimateTokenCount(fromUTF8ByteCount: text.utf8.count)
  }

  private static func estimateTokenCount(fromUTF8ByteCount byteCount: Int) -> Int {
    max(1, Int(ceil(Double(byteCount) / 4.0)))
  }

  private static func printHelp() {
    let help = """
    matcha - Pure Swift TOON CLI

    Usage:
      matcha [input] [options]

    Options:
      -e, --encode           Force JSON -> TOON
      -d, --decode           Force TOON -> JSON
      -o, --output <path>    Write output to file
      --delimiter <char>     Array delimiter: ',', '\\t', '|'
      --indent <n>           Indentation width (default: 2)
      --no-strict            Disable strict TOON validation
      --keyFolding <mode>    Key folding: off | safe
      --flattenDepth <n>     Key folding depth limit
      --expandPaths <mode>   Path expansion: off | safe
      --stats                Print byte stats plus a rough token estimate for encode
      -h, --help             Show this help

    Input:
      Omit input or pass '-' to read from stdin.
      Without --encode/--decode, '.toon' implies decode and everything else implies encode.
    """
    print(help)
  }
}
