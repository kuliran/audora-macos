import AppKit
import AudoraApplication
import AudoraDomain
import SwiftUI

struct ReviewAnnotationStyleToken {
    let underlineStyle: NSUnderlineStyle
    let underlineColor: NSColor
}

/// Semantic presentation tokens kept separate from annotation classification.
/// Each category also has a distinct underline pattern, so color is never the
/// only signal.
enum ReviewAnnotationStyleTokens {
    static let minimumContrastRatio = 3.0

    static func style(
        for category: TextualEventCategory
    ) -> ReviewAnnotationStyleToken {
        switch category {
        case .filledPause:
            ReviewAnnotationStyleToken(
                underlineStyle: .single,
                underlineColor: .systemBrown
            )
        case .partialWord:
            ReviewAnnotationStyleToken(
                underlineStyle: .double,
                underlineColor: .systemRed
            )
        case .repetitionCandidate:
            ReviewAnnotationStyleToken(
                underlineStyle: .single.union(.patternDot),
                underlineColor: .systemPurple
            )
        }
    }
}

enum ReviewActiveWordStyleTokens {
    /// Keeps the playback cue visible without reducing any annotation
    /// underline below the WCAG non-text contrast target.
    static var backgroundColor: NSColor {
        NSColor.controlAccentColor.withAlphaComponent(0.08)
    }
}

public struct ReviewView: View {
    @ObservedObject private var model: ReviewPresentationModel

    public init(model: ReviewPresentationModel) {
        self.model = model
    }

    public var body: some View {
        GroupBox("Transcript Review") {
            Group {
                switch model.state {
                case nil, .some(.loading):
                    ProgressView("Loading transcript review…")
                        .frame(maxWidth: .infinity, alignment: .leading)
                case let .some(.unavailable(_, reason)):
                    unavailable(reason)
                case let .some(.ready(snapshot)):
                    ready(snapshot)
                }
            }
            .padding(.vertical, 4)
        }
        .accessibilityElement(children: .contain)
    }

