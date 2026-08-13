import Foundation
import PMMCore
import SystemConfiguration

enum MainWindowSection: Hashable, Identifiable, Sendable {
    case home
    case installed
    case outdated
    case newUpdated
    case rust
    case homebrew
    case apps
    case javascript
    case python
    case skills
    case category(String)
    case about

    var id: String {
        switch self {
        case .home: "home"
        case .installed: "installed"
        case .outdated: "outdated"
        case .newUpdated: "newUpdated"
        case .rust: "rust"
        case .homebrew: "homebrew"
        case .apps: "apps"
        case .javascript: "javascript"
        case .python: "python"
        case .skills: "skills"
        case .category(let identifier): "category:\(identifier)"
        case .about: "about"
        }
    }

    static let librarySections: [MainWindowSection] = [.home, .installed, .outdated]
    static let managerSections: [MainWindowSection] = [.rust, .homebrew, .apps, .javascript, .python, .skills]
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    static let categoryShortcutSections: [MainWindowSection] = [.newUpdated]

    static let developerTools = category("developer-tools")
    static let cloudInfrastructure = category("cloud-infrastructure")
    static let networking = category("networking")
    static let system = category("system")
    static let security = category("security")
    static let data = category("data")
    static let languageRuntime = category("language-runtime")
    static let media = category("media")
    static let productivity = category("productivity")
    static let science = category("science")
    static let games = category("games")
    static let toys = category("toys")
    static let other = category("other")

    var title: String {
        switch self {
        case .home: "Discover"
        case .installed: "Installed"
        case .outdated: "Outdated"
        case .newUpdated: "New"
        case .rust: "Rust"
        case .homebrew: "Homebrew"
        case .apps: "Apps"
        case .javascript: "JavaScript"
        case .python: "Python"
        case .skills: "Skills"
        case .category(let identifier): Self.categoryTitle(identifier)
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "safari"
        case .installed: "shippingbox"
        case .outdated: "clock"
        case .newUpdated: "sparkles"
        case .rust: "hammer"
        case .homebrew: "mug"
        case .apps: "macwindow"
        case .javascript: "curlybraces"
        case .python: "arrow.forward.to.line"
        case .skills: "wand.and.stars"
        case .category(let identifier): Self.categorySystemImage(identifier)
        case .about: "info.circle"
        }
    }

    var sidebarImage: String? {
        switch self {
        case .rust: "EcosystemRust"
        case .homebrew: "EcosystemHomebrew"
        case .javascript: "EcosystemJavaScript"
        case .python: "EcosystemPython"
        default: nil
        }
    }

    var packageManagers: Set<PackageManagerKind> {
        switch self {
        case .rust: [.cargoInstall, .rustup, .mise]
        case .homebrew: [.homebrew]
        case .apps: [.homebrew, .macApp]
        case .javascript: [.npm, .npx, .mise]
        case .python: [.uv, .uvx, .mise]
        case .skills: [.skills]
        default: []
        }
    }

    var categoryIdentifier: String? {
        guard case .category(let identifier) = self else { return nil }
        return identifier
    }

    private static func categoryTitle(_ identifier: String) -> String {
        switch identifier {
        case "ai": "AI"
        case "developer-tools": "Developer Tools"
        case "cloud-infrastructure": "Cloud Infrastructure"
        case "language-runtime": "Language Runtime"
        default:
            identifier.split(separator: "-").map { word in
                word.prefix(1).uppercased() + word.dropFirst()
            }.joined(separator: " ")
        }
    }

    private static func categorySystemImage(_ identifier: String) -> String {
        switch identifier {
        case "developer-tools": "chevron.left.forwardslash.chevron.right"
        case "cloud-infrastructure": "cloud"
        case "networking": "network"
        case "system": "gearshape"
        case "security": "shield"
        case "data": "chart.bar.doc.horizontal"
        case "language-runtime": "curlybraces"
        case "media": "play.rectangle"
        case "productivity": "checklist"
        case "science": "atom"
        case "games": "gamecontroller"
        case "toys": "puzzlepiece"
        case "other": "ellipsis"
        default: "square.grid.2x2"
        }
    }
}

enum MainWindowLinkTab: String, CaseIterable, Identifiable {
    case homepage
    case update
    case repo
    case docs
    case registry
    case releases

    var id: String { rawValue }
    var title: String {
        switch self {
        case .homepage: "Home"
        case .update: "Update"
        case .registry: "Registry"
        case .docs: "Docs"
        case .repo: "Repo"
        case .releases: "Changelog"
        }
    }

    func urlString(in package: ManagedPackage) -> String? {
        switch self {
        case .homepage: package.homepage
        case .update: package.advisoryURL
        case .registry: mainWindowRegistryURLString(for: package)
        case .docs: package.docs
        case .repo: package.repo
        case .releases: nil
        }
    }
}

enum MainWindowMacAppMark: Equatable {
    case asset(String)
    case paired(asset: String, system: String)
    case system(String)
    case text(String)
}

func mainWindowMacAppMark(for provenance: MacAppProvenance?) -> MainWindowMacAppMark {
    switch provenance ?? .unknown {
    case .appStore: .asset("EcosystemAppStore")
    case .homebrew: .paired(asset: "EcosystemHomebrew", system: "macwindow")
    case .setapp: .text(MacAppProvenance.setapp.title.uppercased())
    case .direct: .system("macwindow")
    case .unknown: .text(MacAppProvenance.unknown.title.uppercased())
    }
}

struct MainWindowPackageLink: Equatable, Identifiable {
    let tab: MainWindowLinkTab
    let url: URL

    var id: MainWindowLinkTab { tab }
}

struct MainWindowPackageURLRequest: Equatable {
    let manager: PackageManagerKind
    let name: String
    let identifier: String

    init?(identifier rawIdentifier: String) {
        let identifier = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { return nil }

        if identifier.hasPrefix("brew:cask:") {
            manager = .homebrew
            name = "cask/" + String(identifier.trimmingPrefix("brew:cask:"))
        } else if identifier.hasPrefix("brew:") {
            manager = .homebrew
            name = String(identifier.trimmingPrefix("brew:"))
        } else if identifier.hasPrefix("cargo:") {
            manager = .cargoInstall
            name = String(identifier.trimmingPrefix("cargo:"))
        } else if identifier.hasPrefix("rustup:") {
            manager = .rustup
            name = String(identifier.trimmingPrefix("rustup:")).replacingOccurrences(of: ":", with: "/")
        } else if identifier.hasPrefix("npm:") {
            manager = .npm
            name = String(identifier.trimmingPrefix("npm:"))
        } else if identifier.hasPrefix("mise:") {
            manager = .mise
            name = String(identifier.trimmingPrefix("mise:"))
        } else if identifier.hasPrefix("npx:") {
            manager = .npx
            name = String(identifier.trimmingPrefix("npx:"))
        } else if identifier.hasPrefix("skills:global:") {
            manager = .skills
            name = String(identifier.trimmingPrefix("skills:global:"))
        } else if identifier.hasPrefix("uv:") {
            manager = .uv
            name = String(identifier.trimmingPrefix("uv:")).replacingOccurrences(of: ":", with: "/")
        } else if identifier.hasPrefix("uvx:") {
            manager = .uvx
            name = String(identifier.trimmingPrefix("uvx:"))
        } else {
            return nil
        }

        guard !name.isEmpty else { return nil }
        self.identifier = identifier
    }

    init?(url: URL) {
        guard url.scheme?.lowercased() == "pkgmgrmgr", let host = url.host()?.lowercased() else { return nil }
        let name = url.path(percentEncoded: false).trimmingPrefix("/").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        switch host {
        case "brew", "homebrew":
            manager = .homebrew
            if name.hasPrefix("cask/") {
                identifier = "brew:cask:\(name.trimmingPrefix("cask/"))"
            } else {
                identifier = "brew:\(name)"
            }
        case "cargo", "cargo-install":
            manager = .cargoInstall
            identifier = "cargo:\(name)"
        case "rustup":
            manager = .rustup
            identifier = "rustup:\(name.replacingOccurrences(of: "/", with: ":"))"
        case "npm":
            manager = .npm
            identifier = "npm:\(name)"
        case "mise":
            manager = .mise
            identifier = "mise:\(name)"
        case "npx":
            manager = .npx
            identifier = "npx:\(name)"
        case "skills":
            manager = .skills
            identifier = "skills:global:\(name)"
        case "uv":
            manager = .uv
            identifier = "uv:\(name.replacingOccurrences(of: "/", with: ":"))"
        case "uvx":
            manager = .uvx
            identifier = "uvx:\(name)"
        default:
            return nil
        }

        self.name = name
    }

    var section: MainWindowSection {
        if manager == .homebrew, name.hasPrefix("cask/") { return .apps }
        return switch manager {
        case .cargoInstall, .rustup: .rust
        case .apk, .apt, .dnf, .zypper: .installed
        case .macApp: .apps
        case .homebrew: .homebrew
        case .npm, .npx: .javascript
        case .mise: .installed
        case .skills: .skills
        case .uv, .uvx: .python
        }
    }

