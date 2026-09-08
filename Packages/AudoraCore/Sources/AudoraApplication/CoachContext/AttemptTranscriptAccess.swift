import AudoraDomain
import CryptoKit
import Foundation

/// A transport-independent, Attempt-local authority for the transcript read
/// broker. Its bearer value is intentionally neither printable nor serializable.
struct AttemptTranscriptAccessCapability: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    private let value: Data

    fileprivate init(value: Data) {
        self.value = value
    }

    fileprivate var digest: Data {
        Data(SHA256.hash(data: value))
    }

    var description: String { "<redacted attempt transcript capability>" }
    var debugDescription: String { description }
}

struct AttemptTranscriptAccessLimits: Equatable, Sendable {
    let maximumRequestBytes: Int
    let maximumRequestedHandles: Int

    init(
        maximumRequestBytes: Int = 16 * 1_024,
        maximumRequestedHandles: Int = 128
    ) {
        self.maximumRequestBytes = maximumRequestBytes
        self.maximumRequestedHandles = maximumRequestedHandles
    }
}

@_spi(InvocationInfrastructure)
public enum AttemptTranscriptAvailability: Equatable, Sendable {
    case available
    case unavailable
}

private enum AttemptTranscriptAvailabilityError: Error {
    case malformedBatchResult
}

@_spi(InvocationInfrastructure)
public struct AttemptTranscriptAvailabilityQuery: Equatable, Sendable {
    public let library: LibraryScope
    public let chatID: ChatID
    public let sourceAttachment: ChatSessionAttachment
    public let revisionSHA256: String

    public var sessionAttachmentID: ChatSessionAttachmentID {
        sourceAttachment.attachmentID
    }

    public init(
        library: LibraryScope,
        chatID: ChatID,
        sourceAttachment: ChatSessionAttachment,
        revisionSHA256: String
    ) {
        self.library = library
        self.chatID = chatID
        self.sourceAttachment = sourceAttachment
        self.revisionSHA256 = revisionSHA256
    }
}

/// App-only factory for exact storage revalidation. Local identifiers remain on
/// this side of the provider boundary and are bound before a grant is issued.
@_spi(InvocationInfrastructure)
public struct AttemptTranscriptAvailabilitySource: Sendable {
    private let implementation:
        @Sendable ([AttemptTranscriptAvailabilityQuery]) async throws
            -> [AttemptTranscriptAvailability]

    public init(
        implementation: @escaping
            @Sendable (AttemptTranscriptAvailabilityQuery) async throws
                -> AttemptTranscriptAvailability
    ) {
        self.implementation = { queries in
            var results: [AttemptTranscriptAvailability] = []
            results.reserveCapacity(queries.count)
            for query in queries {
                results.append(try await implementation(query))
            }
            return results
        }
    }

    public init(
        batchImplementation: @escaping
            @Sendable ([AttemptTranscriptAvailabilityQuery]) async throws
                -> [AttemptTranscriptAvailability]
    ) {
        implementation = batchImplementation
    }

    public static let allAvailable = AttemptTranscriptAvailabilitySource(
        batchImplementation: { queries in
            Array(repeating: .available, count: queries.count)
        }
    )

    public func availability(
        for query: AttemptTranscriptAvailabilityQuery
    ) async throws -> AttemptTranscriptAvailability {
        let results = try await availabilities(for: [query])
        guard results.count == 1, let result = results.first else {
            throw AttemptTranscriptAvailabilityError.malformedBatchResult
        }
        return result
    }

    public func availabilities(
        for queries: [AttemptTranscriptAvailabilityQuery]
    ) async throws -> [AttemptTranscriptAvailability] {
        try await implementation(queries)
    }

    func checker(
        library: LibraryScope,
        chatID: ChatID
    ) -> AttemptTranscriptAvailabilityChecker {
        AttemptTranscriptAvailabilityChecker(batchImplementation: { sources in
            try await availabilities(
                for: sources.map { source in
                    AttemptTranscriptAvailabilityQuery(
                    library: library,
                    chatID: chatID,
                    sourceAttachment: source.attachment,
                    revisionSHA256: source.revisionSHA256
                )
                }
            )
        })
    }
}

struct AttemptTranscriptSourceIdentity: Equatable, Sendable {
    let attachment: ChatSessionAttachment
    let revisionSHA256: String

    var sessionAttachmentID: ChatSessionAttachmentID {
        attachment.attachmentID
    }
}

