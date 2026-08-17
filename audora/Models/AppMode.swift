import Foundation

enum AppMode {
    #if AUDORA_LOCAL_SETUP
    static let isLocalSetup = true
    #else
    static let isLocalSetup = false
    #endif

    static let localConvexURL = "http://127.0.0.1:3210"
    static let localAuthTokenURL = "http://127.0.0.1:5173/api/local-auth-token"
    static let localUserID = "audora-local-user"
}
