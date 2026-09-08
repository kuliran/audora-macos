import AudoraDomain
import Foundation

/// Complete provider bytes. The value is intentionally opaque until the
/// Application validates the whole response batch.
struct CoachProviderCompleteResponse: Equatable, Sendable {
    let body: Data

    init(body: Data) {
        self.body = body
    }

    static func singleMarkdown(_ markdown: String) -> Self {
        CoachProviderCompleteResponse(
            body: CanonicalJSON.serialize(
                .object([
                    "messageBlocks": .array([
                        .object([
                            "kind": .string("markdown"),
                            "markdown": .string(markdown),
                        ]),
                    ]),
                ])
            )
        )
    }
}

/// Qualified, frozen response limits paired with the exact request admission.
/// Equality compares qualification identity rather than the estimator closure.
struct CoachResponseValidationAuthority: Equatable, Sendable {
    let responseReservedTokens: Int
    let responseCollectorByteCeiling: Int
    let coachMemoryMaxTokens: Int
    private let framing: CoachProviderFraming
    private let tokenEstimator: CoachTokenEstimator

    init(
        responseReservedTokens: Int,
        responseCollectorByteCeiling: Int,
        coachMemoryMaxTokens: Int,
        framing: CoachProviderFraming,
        tokenEstimator: CoachTokenEstimator
    ) {
        self.responseReservedTokens = responseReservedTokens
        self.responseCollectorByteCeiling = responseCollectorByteCeiling
        self.coachMemoryMaxTokens = coachMemoryMaxTokens
        self.framing = framing
        self.tokenEstimator = tokenEstimator
    }

    static func == (
        lhs: CoachResponseValidationAuthority,
        rhs: CoachResponseValidationAuthority
    ) -> Bool {
        lhs.responseReservedTokens == rhs.responseReservedTokens &&
            lhs.responseCollectorByteCeiling == rhs.responseCollectorByteCeiling &&
            lhs.coachMemoryMaxTokens == rhs.coachMemoryMaxTokens &&
            lhs.framing == rhs.framing &&
            lhs.tokenEstimator.identifier == rhs.tokenEstimator.identifier &&
            lhs.tokenEstimator.mode == rhs.tokenEstimator.mode &&
            lhs.tokenEstimator.maximumUTF8BytesPerToken ==
            rhs.tokenEstimator.maximumUTF8BytesPerToken
    }

    func responseFits(_ body: Data) throws -> Bool {
        guard responseReservedTokens > 0,
              responseCollectorByteCeiling > 0,
              body.count <= responseCollectorByteCeiling
        else { return false }
        var framed = Data()
        framed.append(framing.minimumResponsePrefix)
        framed.append(body)
        framed.append(framing.minimumResponseSuffix)
        let visible = try tokenEstimator.tokenCount(forUTF8: framed)
        let measured = visible.addingReportingOverflow(
            framing.minimumResponseHiddenTokens
        )
        return !measured.overflow && measured.partialValue <= responseReservedTokens
    }

    func memoryFits(_ memory: CanonicalJSONValue) throws -> Bool {
        guard coachMemoryMaxTokens > 0 else { return false }
        return try tokenEstimator.tokenCount(
            forUTF8: CanonicalJSON.serialize(memory)
        ) <= coachMemoryMaxTokens
    }
}

enum CoachResponseValidationError: Error, Equatable, Sendable {
    case missingValidationAuthority
    case invalidPreparedContext
    case responseByteLimitExceeded
    case responseTokenLimitExceeded
    case invalidUTF8
    case invalidJSON
    case duplicateJSONKey
    case schemaMismatch
    case messageBlocksRequired
    case unsafeMarkdown
    case invalidMemory
    case memoryTokenLimitExceeded
    case invalidEvidencePointer
    case danglingProfileTarget
    case conflictingProfileEffects
}

enum CoachResponseProfileStatementKind: String, Equatable, Sendable {
    case goal
    case coachingPreference
    case selfAssessment
    case speakingObservation
    case growthDirection
}

struct CoachResponseWordID: Hashable, Sendable {
    let rawValue: String

    init?(_ rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }
}

struct CoachResponseAudioEventID: Hashable, Sendable {
    let rawValue: String

    init?(_ rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }
}

struct CoachResponseProfileStatementID: Hashable, Sendable {
    let rawValue: String

    init?(_ rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }
}

enum CoachResponseEvidenceTarget: Equatable, Sendable {
    case wordRange(
        startWordID: CoachResponseWordID,
        endWordID: CoachResponseWordID
    )
    case audioEvent(audioEventID: CoachResponseAudioEventID)
}

struct CoachResponseEvidencePointer: Equatable, Sendable {
    let sessionAttachmentID: ChatSessionAttachmentID
    let target: CoachResponseEvidenceTarget
}

enum ValidatedCoachResponseBlock: Equatable, Sendable {
    case markdown(String)
    case evidenceObservation(
        markdown: String,
        evidence: [CoachResponseEvidencePointer]
    )

    var markdown: String {
        switch self {
        case let .markdown(value), let .evidenceObservation(value, _): value
        }
    }

    var isPlainMarkdown: Bool {
        guard case .markdown = self else { return false }
        return true
    }
}

struct ValidatedCoachResponseMemorySummary: Equatable, Sendable {
    let sessionAttachmentID: ChatSessionAttachmentID
    let notes: String
}

