import AudoraDomain
import Foundation

// Provider-independent production planning extracted from the qualification gate.

public enum CoachTokenEstimateMode: String, Codable, Equatable, Sendable {
    case exact
    case conservativeUpperBound
}

@_spi(CoachContextQualification)
public enum CoachTokenEstimatorError: Error, Equatable {
    case emptyIdentifier
    case invalidMaximumUTF8BytesPerToken
    case negativeTokenCount
}

/// A provider/model-specific tokenizer or a documented conservative substitute.
///
/// The implementation receives one complete model-visible provider message at a
/// time. The planner never sums independently tokenized JSON fields (which can
/// undercount at tokenizer boundaries), and it preserves provider message
/// boundaries for transcript tool calls and results.
@_spi(CoachContextQualification)
public struct CoachTokenEstimator: Sendable {
    public let identifier: String
    public let mode: CoachTokenEstimateMode
    /// A qualified upper bound used to translate a token-bounded value into a
    /// worst-case collector-byte bound.
    public let maximumUTF8BytesPerToken: Int

    private let implementation: @Sendable (Data) -> Int

    public init(
        identifier: String,
        mode: CoachTokenEstimateMode,
        maximumUTF8BytesPerToken: Int,
        implementation: @escaping @Sendable (Data) -> Int
    ) throws {
        guard !identifier.isEmpty else {
            throw CoachTokenEstimatorError.emptyIdentifier
        }
        guard maximumUTF8BytesPerToken > 0 else {
            throw CoachTokenEstimatorError.invalidMaximumUTF8BytesPerToken
        }
        self.identifier = identifier
        self.mode = mode
        self.maximumUTF8BytesPerToken = maximumUTF8BytesPerToken
        self.implementation = implementation
    }

    public func tokenCount(forUTF8 data: Data) throws -> Int {
        let count = implementation(data)
        guard count >= 0 else {
            throw CoachTokenEstimatorError.negativeTokenCount
        }
        return count
    }

    /// A conservative estimator for byte-level provider tokenizers. Known hidden
    /// special tokens still belong in `CoachProviderFraming`.
    public static func utf8ByteUpperBound() -> CoachTokenEstimator {
        try! CoachTokenEstimator(
            identifier: "utf8-byte-upper-bound-v1",
            mode: .conservativeUpperBound,
            maximumUTF8BytesPerToken: 1,
            implementation: { $0.count }
        )
    }
}

/// The exact base provider-visible instruction shared by context measurement
/// and Attempt launch. Keeping it here prevents transcript policy from drifting
/// outside the frozen model-input budget.
@_spi(CoachContextQualification)
public enum CoachProviderPinnedInstruction {
    public static func standard(outputTokenCeiling: Int) -> String {
        "Return one complete structured response that fits within the " +
            "\(outputTokenCeiling)-token output allowance. Ground claims about " +
            "attached Sessions only in complete transcripts supplied inline or " +
            "returned by read_session_transcripts. When the request needs " +
            "evidence from on-demand Session attachments, request every needed " +
            "handle together in one read_session_transcripts call. Do not split, " +
            "reorder, shrink, or retry that logical read. If a transcript read " +
            "does not return complete transcripts, do not answer around missing " +
            "evidence. If you detect that you conflated two Sessions, ask the " +
            "user to send the message again instead of presenting the answer as " +
            "grounded."
    }
}

@_spi(CoachContextQualification)
public enum CompleteToolResponseBudgetError: Error, Equatable, Sendable {
    case negativeRemainingInputTokens
    case negativeHiddenTokens
    case integerOverflow
}

/// Rechecks one complete canonical tool response against the provider's exact
/// remaining input budget.
///
/// The response is framed and tokenized as one model-visible provider message.
/// Callers supply canonical response bytes; they never estimate transcript text,
/// fields, or fragments independently.
@_spi(CoachContextQualification)
public struct CompleteToolResponseBudget: Sendable {
    public let remainingInputTokens: Int

    private let responsePrefix: Data
    private let responseSuffix: Data
    private let hiddenTokens: Int
    private let tokenEstimator: CoachTokenEstimator

    public init(
        remainingInputTokens: Int,
        responsePrefix: Data,
        responseSuffix: Data,
        hiddenTokens: Int,
        tokenEstimator: CoachTokenEstimator
    ) throws {
        guard remainingInputTokens >= 0 else {
            throw CompleteToolResponseBudgetError.negativeRemainingInputTokens
        }
        guard hiddenTokens >= 0 else {
            throw CompleteToolResponseBudgetError.negativeHiddenTokens
        }
        self.remainingInputTokens = remainingInputTokens
        self.responsePrefix = responsePrefix
        self.responseSuffix = responseSuffix
        self.hiddenTokens = hiddenTokens
        self.tokenEstimator = tokenEstimator
    }

    public func admits(canonicalResponse: Data) throws -> Bool {
        var completeFrame = Data()
        completeFrame.append(responsePrefix)
        completeFrame.append(canonicalResponse)
        completeFrame.append(responseSuffix)

        let visibleTokens = try tokenEstimator.tokenCount(forUTF8: completeFrame)
        let measured = visibleTokens.addingReportingOverflow(hiddenTokens)
        guard !measured.overflow else {
            throw CompleteToolResponseBudgetError.integerOverflow
        }
        return measured.partialValue <= remainingInputTokens
    }
}

/// Process-local authority for remeasuring an Attempt's exact fresh-handle
/// frames before any on-demand transcript bytes are disclosed.
///
/// Fresh handles have a fixed wire length, but an exact provider tokenizer may
/// still tokenize their contents differently. Keeping the qualified framing
/// and estimator here prevents the invocation coordinator from guessing a
/// remaining budget from byte counts or from the earlier planning handles.
struct AttemptTranscriptResponseBudgetAuthority: Equatable, Sendable {
    let inputCeilingTokens: Int
    let pinnedInstructionFrame: Data
    let framing: CoachProviderFraming
    let tokenEstimator: CoachTokenEstimator

    static func == (
        lhs: AttemptTranscriptResponseBudgetAuthority,
        rhs: AttemptTranscriptResponseBudgetAuthority
    ) -> Bool {
        lhs.inputCeilingTokens == rhs.inputCeilingTokens &&
            lhs.pinnedInstructionFrame == rhs.pinnedInstructionFrame &&
            lhs.framing == rhs.framing &&
            lhs.tokenEstimator.identifier == rhs.tokenEstimator.identifier &&
            lhs.tokenEstimator.mode == rhs.tokenEstimator.mode &&
            lhs.tokenEstimator.maximumUTF8BytesPerToken ==
            rhs.tokenEstimator.maximumUTF8BytesPerToken
    }

