import AudoraDomain
import Foundation

enum CoachContextInputLimits {
    /// A Draft remains persistable and editable beyond the amount accepted as one turn.
    public static let maximumUserMessageUTF8Bytes = 16_384
    public static let maximumHistoryTurns = 4_096
    public static let maximumHistoryTurnUTF8Bytes = 131_072
    public static let maximumCoachBlocksPerTurn = 1_024
    public static let maximumAttachments = 128
    public static let maximumCanonicalValueUTF8Bytes = 64 * 1_024 * 1_024
    public static let maximumAggregateCanonicalUTF8Bytes = 64 * 1_024 * 1_024
}

enum CoachContextQuoteInputError: Error, Equatable, Sendable {
    case profileTooLarge
    case memoryTooLarge
    case tooManyHistoryTurns
    case emptyHistoryTurn
    case historyTurnTooLarge
    case emptyCoachBlocks
    case tooManyCoachBlocks
    case invalidDraft
    case draftTooLarge
    case tooManyAttachments
    case attachmentTooLarge
    case attachmentTranscriptHandleMismatch
    case aggregateTooLarge
    case canonicalNestingTooDeep
    case integerOverflow
}

struct CoachContextAggregateBudget {
    private(set) var consumed = 0

    var remaining: Int {
        CoachContextInputLimits.maximumAggregateCanonicalUTF8Bytes - consumed
    }

    mutating func consume(_ count: Int) throws {
        guard count >= 0 else {
            throw CoachContextQuoteInputError.integerOverflow
        }
        let addition = consumed.addingReportingOverflow(count)
        guard !addition.overflow else {
            throw CoachContextQuoteInputError.integerOverflow
        }
        guard addition.partialValue <=
            CoachContextInputLimits.maximumAggregateCanonicalUTF8Bytes
        else {
            throw CoachContextQuoteInputError.aggregateTooLarge
        }
        consumed = addition.partialValue
    }

    static func accepts(byteCounts: [Int]) -> Bool {
        var budget = CoachContextAggregateBudget()
        for count in byteCounts {
            do { try budget.consume(count) } catch { return false }
        }
        return true
    }
}

/// One successful prose-history turn. Local evidence controls remain outside this value.
enum CoachContextHistoryTurn: Equatable, Sendable {
    case user(text: String)
    case coach(markdownBlocks: [String])

    fileprivate func canonicalValue() throws -> CanonicalJSONValue {
        switch self {
        case let .user(text):
            try validateHistoryText(text)
            return .object([
                "role": .string("user"),
                "text": .string(text),
            ])
        case let .coach(blocks):
            guard !blocks.isEmpty else {
                throw CoachContextQuoteInputError.emptyCoachBlocks
            }
            guard blocks.count <= CoachContextInputLimits.maximumCoachBlocksPerTurn else {
                throw CoachContextQuoteInputError.tooManyCoachBlocks
            }
            for block in blocks {
                try validateHistoryText(block)
            }
            let text = blocks.joined(separator: "\n\n")
            try validateHistoryText(text)
            return .object([
                "role": .string("coach"),
                "text": .string(text),
            ])
        }
    }
}

/// Creation advisories and exact Send preparation share one builder without
/// inventing user prose. Only a user-message trigger is eligible for launch.
enum CoachContextTrigger: Equatable, Sendable {
    case chatCreation(ChatCreation)
    case userMessage(String)

    var currentDraft: String? {
        guard case let .userMessage(text) = self else { return nil }
        return text
    }

    var costCategory: CoachContextCostCategory {
        switch self {
        case .chatCreation: .framing
        case .userMessage: .draft
        }
    }

    func canonicalValue() -> CanonicalJSONValue {
        switch self {
        case let .chatCreation(creation):
            var fields: [String: CanonicalJSONValue] = [
                "creationKind": .string(creation.kind.rawValue),
                "kind": .string("chatCreationContext"),
            ]
            if let originAttachmentID = creation.originAttachmentID {
                fields["originAttachmentId"] = .string(originAttachmentID.rawValue)
            }
            return .object(fields)
        case let .userMessage(text):
            return .object([
                "kind": .string("userMessage"),
                "text": .string(text),
            ])
        }
    }
}