    func matches(_ package: ManagedPackage) -> Bool {
        package.catalogIdentifier == identifier
            || (package.manager == manager && (package.identifier == identifier || package.packageToken == name))
    }
}

private enum MainWindowPackageURLCommand: Equatable {
    case select(MainWindowPackageURLRequest)
    case install([MainWindowPackageURLRequest])

    init?(url: URL) {
        guard url.scheme?.lowercased() == "pkgmgrmgr" else { return nil }

        if url.host()?.lowercased() == "install" {
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            let identifiers = (components.queryItems ?? [])
                .filter { $0.name == "package" }
                .compactMap(\.value)
            let requests = identifiers.compactMap(MainWindowPackageURLRequest.init(identifier:))
            guard !requests.isEmpty, requests.count == identifiers.count else { return nil }
            self = .install(requests)
            return
        }

        guard let request = MainWindowPackageURLRequest(url: url) else { return nil }
        self = .select(request)
    }
}

enum DashboardBlogCategory: String, Codable, Sendable {
    case pack
    case blog
}

struct DashboardBlogEntry: Codable, Equatable, Identifiable, Sendable {
    let slug: String
    let title: String
    let subtitle: String
    let category: DashboardBlogCategory
    let systemImage: String
    let publishedAt: String
    let url: URL

    var id: String { slug }
    var imageURL: URL { url.appending(path: "hero.png") }
}

struct DashboardBlogIndex: Decodable, Sendable {
    let posts: [DashboardBlogEntry]
}

struct MainWindowInstallPackConfirmation: Equatable, Sendable {
    let packageIDs: [String]
    let packageCount: Int
}

func mainWindowLinks(for package: ManagedPackage?) -> [MainWindowPackageLink] {
    guard let package else { return [] }
    let links = MainWindowLinkTab.allCases.compactMap { tab in
        mainWindowWebURL(tab.urlString(in: package)).map { MainWindowPackageLink(tab: tab, url: $0) }
    }
    let specificURLs = Set(links.filter { $0.tab != .homepage }.map(\.url))
    return links.filter { $0.tab != .homepage || !specificURLs.contains($0.url) }
}

func mainWindowRegistryURLString(for package: ManagedPackage) -> String? {
    if let identifier = package.catalogIdentifier, identifier.hasPrefix("brew:cask:") {
        return "https://formulae.brew.sh/cask/\(identifier.trimmingPrefix("brew:cask:"))"
    }
    switch package.manager {
    case .homebrew:
        let kind = package.identifier.hasPrefix("brew:cask:") ? "cask" : "formula"
        return "https://formulae.brew.sh/\(kind)/\(package.packageToken)"
    case .npm, .npx:
        return "https://www.npmjs.com/package/\(package.packageToken)"
    case .cargoInstall:
        return "https://crates.io/crates/\(package.packageToken)"
    case .uv, .uvx:
        guard package.identifier.hasPrefix("uv:tool:") || package.manager == .uvx else { return nil }
        return "https://pypi.org/project/\(package.packageToken)/"
    case .apk, .apt, .dnf, .zypper, .macApp, .rustup, .mise:
        return nil
    case .skills:
        return nil
    }
}

func mainWindowReleaseNotesURL(for package: ManagedPackage?) -> URL? {
    guard let package, package.isOutdated else { return nil }
    return [package.repo, package.homepage, package.docs]
        .compactMap(mainWindowGitHubRepoReleaseNotesURL)
        .first
}

private func mainWindowWebURL(_ string: String?) -> URL? {
    guard let string, let url = URL(string: string), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host() != nil else {
        return nil
    }
    return url
}

private func mainWindowGitHubRepoReleaseNotesURL(_ string: String?) -> URL? {
    guard let url = mainWindowWebURL(string), url.host()?.lowercased() == "github.com" else { return nil }
    let parts = url.pathComponents.filter { $0 != "/" }
    guard parts.count >= 2, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
    let repo = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
    components.scheme = "https"
    components.host = "github.com"
    components.path = "/" + parts[0] + "/" + repo + "/releases/latest"
    components.query = nil
    components.fragment = nil
    return components.url
}

enum RemoteHostSection: String, CaseIterable, Identifiable, Sendable {
    case installed
    case outdated

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var systemImage: String { self == .outdated ? "clock" : "shippingbox" }
}

enum MainWindowSidebarSelection: Hashable, Sendable {
    case local(MainWindowSection)
    case remote(hostID: UUID, section: RemoteHostSection)
}

struct RemoteHostState: Equatable, Sendable {
    var inventory: PackageInventory?
    var hostDescription: String?
    var systemPackageManager: PackageManagerKind?
    var canManageSystemPackages: Bool?
    var isLoading = false
    var error: String?
}

struct RemoteUninstallConfirmation: Equatable, Sendable {
    let host: RemoteHost
    let package: ManagedPackage
}

enum RemoteHostConfigurationError: LocalizedError, Equatable {
    case duplicateDestination

    var errorDescription: String? { "That SSH host is already configured." }
}

private enum RemotePackageAction {
    case update
    case uninstall
    case updateAll
    case updateSelected([ManagedPackage])
}

private struct PackageActionIdentity: Equatable {
    let runID: UUID?
    let kind: PackageHostActionKind
    let packageID: String
}

private final class CappedActionOutputBuffer: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var output = ""

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ chunk: String) -> Bool {
        guard !chunk.isEmpty else { return false }
        lock.withLock {
            output.append(contentsOf: chunk)
            let threshold = limit + min(limit / 4, 16_384)
            if output.count > threshold { output = String(output.suffix(limit)) }
        }
        return true
    }

    var value: String { lock.withLock { output.count > limit ? String(output.suffix(limit)) : output } }
}

@MainActor
final class MainWindowModel: NSObject, ObservableObject {
    static let defaultDashboardBlogURL = URL(string: "https://mxcl.dev/package-manager-manager/blog/index.json")!

    @Published var selectedSection: MainWindowSection = .home
    @Published private(set) var selectedRemoteHostID: UUID?
    @Published private(set) var selectedRemoteSection: RemoteHostSection?
    @Published private(set) var remoteHosts: [RemoteHost]
    @Published private(set) var remoteHostStates: [UUID: RemoteHostState] = [:]
    @Published private(set) var pendingRemoteUninstall: RemoteUninstallConfirmation?
    @Published var showsHostManagement = false
    @Published private(set) var packages: [ManagedPackage] = []
    @Published private(set) var selectedPackage: ManagedPackage?
    @Published private(set) var selectedPackageIDs: Set<String> = []
    @Published var selectedLinkTab: MainWindowLinkTab?
    @Published private(set) var isReloading = true
    @Published private(set) var loadingManagers = Set(PackageManagerKind.localCases)
    @Published private(set) var errors: [String] = []
    @Published private(set) var isLoadingSelectedPackageMetadata = false
    @Published private(set) var selectedPackageDossier: PackageDossierPage?
    @Published private(set) var selectedPackageDossierError: String?
    @Published private(set) var selectedPackageConfigurationLocations: [MainWindowConfigurationLocation] = []
    @Published private(set) var installingPackageName: String?
    @Published private(set) var uninstallingPackageName: String?
    @Published private(set) var updatingPackageName: String?
    @Published private(set) var packageActionCommand: String?
    @Published private(set) var packageActionOutput = ""
    @Published private(set) var packageActionError: String?
    @Published private(set) var discoverPackageIDToScrollIntoView: String?
    @Published private(set) var dashboardBlogEntries: [DashboardBlogEntry] = []
    @Published private(set) var dashboardBlogEntriesAreLoading = false
    @Published private(set) var pendingInstallPackConfirmation: MainWindowInstallPackConfirmation?
    @Published var searchText = ""
    @Published var showsCategoryCLIs = true {
        didSet { reconcilePackageSelection() }
    }
    @Published var showsCategoryGUIs = true {
        didSet { reconcilePackageSelection() }
    }
    @Published private(set) var setupOffer: ManagerSetupOffer?
    /// The manager whose detection is still running, if it could yet produce an offer.
    @Published private(set) var setupDetectingManager: PackageManagerKind?
    private var cargoSetup = CargoSetupState()
    /// The helper the host reports installing, if any.
    private var installingHelper: CargoHelper?
    private var setupDetectionTask: Task<Void, Never>?

    nonisolated private static let newUpdatedLastClickedAtDefaultsKey = "MainWindowModel.newUpdatedLastClickedAt"
    nonisolated private static let remoteHostsDefaultsKey = "MainWindowModel.remoteHosts"