/// Revalidates that the frozen Chat attachment is still readable. The checker
/// receives only stable Chat identity; provider handles never become storage
/// identifiers and storage never supplies provider-visible transcript values.
struct AttemptTranscriptAvailabilityChecker: Sendable {
    private let implementation:
        @Sendable ([AttemptTranscriptSourceIdentity]) async throws
            -> [AttemptTranscriptAvailability]

    init(
        implementation: @escaping
            @Sendable (AttemptTranscriptSourceIdentity) async throws
                -> AttemptTranscriptAvailability
    ) {
        self.implementation = { sources in
            var results: [AttemptTranscriptAvailability] = []
            results.reserveCapacity(sources.count)
            for source in sources {
                results.append(try await implementation(source))
            }
            return results
        }
    }

    init(
        batchImplementation: @escaping
            @Sendable ([AttemptTranscriptSourceIdentity]) async throws
                -> [AttemptTranscriptAvailability]
    ) {
        implementation = batchImplementation
    }

    static let allAvailable = AttemptTranscriptAvailabilityChecker(
        batchImplementation: { sources in
            Array(repeating: .available, count: sources.count)
        }
    )

    fileprivate func availability(
        of source: AttemptTranscriptSourceIdentity
    ) async throws -> AttemptTranscriptAvailability {
        let results = try await availabilities(of: [source])
        guard results.count == 1, let result = results.first else {
            throw AttemptTranscriptAvailabilityError.malformedBatchResult
        }
        return result
    }

    fileprivate func availabilities(
        of sources: [AttemptTranscriptSourceIdentity]
    ) async throws -> [AttemptTranscriptAvailability] {
        try await implementation(sources)
    }
}

enum AttemptTranscriptAccessResponseKind: String, Equatable, Sendable {
    case complete
    case sessionUnavailable
    case contextCannotFit
}

struct AttemptTranscriptAccessDelivery: Equatable, Sendable {
    let responseBody: Data
    let kind: AttemptTranscriptAccessResponseKind
    let isReplay: Bool
    let terminatesAttempt: Bool
}

enum AttemptTranscriptAccessRejection: String, Equatable, Sendable {
    case closed
}

/// Adapter-owned identity for one logical transport delivery. A transport may
/// redeliver the same identity once; a model-originated second tool call must
/// carry a different identity even when its arguments are byte-identical.
struct AttemptTranscriptTransportRequestID: Hashable, Sendable {
    let rawValue: String

    init?(_ rawValue: String) {
        guard !rawValue.isEmpty,
              rawValue.utf8.count <= 128,
              !rawValue.unicodeScalars.contains(where: {
                  $0.value == 0 || $0.properties.generalCategory == .control
              })
        else { return nil }
        self.rawValue = rawValue
    }

    fileprivate static let directBrokerCall =
        AttemptTranscriptTransportRequestID("direct-broker-call")!
}

enum AttemptTranscriptAccessResult: Equatable, Sendable {
    case delivered(AttemptTranscriptAccessDelivery)
    case rejected(AttemptTranscriptAccessRejection)
}

enum AttemptTranscriptAccessRevocationReason: String, CaseIterable, Equatable, Sendable {
    case attemptCompleted
    case providerFailed
    case cancelled
    case timedOut
    case launchFailed
    case processExited
    case publicationAuthorityLost
    case protocolFailure
}

/// App-only navigation material retained after ephemeral routes are wiped.
/// Both values already belong to the allowlisted Coach attachment descriptor.
struct AttemptTranscriptFailureSession: Equatable, Sendable {
    let sessionAttachmentID: ChatSessionAttachmentID
    let displayLabel: String
}

enum AttemptTranscriptAccessTerminalStatus: Equatable, Sendable {
    case completed
    case sessionUnavailable([AttemptTranscriptFailureSession])
    case contextCannotFit
    case rejected
    case revoked(AttemptTranscriptAccessRevocationReason)
}

enum AttemptTranscriptAccessBrokerStatus: Equatable, Sendable {
    case open
    case checking
    case replayable
    case terminal(AttemptTranscriptAccessTerminalStatus)
}

enum AttemptTranscriptAccessGrantIssueError: Error, Equatable, Sendable {
    case invalidLimits
    case emptyAttachmentSet
    case tooManyAttachments
    case handleCountMismatch
    case duplicatePreparedHandle
    case duplicateFreshHandle
    case freshHandleWasNotRebound
    case invalidCanonicalExchange
    case missingBudgetAuthority
    case invalidAttachmentProjection
    case duplicateSessionAttachmentID
    case contextCannotFit
}