/// Bounded values needed to quote one complete provider exchange.
///
/// Profile, Memory, and attachment DTO values are already projected at their
/// Application seams. History and Draft remain typed here so their canonical prose
/// rules cannot be reimplemented by Presentation or a provider adapter.
struct CoachContextQuoteInput: Equatable, Sendable {
    let profile: CanonicalJSONValue
    let memory: CanonicalJSONValue
    let history: [CoachContextHistoryTurn]
    let trigger: CoachContextTrigger
    let attachments: [PreparedCoachAttachment]

    var currentDraft: String? { trigger.currentDraft }

    init(
        profile: CanonicalJSONValue,
        memory: CanonicalJSONValue,
        history: [CoachContextHistoryTurn],
        currentDraft: String,
        attachments: [PreparedCoachAttachment] = []
    ) throws {
        var aggregateBudget = CoachContextAggregateBudget()
        _ = try measureCanonicalValue(
            profile,
            budget: &aggregateBudget,
            valueTooLarge: .profileTooLarge
        )
        _ = try measureCanonicalValue(
            memory,
            budget: &aggregateBudget,
            valueTooLarge: .memoryTooLarge
        )
        guard history.count <= CoachContextInputLimits.maximumHistoryTurns else {
            throw CoachContextQuoteInputError.tooManyHistoryTurns
        }
        for turn in history {
            let value = try turn.canonicalValue()
            _ = try measureCanonicalValue(
                value,
                budget: &aggregateBudget,
                valueTooLarge: .historyTurnTooLarge
            )
        }
        guard !currentDraft.isEmpty,
              !currentDraft.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            throw CoachContextQuoteInputError.invalidDraft
        }
        guard currentDraft.utf8.count <= ChatDraft.maximumUTF8Bytes else {
            throw CoachContextQuoteInputError.draftTooLarge
        }
        let trigger = CoachContextTrigger.userMessage(currentDraft)
        _ = try measureCanonicalValue(
            trigger.canonicalValue(),
            budget: &aggregateBudget,
            valueTooLarge: .draftTooLarge
        )
        try Self.measureAttachments(attachments, budget: &aggregateBudget)

        self.profile = profile
        self.memory = memory
        self.history = history
        self.trigger = trigger
        self.attachments = attachments
    }

    init(
        profile: CanonicalJSONValue,
        memory: CanonicalJSONValue,
        creation: ChatCreation,
        attachments: [PreparedCoachAttachment] = []
    ) throws {
        var aggregateBudget = CoachContextAggregateBudget()
        _ = try measureCanonicalValue(
            profile,
            budget: &aggregateBudget,
            valueTooLarge: .profileTooLarge
        )
        _ = try measureCanonicalValue(
            memory,
            budget: &aggregateBudget,
            valueTooLarge: .memoryTooLarge
        )
        let trigger = CoachContextTrigger.chatCreation(creation)
        _ = try measureCanonicalValue(
            trigger.canonicalValue(),
            budget: &aggregateBudget,
            valueTooLarge: .draftTooLarge
        )
        try Self.measureAttachments(attachments, budget: &aggregateBudget)

        self.profile = profile
        self.memory = memory
        history = []
        self.trigger = trigger
        self.attachments = attachments
    }

    fileprivate func preparedContext() throws -> PreparedCoachContext {
        PreparedCoachContext(
            profile: profile,
            memory: memory,
            history: try history.map { try $0.canonicalValue() },
            trigger: trigger.canonicalValue(),
            triggerCategory: trigger.costCategory,
            attachments: attachments
        )
    }

    private static func measureAttachments(
        _ attachments: [PreparedCoachAttachment],
        budget: inout CoachContextAggregateBudget
    ) throws {
        guard attachments.count <= CoachContextInputLimits.maximumAttachments else {
            throw CoachContextQuoteInputError.tooManyAttachments
        }
        var handles: [CanonicalJSONValue] = []
        var disclosures: [CanonicalJSONValue] = []
        for attachment in attachments {
            let requestValue: CanonicalJSONValue
            do {
                requestValue = try attachment.authoritativeRequestValue()
                switch attachment {
                case .inline:
                    break
                case let .onDemand(_, handle, transcriptDisclosure):
                    handles.append(.string(handle.rawValue))
                    disclosures.append(transcriptDisclosure)
                }
            } catch CoachContextEstimationError.sessionTranscriptHandleMismatch {
                throw CoachContextQuoteInputError.attachmentTranscriptHandleMismatch
            }
            _ = try measureCanonicalValue(
                requestValue,
                budget: &budget,
                valueTooLarge: .attachmentTooLarge
            )
        }
        if !handles.isEmpty {
            _ = try measureCanonicalValue(
                .object(["sessionTranscriptHandles": .array(handles)]),
                budget: &budget,
                valueTooLarge: .attachmentTooLarge
            )
            _ = try measureCanonicalValue(
                .object([
                    "kind": .string("complete"),
                    "transcripts": .array(disclosures),
                ]),
                budget: &budget,
                valueTooLarge: .attachmentTooLarge
            )
        }
    }
}