    private var inventory = PackageInventory(packages: [])
    private var packageIndex = PackageIndex.empty
    private var installedPackageFirstSeenAtByID: [String: Date]?
    private var hasInventory = false
    private var pendingPackageURLCommand: MainWindowPackageURLCommand?
    private var pendingDiscoverPackageScroll = false
    private var packageSelectionAnchorID: String?
    private var newUpdatedLastClickedAt: Date?
    private var newUpdatedSelectionDisplayCount: Int?
    private let userDefaults: UserDefaults
    private let preferencesStore: PackagePreferencesStore
    /// Injectable so tests can drive detection's timing; shells out in production.
    private let detectCargoSetup: @Sendable (PackagePreferences) -> CargoSetupState
    private let store: PackageHostStore
    private let bundledCatalog: [ManagedPackage]
    private let dossierClient: PackageDossierClient?
    private let remoteClient: RemoteSSHClient
    private var dossierTask: Task<Void, Never>?
    private var dashboardBlogEntriesTask: Task<Void, Never>?
    private var remoteTasks: [UUID: Task<Void, Never>] = [:]
    private var remoteActionTask: Task<Void, Never>?
    private var remoteActionHostID: UUID?
    private var remoteActionID: UUID?
    private var localActionIdentity: PackageActionIdentity?
    private var remoteActionOutputBuffer = CappedActionOutputBuffer(limit: 100_000)
    private var lastRemoteActionOutputPublishAt = Date.distantPast
    private var pendingRemoteActionOutputPublishTask: Task<Void, Never>?
    private var hasUnpublishedRemoteActionOutput = false
    private let notificationCenter = DistributedNotificationCenter.default()
    private static let actionOutputLimit = 100_000
    private static let actionOutputPublishInterval: TimeInterval = 0.1

