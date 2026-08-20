import SwiftUI

struct MeetingListView: View {
    @StateObject private var viewModel = MeetingListViewModel()
    @ObservedObject var settingsViewModel: SettingsViewModel
    @StateObject private var recordingSessionManager = RecordingSessionManager.shared
    @State private var selectedMeeting: Meeting?
    @State private var navigationPath = NavigationPath()
    @Binding var triggerNewRecording: Bool
    @Binding var triggerOpenSettings: Bool
    @Environment(\.openSettings) private var openSettings
    #if AUDORA_LOCAL_SETUP
    @ObservedObject private var localDeepLinkCoordinator = LocalConversationDeepLinkCoordinator.shared
    #endif

    // Default initializer for use without bindings
    init(settingsViewModel: SettingsViewModel,
         triggerNewRecording: Binding<Bool> = .constant(false),
         triggerOpenSettings: Binding<Bool> = .constant(false)) {
        self.settingsViewModel = settingsViewModel
        self._triggerNewRecording = triggerNewRecording
        self._triggerOpenSettings = triggerOpenSettings
    }

    var body: some View {
        NavigationSplitView {
            // Sidebar with meetings list
            sidebarContent
        } detail: {
            // Detail view with meeting content
            detailContent
        }
        .navigationSplitViewStyle(.balanced)
        .overlay {
            if viewModel.isLoading {
                ProgressView("Loading meetings...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.clear)
            }
        }
        .onChange(of: triggerNewRecording) { _, _ in
            // Create new recording when triggered from menu bar
            let newMeeting = viewModel.createNewMeeting()
            selectedMeeting = newMeeting
        }
        .onChange(of: triggerOpenSettings) { _, _ in
            // Open settings window when triggered from menu bar
            openSettings()
        }
        #if AUDORA_LOCAL_SETUP
        .onAppear {
            selectDeepLinkedMeeting()
        }
        .onChange(of: localDeepLinkCoordinator.meetingToOpen?.id) { _, _ in
            selectDeepLinkedMeeting()
        }
        #endif
    }

    #if AUDORA_LOCAL_SETUP
    private func selectDeepLinkedMeeting() {
        if let meeting = localDeepLinkCoordinator.meetingToOpen {
            selectedMeeting = meeting
            localDeepLinkCoordinator.acknowledgeMeetingSelection(meeting.id)
        }
    }
    #endif

    private var sidebarContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search meetings...", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
            }
            .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))

            Divider()

            Spacer().frame(height: 12) // Add space before list content

            List(selection: $selectedMeeting) {
                // Upcoming events section (calendar events)
                if !viewModel.upcomingEvents.isEmpty {
                    Section(header: Text("Upcoming Meetings").font(.caption).foregroundColor(.secondary)) {
                        ForEach(viewModel.upcomingEvents, id: \.eventIdentifier) { event in
                            Button {
                                let newMeeting = viewModel.createMeeting(from: event)
                                selectedMeeting = newMeeting
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(event.title)
                                        .font(.headline)
                                        .lineLimit(1)

                                    HStack {
                                        Text(event.startDate, style: .time)
                                        Text("-")
                                        Text(event.endDate, style: .time)
                                    }
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Only render meeting sections when there are meetings or loading state
                ForEach(groupedMeetings, id: \.day) { dayGroup in
                    Section {
                        ForEach(dayGroup.meetings, id: \.id) { meeting in
                            MeetingRowView(meeting: meeting)
                                .tag(meeting)
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                let meetingToDelete = dayGroup.meetings[index]
                                viewModel.deleteMeeting(meetingToDelete)
                                // Clear selection if the deleted meeting was selected
                                if selectedMeeting?.id == meetingToDelete.id {
                                    selectedMeeting = nil
                                }
                            }
                        }
                    } header: {
                        Text(dayGroup.day)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                    }
                }
            }
            .overlay {
                if viewModel.filteredMeetings.isEmpty && viewModel.upcomingEvents.isEmpty && !viewModel.isLoading {
                    ContentUnavailableView(
                        viewModel.searchText.isEmpty ? "No Meetings Yet" : "No Results",
                        systemImage: viewModel.searchText.isEmpty ? "mic.slash" : "magnifyingglass",
                        description: Text(viewModel.searchText.isEmpty ? "Start a new meeting to begin transcribing" : "Try a different search term")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("Meetings")
    }

    private var detailContent: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if let selectedMeeting = selectedMeeting {
                    MeetingDetailContentView(meeting: selectedMeeting, onDelete: {
                        // When a meeting is deleted from the detail view, clear the selection
                        self.selectedMeeting = nil
                    })
                    .id(selectedMeeting.id) // Force recreation when selection changes
                } else {
                    ContentUnavailableView(
                        "Select a Meeting",
                        systemImage: "sidebar.leading",
                        description: Text("Choose a meeting from the sidebar to view its details")
                    )
                }
            }
            .navigationTitle("")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Spacer()



                    Button {
                        openSettings()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .help("Settings")

                    Button {
                        let newMeeting = viewModel.createNewMeeting()
                        selectedMeeting = newMeeting
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(recordingSessionManager.isRecording)
                    .help(recordingSessionManager.isRecording ? "Cannot create new meeting while recording is active" : "New Meeting")
                }
            }
        }
    }

    private var groupedMeetings: [DayGroup] {
        let calendar = Calendar.current
        let now = Date()

        let grouped = Dictionary(grouping: viewModel.filteredMeetings) { meeting in
            calendar.startOfDay(for: meeting.date)
        }

        return grouped.map { (date, meetings) in
            let dayString: String

            if calendar.isDateInToday(date) {
                dayString = "Today"
            } else if calendar.isDateInYesterday(date) {
                dayString = "Yesterday"
            } else if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
                dayString = date.formatted(.dateTime.weekday(.wide))
            } else {
                dayString = date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
            }

            return DayGroup(day: dayString, date: date, meetings: meetings.sorted { $0.date > $1.date })
        }.sorted { $0.date > $1.date }
    }
}