/// The only part of the canonical exchange that an Attempt transport needs
/// before an on-demand read. Reserved complete transcript bytes remain solely
/// inside the broker.
struct AttemptBoundCoachExchange: Equatable, Sendable {
    let request: Data
    let transcriptHandles: [PreparedCoachTranscriptHandle]
}

struct AttemptTranscriptAccessGrant: Sendable {
    let capability: AttemptTranscriptAccessCapability
    let exchange: AttemptBoundCoachExchange
    let broker: AttemptTranscriptAccessBroker
}

struct AttemptTranscriptAccessGrantIssuer: Sendable {
    init() {}

    /// Remeasures the exact Attempt instruction and fresh-handle exchange before
    /// admission, persistence installation, or provider launch.
    func preflight(
        exchange: CanonicalCoachExchange,
        freshHandles: [PreparedCoachTranscriptHandle],
        pinnedInstruction: String,
        limits: AttemptTranscriptAccessLimits = AttemptTranscriptAccessLimits()
    ) throws {
        guard limits.maximumRequestBytes > 0,
              limits.maximumRequestedHandles > 0
        else {
            throw AttemptTranscriptAccessGrantIssueError.invalidLimits
        }
        guard let baseBudgetAuthority =
            exchange.transcriptResponseBudgetAuthority
        else {
            throw AttemptTranscriptAccessGrantIssueError.missingBudgetAuthority
        }
        let budgetAuthority = baseBudgetAuthority.replacingPinnedInstruction(
            pinnedInstruction
        )

        if exchange.preparedTranscriptHandles.isEmpty {
            guard freshHandles.isEmpty,
                  exchange.preparedTranscriptRoutes.isEmpty,
                  exchange.transcriptReadRequest == nil,
                  exchange.transcriptReadResponse == nil
            else {
                throw AttemptTranscriptAccessGrantIssueError
                    .invalidCanonicalExchange
            }
            guard try budgetAuthority.admitsInitialRequest(exchange.request) else {
                throw AttemptTranscriptAccessGrantIssueError.contextCannotFit
            }
            return
        }

        let validated = try validateAndRebind(
            exchange: exchange,
            freshHandles: freshHandles,
            limits: limits
        )
        let reboundRequest = CanonicalJSON.serialize(validated.reboundRequest)
        let readRequest = CanonicalJSON.serialize(
            .object([
                "sessionTranscriptHandles": .array(
                    freshHandles.map { .string($0.rawValue) }
                ),
            ])
        )
        guard let readResponse = exchange.transcriptReadResponse,
              try budgetAuthority.admitsMaximumTranscriptExchange(
                  reboundInitialRequest: reboundRequest,
                  transcriptReadRequest: readRequest,
                  transcriptReadResponse: readResponse
              )
        else {
            throw AttemptTranscriptAccessGrantIssueError.contextCannotFit
        }
    }

    /// Creates one Attempt authority from an admitted canonical exchange and the
    /// already-qualified fresh handles owned by that Attempt identity.
    func issue(
        exchange: CanonicalCoachExchange,
        freshHandles: [PreparedCoachTranscriptHandle],
        pinnedInstruction: String? = nil,
        availabilityChecker: AttemptTranscriptAvailabilityChecker = .allAvailable,
        limits: AttemptTranscriptAccessLimits = AttemptTranscriptAccessLimits()
    ) throws -> AttemptTranscriptAccessGrant {
        guard limits.maximumRequestBytes > 0,
              limits.maximumRequestedHandles > 0
        else {
            throw AttemptTranscriptAccessGrantIssueError.invalidLimits
        }

        let validated = try validateAndRebind(
            exchange: exchange,
            freshHandles: freshHandles,
            limits: limits
        )
        let capability = AttemptTranscriptAccessCapability(value: randomBytes(count: 32))
        guard let baseBudgetAuthority = exchange.transcriptResponseBudgetAuthority else {
            throw AttemptTranscriptAccessGrantIssueError.missingBudgetAuthority
        }
        let budgetAuthority = baseBudgetAuthority.replacingPinnedInstruction(
            pinnedInstruction ?? exchange.pinnedInstruction
        )
        let reboundRequest = CanonicalJSON.serialize(validated.reboundRequest)
        let broker = AttemptTranscriptAccessBroker(
            capabilityDigest: capability.digest,
            recordsByHandle: validated.recordsByHandle,
            availabilityChecker: availabilityChecker,
            reboundInitialRequest: reboundRequest,
            responseBudgetAuthority: budgetAuthority,
            limits: limits
        )
        return AttemptTranscriptAccessGrant(
            capability: capability,
            exchange: AttemptBoundCoachExchange(
                request: reboundRequest,
                transcriptHandles: freshHandles
            ),
            broker: broker
        )
    }
}