    func budget(
        reboundInitialRequest: Data,
        transcriptReadRequest: Data
    ) throws -> CompleteToolResponseBudget? {
        let instructionTokens = try tokenEstimator.tokenCount(
            forUTF8: pinnedInstructionFrame
        )
        let initialFrame = framed(
            prefix: framing.initialRequestPrefix,
            body: reboundInitialRequest,
            suffix: framing.initialRequestSuffix
        )
        let readRequestFrame = framed(
            prefix: framing.transcriptReadRequestPrefix,
            body: transcriptReadRequest,
            suffix: framing.transcriptReadRequestSuffix
        )
        let initialTokens = try tokenEstimator.tokenCount(forUTF8: initialFrame)
        let readRequestTokens = try tokenEstimator.tokenCount(forUTF8: readRequestFrame)
        let visibleRequest = instructionTokens.addingReportingOverflow(initialTokens)
        guard !visibleRequest.overflow else {
            throw CompleteToolResponseBudgetError.integerOverflow
        }
        let visible = visibleRequest.partialValue.addingReportingOverflow(
            readRequestTokens
        )
        guard !visible.overflow else {
            throw CompleteToolResponseBudgetError.integerOverflow
        }
        let beforeResponse = visible.partialValue.addingReportingOverflow(
            framing.initialRequestHiddenTokens
        )
        guard !beforeResponse.overflow,
              beforeResponse.partialValue <= inputCeilingTokens
        else {
            return nil
        }
        return try CompleteToolResponseBudget(
            remainingInputTokens: inputCeilingTokens - beforeResponse.partialValue,
            responsePrefix: framing.transcriptReadResponsePrefix,
            responseSuffix: framing.transcriptReadResponseSuffix,
            hiddenTokens: framing.transcriptReadExchangeHiddenTokens,
            tokenEstimator: tokenEstimator
        )
    }

    func replacingPinnedInstruction(_ instruction: String) -> Self {
        AttemptTranscriptResponseBudgetAuthority(
            inputCeilingTokens: inputCeilingTokens,
            pinnedInstructionFrame: Data(instruction.utf8),
            framing: framing,
            tokenEstimator: tokenEstimator
        )
    }

    func admitsInitialRequest(_ reboundInitialRequest: Data) throws -> Bool {
        let instructionTokens = try tokenEstimator.tokenCount(
            forUTF8: pinnedInstructionFrame
        )
        let initialFrame = framed(
            prefix: framing.initialRequestPrefix,
            body: reboundInitialRequest,
            suffix: framing.initialRequestSuffix
        )
        let initialTokens = try tokenEstimator.tokenCount(forUTF8: initialFrame)
        let visible = instructionTokens.addingReportingOverflow(initialTokens)
        guard !visible.overflow else {
            throw CompleteToolResponseBudgetError.integerOverflow
        }
        let total = visible.partialValue.addingReportingOverflow(
            framing.initialRequestHiddenTokens
        )
        guard !total.overflow else {
            throw CompleteToolResponseBudgetError.integerOverflow
        }
        return total.partialValue <= inputCeilingTokens
    }

    func admitsMaximumTranscriptExchange(
        reboundInitialRequest: Data,
        transcriptReadRequest: Data,
        transcriptReadResponse: Data
    ) throws -> Bool {
        guard let responseBudget = try budget(
            reboundInitialRequest: reboundInitialRequest,
            transcriptReadRequest: transcriptReadRequest
        ) else { return false }
        return try responseBudget.admits(canonicalResponse: transcriptReadResponse)
    }

    private func framed(prefix: Data, body: Data, suffix: Data) -> Data {
        var result = Data()
        result.reserveCapacity(prefix.count + body.count + suffix.count)
        result.append(prefix)
        result.append(body)
        result.append(suffix)
        return result
    }
}

@_spi(CoachContextQualification)
public struct CoachContextBudget: Equatable, Sendable {
    public let contextWindowTokens: Int
    public let responseReservedTokens: Int
    public let safetyMarginTokens: Int

    public init(
        contextWindowTokens: Int,
        responseReservedTokens: Int,
        safetyMarginTokens: Int
    ) {
        self.contextWindowTokens = contextWindowTokens
        self.responseReservedTokens = responseReservedTokens
        self.safetyMarginTokens = safetyMarginTokens
    }
}

/// The app-only fields from `CoachProviderDescriptor.json`.
@_spi(CoachContextQualification)
public struct CoachProviderDescriptor: Equatable, Sendable {
    public let displayName: String
    public let contextBudget: CoachContextBudget
    public let coachMemoryMaxTokens: Int

    public init(
        displayName: String,
        contextBudget: CoachContextBudget,
        coachMemoryMaxTokens: Int
    ) {
        self.displayName = displayName
        self.contextBudget = contextBudget
        self.coachMemoryMaxTokens = coachMemoryMaxTokens
    }
}

/// Provider and adapter bytes that are outside the Coach JSON contracts.
///
/// Prefixes and suffixes include tool definitions, role wrappers, and adapter
/// syntax that is actually visible to the provider model. The shared pinned
/// instruction is measured as its own exact provider message.
/// Hidden token counts cover provider special tokens that have no UTF-8 spelling.
@_spi(CoachContextQualification)
public struct CoachProviderFraming: Equatable, Sendable {
    public let initialRequestPrefix: Data
    public let initialRequestSuffix: Data
    public let transcriptReadRequestPrefix: Data
    public let transcriptReadRequestSuffix: Data
    public let transcriptReadResponsePrefix: Data
    public let transcriptReadResponseSuffix: Data
    public let minimumResponsePrefix: Data
    public let minimumResponseSuffix: Data
    /// Hidden special-token overhead for the pinned-instruction message and
    /// the structured initial-request message together.
    public let initialRequestHiddenTokens: Int
    public let transcriptReadExchangeHiddenTokens: Int
    public let minimumResponseHiddenTokens: Int

