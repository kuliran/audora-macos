import AudoraApplication
import AudoraDomain
import Foundation

public protocol LibraryLocationChoosing: Sendable {
    func chooseCreateDestination() async -> URL?
    func chooseExistingLibrary() async -> URL?
}

public protocol LibraryBookmarking: Sendable {
    func makeBookmark(for url: URL) throws -> Data
    func resolveBookmark(_ bookmark: Data) throws -> LibraryBookmarkResolution
}

public struct LibraryBookmarkResolution: Sendable {
    public let url: URL
    public let isStale: Bool

    public init(url: URL, isStale: Bool) {
        self.url = url
        self.isStale = isStale
    }
}

public protocol LibraryAccessLease: AnyObject, Sendable {
    var url: URL { get }
    func release()
}

public protocol LibraryAccessGranting: Sendable {
    func acquireAccess(to url: URL) throws -> any LibraryAccessLease
}

public struct MachineLibraryLocator: Equatable, Sendable {
    public static let schemaVersion: UInt32 = 1

    public let expectedLibraryID: LibraryID
    public let restoreOnLaunch: Bool
    public let bookmark: Data

    public init(
        expectedLibraryID: LibraryID,
        restoreOnLaunch: Bool,
        bookmark: Data
    ) {
        self.expectedLibraryID = expectedLibraryID
        self.restoreOnLaunch = restoreOnLaunch
        self.bookmark = bookmark
    }
}

public protocol MachineLibraryLocatorStoring: Sendable {
    func load() async throws -> MachineLibraryLocator?
    func save(_ locator: MachineLibraryLocator) async throws
}

public protocol LibraryRevealing: Sendable {
    func reveal(_ url: URL) async -> Bool
}