    init(
        userDefaults: UserDefaults = .standard,
        store: PackageHostStore = PackageHostStore(),
        bundledCatalog: [ManagedPackage] = PackageHostStore.bundledCatalog(),
        dossierClient: PackageDossierClient? = nil,
        dashboardBlogURL: URL? = nil,
        remoteClient: RemoteSSHClient = RemoteSSHClient(),
        preferencesStore: PackagePreferencesStore = PackagePreferencesStore(),
        detectCargoSetup: @escaping @Sendable (PackagePreferences) -> CargoSetupState
            = { CargoSetupState.detect(preferences: $0) }
    ) {
        self.preferencesStore = preferencesStore
        self.detectCargoSetup = detectCargoSetup
        self.userDefaults = userDefaults
        newUpdatedLastClickedAt = userDefaults.object(forKey: Self.newUpdatedLastClickedAtDefaultsKey) as? Date
        remoteHosts = userDefaults.data(forKey: Self.remoteHostsDefaultsKey)
            .flatMap { try? JSONDecoder().decode([RemoteHost].self, from: $0) } ?? []
        self.store = store
        self.bundledCatalog = bundledCatalog
        self.dossierClient = dossierClient
        self.remoteClient = remoteClient
        super.init()
#if DEBUG
        let isTerminalDemo = ProcessInfo.processInfo.environment["PMM_TERMINAL_DEMO"] == "1"
        if isTerminalDemo {
            showTerminalDemo()
        } else {
            syncFromHost()
            if let dashboardBlogURL {
                loadDashboardBlogEntries(from: dashboardBlogURL)
            }
            notificationCenter.addObserver(self, selector: #selector(hostSnapshotChanged(_:)), name: PackageHostNotifications.snapshotChanged, object: nil)
            notificationCenter.addObserver(self, selector: #selector(hostActionOutputChanged(_:)), name: PackageHostNotifications.actionOutputChanged, object: nil)
            reloadRemoteHosts()
        }
#else
        syncFromHost()
        if let dashboardBlogURL {
            loadDashboardBlogEntries(from: dashboardBlogURL)
        }
        notificationCenter.addObserver(self, selector: #selector(hostSnapshotChanged(_:)), name: PackageHostNotifications.snapshotChanged, object: nil)
        notificationCenter.addObserver(self, selector: #selector(hostActionOutputChanged(_:)), name: PackageHostNotifications.actionOutputChanged, object: nil)
        reloadRemoteHosts()
#endif
    }

    deinit {
        dossierTask?.cancel()
        dashboardBlogEntriesTask?.cancel()
        remoteTasks.values.forEach { $0.cancel() }
        remoteActionTask?.cancel()
        pendingRemoteActionOutputPublishTask?.cancel()
        notificationCenter.removeObserver(self)
    }

    var sidebarSelection: MainWindowSidebarSelection {
        if let selectedRemoteHostID, let selectedRemoteSection {
            return .remote(hostID: selectedRemoteHostID, section: selectedRemoteSection)
        }
        return .local(selectedSection)
    }

    var activeSidebarSection: MainWindowSection? { selectedRemoteHostID == nil ? selectedSection : nil }
    var isRemoteSelection: Bool { selectedRemoteHostID != nil }
    var showsLocalFilesystemActions: Bool { !isRemoteSelection }
    var showsDashboard: Bool { !isRemoteSelection && selectedSection == .home }
    var selectedRemoteHost: RemoteHost? { remoteHosts.first { $0.id == selectedRemoteHostID } }
    private var selectedRemoteState: RemoteHostState? { selectedRemoteHostID.flatMap { remoteHostStates[$0] } }

    var displayedSectionTitle: String {
        guard let host = selectedRemoteHost, let selectedRemoteSection else { return selectedSection.title }
        return "\(host.displayName) · \(selectedRemoteSection.title)"
    }

    var hasMultipleHosts: Bool { !remoteHosts.isEmpty }

    nonisolated static var localSidebarHostName: String {
        sidebarHostName(
            localHostName: SCDynamicStoreCopyLocalHostName(nil) as String?,
            fallback: ProcessInfo.processInfo.hostName
        )
    }

    nonisolated static func sidebarHostName(localHostName: String?, fallback: String) -> String {
        let name = localHostName.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        let hostname = droppingLocalSuffix(name)
        return hostname.prefix(1).uppercased() + hostname.dropFirst()
    }

    nonisolated static func droppingLocalSuffix(_ value: String) -> String {
        value.lowercased().hasSuffix(".local") ? String(value.dropLast(6)) : value
    }

    var displayedPackagesAreLoading: Bool {
        if let hostID = selectedRemoteHostID {
            return remoteHostStates[hostID]?.isLoading == true
        }
        return activeSidebarSection.map(isLoadingCount(for:)) == true
    }

    var displayedPackagesError: String? {
        selectedRemoteHostID.flatMap { remoteHostStates[$0]?.error }
    }

    var dashboardIsLoadingData: Bool {
        !hasInventory || !loadingManagers.isEmpty
    }

    var dashboardCatalogIsLoading: Bool {
        !packageIndex.hasCatalog
    }

    var dashboardInstalledCount: Int? {
        hasInventory ? packages.count : nil
    }

    var dashboardInstalledThisWeekText: String? {
        guard hasInventory, let installedPackageFirstSeenAtByID else { return nil }
        guard let week = Calendar.current.dateInterval(of: .weekOfYear, for: Date()) else { return nil }
        let count = packages.filter { package in
            installedPackageFirstSeenAtByID[package.id].map(week.contains) == true
        }.count
        return count > 0 ? "+\(count) this week" : nil
    }

    var dashboardOutdatedCount: Int? {
        hasInventory ? count(for: .outdated) : nil
    }

    var dashboardActiveEcosystemCount: Int? {
        hasInventory ? MainWindowSection.managerSections.filter { (count(for: $0) ?? 0) > 0 }.count : nil
    }

    var dashboardLastUpdatedText: String? {
        guard hasInventory else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Last updated: \(formatter.localizedString(for: inventory.generatedAt, relativeTo: Date()))"
    }

    var dashboardWhatsNewPackages: [ManagedPackage] {
        Array((packageIndex.packagesBySection[.newUpdated] ?? []).prefix(5))
    }

    var dashboardRecommendedPackages: [ManagedPackage] {
        Array(packageIndex.recommendedPackages.prefix(3))
    }

    var dashboardBlogPosts: [DashboardBlogEntry] {
        dashboardBlogEntries.filter { $0.category == .blog }
    }

    var dashboardInstallPacks: [DashboardBlogEntry] {
        dashboardBlogEntries.filter { $0.category == .pack }
    }

    var visibleManagerSections: [MainWindowSection] {
        if isReloading { return MainWindowSection.managerSections }
        return MainWindowSection.managerSections.filter { isLoadingCount(for: $0) || (count(for: $0) ?? 0) > 0 }
    }

    var visibleCategorySections: [MainWindowSection] {
        packageIndex.categorySections
    }

    var displayedPackages: [ManagedPackage] {
        if let hostID = selectedRemoteHostID, let section = selectedRemoteSection {
            let packages = remoteHostStates[hostID]?.inventory?.packages ?? []
            let index = PackageIndex(packages: packages, catalogPackages: [], newUpdatedLastClickedAt: nil)
            let localSection: MainWindowSection = section == .outdated ? .outdated : .installed
            let values = index.packagesBySection[localSection] ?? []
            let query = searchQuery
            return query.isEmpty ? values : values.filter { matchesSearch($0, query: query) }
        }
        return packages(in: selectedSection)
    }

    var showsUpdateAllOutdatedPackages: Bool {
        selectedRemoteSection == .outdated || (!isRemoteSelection && selectedSection == .outdated)
    }

    var canUpdateAllOutdatedPackages: Bool {
        guard showsUpdateAllOutdatedPackages, !displayedPackagesAreLoading, !isPackageActionRunning else { return false }
        return !packagesToUpdate.isEmpty && (!hasMultipleSelectedPackages || packagesToUpdate.count == selectedPackageIDs.count)
    }

    var hasMultipleSelectedPackages: Bool { selectedPackageIDs.count > 1 }
    var updateOutdatedPackagesButtonTitle: String {
        if hasMultipleSelectedPackages { return "Update Selected" }
        return selectedRemoteState?.systemPackageManager?.isLinuxSystem == true ? "Update System" : "Update All"
    }

    func reload() {
        PackageHostNotifications.postRefreshRequested()
        reloadRemoteHosts(ignoringAppCache: true)
    }

    func showHostManagement() {
        showsHostManagement = true
    }

    @discardableResult
    func saveRemoteHost(id: UUID? = nil, name: String?, destination: String) throws -> RemoteHost {
        let host = try RemoteHost(id: id ?? UUID(), name: name, destination: destination)
        guard !remoteHosts.contains(where: { $0.id != host.id && $0.destination == host.destination }) else {
            throw RemoteHostConfigurationError.duplicateDestination
        }
        if let index = remoteHosts.firstIndex(where: { $0.id == host.id }) {
            let destinationChanged = remoteHosts[index].destination != host.destination
            remoteHosts[index] = host
            if destinationChanged { remoteHostStates[host.id] = nil }
        } else {
            remoteHosts.append(host)
        }
        remoteHosts.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        persistRemoteHosts()
        refreshRemoteHost(host.id)
        return host
    }

    func removeRemoteHost(_ hostID: UUID) {
        guard remoteActionHostID != hostID else { return }
        remoteTasks.removeValue(forKey: hostID)?.cancel()
        remoteHosts.removeAll { $0.id == hostID }
        remoteHostStates[hostID] = nil
        persistRemoteHosts()
        if selectedRemoteHostID == hostID { selectSection(.home) }
    }

    func reloadRemoteHosts(ignoringAppCache: Bool = false) {
        for host in remoteHosts where remoteActionHostID != host.id {
            refreshRemoteHost(host.id, ignoringAppCache: ignoringAppCache)
        }
    }

    func refreshRemoteHost(_ hostID: UUID, ignoringAppCache: Bool = false) {
        guard remoteActionHostID != hostID, let host = remoteHosts.first(where: { $0.id == hostID }) else { return }
        remoteTasks.removeValue(forKey: hostID)?.cancel()
        var state = remoteHostStates[hostID] ?? RemoteHostState()
        state.isLoading = true
        state.error = nil
        remoteHostStates[hostID] = state
        let remoteClient = remoteClient
        remoteTasks[hostID] = Task { [weak self] in
            do {
                let response = try await remoteClient.inventory(on: host, ignoringAppCache: ignoringAppCache)
                guard !Task.isCancelled else { return }
                self?.remoteHostStates[hostID] = RemoteHostState(
                    inventory: response.inventory,
                    hostDescription: response.hostDescription,
                    systemPackageManager: response.systemPackageManager,
                    canManageSystemPackages: response.canManageSystemPackages
                )
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                var failed = self?.remoteHostStates[hostID] ?? RemoteHostState()
                failed.isLoading = false
                failed.error = error.localizedDescription
                self?.remoteHostStates[hostID] = failed
            }
            self?.remoteTasks[hostID] = nil
        }
    }

    private func persistRemoteHosts() {
        guard let data = try? JSONEncoder().encode(remoteHosts) else { return }
        userDefaults.set(data, forKey: Self.remoteHostsDefaultsKey)
    }

    func selectSection(_ section: MainWindowSection) {
        cancelDiscoverPackageScroll()
        if section == .newUpdated {
            newUpdatedSelectionDisplayCount = newUpdatedUnreadCount
            recordNewUpdatedSidebarClick()
        } else {
            newUpdatedSelectionDisplayCount = nil
        }
        selectedRemoteHostID = nil
        selectedRemoteSection = nil
        selectedSection = section
        packageSelectionAnchorID = nil
        selectedPackageIDs = []
        selectedPackage = nil
        selectedLinkTab = nil
        clearDossier()
    }

    func selectRemoteHost(_ hostID: UUID, section: RemoteHostSection) {
        guard remoteHosts.contains(where: { $0.id == hostID }) else { return }
        cancelDiscoverPackageScroll()
        selectedRemoteHostID = hostID
        selectedRemoteSection = section
        packageSelectionAnchorID = nil
        selectedPackageIDs = []
        selectedPackage = nil
        selectedLinkTab = nil
        clearDossier()
    }

    func select(_ package: ManagedPackage, extendingSelection: Bool = false, selectingRange: Bool = false) {
        cancelDiscoverPackageScroll()
        guard showsUpdateAllOutdatedPackages, extendingSelection || selectingRange else {
            packageSelectionAnchorID = package.id
            selectPackages([package.id])
            return
        }

        if selectingRange,
           let anchorID = packageSelectionAnchorID,
           let anchorIndex = displayedPackages.firstIndex(where: { $0.id == anchorID }),
           let packageIndex = displayedPackages.firstIndex(where: { $0.id == package.id }) {
            let rangeIDs = Set(displayedPackages[min(anchorIndex, packageIndex)...max(anchorIndex, packageIndex)].map(\.id))
            selectPackages(extendingSelection ? selectedPackageIDs.union(rangeIDs) : rangeIDs)
        } else {
            packageSelectionAnchorID = package.id
            var ids = selectedPackageIDs
            if !ids.insert(package.id).inserted { ids.remove(package.id) }
            selectPackages(ids)
        }
    }

    func selectPackages(_ ids: Set<String>) {
        let availableIDs = Set(displayedPackages.map(\.id))
        var ids = ids.intersection(availableIDs)
        if !showsUpdateAllOutdatedPackages, ids.count > 1 {
            ids = [ids.subtracting(selectedPackageIDs).first ?? ids.first!]
        }
        selectedPackageIDs = ids
        guard ids.count == 1, let package = displayedPackages.first(where: { ids.contains($0.id) }) else {
            selectedPackage = nil
            selectedLinkTab = nil
            clearDossier()
            return
        }
        selectedPackage = package
        selectedLinkTab = nil
        loadDossier(for: package)
    }

    func openDashboardPackage(_ package: ManagedPackage) {
        let section = package.category.map(MainWindowSection.category) ?? .newUpdated
        selectSection(section)
        let package = packageIndex.packagesBySection[section]?.first { $0.id == package.id } ?? package
        select(package)
    }

    @discardableResult
    func openDiscoverPackage(_ package: DiscoverFeedPackage, installing: Bool = false) -> Bool {
        guard let request = MainWindowPackageURLRequest(identifier: package.id) else { return false }
        let command: MainWindowPackageURLCommand = installing ? .install([request]) : .select(request)
        pendingPackageURLCommand = command
        pendingDiscoverPackageScroll = false
        let didOpen = openPackageURLCommand(command)
        if didOpen {
            requestDiscoverPackageScroll()
        } else {
            pendingDiscoverPackageScroll = true
        }
        return didOpen
    }

    func isDiscoverPackageInstalled(_ package: DiscoverFeedPackage) -> Bool {
        guard let request = MainWindowPackageURLRequest(identifier: package.id) else { return false }
        return packages.contains(where: request.matches)
    }

    @discardableResult
    func openPackageURL(_ url: URL) -> Bool {
        guard let command = MainWindowPackageURLCommand(url: url) else { return false }
        cancelDiscoverPackageScroll()
        pendingPackageURLCommand = command
        return openPackageURLCommand(command)
    }

    func consumeDiscoverPackageScrollRequest() {
        discoverPackageIDToScrollIntoView = nil
    }

    private func requestDiscoverPackageScroll() {
        discoverPackageIDToScrollIntoView = selectedPackage?.id
        pendingDiscoverPackageScroll = false
    }

    private func cancelDiscoverPackageScroll() {
        discoverPackageIDToScrollIntoView = nil
        pendingDiscoverPackageScroll = false
    }

    func selectAdjacentPackage(offset: Int) -> Bool {
        guard offset != 0, let selectedPackage else { return false }
        let packages = displayedPackages
        guard !packages.isEmpty else { return false }

        let index = packages.firstIndex { $0.id == selectedPackage.id } ?? (offset > 0 ? -1 : packages.count)
        let nextIndex = min(max(index + offset, 0), packages.count - 1)
        if nextIndex != index {
            select(packages[nextIndex])
        }
        return true
    }

    func count(for section: MainWindowSection) -> Int? {
        if let count = filteredCount(for: section) { return count }
        return switch section {
        case .home, .about: nil
        case .newUpdated: newUpdatedSelectionDisplayCount ?? newUpdatedUnreadCount
        default: packageIndex.countsBySection[section]
        }
    }

    func count(for section: RemoteHostSection, on hostID: UUID) -> Int? {
        guard let inventory = remoteHostStates[hostID]?.inventory else { return nil }
        let packages = section == .outdated ? inventory.outdatedPackages : inventory.packages
        let query = searchQuery
        return query.isEmpty ? packages.count : packages.filter { matchesSearch($0, query: query) }.count
    }

    func isLoading(_ hostID: UUID) -> Bool {
        remoteHostStates[hostID]?.isLoading == true
    }

    func isRunningAction(on hostID: UUID) -> Bool {
        remoteActionHostID == hostID
    }

    func error(for hostID: UUID) -> String? {
        remoteHostStates[hostID]?.error
    }

    func isLoadingCount(for section: MainWindowSection) -> Bool {
        !section.packageManagers.isDisjoint(with: loadingManagers)
    }

    func install(_ package: ManagedPackage) {
        guard canInstall(package), !isPackageActionRunning else { return }
        PackageHostNotifications.postInstallRequested(packageID: package.id)
    }

    func uninstall(_ package: ManagedPackage) {
        guard canUninstall(package), !isPackageActionRunning else { return }
        if let host = selectedRemoteHost {
            pendingRemoteUninstall = RemoteUninstallConfirmation(host: host, package: package)
            return
        }
        PackageHostNotifications.postUninstallRequested(packageID: package.id)
    }

    /// The setup offer to show above the current section, if any.
    ///
    /// Gated on activeSidebarSection, not selectedSection: the latter keeps its value while a
    /// remote host is selected, and helpers install on this Mac, not the one being viewed.
    func setupOffer(for section: MainWindowSection) -> ManagerSetupOffer? {
        guard activeSidebarSection == section, let setupOffer, mainWindowSetupSection(setupOffer.manager) == section else {
            return nil
        }
        return setupOffer
    }

    /// True while a section that could still produce an offer is waiting on detection, so the card
    /// slot can hold a spinner rather than render "not detected yet" as "nothing to offer".
    func isDetectingSetupOffer(for section: MainWindowSection) -> Bool {
        guard activeSidebarSection == section, setupOffer == nil, let manager = setupDetectingManager else {
            return false
        }
        return mainWindowSetupSection(manager) == section
    }

    /// Detecting tools shells out, so it never runs on the main thread.
    ///
    /// One detection at a time: this is kicked on every section change, and an older run landing
    /// after a newer one would put back the tool status from before a helper was installed.
    func refreshSetupOffers() {
        setupDetectionTask?.cancel()
        setupDetectionTask = Task { [preferencesStore, detectCargoSetup] in
            let detected = await Task.detached(priority: .utility) {
                detectCargoSetup(preferencesStore.load())
            }.value
            guard !Task.isCancelled else { return }
            cargoSetup = cargoSetup.merging(status: detected.status, preferences: detected.preferences)
            refreshSetupOffer()
        }
    }

    private func refreshSetupOffer() {
        // Recomputed on every snapshot, so no intermediate array.
        let installedManagers = Set(inventory.packages.lazy.map(\.manager))
        setupOffer = cargoSetup.offer(installedManagers: installedManagers)?.setupOffer
        // Cargo is the only manager with an offer, so the mapping to a section lives here rather
        // than behind a dispatch layer that would have exactly one case.
        setupDetectingManager = cargoSetup.isAwaitingDetection(installedManagers: installedManagers)
            ? .cargoInstall
            : nil
    }

    var isInstallingHelper: Bool { installingHelper != nil }

    /// The host refuses a helper install that arrives while a refresh or another action is running,
    /// so the card disables its button rather than offering a click that goes nowhere.
    var canInstallHelper: Bool { !isReloading && !isPackageActionRunning }

    func installHelper(_ id: String) {
        guard canInstallHelper, !isInstallingHelper else { return }
        // Deliberately no optimistic state: the host is the authority on whether the install
        // actually started, and claiming it here would show "Installing…" over a dropped request.
        PackageHostNotifications.postHelperInstallRequested(id)
    }

    func dismissHelper(_ id: String) {
        cargoSetup.preferences.dismiss(id)
        refreshSetupOffer()
        // The store owns both the ordering and the IO, so there is no background task here to
        // reorder two dismissals made back to back.
        preferencesStore.save(cargoSetup.preferences)
    }

    func update(_ package: ManagedPackage) {
        guard canUpdate(package), !isPackageActionRunning else { return }
        if let host = selectedRemoteHost {
            runRemoteAction(.update, package: package, host: host)
            return
        }
        PackageHostNotifications.postUpdateRequested(packageID: package.id)
    }

    func updateAllOutdatedPackages() {
        guard canUpdateAllOutdatedPackages else { return }
        if let host = selectedRemoteHost {
            if hasMultipleSelectedPackages {
                runRemoteAction(.updateSelected(packagesToUpdate), package: nil, host: host)
                return
            }
            runRemoteAction(.updateAll, package: nil, host: host)
            return
        }
        PackageHostNotifications.postUpdateAllRequested(packageIDs: hasMultipleSelectedPackages ? packagesToUpdate.map(\.id) : [])
    }

    func confirmRemoteUninstall() {
        guard let confirmation = pendingRemoteUninstall else { return }
        pendingRemoteUninstall = nil
        runRemoteAction(.uninstall, package: confirmation.package, host: confirmation.host)
    }

    func cancelRemoteUninstall() {
        pendingRemoteUninstall = nil
    }

    private func runRemoteAction(_ action: RemotePackageAction, package: ManagedPackage?, host: RemoteHost) {
        guard !isPackageActionRunning else { return }
        switch action {
        case .update, .uninstall: guard package != nil else { return }
        case .updateAll, .updateSelected: break
        }
        remoteTasks.removeValue(forKey: host.id)?.cancel()
        let actionID = UUID()
        let outputBuffer = CappedActionOutputBuffer(limit: Self.actionOutputLimit)
        remoteActionHostID = host.id
        remoteActionID = actionID
        remoteActionOutputBuffer = outputBuffer
        pendingRemoteActionOutputPublishTask?.cancel()
        pendingRemoteActionOutputPublishTask = nil
        lastRemoteActionOutputPublishAt = .distantPast
        hasUnpublishedRemoteActionOutput = false
        packageActionOutput = ""
        packageActionError = nil
        switch action {
        case .update:
            updatingPackageName = package?.displayName
            packageActionCommand = "ssh \(host.destination) — pmmctl update \(package?.displayName ?? "package")"
        case .uninstall:
            uninstallingPackageName = package?.displayName
            packageActionCommand = "ssh \(host.destination) — pmmctl uninstall \(package?.displayName ?? "package")"
        case .updateAll:
            updatingPackageName = "All outdated packages on \(host.displayName)"
            packageActionCommand = "ssh \(host.destination) — pmmctl update-all"
        case .updateSelected(let packages):
            updatingPackageName = "\(packages.count) selected packages on \(host.displayName)"
            packageActionCommand = "ssh \(host.destination) — update selected"
        }

        let remoteClient = remoteClient
        let progress: @Sendable (String) -> Void = { [weak self, outputBuffer] chunk in
            guard outputBuffer.append(chunk) else { return }
            Task { @MainActor in self?.remoteActionOutputDidChange(actionID: actionID, buffer: outputBuffer) }
        }
        remoteActionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response: RemoteControlResponse
                switch action {
                case .update:
                    response = try await remoteClient.update(package!, on: host, onProgress: progress)
                case .uninstall:
                    response = try await remoteClient.uninstall(package!, on: host, onProgress: progress)
                case .updateAll:
                    response = try await remoteClient.updateAll(on: host, onProgress: progress)
                case .updateSelected(let packages):
                    var inventory = remoteHostStates[host.id]?.inventory ?? PackageInventory(packages: [])
                    var failures: [RemoteControlFailure] = []
                    for package in packages {
                        try Task.checkCancellation()
                        do {
                            let result = try await remoteClient.update(package, on: host, onProgress: progress)
                            inventory = result.inventory
                            failures += result.failures
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            failures.append(RemoteControlFailure(packageID: package.id, message: "\(package.displayName): \(error.localizedDescription)"))
                        }
                    }
                    response = RemoteControlResponse(inventory: inventory, failures: failures)
                }
                let previousState = remoteHostStates[host.id]
                remoteHostStates[host.id] = RemoteHostState(
                    inventory: response.inventory,
                    hostDescription: response.hostDescription ?? previousState?.hostDescription,
                    systemPackageManager: response.systemPackageManager ?? previousState?.systemPackageManager,
                    canManageSystemPackages: response.canManageSystemPackages ?? previousState?.canManageSystemPackages,
                    error: response.failures.isEmpty ? nil : response.failures.map(\.message).joined(separator: "\n")
                )
                if !response.failures.isEmpty {
                    packageActionError = response.failures.map(\.message).joined(separator: "\n")
                }
                reconcilePackageSelection()
            } catch is CancellationError {
            } catch {
                var state = remoteHostStates[host.id] ?? RemoteHostState()
                state.isLoading = false
                state.error = error.localizedDescription
                remoteHostStates[host.id] = state
                packageActionError = error.localizedDescription
            }
            flushRemoteActionOutput(buffer: outputBuffer)
            updatingPackageName = nil
            uninstallingPackageName = nil
            remoteActionHostID = nil
            remoteActionID = nil
            remoteActionTask = nil
        }
    }

    private func remoteActionOutputDidChange(actionID: UUID, buffer: CappedActionOutputBuffer) {
        guard remoteActionID == actionID, remoteActionOutputBuffer === buffer else { return }
        hasUnpublishedRemoteActionOutput = true
        publishRemoteActionOutputSoon()
    }

    private func publishRemoteActionOutputSoon() {
        let now = Date()
        if now.timeIntervalSince(lastRemoteActionOutputPublishAt) >= Self.actionOutputPublishInterval {
            publishRemoteActionOutputNow(at: now)
            return
        }
        guard pendingRemoteActionOutputPublishTask == nil else { return }
        let delay = Self.actionOutputPublishInterval - now.timeIntervalSince(lastRemoteActionOutputPublishAt)
        pendingRemoteActionOutputPublishTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self else { return }
            self.pendingRemoteActionOutputPublishTask = nil
            self.publishRemoteActionOutputNow(at: Date())
        }
    }

    private func publishRemoteActionOutputNow(at date: Date) {
        guard hasUnpublishedRemoteActionOutput else { return }
        hasUnpublishedRemoteActionOutput = false
        lastRemoteActionOutputPublishAt = date
        packageActionOutput = remoteActionOutputBuffer.value
    }

    private func flushRemoteActionOutput(buffer: CappedActionOutputBuffer) {
        pendingRemoteActionOutputPublishTask?.cancel()
        pendingRemoteActionOutputPublishTask = nil
        guard remoteActionOutputBuffer === buffer else { return }
        hasUnpublishedRemoteActionOutput = true
        publishRemoteActionOutputNow(at: Date())
    }

    func dismissPackageAction() {
        guard !isPackageActionRunning else { return }
        packageActionCommand = nil
        packageActionOutput = ""
        packageActionError = nil
    }

    func confirmPendingInstallPack() {
        guard let pendingInstallPackConfirmation else { return }
        self.pendingInstallPackConfirmation = nil
        PackageHostNotifications.postInstallManyRequested(packageIDs: pendingInstallPackConfirmation.packageIDs)
    }

    func cancelPendingInstallPack() {
        pendingInstallPackConfirmation = nil
    }

    func canInstall(_ package: ManagedPackage) -> Bool {
        let identifier = package.catalogIdentifier ?? package.identifier
        return !isRemoteSelection && PackageInstaller.supports(package) && !packages.contains {
            $0.identifier == identifier || $0.catalogIdentifier == identifier || $0.identifier == package.identifier
        }
    }

    func canUpdate(_ package: ManagedPackage) -> Bool {
        guard PackageUpdater.supports(package) else { return false }
        guard package.manager.isLinuxSystem else { return true }
        return selectedRemoteState?.systemPackageManager == package.manager
            && selectedRemoteState?.canManageSystemPackages == true
    }

    func canUninstall(_ package: ManagedPackage) -> Bool {
        guard PackageUninstaller.supports(package) else { return false }
        guard package.manager.isLinuxSystem else { return true }
        return selectedRemoteState?.systemPackageManager == package.manager
            && selectedRemoteState?.canManageSystemPackages == true
    }

    func isReadOnlySystemPackage(_ package: ManagedPackage) -> Bool {
        package.manager.isLinuxSystem && isRemoteSelection && selectedRemoteState?.canManageSystemPackages == false
    }

    private var isPackageActionRunning: Bool {
        installingPackageName != nil || uninstallingPackageName != nil || updatingPackageName != nil
    }

    private var newUpdatedUnreadCount: Int? {
        packageIndex.newUpdatedUnreadCount
    }

    private var updatableOutdatedPackages: [ManagedPackage] {
        if isRemoteSelection {
            let packages = displayedPackages.filter(canUpdate)
            guard !hasMultipleSelectedPackages,
                  let manager = selectedRemoteState?.systemPackageManager,
                  manager.isLinuxSystem else { return packages }
            return packages.filter { $0.manager == manager }
        }
        return (packageIndex.packagesBySection[.outdated] ?? []).filter(PackageUpdater.supports)
    }

    private var packagesToUpdate: [ManagedPackage] {
        guard hasMultipleSelectedPackages else { return updatableOutdatedPackages }
        return displayedPackages.filter { selectedPackageIDs.contains($0.id) && canUpdate($0) }
    }

    private func reconcilePackageSelection() {
        selectedPackageIDs.formIntersection(displayedPackages.map(\.id))
        guard selectedPackageIDs.count == 1,
              let package = displayedPackages.first(where: { selectedPackageIDs.contains($0.id) }) else {
            selectedPackage = nil
            selectedLinkTab = nil
            clearDossier()
            return
        }
        let selectionChanged = selectedPackage?.id != package.id
        selectedPackage = package
        if selectionChanged {
            selectedLinkTab = nil
            loadDossier(for: package)
        }
    }

    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fetchDashboardBlogEntries(from url: URL) async throws -> [DashboardBlogEntry] {
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode(DashboardBlogIndex.self, from: data).posts
    }

    private func loadDashboardBlogEntries(from url: URL) {
        dashboardBlogEntriesTask?.cancel()
        dashboardBlogEntriesAreLoading = true
        dashboardBlogEntriesTask = Task { [url] in
            let result = await Task.detached(priority: .utility) { () -> Result<[DashboardBlogEntry], Error> in
                do {
                    return .success(try await Self.fetchDashboardBlogEntries(from: url))
                } catch {
                    return .failure(error)
                }
            }.value

            guard !Task.isCancelled else { return }
            dashboardBlogEntriesAreLoading = false
            if case .success(let posts) = result {
                dashboardBlogEntries = posts
            } else {
                dashboardBlogEntries = []
            }
        }
    }

    private func packages(in section: MainWindowSection) -> [ManagedPackage] {
        var packages = packageIndex.packagesBySection[section] ?? []
        if section.categoryIdentifier != nil {
            packages = packages.filter {
                mainWindowManagerSection(for: $0) == .apps ? showsCategoryGUIs : showsCategoryCLIs
            }
        }
        let query = searchQuery
        guard !query.isEmpty else { return packages }
        return packages.filter { matchesSearch($0, query: query) }
    }

    private func filteredCount(for section: MainWindowSection) -> Int? {
        let query = searchQuery
        let categoryIsFiltered = section.categoryIdentifier != nil && (!showsCategoryCLIs || !showsCategoryGUIs)
        guard !query.isEmpty || categoryIsFiltered else { return nil }
        return packages(in: section).count
    }

    private func matchesSearch(_ package: ManagedPackage, query: String) -> Bool {
        package.displayName.localizedCaseInsensitiveContains(query)
            || package.identifier.localizedCaseInsensitiveContains(query)
            || (package.catalogIdentifier?.localizedCaseInsensitiveContains(query) == true)
            || (package.summary?.localizedCaseInsensitiveContains(query) == true)
            || package.executableNames.contains { $0.localizedCaseInsensitiveContains(query) }
            || (package.binaryPath?.localizedCaseInsensitiveContains(query) == true)
    }

    @discardableResult
    private func openPackageURLCommand(_ command: MainWindowPackageURLCommand) -> Bool {
        switch command {
        case .select(let request):
            openPackage(request)
        case .install(let requests):
            install(requests)
        }
    }

    @discardableResult
    private func openPackage(_ request: MainWindowPackageURLRequest) -> Bool {
        guard let package = package(matching: request) else {
            selectSection(request.section)
            return false
        }
        let section = section(for: package, preferred: request.section)
        selectSection(section)
        let resolvedPackage = packageIndex.packagesBySection[section]?.first { $0.id == package.id } ?? package
        select(resolvedPackage)
        pendingPackageURLCommand = nil
        return true
    }

    @discardableResult
    private func install(_ requests: [MainWindowPackageURLRequest]) -> Bool {
        guard !isPackageActionRunning else { return false }
        guard hasInventory else {
            if let first = requests.first {
                selectSection(first.section)
            }
            return false
        }
        let installablePackages = requests.compactMap(package(matching:)).filter(canInstall)
        pendingPackageURLCommand = nil
        guard !installablePackages.isEmpty else {
            if let first = requests.first {
                _ = openPackage(first)
            }
            return false
        }
        openDashboardPackage(installablePackages[0])
        pendingInstallPackConfirmation = MainWindowInstallPackConfirmation(
            packageIDs: installablePackages.map(\.id),
            packageCount: installablePackages.count
        )
        return true
    }

    private func package(matching request: MainWindowPackageURLRequest) -> ManagedPackage? {
        (packageIndex.packagesBySection[request.section] ?? []).first(where: request.matches)
            ?? packageIndex.packagesBySection.values.lazy.flatMap { $0 }.first(where: request.matches)
    }

    private func section(for package: ManagedPackage, preferred: MainWindowSection) -> MainWindowSection {
        if packageIndex.packagesBySection[preferred]?.contains(where: { $0.id == package.id }) == true {
            return preferred
        }
        return package.category.map(MainWindowSection.category) ?? preferred
    }

    private func recordNewUpdatedSidebarClick() {
        let clickedAt = Date()
        newUpdatedLastClickedAt = clickedAt
        userDefaults.set(clickedAt, forKey: Self.newUpdatedLastClickedAtDefaultsKey)
    }

    func apply(inventory next: PackageInventory, index: PackageIndex, installedPackageFirstSeenAtByID: [String: Date]? = nil) {
        inventory = next
        packageIndex = index
        self.installedPackageFirstSeenAtByID = installedPackageFirstSeenAtByID
        hasInventory = true
        packages = next.packages
        errors = next.errors
        reconcilePackageSelection()
        if let pendingPackageURLCommand {
            let shouldScroll = pendingDiscoverPackageScroll
            if shouldScroll {
                if openPackageURLCommand(pendingPackageURLCommand) {
                    requestDiscoverPackageScroll()
                } else {
                    pendingDiscoverPackageScroll = true
                }
            } else {
                openPackageURLCommand(pendingPackageURLCommand)
            }
        }
        if selectedPackage == nil { clearDossier() }
    }

    func syncFromHost() {
        guard var snapshot = (try? store.load()) ?? (bundledCatalog.isEmpty ? nil : PackageHostSnapshot()) else {
            hasInventory = false
            installedPackageFirstSeenAtByID = nil
            isReloading = true
            loadingManagers = Set(PackageManagerKind.localCases)
            return
        }
        if snapshot.catalogPackages.isEmpty {
            snapshot.catalogPackages = bundledCatalog
        }
        apply(snapshot: snapshot)
    }

    func apply(snapshot: PackageHostSnapshot) {
        guard let inventory = snapshot.inventory else {
            hasInventory = false
            installedPackageFirstSeenAtByID = nil
            isReloading = true
            loadingManagers = Set(PackageManagerKind.localCases)
            packageIndex = PackageIndex(
                packages: [],
                catalogPackages: snapshot.catalogPackages,
                newUpdatedLastClickedAt: newUpdatedLastClickedAt
            )
            installingPackageName = nil
            uninstallingPackageName = nil
            updatingPackageName = nil
            installingHelper = nil
            packageActionCommand = nil
            packageActionOutput = ""
            return
        }
        apply(snapshot: snapshot, inventory: inventory)
    }

#if DEBUG
    func showTerminalDemo() {
        selectedSection = .installed
        installingPackageName = "terminal-output-demo"
        uninstallingPackageName = nil
        updatingPackageName = nil
        packageActionCommand = "brew install terminal-output-demo"

        func progress(_ name: String, marks: Int, status: String) -> String {
            let prefix = "\u{1B}[34m: \u{1B}[0mBottle \(name)"
            let visiblePrefix = ": Bottle \(name)"
            let suffix = "\(String(repeating: "#", count: marks)) \(status)"
            return prefix + String(repeating: " ", count: max(1, 80 - visiblePrefix.count - suffix.count)) + suffix
        }

        var output = "\u{1B}[?25l\u{1B}[34m==>\u{1B}[0m Downloading https://ghcr.io/v2/homebrew/core/terminal-output-demo/manifests/1.0.0\r\n"
        output += progress("alpha (1.0.0)", marks: 2, status: "Downloading 1.2MB/8.0MB") + "\r\n"
        output += progress("beta (2.0.0)", marks: 8, status: "Downloading 2.1MB/4.0MB") + "\r\n"
        for step in 3...8 {
            output += "\u{1B}[2A\r\u{1B}[2K" + progress("alpha (1.0.0)", marks: step, status: "Downloading \(step).0MB/8.0MB") + "\r\n"
            output += "\r\u{1B}[2K" + progress("beta (2.0.0)", marks: step + 6, status: "Downloading \(min(step, 4)).0MB/4.0MB") + "\r\n"
        }
        output += "\u{1B}[2A\r\u{1B}[2K" + progress("alpha (1.0.0)", marks: 10, status: "Downloaded 8.0MB") + "\r\n"
        output += "\r\u{1B}[2K" + progress("beta (2.0.0)", marks: 10, status: "Downloaded 4.0MB") + "\r\n"
        output += "\u{1B}[32m✔\u{1B}[0m Pouring terminal-output-demo--1.0.0.arm64_sonoma.bottle.tar.gz\r\n"
        output += "\u{1B}[32m==>\u{1B}[0m Caveats\r\nExactly eighty columns are rendered before this sentence wraps at the edge.......X"
        output += "\u{1B}[?25h"
        packageActionOutput = output
    }
#endif

    private func apply(snapshot: PackageHostSnapshot, inventory: PackageInventory) {
        let packageActionWasRunning = isPackageActionRunning
        isReloading = snapshot.isRefreshing
        loadingManagers = snapshot.loadingManagers ?? (snapshot.isRefreshing ? Set(PackageManagerKind.localCases) : [])
        var nextErrors = inventory.errors
        if let errorMessage = snapshot.errorMessage, !nextErrors.contains(errorMessage) {
            nextErrors.insert(errorMessage, at: 0)
        }
        let nextInventory = PackageInventory(generatedAt: inventory.generatedAt, packages: inventory.packages, errors: nextErrors)
        apply(
            inventory: nextInventory,
            index: PackageIndex(
                packages: nextInventory.packages,
                catalogPackages: snapshot.catalogPackages,
                newUpdatedLastClickedAt: newUpdatedLastClickedAt
            ),
            installedPackageFirstSeenAtByID: snapshot.installedPackageFirstSeenAtByID
        )
        // The offer depends on which managers have packages, so it is only answerable once an
        // inventory has landed — detection alone runs before the first scan finishes.
        refreshSetupOffer()
        guard remoteActionHostID == nil else { return }
        // The host is the authority on whether a helper install is running: it refuses a request
        // that arrives during a refresh or another action, so anything set at click time could
        // claim an install that never started. Its running action is also the only reliable
        // completion signal — waiting for the tool to appear leaves the card spinning forever
        // whenever the install failed.
        let wasInstallingHelper = installingHelper != nil
        installingHelper = snapshot.runningAction.flatMap { action in
            action.kind == .install ? CargoHelper(promptKey: action.packageID) : nil
        }
        // Detection shells out, and the host publishes a snapshot per manager during a refresh — a
        // dozen in a burst. What it detects only changes when a helper install finishes, so that is
        // the one snapshot worth re-detecting on. First load and section changes are covered by the
        // list view's task.
        if wasInstallingHelper, installingHelper == nil { refreshSetupOffers() }
        installingPackageName = snapshot.runningAction?.kind == .install ? snapshot.runningAction?.displayName : nil
        uninstallingPackageName = snapshot.runningAction?.kind == .uninstall ? snapshot.runningAction?.displayName : nil
        updatingPackageName = snapshot.runningAction?.kind == .update ? snapshot.runningAction?.displayName : nil
        if let runningAction = snapshot.runningAction {
            localActionIdentity = PackageActionIdentity(runID: runningAction.runID, kind: runningAction.kind, packageID: runningAction.packageID)
            packageActionCommand = runningAction.command
            packageActionOutput = runningAction.output ?? ""
            packageActionError = nil
        } else if packageActionWasRunning, let errorMessage = snapshot.errorMessage {
            localActionIdentity = nil
            packageActionError = errorMessage
        } else if packageActionError == nil {
            localActionIdentity = nil
            packageActionCommand = nil
            packageActionOutput = ""
        }
    }

    @objc private func hostSnapshotChanged(_ notification: Notification) {
        syncFromHost()
    }

    @objc private func hostActionOutputChanged(_ notification: Notification) {
        guard let (kind, packageID, runID, output) = PackageHostNotifications.actionOutput(from: notification) else { return }
        applyHostActionOutput(runID: runID, kind: kind, packageID: packageID, output: output)
    }

    func applyHostActionOutput(runID: UUID? = nil, kind: PackageHostActionKind, packageID: String, output: String) {
        guard remoteActionHostID == nil,
              localActionIdentity == PackageActionIdentity(runID: runID, kind: kind, packageID: packageID) else { return }
        packageActionOutput = output
    }

    private func clearDossier() {
        dossierTask?.cancel()
        dossierTask = nil
        isLoadingSelectedPackageMetadata = false
        selectedPackageDossier = nil
        selectedPackageDossierError = nil
        selectedPackageConfigurationLocations = []
    }

    private func loadDossier(for package: ManagedPackage) {
        clearDossier()
        guard let dossierClient else { return }
        let packageID = package.id
        let resolvesLocalPaths = !isRemoteSelection
        isLoadingSelectedPackageMetadata = true
        dossierTask = Task { [dossierClient] in
            do {
                let dossier = try await dossierClient.dossier(for: package)
                let configurationLocations = resolvesLocalPaths
                    ? await mainWindowResolvedConfigurationLocations(for: dossier)
                    : []
                guard !Task.isCancelled else { return }
                if selectedPackage?.id == packageID {
                    selectedPackageDossier = dossier
                    selectedPackageConfigurationLocations = configurationLocations
                    selectedPackageDossierError = nil
                    isLoadingSelectedPackageMetadata = false
                }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                if selectedPackage?.id == packageID {
                    selectedPackageDossier = nil
                    selectedPackageDossierError = error.localizedDescription
                    isLoadingSelectedPackageMetadata = false
                }
            }
        }
    }
}

struct PackageIndex: Sendable {
    static let empty = PackageIndex(packages: [], catalogPackages: [], newUpdatedLastClickedAt: nil)