    public init(
        initialRequestPrefix: Data,
        initialRequestSuffix: Data,
        transcriptReadRequestPrefix: Data,
        transcriptReadRequestSuffix: Data,
        transcriptReadResponsePrefix: Data,
        transcriptReadResponseSuffix: Data,
        minimumResponsePrefix: Data,
        minimumResponseSuffix: Data,
        initialRequestHiddenTokens: Int,
        transcriptReadExchangeHiddenTokens: Int,
        minimumResponseHiddenTokens: Int
    ) {
        self.initialRequestPrefix = initialRequestPrefix
        self.initialRequestSuffix = initialRequestSuffix
        self.transcriptReadRequestPrefix = transcriptReadRequestPrefix
        self.transcriptReadRequestSuffix = transcriptReadRequestSuffix
        self.transcriptReadResponsePrefix = transcriptReadResponsePrefix
        self.transcriptReadResponseSuffix = transcriptReadResponseSuffix
        self.minimumResponsePrefix = minimumResponsePrefix
        self.minimumResponseSuffix = minimumResponseSuffix
        self.initialRequestHiddenTokens = initialRequestHiddenTokens
        self.transcriptReadExchangeHiddenTokens = transcriptReadExchangeHiddenTokens
        self.minimumResponseHiddenTokens = minimumResponseHiddenTokens
    }
}

/// Qualified implementation details that intentionally remain outside provider DTOs.
@_spi(CoachContextQualification)
public struct CoachProviderEstimationPolicy: Sendable {
    public let providerIdentifier: String
    public let responseCollectorByteCeiling: Int
    public let framing: CoachProviderFraming
    public let attachmentProjectionPolicy: CoachAttachmentProjectionPolicy
    public var tokenEstimator: CoachTokenEstimator {
        attachmentProjectionPolicy.tokenEstimator
    }

    public init(
        providerIdentifier: String,
        responseCollectorByteCeiling: Int,
        framing: CoachProviderFraming,
        attachmentProjectionPolicy: CoachAttachmentProjectionPolicy
    ) {
        self.providerIdentifier = providerIdentifier
        self.responseCollectorByteCeiling = responseCollectorByteCeiling
        self.framing = framing
        self.attachmentProjectionPolicy = attachmentProjectionPolicy
    }
}

/// Immutable provider/model configuration that must match at both context
/// measurement and transport launch.
///
/// The estimator implementation is represented by its qualified identifier and
/// declared behavior. Qualification owns the invariant that an identifier is
/// never reused for different tokenizer behavior. Provider identity likewise
/// names the exact qualified model/adapter build, not merely a product family.
@_spi(CoachContextQualification)
public struct CoachProviderConfigurationBinding: Equatable, Sendable {
    public let descriptor: CoachProviderDescriptor
    public let providerIdentifier: String
    public let responseCollectorByteCeiling: Int
    public let framing: CoachProviderFraming
    public let maximumInlineTranscriptTokens: Int
    public let estimatorIdentifier: String
    public let estimatorMode: CoachTokenEstimateMode
    public let estimatorMaximumUTF8BytesPerToken: Int

    public init(
        descriptor: CoachProviderDescriptor,
        policy: CoachProviderEstimationPolicy
    ) {
        self.descriptor = descriptor
        providerIdentifier = policy.providerIdentifier
        responseCollectorByteCeiling = policy.responseCollectorByteCeiling
        framing = policy.framing
        maximumInlineTranscriptTokens =
            policy.attachmentProjectionPolicy.maximumInlineTranscriptTokens
        estimatorIdentifier = policy.tokenEstimator.identifier
        estimatorMode = policy.tokenEstimator.mode
        estimatorMaximumUTF8BytesPerToken =
            policy.tokenEstimator.maximumUTF8BytesPerToken
    }
}

/// One bounded Attempt-scoped handle used by both the Coach Request and the
/// conservatively reserved transcript-read exchange.
@_spi(CoachContextQualification)
public typealias PreparedCoachTranscriptHandle = CoachProviderTranscriptHandle

@_spi(CoachContextQualification)
public typealias PreparedCoachTranscriptHandleError = CoachProviderTranscriptHandleError

@_spi(CoachContextQualification)
public enum PreparedCoachAttachment: Equatable, Sendable {
    /// The complete `SessionAttachmentInline` provider value.
    case inline(requestValue: CanonicalJSONValue)

    /// The request descriptor plus values needed to reserve one complete atomic
    /// `ReadSessionTranscripts` exchange.
    case onDemand(
        requestValue: CanonicalJSONValue,
        sessionTranscriptHandle: PreparedCoachTranscriptHandle,
        transcriptDisclosure: CanonicalJSONValue,
        sourceAttachment: ChatSessionAttachment,
        revisionSHA256: String
    )

    func authoritativeRequestValue() throws -> CanonicalJSONValue {
        switch self {
        case let .inline(requestValue):
            return requestValue
        case let .onDemand(requestValue, handle, _, _, _):
            guard case var .object(fields) = requestValue,
                  fields["sessionTranscriptHandle"] == .string(handle.rawValue)
            else {
                throw CoachContextEstimationError.sessionTranscriptHandleMismatch
            }
            // Reinstall the typed value so this one authority feeds both payloads.
            fields["sessionTranscriptHandle"] = .string(handle.rawValue)
            return .object(fields)
        }
    }
}

@_spi(CoachContextQualification)
public struct PreparedCoachContext: Equatable, Sendable {
    public let profile: CanonicalJSONValue
    public let memory: CanonicalJSONValue
    public let history: [CanonicalJSONValue]
    public let trigger: CanonicalJSONValue
    public let triggerCategory: CoachContextCostCategory
    public let attachments: [PreparedCoachAttachment]

    public init(
        profile: CanonicalJSONValue,
        memory: CanonicalJSONValue,
        history: [CanonicalJSONValue],
        trigger: CanonicalJSONValue,
        triggerCategory: CoachContextCostCategory = .draft,
        attachments: [PreparedCoachAttachment]
    ) {
        self.profile = profile
        self.memory = memory
        self.history = history
        self.trigger = trigger
        self.triggerCategory = triggerCategory
        self.attachments = attachments
    }

    public static func minimumRequest(maximumMemory: CanonicalJSONValue) -> Self {
        PreparedCoachContext(
            profile: .object(["statements": .array([])]),
            memory: maximumMemory,
            history: [],
            trigger: .object([
                "kind": .string("userMessage"),
                "text": .string("x"),
            ]),
            attachments: []
        )
    }
}

public enum CoachContextCostCategory: String, CaseIterable, Codable, Hashable, Sendable {
    case profile
    case memory
    case history
    case draft
    case framing
    case attachments
    case transcriptExchange
    case responseReserve
    case safetyMargin
}