struct ValidatedCoachResponseMemory: Equatable, Sendable {
    let generalNotes: String
    let sessionSummaries: [ValidatedCoachResponseMemorySummary]

    var canonicalValue: CanonicalJSONValue {
        .object([
            "generalNotes": .string(generalNotes),
            "sessionSummaries": .array(sessionSummaries.map { summary in
                .object([
                    "notes": .string(summary.notes),
                    "sessionAttachmentId": .string(
                        summary.sessionAttachmentID.rawValue
                    ),
                ])
            }),
        ])
    }
}

enum ValidatedCoachProfileEdit: Equatable, Sendable {
    case add(statementKind: CoachResponseProfileStatementKind, wording: String)
    case replace(targetStatementID: CoachResponseProfileStatementID, wording: String)
    case retire(targetStatementID: CoachResponseProfileStatementID)

    var targetStatementID: CoachResponseProfileStatementID? {
        switch self {
        case .add: nil
        case let .replace(target, _), let .retire(target): target
        }
    }
}

struct ValidatedCoachProfileEditProposal: Equatable, Sendable {
    let edit: ValidatedCoachProfileEdit
    let evidence: [CoachResponseEvidencePointer]
}

struct ValidatedCoachProfileEvidenceAppend: Equatable, Sendable {
    let targetStatementID: CoachResponseProfileStatementID
    let evidence: [CoachResponseEvidencePointer]
}

/// The indivisible result of schema and semantic validation. Callers cannot
/// obtain messages, Memory, or Profile effects from a failed batch.
struct ValidatedCoachResponse: Equatable, Sendable {
    let messageBlocks: [ValidatedCoachResponseBlock]
    let newMemory: ValidatedCoachResponseMemory?
    let proposedProfileEdits: [ValidatedCoachProfileEditProposal]
    let appendedProfileEvidence: [ValidatedCoachProfileEvidenceAppend]

    var publicationMarkdown: String? {
        guard !messageBlocks.isEmpty else { return nil }
        return messageBlocks.map(\.markdown).joined(separator: "\n\n")
    }

    /// #28, #29, and #30 add durable Memory, evidence-block, and Profile-effect
    /// publication. Until then, fail closed rather than silently dropping a
    /// validated component while publishing its message.
    var isSupportedByCurrentPublicationSlice: Bool {
        newMemory == nil &&
            proposedProfileEdits.isEmpty &&
            appendedProfileEvidence.isEmpty &&
            messageBlocks.count == 1 &&
            messageBlocks.allSatisfy(\.isPlainMarkdown)
    }
}

enum CoachResponseTriggerPosition: Equatable, Sendable {
    case userMessage
    case reconsiderProfileChange
}

struct CoachResponseTranscriptEvidenceIndex: Equatable, Sendable {
    let wordPositions: [CoachResponseWordID: Int]
    let audioEventIDs: Set<CoachResponseAudioEventID>
    let audioEventIDsIneligibleForProfileSupport: Set<CoachResponseAudioEventID>

    init(
        wordIDs: [String],
        audioEventIDs: [String],
        audioEventIDsIneligibleForProfileSupport: Set<String> = []
    ) throws {
        let parsedWordIDs = wordIDs.compactMap(CoachResponseWordID.init)
        let parsedAudioEventIDs = audioEventIDs.compactMap(
            CoachResponseAudioEventID.init
        )
        let parsedIneligibleAudioEventIDs =
            audioEventIDsIneligibleForProfileSupport.compactMap(
                CoachResponseAudioEventID.init
            )
        guard parsedWordIDs.count == wordIDs.count,
              parsedAudioEventIDs.count == audioEventIDs.count,
              parsedIneligibleAudioEventIDs.count ==
              audioEventIDsIneligibleForProfileSupport.count,
              Set(parsedWordIDs).count == parsedWordIDs.count,
              Set(parsedAudioEventIDs).count == parsedAudioEventIDs.count,
              Set(parsedIneligibleAudioEventIDs).isSubset(
                  of: Set(parsedAudioEventIDs)
              )
        else { throw CoachResponseValidationError.invalidPreparedContext }
        wordPositions = Dictionary(
            uniqueKeysWithValues: parsedWordIDs.enumerated().map {
                ($0.element, $0.offset)
            }
        )
        self.audioEventIDs = Set(parsedAudioEventIDs)
        self.audioEventIDsIneligibleForProfileSupport =
            Set(parsedIneligibleAudioEventIDs)
    }
}

struct CoachResponseValidationContext: Equatable, Sendable {
    let triggerPosition: CoachResponseTriggerPosition
    let transcripts:
        [ChatSessionAttachmentID: CoachResponseTranscriptEvidenceIndex]
    let activeProfileStatementIDs: Set<CoachResponseProfileStatementID>
    let authority: CoachResponseValidationAuthority

    init(
        triggerPosition: CoachResponseTriggerPosition,
        transcripts: [
            ChatSessionAttachmentID: CoachResponseTranscriptEvidenceIndex
        ],
        activeProfileStatementIDs: Set<String>,
        authority: CoachResponseValidationAuthority
    ) throws {
        let parsedProfileStatementIDs = activeProfileStatementIDs.compactMap(
            CoachResponseProfileStatementID.init
        )
        guard parsedProfileStatementIDs.count == activeProfileStatementIDs.count
        else { throw CoachResponseValidationError.invalidPreparedContext }
        self.triggerPosition = triggerPosition
        self.transcripts = transcripts
        self.activeProfileStatementIDs = Set(parsedProfileStatementIDs)
        self.authority = authority
    }

