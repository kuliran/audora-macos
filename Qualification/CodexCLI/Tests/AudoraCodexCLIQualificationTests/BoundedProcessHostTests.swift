import Foundation
import XCTest

#if canImport(Darwin)
import Darwin
#endif

@testable import AudoraCodexCLIQualification

final class BoundedProcessHostTests: XCTestCase {
    func testDescriptorBoundLaunchUsesTheExactRevalidatedNativeArtifact() throws {
        let executable = URL(fileURLWithPath: "/bin/echo")
        let artifact = try XCTUnwrap(
            CodexCLIExecutableArtifact(executableURL: executable)
        )

        let result = BoundedProcessHost().run(
            request(executableURL: executable, artifact: artifact, arguments: ["exact"])
        )

        XCTAssertTrue(result.launched)
        XCTAssertTrue(result.exitedNormally)
        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertEqual(String(decoding: result.standardOutput, as: UTF8.self), "exact\n")
    }

    func testDescriptorBoundLaunchRejectsAnInPlaceArtifactMutation() throws {
        let fixtureDirectory = try temporaryFixtureDirectory(
            prefix: "audora-mutated-executable"
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let executable = fixtureDirectory.appendingPathComponent("codex")
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/bin/echo"),
            to: executable
        )
        let artifact = try XCTUnwrap(
            CodexCLIExecutableArtifact(executableURL: executable)
        )
        let handle = try FileHandle(forWritingTo: executable)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()

        let result = BoundedProcessHost().run(
            request(executableURL: executable, artifact: artifact, arguments: ["changed"])
        )

        XCTAssertFalse(result.launched)
        XCTAssertTrue(result.standardOutput.isEmpty)
    }

    func testDescriptorBoundLaunchRejectsAPathSwapBeforeLaunch() throws {
        let fixtureDirectory = try temporaryFixtureDirectory(
            prefix: "audora-swapped-executable"
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let executable = fixtureDirectory.appendingPathComponent("codex")
        let replacement = fixtureDirectory.appendingPathComponent("replacement")
        let displaced = fixtureDirectory.appendingPathComponent("displaced")
        let launchMarker = fixtureDirectory.appendingPathComponent("launched")
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/bin/echo"),
            to: executable
        )
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/touch"),
            to: replacement
        )
        let artifact = try XCTUnwrap(
            CodexCLIExecutableArtifact(executableURL: executable)
        )
        try FileManager.default.moveItem(at: executable, to: displaced)
        try FileManager.default.moveItem(at: replacement, to: executable)

        let result = BoundedProcessHost().run(
            request(
                executableURL: executable,
                artifact: artifact,
                arguments: [launchMarker.path]
            )
        )

        XCTAssertFalse(result.launched)
        XCTAssertFalse(FileManager.default.fileExists(atPath: launchMarker.path))
    }

    func testSuspendedLaunchRejectsSwapAndSwapBackOfIdenticalBytes() throws {
        let fixtureDirectory = try temporaryFixtureDirectory(
            prefix: "audora-swap-back-executable"
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        // A copied XCTest host can be rejected by SwiftPM's test sandbox before
        // `posix_spawn` returns, which would never exercise the suspended-child
        // identity check. A system Mach-O remains executable after copying and
        // gives us two distinct vnodes with identical bytes.
        let sourceExecutable = URL(fileURLWithPath: "/bin/echo")
        let executable = fixtureDirectory.appendingPathComponent("codex")
        let replacement = fixtureDirectory.appendingPathComponent("replacement")
        let displaced = fixtureDirectory.appendingPathComponent("displaced")
        try FileManager.default.copyItem(at: sourceExecutable, to: executable)
        try FileManager.default.copyItem(at: sourceExecutable, to: replacement)
        let artifact = try XCTUnwrap(
            CodexCLIExecutableArtifact(executableURL: executable)
        )
        let swap = ExecutableSwapBack(
            executable: executable,
            replacement: replacement,
            displaced: displaced,
            artifact: artifact
        )
        let host = BoundedProcessHost(
            willSpawn: swap.installReplacement,
            didSpawnSuspended: swap.restoreApprovedPath
        )

        let result = host.run(
            request(
                executableURL: executable,
                artifact: artifact,
                arguments: ["--help"]
            )
        )

        XCTAssertNil(swap.errorDescription)
        XCTAssertEqual(swap.approvedPathRestoredToPinnedBytes, true)
        XCTAssertEqual(
            swap.spawnedProcessMappedApprovedVnode,
            false,
            "the child must be tied to the mapped executable vnode, not path text or equal bytes"
        )
        XCTAssertFalse(result.launched)
        XCTAssertTrue(result.processGroupWasReaped)
    }

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

    private func temporaryFixtureDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(prefix)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
        return url
    }

    private func request(
        executableURL: URL,
        artifact: CodexCLIExecutableArtifact,
        arguments: [String]
    ) -> BoundedProcessRequest {
        BoundedProcessRequest(
            executableURL: executableURL,
            executableArtifact: artifact,
            arguments: arguments,
            environment: ["PATH": "/usr/bin:/bin"],
            workingDirectoryURL: executableURL.deletingLastPathComponent(),
            standardInput: Data(),
            standardOutputByteCeiling: 4_096,
            standardErrorByteCeiling: 4_096,
            timeoutSeconds: 2,
            cancelAfterSeconds: nil,
            terminationGraceSeconds: 0.2
        )
    }
}

private final class ExecutableSwapBack: @unchecked Sendable {
    private let lock = NSLock()
    private let executable: URL
    private let replacement: URL
    private let displaced: URL
    private let artifact: CodexCLIExecutableArtifact
    private var storedErrorDescription: String?
    private var storedApprovedPathRestoredToPinnedBytes: Bool?
    private var storedSpawnedProcessMappedApprovedVnode: Bool?

    init(
        executable: URL,
        replacement: URL,
        displaced: URL,
        artifact: CodexCLIExecutableArtifact
    ) {
        self.executable = executable
        self.replacement = replacement
        self.displaced = displaced
        self.artifact = artifact
    }

    var errorDescription: String? {
        withLock { storedErrorDescription }
    }

    var approvedPathRestoredToPinnedBytes: Bool? {
        withLock { storedApprovedPathRestoredToPinnedBytes }
    }

    var spawnedProcessMappedApprovedVnode: Bool? {
        withLock { storedSpawnedProcessMappedApprovedVnode }
    }

    func installReplacement() {
        do {
            try FileManager.default.moveItem(at: executable, to: displaced)
            try FileManager.default.moveItem(at: replacement, to: executable)
        } catch {
            record(error)
        }
    }

    func restoreApprovedPath(processID: pid_t) {
        do {
            try FileManager.default.moveItem(at: executable, to: replacement)
            try FileManager.default.moveItem(at: displaced, to: executable)
            withLock {
                storedApprovedPathRestoredToPinnedBytes = artifact
                    .pathStillNamesPinnedBytes()
                storedSpawnedProcessMappedApprovedVnode = artifact
                    .launchedProcessMapsPinnedExecutable(processID)
            }
        } catch {
            record(error)
        }
    }

    private func record(_ error: Error) {
        withLock {
            storedErrorDescription = String(describing: error)
        }
    }

    private func withLock<Value>(_ operation: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return operation()
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
