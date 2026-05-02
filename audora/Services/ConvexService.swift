// ConvexService.swift
// Handles interactions with Convex backend

import Foundation
import ConvexMobile
import ConvexClerk
import Clerk
import Combine

private struct RawConvexJSON: ConvexEncodable {
    let json: String

    func convexEncode() throws -> String {
        json
    }
}

/// Authentication state for the app
enum AuthState: Equatable {
    case loading
    case authenticated(userId: String)
    case unauthenticated
}

/// Service for interacting with Convex backend with Clerk authentication
/// Manages conversations, transcription, and user session state
@MainActor
class ConvexService: ObservableObject {
    static let shared = ConvexService()

    private var client: ConvexClientWithAuth<ClerkCredentials>?
    private var hasAuthenticatedConvexClient = false
    private var hasEnsuredUserRecord = false

    @Published var authState: AuthState = .loading
    @Published var errorMessage: String?

    private init() {
        // Initialize Convex client with Clerk authentication
        if let deploymentURL = getConvexDeploymentURL() {
            // Create Clerk auth provider using ConvexClerk package
            // jwtTemplate must match the template name in Clerk Dashboard (default: "convex")
            let authProvider = ClerkAuthProvider(jwtTemplate: "convex")

            // Initialize authenticated client
            client = ConvexClientWithAuth(
                deploymentUrl: deploymentURL,
                authProvider: authProvider
            )
            print("✅ Convex client initialized with Clerk authentication")
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

    /// Gets the Clerk publishable key from environment or configuration
    private func getClerkPublishableKey() -> String? {
        // Check environment variable
        let envKey = ProcessInfo.processInfo.environment["CLERK_PUBLISHABLE_KEY"]
        if let key = envKey, !key.isEmpty {
            return key
        }

        // Check Info.plist
        let plistKey = Bundle.main.object(forInfoDictionaryKey: "CLERK_PUBLISHABLE_KEY") as? String
        if let key = plistKey, !key.isEmpty, key != "$(CLERK_PUBLISHABLE_KEY)" {
            return key
        }

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

                do {
                    try await prepareAuthenticatedBackend()
                } catch {
                    print("❌ Failed to prepare Convex backend: \(error)")
                    errorMessage = error.localizedDescription
                }

                authState = .authenticated(userId: user.id)
                return true
            }
        }

        print("   ⚠️ No session found")
        authState = .unauthenticated
        return false
    }

    /// Called after Clerk sign-in completes
    func onSignInComplete() async {
        if let user = Clerk.shared.user {
            do {
                try await prepareAuthenticatedBackend()
            } catch {
                print("❌ Failed to prepare Convex backend after sign-in: \(error)")
                errorMessage = error.localizedDescription
            }

            authState = .authenticated(userId: user.id)
        }
    }

    /// Ensures authenticated backend calls can rely on Convex auth and a user row.
    private func prepareAuthenticatedBackend() async throws {
        guard let client = client else {
            throw ConvexError.clientNotInitialized
        }

        if !hasAuthenticatedConvexClient {
            switch await client.login() {
            case .success(_):
                hasAuthenticatedConvexClient = true
                print("✅ Convex client authenticated with Clerk")
            case .failure(let error):
                throw error
            }
        }

        if !hasEnsuredUserRecord {
            try await ensureUserExists()
            hasEnsuredUserRecord = true
        }
    }

    private func ensureAuthenticatedBackendReady() async throws {
        guard case .authenticated = authState else {
            print("❌ Backend call requires authentication (authState: \(authState))")
            throw ConvexError.authenticationRequired
        }

        try await prepareAuthenticatedBackend()
    }

    /// Ensures the user record exists in Convex database
    /// CRITICAL: Must be called after authentication before creating conversations
    private func ensureUserExists() async throws {
        guard let client = client else {
            throw ConvexError.clientNotInitialized
        }

        struct UserResponse: Decodable {
            let _id: String
        }

        let _: UserResponse? = try await client.mutation(
            "users:upsertUser",
            with: [:]
        )
        print("✅ User record created/updated")
    }

    /// Signs out the current user
    func logout() async {
        do {
            // Logout from Convex client first
            if let client = client {
                await client.logout()
            }
            hasAuthenticatedConvexClient = false
            hasEnsuredUserRecord = false

            // Then logout from Clerk
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
        try await ensureAuthenticatedBackendReady()

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
    /// - Parameters:
    ///   - title: Optional conversation title (typically meeting name)
    ///   - calendarEventId: Optional calendar event ID for linking
    /// - Returns: The conversation ID from Convex database
    func createConversation(title: String?, calendarEventId: String?) async throws -> String {
        try await ensureAuthenticatedBackendReady()

        guard let client = client else {
            print("❌ Cannot create conversation: Client not initialized")
            throw ConvexError.clientNotInitialized
        }

        var args: [String: (any ConvexEncodable)?] = [:]
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            args["location"] = title
        }
        args["participantMode"] = "anonymous"
        args["reusePending"] = false

        print("📝 Creating conversation: \(title ?? "Untitled")")

        do {
            struct CreateConversationResponse: Decodable {
                let id: String
                let inviteCode: String
            }

            let result: CreateConversationResponse? = try await client.mutation(
                "conversations:create",
                with: args
            )

            if let id = result?.id {
                print("   ✅ Conversation created: \(id)")
                return id
            } else {
                 print("⚠️ Conversation creation returned null response")
                 throw ConvexError.netError("Backend returned null conversation ID")
            }
        } catch {
            print("❌ Conversation creation failed: \(error)")
            throw error
        }
    }

    /// Saves a finished Mac transcript to an existing backend conversation without running analysis.
    func saveTranscriptData(
        conversationId: String,
        transcriptTurns: [[String: Any]],
        summary: String
    ) async throws {
        try await ensureAuthenticatedBackendReady()

        guard let client = client else {
            throw ConvexError.clientNotInitialized
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: transcriptTurns, options: []),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            print("❌ Failed to serialize transcript to JSON")
            throw ConvexError.netError("Failed to serialize transcript")
        }

        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        var args: [String: (any ConvexEncodable)?] = [:]
        args["conversationId"] = conversationId
        args["transcript"] = RawConvexJSON(json: jsonString)
        args["S1_facts"] = RawConvexJSON(json: "[]")
        args["S2_facts"] = RawConvexJSON(json: "[]")
        args["summary"] = trimmedSummary.isEmpty ? "Mac recording" : trimmedSummary

        print("📤 Saving transcript (\(transcriptTurns.count) turns)")
        let _: String? = try await client.mutation(
            "conversations:saveTranscriptData",
            with: args
        )

        print("   ✅ Transcript saved successfully")
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