public struct CoachContextComponentCost: Equatable, Sendable {
    public let utf8ByteCount: Int
    public let estimatedTokenCount: Int

    public init(utf8ByteCount: Int, estimatedTokenCount: Int) {
        self.utf8ByteCount = utf8ByteCount
        self.estimatedTokenCount = estimatedTokenCount
    }
}

struct CoachContextCapacityLowerBoundEstimate: Equatable, Sendable {
    let minimumCompleteInputTokens: Int
    let inputCeilingTokens: Int
    let reservedResponseTokens: Int
    let safetyMarginTokens: Int
    let minimumTotalContextTokens: Int
    let minimumComponentCosts: [CoachContextCostCategory: CoachContextComponentCost]
    let estimatorIdentifier: String
}

@_spi(CoachContextQualification)
public struct CanonicalCoachExchange: Equatable, Sendable {
    public let pinnedInstruction: String
    public let request: Data
    public let transcriptReadRequest: Data?
    public let transcriptReadResponse: Data?
    /// Complete framed provider messages in context order. Message boundaries
    /// are semantically significant and must not be collapsed by an adapter.
    public let modelInputFrames: [Data]
    /// A byte-count/debug projection only; this is not itself a provider payload.
    public let completeModelInput: Data
    /// Handles used while measuring the frozen semantic exchange. Provider
    /// Attempts receive fresh routes separately and adapters rebind them at the
    /// transport seam without rebuilding semantic context.
    public let preparedTranscriptHandles: [PreparedCoachTranscriptHandle]

    /// The typed request and disclosure routes are deliberately kept behind the
    /// Application boundary. Attempt setup uses them to replace only descriptor
    /// handle fields; provider adapters never parse or rewrite frozen JSON bytes.
    let structuralRequest: CanonicalJSONValue?
    let preparedTranscriptRoutes: [CanonicalCoachTranscriptRoute]
    let transcriptResponseBudgetAuthority:
        AttemptTranscriptResponseBudgetAuthority?
    /// Frozen qualified limits used to treat the provider's complete output as
    /// untrusted bytes. Provider adapters cannot replace these values after
    /// context admission.
    let responseValidationAuthority: CoachResponseValidationAuthority?

    public init(
        pinnedInstruction: String,
        request: Data,
        transcriptReadRequest: Data?,
        transcriptReadResponse: Data?,
        modelInputFrames: [Data],
        completeModelInput: Data,
        preparedTranscriptHandles: [PreparedCoachTranscriptHandle] = []
    ) {
        self.pinnedInstruction = pinnedInstruction
        self.request = request
        self.transcriptReadRequest = transcriptReadRequest
        self.transcriptReadResponse = transcriptReadResponse
        self.modelInputFrames = modelInputFrames
        self.completeModelInput = completeModelInput
        self.preparedTranscriptHandles = preparedTranscriptHandles
        structuralRequest = nil
        preparedTranscriptRoutes = []
        transcriptResponseBudgetAuthority = nil
        responseValidationAuthority = nil
    }

    init(
        pinnedInstruction: String,
        request: Data,
        transcriptReadRequest: Data?,
        transcriptReadResponse: Data?,
        modelInputFrames: [Data],
        completeModelInput: Data,
        preparedTranscriptHandles: [PreparedCoachTranscriptHandle],
        structuralRequest: CanonicalJSONValue,
        preparedTranscriptRoutes: [CanonicalCoachTranscriptRoute],
        transcriptResponseBudgetAuthority:
            AttemptTranscriptResponseBudgetAuthority?,
        responseValidationAuthority: CoachResponseValidationAuthority? = nil
    ) {
        self.pinnedInstruction = pinnedInstruction
        self.request = request
        self.transcriptReadRequest = transcriptReadRequest
        self.transcriptReadResponse = transcriptReadResponse
        self.modelInputFrames = modelInputFrames
        self.completeModelInput = completeModelInput
        self.preparedTranscriptHandles = preparedTranscriptHandles
        self.structuralRequest = structuralRequest
        self.preparedTranscriptRoutes = preparedTranscriptRoutes
        self.transcriptResponseBudgetAuthority = transcriptResponseBudgetAuthority
        self.responseValidationAuthority = responseValidationAuthority
    }
}

struct CanonicalCoachTranscriptRoute: Equatable, Sendable {
    let requestAttachmentIndex: Int
    let preparedHandle: PreparedCoachTranscriptHandle
    let disclosure: CanonicalJSONValue
    let sourceAttachment: ChatSessionAttachment
    let revisionSHA256: String
}

@_spi(CoachContextQualification)
public struct CoachContextEstimate: Equatable, Sendable {
    /// The authoritative whole-envelope estimate used for admission.
    public let completeInputTokens: Int
    public let inputCeilingTokens: Int
    public let reservedResponseTokens: Int
    public let safetyMarginTokens: Int
    public let totalContextTokens: Int
    public let responseCollectorByteCeiling: Int
    public let fits: Bool
    public let componentCosts: [CoachContextCostCategory: CoachContextComponentCost]
    public let exchange: CanonicalCoachExchange
    public let estimatorIdentifier: String
    public let estimatorMode: CoachTokenEstimateMode

    public init(
        completeInputTokens: Int,
        inputCeilingTokens: Int,
        reservedResponseTokens: Int,
        safetyMarginTokens: Int,
        totalContextTokens: Int,
        responseCollectorByteCeiling: Int,
        fits: Bool,
        componentCosts: [CoachContextCostCategory: CoachContextComponentCost],
        exchange: CanonicalCoachExchange,
        estimatorIdentifier: String,
        estimatorMode: CoachTokenEstimateMode
    ) {
        self.completeInputTokens = completeInputTokens
        self.inputCeilingTokens = inputCeilingTokens
        self.reservedResponseTokens = reservedResponseTokens
        self.safetyMarginTokens = safetyMarginTokens
        self.totalContextTokens = totalContextTokens
        self.responseCollectorByteCeiling = responseCollectorByteCeiling
        self.fits = fits
        self.componentCosts = componentCosts
        self.exchange = exchange
        self.estimatorIdentifier = estimatorIdentifier
        self.estimatorMode = estimatorMode
    }
}

@_spi(CoachContextQualification)
public enum CoachContextEstimationError: Error, Equatable {
    case duplicateSessionTranscriptHandle
    case sessionTranscriptHandleMismatch
    case invalidDescriptor(CoachProviderDescriptorValidationError)
    case integerOverflow
}