    init(
        prepared: PreparedCoachLaunchContext,
        base: ChatAggregate
    ) throws {
        guard let structuralRequest = prepared.exchange.structuralRequest,
              let authority = prepared.exchange.responseValidationAuthority
        else { throw CoachResponseValidationError.missingValidationAuthority }
        guard case let .object(root) = structuralRequest,
              case let .object(conversation)? = root["conversation"],
              case let .object(trigger)? = conversation["trigger"],
              case let .string(triggerKind)? = trigger["kind"],
              case let .object(profile)? = root["profile"],
              case let .array(statements)? = profile["statements"],
              case let .array(attachments)? = root["sessionAttachments"],
              attachments.count == base.chat.attachments.values.count
        else { throw CoachResponseValidationError.invalidPreparedContext }

        switch triggerKind {
        case "userMessage": triggerPosition = .userMessage
        case "reconsiderProfileChange": triggerPosition = .reconsiderProfileChange
        default: throw CoachResponseValidationError.invalidPreparedContext
        }

        var profileIDs: Set<CoachResponseProfileStatementID> = []
        for statement in statements {
            guard case let .object(fields) = statement,
                  case let .string(rawStatementID)? = fields["statementId"],
                  let statementID = CoachResponseProfileStatementID(rawStatementID),
                  profileIDs.insert(statementID).inserted
            else { throw CoachResponseValidationError.invalidPreparedContext }
        }

        let expectedAttachments = base.chat.attachments.values
        var transcriptIndexes:
            [ChatSessionAttachmentID: CoachResponseTranscriptEvidenceIndex] = [:]
        for (index, attachmentValue) in attachments.enumerated() {
            guard case let .object(fields) = attachmentValue,
                  case let .string(rawAttachmentID)? = fields["sessionAttachmentId"],
                  let attachmentID = try? ChatSessionAttachmentID(rawAttachmentID),
                  attachmentID == expectedAttachments[index].attachmentID,
                  case let .string(kind)? = fields["kind"]
            else { throw CoachResponseValidationError.invalidPreparedContext }

            let transcript: CanonicalJSONValue
            switch kind {
            case "inline":
                guard let inlineTranscript = fields["transcript"] else {
                    throw CoachResponseValidationError.invalidPreparedContext
                }
                transcript = inlineTranscript
            case "onDemand":
                guard let route = prepared.exchange.preparedTranscriptRoutes
                    .first(where: { $0.requestAttachmentIndex == index }),
                    route.sourceAttachment == expectedAttachments[index],
                    case let .object(disclosure) = route.disclosure,
                    disclosure["sessionAttachmentId"] == .string(rawAttachmentID),
                    let disclosedTranscript = disclosure["transcript"]
                else { throw CoachResponseValidationError.invalidPreparedContext }
                transcript = disclosedTranscript
            default:
                throw CoachResponseValidationError.invalidPreparedContext
            }
            guard transcriptIndexes.updateValue(
                try Self.index(transcript: transcript),
                forKey: attachmentID
            ) == nil else {
                throw CoachResponseValidationError.invalidPreparedContext
            }
        }

        guard Set(transcriptIndexes.keys) ==
            Set(expectedAttachments.map(\.attachmentID))
        else { throw CoachResponseValidationError.invalidPreparedContext }
        transcripts = transcriptIndexes
        activeProfileStatementIDs = profileIDs
        self.authority = authority
    }

    private static func index(
        transcript: CanonicalJSONValue
    ) throws -> CoachResponseTranscriptEvidenceIndex {
        guard case let .object(fields) = transcript,
              case let .array(lines)? = fields["lines"],
              case let .array(audioEvents)? = fields["audioEvents"]
        else { throw CoachResponseValidationError.invalidPreparedContext }
        var wordIDs: [CoachResponseWordID] = []
        for line in lines {
            guard case let .object(lineFields) = line,
                  case let .array(words)? = lineFields["words"]
            else { throw CoachResponseValidationError.invalidPreparedContext }
            for word in words {
                guard case let .object(wordFields) = word,
                      case let .string(rawWordID)? = wordFields["wordId"],
                      let wordID = CoachResponseWordID(rawWordID)
                else { throw CoachResponseValidationError.invalidPreparedContext }
                wordIDs.append(wordID)
            }
        }
        let parsedAudioEvents = try audioEvents.map {
            event -> (CoachResponseAudioEventID, TranscriptAudioEventCategory) in
            guard case let .object(eventFields) = event,
                  case let .string(rawAudioEventID)? = eventFields["audioEventId"],
                  let audioEventID = CoachResponseAudioEventID(rawAudioEventID),
                  case let .string(rawCategory)? = eventFields["category"],
                  let category = TranscriptAudioEventCategory(rawValue: rawCategory)
            else { throw CoachResponseValidationError.invalidPreparedContext }
            return (audioEventID, category)
        }
        return try CoachResponseTranscriptEvidenceIndex(
            wordIDs: wordIDs.map(\.rawValue),
            audioEventIDs: parsedAudioEvents.map(\.0.rawValue),
            audioEventIDsIneligibleForProfileSupport: Set(
                parsedAudioEvents.compactMap { eventID, category in
                    switch category {
                    case .muted, .captureGap: eventID.rawValue
                    case .nonSpeech, .silentPause, .untranscribedVoicedInterval: nil
                    }
                }
            )
        )
    }
}

