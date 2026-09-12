import Foundation
import XCTest

#if canImport(Darwin)
import Darwin
#endif

@testable import AudoraCodexCLIQualification

final class BoundedProcessHostTests: XCTestCase {
    func testTimeoutUsesInjectedMonotonicClockAndReapsWithoutBlocking() {
        let clock = IncrementingMonotonicClock(stepNanoseconds: 100_000_000)
        let host = BoundedProcessHost(monotonicNanoseconds: clock.now)
        let startedAt = DispatchTime.now().uptimeNanoseconds

        let result = host.run(
            BoundedProcessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["10"],
                environment: ["PATH": "/usr/bin:/bin"],
                workingDirectoryURL: FileManager.default.temporaryDirectory,
                standardInput: Data(),
                standardOutputByteCeiling: 4_096,
                standardErrorByteCeiling: 4_096,
                timeoutSeconds: 0.2,
                cancelAfterSeconds: nil,
                terminationGraceSeconds: 0
            )
        )

        let wallMilliseconds = Int(
            (DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
        )
        XCTAssertEqual(result.stopReason, .timedOut)
        XCTAssertTrue(result.processGroupWasReaped)
        XCTAssertGreaterThanOrEqual(result.durationMilliseconds, 200)
        XCTAssertLessThan(wallMilliseconds, 1_000)
    }

    func testDetachedDescendantThatClosesPipesPreventsReclamationProof() throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "audora-process-tree-proof-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let detachedPIDURL = fixtureDirectory.appendingPathComponent("detached.pid")
        var detachedPID: pid_t?
        defer {
            if let detachedPID, kill(detachedPID, 0) == 0 {
                _ = kill(detachedPID, SIGKILL)
                let deadline = Date().addingTimeInterval(0.5)
                while kill(detachedPID, 0) == 0, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
        }

        let fixtureProgram = #"""
        my ($pid_path) = @ARGV;
        my $child = fork();
        die "fork failed" unless defined $child;
        if ($child == 0) {
            POSIX::setsid();
            open my $pid_file, '>', $pid_path or exit 2;
            print $pid_file "$$\n";
            close $pid_file;
            close STDIN;
            close STDOUT;
            close STDERR;
            sleep 10;
            exit 0;
        }
        for (1 .. 100) {
            last if -s $pid_path;
            select undef, undef, undef, 0.01;
        }
        sleep 10;
        """#
        let result = BoundedProcessHost().run(
            BoundedProcessRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
                arguments: ["-MPOSIX", "-e", fixtureProgram, detachedPIDURL.path],
                environment: ["PATH": "/usr/bin:/bin"],
                workingDirectoryURL: fixtureDirectory,
                standardInput: Data(),
                standardOutputByteCeiling: 4_096,
                standardErrorByteCeiling: 4_096,
                timeoutSeconds: 2,
                cancelAfterSeconds: 0.1,
                terminationGraceSeconds: 0.05
            )
        )

        detachedPID = try XCTUnwrap(
            pid_t(
                String(decoding: Data(contentsOf: detachedPIDURL), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
        XCTAssertEqual(kill(try XCTUnwrap(detachedPID), 0), 0)
        XCTAssertFalse(result.processGroupWasReaped)
        XCTAssertEqual(result.stopReason, .ioFailure)
    }
}

private final class IncrementingMonotonicClock: @unchecked Sendable {
    private let lock = NSLock()
    private var currentNanoseconds: UInt64 = 0
    private let stepNanoseconds: UInt64

    init(stepNanoseconds: UInt64) {
        self.stepNanoseconds = stepNanoseconds
    }

    func now() -> UInt64 {
        lock.lock()
        defer {
            currentNanoseconds += stepNanoseconds
            lock.unlock()
        }
        return currentNanoseconds
    }
}
