import AudoraApplication
import AudoraDomain
import Foundation

struct LibraryCatalogRowPresentation: Equatable {
    let aggregate: LibraryAggregate
    let kind: String
    let title: String
    let metadata: String
    let accessibilityLabel: String

    private let searchValues: [String]

    init(
        row: LibraryCatalogRow,
        formatDate: (UTCInstant) -> String = LibraryCatalogFormatting.localizedDate
    ) {
        aggregate = row.aggregate
        kind = switch row.aggregate {
        case .session: "Session"
        case .chat: "Chat"
        }

        switch row {
        case let .session(_, metadata):
            title = "Session · \(formatDate(metadata.createdAt))"
            let acquisition = switch metadata.acquisition {
            case .imported: "Imported"
            case .recorded: "Recorded"
            }
            let transcript = metadata.hasSelectedTranscript
                ? "Transcript ready"
                : "No transcript"
            self.metadata = "\(acquisition) · \(transcript)"
            searchValues = [
                kind,
                title,
                self.metadata,
                metadata.createdAt.rawValue,
            ]
        case let .chat(_, metadata):
            title = metadata.title.rawValue
            self.metadata =
                "Created \(formatDate(metadata.createdAt)) · Updated " +
                formatDate(metadata.updatedAt)
            searchValues = [
                kind,
                title,
                self.metadata,
                metadata.createdAt.rawValue,
                metadata.updatedAt.rawValue,
            ]
        case let .unavailable(_, reason):
            title = "Unavailable \(kind)"
            self.metadata = switch reason {
            case .corrupt: "Manifest could not be read"
            case .newerSchema: "Created by a newer Audora version"
            case .unsupportedSchema: "Manifest version is not supported"
            }
            searchValues = [kind, title, self.metadata]
        }

        accessibilityLabel = "\(kind) \(title), \(metadata)"
    }

    func matches(_ query: String) -> Bool {
        let foldedQuery = LibraryCatalogFormatting.folded(
            query.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !foldedQuery.isEmpty else { return true }
        return searchValues.contains {
            LibraryCatalogFormatting.folded($0).contains(foldedQuery)
        }
    }
}

enum LibraryCatalogMutationNoticeFormatter {
    static func text(for notice: LibraryCatalogMutationNotice) -> String {
        let successes = outcomeCount(.succeeded, in: notice)
        let uncertain = outcomeCount(.commitUncertain, in: notice)
        let action = switch notice.action {
        case .movedToTrash: "Moved to Trash"
        case .restored: "Restored"
        }
        var parts: [String] = []
        if successes > 0 { parts.append("\(action): \(successes)") }
        if uncertain > 0 {
            let change = uncertain == 1 ? "change" : "changes"
            if notice.catalogVerification == .verifiedCurrentContents {
                parts.append(
                    "\(uncertain) \(change) may have completed; " +
                        "the Library contents were refreshed"
                )
            } else {
                parts.append(
                    "\(uncertain) \(change) may have completed; current " +
                        "Library contents could not be verified"
                )
            }
        }
        appendOutcome(
            .sourceMissing,
            to: &parts,
            notice: notice,
            message: "no longer existed in its expected location"
        )
        appendOutcome(
            .targetCollision,
            to: &parts,
            notice: notice,
            message: "already existed at the destination"
        )
        appendOutcome(
            .busy,
            to: &parts,
            notice: notice,
            message: "was busy and was not changed"
        )
        appendOutcome(
            .readOnly,
            to: &parts,
            notice: notice,
            message: "could not change because the Library is read-only"
        )
        appendOutcome(
            .unsupportedSchema,
            to: &parts,
            notice: notice,
            message: "uses an unsupported schema and was not changed"
        )
        appendOutcome(
            .unavailable,
            to: &parts,
            notice: notice,
            message: "was unavailable and was not changed"
        )
        appendOutcome(
            .integrityMismatch,
            to: &parts,
            notice: notice,
            message: "could not be verified and was not changed"
        )
        appendOutcome(
            .failed,
            to: &parts,
            notice: notice,
            message: "could not be changed"
        )
        return parts.isEmpty
            ? "No Library items changed."
            : parts.joined(separator: ". ") + "."
    }

    private static func outcomeCount(
        _ outcome: LibraryAggregateMutationOutcome,
        in notice: LibraryCatalogMutationNotice
    ) -> Int {
        notice.results.filter { $0.outcome == outcome }.count
    }

    private static func appendOutcome(
        _ outcome: LibraryAggregateMutationOutcome,
        to parts: inout [String],
        notice: LibraryCatalogMutationNotice,
        message: String
    ) {
        let count = outcomeCount(outcome, in: notice)
        guard count > 0 else { return }
        parts.append("\(count) item\(count == 1 ? "" : "s") \(message)")
    }
}

private enum LibraryCatalogFormatting {
    static func folded(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    static func localizedDate(_ instant: UTCInstant) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: instant.rawValue) else {
            return instant.rawValue
        }
        return DateFormatter.localizedString(
            from: date,
            dateStyle: .medium,
            timeStyle: .short
        )
    }
}