struct CoachResponseValidator: Sendable {
    func validate(
        _ complete: CoachProviderCompleteResponse,
        in context: CoachResponseValidationContext
    ) throws -> ValidatedCoachResponse {
        guard complete.body.count <= context.authority.responseCollectorByteCeiling
        else { throw CoachResponseValidationError.responseByteLimitExceeded }
        guard String(data: complete.body, encoding: .utf8) != nil else {
            throw CoachResponseValidationError.invalidUTF8
        }
        do {
            var scanner = StrictJSONStructureScanner(data: complete.body)
            try scanner.validate()
        } catch StrictJSONStructureScanner.Error.duplicateKey {
            throw CoachResponseValidationError.duplicateJSONKey
        } catch {
            throw CoachResponseValidationError.invalidJSON
        }
        let fits: Bool
        do { fits = try context.authority.responseFits(complete.body) } catch {
            throw CoachResponseValidationError.responseTokenLimitExceeded
        }
        guard fits else { throw CoachResponseValidationError.responseTokenLimitExceeded }

        let decoded: ParsedCoachResponse
        do { decoded = try CoachResponseSchemaDecoder().decode(complete.body) } catch {
            throw CoachResponseValidationError.schemaMismatch
        }
        if context.triggerPosition == .userMessage,
           decoded.messageBlocks.isEmpty
        {
            throw CoachResponseValidationError.messageBlocksRequired
        }

        for block in decoded.messageBlocks {
            try validateMarkdown(block.markdown)
            if case let .evidenceObservation(_, evidence) = block {
                try validate(
                    evidence: evidence,
                    purpose: .messageObservation,
                    in: context
                )
            }
        }
        if let memory = decoded.newMemory {
            try validate(memory: memory, in: context)
        }
        for proposal in decoded.proposedProfileEdits {
            try validate(
                evidence: proposal.evidence,
                purpose: .profileSupport,
                in: context
            )
        }
        for append in decoded.appendedProfileEvidence {
            try validate(
                evidence: append.evidence,
                purpose: .profileSupport,
                in: context
            )
        }
        try validateProfileEffects(decoded, in: context)

        return ValidatedCoachResponse(
            messageBlocks: decoded.messageBlocks,
            newMemory: decoded.newMemory,
            proposedProfileEdits: decoded.proposedProfileEdits,
            appendedProfileEvidence: decoded.appendedProfileEvidence
        )
    }

    private func validateMarkdown(_ markdown: String) throws {
        guard markdown.unicodeScalars.contains(where: {
            !$0.properties.isWhitespace
        }) else { throw CoachResponseValidationError.unsafeMarkdown }
        for scalar in markdown.unicodeScalars {
            let allowedWhitespace = scalar.value == 0x09 ||
                scalar.value == 0x0A || scalar.value == 0x0D
            if scalar.value == 0 ||
                (scalar.properties.generalCategory == .control && !allowedWhitespace) ||
                scalar.value == 0x061C ||
                scalar.value == 0x200E || scalar.value == 0x200F ||
                (0x202A ... 0x202E).contains(scalar.value) ||
                (0x2066 ... 0x206F).contains(scalar.value)
            {
                throw CoachResponseValidationError.unsafeMarkdown
            }
        }
        let lowered = markdown.lowercased()
        let forbiddenFragments = ["![", "](", "]["]
        guard !forbiddenFragments.contains(where: lowered.contains),
              !containsLinkDefinition(in: markdown),
              !containsBareURI(in: lowered),
              !containsAngleBracketEmailAutolink(in: markdown),
              !containsRawHTML(in: markdown)
        else { throw CoachResponseValidationError.unsafeMarkdown }
    }

    private func containsLinkDefinition(in markdown: String) -> Bool {
        let scalars = Array(markdown.unicodeScalars)
        for opening in scalars.indices where scalars[opening].value == 0x5B {
            guard hasMarkdownContainerPrefix(scalars, before: opening) else {
                continue
            }
            var cursor = opening + 1
            var scanned = 0
            var crossedLine = false
            var onlyWhitespaceSinceLine = true
            while cursor < scalars.endIndex, scanned <= 1_000 {
                let value = scalars[cursor].value
                if value == 0x0A || value == 0x0D {
                    if crossedLine && onlyWhitespaceSinceLine { break }
                    crossedLine = true
                    onlyWhitespaceSinceLine = true
                    if value == 0x0D, cursor + 1 < scalars.endIndex,
                       scalars[cursor + 1].value == 0x0A
                    {
                        cursor += 1
                    }
                } else {
                    if value != 0x20 && value != 0x09 {
                        onlyWhitespaceSinceLine = false
                    }
                    if value == 0x5B, isUnescaped(scalars, at: cursor) {
                        break
                    }
                    if value == 0x5D, isUnescaped(scalars, at: cursor) {
                        if cursor + 1 < scalars.endIndex,
                           scalars[cursor + 1].value == 0x3A
                        {
                            return true
                        }
                        break
                    }
                }
                cursor += 1
                scanned += 1
            }
        }
        return false
    }

