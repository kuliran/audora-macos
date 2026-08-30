import AudoraCodexCLIQualification
import Foundation

private struct Options {
    var executablePath = "/opt/homebrew/bin/codex"
    var model = "gpt-5.4"
    var selectedCase: QualificationCase?
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
        case "--case":
            guard index + 1 < arguments.count else { throw ArgumentError.invalid }
            let value = arguments[index + 1]
            if value == "all" {
                options.selectedCase = nil
            } else if let qualificationCase = QualificationCase(rawValue: value) {
                options.selectedCase = qualificationCase
            } else {
                throw ArgumentError.invalid
            }
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
        "Usage: codex-cli-qualification [--codex /absolute/path] [--model allowlisted-model] [--case all|structuredResponse|cancellation|timeout]"
    )
}

do {
    let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
    guard options.executablePath.hasPrefix("/") else { throw ArgumentError.invalid }

    let harness = CodexCLIQualificationHarness()
    let report: QualificationSuiteReport
    if let selectedCase = options.selectedCase {
        let caseReport = try harness.runCase(
            selectedCase,
            executableURL: URL(fileURLWithPath: options.executablePath),
            model: options.model
        )
        report = QualificationSuiteReport(cases: [caseReport])
    } else {
        report = try harness.runSuite(
            executableURL: URL(fileURLWithPath: options.executablePath),
            model: options.model
        )
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(report))
    FileHandle.standardOutput.write(Data("\n".utf8))

    let casesPassed = report.cases.allSatisfy(\.passed)
    exit(casesPassed ? 0 : 1)
} catch {
    FileHandle.standardError.write(
        Data("Qualification could not start. No provider details were emitted.\n".utf8)
    )
    printUsage()
    exit(64)
}
