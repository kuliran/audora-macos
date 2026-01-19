// ConvexService.swift
// Handles interactions with Convex backend

import Foundation
import ConvexMobile
import Clerk
import Combine

/// Authentication state for the app
enum AuthState: Equatable {
    case loading
    case authenticated(userId: String)
    case unauthenticated
}

/// Service for interacting with Convex backend
@MainActor
class ConvexService: ObservableObject {
    static let shared = ConvexService()

    private var client: ConvexClient?

    @Published var authState: AuthState = .loading
    @Published var errorMessage: String?

    private init() {
        // Initialize Convex client with deployment URL
        if let deploymentURL = getConvexDeploymentURL() {
            client = ConvexClient(deploymentUrl: deploymentURL)
            print("✅ Convex client initialized with URL: \(deploymentURL)")
        } else {
            print("⚠️ Convex deployment URL not configured")
        }
        // Keep authState as .loading until loginFromCache() completes
    }

    /// Gets the Convex deployment URL from environment or configuration
    private func getConvexDeploymentURL() -> String? {
        print("🔍 [ConvexService] Looking for CONVEX_DEPLOYMENT_URL...")

        // Check environment variable
        let envUrl = ProcessInfo.processInfo.environment["CONVEX_DEPLOYMENT_URL"]
        print("   - Environment: \(envUrl ?? "not found")")

        if let url = envUrl, !url.isEmpty {
            return url
        }

        // Check Info.plist
        let plistUrl = Bundle.main.object(forInfoDictionaryKey: "CONVEX_DEPLOYMENT_URL") as? String
        print("   - Info.plist: \(plistUrl ?? "not found")")

        if let url = plistUrl, !url.isEmpty, url != "$(CONVEX_DEPLOYMENT_URL)" {
            return url
        }

        print("   ⚠️ CONVEX_DEPLOYMENT_URL not found!")
        return nil
    }

    // MARK: - Authentication

    /// Attempts to restore session from Clerk on app launch
    func loginFromCache() async -> Bool {
        print("🔐 [ConvexService] loginFromCache() called")

        // First, ensure Clerk has loaded its saved session
        print("   - Calling Clerk.shared.load()...")
        do {
            try await Clerk.shared.load()
            print("   - Clerk.load() completed")
        } catch {
            print("   ⚠️ Clerk.load() failed: \(error)")
        }

        // Check for session
        print("   - Checking for session...")
        if let session = Clerk.shared.session {
            print("   ✅ Session found: \(session.id)")
            if let user = Clerk.shared.user {
                print("   ✅ User found: \(user.id)")
                authState = .authenticated(userId: user.id)
                return true
            }
        }

        print("   ⚠️ No session found")
        authState = .unauthenticated
        return false
    }

    /// Called after Clerk sign-in completes
    func onSignInComplete() {
        if let user = Clerk.shared.user {
            authState = .authenticated(userId: user.id)
        }
    }