    private func ready(_ snapshot: ReviewReadySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Button {
                    snapshot.playback.status == .playing
                        ? model.pause()
                        : model.play()
                } label: {
                    Label(
                        snapshot.playback.status == .playing ? "Pause" : "Play",
                        systemImage: snapshot.playback.status == .playing
                            ? "pause.fill"
                            : "play.fill"
                    )
                }
                .disabled(snapshot.activity != nil)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Canonical audio")
                        .font(.caption.weight(.semibold))
                    Text(
                        "\(format(snapshot.playback.positionMilliseconds)) / " +
                            format(snapshot.playback.durationMilliseconds)
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }

                ProgressView(
                    value: Double(snapshot.playback.positionMilliseconds),
                    total: Double(snapshot.playback.durationMilliseconds)
                )
                .accessibilityLabel("Playback position")

                Spacer(minLength: 8)

                Toggle(
                    "Show annotations",
                    isOn: Binding(
                        get: { snapshot.annotations.isVisible },
                        set: { model.setAnnotationsVisible($0) }
                    )
                )
                .toggleStyle(.switch)
                .accessibilityLabel("Show speech annotations")
                .accessibilityHint(
                    "Shows or hides local speech evidence without changing the transcript."
                )
                .disabled(snapshot.activity != nil)

                Menu {
                    ForEach(snapshot.revisionIDs, id: \.self) { revisionID in
                        Button {
                            model.selectRevision(revisionID)
                        } label: {
                            HStack {
                                Text(revisionID.rawValue)
                                if revisionID == snapshot.selectedRevisionID {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .disabled(revisionID == snapshot.selectedRevisionID)
                    }
                } label: {
                    Label(
                        "Revision \(selectedRevisionNumber(snapshot)) " +
                            "of \(snapshot.revisionIDs.count)",
                        systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90"
                    )
                }
                .disabled(snapshot.activity != nil)

                Button("Retranscribe") { model.retranscribe() }
                    .disabled(snapshot.activity != nil)
            }

            if let activity = snapshot.activity {
                ProgressView(activityLabel(activity))
                    .controlSize(.small)
            }
            if let notice = snapshot.notice {
                Text(noticeText(notice))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ReviewTranscriptTextView(
                revision: snapshot.selectedRevision,
                activeWordID: snapshot.activeWordID,
                annotations: snapshot.annotations,
                allowsSeeking: snapshot.activity == nil
            ) { lineID, utf8ByteOffset in
                model.seek(lineID: lineID, utf8ByteOffset: utf8ByteOffset)
            }
            .frame(minHeight: 150, idealHeight: 210, maxHeight: 260)
            .accessibilityLabel("Immutable selected transcript")

            if snapshot.annotations.isVisible,
               !snapshot.annotations.projection.audioEvents.isEmpty
            {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        ForEach(
                            snapshot.annotations.projection.audioEvents.prefix(500),
                            id: \.audioEventID
                        ) { event in
                            let accessibilityLabel =
                                ReviewPresentationModel.audioEventAccessibilityLabel(
                                    for: event
                                )
                            Text(accessibilityLabel)
                                .font(.caption.monospacedDigit())
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(.quaternary, in: Capsule())
                                .accessibilityLabel(accessibilityLabel)
                        }
                        let hiddenCount = max(
                            snapshot.annotations.projection.audioEvents.count - 500,
                            0
                        )
                        if hiddenCount > 0 {
                            Text("+\(hiddenCount) more local events")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityLabel("Local audio annotations")
            }
        }
    }

    private func unavailable(_ reason: ReviewUnavailableReason) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(unavailableTitle(reason)).font(.headline)
            Text(unavailableDetail(reason))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func selectedRevisionNumber(_ snapshot: ReviewReadySnapshot) -> Int {
        (snapshot.revisionIDs.firstIndex(of: snapshot.selectedRevisionID) ?? 0) + 1
    }

    private func activityLabel(_ activity: ReviewActivity) -> String {
        switch activity {
        case .settingAnnotationVisibility: "Saving annotation preference…"
        case .selectingRevision: "Selecting revision…"
        case .retranscribing: "Transcribing another revision…"
        }
    }

    private func format(_ milliseconds: UInt64) -> String {
        let totalSeconds = milliseconds / 1_000
        return String(format: "%02llu:%02llu", totalSeconds / 60, totalSeconds % 60)
    }

    private func unavailableTitle(_ reason: ReviewUnavailableReason) -> String {
        switch reason {
        case .noSession: "Choose a Session to review"
        case .noTranscript: "No transcript is ready"
        case .integrityMismatch: "Transcript review could not be verified"
        case .playbackUnavailable: "Canonical audio is unavailable"
        }
    }

    private func unavailableDetail(_ reason: ReviewUnavailableReason) -> String {
        switch reason {
        case .noSession: "Record or import audio, then select its Session."
        case .noTranscript: "Transcribe this Session to create its first immutable revision."
        case .integrityMismatch: "Audora did not display mismatched Session state."
        case .playbackUnavailable: "The selected revision was preserved, but its audio could not be opened."
        }
    }

    private func noticeText(_ notice: ReviewNotice) -> String {
        switch notice {
        case .selectionChanged: "Another reviewer changed the selected revision; the latest selection is shown."
        case .selectionFailed: "The selected revision could not be changed."
        case .retranscribed: "A new immutable revision was added and selected."
        case .retranscriptionFailed: "Another revision could not be created."
        case .playbackUnavailable: "Canonical audio playback is unavailable."
        }
    }

}

private struct ReviewTranscriptTextView: NSViewRepresentable {
    let revision: TranscriptRevision
    let activeWordID: TranscriptWordID?
    let annotations: ReviewAnnotations
    let allowsSeeking: Bool
    let onSeek: (TranscriptLineID, Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSeek: onSeek) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = true

        let textView = SeekingTranscriptTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.onCharacterIndex = { [weak coordinator = context.coordinator] index in
            coordinator?.seek(characterIndex: index)
        }
        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.install(
            revision: revision,
            activeWordID: activeWordID,
            annotations: annotations,
            allowsSeeking: allowsSeeking
        )
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onSeek = onSeek
        context.coordinator.install(
            revision: revision,
            activeWordID: activeWordID,
            annotations: annotations,
            allowsSeeking: allowsSeeking
        )
    }

    @MainActor
    final class Coordinator {
        struct LinePlacement {
            let characterRange: NSRange
            let lineID: TranscriptLineID
            let text: String
        }

        weak var textView: SeekingTranscriptTextView?
        var onSeek: (TranscriptLineID, Int) -> Void
        private var installedRevisionID: TranscriptRevisionID?
        private var installedActiveWordID: TranscriptWordID?
        private var installedAnnotations: ReviewAnnotations?
        private var allowsSeeking = true
        private var linePlacements: [LinePlacement] = []
        private var wordRanges: [TranscriptWordID: NSRange] = [:]

        init(onSeek: @escaping (TranscriptLineID, Int) -> Void) {
            self.onSeek = onSeek
        }

        func install(
            revision: TranscriptRevision,
            activeWordID: TranscriptWordID?,
            annotations: ReviewAnnotations,
            allowsSeeking: Bool
        ) {
            self.allowsSeeking = allowsSeeking
            if installedRevisionID != revision.revisionID {
                rebuild(revision)
                installedRevisionID = revision.revisionID
                installedActiveWordID = nil
                installedAnnotations = nil
            }
            updateAnnotations(annotations)
            updateHighlight(activeWordID)
        }

        func seek(characterIndex: Int) {
            guard allowsSeeking,
                  let placement = placement(containing: characterIndex)
            else { return }
            let localUTF16Offset = min(
                max(characterIndex - placement.characterRange.location, 0),
                placement.text.utf16.count
            )
            let byteOffset = utf8Offset(
                in: placement.text,
                utf16Offset: localUTF16Offset
            )
            onSeek(placement.lineID, byteOffset)
        }

        private func rebuild(_ revision: TranscriptRevision) {
            let document = NSMutableAttributedString()
            var placements: [LinePlacement] = []
            var ranges: [TranscriptWordID: NSRange] = [:]
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3
            let baseAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.preferredFont(forTextStyle: .body),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]

            for (index, line) in revision.lines.enumerated() {
                if index > 0 {
                    document.append(NSAttributedString(string: "\n\n", attributes: baseAttributes))
                }
                let start = document.length
                document.append(NSAttributedString(string: line.text, attributes: baseAttributes))
                placements.append(
                    LinePlacement(
                        characterRange: NSRange(
                            location: start,
                            length: (line.text as NSString).length
                        ),
                        lineID: line.lineID,
                        text: line.text
                    )
                )
                for word in line.words {
                    guard let localRange = nsRange(
                        in: line.text,
                        utf8Range: word.displayRange
                    ) else { continue }
                    ranges[word.wordID] = NSRange(
                        location: start + localRange.location,
                        length: localRange.length
                    )
                }
            }
            linePlacements = placements
            wordRanges = ranges
            textView?.textStorage?.setAttributedString(document)
        }

        private func updateHighlight(_ activeWordID: TranscriptWordID?) {
            guard activeWordID != installedActiveWordID else { return }
            if let previous = installedActiveWordID,
               let range = wordRanges[previous]
            {
                textView?.textStorage?.removeAttribute(.backgroundColor, range: range)
            }
            if let activeWordID, let range = wordRanges[activeWordID] {
                textView?.textStorage?.addAttribute(
                    .backgroundColor,
                    value: ReviewActiveWordStyleTokens.backgroundColor,
                    range: range
                )
                textView?.scrollRangeToVisible(range)
            }
            installedActiveWordID = activeWordID
        }

        private func updateAnnotations(_ annotations: ReviewAnnotations) {
            guard annotations != installedAnnotations,
                  let storage = textView?.textStorage
            else { return }
            let documentRange = NSRange(location: 0, length: storage.length)
            storage.removeAttribute(.underlineStyle, range: documentRange)
            storage.removeAttribute(.underlineColor, range: documentRange)
            if annotations.isVisible {
                for overlay in annotations.projection.textualOverlays {
                    guard let range = wordRanges[overlay.wordID] else { continue }
                    let token = ReviewAnnotationStyleTokens.style(
                        for: overlay.category
                    )
                    storage.addAttribute(
                        .underlineStyle,
                        value: token.underlineStyle.rawValue,
                        range: range
                    )
                    storage.addAttribute(
                        .underlineColor,
                        value: token.underlineColor,
                        range: range
                    )
                }
            }
            installedAnnotations = annotations
        }

        private func placement(containing characterIndex: Int) -> LinePlacement? {
            var lower = 0
            var upper = linePlacements.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                let candidate = linePlacements[middle]
                if characterIndex < candidate.characterRange.location {
                    upper = middle
                } else if characterIndex >= NSMaxRange(candidate.characterRange) {
                    lower = middle + 1
                } else {
                    return candidate
                }
            }
            return nil
        }

        private func nsRange(
            in text: String,
            utf8Range: LineTextRange
        ) -> NSRange? {
            let utf8 = text.utf8
            guard utf8Range.startUTF8Byte >= 0,
                  utf8Range.endUTF8Byte >= utf8Range.startUTF8Byte,
                  utf8Range.endUTF8Byte <= utf8.count
            else { return nil }
            let startUTF8 = utf8.index(
                utf8.startIndex,
                offsetBy: utf8Range.startUTF8Byte
            )
            let endUTF8 = utf8.index(
                utf8.startIndex,
                offsetBy: utf8Range.endUTF8Byte
            )
            guard let start = String.Index(startUTF8, within: text),
                  let end = String.Index(endUTF8, within: text)
            else { return nil }
            return NSRange(start..<end, in: text)
        }

        private func utf8Offset(in text: String, utf16Offset: Int) -> Int {
            let utf16 = text.utf16
            var offset = min(max(utf16Offset, 0), utf16.count)
            while offset > 0 {
                let utf16Index = utf16.index(utf16.startIndex, offsetBy: offset)
                if let index = String.Index(utf16Index, within: text) {
                    return text[..<index].utf8.count
                }
                offset -= 1
            }
            return 0
        }
    }
}

@MainActor
private final class SeekingTranscriptTextView: NSTextView {
    var onCharacterIndex: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard let layoutManager, let textContainer else { return }
        var point = convert(event.locationInWindow, from: nil)
        point.x -= textContainerOrigin.x
        point.y -= textContainerOrigin.y
        let glyphIndex = layoutManager.glyphIndex(
            for: point,
            in: textContainer,
            fractionOfDistanceThroughGlyph: nil
        )
        guard glyphIndex < layoutManager.numberOfGlyphs else { return }
        onCharacterIndex?(layoutManager.characterIndexForGlyph(at: glyphIndex))
    }
}
