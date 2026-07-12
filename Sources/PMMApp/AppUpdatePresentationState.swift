import PMMCore

enum AppUpdatePresentationResult: Equatable {
    case available
    case current
    case checkFailed(String)
    case installFailed(String)
}

struct AppUpdatePresentationState {
    private(set) var host = AppUpdateHostState()
    private var manualCheckPending = false
    private var installPending = false

    mutating func beginManualCheck() -> Bool {
        guard !host.isChecking else { return false }
        manualCheckPending = true
        host.isChecking = true
        return true
    }

    mutating func beginInstall() {
        installPending = true
    }

    mutating func apply(_ host: AppUpdateHostState) -> AppUpdatePresentationResult? {
        self.host = host
        guard !host.isChecking else { return nil }

        if installPending, let error = host.errorMessage {
            installPending = false
            return .installFailed(error)
        }
        if installPending, !host.isAvailable {
            installPending = false
            return .current
        }
        guard manualCheckPending else { return nil }
        manualCheckPending = false
        if let error = host.errorMessage {
            return .checkFailed(error)
        }
        return host.isAvailable ? .available : .current
    }
}