    private func hasMarkdownContainerPrefix(
        _ scalars: [Unicode.Scalar],
        before opening: Int
    ) -> Bool {
        var lineStart = opening
        while lineStart > scalars.startIndex {
            let previous = scalars[lineStart - 1].value
            guard previous != 0x0A && previous != 0x0D else { break }
            lineStart -= 1
        }
        var cursor = lineStart
        func skippingHorizontalWhitespace(_ initial: Int) -> Int {
            var result = initial
            while result < opening,
                  [0x20, 0x09].contains(scalars[result].value)
            {
                result += 1
            }
            return result
        }
        while true {
            cursor = skippingHorizontalWhitespace(cursor)
            if cursor == opening { return true }
            if scalars[cursor].value == 0x3E {
                cursor += 1
                continue
            }
            if [0x2D, 0x2B, 0x2A].contains(scalars[cursor].value),
               cursor + 1 < opening,
               [0x20, 0x09].contains(scalars[cursor + 1].value)
            {
                cursor += 2
                continue
            }
            if (0x30 ... 0x39).contains(scalars[cursor].value) {
                var end = cursor
                while end < opening, end - cursor < 9,
                      (0x30 ... 0x39).contains(scalars[end].value)
                {
                    end += 1
                }
                if end < opening,
                   [0x2E, 0x29].contains(scalars[end].value),
                   end + 1 < opening,
                   [0x20, 0x09].contains(scalars[end + 1].value)
                {
                    cursor = end + 2
                    continue
                }
            }
            return false
        }
    }

    private func isUnescaped(
        _ scalars: [Unicode.Scalar],
        at index: Int
    ) -> Bool {
        var slashCount = 0
        var cursor = index
        while cursor > scalars.startIndex,
              scalars[cursor - 1].value == 0x5C
        {
            slashCount += 1
            cursor -= 1
        }
        return slashCount.isMultiple(of: 2)
    }

    private func containsBareURI(in markdown: String) -> Bool {
        let scalars = Array(markdown.unicodeScalars)
        guard scalars.count >= 4 else { return false }
        for colon in scalars.indices where scalars[colon].value == 0x3A {
            guard colon + 2 < scalars.endIndex,
                  scalars[colon + 1].value == 0x2F,
                  scalars[colon + 2].value == 0x2F
            else { continue }
            var start = colon
            while start > scalars.startIndex {
                let candidate = scalars[start - 1].value
                let isSchemeCharacter = (0x41 ... 0x5A).contains(candidate) ||
                    (0x61 ... 0x7A).contains(candidate) ||
                    (0x30 ... 0x39).contains(candidate) ||
                    candidate == 0x2B || candidate == 0x2D || candidate == 0x2E
                guard isSchemeCharacter else { break }
                start -= 1
            }
            guard start < colon else { continue }
            if scalars[start ..< colon].contains(where: { scalar in
                (0x41 ... 0x5A).contains(scalar.value) ||
                    (0x61 ... 0x7A).contains(scalar.value)
            }) {
                return true
            }
        }
        return false
    }

    private func containsAngleBracketEmailAutolink(in markdown: String) -> Bool {
        let scalars = Array(markdown.unicodeScalars)
        for opening in scalars.indices where scalars[opening].value == 0x3C {
            guard isUnescaped(scalars, at: opening) else { continue }
            var cursor = opening + 1
            var containsAtSign = false
            while cursor < scalars.endIndex {
                let value = scalars[cursor].value
                if value == 0x0A || value == 0x0D || value == 0x3C { break }
                if value == 0x3E {
                    if containsAtSign { return true }
                    break
                }
                containsAtSign = containsAtSign || value == 0x40
                cursor += 1
            }
        }
        return false
    }

    private func containsRawHTML(in markdown: String) -> Bool {
        let scalars = Array(markdown.unicodeScalars)
        for index in scalars.indices where scalars[index].value == 0x3C {
            guard isUnescaped(scalars, at: index), index + 1 < scalars.endIndex
            else { continue }
            let next = scalars[index + 1]
            let hasClosingAngle = scalars[(index + 2)...].contains {
                $0.value == 0x3E
            }
            let startsHTML = next.value == 0x21 || next.value == 0x2F ||
                next.value == 0x3F ||
                (0x41 ... 0x5A).contains(next.value) ||
                (0x61 ... 0x7A).contains(next.value)
            if startsHTML &&
                (hasClosingAngle ||
                    hasMarkdownContainerPrefix(scalars, before: index))
            {
                return true
            }
        }
        return false
    }

    private func validate(
        memory: ValidatedCoachResponseMemory,
        in context: CoachResponseValidationContext
    ) throws {
        let allowedAttachments = Set(context.transcripts.keys)
        var seen: Set<ChatSessionAttachmentID> = []
        let text = [memory.generalNotes] + memory.sessionSummaries.map(\.notes)
        guard text.allSatisfy({
            $0.utf8.count <= CoachMemory.maximumTextUTF8Bytes &&
                !$0.unicodeScalars.contains(where: { $0.value == 0 })
        })
        else { throw CoachResponseValidationError.invalidMemory }
        for summary in memory.sessionSummaries {
            guard allowedAttachments.contains(summary.sessionAttachmentID),
                  seen.insert(summary.sessionAttachmentID).inserted
            else { throw CoachResponseValidationError.invalidMemory }
        }
        let fits: Bool
        do { fits = try context.authority.memoryFits(memory.canonicalValue) } catch {
            throw CoachResponseValidationError.memoryTokenLimitExceeded
        }
        guard fits else {
            throw CoachResponseValidationError.memoryTokenLimitExceeded
        }
    }