@_spi(CoachContextQualification)
public struct CoachContextPlanner: Sendable {
    public init() {}

    public func estimate(
        _ context: PreparedCoachContext,
        descriptor: CoachProviderDescriptor,
        policy: CoachProviderEstimationPolicy
    ) throws -> CoachContextEstimate {
        if let descriptorError = basicValidationError(
            descriptor: descriptor,
            policy: policy
        ) {
            throw CoachContextEstimationError.invalidDescriptor(descriptorError)
        }

        let pinnedInstruction = CoachProviderPinnedInstruction.standard(
            outputTokenCeiling: descriptor.contextBudget.responseReservedTokens
        )
        let prepared = try buildSegments(
            context: context,
            framing: policy.framing,
            pinnedInstruction: pinnedInstruction
        )
        var completeInputTokens = 0
        for unit in prepared.tokenizationUnits {
            completeInputTokens = try checkedAdd(
                completeInputTokens,
                policy.tokenEstimator.tokenCount(forUTF8: unit)
            )
        }
        completeInputTokens = try checkedAdd(
            completeInputTokens,
            policy.framing.initialRequestHiddenTokens
        )
        if prepared.transcriptReadRequest != nil {
            completeInputTokens = try checkedAdd(
                completeInputTokens,
                policy.framing.transcriptReadExchangeHiddenTokens
            )
        }

        let reservedAndMargin = try checkedAdd(
            descriptor.contextBudget.responseReservedTokens,
            descriptor.contextBudget.safetyMarginTokens
        )
        let inputCeiling = descriptor.contextBudget.contextWindowTokens - reservedAndMargin
        let totalContextTokens = try checkedAdd(completeInputTokens, reservedAndMargin)
        let exchange = CanonicalCoachExchange(
            pinnedInstruction: pinnedInstruction,
            request: prepared.request,
            transcriptReadRequest: prepared.transcriptReadRequest,
            transcriptReadResponse: prepared.transcriptReadResponse,
            modelInputFrames: prepared.tokenizationUnits,
            completeModelInput: prepared.completeInput,
            preparedTranscriptHandles: prepared.handles,
            structuralRequest: prepared.structuralRequest,
            preparedTranscriptRoutes: prepared.transcriptRoutes,
            transcriptResponseBudgetAuthority:
                AttemptTranscriptResponseBudgetAuthority(
                    inputCeilingTokens: inputCeiling,
                    pinnedInstructionFrame: Data(pinnedInstruction.utf8),
                    framing: policy.framing,
                    tokenEstimator: policy.tokenEstimator
                ),
            responseValidationAuthority: CoachResponseValidationAuthority(
                responseReservedTokens: descriptor.contextBudget.responseReservedTokens,
                responseCollectorByteCeiling: policy.responseCollectorByteCeiling,
                coachMemoryMaxTokens: descriptor.coachMemoryMaxTokens,
                framing: policy.framing,
                tokenEstimator: policy.tokenEstimator
            )
        )

        var componentCosts: [CoachContextCostCategory: CoachContextComponentCost] = [:]
        for component in CoachContextCostCategory.allCases {
            switch component {
            case .responseReserve:
                componentCosts[component] = CoachContextComponentCost(
                    utf8ByteCount: 0,
                    estimatedTokenCount: descriptor.contextBudget.responseReservedTokens
                )
            case .safetyMargin:
                componentCosts[component] = CoachContextComponentCost(
                    utf8ByteCount: 0,
                    estimatedTokenCount: descriptor.contextBudget.safetyMarginTokens
                )
            default:
                let data = prepared.componentData[component, default: Data()]
                var tokens = try policy.tokenEstimator.tokenCount(forUTF8: data)
                if component == .framing {
                    tokens = try checkedAdd(tokens, policy.framing.initialRequestHiddenTokens)
                    if prepared.transcriptReadRequest != nil {
                        tokens = try checkedAdd(
                            tokens,
                            policy.framing.transcriptReadExchangeHiddenTokens
                        )
                    }
                }
                componentCosts[component] = CoachContextComponentCost(
                    utf8ByteCount: data.count,
                    estimatedTokenCount: tokens
                )
            }
        }

        return CoachContextEstimate(
            completeInputTokens: completeInputTokens,
            inputCeilingTokens: inputCeiling,
            reservedResponseTokens: descriptor.contextBudget.responseReservedTokens,
            safetyMarginTokens: descriptor.contextBudget.safetyMarginTokens,
            totalContextTokens: totalContextTokens,
            responseCollectorByteCeiling: policy.responseCollectorByteCeiling,
            fits: completeInputTokens <= inputCeiling,
            componentCosts: componentCosts,
            exchange: exchange,
            estimatorIdentifier: policy.tokenEstimator.identifier,
            estimatorMode: policy.tokenEstimator.mode
        )
    }