struct DayGroup {
    let day: String
    let date: Date
    let meetings: [Meeting]
}

struct MeetingRowView: View {
    let meeting: Meeting
    @StateObject private var recordingSessionManager = RecordingSessionManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Title or default
            HStack(spacing: 4) {
                if recordingSessionManager.isRecordingMeeting(meeting.id) {
                    Image(systemName: "record.circle")
                        .foregroundColor(.red)
                        .font(.headline)
                }
                Text(meeting.title.isEmpty ? "Untitled meeting" : meeting.title)
                    .font(.headline)
                    .lineLimit(1)
            }
            // Date
            HStack {
                Text(meeting.date, style: .time)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Meeting Detail Content View
// This is a refactored version of MeetingDetailView that works within the sidebar layout

struct CollapsedTranscriptChunkView: View {
    let chunk: CollapsedTranscriptChunk
    let onSeek: (TimeInterval) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // Source indicator
            HStack(spacing: 4) {
                Image(systemName: chunk.source.icon)
                    .font(.caption)
                    .foregroundColor(chunk.source == .mic ? .accentColor : .orange)

                Text(chunk.source.displayName)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(chunk.source == .mic ? .accentColor : .orange)
            }
            .frame(width: 50, alignment: .leading)

            Text(chunk.combinedText)
                .font(.body)
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            if let startTime = chunk.startTime {
                onSeek(startTime)
            }
        }
        .help(chunk.startTime == nil ? "Timestamp unavailable" : "Jump to this transcript in the recording")
    }
}

private enum MeetingDetailPane: String, CaseIterable, Identifiable {
    case transcript = "Transcript"
    case voiceCadence = "Voice & cadence"
    case preMeetingNotes = "Pre-meeting notes"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .transcript:
            return "text.bubble"
        case .voiceCadence:
            return "waveform.path.ecg"
        case .preMeetingNotes:
            return "note.text"
        }
    }
}