actor AttemptTranscriptAccessBroker {
    private enum State {
        case open
        case checking(
            transportRequestID: AttemptTranscriptTransportRequestID,
            requestHandles: [PreparedCoachTranscriptHandle],
            token: UUID,
            task: Task<[
                PreparedCoachTranscriptHandle: AttemptTranscriptAvailability
            ], Never>
        )
        case replayable(
            transportRequestID: AttemptTranscriptTransportRequestID,
            requestHandles: [PreparedCoachTranscriptHandle],
            responseBody: Data
        )
        case terminal(AttemptTranscriptAccessTerminalStatus)
    }

    private var state: State = .open
    private var capabilityDigest: Data
    private var recordsByHandle:
        [PreparedCoachTranscriptHandle: AttemptTranscriptRecord]
    private let availabilityChecker: AttemptTranscriptAvailabilityChecker
    private let reboundInitialRequest: Data
    private let responseBudgetAuthority: AttemptTranscriptResponseBudgetAuthority
    private let limits: AttemptTranscriptAccessLimits

    fileprivate init(
        capabilityDigest: Data,
        recordsByHandle: [PreparedCoachTranscriptHandle: AttemptTranscriptRecord],
        availabilityChecker: AttemptTranscriptAvailabilityChecker,
        reboundInitialRequest: Data,
        responseBudgetAuthority: AttemptTranscriptResponseBudgetAuthority,
        limits: AttemptTranscriptAccessLimits
    ) {
        self.capabilityDigest = capabilityDigest
        self.recordsByHandle = recordsByHandle
        self.availabilityChecker = availabilityChecker
        self.reboundInitialRequest = reboundInitialRequest
        self.responseBudgetAuthority = responseBudgetAuthority
        self.limits = limits
    }

    /// Processes one semantic tool read. The broker installs an in-flight state
    /// before exact storage revalidation suspends, then rechecks that state before
    /// any transcript bytes can escape. Revocation therefore wins cleanly at the
    /// actor boundary even while local storage is being retried.
    func read(
        capability: AttemptTranscriptAccessCapability,
        transportRequestID: AttemptTranscriptTransportRequestID,
        handles: [PreparedCoachTranscriptHandle]
    ) async -> AttemptTranscriptAccessResult {
        guard case .terminal = state else {
            guard constantTimeEqual(capability.digest, capabilityDigest),
                  isValidRequest(handles)
            else {
                close(with: .rejected)
                return .rejected(.closed)
            }

            switch state {
            case .open:
                return await beginFirstRead(
                    transportRequestID: transportRequestID,
                    handles: handles
                )

            case let .checking(firstRequestID, firstHandles, token, task):
                guard transportRequestID == firstRequestID,
                      handles == firstHandles
                else {
                    close(with: .rejected)
                    return .rejected(.closed)
                }
                return await finishFirstRead(
                    transportRequestID: transportRequestID,
                    handles: handles,
                    token: token,
                    task: task
                )

            case let .replayable(firstRequestID, firstHandles, responseBody):
                guard transportRequestID == firstRequestID,
                      handles == firstHandles
                else {
                    close(with: .rejected)
                    return .rejected(.closed)
                }
                let replayBody = responseBody
                close(with: .completed)
                return .delivered(
                    AttemptTranscriptAccessDelivery(
                        responseBody: replayBody,
                        kind: .complete,
                        isReplay: true,
                        terminatesAttempt: true
                    )
                )

            case .terminal:
                return .rejected(.closed)
            }
        }
        return .rejected(.closed)
    }

    /// Direct module tests use one stable delivery identity. Provider adapters
    /// must call the identity-bearing overload above.
    func read(
        capability: AttemptTranscriptAccessCapability,
        handles: [PreparedCoachTranscriptHandle]
    ) async -> AttemptTranscriptAccessResult {
        await read(
            capability: capability,
            transportRequestID: .directBrokerCall,
            handles: handles
        )
    }

    func revoke(reason: AttemptTranscriptAccessRevocationReason) {
        _ = finalize(reason: reason)
    }

    /// Atomically captures the provider-visible read state and closes the
    /// Attempt. A detached read therefore cannot land between a coordinator
    /// status check and revocation.
    func finalize(
        reason: AttemptTranscriptAccessRevocationReason
    ) -> AttemptTranscriptAccessBrokerStatus {
        let prior = status()
        guard case .terminal = state else {
            close(with: .revoked(reason))
            return prior
        }
        return prior
    }

    func status() -> AttemptTranscriptAccessBrokerStatus {
        switch state {
        case .open:
            .open
        case .checking:
            .checking
        case .replayable:
            .replayable
        case let .terminal(status):
            .terminal(status)
        }
    }

    private func beginFirstRead(
        transportRequestID: AttemptTranscriptTransportRequestID,
        handles: [PreparedCoachTranscriptHandle]
    ) async -> AttemptTranscriptAccessResult {
        // Resolve the entire set before touching storage so unknown or mixed-scope
        // requests can never reveal which individual handle was valid.
        var requested: [(PreparedCoachTranscriptHandle, AttemptTranscriptRecord)] = []
        requested.reserveCapacity(handles.count)
        for handle in handles {
            guard let record = recordsByHandle[handle] else {
                close(with: .rejected)
                return .rejected(.closed)
            }
            requested.append((handle, record))
        }

        // First establish availability for the whole batch. No transcript value
        // is staged unless every requested attachment remains available.
        let checker = availabilityChecker
        let requestedIdentities = requested.map {
            ($0.0, $0.1.source)
        }
        let task = Task {
            guard !Task.isCancelled else {
                return [PreparedCoachTranscriptHandle:
                    AttemptTranscriptAvailability]()
            }
            let availabilities: [AttemptTranscriptAvailability]
            do {
                availabilities = try await checker.availabilities(
                    of: requestedIdentities.map(\.1)
                )
            } catch {
                guard !Task.isCancelled else {
                    return [PreparedCoachTranscriptHandle:
                        AttemptTranscriptAvailability]()
                }
                return Dictionary(
                    uniqueKeysWithValues: requestedIdentities.map {
                        ($0.0, .unavailable)
                    }
                )
            }
            guard !Task.isCancelled,
                  availabilities.count == requestedIdentities.count
            else {
                return [PreparedCoachTranscriptHandle:
                    AttemptTranscriptAvailability]()
            }
            return Dictionary(
                uniqueKeysWithValues: zip(
                    requestedIdentities.map(\.0),
                    availabilities
                )
            )
        }
        let token = UUID()
        state = .checking(
            transportRequestID: transportRequestID,
            requestHandles: handles,
            token: token,
            task: task
        )
        return await finishFirstRead(
            transportRequestID: transportRequestID,
            handles: handles,
            token: token,
            task: task
        )
    }

    private func finishFirstRead(
        transportRequestID: AttemptTranscriptTransportRequestID,
        handles: [PreparedCoachTranscriptHandle],
        token: UUID,
        task: Task<[
            PreparedCoachTranscriptHandle: AttemptTranscriptAvailability
        ], Never>
    ) async -> AttemptTranscriptAccessResult {
        let availabilities = await task.value
        switch state {
        case let .checking(firstRequestID, firstHandles, currentToken, _)
            where firstRequestID == transportRequestID &&
            firstHandles == handles && currentToken == token:
            break
        case let .replayable(firstRequestID, firstHandles, responseBody)
            where firstRequestID == transportRequestID && firstHandles == handles:
            close(with: .completed)
            return .delivered(
                AttemptTranscriptAccessDelivery(
                    responseBody: responseBody,
                    kind: .complete,
                    isReplay: true,
                    terminatesAttempt: true
                )
            )
        case .open, .checking, .replayable, .terminal:
            return .rejected(.closed)
        }

        var requested: [(PreparedCoachTranscriptHandle, AttemptTranscriptRecord)] = []
        requested.reserveCapacity(handles.count)
        var unavailableHandles: [PreparedCoachTranscriptHandle] = []
        var unavailableSessions: [AttemptTranscriptFailureSession] = []
        for handle in handles {
            guard let record = recordsByHandle[handle],
                  let availability = availabilities[handle]
            else {
                close(with: .rejected)
                return .rejected(.closed)
            }
            requested.append((handle, record))
            if availability == .unavailable {
                unavailableHandles.append(handle)
                unavailableSessions.append(
                    AttemptTranscriptFailureSession(
                        sessionAttachmentID: record.sessionAttachmentID,
                        displayLabel: record.displayLabel
                    )
                )
            }
        }

        if !unavailableHandles.isEmpty {
            let responseBody = CanonicalJSON.serialize(
                .object([
                    "kind": .string(AttemptTranscriptAccessResponseKind
                        .sessionUnavailable.rawValue),
                    "unavailableSessionTranscriptHandles": .array(
                        unavailableHandles.map { .string($0.rawValue) }
                    ),
                ])
            )
            // Translate ephemeral routes to stable app identity before wiping the
            // route map. The terminal status contains no transcript content.
            close(with: .sessionUnavailable(unavailableSessions))
            return .delivered(
                AttemptTranscriptAccessDelivery(
                    responseBody: responseBody,
                    kind: .sessionUnavailable,
                    isReplay: false,
                    terminatesAttempt: true
                )
            )
        }

        let completeBody = CanonicalJSON.serialize(
            .object([
                "kind": .string(AttemptTranscriptAccessResponseKind.complete.rawValue),
                "transcripts": .array(requested.map { $0.1.disclosure }),
            ])
        )
        let readRequest = CanonicalJSON.serialize(
            .object([
                "sessionTranscriptHandles": .array(
                    handles.map { .string($0.rawValue) }
                ),
            ])
        )
        let fits: Bool
        do {
            guard let completeResponseBudget = try responseBudgetAuthority.budget(
                reboundInitialRequest: reboundInitialRequest,
                transcriptReadRequest: readRequest
            ) else {
                close(with: .contextCannotFit)
                return .delivered(
                    AttemptTranscriptAccessDelivery(
                        responseBody: CanonicalJSON.serialize(
                            .object([
                                "kind": .string(
                                    AttemptTranscriptAccessResponseKind
                                        .contextCannotFit.rawValue
                                ),
                            ])
                        ),
                        kind: .contextCannotFit,
                        isReplay: false,
                        terminatesAttempt: true
                    )
                )
            }
            fits = try completeResponseBudget.admits(canonicalResponse: completeBody)
        } catch {
            close(with: .rejected)
            return .rejected(.closed)
        }
        guard fits else {
            let responseBody = CanonicalJSON.serialize(
                .object([
                    "kind": .string(AttemptTranscriptAccessResponseKind
                        .contextCannotFit.rawValue),
                ])
            )
            close(with: .contextCannotFit)
            return .delivered(
                AttemptTranscriptAccessDelivery(
                    responseBody: responseBody,
                    kind: .contextCannotFit,
                    isReplay: false,
                    terminatesAttempt: true
                )
            )
        }

        state = .replayable(
            transportRequestID: transportRequestID,
            requestHandles: handles,
            responseBody: completeBody
        )
        return .delivered(
            AttemptTranscriptAccessDelivery(
                responseBody: completeBody,
                kind: .complete,
                isReplay: false,
                terminatesAttempt: false
            )
        )
    }

    private func isValidRequest(_ handles: [PreparedCoachTranscriptHandle]) -> Bool {
        guard !handles.isEmpty,
              handles.count <= limits.maximumRequestedHandles,
              Set(handles).count == handles.count
        else {
            return false
        }
        let canonicalRequest = CanonicalJSON.serialize(
            .object([
                "sessionTranscriptHandles": .array(
                    handles.map { .string($0.rawValue) }
                ),
            ])
        )
        return canonicalRequest.count <= limits.maximumRequestBytes
    }

    private func close(with status: AttemptTranscriptAccessTerminalStatus) {
        if case let .checking(_, _, _, task) = state {
            task.cancel()
        }
        state = .terminal(status)
        capabilityDigest.resetBytes(in: 0 ..< capabilityDigest.count)
        capabilityDigest.removeAll(keepingCapacity: false)
        recordsByHandle.removeAll(keepingCapacity: false)
    }
}