    /// Signs out the current user
    func logout() async {
        do {
            try await Clerk.shared.signOut()
            authState = .unauthenticated
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Transcription

    // MARK: - Speechmatics Transcription

    /// Fetches a JWT for Speechmatics real-time transcription from the backend
    func getSpeechmaticsJWT() async throws -> String {
        guard let client = client else {
            throw ConvexError.clientNotInitialized
        }

        print("🔑 Fetching Speechmatics JWT from backend...")
        let jwt: String = try await client.action("speechmatics:generateJWT", with: [:])

        print("   ✅ JWT fetched successfully")
        return jwt
    }

    // MARK: - Conversation Management

    /// Creates a new conversation for Mac app recording
    /// Note: Will fail with authentication error until ConvexMobile SDK adds Clerk support
    func createConversation(title: String?, calendarEventId: String?) async throws -> String {
        guard let client = client else {
            throw ConvexError.clientNotInitialized
        }
        
        // Build args dictionary with ConvexEncodable types
        var args: [String: (any ConvexEncodable)?] = [:]
        if let title = title {
            args["title"] = title as (any ConvexEncodable)?
        }
        if let calendarEventId = calendarEventId {
            args["calendarEventId"] = calendarEventId as (any ConvexEncodable)?
        }
        
        print("📝 Creating conversation in backend...")
        let result: [String: String] = try await client.mutation(
            "conversations:createMacConversation",
            with: args
        )
        
        guard let conversationId = result["id"] else {
            throw ConvexError.netError("Failed to create conversation")
        }
        
        print("   ✅ Conversation created: \(conversationId)")
        return conversationId
    }

    /// Processes transcript with backend after recording completes
    /// Note: Will fail with authentication error until ConvexMobile SDK adds Clerk support
    func processRealtimeTranscript(
        conversationId: String,
        transcriptTurns: [[String: Any]],
        initiatorName: String?
    ) async throws -> [String: Any] {
        guard let client = client else {
            throw ConvexError.clientNotInitialized
        }
        
        // Convert transcriptTurns to ConvexEncodable format
        // Build array of dictionaries with ConvexEncodable values
        let encodedTurns: [[String: (any ConvexEncodable)?]] = transcriptTurns.map { turn in
            var encodedTurn: [String: (any ConvexEncodable)?] = [:]
            if let speaker = turn["speaker"] as? String {
                encodedTurn["speaker"] = speaker
            }
            if let text = turn["text"] as? String {
                encodedTurn["text"] = text
            }
            if let startTime = turn["startTime"] as? Double {
                encodedTurn["startTime"] = startTime
            } else if let startTime = turn["startTime"] as? Int {
                encodedTurn["startTime"] = Double(startTime)
            }
            if let endTime = turn["endTime"] as? Double {
                encodedTurn["endTime"] = endTime
            } else if let endTime = turn["endTime"] as? Int {
                encodedTurn["endTime"] = Double(endTime)
            }
            return encodedTurn
        }
        
        // Build args with proper ConvexEncodable types
        var args: [String: (any ConvexEncodable)?] = [:]
        args["conversationId"] = conversationId
        
        // Arrays conform to ConvexEncodable in ConvexMobile, but Swift's type system
        // doesn't recognize [[String: (any ConvexEncodable)?]] as (any ConvexEncodable)?
        // We use unsafe cast here because we know arrays are valid ConvexEncodable values
        // This is a limitation of Swift's type system with protocol existentials
        args["transcriptTurns"] = (encodedTurns as [Any]) as? (any ConvexEncodable) ?? encodedTurns as? (any ConvexEncodable)
        
        args["initiatorName"] = initiatorName ?? "Me"
        args["scannerName"] = "System"
        
        print("📤 Processing transcript with backend...")
        // Backend returns: { transcript: [...], S1_facts: [...], S2_facts: [...] }
        struct ProcessTranscriptResponse: Decodable {
            let transcript: [[String: String]]?
            let S1_facts: [String]?
            let S2_facts: [String]?
            
            enum CodingKeys: String, CodingKey {
                case transcript
                case S1_facts = "S1_facts"
                case S2_facts = "S2_facts"
            }
        }
        
        // Try without explicit type on args to see if Swift infers correct overload
        let response = try await client.action(
            "realtimeTranscription:processRealtimeTranscript",
            with: args
        ) as ProcessTranscriptResponse
        
        // Convert to [String: Any] dictionary
        var resultDict: [String: Any] = [:]
        if let transcript = response.transcript {
            resultDict["transcript"] = transcript
        }
        if let s1Facts = response.S1_facts {
            resultDict["S1_facts"] = s1Facts
        }
        if let s2Facts = response.S2_facts {
            resultDict["S2_facts"] = s2Facts
        }
        
        print("   ✅ Transcript processed successfully")
        return resultDict
    }

    /// Checks if Convex is properly configured
    func isConfigured() -> Bool {
        return client != nil
    }
    // MARK: - Notes Generation

    /// Generates notes from a transcript using the backend
    func generateNotes(transcript: String, templateId: String?) async -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let client = client else {
                        throw ConvexError.clientNotInitialized
                    }

                    // Call backend action named "notes:generate"
                    let args: [String: String] = [
                        "transcript": transcript,
                        "templateId": templateId ?? ""
                    ]

                    let result: String = try await client.action("notes:generate", with: args)

                    continuation.yield(result)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    // MARK: - Audio Upload

    /// Uploads an audio file to Convex storage
    func uploadAudioFile(audioFileURL: URL, meetingId: UUID) async throws -> String? {
        guard let client = client else { return nil }

        // 1. Get upload URL
        // Standard Convex action for getting upload URL
        let uploadUrl: String = try await client.action("storage:generateUploadUrl", with: [:])
        guard let url = URL(string: uploadUrl) else { return nil }

        // 2. Upload file
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("audio/m4a", forHTTPHeaderField: "Content-Type")

        let data = try Data(contentsOf: audioFileURL)
        let (responseData, response) = try await URLSession.shared.upload(for: request, from: data)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return nil
        }

        // 3. Parse response to get storageId
        struct UploadResponse: Decodable {
            let storageId: String
        }

        let uploadResponse = try JSONDecoder().decode(UploadResponse.self, from: responseData)
        return uploadResponse.storageId
    }
}

// MARK: - Supporting Types

struct TranscriptionSessionConfig {
    let wsUrl: String
    let authToken: String?
    let config: [String: Any]?
}

// MARK: - Convex Errors

enum ConvexError: LocalizedError {
    case clientNotInitialized
    case fileReadFailed
    case uploadFailed(String)
    case netError(String)
    case authenticationRequired

    var errorDescription: String? {
        switch self {
        case .clientNotInitialized:
            return "Backend not configured. Please set CONVEX_DEPLOYMENT_URL."
        case .fileReadFailed:
            return "Failed to read audio file."
        case .uploadFailed(let message):
            return "Upload failed: \(message)"
        case .netError(let message):
            return "Network error: \(message)"
        case .authenticationRequired:
            return "Please sign in to continue."
        }
    }
}
