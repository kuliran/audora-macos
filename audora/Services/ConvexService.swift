// ConvexService.swift
// Handles interactions with Convex backend

import Foundation
import ConvexMobile
#if !AUDORA_LOCAL_SETUP
import ConvexClerk
import Clerk
#endif
import Combine

private struct RawConvexJSON: ConvexEncodable {
    let json: String

    func convexEncode() throws -> String {
        json
    }
}

private func isAllowedLocalConvexUploadURL(_ url: URL?) -> Bool {
    guard let url,
          url.scheme == "http",
          url.host == "127.0.0.1",
          url.port == 3210,
          url.path == "/api/storage/upload",
          url.user == nil,
          url.password == nil,
          url.fragment == nil,
          let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
          queryItems.count == 1,
          queryItems[0].name == "token",
          !(queryItems[0].value ?? "").isEmpty else {
        return false
    }
    return true
}

private final class LoopbackUploadSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(isAllowedLocalConvexUploadURL(request.url) ? request : nil)
    }
}

/// Authentication state for the app
enum AuthState: Equatable {
    case loading
    case authenticated(userId: String)
    case unauthenticated
}

#if AUDORA_LOCAL_SETUP
struct LocalConversationReference: Equatable {
    enum Status: String, Decodable {
        case pending
        case active
        case ended
    }

    let id: String
    let status: Status
    let location: String?
}

private struct LocalConversationAccessResponse: Decodable {
    let id: String
    let status: LocalConversationReference.Status
    let location: String?

    private enum CodingKeys: String, CodingKey {
        case id = "_id"
        case status
        case location
    }
}
#endif

/// Service for interacting with Convex using either local JWT or Clerk authentication.
/// Manages conversations, transcription, and user session state
@MainActor
class ConvexService: ObservableObject {
    static let shared = ConvexService()

    #if AUDORA_LOCAL_SETUP
    private var client: ConvexClientWithAuth<LocalCredentials>?
    #else
    private var client: ConvexClientWithAuth<ClerkCredentials>?
    #endif
    private var hasAuthenticatedConvexClient = false
    private var hasEnsuredUserRecord = false
    private var loginTask: Task<Bool, Never>?
    #if AUDORA_LOCAL_SETUP
    private var localCredentialsExpiresAt: Date?
    #endif

    @Published var authState: AuthState = .loading
    @Published var errorMessage: String?

    private init() {
        if let deploymentURL = getConvexDeploymentURL() {
            #if AUDORA_LOCAL_SETUP
            client = ConvexClientWithAuth(
                deploymentUrl: deploymentURL,
                authProvider: LocalAuthProvider()
            )
            print("✅ Convex client initialized with loopback JWT authentication")
            #else
            // Create Clerk auth provider using ConvexClerk package
            // jwtTemplate must match the template name in Clerk Dashboard (default: "convex")
            let authProvider = ClerkAuthProvider(jwtTemplate: "convex")

            // Initialize authenticated client
            client = ConvexClientWithAuth(
                deploymentUrl: deploymentURL,
                authProvider: authProvider
            )
            print("✅ Convex client initialized with Clerk authentication")
            #endif
        } else {
            print("⚠️ Convex deployment URL not configured")
        }
        // Keep authState as .loading until loginFromCache() completes
    }

    /// Gets the Convex deployment URL from environment or configuration
    private func getConvexDeploymentURL() -> String? {
        #if AUDORA_LOCAL_SETUP
        let environmentValue = ProcessInfo.processInfo.environment["CONVEX_DEPLOYMENT_URL"]
        let plistValue = Bundle.main.object(forInfoDictionaryKey: "CONVEX_DEPLOYMENT_URL") as? String
        let candidate = [environmentValue, plistValue]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0 != "$(CONVEX_DEPLOYMENT_URL)" }
            ?? AppMode.localConvexURL