struct MeetingDetailContentView: View {
    @StateObject private var viewModel: MeetingViewModel
    @StateObject private var recordingSessionManager = RecordingSessionManager.shared
    @StateObject private var audioManager = AudioManager.shared
    @StateObject private var audioPlayerManager = AudioPlayerManager()
    @State private var showDeleteAlert = false
    @State private var selectedDetailPane: MeetingDetailPane = .transcript
    let onDelete: () -> Void

    init(meeting: Meeting, onDelete: @escaping () -> Void) {
        self._viewModel = StateObject(wrappedValue: MeetingViewModel(meeting: meeting))
        self.onDelete = onDelete
    }

    // Computed property to determine if recording button should be disabled
    private var cannotStartRecording: Bool {
        recordingSessionManager.isBusy(withOtherMeeting: viewModel.meeting.id)
    }

    var body: some View {
        middleColumn
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
            Button("OK") {
                viewModel.errorMessage = nil
            }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .alert("Delete Meeting", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) {
                viewModel.deleteMeeting()
                onDelete()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Are you sure you want to delete this meeting? This action cannot be undone.")
        }
        .onDisappear {
            // Do not let a model download finish later and start invisible capture
            // after the user has navigated away from this meeting.
            if recordingSessionManager.isPreparingMeeting(viewModel.meeting.id) {
                viewModel.cancelPendingStart()
            }
            // Auto-delete empty meetings when leaving, otherwise save
            viewModel.deleteIfEmpty()
        }
    }

    // MARK: - Middle Column

    private var middleColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header with title and controls
            headerSection

            // Audio Player (fixed at top)
            if let audioFileURLString = viewModel.meeting.audioFileURL {
                let audioURL = URL(fileURLWithPath: audioFileURLString)
                // Verify file exists before showing player
                if FileManager.default.fileExists(atPath: audioURL.path) {
                    AudioPlayerView(
                        audioURL: audioURL,
                        playerManager: audioPlayerManager
                    )
                } else {
                    // File path exists in meeting but file not found - might be deleted or path is wrong
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                        Text("Audio file not found")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("Path: \(audioFileURLString)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(12)
                }
            }

            detailPaneToggle

            switch selectedDetailPane {
            case .transcript:
                transcriptSection
            case .voiceCadence:
                voiceCadenceSection
            case .preMeetingNotes:
                preMeetingNotesSection
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Title and Menu
            HStack {
                TextField("Meeting Title", text: $viewModel.meeting.title)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .textFieldStyle(.plain)

                Spacer()

                // Ellipsis menu
                Menu {
                    Button("Delete Meeting", role: .destructive) {
                        showDeleteAlert = true
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 12, height: 12)
                        .foregroundColor(.secondary)
                }
                .labelStyle(.iconOnly)
                .menuIndicator(.hidden)
                .menuStyle(BorderlessButtonMenuStyle())
                .frame(width: 20, height: 20)
            }

            // Recording controls
            HStack(spacing: 8) {
                Button(action: {
                    viewModel.toggleRecording()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: viewModel.isRecording ? "stop.circle.fill" : "record.circle")
                            .foregroundColor(viewModel.isRecording ? .red : .accentColor)
                        Text(viewModel.recordingButtonText)
                    }
                    .frame(minWidth: 110, minHeight: 36)
                    .background(viewModel.isRecording ? Color.red.opacity(0.1) : Color.accentColor.opacity(0.1))
                    .cornerRadius(8)
                    .overlay(
                        Group {
                            if viewModel.shouldAnimateTranscribeButton {
                                ShimmerOverlay(color: .accentColor)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    )
                }
                .buttonStyle(.plain)
                .disabled(
                    cannotStartRecording
                    || viewModel.isValidatingKey
                    || recordingSessionManager.isStoppingMeeting(viewModel.meeting.id)
                )
                .help(cannotStartRecording ? "Another meeting is currently being recorded" : "Start or stop recording for this meeting")

                if viewModel.meeting.convexConversationId != nil {
                    Button(action: {
                        viewModel.openConversationInWeb()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.right")
                                .foregroundColor(.accentColor)
                            Text("Web")
                        }
                        .frame(minWidth: 80, minHeight: 36)
                        .padding(.horizontal, 8)
                        .background(Color.accentColor.opacity(0.1))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.conversationURL == nil)
                    .help("Open conversation in Audora web")
                }

                Spacer()
            }

            if viewModel.isStartingRecording {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(audioManager.transcriptionStatus)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if let progress = audioManager.parakeetDownloadProgress {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .accessibilityLabel("Parakeet model download")
                    }
                }
            }
        }
    }



