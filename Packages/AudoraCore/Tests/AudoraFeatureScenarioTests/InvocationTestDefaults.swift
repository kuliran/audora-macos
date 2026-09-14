@testable import AudoraApplication

extension Invocations {
    func tryInvoke(
        _ prepared: PreparedPendingCoachInvocation,
        observingStopAuthority observer: @escaping InvocationStopAuthorityObserver
    ) async -> InvocationTryOutcome {
        await tryInvoke(prepared)
    }

    func tryInvoke(
        _ request: PendingCoachInvocationRequest,
        observingStopAuthority observer: @escaping InvocationStopAuthorityObserver
    ) async -> InvocationTryOutcome {
        await tryInvoke(request)
    }

    func stop(
        _ request: StopCoachInvocationRequest,
        authority: InvocationStopAuthority
    ) async -> InvocationStopOutcome {
        .noActiveInvocation
    }
}