    let packagesBySection: [MainWindowSection: [ManagedPackage]]
    let countsBySection: [MainWindowSection: Int]
    let categorySections: [MainWindowSection]
    let recommendedPackages: [ManagedPackage]
    let newUpdatedUnreadCount: Int?
    let hasCatalog: Bool

    init(packages: [ManagedPackage], catalogPackages: [ManagedPackage], newUpdatedLastClickedAt: Date?) {
        hasCatalog = !catalogPackages.isEmpty
        var installedByIdentifier: [String: ManagedPackage] = [:]
        for package in packages where installedByIdentifier[package.identifier] == nil {
            installedByIdentifier[package.identifier] = package
        }
        for package in packages {
            guard let identifier = package.catalogIdentifier, installedByIdentifier[identifier] == nil else { continue }
            installedByIdentifier[identifier] = package
        }
        let catalogPackages = catalogPackages.map { catalogPackage in
            guard let installedPackage = installedByIdentifier[catalogPackage.identifier] else { return catalogPackage }
            return Self.catalogPackage(catalogPackage, withInstalledStateFrom: installedPackage)
        }
        let newUpdated = catalogPackages
            .filter { $0.pulseKind == "new" }
            .sorted(by: Self.newestUpdatedFirst)

        let catalogApps = catalogPackages.filter {
            let identifier = $0.catalogIdentifier ?? $0.identifier
            return mainWindowManagerSection(for: $0) == .apps && installedByIdentifier[identifier] != nil
        }
        let representedAppIdentifiers = Set(catalogApps.map { $0.catalogIdentifier ?? $0.identifier })
        let unmatchedApps = packages.filter {
            mainWindowManagerSection(for: $0) == .apps
                && !representedAppIdentifiers.contains($0.catalogIdentifier ?? $0.identifier)
        }
        var bySection: [MainWindowSection: [ManagedPackage]] = [
            .installed: packages.sorted(by: Self.alphabetical),
            .outdated: packages.filter(\.isOutdated).sorted(by: Self.mostOutdatedFirst),
            .newUpdated: newUpdated,
            .rust: packages.filter { mainWindowManagerSection(for: $0) == .rust }.sorted(by: Self.alphabetical),
            .homebrew: packages.filter { $0.manager == .homebrew }.sorted(by: Self.alphabetical),
            .apps: (catalogApps + unmatchedApps).sorted(by: Self.alphabetical),
            .javascript: packages.filter { mainWindowManagerSection(for: $0) == .javascript }.sorted(by: Self.alphabetical),
            .python: packages.filter { mainWindowManagerSection(for: $0) == .python }.sorted(by: Self.alphabetical),
            .skills: packages.filter { $0.manager == .skills }.sorted(by: Self.alphabetical),
        ]

        categorySections = Set(catalogPackages.compactMap(\.category).filter { !$0.isEmpty })
            .map(MainWindowSection.category)
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        for section in categorySections {
            bySection[section] = catalogPackages
                .filter { $0.category == section.categoryIdentifier }
                .sorted(by: Self.newestUpdatedFirst)
        }

        packagesBySection = bySection
        countsBySection = bySection.mapValues(\.count)
        recommendedPackages = categorySections
            .flatMap { bySection[$0] ?? [] }
            .filter { $0.pulseKind != "new" }
            .sorted(by: Self.newestUpdatedFirst)

        let clickedAt = newUpdatedLastClickedAt.map { ISO8601DateFormatter().string(from: $0) }
        let unread = newUpdated.filter {
            guard let clickedAt else { return $0.pulseKind == "new" }
            return ($0.lastUpdatedAt ?? "") > clickedAt
        }.count
        newUpdatedUnreadCount = unread > 0 ? unread : nil
    }