private func measureCanonicalValue(
    _ value: CanonicalJSONValue,
    budget: inout CoachContextAggregateBudget,
    valueTooLarge: CoachContextQuoteInputError
) throws -> Int {
    let allowed = min(
        CoachContextInputLimits.maximumCanonicalValueUTF8Bytes,
        budget.remaining
    )
    do {
        let count = try CanonicalJSON.byteCount(
            of: value,
            maximumByteCount: allowed
        )
        try budget.consume(count)
        return count
    } catch CanonicalJSONMeasurementError.byteLimitExceeded {
        throw budget.remaining < CoachContextInputLimits.maximumCanonicalValueUTF8Bytes
            ? CoachContextQuoteInputError.aggregateTooLarge
            : valueTooLarge
    } catch CanonicalJSONMeasurementError.nestingLimitExceeded {
        throw CoachContextQuoteInputError.canonicalNestingTooDeep
    } catch {
        throw CoachContextQuoteInputError.integerOverflow
    }
}

enum CoachContextConfigurationError: Error, Equatable, Sendable {
    case invalidDescriptor(CoachProviderDescriptorValidationError)
}

/// Qualified app-only provider limits and framing. No estimator data enters Coach DTOs.
struct CoachContextConfiguration: Sendable {
    let descriptor: CoachProviderDescriptor
    let policy: CoachProviderEstimationPolicy

    init(
        descriptor: CoachProviderDescriptor,
        policy: CoachProviderEstimationPolicy
    ) throws {
        if let error = basicValidationError(descriptor: descriptor, policy: policy) {
            throw CoachContextConfigurationError.invalidDescriptor(error)
        }
        self.descriptor = descriptor
        self.policy = policy
    }
}

public enum CoachContextMessageLength: Equatable, Sendable {
    case eligible
    case mustShorten(maximumUTF8Bytes: Int)
}

/// Advisory projection. Category estimates explain usage but are never added for fit.
public struct CoachContextQuote: Equatable, Sendable {
    public let maximumUserMessageUTF8Bytes: Int
    public let completeInputTokens: Int
    public let inputCeilingTokens: Int
    public let reservedResponseTokens: Int
    public let safetyMarginTokens: Int
    public let totalContextTokens: Int
    public let fits: Bool
    public let messageLength: CoachContextMessageLength
    public let categoryCosts: [CoachContextCostCategory: CoachContextComponentCost]
    public let estimatorIdentifier: String
    public let estimatorMode: CoachTokenEstimateMode

    fileprivate init(
        estimate: CoachContextEstimate,
        messageLength: CoachContextMessageLength
    ) {
        maximumUserMessageUTF8Bytes = CoachContextInputLimits.maximumUserMessageUTF8Bytes
        completeInputTokens = estimate.completeInputTokens
        inputCeilingTokens = estimate.inputCeilingTokens
        reservedResponseTokens = estimate.reservedResponseTokens
        safetyMarginTokens = estimate.safetyMarginTokens
        totalContextTokens = estimate.totalContextTokens
        fits = estimate.fits
        self.messageLength = messageLength
        categoryCosts = estimate.componentCosts
        estimatorIdentifier = estimate.estimatorIdentifier
        estimatorMode = estimate.estimatorMode
    }
}

public struct ChatCreationQuote: Equatable, Sendable {
    public let context: CoachContextQuote

