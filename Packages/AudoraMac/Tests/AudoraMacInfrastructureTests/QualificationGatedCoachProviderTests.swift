@testable @_spi(CoachContextQualification) @_spi(InvocationInfrastructure) import AudoraApplication
import AudoraDomain
@testable @_spi(InvocationInfrastructure) import AudoraMacInfrastructure
import Foundation
import XCTest

final class QualificationGatedCoachProviderTests: XCTestCase {
    func testEmptyGatewayFailsClosedWithoutLaunchingAProvider() async throws {
        let gateway = QualificationGatedCoachProvider()

        let health = await gateway.health()
        XCTAssertEqual(health, .unavailable)

        do {
            _ = try await gateway.run(
                request: Self.request,
                execution: try Self.execution,
                transcriptAccess: nil
            )
            XCTFail("an unqualified gateway must not synthesize a response")
        } catch let error as CoachProviderRunError {
            XCTAssertEqual(error, .userRetryableFailure)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let cancellation = await gateway.cancelAndReap(
            attemptID: try Self.execution.attemptID,
            graceMilliseconds: 2_000
        )
        XCTAssertEqual(cancellation, .alreadyAbsent)
    }

    func testQualifiedBundleOwnsConfigurationWhileGatewayDelegatesTransport()
        async throws
    {
        let response = CoachProviderCompleteResponse(body: Data(#"{"messageBlocks":[]}"#.utf8))
        let provider = QualifiedCoachProviderFixture(response: response)
        let binding = qualifiedBinding(descriptor: Self.descriptor)
        let gateway = QualificationGatedCoachProvider(
            qualifiedBundle: QualifiedCoachProviderBundle(
                configuration: binding,
                transport: provider
            )
        )

        let health = await gateway.health()
        XCTAssertEqual(health, .available)
        let received = try await gateway.run(
            request: Self.request,
            execution: try Self.execution,
            transcriptAccess: nil
        )
        XCTAssertEqual(received, response)
        let cancellation = await gateway.cancelAndReap(
            attemptID: try Self.execution.attemptID,
            graceMilliseconds: 2_000
        )
        XCTAssertEqual(cancellation, .reaped)
    }

    func testGatewayRejectsSameDescriptorBoundToDifferentQualifiedPolicy() async throws {
        let runRecorder = CoachProviderRunRecorder()
        let provider = QualifiedCoachProviderFixture(
            response: CoachProviderCompleteResponse(body: Data("{}".utf8)),
            runRecorder: runRecorder
        )
        let gateway = QualificationGatedCoachProvider(
            qualifiedBundle: QualifiedCoachProviderBundle(
                configuration: qualifiedBinding(descriptor: Self.descriptor),
                transport: provider
            )
        )
        let mismatched = CoachRequest(
            body: Data("{}".utf8),
            outputTokenCeiling: 256,
            pinnedInstruction: "Return one complete structured response.",
            providerBinding: qualifiedBinding(
                descriptor: Self.descriptor,
                providerIdentifier: "same-limits-different-qualified-provider"
            )
        )

        do {
            _ = try await gateway.run(
                request: mismatched,
                execution: try Self.execution,
                transcriptAccess: nil
            )
            XCTFail("configuration mismatch must not reach the provider")
        } catch let error as CoachProviderRunError {
            XCTAssertEqual(error, .userRetryableFailure)
        }
        let runCount = await runRecorder.count()
        XCTAssertEqual(runCount, 0)
    }

    private static let request = CoachRequest(
        body: Data("{}".utf8),
        outputTokenCeiling: 512,
        pinnedInstruction: "Return one complete structured response.",
        providerBinding: qualifiedBinding(descriptor: descriptor)
    )

    private static let descriptor = CoachProviderDescriptor(
        displayName: "Qualified fixture",
        contextBudget: CoachContextBudget(
            contextWindowTokens: 4_096,
            responseReservedTokens: 512,
            safetyMarginTokens: 128
        ),
        coachMemoryMaxTokens: 256
    )

    private static var execution: ProviderAttemptMetadata {
        get throws {
            ProviderAttemptMetadata(
                attemptID: try CoachProviderAttemptID(
                    "atm-20260830T120000000Z-6NPQ"
                ),
                attemptOrdinal: 1,
                attemptKind: .standard,
                providerIdempotencyValue: try ProviderIdempotencyValue(
                    "provider-idempotency-fixture"
                ),
                control: .standard
            )
        }
    }
}

private struct QualifiedCoachProviderFixture: QualifiedCoachProviderTransport {
    let response: CoachProviderCompleteResponse
    var runRecorder: CoachProviderRunRecorder?

    init(
        response: CoachProviderCompleteResponse,
        runRecorder: CoachProviderRunRecorder? = nil
    ) {
        self.response = response
        self.runRecorder = runRecorder
    }

    func health() async -> CoachProviderHealth { .available }

    func run(
        request: CoachRequest,
        execution: ProviderAttemptMetadata,
        transcriptAccess: CoachTranscriptAccess?
    ) async throws -> CoachProviderCompleteResponse {
        await runRecorder?.record()
        return response
    }

    func cancelAndReap(
        attemptID: CoachProviderAttemptID,
        graceMilliseconds: Int64
    ) async -> CoachProviderAttemptCancellationOutcome {
        .reaped
    }
}

private actor CoachProviderRunRecorder {
    private var runCount = 0

    func record() {
        runCount += 1
    }

    func count() -> Int {
        runCount
    }
}

private func qualifiedBinding(
    descriptor: CoachProviderDescriptor,
    providerIdentifier: String = "qualified-provider-fixture-v1"
) -> CoachProviderConfigurationBinding {
    CoachProviderConfigurationBinding(
        descriptor: descriptor,
        policy: CoachProviderEstimationPolicy(
            providerIdentifier: providerIdentifier,
            responseCollectorByteCeiling: 1_048_576,
            framing: .testUnframed,
            attachmentProjectionPolicy: try! CoachAttachmentProjectionPolicy(
                maximumInlineTranscriptTokens: 1_024,
                tokenEstimator: .utf8ByteUpperBound()
            )
        )
    )
}