    private static func catalogPackage(_ catalogPackage: ManagedPackage, withInstalledStateFrom installedPackage: ManagedPackage) -> ManagedPackage {
        let associatedDirectApp = installedPackage.catalogIdentifier == catalogPackage.identifier
        return ManagedPackage(
            manager: associatedDirectApp ? installedPackage.manager : catalogPackage.manager,
            identifier: associatedDirectApp ? installedPackage.identifier : catalogPackage.identifier,
            catalogIdentifier: associatedDirectApp ? catalogPackage.identifier : installedPackage.catalogIdentifier,
            displayName: catalogPackage.displayName,
            installedVersion: installedPackage.installedVersion,
            installedVersions: installedPackage.installedVersions,
            latestVersion: catalogPackage.latestVersion ?? installedPackage.latestVersion,
            summary: catalogPackage.summary ?? installedPackage.summary,
            category: catalogPackage.category ?? installedPackage.category,
            homepage: catalogPackage.homepage ?? installedPackage.homepage,
            docs: catalogPackage.docs ?? installedPackage.docs,
            repo: catalogPackage.repo ?? installedPackage.repo,
            lastUpdatedAt: catalogPackage.lastUpdatedAt,
            pulseKind: catalogPackage.pulseKind,
            installLocation: installedPackage.installLocation,
            binaryPath: installedPackage.binaryPath,
            executableNames: installedPackage.executableNames,
            bundleIdentifier: installedPackage.bundleIdentifier,
            bundleVersion: installedPackage.bundleVersion,
            appProvenance: installedPackage.appProvenance,
            versionSource: installedPackage.versionSource,
            advisoryURL: installedPackage.advisoryURL,
            versionCheckedAt: installedPackage.versionCheckedAt
        )
    }

