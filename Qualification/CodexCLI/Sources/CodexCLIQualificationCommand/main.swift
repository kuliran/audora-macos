import AudoraCodexCLIQualification
import Foundation

private struct Options {
    enum Mode {
        case preflight
        case execute
    }

    var executablePath = "/opt/homebrew/bin/codex"
    var model = "gpt-5.4"
    var mode = Mode.preflight
}

private enum ArgumentError: Error {
    case invalid
}

private func parseOptions(_ arguments: [String]) throws -> Options {
    var options = Options()
    var explicitMode: Options.Mode?
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
        case "--preflight":
            guard explicitMode == nil else { throw ArgumentError.invalid }
            explicitMode = .preflight
            options.mode = .preflight
            index += 1
        case "--execute":
            guard explicitMode == nil else { throw ArgumentError.invalid }
            explicitMode = .execute
            options.mode = .execute
            index += 1
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
        "Usage: codex-cli-qualification [--preflight | --execute] " +
            "[--codex /absolute/path] [--model allowlisted-model]"
    )
}

private func writeJSON<T: Encodable>(_ value: T) -> Bool {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(value) else { return false }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
    return true
}

do {
    let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
    guard options.executablePath.hasPrefix("/") else { throw ArgumentError.invalid }

    let harness = CodexCLIQualificationHarness()
    let executableURL = URL(fileURLWithPath: options.executablePath)
    switch options.mode {
    case .preflight:
        let report = try harness.preflight(
            executableURL: executableURL,
            model: options.model
        )
        guard writeJSON(report) else { throw ArgumentError.invalid }
        exit(report.providerLaunchPermitted ? 0 : 1)
    case .execute:
        guard let authorization = CodexCLIQualificationExecutionAuthorization()
        else {
            throw CodexCLIQualificationStartError
                .sameProcessAuthorizationUnavailable
        }
        let report = try harness.runSuite(
            executableURL: executableURL,
            model: options.model,
            authorization: authorization
        )
        guard writeJSON(report) else { throw ArgumentError.invalid }
        let commandSucceeded = QualificationCommandExitPolicy.succeeded(
            report: report,
            ranFullSuite: true
        )
        exit(commandSucceeded ? 0 : 1)
    }
} catch let error as CodexCLIQualificationStartError {
    if case let .qualificationUnavailable(report) = error, writeJSON(report) {
        FileHandle.standardError.write(
            Data("Qualification blocked. Zero provider cases were launched.\n".utf8)
        )
        exit(1)
    }
    FileHandle.standardError.write(
        Data("Qualification could not start. No provider details were emitted.\n".utf8)
    )
    printUsage()
    exit(64)
} catch {
    FileHandle.standardError.write(
        Data("Qualification could not start. No provider details were emitted.\n".utf8)
    )
    printUsage()
    exit(64)
}