    /// Computes a deterministic floor from the exact canonical exchange bytes
    /// and the qualified estimator's maximum bytes per token. It is used only
    /// to prove that a Chat creation configuration is impossible while the
    /// provider cannot supply current Profile context.
    func estimateCapacityLowerBound(
        _ context: PreparedCoachContext,
        descriptor: CoachProviderDescriptor,
        policy: CoachProviderEstimationPolicy
    ) throws -> CoachContextCapacityLowerBoundEstimate {
        if let descriptorError = basicValidationError(
            descriptor: descriptor,
            policy: policy
        ) {
            throw CoachContextEstimationError.invalidDescriptor(descriptorError)
        }

        let pinnedInstruction = CoachProviderPinnedInstruction.standard(
            outputTokenCeiling: descriptor.contextBudget.responseReservedTokens
        )
        let prepared = try buildSegments(
            context: context,
            framing: policy.framing,
            pinnedInstruction: pinnedInstruction
        )
        let maximumBytesPerToken = policy.tokenEstimator.maximumUTF8BytesPerToken
        var minimumCompleteInputTokens = 0
        for unit in prepared.tokenizationUnits {
            minimumCompleteInputTokens = try checkedAdd(
                minimumCompleteInputTokens,
                minimumTokenCount(
                    forUTF8ByteCount: unit.count,
                    maximumBytesPerToken: maximumBytesPerToken
                )
            )
        }
        minimumCompleteInputTokens = try checkedAdd(
            minimumCompleteInputTokens,
            policy.framing.initialRequestHiddenTokens
        )
        if prepared.transcriptReadRequest != nil {
            minimumCompleteInputTokens = try checkedAdd(
                minimumCompleteInputTokens,
                policy.framing.transcriptReadExchangeHiddenTokens
            )
        }

        let reservedAndMargin = try checkedAdd(
            descriptor.contextBudget.responseReservedTokens,
            descriptor.contextBudget.safetyMarginTokens
        )
        let inputCeiling = descriptor.contextBudget.contextWindowTokens -
            reservedAndMargin
        let minimumTotalContextTokens = try checkedAdd(
            minimumCompleteInputTokens,
            reservedAndMargin
        )

        var minimumComponentCosts:
            [CoachContextCostCategory: CoachContextComponentCost] = [:]
        for component in CoachContextCostCategory.allCases {
            switch component {
            case .responseReserve:
                minimumComponentCosts[component] = CoachContextComponentCost(
                    utf8ByteCount: 0,
                    estimatedTokenCount: descriptor.contextBudget.responseReservedTokens
                )
            case .safetyMargin:
                minimumComponentCosts[component] = CoachContextComponentCost(
                    utf8ByteCount: 0,
                    estimatedTokenCount: descriptor.contextBudget.safetyMarginTokens
                )
            default:
                let data = prepared.componentData[component, default: Data()]
                var minimumTokens = minimumTokenCount(
                    forUTF8ByteCount: data.count,
                    maximumBytesPerToken: maximumBytesPerToken
                )
                if component == .framing {
                    minimumTokens = try checkedAdd(
                        minimumTokens,
                        policy.framing.initialRequestHiddenTokens
                    )
                    if prepared.transcriptReadRequest != nil {
                        minimumTokens = try checkedAdd(
                            minimumTokens,
                            policy.framing.transcriptReadExchangeHiddenTokens
                        )
                    }
                }
                minimumComponentCosts[component] = CoachContextComponentCost(
                    utf8ByteCount: data.count,
                    estimatedTokenCount: minimumTokens
                )
            }
        }

        return CoachContextCapacityLowerBoundEstimate(
            minimumCompleteInputTokens: minimumCompleteInputTokens,
            inputCeilingTokens: inputCeiling,
            reservedResponseTokens: descriptor.contextBudget.responseReservedTokens,
            safetyMarginTokens: descriptor.contextBudget.safetyMarginTokens,
            minimumTotalContextTokens: minimumTotalContextTokens,
            minimumComponentCosts: minimumComponentCosts,
            estimatorIdentifier: policy.tokenEstimator.identifier
        )
    }

    private func buildSegments(
        context: PreparedCoachContext,
        framing: CoachProviderFraming,
        pinnedInstruction: String
    ) throws -> PreparedSegments {
        let history = CanonicalJSON.serialize(.array(context.history))
        let memory = CanonicalJSON.serialize(context.memory)
        let profile = CanonicalJSON.serialize(context.profile)
        let trigger = CanonicalJSON.serialize(context.trigger)

        var requestSegments: [LabeledSegment] = [
            LabeledSegment(.framing, Data("{\"conversation\":{\"history\":".utf8)),
            LabeledSegment(.history, history),
            LabeledSegment(.framing, Data(",\"memory\":".utf8)),
            LabeledSegment(.memory, memory),
            LabeledSegment(.framing, Data(",\"trigger\":".utf8)),
            LabeledSegment(context.triggerCategory, trigger),
            LabeledSegment(.framing, Data("},\"profile\":".utf8)),
            LabeledSegment(.profile, profile),
            LabeledSegment(.framing, Data(",\"sessionAttachments\":[".utf8)),
        ]

        var handles: [PreparedCoachTranscriptHandle] = []
        var disclosures: [CanonicalJSONValue] = []
        var transcriptRoutes: [CanonicalCoachTranscriptRoute] = []
        var seenHandles: Set<String> = []
        for (index, attachment) in context.attachments.enumerated() {
            if index > 0 {
                requestSegments.append(LabeledSegment(.framing, Data(",".utf8)))
            }
            let requestValue = try attachment.authoritativeRequestValue()
            switch attachment {
            case .inline:
                requestSegments.append(
                    LabeledSegment(.attachments, CanonicalJSON.serialize(requestValue))
                )
            case let .onDemand(
                _, handle, disclosure, sourceAttachment, revisionSHA256
            ):
                guard seenHandles.insert(handle.rawValue).inserted else {
                    throw CoachContextEstimationError.duplicateSessionTranscriptHandle
                }
                requestSegments.append(
                    LabeledSegment(.attachments, CanonicalJSON.serialize(requestValue))
                )
                handles.append(handle)
                disclosures.append(disclosure)
                transcriptRoutes.append(
                    CanonicalCoachTranscriptRoute(
                        requestAttachmentIndex: index,
                        preparedHandle: handle,
                        disclosure: disclosure,
                        sourceAttachment: sourceAttachment,
                        revisionSHA256: revisionSHA256
                    )
                )
            }
        }
        requestSegments.append(LabeledSegment(.framing, Data("]}".utf8)))

        let request = joined(requestSegments)
        let structuralRequest = try requestValue(context: context)
        let canonicalRequest = CanonicalJSON.serialize(structuralRequest)
        precondition(request == canonicalRequest, "segmented request must remain canonical")

        var initialRequestSegments: [LabeledSegment] = [
            LabeledSegment(.framing, framing.initialRequestPrefix),
        ]
        initialRequestSegments.append(contentsOf: requestSegments)
        initialRequestSegments.append(LabeledSegment(.framing, framing.initialRequestSuffix))
        let pinnedInstructionSegment = LabeledSegment(
            .framing,
            Data(pinnedInstruction.utf8)
        )
        var completeSegments = [pinnedInstructionSegment]
        completeSegments.append(contentsOf: initialRequestSegments)
        var tokenizationUnits = [
            pinnedInstructionSegment.data,
            joined(initialRequestSegments),
        ]

        var readRequest: Data?
        var readResponse: Data?
        if !handles.isEmpty {
            let requestValue = CanonicalJSONValue.object([
                "sessionTranscriptHandles": .array(
                    handles.map { .string($0.rawValue) }
                ),
            ])
            let responseValue = CanonicalJSONValue.object([
                "kind": .string("complete"),
                "transcripts": .array(disclosures),
            ])
            let serializedRequest = CanonicalJSON.serialize(requestValue)
            let serializedResponse = CanonicalJSON.serialize(responseValue)
            readRequest = serializedRequest
            readResponse = serializedResponse
            let readRequestSegments = [
                LabeledSegment(.framing, framing.transcriptReadRequestPrefix),
                LabeledSegment(.transcriptExchange, serializedRequest),
                LabeledSegment(.framing, framing.transcriptReadRequestSuffix),
            ]
            let readResponseSegments = [
                LabeledSegment(.framing, framing.transcriptReadResponsePrefix),
                LabeledSegment(.transcriptExchange, serializedResponse),
                LabeledSegment(.framing, framing.transcriptReadResponseSuffix),
            ]
            completeSegments.append(contentsOf: readRequestSegments)
            completeSegments.append(contentsOf: readResponseSegments)
            tokenizationUnits.append(joined(readRequestSegments))
            tokenizationUnits.append(joined(readResponseSegments))
        }

        var componentData: [CoachContextCostCategory: Data] = [:]
        for segment in completeSegments {
            componentData[segment.component, default: Data()].append(segment.data)
        }

        return PreparedSegments(
            request: request,
            transcriptReadRequest: readRequest,
            transcriptReadResponse: readResponse,
            completeInput: joined(completeSegments),
            tokenizationUnits: tokenizationUnits,
            componentData: componentData,
            handles: handles,
            structuralRequest: structuralRequest,
            transcriptRoutes: transcriptRoutes
        )
    }