    private static func alphabetical(_ lhs: ManagedPackage, _ rhs: ManagedPackage) -> Bool {
        let displayOrder = lhs.displayName.localizedStandardCompare(rhs.displayName)
        if displayOrder != .orderedSame { return displayOrder == .orderedAscending }
        return lhs.identifier < rhs.identifier
    }

    private static func newestUpdatedFirst(_ lhs: ManagedPackage, _ rhs: ManagedPackage) -> Bool {
        let order = (lhs.lastUpdatedAt ?? "").localizedStandardCompare(rhs.lastUpdatedAt ?? "")
        if order != .orderedSame { return order == .orderedDescending }
        return alphabetical(lhs, rhs)
    }

    private static func mostOutdatedFirst(_ lhs: ManagedPackage, _ rhs: ManagedPackage) -> Bool {
        let lhsGap = versionGap(lhs)
        let rhsGap = versionGap(rhs)
        for index in lhsGap.indices where lhsGap[index] != rhsGap[index] {
            return lhsGap[index] > rhsGap[index]
        }
        return alphabetical(lhs, rhs)
    }

    private static func versionGap(_ package: ManagedPackage) -> [Int] {
        zip(versionParts(package.latestVersion), versionParts(package.installedVersion)).map { $0.0 - $0.1 }
    }

