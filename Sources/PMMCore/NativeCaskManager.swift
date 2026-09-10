import AppKit
import CryptoKit
import Darwin
import Foundation

public struct NativeCaskInstallation: Codable, Equatable, Sendable {
    public let token: String
    public let version: String
    public let appPath: String
    public let bundleIdentifier: String
    public let teamIdentifier: String
    public let shortVersion: String
    public let bundleVersion: String
    public let quitBundleIdentifiers: [String]?

    public init(token: String, version: String, appPath: String, bundleIdentifier: String, teamIdentifier: String,
                shortVersion: String, bundleVersion: String, quitBundleIdentifiers: [String]? = nil) {
        self.token = token
        self.version = version
        self.appPath = appPath
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
        self.shortVersion = shortVersion
        self.bundleVersion = bundleVersion
        self.quitBundleIdentifiers = quitBundleIdentifiers
    }
}

/// Real shared state, unlike the inventory snapshot. The lock covers both helper and SSH actions.
struct NativeCaskStore: Sendable {
    let directory: URL
    var receiptsURL: URL { directory.appendingPathComponent("native-casks.json") }
    var journalURL: URL { directory.appendingPathComponent("native-cask-transaction.json") }

    func load() throws -> [String: NativeCaskInstallation] {
        guard FileManager.default.fileExists(atPath: receiptsURL.path) else { return [:] }
        return try JSONDecoder().decode([String: NativeCaskInstallation].self, from: Data(contentsOf: receiptsURL))
    }

    func save(_ receipts: [String: NativeCaskInstallation]) throws {
        try JSONEncoder().encode(receipts).write(to: receiptsURL, options: .atomic)
    }

    func lock() throws -> Int32 {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.appendingPathComponent("native-casks.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw NativeCaskError("Could not open native cask lock.") }
        // ponytail: one host-wide lock; use per-app locks only if concurrent installs become necessary.
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw NativeCaskError("Another native app operation is running. Try again when it finishes.")
        }
        return fd
    }
}

private struct NativeCaskTransaction: Codable {
    let receipt: NativeCaskInstallation
    let previous: NativeCaskInstallation?
    let stagingPath: String
}

private final class NativeCaskHTTPSDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }
}

func nativeCaskWork<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            continuation.resume(with: Result { try work() })
        }
    }
}

