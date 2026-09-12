import AudoraCodexCLIQualification
import Foundation

private struct Options {
    var executablePath = "/opt/homebrew/bin/codex"
    var model = "gpt-5.4"
}

private enum ArgumentError: Error {
    case invalid
}

private func parseOptions(_ arguments: [String]) throws -> Options {
    var options = Options()
    var index = 0
    while index < arguments.count {
        switch arguments[index] {
        case "--codex":
            guard index + 1 < arguments.count else { throw ArgumentError.invalid }
            options.executablePath = arguments[index + 1]
            index += 2
        case "--model":
            guard index + 1 < arguments.count else { throw ArgumentError.invalid }
            options.model = arguments[index + 1]
            index += 2
        case "--help", "-h":
            printUsage()
            exit(0)
        default:
            throw ArgumentError.invalid
        }
    }
    return options
}

private func printUsage() {
    print(
        "Usage: codex-cli-qualification [--codex /absolute/path] [--model allowlisted-model]"
    )
}

do {
    let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
    guard options.executablePath.hasPrefix("/") else { throw ArgumentError.invalid }

    let harness = CodexCLIQualificationHarness()
    let report = try harness.runSuite(
        executableURL: URL(fileURLWithPath: options.executablePath),
        model: options.model
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(report))
    FileHandle.standardOutput.write(Data("\n".utf8))

    let commandSucceeded = QualificationCommandExitPolicy.succeeded(
        report: report,
        ranFullSuite: true
    )
    exit(commandSucceeded ? 0 : 1)
} catch {
    FileHandle.standardError.write(
        Data("Qualification could not start. No provider details were emitted.\n".utf8)
    )
    printUsage()
    exit(64)
}