    private func requestValue(context: PreparedCoachContext) throws -> CanonicalJSONValue {
        let attachments = try context.attachments.map { attachment in
            try attachment.authoritativeRequestValue()
        }
        return .object([
            "profile": context.profile,
            "conversation": .object([
                "history": .array(context.history),
                "memory": context.memory,
                "trigger": context.trigger,
            ]),
            "sessionAttachments": .array(attachments),
        ])
    }
}

@_spi(CoachContextQualification)
public enum CoachProviderDescriptorValidationError: Error, Equatable, Sendable {
    case emptyDisplayName
    case emptyProviderIdentifier
    case contextWindowMustBePositive
    case responseReserveMustBePositive
    case safetyMarginMustBeNonnegative
    case coachMemoryMaximumMustBePositive
    case responseCollectorByteCeilingMustBePositive
    case hiddenFramingTokensMustBeNonnegative
    case reserveAndSafetyMarginReachContextWindow
    case invalidMaximumMemoryFixture
    case maximumMemoryFixtureTokenMismatch(declared: Int, measured: Int)
    case maximumMemoryDoesNotFitMinimumRequest(required: Int, ceiling: Int)
    case maximumMemoryDoesNotFitMinimumResponseTokens(required: Int, ceiling: Int)
    case maximumMemoryDoesNotFitResponseCollectorBytes(required: Int, ceiling: Int)
    case integerOverflow
}

@_spi(CoachContextQualification)
public struct QualifiedCoachProviderDescriptor: Equatable, Sendable {
    public let descriptor: CoachProviderDescriptor
    public let providerIdentifier: String
    public let estimatorIdentifier: String
    public let estimatorMode: CoachTokenEstimateMode
    public let inputCeilingTokens: Int
    public let maximumMemoryTokens: Int
    public let minimumRequestWithMaximumMemoryTokens: Int
    public let minimumResponseWithMaximumMemoryTokens: Int
    public let minimumResponseWithMaximumMemoryBytes: Int
    public let responseCollectorByteCeiling: Int

    public init(
        descriptor: CoachProviderDescriptor,
        providerIdentifier: String,
        estimatorIdentifier: String,
        estimatorMode: CoachTokenEstimateMode,
        inputCeilingTokens: Int,
        maximumMemoryTokens: Int,
        minimumRequestWithMaximumMemoryTokens: Int,
        minimumResponseWithMaximumMemoryTokens: Int,
        minimumResponseWithMaximumMemoryBytes: Int,
        responseCollectorByteCeiling: Int
    ) {
        self.descriptor = descriptor
        self.providerIdentifier = providerIdentifier
        self.estimatorIdentifier = estimatorIdentifier
        self.estimatorMode = estimatorMode
        self.inputCeilingTokens = inputCeilingTokens
        self.maximumMemoryTokens = maximumMemoryTokens
        self.minimumRequestWithMaximumMemoryTokens = minimumRequestWithMaximumMemoryTokens
        self.minimumResponseWithMaximumMemoryTokens = minimumResponseWithMaximumMemoryTokens
        self.minimumResponseWithMaximumMemoryBytes = minimumResponseWithMaximumMemoryBytes
        self.responseCollectorByteCeiling = responseCollectorByteCeiling
    }
}

@_spi(CoachContextQualification)
public struct CoachProviderDescriptorQualifier: Sendable {
    private let planner: CoachContextPlanner

    public init(planner: CoachContextPlanner = CoachContextPlanner()) {
        self.planner = planner
    }

