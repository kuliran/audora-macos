import SwiftUI

struct AnalyticsView: View {
    let analytics: SpeechAnalytics
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                Text("Communication Analysis")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                // Score Cards
                HStack(spacing: 16) {
                    ScoreCard(
                        title: "Clarity",
                        score: analytics.scores.clarity,
                        subtitle: "Based on filler words"
                    )
                    
                    ScoreCard(
                        title: "Conciseness",
                        score: analytics.scores.conciseness,
                        subtitle: "Based on repetitions"
                    )
                    
                    ScoreCard(
                        title: "Confidence",
                        score: analytics.scores.confidence,
                        subtitle: "Based on sentence starters"
                    )
                }
                
                // Metrics Grid
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    // Filler Words Card
                    MetricCard(
                        icon: "bubble.left.fill",
                        title: "Filler Words",
                        color: .accentColor
                    ) {
                        VStack(alignment: .leading, spacing: 8) {
                            MetricRow(
                                label: "Total Count",
                                value: "\(analytics.fillerWords.count)"
                            )
                            MetricRow(
                                label: "Per Minute",
                                value: String(format: "%.1f", analytics.fillerWords.ratePerMinute)
                            )
                            
                            if !analytics.fillerWords.instances.isEmpty {
                                Divider()
                                    .padding(.vertical, 4)
                                
                                Text("Most Common:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                
                                FlowLayout(spacing: 6) {
                                    ForEach(Array(Set(analytics.fillerWords.instances.prefix(5).map { $0.word })), id: \.self) { word in
                                        Text(word)
                                            .font(.caption)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color.gray.opacity(0.2))
                                            .cornerRadius(4)
                                    }
                                }
                            }
                        }
                    }
                    
                    // Pacing Card
                    MetricCard(
                        icon: "timer",
                        title: "Pacing",
                        color: .green
                    ) {
                        VStack(alignment: .leading, spacing: 8) {
                            MetricRow(
                                label: "Words Per Minute",
                                value: "\(analytics.pacing.wordsPerMinute)"
                            )
                            
                            Divider()
                                .padding(.vertical, 4)
                            
                            Text(pacingFeedback)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    // Repeated Words
                    if !analytics.repetitions.repeatedWords.isEmpty {
                        MetricCard(
                            icon: "repeat",
                            title: "Repeated Words",
                            color: .orange
                        ) {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(analytics.repetitions.repeatedWords.prefix(5)) { word in
                                    MetricRow(
                                        label: word.word.capitalized,
                                        value: "\(word.count)x"
                                    )
                                }
                            }
                        }
                    }
                    
                    // Weak Sentence Starters
                    if !analytics.sentenceStarters.weak.isEmpty {
                        MetricCard(
                            icon: "exclamationmark.triangle.fill",
                            title: "Weak Sentence Starters",
                            color: .yellow
                        ) {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(analytics.sentenceStarters.weak.prefix(5)) { starter in
                                    MetricRow(
                                        label: "\"\(starter.word)\"",
                                        value: "\(starter.count)x"
                                    )
                                }
                                
                                Divider()
                                    .padding(.vertical, 4)
                                
                                Text("Try to vary your sentence starters for better flow")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                
                // Weak Words with Suggestions
                if !analytics.weakWords.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Improvement Suggestions")
                            .font(.headline)
                        
                        ForEach(analytics.weakWords.prefix(3)) { weakWord in
                            WeakWordCard(weakWord: weakWord)
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .padding()
        }
    }
    
    private var pacingFeedback: String {
        let wpm = analytics.pacing.wordsPerMinute
        if wpm < 100 {
            return "Speaking slowly - good for clarity"
        } else if wpm > 160 {
            return "Speaking quickly - consider slowing down"
        } else {
            return "Good speaking pace"
        }
    }
}

// MARK: - Score Card Component

struct ScoreCard: View {
    let title: String
    let score: Int
    let subtitle: String
    
    private var scoreColor: Color {
        if score >= 80 { return .green }
        if score >= 60 { return .yellow }
        return .red
    }
    
    private var backgroundColor: Color {
        if score >= 80 { return Color.green.opacity(0.1) }
        if score >= 60 { return Color.yellow.opacity(0.1) }
        return Color.red.opacity(0.1)
    }
    
    private var trendIcon: String {
        if score >= 80 { return "arrow.up.right" }
        if score >= 60 { return "minus" }
        return "arrow.down.right"
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Image(systemName: trendIcon)
                    .font(.caption)
                    .foregroundColor(scoreColor)
            }
            
            Text("\(score)")
                .font(.system(size: 36, weight: .bold))
                .foregroundColor(scoreColor)
            
            Text(subtitle)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundColor)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(scoreColor.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - Metric Card Component

struct MetricCard<Content: View>: View {
    let icon: String
    let title: String
    let color: Color
    let content: () -> Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundColor(color)
                
                Text(title)
                    .font(.headline)
            }
            
            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - Metric Row Component

struct MetricRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            
            Spacer()
            
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
        }
    }
}