    private enum EvidencePurpose { case messageObservation, profileSupport }

    private func validate(
        evidence: [CoachResponseEvidencePointer],
        purpose: EvidencePurpose,
        in context: CoachResponseValidationContext
    ) throws {
        for pointer in evidence {
            guard let transcript = context.transcripts[pointer.sessionAttachmentID]
            else { throw CoachResponseValidationError.invalidEvidencePointer }
            switch pointer.target {
            case let .wordRange(startWordID, endWordID):
                guard let start = transcript.wordPositions[startWordID],
                      let end = transcript.wordPositions[endWordID],
                      start <= end
                else { throw CoachResponseValidationError.invalidEvidencePointer }
            case let .audioEvent(audioEventID):
                guard transcript.audioEventIDs.contains(audioEventID) else {
                    throw CoachResponseValidationError.invalidEvidencePointer
                }
                if purpose == .profileSupport,
                   transcript.audioEventIDsIneligibleForProfileSupport.contains(
                       audioEventID
                   )
                {
                    throw CoachResponseValidationError.invalidEvidencePointer
                }
            }
        }
    }

    private func validateProfileEffects(
        _ response: ParsedCoachResponse,
        in context: CoachResponseValidationContext
    ) throws {
        var semanticTargets: [
            CoachResponseProfileStatementID: ValidatedCoachProfileEdit
        ] = [:]
        for proposal in response.proposedProfileEdits {
            guard let target = proposal.edit.targetStatementID else { continue }
            guard context.activeProfileStatementIDs.contains(target) else {
                throw CoachResponseValidationError.danglingProfileTarget
            }
            if let existing = semanticTargets[target], existing != proposal.edit {
                throw CoachResponseValidationError.conflictingProfileEffects
            }
            semanticTargets[target] = proposal.edit
        }
        for append in response.appendedProfileEvidence {
            guard context.activeProfileStatementIDs.contains(
                append.targetStatementID
            ) else { throw CoachResponseValidationError.danglingProfileTarget }
            guard semanticTargets[append.targetStatementID] == nil else {
                throw CoachResponseValidationError.conflictingProfileEffects
            }
        }
    }
}

private struct ParsedCoachResponse {
    let messageBlocks: [ValidatedCoachResponseBlock]
    let newMemory: ValidatedCoachResponseMemory?
    let proposedProfileEdits: [ValidatedCoachProfileEditProposal]
    let appendedProfileEvidence: [ValidatedCoachProfileEvidenceAppend]
}

private struct CoachResponseSchemaDecoder {
    private enum SchemaError: Error { case mismatch }

    func decode(_ data: Data) throws -> ParsedCoachResponse {
        let value = try JSONSerialization.jsonObject(with: data)
        let root = try object(
            value,
            allowed: [
                "messageBlocks", "newMemory", "proposeProfileEdits",
                "appendProfileEvidence",
            ],
            required: []
        )
        let blocks = try optionalArray(root, key: "messageBlocks")?.map(block) ?? []
        let memory = try root["newMemory"].map(memory)
        let edits = try optionalArray(root, key: "proposeProfileEdits")?
            .map(profileEditProposal) ?? []
        let appends = try optionalArray(root, key: "appendProfileEvidence")?
            .map(profileEvidenceAppend) ?? []
        return ParsedCoachResponse(
            messageBlocks: blocks,
            newMemory: memory,
            proposedProfileEdits: edits,
            appendedProfileEvidence: appends
        )
    }

    private func block(_ value: Any) throws -> ValidatedCoachResponseBlock {
        let discriminator = try discriminatedObject(value)
        switch discriminator.kind {
        case "markdown":
            let fields = try exact(
                discriminator.fields,
                allowed: ["kind", "markdown"],
                required: ["kind", "markdown"]
            )
            return .markdown(try nonemptyString(fields["markdown"]))
        case "evidenceObservation":
            let fields = try exact(
                discriminator.fields,
                allowed: ["kind", "markdown", "evidence"],
                required: ["kind", "markdown", "evidence"]
            )
            return .evidenceObservation(
                markdown: try nonemptyString(fields["markdown"]),
                evidence: try nonemptyArray(fields["evidence"]).map(pointer)
            )
        default: throw SchemaError.mismatch
        }
    }

    private func memory(_ value: Any) throws -> ValidatedCoachResponseMemory {
        let fields = try object(
            value,
            allowed: ["generalNotes", "sessionSummaries"],
            required: ["generalNotes", "sessionSummaries"]
        )
        guard let notes = fields["generalNotes"] as? String,
              let summaries = fields["sessionSummaries"] as? [Any]
        else { throw SchemaError.mismatch }
        return ValidatedCoachResponseMemory(
            generalNotes: notes,
            sessionSummaries: try summaries.map(memorySummary)
        )
    }

    private func memorySummary(
        _ value: Any
    ) throws -> ValidatedCoachResponseMemorySummary {
        let fields = try object(
            value,
            allowed: ["sessionAttachmentId", "notes"],
            required: ["sessionAttachmentId", "notes"]
        )
        guard let rawID = fields["sessionAttachmentId"] as? String,
              let attachmentID = try? ChatSessionAttachmentID(rawID)
        else { throw SchemaError.mismatch }
        return ValidatedCoachResponseMemorySummary(
            sessionAttachmentID: attachmentID,
            notes: try nonemptyString(fields["notes"])
        )
    }