    /// Validates the cross-field invariants that JSON Schema cannot express.
    ///
    /// `maximumMemory` is a provider qualification fixture and must measure exactly
    /// to the descriptor's declared Memory ceiling. This prevents qualification
    /// with a conveniently smaller snapshot.
    public func qualify(
        descriptor: CoachProviderDescriptor,
        policy: CoachProviderEstimationPolicy,
        maximumMemory: CanonicalJSONValue
    ) throws -> QualifiedCoachProviderDescriptor {
        if let error = basicValidationError(descriptor: descriptor, policy: policy) {
            throw error
        }
        guard isStructurallyValidCoachMemory(maximumMemory) else {
            throw CoachProviderDescriptorValidationError.invalidMaximumMemoryFixture
        }

        let serializedMemory = CanonicalJSON.serialize(maximumMemory)
        let memoryTokens = try policy.tokenEstimator.tokenCount(forUTF8: serializedMemory)
        guard memoryTokens == descriptor.coachMemoryMaxTokens else {
            throw CoachProviderDescriptorValidationError.maximumMemoryFixtureTokenMismatch(
                declared: descriptor.coachMemoryMaxTokens,
                measured: memoryTokens
            )
        }

        let requestEstimate = try planner.estimate(
            .minimumRequest(maximumMemory: maximumMemory),
            descriptor: descriptor,
            policy: policy
        )
        guard requestEstimate.fits else {
            throw CoachProviderDescriptorValidationError.maximumMemoryDoesNotFitMinimumRequest(
                required: requestEstimate.completeInputTokens,
                ceiling: requestEstimate.inputCeilingTokens
            )
        }

        let minimumResponse = CanonicalJSON.serialize(
            .object(["newMemory": maximumMemory])
        )
        var framedResponse = Data()
        framedResponse.append(policy.framing.minimumResponsePrefix)
        framedResponse.append(minimumResponse)
        framedResponse.append(policy.framing.minimumResponseSuffix)
        var responseTokens = try policy.tokenEstimator.tokenCount(forUTF8: framedResponse)
        do {
            responseTokens = try checkedAdd(
                responseTokens,
                policy.framing.minimumResponseHiddenTokens
            )
        } catch {
            throw CoachProviderDescriptorValidationError.integerOverflow
        }

        guard responseTokens <= descriptor.contextBudget.responseReservedTokens else {
            throw CoachProviderDescriptorValidationError
                .maximumMemoryDoesNotFitMinimumResponseTokens(
                    required: responseTokens,
                    ceiling: descriptor.contextBudget.responseReservedTokens
                )
        }
        let maximumMemoryBytes: Int
        let maximumResponseBytes: Int
        do {
            maximumMemoryBytes = try checkedMultiply(
                descriptor.coachMemoryMaxTokens,
                policy.tokenEstimator.maximumUTF8BytesPerToken
            )
            let responseWrapperBytes = minimumResponse.count - serializedMemory.count
            maximumResponseBytes = try checkedAdd(responseWrapperBytes, maximumMemoryBytes)
        } catch {
            throw CoachProviderDescriptorValidationError.integerOverflow
        }
        let requiredCollectorBytes = max(minimumResponse.count, maximumResponseBytes)
        guard requiredCollectorBytes <= policy.responseCollectorByteCeiling else {
            throw CoachProviderDescriptorValidationError
                .maximumMemoryDoesNotFitResponseCollectorBytes(
                    required: requiredCollectorBytes,
                    ceiling: policy.responseCollectorByteCeiling
                )
        }

        return QualifiedCoachProviderDescriptor(
            descriptor: descriptor,
            providerIdentifier: policy.providerIdentifier,
            estimatorIdentifier: policy.tokenEstimator.identifier,
            estimatorMode: policy.tokenEstimator.mode,
            inputCeilingTokens: requestEstimate.inputCeilingTokens,
            maximumMemoryTokens: memoryTokens,
            minimumRequestWithMaximumMemoryTokens: requestEstimate.completeInputTokens,
            minimumResponseWithMaximumMemoryTokens: responseTokens,
            minimumResponseWithMaximumMemoryBytes: requiredCollectorBytes,
            responseCollectorByteCeiling: policy.responseCollectorByteCeiling
        )
    }
}

private struct LabeledSegment {
    let component: CoachContextCostCategory
    let data: Data

    init(_ component: CoachContextCostCategory, _ data: Data) {
        self.component = component
        self.data = data
    }
}

private struct PreparedSegments {
    let request: Data
    let transcriptReadRequest: Data?
    let transcriptReadResponse: Data?
    let completeInput: Data
    let tokenizationUnits: [Data]
    let componentData: [CoachContextCostCategory: Data]
    let handles: [PreparedCoachTranscriptHandle]
    let structuralRequest: CanonicalJSONValue
    let transcriptRoutes: [CanonicalCoachTranscriptRoute]
}

private func joined(_ segments: [LabeledSegment]) -> Data {
    var result = Data()
    result.reserveCapacity(segments.reduce(0) { $0 + $1.data.count })
    for segment in segments {
        result.append(segment.data)
    }
    return result
}

private func checkedAdd(_ lhs: Int, _ rhs: Int) throws -> Int {
    let result = lhs.addingReportingOverflow(rhs)
    guard !result.overflow else {
        throw CoachContextEstimationError.integerOverflow
    }
    return result.partialValue
}

private func minimumTokenCount(
    forUTF8ByteCount byteCount: Int,
    maximumBytesPerToken: Int
) -> Int {
    byteCount / maximumBytesPerToken +
        (byteCount.isMultiple(of: maximumBytesPerToken) ? 0 : 1)
}

private func checkedMultiply(_ lhs: Int, _ rhs: Int) throws -> Int {
    let result = lhs.multipliedReportingOverflow(by: rhs)
    guard !result.overflow else {
        throw CoachContextEstimationError.integerOverflow
    }
    return result.partialValue
}

func basicValidationError(
    descriptor: CoachProviderDescriptor,
    policy: CoachProviderEstimationPolicy
) -> CoachProviderDescriptorValidationError? {
    guard !descriptor.displayName.isEmpty else { return .emptyDisplayName }
    guard !policy.providerIdentifier.isEmpty else { return .emptyProviderIdentifier }
    guard descriptor.contextBudget.contextWindowTokens > 0 else {
        return .contextWindowMustBePositive
    }
    guard descriptor.contextBudget.responseReservedTokens > 0 else {
        return .responseReserveMustBePositive
    }
    guard descriptor.contextBudget.safetyMarginTokens >= 0 else {
        return .safetyMarginMustBeNonnegative
    }
    guard descriptor.coachMemoryMaxTokens > 0 else {
        return .coachMemoryMaximumMustBePositive
    }
    guard policy.responseCollectorByteCeiling > 0 else {
        return .responseCollectorByteCeilingMustBePositive
    }
    let hiddenCounts = [
        policy.framing.initialRequestHiddenTokens,
        policy.framing.transcriptReadExchangeHiddenTokens,
        policy.framing.minimumResponseHiddenTokens,
    ]
    guard hiddenCounts.allSatisfy({ $0 >= 0 }) else {
        return .hiddenFramingTokensMustBeNonnegative
    }

    let reserveAndMargin = descriptor.contextBudget.responseReservedTokens
        .addingReportingOverflow(descriptor.contextBudget.safetyMarginTokens)
    guard !reserveAndMargin.overflow else { return .integerOverflow }
    guard reserveAndMargin.partialValue < descriptor.contextBudget.contextWindowTokens else {
        return .reserveAndSafetyMarginReachContextWindow
    }
    return nil
}

private func isStructurallyValidCoachMemory(_ value: CanonicalJSONValue) -> Bool {
    guard case let .object(fields) = value,
          fields.count == 2,
          case .string = fields["generalNotes"],
          case let .array(summaries)? = fields["sessionSummaries"]
    else {
        return false
    }

    return summaries.allSatisfy { summary in
        guard case let .object(summaryFields) = summary,
              summaryFields.count == 2,
              case let .string(attachmentID)? = summaryFields["sessionAttachmentId"],
              !attachmentID.isEmpty,
              case let .string(notes)? = summaryFields["notes"],
              !notes.isEmpty
        else {
            return false
        }
        return true
    }
}