private struct ValidatedAttemptTranscriptAccess {
    let reboundRequest: CanonicalJSONValue
    let recordsByHandle:
        [PreparedCoachTranscriptHandle: AttemptTranscriptRecord]
}

private struct AttemptTranscriptRecord: Sendable {
    let source: AttemptTranscriptSourceIdentity
    let displayLabel: String
    let disclosure: CanonicalJSONValue

    var sessionAttachmentID: ChatSessionAttachmentID {
        source.sessionAttachmentID
    }
}

private func validateAndRebind(
    exchange: CanonicalCoachExchange,
    freshHandles: [PreparedCoachTranscriptHandle],
    limits: AttemptTranscriptAccessLimits
) throws -> ValidatedAttemptTranscriptAccess {
    let preparedHandles = exchange.preparedTranscriptHandles
    let routes = exchange.preparedTranscriptRoutes

    guard !preparedHandles.isEmpty else {
        throw AttemptTranscriptAccessGrantIssueError.emptyAttachmentSet
    }
    guard preparedHandles.count <= limits.maximumRequestedHandles else {
        throw AttemptTranscriptAccessGrantIssueError.tooManyAttachments
    }
    guard preparedHandles.count == routes.count,
          routes.count == freshHandles.count
    else {
        throw AttemptTranscriptAccessGrantIssueError.handleCountMismatch
    }
    guard Set(preparedHandles).count == preparedHandles.count else {
        throw AttemptTranscriptAccessGrantIssueError.duplicatePreparedHandle
    }
    guard Set(freshHandles).count == freshHandles.count else {
        throw AttemptTranscriptAccessGrantIssueError.duplicateFreshHandle
    }
    guard Set(preparedHandles).isDisjoint(with: Set(freshHandles)) else {
        throw AttemptTranscriptAccessGrantIssueError.freshHandleWasNotRebound
    }
    guard let structuralRequest = exchange.structuralRequest,
          CanonicalJSON.serialize(structuralRequest) == exchange.request,
          case var .object(requestFields) = structuralRequest,
          case var .array(requestAttachments)? = requestFields["sessionAttachments"]
    else {
        throw AttemptTranscriptAccessGrantIssueError.invalidCanonicalExchange
    }

    let expectedReadRequest = CanonicalJSON.serialize(
        .object([
            "sessionTranscriptHandles": .array(
                preparedHandles.map { .string($0.rawValue) }
            ),
        ])
    )
    let expectedReadResponse = CanonicalJSON.serialize(
        .object([
            "kind": .string(AttemptTranscriptAccessResponseKind.complete.rawValue),
            "transcripts": .array(routes.map(\.disclosure)),
        ])
    )
    guard exchange.transcriptReadRequest == expectedReadRequest,
          exchange.transcriptReadResponse == expectedReadResponse
    else {
        throw AttemptTranscriptAccessGrantIssueError.invalidCanonicalExchange
    }

    var onDemandIndices: [Int] = []
    for (index, attachment) in requestAttachments.enumerated() {
        guard case let .object(fields) = attachment else {
            throw AttemptTranscriptAccessGrantIssueError.invalidAttachmentProjection
        }
        if fields["kind"] == .string("onDemand") {
            onDemandIndices.append(index)
        } else if fields["sessionTranscriptHandle"] != nil {
            throw AttemptTranscriptAccessGrantIssueError.invalidAttachmentProjection
        }
    }
    guard onDemandIndices.count == routes.count else {
        throw AttemptTranscriptAccessGrantIssueError.handleCountMismatch
    }

    var stableIDs: Set<ChatSessionAttachmentID> = []
    var recordsByHandle:
        [PreparedCoachTranscriptHandle: AttemptTranscriptRecord] = [:]
    for position in routes.indices {
        let route = routes[position]
        let attachmentIndex = onDemandIndices[position]
        guard route.requestAttachmentIndex == attachmentIndex,
              route.preparedHandle == preparedHandles[position],
              case var .object(descriptor) = requestAttachments[attachmentIndex],
              Set(descriptor.keys) == Set([
                  "displayLabel",
                  "kind",
                  "sessionAttachmentId",
                  "sessionTranscriptHandle",
              ]),
              descriptor["kind"] == .string("onDemand"),
              descriptor["sessionTranscriptHandle"] ==
                  .string(route.preparedHandle.rawValue),
              case let .string(displayLabel)? = descriptor["displayLabel"],
              !displayLabel.isEmpty,
              case let .string(rawAttachmentID)? = descriptor["sessionAttachmentId"],
              let attachmentID = try? ChatSessionAttachmentID(rawAttachmentID),
              route.sourceAttachment.attachmentID == attachmentID,
              AudioArtifactFingerprint.isSHA256(route.revisionSHA256),
              validDisclosure(route.disclosure, attachmentID: attachmentID)
        else {
            throw AttemptTranscriptAccessGrantIssueError.invalidAttachmentProjection
        }
        guard stableIDs.insert(attachmentID).inserted else {
            throw AttemptTranscriptAccessGrantIssueError.duplicateSessionAttachmentID
        }

        let freshHandle = freshHandles[position]
        descriptor["sessionTranscriptHandle"] = .string(freshHandle.rawValue)
        requestAttachments[attachmentIndex] = .object(descriptor)
        recordsByHandle[freshHandle] = AttemptTranscriptRecord(
            source: AttemptTranscriptSourceIdentity(
                attachment: route.sourceAttachment,
                revisionSHA256: route.revisionSHA256
            ),
            displayLabel: displayLabel,
            disclosure: route.disclosure
        )
    }

    guard recordsByHandle.count == freshHandles.count else {
        throw AttemptTranscriptAccessGrantIssueError.handleCountMismatch
    }
    requestFields["sessionAttachments"] = .array(requestAttachments)
    return ValidatedAttemptTranscriptAccess(
        reboundRequest: .object(requestFields),
        recordsByHandle: recordsByHandle
    )
}