    private func profileEditProposal(
        _ value: Any
    ) throws -> ValidatedCoachProfileEditProposal {
        let fields = try object(
            value,
            allowed: ["edit", "evidence"],
            required: ["edit"]
        )
        let evidence = try optionalArray(fields, key: "evidence")?.map(pointer) ?? []
        return ValidatedCoachProfileEditProposal(
            edit: try profileEdit(fields["edit"] as Any),
            evidence: evidence
        )
    }

    private func profileEdit(_ value: Any) throws -> ValidatedCoachProfileEdit {
        let discriminator = try discriminatedObject(value)
        switch discriminator.kind {
        case "add":
            let fields = try exact(
                discriminator.fields,
                allowed: ["kind", "statementKind", "wording"],
                required: ["kind", "statementKind", "wording"]
            )
            guard let rawKind = fields["statementKind"] as? String,
                  let kind = CoachResponseProfileStatementKind(rawValue: rawKind)
            else { throw SchemaError.mismatch }
            return .add(
                statementKind: kind,
                wording: try nonemptyString(fields["wording"])
            )
        case "replace":
            let fields = try exact(
                discriminator.fields,
                allowed: ["kind", "targetStatementId", "wording"],
                required: ["kind", "targetStatementId", "wording"]
            )
            return .replace(
                targetStatementID: try profileStatementID(
                    fields["targetStatementId"]
                ),
                wording: try nonemptyString(fields["wording"])
            )
        case "retire":
            let fields = try exact(
                discriminator.fields,
                allowed: ["kind", "targetStatementId"],
                required: ["kind", "targetStatementId"]
            )
            return .retire(
                targetStatementID: try profileStatementID(
                    fields["targetStatementId"]
                )
            )
        default: throw SchemaError.mismatch
        }
    }

    private func profileEvidenceAppend(
        _ value: Any
    ) throws -> ValidatedCoachProfileEvidenceAppend {
        let fields = try object(
            value,
            allowed: ["targetStatementId", "evidence"],
            required: ["targetStatementId", "evidence"]
        )
        return ValidatedCoachProfileEvidenceAppend(
            targetStatementID: try profileStatementID(fields["targetStatementId"]),
            evidence: try nonemptyArray(fields["evidence"]).map(pointer)
        )
    }

    private func pointer(_ value: Any) throws -> CoachResponseEvidencePointer {
        let fields = try object(
            value,
            allowed: ["sessionAttachmentId", "target"],
            required: ["sessionAttachmentId", "target"]
        )
        guard let rawID = fields["sessionAttachmentId"] as? String,
              let attachmentID = try? ChatSessionAttachmentID(rawID),
              let targetValue = fields["target"]
        else { throw SchemaError.mismatch }
        return CoachResponseEvidencePointer(
            sessionAttachmentID: attachmentID,
            target: try target(targetValue)
        )
    }

    private func target(_ value: Any) throws -> CoachResponseEvidenceTarget {
        let discriminator = try discriminatedObject(value)
        switch discriminator.kind {
        case "wordRange":
            let fields = try exact(
                discriminator.fields,
                allowed: ["kind", "startWordId", "endWordId"],
                required: ["kind", "startWordId", "endWordId"]
            )
            return .wordRange(
                startWordID: try wordID(fields["startWordId"]),
                endWordID: try wordID(fields["endWordId"])
            )
        case "audioEvent":
            let fields = try exact(
                discriminator.fields,
                allowed: ["kind", "audioEventId"],
                required: ["kind", "audioEventId"]
            )
            return .audioEvent(
                audioEventID: try audioEventID(fields["audioEventId"])
            )
        default: throw SchemaError.mismatch
        }
    }

    private func discriminatedObject(
        _ value: Any
    ) throws -> (kind: String, fields: [String: Any]) {
        guard let fields = value as? [String: Any],
              let kind = fields["kind"] as? String
        else { throw SchemaError.mismatch }
        return (kind, fields)
    }

    private func object(
        _ value: Any,
        allowed: Set<String>,
        required: Set<String>
    ) throws -> [String: Any] {
        guard let fields = value as? [String: Any] else {
            throw SchemaError.mismatch
        }
        return try exact(fields, allowed: allowed, required: required)
    }

    private func exact(
        _ fields: [String: Any],
        allowed: Set<String>,
        required: Set<String>
    ) throws -> [String: Any] {
        let keys = Set(fields.keys)
        guard keys.isSubset(of: allowed), required.isSubset(of: keys) else {
            throw SchemaError.mismatch
        }
        return fields
    }

    private func optionalArray(
        _ fields: [String: Any],
        key: String
    ) throws -> [Any]? {
        guard let value = fields[key] else { return nil }
        return try nonemptyArray(value)
    }

    private func nonemptyArray(_ value: Any?) throws -> [Any] {
        guard let array = value as? [Any], !array.isEmpty else {
            throw SchemaError.mismatch
        }
        return array
    }

    private func nonemptyString(_ value: Any?) throws -> String {
        guard let string = value as? String, !string.isEmpty else {
            throw SchemaError.mismatch
        }
        return string
    }

