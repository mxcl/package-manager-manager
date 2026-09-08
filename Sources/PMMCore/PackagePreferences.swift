import Foundation

/// Choices the user has made that outlive a single launch.
///
/// Shared by the main app and its package host.
public struct PackagePreferences: Sendable, Equatable, Codable {
    public var dismissedPrompts: Set<String>
    public var nativeCaskManagementEnabled: Bool

    public init(dismissedPrompts: Set<String> = [], nativeCaskManagementEnabled: Bool = false) {
        self.dismissedPrompts = dismissedPrompts
        self.nativeCaskManagementEnabled = nativeCaskManagementEnabled
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        dismissedPrompts = try values.decodeIfPresent(Set<String>.self, forKey: .dismissedPrompts) ?? []
        nativeCaskManagementEnabled = try values.decodeIfPresent(Bool.self, forKey: .nativeCaskManagementEnabled) ?? false
    }

    public func hasDismissed(_ prompt: String) -> Bool {
        dismissedPrompts.contains(prompt)
    }

    public mutating func dismiss(_ prompt: String) {
        dismissedPrompts.insert(prompt)
    }

    /// Folds a second set of dismissals into this one.
    ///
    /// A union rather than a replacement, because the two sides are not ordered: preferences are
    /// reloaded from disk on a background task, and a dismissal made while that read was in flight
    /// exists only in memory. Taking the loaded set wholesale would resurrect the prompt the user
    /// just dismissed.
    ///
    /// Dismissals therefore only ever accumulate, and there is deliberately no way to undo one: a
    /// `restore` would be silently discarded by the fold in ``PackagePreferencesStore/save(_:)``,
    /// so the API that could only lie does not exist. Un-dismissing needs a real design — a
    /// tombstone or a last-writer-wins timestamp — not a `Set.remove`.
    public func merging(_ other: PackagePreferences) -> PackagePreferences {
        PackagePreferences(dismissedPrompts: dismissedPrompts.union(other.dismissedPrompts), nativeCaskManagementEnabled: other.nativeCaskManagementEnabled)
    }
}

/// Persists ``PackagePreferences`` beside the host snapshot.
///
/// Not `UserDefaults`: the main app and the menu bar helper are separate bundle identifiers with
/// separate defaults domains, and the helper is the process that runs installs and updates.
public struct PackagePreferencesStore: Sendable {
    /// Writes are serialized here rather than at each call site, so no caller can reorder them.
    private static let queue = DispatchQueue(label: "dev.mxcl.pmm.package-preferences")
    private let url: URL

    public init(url: URL? = nil) {
        self.url = url ?? PackageHostStore.defaultDirectory()
            .appendingPathComponent("package-preferences.json", isDirectory: false)
    }

    public func load() -> PackagePreferences {
        guard let data = try? Data(contentsOf: url),
              let preferences = try? JSONDecoder().decode(PackagePreferences.self, from: data)
        else { return PackagePreferences() }
        return preferences
    }

    /// Folds `preferences` into what is already on disk. Returns immediately; the write happens on
    /// the store's own queue, so callers need no background task of their own.
    ///
    /// The queue settles the ordering within a process: dismissing one prompt and then another used
    /// to schedule two independent writes, and if the older `{first}` landed last it replaced
    /// `{first, second}` and the second prompt came back after relaunch.
    ///
    /// The fold narrows the cross-process window rather than closing it — two processes can still
    /// both read `{}` before either writes, and one dismissal is lost. Only PMMApp writes today, so
    /// that window is theoretical; a second writer would need a real lock around the read and the
    /// write, not just this fold. Dismissals only accumulate, so the fold is a union — see
    /// ``PackagePreferences/merging(_:)``.
    public func save(_ preferences: PackagePreferences) {
        Self.queue.async {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard let data = try? JSONEncoder().encode(preferences.merging(load())) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Only this operation writes the toggle; a stale dismissal must never change it.
    public func setNativeCaskManagementEnabled(_ enabled: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.queue.async {
                do {
                    var preferences = load()
                    preferences.nativeCaskManagementEnabled = enabled
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try JSONEncoder().encode(preferences).write(to: url, options: .atomic)
                    PackageHostNotifications.postPreferencesChanged()
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Waits for every queued write to land.
    ///
    /// `save` returns before the write happens, so quitting immediately after clicking Not Now
    /// would otherwise lose the dismissal and bring the card back on next launch. Both apps call
    /// this on termination; the queue is shared, so any instance drains all of them.
    public func flush() {
        Self.queue.sync {}
    }

    /// ``flush()`` without needing an instance, for a terminate handler that owns no store.
    public static func flushPendingWrites() {
        queue.sync {}
    }
}