private func validDisclosure(
    _ disclosure: CanonicalJSONValue,
    attachmentID: ChatSessionAttachmentID
) -> Bool {
    guard case let .object(fields) = disclosure,
          Set(fields.keys) == Set(["sessionAttachmentId", "transcript"]),
          fields["sessionAttachmentId"] == .string(attachmentID.rawValue),
          let transcript = fields["transcript"]
    else {
        return false
    }
    return validProviderTranscript(transcript)
}

private func validProviderTranscript(_ value: CanonicalJSONValue) -> Bool {
    guard case let .object(fields) = value,
          Set(fields.keys) == Set(["audioEvents", "lines"]),
          case let .array(audioEvents)? = fields["audioEvents"],
          case let .array(lines)? = fields["lines"]
    else {
        return false
    }

    let validLines = lines.allSatisfy { line in
        guard case let .object(lineFields) = line,
              Set(lineFields.keys) == Set(["text", "timeRange", "words"]),
              case .string = lineFields["text"],
              let timeRange = lineFields["timeRange"],
              validTimeRange(timeRange),
              case let .array(words)? = lineFields["words"]
        else {
            return false
        }
        return words.allSatisfy(validProviderWord)
    }
    guard validLines else { return false }

    let categories = Set([
        "nonSpeech",
        "silentPause",
        "untranscribedVoicedInterval",
        "muted",
        "captureGap",
    ])
    return audioEvents.allSatisfy { event in
        guard case let .object(eventFields) = event,
              Set(eventFields.keys) == Set(["audioEventId", "category", "timeRange"]),
              case let .string(eventID)? = eventFields["audioEventId"],
              !eventID.isEmpty,
              case let .string(category)? = eventFields["category"],
              categories.contains(category),
              let timeRange = eventFields["timeRange"]
        else {
            return false
        }
        return validTimeRange(timeRange)
    }
}