    private var detailPaneToggle: some View {
        Picker("Meeting detail", selection: $selectedDetailPane) {
            ForEach(MeetingDetailPane.allCases) { pane in
                Label(pane.rawValue, systemImage: pane.systemImage)
                    .tag(pane)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Transcript Header
            HStack {
                Text("Transcript")
                    .font(.headline)
                    .foregroundColor(.secondary)

                Spacer()
            }

            // Transcript Content
            VStack(alignment: .leading, spacing: 8) {
                ScrollView {
                    if viewModel.meeting.timestampedTranscriptChunks.isEmpty {
                        Text("Transcript will appear here...")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .foregroundColor(.secondary)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(viewModel.meeting.timestampedTranscriptChunks) { chunk in
                                CollapsedTranscriptChunkView(chunk: chunk) { startTime in
                                    audioPlayerManager.seek(toTime: startTime)
                                }
                            }
                        }
                        .padding()
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .background(Color.gray.opacity(0.05))
            .cornerRadius(8)
        }
    }

    private var voiceCadenceSection: some View {
        Group {
            if let metrics = viewModel.meeting.localAcousticMetrics,
               !metrics.sources.isEmpty {
                VoiceCadenceMetricsView(metrics: metrics) { startTime in
                    audioPlayerManager.seek(toTime: startTime)
                }
            } else {
                ContentUnavailableView(
                    "No voice metrics yet",
                    systemImage: "waveform.path.ecg",
                    description: Text("Record with Local Parakeet to calculate voice and cadence locally.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var preMeetingNotesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Pre-meeting notes")
                    .font(.headline)
                    .foregroundColor(.secondary)

                Spacer()

                Text("Saved locally")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $viewModel.meeting.userNotes)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if viewModel.meeting.userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Jot down agenda items, questions, names, reminders, or anything you want top of mind before the call.")
                        .foregroundColor(.secondary)
                        .padding(EdgeInsets(top: 16, leading: 14, bottom: 0, trailing: 14))
                        .allowsHitTesting(false)
                }
            }
            .frame(maxHeight: .infinity)
            .background(Color.gray.opacity(0.05))
            .cornerRadius(8)
        }
    }
}

private struct VoiceCadenceMetricsView: View {
    let metrics: LocalAcousticMetrics
    let onSeek: (TimeInterval) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Text("Calculated on this Mac. No waveform, pitch contour, voice embedding, or emotion inference is stored. Absolute pitch is excluded from AI coaching context.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(metrics.sources, id: \.source) { source in
                    sourceCard(source)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func sourceCard(_ source: LocalAcousticSourceMetrics) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label(
                    source.source == .mic ? "Microphone" : "System audio",
                    systemImage: source.source == .mic ? "mic.fill" : "speaker.wave.2.fill"
                )
                .font(.headline)

                if source.scope == .mixedChannel {
                    Text("Mixed channel")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.orange.opacity(0.12), in: Capsule())
                        .help("System audio may contain multiple people; these measurements are not attributed to one speaker.")
                }

                Spacer()
            }

            if let overall = source.overall {
                metricGrid(overall, includeRelativeVolume: false)

                if !overall.qualityFlags.isEmpty {
                    qualityFlags(overall.qualityFlags)
                }
            }

            if !source.phrases.isEmpty {
                Divider()
                Text("Phrase windows")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                LazyVStack(spacing: 5) {
                    ForEach(source.phrases.indices, id: \.self) { index in
                        let phrase = source.phrases[index]
                        Button {
                            onSeek(phrase.startTime)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(systemName: "play.circle")
                                        .foregroundStyle(.tint)
                                    Text(Self.timestamp(phrase.startTime))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    Text(phrase.text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Phrase \(index + 1)")
                                        .lineLimit(1)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                }

                                Text(Self.phraseSummary(phrase.metrics))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .padding(.leading, 28)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(Color.gray.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                        .help("Jump to \(Self.timestamp(phrase.startTime)) in the recording")
                    }
                }
            }
        }
        .padding(14)
        .background(Color.gray.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private func metricGrid(
        _ metrics: LocalAcousticWindowMetrics,
        includeRelativeVolume: Bool
    ) -> some View {
        let values = Self.metricValues(metrics, includeRelativeVolume: includeRelativeVolume)
        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 120), spacing: 8)],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(values) { value in
                VStack(alignment: .leading, spacing: 2) {
                    Text(value.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(value.value)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func qualityFlags(_ flags: [AcousticQualityFlag]) -> some View {
        HStack(spacing: 6) {
            ForEach(flags, id: \.self) { flag in
                Text(Self.readable(flag.rawValue))
                    .font(.caption2)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.1), in: Capsule())
            }
        }
    }

    private struct MetricValue: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    private static func metricValues(
        _ metrics: LocalAcousticWindowMetrics,
        includeRelativeVolume: Bool
    ) -> [MetricValue] {
        var values: [MetricValue] = []
        if let value = metrics.paceWpm {
            values.append(MetricValue(label: "Pace", value: "\(Int(value.rounded())) WPM"))
        }
        if let value = metrics.articulationRateWpm {
            values.append(MetricValue(label: "Articulation", value: "\(Int(value.rounded())) WPM"))
        }
        if let value = metrics.medianPitchHz {
            values.append(MetricValue(label: "Median pitch", value: "\(Int(value.rounded())) Hz"))
        }
        if let value = metrics.pitchRangeSemitones {
            values.append(MetricValue(label: "Pitch range", value: String(format: "%.1f st", value)))
        }
        if metrics.pitchDirection != .unavailable {
            values.append(MetricValue(label: "Pitch direction", value: readable(metrics.pitchDirection.rawValue)))
        }
        if includeRelativeVolume, let value = metrics.relativeVolumeDb {
            values.append(MetricValue(label: "Relative volume", value: String(format: "%+.1f dB", value)))
        }
        if let value = metrics.volumeVariabilityDb {
            values.append(MetricValue(label: "Volume variation", value: String(format: "%.1f dB", value)))
        }
        if let value = metrics.steadiness {
            values.append(MetricValue(label: "Cadence steadiness", value: "\(Int((value * 100).rounded()))%"))
        }
        values.append(MetricValue(label: "Voiced coverage", value: "\(Int((metrics.voicedRatio * 100).rounded()))%"))
        return values
    }

    private static func phraseSummary(_ metrics: LocalAcousticWindowMetrics) -> String {
        metricValues(metrics, includeRelativeVolume: true)
            .filter { $0.label != "Median pitch" }
            .prefix(5)
            .map { "\($0.label): \($0.value)" }
            .joined(separator: " · ")
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let safe = max(0, seconds)
        return String(format: "%d:%04.1f", Int(safe) / 60, safe.truncatingRemainder(dividingBy: 60))
    }

    private static func readable(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Shimmer Overlay
struct ShimmerOverlay: View {
    @State private var animate: Bool = false
    let color: Color

    init(color: Color = .green) {
        self.color = color
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [Color.clear, color.opacity(0.1), Color.clear]),
                        startPoint: UnitPoint(x: animate ? 2.5 : -1, y: 0.5),
                        endPoint: UnitPoint(x: animate ? 3.5 : 0, y: 0.5)
                    )
                )
                .frame(width: width, height: height)
                .onAppear {
                    animate = true
                }
                .animation(
                    Animation.linear(duration: 1.5).repeatForever(autoreverses: false),
                    value: animate
                )
        }
        .allowsHitTesting(false)
    }
}

#Preview {
    MeetingListView(settingsViewModel: SettingsViewModel())
}