    public init(context: CoachContextQuote) {
        self.context = context
    }
}

public enum CoachContextRecoveryAction: String, CaseIterable, Equatable, Sendable {
    case retry
    case discard
    case createNewChat
}

public struct CoachContextCapacityFailure: Equatable, Sendable {
    public let quote: CoachContextQuote
    public let recoveryActions: [CoachContextRecoveryAction]

    public init(
        quote: CoachContextQuote,
        recoveryActions: [CoachContextRecoveryAction] = CoachContextRecoveryAction.allCases
    ) {
        self.quote = quote
        self.recoveryActions = recoveryActions
    }
}

enum CoachContextPreparationError: Error, Equatable, Sendable {
    case messageTooLong(CoachContextQuote)
    case cannotFit(CoachContextCapacityFailure)
}

/// Exact launch artifact. Adapters must transmit these bytes instead of re-encoding DTOs.
struct MeasuredCoachLaunchContext: Equatable, Sendable {
    let quote: CoachContextQuote
    let exchange: CanonicalCoachExchange

    init(quote: CoachContextQuote, exchange: CanonicalCoachExchange) {
        self.quote = quote
        self.exchange = exchange
    }
}

/// Deep in-process module for both advisory quotes and authoritative launch preflight.
struct CoachContextCapacity: Sendable {
    private let planner: CoachContextPlanner

    init(planner: CoachContextPlanner = CoachContextPlanner()) {
        self.planner = planner
    }

    func quoteNewChat(
        _ input: CoachContextQuoteInput,
        configuration: CoachContextConfiguration
    ) throws -> ChatCreationQuote {
        guard case .chatCreation = input.trigger else {
            throw CoachContextQuoteInputError.invalidDraft
        }
        return ChatCreationQuote(
            context: try quoteChat(input, configuration: configuration)
        )
    }

    func quoteChat(
        _ input: CoachContextQuoteInput,
        configuration: CoachContextConfiguration
    ) throws -> CoachContextQuote {
        try measure(input, configuration: configuration).quote
    }

    /// Rebuilds and measures the exact serialized exchange immediately before launch.
    /// A successful caller must use the returned bytes; no parallel serializer exists.
    func prepareForLaunch(
        _ input: CoachContextQuoteInput,
        configuration: CoachContextConfiguration
    ) throws -> MeasuredCoachLaunchContext {
        guard case .userMessage = input.trigger else {
            throw CoachContextQuoteInputError.invalidDraft
        }
        let measured = try measure(input, configuration: configuration)
        if case .mustShorten = measured.quote.messageLength {
            throw CoachContextPreparationError.messageTooLong(measured.quote)
        }
        guard measured.quote.fits else {
            throw CoachContextPreparationError.cannotFit(
                CoachContextCapacityFailure(quote: measured.quote)
            )
        }
        return MeasuredCoachLaunchContext(
            quote: measured.quote,
            exchange: measured.estimate.exchange
        )
    }

    private func measure(
        _ input: CoachContextQuoteInput,
        configuration: CoachContextConfiguration
    ) throws -> (quote: CoachContextQuote, estimate: CoachContextEstimate) {
        let estimate = try planner.estimate(
            input.preparedContext(),
            descriptor: configuration.descriptor,
            policy: configuration.policy
        )
        let messageLength: CoachContextMessageLength
        switch input.trigger {
        case .chatCreation:
            messageLength = .eligible
        case let .userMessage(text):
            messageLength = text.utf8.count <=
                CoachContextInputLimits.maximumUserMessageUTF8Bytes
                ? .eligible
                : .mustShorten(
                    maximumUTF8Bytes: CoachContextInputLimits.maximumUserMessageUTF8Bytes
                )
        }
        return (
            CoachContextQuote(estimate: estimate, messageLength: messageLength),
            estimate
        )
    }
}

private func validateHistoryText(_ text: String) throws {
    guard !text.isEmpty,
          !text.unicodeScalars.contains(where: { $0.value == 0 })
    else {
        throw CoachContextQuoteInputError.emptyHistoryTurn
    }
    guard text.utf8.count <= CoachContextInputLimits.maximumHistoryTurnUTF8Bytes else {
        throw CoachContextQuoteInputError.historyTurnTooLarge
    }
}
