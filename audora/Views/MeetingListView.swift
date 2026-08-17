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
    }

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
    }
}

private enum MeetingDetailPane: String, CaseIterable, Identifiable {
    case transcript = "Transcript"
    case preMeetingNotes = "Pre-meeting notes"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .transcript:
            return "text.bubble"
        case .preMeetingNotes:
            return "note.text"
        }
    }
}

struct MeetingDetailContentView: View {
    @StateObject private var viewModel: MeetingViewModel
    @StateObject private var recordingSessionManager = RecordingSessionManager.shared
    @StateObject private var audioManager = AudioManager.shared
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
                    AudioPlayerView(audioURL: audioURL)
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
                    if viewModel.meeting.collapsedTranscriptChunks.isEmpty {
                        Text("Transcript will appear here...")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .foregroundColor(.secondary)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(viewModel.meeting.collapsedTranscriptChunks) { chunk in
                                CollapsedTranscriptChunkView(chunk: chunk)
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
