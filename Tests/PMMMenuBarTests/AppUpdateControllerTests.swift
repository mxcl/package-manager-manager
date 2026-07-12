import Foundation
import PMMCore
import Testing
@testable import PMMMenuBar

@Test @MainActor func appUpdateCheckPublishesAvailableState() async {
    var installed = false
    let controller = AppUpdateController(
        checkForUpdate: {
            AppUpdateInstallation { installed = true }
        },
        publish: { _ in },
        requestMainAppQuit: {},
        waitForMainAppExit: { true }
    )

    await controller.check()

    #expect(controller.state == AppUpdateHostState(isAvailable: true))
    #expect(!installed)
}

@Test @MainActor func appUpdateCheckPublishesCurrentState() async {
    let controller = AppUpdateController(
        checkForUpdate: { nil },
        publish: { _ in },
        requestMainAppQuit: {},
        waitForMainAppExit: { true }
    )

    await controller.check()

    #expect(controller.state == AppUpdateHostState())
}

@Test @MainActor func appUpdateCheckPublishesError() async {
    let controller = AppUpdateController(
        checkForUpdate: { throw AppUpdateTestError.failed },
        publish: { _ in },
        requestMainAppQuit: {},
        waitForMainAppExit: { true }
    )

    await controller.check()

    #expect(controller.state.errorMessage == "failed")
    #expect(!controller.state.isAvailable)
}

@Test @MainActor func repeatedFailedCheckKeepsStagedUpdateAvailable() async {
    var checks = 0
    let controller = AppUpdateController(
        checkForUpdate: {
            checks += 1
            if checks == 2 { throw AppUpdateTestError.failed }
            return AppUpdateInstallation {}
        },
        publish: { _ in },
        requestMainAppQuit: {},
        waitForMainAppExit: { true }
    )

    await controller.check()
    await controller.check()

    #expect(controller.state.isAvailable)
    #expect(controller.state.errorMessage == "failed")
}

@Test @MainActor func installAfterRestartRechecksBeforeInstalling() async {
    var checks = 0
    var quitRequests = 0
    var installs = 0
    let controller = AppUpdateController(
        initialState: AppUpdateHostState(isAvailable: true),
        checkForUpdate: {
            checks += 1
            return AppUpdateInstallation { installs += 1 }
        },
        publish: { _ in },
        requestMainAppQuit: { quitRequests += 1 },
        waitForMainAppExit: { true }
    )

    await controller.install()

    #expect(checks == 1)
    #expect(quitRequests == 1)
    #expect(installs == 1)
}

private enum AppUpdateTestError: LocalizedError {
    case failed

    var errorDescription: String? { "failed" }
}
