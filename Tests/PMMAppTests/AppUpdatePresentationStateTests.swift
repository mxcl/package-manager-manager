import PMMCore
import Testing
@testable import PMMApp

@Test func manualAppUpdateCheckReportsAvailableOnce() {
    var state = AppUpdatePresentationState()

    let started = state.beginManualCheck()
    #expect(started)
    #expect(state.apply(AppUpdateHostState(isChecking: true)) == nil)
    #expect(state.apply(AppUpdateHostState(isAvailable: true)) == .available)
    #expect(state.apply(AppUpdateHostState(isAvailable: true)) == nil)
    #expect(state.host.isAvailable)
}

@Test func manualAppUpdateCheckReportsCurrentAndError() {
    var current = AppUpdatePresentationState()
    let currentStarted = current.beginManualCheck()
    #expect(currentStarted)
    #expect(current.apply(AppUpdateHostState()) == .current)

    var failed = AppUpdatePresentationState()
    let failedStarted = failed.beginManualCheck()
    #expect(failedStarted)
    #expect(failed.apply(AppUpdateHostState(errorMessage: "offline")) == .checkFailed("offline"))
}

@Test func appUpdateInstallErrorIsReportedOnce() {
    var state = AppUpdatePresentationState()
    state.beginInstall()

    #expect(state.apply(AppUpdateHostState(isAvailable: true, errorMessage: "denied")) == .installFailed("denied"))
    #expect(state.apply(AppUpdateHostState(isAvailable: true, errorMessage: "denied")) == nil)
}