    private static func versionParts(_ version: String?) -> [Int] {
        let parts = version?.split(separator: ".").prefix(3).map { Int($0) ?? 0 } ?? []
        return parts + Array(repeating: 0, count: 3 - parts.count)
    }
}

/// The section a manager's setup offer belongs above. Managers whose packages span sections have
/// no single home, so they cannot make offers.
func mainWindowSetupSection(_ manager: PackageManagerKind) -> MainWindowSection? {
    switch manager {
    case .cargoInstall, .rustup: .rust
    case .apk, .apt, .dnf, .zypper: .installed
    case .homebrew: .homebrew
    case .npm, .npx: .javascript
    case .skills: .skills
    case .uv, .uvx: .python
    case .macApp, .mise: nil
    }
}

func mainWindowManagerSection(for package: ManagedPackage) -> MainWindowSection {
    if package.identifier.hasPrefix("brew:cask:") {
        return package.appProvenance == .homebrew ? .apps : .homebrew
    }
    switch package.manager {
    case .cargoInstall, .rustup: return .rust
    case .apk, .apt, .dnf, .zypper: return .installed
    case .macApp: return .apps
    case .homebrew: return .homebrew
    case .npm, .npx: return .javascript
    case .skills: return .skills
    case .uv, .uvx: return .python
    case .mise:
        switch package.packageToken.lowercased() {
        case "node", "bun", "deno": return .javascript
        case "python": return .python
        case "rust": return .rust
        default: return .languageRuntime
        }
    }
}