public struct NativeCaskManager: Sendable {
    private let runner: CommandRunning
    private let session: URLSession
    private let store: NativeCaskStore
    private let preferences: PackagePreferencesStore
    private let applicationDirectories: [URL]
    private let homebrewExecutable: @Sendable () -> String?
    private let isAppRunning: @Sendable (String) -> Bool
    private let apiURL: URL
    private let loadDatabase: @Sendable () async -> PackageDatabase
    private let scanApps: @Sendable (PackageDatabase) async throws -> PackageInventory
    private static let downloadSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 1800
        return URLSession(configuration: config, delegate: NativeCaskHTTPSDelegate(), delegateQueue: nil)
    }()

    public init(runner: CommandRunning = SystemCommandRunner(), session: URLSession? = nil,
                directory: URL = PackageHostStore.defaultDirectory(), preferences: PackagePreferencesStore = PackagePreferencesStore(),
                applicationDirectories: [URL] = [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")],
                apiURL: URL = URL(string: "https://formulae.brew.sh/api/cask/")!,
                homebrewExecutable: @escaping @Sendable () -> String? = { firstExecutable(named: "brew") },
                isAppRunning: @escaping @Sendable (String) -> Bool = { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty },
                loadDatabase: @escaping @Sendable () async -> PackageDatabase = { await PackageDatabase.load() },
                scanApps: @escaping @Sendable (PackageDatabase) async throws -> PackageInventory = { try await NativeCaskManager.scanApps(database: $0) }) {
        self.runner = runner
        self.session = session ?? Self.downloadSession
        self.store = NativeCaskStore(directory: directory)
        self.preferences = preferences
        self.applicationDirectories = applicationDirectories
        self.homebrewExecutable = homebrewExecutable
        self.isAppRunning = isAppRunning
        self.apiURL = apiURL
        self.loadDatabase = loadDatabase
        self.scanApps = scanApps
    }

    public static func token(for package: ManagedPackage) -> String? {
        let identifier = package.catalogIdentifier ?? package.identifier
        guard identifier.hasPrefix("brew:cask:") else { return nil }
        let token = String(identifier.dropFirst("brew:cask:".count))
        return NativeCaskRecipe.validToken(token) ? token : nil
    }

    public func recipe(for token: String) async throws -> NativeCaskRecipe {
        guard NativeCaskRecipe.validToken(token) else { throw NativeCaskError("Invalid cask token.") }
        let (data, response) = try await session.data(from: apiURL.appendingPathComponent(token + ".json"))
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 2_000_000 else {
            throw NativeCaskError("Could not load this cask’s installation recipe.")
        }
        return try await nativeCaskWork { try NativeCaskRecipe.decode(data, token: token) }
    }

    public func perform(_ kind: PackageHostActionKind, package: ManagedPackage,
                        onProgress: (@Sendable (PackageCommandProgress) -> Void)? = nil) async throws {
        try Task.checkCancellation()
        let fd = try await nativeCaskWork { try store.lock() }
        defer { flock(fd, LOCK_UN); close(fd) }
        try await nativeCaskWork {
            try recover()
            try reconcileMissingInstallations()
            try requireEnabled()
        }
        guard let token = Self.token(for: package) else { throw NativeCaskError("This app has no associated cask.") }
        onProgress?(.started(command: "PMM \(kind.rawValue) \(token)"))
        if kind == .uninstall, package.nativeCaskInstallation != nil {
            try await nativeCaskWork { try uninstall(package) }
            onProgress?(.output("Moved app to Trash. Application data was preserved.\n"))
            return
        }
        onProgress?(.output("Checking cask compatibility…\n"))
        let recipe = try await recipe(for: token)
        try Task.checkCancellation()
        // Re-scan ownership at the execution boundary; notification payloads are not authority.
        let database = await loadDatabase()
        let inventory = try await scanApps(database)
        try Self.checkConflicts(recipe, packages: inventory.packages)
        try await nativeCaskWork {
            for id in recipe.quitBundleIdentifiers { try requireClosed(id) }
        }
        let adopted = try await nativeCaskWork { () throws -> NativeCaskInstallation? in
            guard kind == .adopt || ((kind == .update || kind == .uninstall) && PackageActions.canAdopt(package)) else { return nil }
            return try adopt(package, recipe: recipe, inventory: inventory, database: database)
        }
        if kind == .adopt {
            onProgress?(.output("This app is now managed by PMM.\n"))
            return
        }
        if kind == .uninstall {
            try await nativeCaskWork { try uninstall(package, installation: adopted) }
            onProgress?(.output("Moved app to Trash. Application data was preserved.\n"))
            return
        }
        let previous = try await nativeCaskWork { () throws -> NativeCaskInstallation? in
            if kind == .update { return try owned(package, installation: adopted) }
            guard kind == .install, package.installedVersion == nil,
                  !inventory.packages.contains(where: { Self.token(for: $0) == token }) else {
                throw NativeCaskError("This app is already installed. Use Update to manage it with PMM.")
            }
            return nil
        }
        if let previous, !Self.isNewer(recipe.version, than: previous.version) {
            onProgress?(.output("This app is already current.\n"))
            return
        }
        try await downloadAndInstall(recipe, previous: previous, onProgress: onProgress)
    }

    public static func supportsDirectUpdate(_ package: ManagedPackage) -> Bool {
        guard package.manager == .macApp, package.appProvenance == .direct,
              package.nativeCaskInstallation == nil, package.isOutdated, package.versionSource == .sparkle,
              package.bundleIdentifier != nil, package.installLocation != nil,
              let address = package.updateDownloadURL, let url = URL(string: address),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { return false }
        return ["zip", "dmg"].contains(url.pathExtension.lowercased())
    }

    public func updateDirectApp(_ package: ManagedPackage,
                                onProgress: (@Sendable (PackageCommandProgress) -> Void)? = nil) async throws {
        guard Self.supportsDirectUpdate(package), let path = package.installLocation,
              let id = package.bundleIdentifier, let version = package.latestVersion,
              let address = package.updateDownloadURL, let url = URL(string: address) else {
            throw NativeCaskError("This app does not provide a supported update download.")
        }
        let fd = try await nativeCaskWork { try store.lock() }
        defer { flock(fd, LOCK_UN); close(fd) }
        let previous = try await nativeCaskWork {
            try recover()
            let app = try checkedPath(path)
            try requireClosed(id)
            try requireHomebrewDoesNotOwn(token: Self.token(for: package) ?? id, app: app)
            guard !(try store.load()).values.contains(where: { $0.appPath == path }) else {
                throw NativeCaskError("PMM ownership changed. Refresh and try again.")
            }
            let identity = try inspect(app)
            guard identity.id == id else { throw NativeCaskError("The installed app’s identity changed. Refresh and try again.") }
            return NativeCaskInstallation(token: id, version: identity.short, appPath: path,
                bundleIdentifier: id, teamIdentifier: identity.team, shortVersion: identity.short, bundleVersion: identity.build)
        }
        let name = URL(fileURLWithPath: path).lastPathComponent
        let recipe = NativeCaskRecipe(token: previous.token, version: version, url: url,
            sha256: "", app: name, targetName: name, conflicts: [], quitBundleIdentifiers: [])
        onProgress?(.started(command: "Update \(package.displayName)"))
        try await downloadAndInstall(recipe, previous: previous, direct: true, onProgress: onProgress)
        PostHogTelemetry.shared.capturePackageUpdated(package)
    }

    private func downloadAndInstall(_ recipe: NativeCaskRecipe, previous: NativeCaskInstallation?, direct: Bool = false,
                                    onProgress: (@Sendable (PackageCommandProgress) -> Void)?) async throws {
        let work = try await nativeCaskWork { () throws -> URL in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pmm-cask-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            return url
        }
        do {
            onProgress?(.output("Downloading \(recipe.url.lastPathComponent)…\n"))
            let (download, response) = try await session.download(from: recipe.url)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200, response.url?.scheme == "https" else {
                try? await nativeCaskWork { try FileManager.default.removeItem(at: download) }
                throw NativeCaskError("The app download failed.")
            }
            if Task.isCancelled {
                try? await nativeCaskWork { try FileManager.default.removeItem(at: download) }
                throw CancellationError()
            }
            let archive = work.appendingPathComponent("download")
            try await nativeCaskWork {
                try FileManager.default.moveItem(at: download, to: archive)
                onProgress?(.output("Verifying download…\n"))
                if !direct { try Self.verifyChecksum(archive, expected: recipe.sha256) }
                // Do not remove Gatekeeper's first-launch check from software acquired by PMM.
                try command("/usr/bin/xattr", ["-w", "com.apple.quarantine", "0081;\(String(Int(Date().timeIntervalSince1970), radix: 16));PMM;", archive.path])
                try installArchive(archive, work: work, recipe: recipe, previous: previous, direct: direct, onProgress: onProgress)
            }
            try await nativeCaskWork { try FileManager.default.removeItem(at: work) }
        } catch {
            try? await nativeCaskWork { try FileManager.default.removeItem(at: work) }
            throw error
        }
    }

    public static func scanApps(database: PackageDatabase) async throws -> PackageInventory {
        // A failed brew inventory cannot be treated as proof that a direct app is unowned.
        try await nativeCaskWork {
            if let brew = firstExecutable(named: "brew") {
                let result = try SystemCommandRunner().run(brew, ["info", "--json=v2", "--installed"],
                    options: CommandRunOptions(environment: ["HOMEBREW_NO_AUTO_UPDATE": "1"]))
                guard result.status == 0, let data = result.stdout.data(using: .utf8),
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], json["casks"] is [[String: Any]] else {
                    throw NativeCaskError("Could not verify Homebrew ownership. Fix its inventory error before using native app management.")
                }
            }
        }
        var packages: [ManagedPackage] = []
        for await result in PackageScanner().results(for: [.homebrew, .macApp], database: database, mode: .local) {
            if !result.errors.isEmpty { throw NativeCaskError(result.errors.joined(separator: "\n")) }
            packages += result.packages
        }
        return PackageInventory(packages: packages)
    }

    static func checkConflicts(_ recipe: NativeCaskRecipe, packages: [ManagedPackage]) throws {
        if packages.contains(where: { package in
            guard let token = token(for: package) else { return false }
            return recipe.conflicts.contains(token)
        }) { throw NativeCaskError("A conflicting version of this app is installed. Remove it first.") }
    }

    public static func isNewer(_ candidate: String, than installed: String) -> Bool {
        let a = candidate.split(separator: ",").map(String.init)
        let b = installed.split(separator: ",").map(String.init)
        for (left, right) in zip(a, b) {
            let comparison = numericVersionComparison(left, right) ?? left.compare(right, options: .numeric)
            if comparison != .orderedSame { return comparison == .orderedDescending }
        }
        return a.count > b.count
    }

    func managementEnabled() -> Bool { preferences.load().nativeCaskManagementEnabled }

    private func requireEnabled() throws {
        guard managementEnabled() else { throw NativeCaskError("Enable “Manage apps without Homebrew” in Settings first.") }
    }

    @discardableResult
    private func command(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        let result = try runner.run(executable, arguments, options: CommandRunOptions())
        guard result.status == 0 else { throw NativeCaskError("\(URL(fileURLWithPath: executable).lastPathComponent): \(result.stderr.isEmpty ? result.stdout : result.stderr)") }
        return result
    }

    static func verifyChecksum(_ archive: URL, expected: String) throws {
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty { hash.update(data: bytes) }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == expected else {
            throw NativeCaskError("Download checksum mismatch. Nothing was installed.")
        }
    }

    private func checkedPath(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.pathExtension == "app", url.resolvingSymlinksInPath().path == url.path,
              applicationDirectories.contains(where: { url.path.hasPrefix($0.standardizedFileURL.path + "/") }),
              !url.pathComponents.contains("Setapp") else { throw NativeCaskError("The app location is outside a writable Applications folder or uses a symbolic link.") }
        return url
    }

    private func inspect(_ app: URL) throws -> (id: String, team: String, short: String, build: String) {
        try Self.validateBundlePaths(app)
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        guard let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any],
              let id = info["CFBundleIdentifier"] as? String, !id.isEmpty,
              let short = info["CFBundleShortVersionString"] as? String, !short.isEmpty,
              let build = info["CFBundleVersion"] as? String, !build.isEmpty,
              !FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/_MASReceipt/receipt").path) else {
            throw NativeCaskError("The download is not a supported direct-download app bundle.")
        }
        try command("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        try command("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path])
        let signature = try command("/usr/bin/codesign", ["-dv", "--verbose=4", app.path])
        let lines = (signature.stdout + "\n" + signature.stderr).components(separatedBy: .newlines)
        guard let team = lines.first(where: { $0.hasPrefix("TeamIdentifier=") }).map({ String($0.dropFirst("TeamIdentifier=".count)) }),
              !team.isEmpty, team != "not set" else { throw NativeCaskError("This app has no verifiable developer identity.") }
        return (id, team, short, build)
    }

    static func validateBundlePaths(_ app: URL) throws {
        let root = app.standardizedFileURL.path
        guard app.resolvingSymlinksInPath().path == root,
              let enumerator = FileManager.default.enumerator(at: app, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
            throw NativeCaskError("Invalid app bundle.")
        }
        for case let url as URL in enumerator {
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved == root || resolved.hasPrefix(root + "/") else {
                throw NativeCaskError("The app contains a symbolic link outside its bundle.")
            }
        }
    }

    private func requireHomebrewDoesNotOwn(token: String, app: URL) throws {
        guard let brew = homebrewExecutable() else { return }
        let result = try runner.run(brew, ["info", "--json=v2", "--installed"],
            options: CommandRunOptions(environment: ["HOMEBREW_NO_AUTO_UPDATE": "1"]))
        guard result.status == 0, let data = result.stdout.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = json["casks"] as? [[String: Any]] else {
            throw NativeCaskError("Could not verify Homebrew ownership. Nothing was modified.")
        }
        for cask in casks {
            let ownsPath = (cask["artifacts"] as? [[String: Any]] ?? []).contains { artifact in
                guard let values = artifact["app"] as? [Any], let name = values.first as? String else { return false }
                let path = artifact["target"] as? String ?? "/Applications/" + name
                return URL(fileURLWithPath: path).resolvingSymlinksInPath().path == app.path
            }
            if cask["token"] as? String == token || ownsPath { throw NativeCaskError("Homebrew owns this app. Manage it through Homebrew.") }
        }
    }

    private func requireClosed(_ id: String) throws {
        guard !isAppRunning(id) else {
            throw NativeCaskError("Quit \(id) before updating or removing it, then try again.")
        }
    }

    private func owned(_ package: ManagedPackage, installation: NativeCaskInstallation? = nil) throws -> NativeCaskInstallation {
        guard let expected = installation ?? package.nativeCaskInstallation,
              let receipt = try store.load()[expected.token], receipt == expected,
              package.installLocation == receipt.appPath, package.bundleIdentifier == receipt.bundleIdentifier else {
            throw NativeCaskError("This app is not owned by PMM, or its installation changed. Refresh and try again.")
        }
        let app = try checkedPath(receipt.appPath)
        try requireHomebrewDoesNotOwn(token: receipt.token, app: app)
        let identity = try inspect(app)
        guard identity.id == receipt.bundleIdentifier, identity.team == receipt.teamIdentifier else { throw NativeCaskError("The installed app’s identity changed. Nothing was modified.") }
        try requireClosed(identity.id)
        for id in receipt.quitBundleIdentifiers ?? [] { try requireClosed(id) }
        return receipt
    }

    @discardableResult
    func adopt(_ package: ManagedPackage, recipe: NativeCaskRecipe, inventory: PackageInventory, database: PackageDatabase) throws -> NativeCaskInstallation {
        try requireEnabled()
        guard package.manager == .macApp, package.appProvenance == .direct, package.nativeCaskInstallation == nil,
              let path = package.installLocation, let id = package.bundleIdentifier,
              database.app(for: id)?.cask == recipe.token,
              inventory.packages.filter({ Self.token(for: $0) == recipe.token }).count == 1,
              inventory.packages.contains(where: { $0.id == package.id && $0.installLocation == path && $0.bundleIdentifier == id && $0.appProvenance == .direct && $0.nativeCaskInstallation == nil }) else {
            throw NativeCaskError("This app cannot be unambiguously adopted. Refresh and check its installation source.")
        }
        let app = try checkedPath(path)
        try requireHomebrewDoesNotOwn(token: recipe.token, app: app)
        guard app.lastPathComponent == recipe.targetName else { throw NativeCaskError("The app name does not match this cask.") }
        let identity = try inspect(app)
        guard identity.id == id else { throw NativeCaskError("The app identity does not match this cask.") }
        try requireClosed(id)
        var receipts = try store.load()
        guard receipts[recipe.token] == nil else { throw NativeCaskError("PMM already manages an installation of this cask.") }
        let receipt = NativeCaskInstallation(token: recipe.token, version: identity.short, appPath: app.path,
            bundleIdentifier: id, teamIdentifier: identity.team, shortVersion: identity.short, bundleVersion: identity.build, quitBundleIdentifiers: recipe.quitBundleIdentifiers)
        receipts[recipe.token] = receipt
        try store.save(receipts)
        return receipt
    }

    func installArchive(_ archive: URL, work: URL, recipe: NativeCaskRecipe, previous: NativeCaskInstallation?, direct: Bool = false,
                                onProgress: (@Sendable (PackageCommandProgress) -> Void)?) throws {
        let handle = try FileHandle(forReadingFrom: archive)
        let header = try handle.read(upToCount: 4)
        let size = try handle.seekToEnd()
        if size >= 512 { try handle.seek(toOffset: size - 512) }
        let footer = try handle.read(upToCount: 4)
        try handle.close()
        let extracted = work.appendingPathComponent("contents", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: false)
        let isDMG = footer == Data("koly".utf8)
        if isDMG {
            try command("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", extracted.path, archive.path])
        } else {
            guard header == Data([0x50, 0x4b, 0x03, 0x04]) else { throw NativeCaskError("Only DMG and ZIP app downloads are supported.") }
            // bsdtar refuses traversal and writes through escaping symlinks; do not pass -P.
            try command("/usr/bin/tar", ["-xf", archive.path, "-C", extracted.path, "--no-same-owner"])
        }
        defer { if isDMG { _ = try? command("/usr/bin/hdiutil", ["detach", extracted.path]) } }
        let source = extracted.appendingPathComponent(recipe.app)
        guard source.resolvingSymlinksInPath().path.hasPrefix(extracted.path + "/") else { throw NativeCaskError("The app artifact escapes the download.") }
        let parent: URL
        if let previous { parent = try checkedPath(previous.appPath).deletingLastPathComponent() }
        else {
            guard let selected = applicationDirectories.first(where: { FileManager.default.isWritableFile(atPath: $0.path) }) ?? applicationDirectories.last else {
                throw NativeCaskError("No Applications folder is available.")
            }
            parent = selected
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        let destination = previous.map { URL(fileURLWithPath: $0.appPath) } ?? parent.appendingPathComponent(recipe.targetName)
        _ = try checkedPath(destination.path)
        if previous == nil && FileManager.default.fileExists(atPath: destination.path) { throw NativeCaskError("An app already exists at \(destination.path). Adopt it explicitly first.") }
        let staging = parent.appendingPathComponent(".pmm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let staged = staging.appendingPathComponent("new.app")
        var journalWritten = false
        defer { if !journalWritten { try? FileManager.default.removeItem(at: staging) } }
        try Self.validateBundlePaths(source)
        try command("/usr/bin/ditto", [source.path, staged.path])
        try command("/usr/bin/xattr", ["-w", "com.apple.quarantine", "0081;\(String(Int(Date().timeIntervalSince1970), radix: 16));PMM;", staged.path])
        let identity = try inspect(staged)
        try requireClosed(identity.id)
        for id in recipe.quitBundleIdentifiers { try requireClosed(id) }
        if let previous {
            guard identity.id == previous.bundleIdentifier, identity.team == previous.teamIdentifier else { throw NativeCaskError("The update’s developer or bundle identity does not match the installed app.") }
            let existing = try inspect(destination)
            guard existing.id == previous.bundleIdentifier, existing.team == previous.teamIdentifier else { throw NativeCaskError("The installed app changed while the update downloaded.") }
            if direct {
                guard existing.short == previous.shortVersion, existing.build == previous.bundleVersion else {
                    throw NativeCaskError("The installed app changed while the update downloaded. Try again.")
                }
            }
            guard !Self.isNewer(existing.short, than: identity.short) else { throw NativeCaskError("The installed app is newer than this download.") }
        }
        try requireHomebrewDoesNotOwn(token: recipe.token, app: destination)
        if direct {
            guard let previous,
                  identity.short == recipe.version,
                  Self.isNewer(identity.build, than: previous.bundleVersion) else {
                throw NativeCaskError("The download does not contain the expected newer app version.")
            }
            let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: staged.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any]
            if let minimum = info?["LSMinimumSystemVersion"] as? String,
               Self.isNewer(minimum, than: NativeCaskRecipe.currentOSVersion) {
                throw NativeCaskError("This update requires macOS \(minimum) or later.")
            }
            guard let executable = info?["CFBundleExecutable"] as? String, !executable.isEmpty,
                  !executable.contains("/"), executable != ".." else { throw NativeCaskError("The app has no valid executable.") }
            try command("/usr/bin/lipo", [staged.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable).path,
                "-verify_arch", NativeCaskRecipe.isAppleSilicon ? "arm64" : "x86_64"])
            // Both bundles stay on the same volume. Atomic exchange leaves the old app intact on failure.
            try requireClosed(identity.id)
            guard renameatx_np(AT_FDCWD, staged.path, AT_FDCWD, destination.path, UInt32(RENAME_SWAP)) == 0 else {
                throw NativeCaskError("Could not replace the app: \(String(cString: strerror(errno))). Nothing was changed.")
            }
            onProgress?(.output("Installed \(recipe.version).\n"))
            return
        }
        let receipt = NativeCaskInstallation(token: recipe.token, version: recipe.version, appPath: destination.path,
            bundleIdentifier: identity.id, teamIdentifier: identity.team, shortVersion: identity.short, bundleVersion: identity.build, quitBundleIdentifiers: recipe.quitBundleIdentifiers)
        try requireEnabled()
        var receipts = try store.load()
        guard receipts[recipe.token] == previous else { throw NativeCaskError("Cask ownership changed. Refresh and try again.") }
        let transaction = NativeCaskTransaction(receipt: receipt, previous: previous, stagingPath: staging.path)
        try JSONEncoder().encode(transaction).write(to: store.journalURL, options: .atomic)
        journalWritten = true
        onProgress?(.output("Installing \(recipe.targetName)…\n"))
        do {
            if previous != nil { try FileManager.default.moveItem(at: destination, to: staging.appendingPathComponent("previous.app")) }
            try FileManager.default.moveItem(at: staged, to: destination)
            receipts[recipe.token] = receipt
            try store.save(receipts)
            try recover()
        } catch {
            try recover()
            throw error
        }
        onProgress?(.output("Installed \(recipe.version).\n"))
    }

    /// The receipt is the commit point. Before it commits, restore the old bundle.
    func recover() throws {
        guard FileManager.default.fileExists(atPath: store.journalURL.path) else { return }
        let transaction = try JSONDecoder().decode(NativeCaskTransaction.self, from: Data(contentsOf: store.journalURL))
        let destination = try checkedPath(transaction.receipt.appPath)
        let staging = URL(fileURLWithPath: transaction.stagingPath).standardizedFileURL
        guard staging.deletingLastPathComponent() == destination.deletingLastPathComponent(),
              staging.lastPathComponent.hasPrefix(".pmm-"), staging.resolvingSymlinksInPath().path == staging.path else {
            throw NativeCaskError("Invalid pending native cask transaction.")
        }
        let previous = staging.appendingPathComponent("previous.app")
        if try store.load()[transaction.receipt.token] != transaction.receipt {
            if FileManager.default.fileExists(atPath: previous.path) {
                let oldIdentity = try inspect(previous)
                guard oldIdentity.id == transaction.previous?.bundleIdentifier,
                      oldIdentity.team == transaction.previous?.teamIdentifier else {
                    throw NativeCaskError("The recovery backup’s identity changed. No files were removed.")
                }
                if FileManager.default.fileExists(atPath: destination.path) {
                    try verifyRecoveryDestination(destination, receipt: transaction.receipt)
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: previous, to: destination)
            } else if transaction.previous == nil && !FileManager.default.fileExists(atPath: staging.appendingPathComponent("new.app").path),
                      FileManager.default.fileExists(atPath: destination.path) {
                try verifyRecoveryDestination(destination, receipt: transaction.receipt)
                try FileManager.default.removeItem(at: destination)
            }
        }
        if FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) }
        try FileManager.default.removeItem(at: store.journalURL)
    }

    private func verifyRecoveryDestination(_ destination: URL, receipt: NativeCaskInstallation) throws {
        let identity = try inspect(destination)
        guard identity.id == receipt.bundleIdentifier, identity.team == receipt.teamIdentifier,
              identity.short == receipt.shortVersion, identity.build == receipt.bundleVersion else {
            throw NativeCaskError("The app changed during recovery. No files were removed.")
        }
        try requireClosed(identity.id)
    }

    func uninstall(_ package: ManagedPackage, installation: NativeCaskInstallation? = nil) throws {
        let receipt = try owned(package, installation: installation)
        try requireEnabled()
        var receipts = try store.load()
        try FileManager.default.trashItem(at: URL(fileURLWithPath: receipt.appPath), resultingItemURL: nil)
        receipts.removeValue(forKey: receipt.token)
        try store.save(receipts)
    }

    /// Called by the scanner on its utility queue, including when native management is disabled.
    func installations() throws -> [String: NativeCaskInstallation] {
        guard let fd = try? store.lock() else { return try store.load() }
        defer { flock(fd, LOCK_UN); close(fd) }
        try recover()
        try reconcileMissingInstallations()
        return try store.load()
    }

    private func reconcileMissingInstallations() throws {
        let receipts = try store.load()
        let remaining = receipts.filter { FileManager.default.fileExists(atPath: $0.value.appPath) }
        if receipts != remaining { try store.save(remaining) }
    }

    func matches(_ receipt: NativeCaskInstallation, app: URL) -> Bool {
        guard receipt.appPath == app.standardizedFileURL.path, let identity = try? inspect(app.standardizedFileURL) else { return false }
        return identity.id == receipt.bundleIdentifier && identity.team == receipt.teamIdentifier
    }
}