    private func wordID(_ value: Any?) throws -> CoachResponseWordID {
        guard let result = CoachResponseWordID(try nonemptyString(value)) else {
            throw SchemaError.mismatch
        }
        return result
    }

    private func audioEventID(_ value: Any?) throws -> CoachResponseAudioEventID {
        guard let result = CoachResponseAudioEventID(try nonemptyString(value)) else {
            throw SchemaError.mismatch
        }
        return result
    }

    private func profileStatementID(
        _ value: Any?
    ) throws -> CoachResponseProfileStatementID {
        guard let result = CoachResponseProfileStatementID(
            try nonemptyString(value)
        ) else { throw SchemaError.mismatch }
        return result
    }
}

/// Rejects duplicate object keys before Foundation decoding, including escaped
/// spellings of the same key. It also supplies a bounded nesting gate.
private struct StrictJSONStructureScanner {
    enum Error: Swift.Error { case malformed, duplicateKey, nesting }

    private let bytes: [UInt8]
    private var index = 0
    private let maximumDepth = 128

    init(data: Data) {
        bytes = Array(data)
    }

    mutating func validate() throws {
        skipWhitespace()
        try parseValue(depth: 0)
        skipWhitespace()
        guard index == bytes.count else { throw Error.malformed }
    }

    private mutating func parseValue(depth: Int) throws {
        guard depth <= maximumDepth, index < bytes.count else {
            throw depth > maximumDepth ? Error.nesting : Error.malformed
        }
        switch bytes[index] {
        case 0x7B: try parseObject(depth: depth)
        case 0x5B: try parseArray(depth: depth)
        case 0x22: _ = try parseString()
        case 0x74: try consume("true")
        case 0x66: try consume("false")
        case 0x6E: try consume("null")
        case 0x2D, 0x30 ... 0x39: try parseNumber()
        default: throw Error.malformed
        }
    }

    private mutating func parseObject(depth: Int) throws {
        index += 1
        skipWhitespace()
        if consumeIf(0x7D) { return }
        var keys: Set<String> = []
        while true {
            guard index < bytes.count, bytes[index] == 0x22 else {
                throw Error.malformed
            }
            let key = try parseString()
            guard keys.insert(key).inserted else { throw Error.duplicateKey }
            skipWhitespace()
            guard consumeIf(0x3A) else { throw Error.malformed }
            skipWhitespace()
            try parseValue(depth: depth + 1)
            skipWhitespace()
            if consumeIf(0x7D) { return }
            guard consumeIf(0x2C) else { throw Error.malformed }
            skipWhitespace()
        }
    }

    private mutating func parseArray(depth: Int) throws {
        index += 1
        skipWhitespace()
        if consumeIf(0x5D) { return }
        while true {
            try parseValue(depth: depth + 1)
            skipWhitespace()
            if consumeIf(0x5D) { return }
            guard consumeIf(0x2C) else { throw Error.malformed }
            skipWhitespace()
        }
    }

    private mutating func parseString() throws -> String {
        let start = index
        index += 1
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 {
                index += 1
                let token = Data(bytes[start ..< index])
                guard let value = try? JSONDecoder().decode(String.self, from: token)
                else { throw Error.malformed }
                return value
            }
            if byte < 0x20 { throw Error.malformed }
            if byte == 0x5C {
                index += 1
                guard index < bytes.count else { throw Error.malformed }
                let escaped = bytes[index]
                if escaped == 0x75 {
                    guard index + 4 < bytes.count else { throw Error.malformed }
                    for offset in 1 ... 4 where !Self.isHex(bytes[index + offset]) {
                        throw Error.malformed
                    }
                    index += 5
                    continue
                }
                guard [0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74]
                    .contains(escaped)
                else { throw Error.malformed }
            }
            index += 1
        }
        throw Error.malformed
    }

    private mutating func parseNumber() throws {
        _ = consumeIf(0x2D)
        guard index < bytes.count else { throw Error.malformed }
        if consumeIf(0x30) {
            if index < bytes.count, (0x30 ... 0x39).contains(bytes[index]) {
                throw Error.malformed
            }
        } else {
            guard consumeDigit(0x31 ... 0x39) else { throw Error.malformed }
            while consumeDigit(0x30 ... 0x39) {}
        }
        if consumeIf(0x2E) {
            guard consumeDigit(0x30 ... 0x39) else { throw Error.malformed }
            while consumeDigit(0x30 ... 0x39) {}
        }
        if index < bytes.count,
           bytes[index] == 0x65 || bytes[index] == 0x45
        {
            index += 1
            if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D {
                index += 1
            }
            guard consumeDigit(0x30 ... 0x39) else { throw Error.malformed }
            while consumeDigit(0x30 ... 0x39) {}
        }
    }

    private mutating func consume(_ literal: StaticString) throws {
        for byte in String(describing: literal).utf8 {
            guard consumeIf(byte) else { throw Error.malformed }
        }
    }

    private mutating func consumeDigit(
        _ range: ClosedRange<UInt8>
    ) -> Bool {
        guard index < bytes.count, range.contains(bytes[index]) else { return false }
        index += 1
        return true
    }

    private mutating func consumeIf(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while index < bytes.count {
            guard [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) else {
                return
            }
            index += 1
        }
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (0x30 ... 0x39).contains(byte) || (0x41 ... 0x46).contains(byte) ||
            (0x61 ... 0x66).contains(byte)
    }
}