private func validProviderWord(_ value: CanonicalJSONValue) -> Bool {
    guard case let .object(fields) = value,
          Set(fields.keys).isSubset(of: Set(["text", "timeRange", "wordId"])),
          fields.keys.contains("text"),
          fields.keys.contains("wordId"),
          case .string = fields["text"],
          case let .string(wordID)? = fields["wordId"],
          !wordID.isEmpty
    else {
        return false
    }
    return fields["timeRange"].map(validTimeRange) ?? true
}

private func validTimeRange(_ value: CanonicalJSONValue) -> Bool {
    guard case let .object(fields) = value,
          Set(fields.keys) == Set(["endMs", "startMs"]),
          case let .integer(start)? = fields["startMs"],
          case let .integer(end)? = fields["endMs"]
    else {
        return false
    }
    return start >= 0 && start < end && end <= Int64(Int32.max)
}

private func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
    let maximumCount = max(lhs.count, rhs.count)
    var difference = UInt8(truncatingIfNeeded: lhs.count ^ rhs.count)
    for index in 0 ..< maximumCount {
        let left = index < lhs.count ? lhs[index] : 0
        let right = index < rhs.count ? rhs[index] : 0
        difference |= left ^ right
    }
    return difference == 0
}

private func randomBytes(count: Int) -> Data {
    var generator = SystemRandomNumberGenerator()
    return Data((0 ..< count).map { _ in
        UInt8.random(in: UInt8.min ... UInt8.max, using: &generator)
    })
}