        guard let url = URL(string: candidate),
              url.scheme == "http",
              url.host == "127.0.0.1",
              url.port == 3210,
              url.path.isEmpty || url.path == "/" else {
            print("❌ Local setup rejected non-loopback Convex URL: \(candidate)")
            return nil
        }
        return candidate
        #else
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
        #endif
    }

    #if !AUDORA_LOCAL_SETUP
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
    #endif

    // MARK: - Authentication

    /// Restores either the loopback JWT session or the cached Clerk session.
    func loginFromCache() async -> Bool {
        if let loginTask {
            return await loginTask.value
        }

        let task = Task { [weak self] in
            guard let self else { return false }
            return await self.performLoginFromCache()
        }
        loginTask = task
        let result = await task.value
        loginTask = nil
        return result
    }

    private func performLoginFromCache() async -> Bool {
        print("🔐 [ConvexService] loginFromCache() called")

        #if AUDORA_LOCAL_SETUP
        // Retry is a fresh attempt. Clear both the old error and all cached
        // authentication bookkeeping before contacting the loopback issuer.
        authState = .loading
        errorMessage = nil
        resetLocalAuthenticationState(updatePublishedState: false)
        do {
            try await prepareAuthenticatedBackend(forceRefresh: true)
            authState = .authenticated(userId: AppMode.localUserID)
            errorMessage = nil
            return true
        } catch {
            print("❌ Local backend authentication failed: \(error)")
            resetLocalAuthenticationState()
            errorMessage = error.localizedDescription
            return false
        }
        #else
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
        #endif
    }

    /// Called after Clerk sign-in completes
    func onSignInComplete() async {
        #if AUDORA_LOCAL_SETUP
        _ = await loginFromCache()
        #else
        if let user = Clerk.shared.user {
            do {
                try await prepareAuthenticatedBackend()
            } catch {
                print("❌ Failed to prepare Convex backend after sign-in: \(error)")
                errorMessage = error.localizedDescription
            }

            authState = .authenticated(userId: user.id)
        }
        #endif
    }

    /// Ensures authenticated backend calls can rely on Convex auth and a user row.
    private func prepareAuthenticatedBackend(forceRefresh: Bool = false) async throws {
        guard let client = client else {
            throw ConvexError.clientNotInitialized
        }

        #if AUDORA_LOCAL_SETUP
        // The local issuer keeps its signing key only for the lifetime of Vite.
        // Refresh on every backend operation so a Vite restart or an expired JWT
        // cannot leave the native client wedged with a stale token.
        let credentialsNeedRefresh = forceRefresh
            || !hasAuthenticatedConvexClient
            || localCredentialsExpiresAt.map { $0.timeIntervalSinceNow < 5 * 60 } != false
        #else
        let credentialsNeedRefresh = !hasAuthenticatedConvexClient
        #endif

        if credentialsNeedRefresh {
            switch await client.login() {
            case .success(let credentials):
                hasAuthenticatedConvexClient = true
                #if AUDORA_LOCAL_SETUP
                localCredentialsExpiresAt = credentials.expiresAt
                // The self-hosted backend may have been restarted with fresh state.
                hasEnsuredUserRecord = false
                #endif
                print("✅ Convex client authenticated")
            case .failure(let error):
                resetLocalAuthenticationState()
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

        #if AUDORA_LOCAL_SETUP
        try await prepareAuthenticatedBackend(forceRefresh: true)
        #else
        try await prepareAuthenticatedBackend()
        #endif
    }

    private func resetLocalAuthenticationState(updatePublishedState: Bool = true) {
        hasAuthenticatedConvexClient = false
        hasEnsuredUserRecord = false
        #if AUDORA_LOCAL_SETUP
        localCredentialsExpiresAt = nil
        if updatePublishedState {
            authState = .unauthenticated
        }
        #endif
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
        #if AUDORA_LOCAL_SETUP
        resetLocalAuthenticationState()
        errorMessage = "Local setup uses an automatic loopback identity and has no account session."
        return
        #else
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
        #endif
    }

    // MARK: - Transcription

    // MARK: - Speechmatics Transcription

    /// Fetches a JWT for Speechmatics real-time transcription from the backend
    func getSpeechmaticsJWT() async throws -> String {
        #if AUDORA_LOCAL_SETUP
        throw ConvexError.speechmaticsDisabled
        #else
        try await ensureAuthenticatedBackendReady()

        guard let client = client else {
            throw ConvexError.clientNotInitialized
        }

        print("🔑 Fetching Speechmatics JWT from backend...")
        let jwt: String = try await client.action("speechmatics:generateJWT", with: [:])

        print("   ✅ JWT fetched successfully")
        return jwt
        #endif
    }

    // MARK: - Conversation Management

    #if AUDORA_LOCAL_SETUP
    /// Resolves a deep-linked conversation through an authenticated query.
    /// The backend query enforces that the current local identity owns or is a
    /// participant in the conversation; parsing an ID from a URL is never
    /// treated as authorization.
    func verifyLocalConversationAccess(
        conversationID: String
    ) async throws -> LocalConversationReference {
        guard LocalConversationDeepLink.isValidConversationID(conversationID) else {
            throw ConvexError.netError("Invalid local conversation identifier.")
        }

        try await ensureAuthenticatedBackendReady()

        guard let client else {
            throw ConvexError.clientNotInitialized
        }

        let subscription = client.subscribe(
            to: "conversations:get",
            with: ["id": conversationID],
            yielding: LocalConversationAccessResponse?.self
        )

        for try await response in subscription.first().values {
            guard let response, response.id == conversationID else {
                throw ConvexError.netError("Conversation could not be verified.")
            }
            return LocalConversationReference(
                id: response.id,
                status: response.status,
                location: response.location
            )
        }

        throw ConvexError.netError("Conversation could not be verified.")
    }
    #endif

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

        print("📝 Creating conversation")

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
        summary: String,
        acousticMetrics: AcousticMetrics? = nil
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
        if let acousticMetrics {
            let encoder = JSONEncoder()
            guard let metricsData = try? encoder.encode(acousticMetrics),
                  let metricsJSON = String(data: metricsData, encoding: .utf8) else {
                throw ConvexError.netError("Failed to serialize acoustic metrics")
            }
            args["acousticMetrics"] = RawConvexJSON(json: metricsJSON)
        }

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
                    try await self.ensureAuthenticatedBackendReady()
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

    /// Uploads an audio file to Convex storage and links it to an existing conversation.
    func uploadAudioFile(audioFileURL: URL, conversationId: String) async throws -> String {
        try await ensureAuthenticatedBackendReady()

        guard let client = client else {
            throw ConvexError.clientNotInitialized
        }

        guard FileManager.default.fileExists(atPath: audioFileURL.path) else {
            throw ConvexError.fileReadFailed
        }

        print("📤 Uploading audio file to backend conversation...")

        let uploadUrl: String = try await client.mutation("conversations:generateUploadUrl", with: [:])
        guard let url = URL(string: uploadUrl), isAllowedLocalConvexUploadURL(url) else {
            throw ConvexError.uploadFailed("Backend returned a non-loopback upload URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [:]
        let delegate = LoopbackUploadSessionDelegate()
        let uploadSession = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { uploadSession.finishTasksAndInvalidate() }

        let (responseData, response) = try await uploadSession.upload(for: request, fromFile: audioFileURL)

        guard let httpResponse = response as? HTTPURLResponse,
              isAllowedLocalConvexUploadURL(httpResponse.url) else {
            throw ConvexError.uploadFailed("Upload did not return an HTTP response")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: responseData, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw ConvexError.uploadFailed(message)
        }

        struct UploadResponse: Decodable {
            let storageId: String
        }

        let uploadResponse = try JSONDecoder().decode(UploadResponse.self, from: responseData)

        var args: [String: (any ConvexEncodable)?] = [:]
        args["conversationId"] = conversationId
        args["storageId"] = uploadResponse.storageId

        try await client.mutation("conversations:saveAudioStorageId", with: args)

        print("   ✅ Audio uploaded and linked: \(uploadResponse.storageId)")
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
    case speechmaticsDisabled

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
        case .speechmaticsDisabled:
            return "Speechmatics is disabled in the local setup."
        }
    }
}
