import Foundation
import PMMCore

@MainActor
struct AppUpdateInstallation {
    let install: () async throws -> Void
}

@MainActor
final class AppUpdateController {
    typealias Check = () async throws -> AppUpdateInstallation?

    private let checkForUpdate: Check
    private let publish: (AppUpdateHostState) -> Void
    private let requestMainAppQuit: () -> Void
    private let waitForMainAppExit: () async -> Bool
    private var installation: AppUpdateInstallation?

    private(set) var state: AppUpdateHostState

    init(
        initialState: AppUpdateHostState = AppUpdateHostState(),
        checkForUpdate: @escaping Check,
        publish: @escaping (AppUpdateHostState) -> Void,
        requestMainAppQuit: @escaping () -> Void,
        waitForMainAppExit: @escaping () async -> Bool
    ) {
        state = initialState
        self.checkForUpdate = checkForUpdate
        self.publish = publish
        self.requestMainAppQuit = requestMainAppQuit
        self.waitForMainAppExit = waitForMainAppExit
    }

    func check() async {
        guard !state.isChecking else { return }
        setState(AppUpdateHostState(isChecking: true, isAvailable: installation != nil))
        do {
            installation = try await checkForUpdate()
            setState(AppUpdateHostState(isAvailable: installation != nil))
        } catch {
            setState(AppUpdateHostState(isAvailable: installation != nil, errorMessage: error.localizedDescription))
        }
    }

    func install() async {
        if installation == nil {
            await check()
        }
        guard let installation else { return }

        requestMainAppQuit()
        guard await waitForMainAppExit() else {
            setState(AppUpdateHostState(isAvailable: true, errorMessage: "The main app did not quit in time."))
            return
        }

        do {
            try await installation.install()
        } catch {
            setState(AppUpdateHostState(isAvailable: true, errorMessage: error.localizedDescription))
        }
    }

    private func setState(_ state: AppUpdateHostState) {
        self.state = state
        publish(state)
    }
}
