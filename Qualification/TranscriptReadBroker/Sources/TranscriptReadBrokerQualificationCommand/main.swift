import AudoraTranscriptReadBroker
import Darwin
import Foundation

@main
struct TranscriptReadBrokerQualificationCommand {
    static func main() async {
        let report: TranscriptReadQualificationReport
        let exitCode: Int32
        do {
            report = try await TranscriptReadQualificationRunner().run()
            exitCode = 0
        } catch {
            report = .failedClosed
            exitCode = 1
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(report) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
        Darwin.exit(exitCode)
    }
}
