import Foundation

public struct PostHogTelemetry: Sendable {
    public static let shared = PostHogTelemetry()

    private static let heartbeatDefaultsKey = "PostHogLastHeartbeatAt"
    private static let heartbeatInterval: TimeInterval = 24 * 60 * 60
    private static let installIDDefaultsKey = "PostHogAnonymousInstallID"
    private let endpoint = URL(string: "https://us.i.posthog.com/i/v0/e/")!
    private let apiKey: String?
    private let appVersion: String

    public init(bundle: Bundle = .main) {
        apiKey = (bundle.object(forInfoDictionaryKey: "PostHogAPIKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown"
    }

    public func captureAppOpened() {
        capture(event: "pmm_app_opened")
    }

    public func captureHeartbeat() {
        let defaults = UserDefaults.standard
        let now = Date()
        guard Self.heartbeatIsDue(
            lastCapturedAt: defaults.object(forKey: Self.heartbeatDefaultsKey) as? Date,
            now: now
        ) else { return }
        capture(event: "pmm_heartbeat") {
            UserDefaults.standard.set(now, forKey: Self.heartbeatDefaultsKey)
        }
    }

    public func capturePackageUpdated(_ package: ManagedPackage) {
        capture(
            event: "pmm_package_updated",
            package: PackageProperties(
                manager: package.manager.rawValue,
                identifier: package.identifier,
                fromVersion: package.installedVersion ?? "unknown",
                toVersion: package.latestVersion ?? "unknown"
            )
        )
    }

    private func capture(
        event: String,
        package: PackageProperties? = nil,
        onSuccess: (@Sendable () -> Void)? = nil
    ) {
        guard let apiKey, !apiKey.isEmpty else { return }

        let endpoint = endpoint
        let appVersion = appVersion
        let distinctID = Self.anonymousInstallID()
        Task.detached(priority: .utility) {
            var properties: [String: Any] = [
                "$process_person_profile": false,
                "app_name": "Package Manager Manager",
                "app_version": appVersion,
                "macos_version": ProcessInfo.processInfo.operatingSystemVersionString,
                "machine_arch": Self.machineArchitecture,
            ]
            if let package {
                properties["package_manager"] = package.manager
                properties["package_identifier"] = package.identifier
                properties["from_version"] = package.fromVersion
                properties["to_version"] = package.toVersion
            }
            let payload: [String: Any] = [
                "api_key": apiKey,
                "event": event,
                "distinct_id": distinctID,
                "properties": properties,
            ]

            guard JSONSerialization.isValidJSONObject(payload),
                  let body = try? JSONSerialization.data(withJSONObject: payload) else {
                NSLog("posthog telemetry skipped: invalid payload")
                return
            }

            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            request.timeoutInterval = 5

            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let statusCode = (response as? HTTPURLResponse)?.statusCode,
                      (200..<300).contains(statusCode) else {
                    NSLog("posthog telemetry failed with status: %d", (response as? HTTPURLResponse)?.statusCode ?? 0)
                    return
                }
                onSuccess?()
            } catch {
                NSLog("posthog telemetry failed: %@", error.localizedDescription)
            }
        }
    }

    static func heartbeatIsDue(lastCapturedAt: Date?, now: Date) -> Bool {
        guard let lastCapturedAt else { return true }
        return now.timeIntervalSince(lastCapturedAt) >= heartbeatInterval
    }

    private static func anonymousInstallID(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: installIDDefaultsKey), !existing.isEmpty {
            return existing
        }
        let installID = UUID().uuidString
        defaults.set(installID, forKey: installIDDefaultsKey)
        return installID
    }

    private static var machineArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}

private struct PackageProperties: Sendable {
    let manager: String
    let identifier: String
    let fromVersion: String
    let toVersion: String
}