public actor PortableLibraryWorkspace: LibraryWorkspacePort {
    private struct ActiveScope: Sendable {
        let lease: any LibraryAccessLease
        let loaded: LoadedPortableLibrary

        var root: URL { lease.url }

        var libraryID: LibraryID? {
            switch loaded {
            case let .readWrite(authority): authority.manifest.libraryID
            case let .readOnly(libraryID): libraryID
            }
        }
    }

    private let persistence: PortableLibraryPersistence
    private let locations: any LibraryLocationChoosing
    private let bookmarks: any LibraryBookmarking
    private let access: any LibraryAccessGranting
    private let locatorStore: any MachineLibraryLocatorStoring
    private let revealer: any LibraryRevealing
    private var activeScope: ActiveScope?
    private var externalRequests: [LibraryOpenRequestToken: URL] = [:]
    private var nextExternalRequest = 0
    private var operationInFlight = false
    private var workspaceGeneration: UInt64 = 0

    public init(
        persistence: PortableLibraryPersistence = PortableLibraryPersistence(),
        locations: any LibraryLocationChoosing,
        bookmarks: any LibraryBookmarking,
        access: any LibraryAccessGranting,
        locatorStore: any MachineLibraryLocatorStoring,
        revealer: any LibraryRevealing
    ) {
        self.persistence = persistence
        self.locations = locations
        self.bookmarks = bookmarks
        self.access = access
        self.locatorStore = locatorStore
        self.revealer = revealer
    }

    public func registerExternalOpenRequest(_ url: URL) -> LibraryOpenRequestToken {
        // Launch Services may deliver another callback while Application is busy.
        // Retain at most one unconsumed URL capability; replacement revokes the old token.
        externalRequests.removeAll(keepingCapacity: true)
        nextExternalRequest += 1
        let token = LibraryOpenRequestToken("external_\(nextExternalRequest)")!
        externalRequests[token] = url
        return token
    }

    public func revokeExternalOpenRequest(_ token: LibraryOpenRequestToken) {
        externalRequests.removeValue(forKey: token)
    }

    var pendingExternalRequestCount: Int { externalRequests.count }

    func acquireAudioImportScope() -> ActiveLibraryImportScope? {
        guard let activeScope,
              case let .readWrite(authority) = activeScope.loaded,
              let importLease = try? access.acquireAccess(to: activeScope.root)
        else {
            return nil
        }
        return ActiveLibraryImportScope(
            identity: AudioImportScopeIdentity(
                libraryID: authority.manifest.libraryID,
                workspaceGeneration: workspaceGeneration
            ),
            root: importLease.url,
            lease: importLease
        )
    }

    func isCurrentAudioImportScope(_ identity: AudioImportScopeIdentity) -> Bool {
        guard identity.workspaceGeneration == workspaceGeneration,
              let activeScope,
              case let .readWrite(authority) = activeScope.loaded
        else {
            return false
        }
        return authority.manifest.libraryID == identity.libraryID
    }

    func withCurrentAudioImportScope<Result: Sendable>(
        _ identity: AudioImportScopeIdentity,
        perform operation: @Sendable () throws -> Result
    ) throws -> Result {
        guard isCurrentAudioImportScope(identity) else {
            throw AudioImportFailure.libraryChanged
        }
        // The synchronous authority-changing operation runs while this actor is
        // isolated, so close/switch cannot race between the identity check and
        // the Session directory's no-replace install.
        return try operation()
    }

    public func restoreActiveLibrary() async -> LibraryOpenOutcome {
        guard reserveOperation() else { return .failed(.candidateUnavailable) }
        defer { operationInFlight = false }
        let locator: MachineLibraryLocator
        do {
            guard let loaded = try await locatorStore.load() else {
                return .noLibrarySelected(recentAvailable: false)
            }
            guard loaded.restoreOnLaunch else {
                return .noLibrarySelected(recentAvailable: true)
            }
            locator = loaded
        } catch {
            return .noLibrarySelected(recentAvailable: false)
        }
        return await openLocator(locator, restoreOnLaunch: true)
    }

    public func createLibrary(_ seed: NewLibrarySeed) async -> LibraryOpenOutcome {
        guard reserveOperation() else { return .failed(.createFailed) }
        defer { operationInFlight = false }
        guard let destination = await locations.chooseCreateDestination() else {
            return .cancelled
        }
        let candidateLease: any LibraryAccessLease
        do {
            candidateLease = try access.acquireAccess(to: destination)
        } catch {
            return .failed(.candidateUnavailable)
        }
        do {
            let authority = try persistence.create(at: destination, seed: seed)
            let scope = ActiveScope(lease: candidateLease, loaded: .readWrite(authority))
            replaceActiveScope(with: scope)
            let locatorResult = await persistLocator(
                root: destination,
                libraryID: authority.manifest.libraryID,
                restoreOnLaunch: true
            )
            return .opened(
                authority.snapshot,
                notice: locatorResult ? nil : .locatorUpdateFailed
            )
        } catch PortableLibraryPersistenceError.destinationExists {
            candidateLease.release()
            return .failed(.createDestinationExists)
        } catch {
            candidateLease.release()
            return .failed(.createFailed)
        }
    }

    public func chooseLibrary() async -> LibraryOpenOutcome {
        guard reserveOperation() else { return .failed(.candidateUnavailable) }
        defer { operationInFlight = false }
        guard let url = await locations.chooseExistingLibrary() else {
            return .cancelled
        }
        return await validateAndSwitch(to: url, expectedID: nil, restoreOnLaunch: true)
    }

    public func openExternalRequest(_ token: LibraryOpenRequestToken) async -> LibraryOpenOutcome {
        guard reserveOperation() else { return .failed(.candidateUnavailable) }
        defer { operationInFlight = false }
        guard let url = externalRequests.removeValue(forKey: token) else {
            return .failed(.externalOpenRequestExpired)
        }
        return await validateAndSwitch(to: url, expectedID: nil, restoreOnLaunch: true)
    }

    public func reopenRecentLibrary() async -> LibraryOpenOutcome {
        guard reserveOperation() else { return .failed(.candidateUnavailable) }
        defer { operationInFlight = false }
        do {
            guard let locator = try await locatorStore.load() else {
                return .failed(.selectionRequired)
            }
            return await openLocator(locator, restoreOnLaunch: true)
        } catch {
            return .failed(.candidateUnavailable)
        }
    }

    public func revealActiveLibrary() async -> LibraryActionOutcome {
        guard reserveOperation() else { return .failed(.revealFailed) }
        defer { operationInFlight = false }
        guard let activeScope else { return .failed(.revealFailed) }
        return await revealer.reveal(activeScope.root)
            ? .succeeded()
            : .failed(.revealFailed)
    }

    public func closeActiveLibrary() async -> LibraryActionOutcome {
        guard reserveOperation() else { return .failed(.closeFailed) }
        defer { operationInFlight = false }
        guard let activeScope else {
            self.activeScope = nil
            workspaceGeneration &+= 1
            return .succeeded(recentAvailable: false)
        }
        guard let libraryID = activeScope.libraryID else {
            self.activeScope = nil
            workspaceGeneration &+= 1
            activeScope.lease.release()
            return .succeeded(recentAvailable: false)
        }
        guard await persistLocator(
            root: activeScope.root,
            libraryID: libraryID,
            restoreOnLaunch: false
        ) else {
            return .failed(.closeFailed)
        }
        self.activeScope = nil
        workspaceGeneration &+= 1
        activeScope.lease.release()
        return .succeeded(recentAvailable: true)
    }

    private func openLocator(
        _ locator: MachineLibraryLocator,
        restoreOnLaunch: Bool
    ) async -> LibraryOpenOutcome {
        let resolution: LibraryBookmarkResolution
        do {
            resolution = try bookmarks.resolveBookmark(locator.bookmark)
        } catch {
            return .failed(.candidateUnavailable)
        }
        guard !resolution.isStale else { return .failed(.selectionRequired) }
        return await validateAndSwitch(
            to: resolution.url,
            expectedID: locator.expectedLibraryID,
            restoreOnLaunch: restoreOnLaunch
        )
    }

    private func validateAndSwitch(
        to url: URL,
        expectedID: LibraryID?,
        restoreOnLaunch: Bool
    ) async -> LibraryOpenOutcome {
        let candidateLease: any LibraryAccessLease
        do {
            candidateLease = try access.acquireAccess(to: url)
        } catch {
            return .failed(.candidateUnavailable)
        }
        let loaded: LoadedPortableLibrary
        do {
            loaded = try persistence.open(at: candidateLease.url)
        } catch PortableLibraryPersistenceError.unsupportedOlderSchema {
            candidateLease.release()
            return .failed(.unsupportedOlderSchema)
        } catch PortableLibraryPersistenceError.ioFailure {
            candidateLease.release()
            return .failed(.candidateUnavailable)
        } catch {
            candidateLease.release()
            return .failed(.candidateCorrupt)
        }

        let candidate = ActiveScope(lease: candidateLease, loaded: loaded)
        if let expectedID, candidate.libraryID != expectedID {
            candidateLease.release()
            return .failed(.identityMismatch)
        }

        // Candidate parsing and locator identity checks complete before the old
        // scope is replaced. From this point the selected candidate is coherent.
        replaceActiveScope(with: candidate)
        var locatorNotice: LibraryNotice?
        if let libraryID = candidate.libraryID,
           !(await persistLocator(
               root: candidate.root,
               libraryID: libraryID,
               restoreOnLaunch: restoreOnLaunch
           ))
        {
            locatorNotice = .locatorUpdateFailed
        }

        switch loaded {
        case let .readWrite(authority):
            return .opened(authority.snapshot, notice: locatorNotice)
        case let .readOnly(libraryID):
            return .readOnly(
                ReadOnlyLibrarySnapshot(libraryID: libraryID),
                reason: .newerSchema,
                notice: locatorNotice
            )
        }
    }

    private func replaceActiveScope(with candidate: ActiveScope) {
        let previous = activeScope
        activeScope = candidate
        workspaceGeneration &+= 1
        previous?.lease.release()
    }

    private func reserveOperation() -> Bool {
        guard !operationInFlight else { return false }
        operationInFlight = true
        return true
    }

    private func persistLocator(
        root: URL,
        libraryID: LibraryID,
        restoreOnLaunch: Bool
    ) async -> Bool {
        do {
            let bookmark = try bookmarks.makeBookmark(for: root)
            try await locatorStore.save(
                MachineLibraryLocator(
                    expectedLibraryID: libraryID,
                    restoreOnLaunch: restoreOnLaunch,
                    bookmark: bookmark
                )
            )
            return true
        } catch {
            return false
        }
    }
}