// MARK: - Weak Word Card Component

struct WeakWordCard: View {
    let weakWord: WeakWordInstance
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                    .font(.caption)
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Weak word:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("\"\(weakWord.word)\"")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                }
            }
            
            Text("\"\(weakWord.sentence)\"")
                .font(.caption)
                .italic()
                .foregroundColor(.secondary)
            
            if let suggestion = weakWord.suggestion {
                Divider()
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Suggested:")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    Text("\"\(suggestion)\"")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                        .fontWeight(.medium)
                }
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }
}

// MARK: - Flow Layout for Tags

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrangeViews(proposal: proposal, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height + spacing } - spacing
        return CGSize(width: proposal.width ?? 0, height: height)
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrangeViews(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        
        for row in rows {
            var x = bounds.minX
            for (index, size) in row.sizes {
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }
    
    private func arrangeViews(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var currentRow: Row = Row(sizes: [], height: 0)
        var x: CGFloat = 0
        let maxWidth = proposal.width ?? .infinity
        
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            
            if x + size.width > maxWidth && !currentRow.sizes.isEmpty {
                rows.append(currentRow)
                currentRow = Row(sizes: [], height: 0)
                x = 0
            }
            
            currentRow.sizes.append((index, size))
            currentRow.height = max(currentRow.height, size.height)
            x += size.width + spacing
        }
        
        if !currentRow.sizes.isEmpty {
            rows.append(currentRow)
        }
        
        return rows
    }
    
    struct Row {
        var sizes: [(Int, CGSize)]
        var height: CGFloat
    }
}

// MARK: - Preview

#Preview {
    AnalyticsView(
        analytics: SpeechAnalytics(
            fillerWords: FillerWords(
                count: 15,
                ratePerMinute: 2.5,
                instances: [
                    FillerWordInstance(word: "um", position: 5),
                    FillerWordInstance(word: "like", position: 12),
                    FillerWordInstance(word: "you know", position: 20)
                ]
            ),
            pacing: PacingMetrics(
                wordsPerMinute: 145,
                averagePauseDuration: nil,
                longestPause: nil
            ),
            repetitions: Repetitions(
                repeatedWords: [
                    RepeatedWord(word: "really", count: 5),
                    RepeatedWord(word: "think", count: 4)
                ],
                repeatedPhrases: [
                    RepeatedPhrase(phrase: "i think", count: 3)
                ]
            ),
            sentenceStarters: SentenceStarters(
                total: 20,
                weak: [
                    WeakStarter(word: "so", count: 3),
                    WeakStarter(word: "well", count: 2)
                ]
            ),
            weakWords: [
                WeakWordInstance(
                    word: "just",
                    sentence: "I just wanted to say that this is really important.",
                    suggestion: "I wanted to say that this is important."
                )
            ],
            scores: AnalyticsScores(
                clarity: 75,
                conciseness: 68,
                confidence: 82
            )
        )
    )
    .frame(width: 800, height: 600)
}
