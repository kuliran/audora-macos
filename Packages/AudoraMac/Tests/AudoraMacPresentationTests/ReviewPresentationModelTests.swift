import AppKit
import AudoraApplication
import AudoraDomain
@testable import AudoraMacPresentation
import XCTest

@MainActor
final class ReviewPresentationModelTests: XCTestCase {
    func testAnnotationStyleTokensMeetContrastInEverySupportedAppearance() throws {
        let appearances: [NSAppearance.Name] = [
            .aqua,
            .darkAqua,
            .vibrantLight,
            .vibrantDark,
            .accessibilityHighContrastAqua,
            .accessibilityHighContrastDarkAqua,
            .accessibilityHighContrastVibrantLight,
            .accessibilityHighContrastVibrantDark,
        ]
        let categories: [TextualEventCategory] = [
            .filledPause,
            .partialWord,
            .repetitionCandidate,
        ]

        for appearanceName in appearances {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            appearance.performAsCurrentDrawingAppearance {
                for category in categories {
                    let token = ReviewAnnotationStyleTokens.style(for: category)
                    for background in [
                        NSColor.textBackgroundColor,
                        composite(
                            foreground: ReviewActiveWordStyleTokens.backgroundColor,
                            over: .textBackgroundColor
                        ),
                    ] {
                        let contrast = contrastRatio(
                            foreground: token.underlineColor,
                            background: background
                        )
                        XCTAssertGreaterThanOrEqual(
                            contrast,
                            ReviewAnnotationStyleTokens.minimumContrastRatio,
                            "\(category) in \(appearanceName.rawValue)"
                        )
                    }
                }
            }
        }

        XCTAssertEqual(
            ReviewAnnotationStyleTokens.style(for: .filledPause).underlineStyle,
            .single
        )
        XCTAssertEqual(
            ReviewAnnotationStyleTokens.style(for: .partialWord).underlineStyle,
            .double
        )
        XCTAssertTrue(
            ReviewAnnotationStyleTokens.style(for: .repetitionCandidate)
                .underlineStyle.contains(.patternDot)
        )
    }

    func testModelProjectsStateAndSendsTypedReviewCommands() async throws {
        let feature = ScriptedReviewFeature()
        let model = ReviewPresentationModel(feature: feature)
        let selection = ReviewSelection(
            scope: LibraryScope(
                libraryID: try LibraryID("lib-20260830T120000000Z-1ABC")
            ),
            sessionID: try SessionID("ses-20260830T120100000Z-2CDE")
        )

        await model.start()
        model.selectSession(selection)
        model.play()
        model.pause()
        model.setAnnotationsVisible(false)
        model.retranscribe()
        model.clearSelection()
        await feature.waitForCommandCount(6)

        guard case let .unavailable(_, reason) = model.state else {
            return XCTFail("expected initial Review projection")
        }
        XCTAssertEqual(reason, .noSession)
        let commands = await feature.recordedCommands()
        XCTAssertEqual(
            commands,
            [
                .selectSession(selection),
                .play,
                .pause,
                .setAnnotationsVisible(false),
                .retranscribe,
                .clearSelection,
            ]
        )
    }
}

private func contrastRatio(
    foreground: NSColor,
    background: NSColor
) -> Double {
    guard let foreground = foreground.usingColorSpace(.sRGB),
          let background = background.usingColorSpace(.sRGB)
    else { return 0 }
    let alpha = Double(foreground.alphaComponent)
    let red = Double(foreground.redComponent) * alpha +
        Double(background.redComponent) * (1 - alpha)
    let green = Double(foreground.greenComponent) * alpha +
        Double(background.greenComponent) * (1 - alpha)
    let blue = Double(foreground.blueComponent) * alpha +
        Double(background.blueComponent) * (1 - alpha)
    let foregroundLuminance = relativeLuminance(red: red, green: green, blue: blue)
    let backgroundLuminance = relativeLuminance(
        red: Double(background.redComponent),
        green: Double(background.greenComponent),
        blue: Double(background.blueComponent)
    )
    return (max(foregroundLuminance, backgroundLuminance) + 0.05) /
        (min(foregroundLuminance, backgroundLuminance) + 0.05)
}

private func composite(foreground: NSColor, over background: NSColor) -> NSColor {
    guard let foreground = foreground.usingColorSpace(.sRGB),
          let background = background.usingColorSpace(.sRGB)
    else { return .clear }
    let alpha = foreground.alphaComponent
    return NSColor(
        calibratedRed: foreground.redComponent * alpha +
            background.redComponent * (1 - alpha),
        green: foreground.greenComponent * alpha +
            background.greenComponent * (1 - alpha),
        blue: foreground.blueComponent * alpha +
            background.blueComponent * (1 - alpha),
        alpha: 1
    )
}

private func relativeLuminance(red: Double, green: Double, blue: Double) -> Double {
    0.2126 * linearized(red) + 0.7152 * linearized(green) +
        0.0722 * linearized(blue)
}

private func linearized(_ component: Double) -> Double {
    component <= 0.04045
        ? component / 12.92
        : pow((component + 0.055) / 1.055, 2.4)
}

private actor ScriptedReviewFeature: ReviewFeature {
    nonisolated let states: AsyncStream<ReviewFeatureState>
    private let state: ReviewFeatureState
    private var commands: [ReviewCommand] = []

    init() {
        let state = ReviewFeatureState.unavailable(
            selection: nil,
            reason: .noSession
        )
        self.state = state
        states = AsyncStream { continuation in
            continuation.yield(state)
            continuation.finish()
        }
    }

    var currentState: ReviewFeatureState { state }

    func send(_ command: ReviewCommand) { commands.append(command) }

    func recordedCommands() -> [ReviewCommand] { commands }

    func waitForCommandCount(_ expected: Int) async {
        while commands.count < expected { await Task.yield() }
    }
}
