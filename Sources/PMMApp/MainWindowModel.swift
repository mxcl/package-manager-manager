import Foundation
import PMMCore

enum MainWindowSection: String, CaseIterable, Identifiable, Sendable {
    case home
    case installed
    case outdated
    case newUpdated
    case rust
    case homebrew
    case casks
    case javascript
    case python
    case skills
    case developerTools
    case cloudInfrastructure
    case networking
    case system
    case security
    case data
    case languageRuntime
    case media
    case productivity
    case science
    case games
    case toys
    case other
    case about

    var id: String { rawValue }

    static let librarySections: [MainWindowSection] = [.home, .installed, .outdated]
    static let managerSections: [MainWindowSection] = [.rust, .homebrew, .casks, .javascript, .python, .skills]
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    static let categorySections: [MainWindowSection] = [
        .developerTools, .cloudInfrastructure, .networking, .system, .security,
        .data, .languageRuntime, .media, .productivity, .science, .games, .toys, .other
    ].sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    static let categoryShortcutSections: [MainWindowSection] = [.newUpdated]

    var title: String {
        switch self {
        case .home: "Home"
        case .installed: "Installed"
        case .outdated: "Outdated"
        case .newUpdated: "New"
        case .rust: "Rust"
        case .homebrew: "Homebrew"
        case .casks: "Casks"
        case .javascript: "JavaScript"
        case .python: "Python"
        case .skills: "Skills"
        case .developerTools: "Developer Tools"
        case .cloudInfrastructure: "Cloud Infrastructure"
        case .networking: "Networking"
        case .system: "System"
        case .security: "Security"
        case .data: "Data"
        case .languageRuntime: "Language Runtime"
        case .media: "Media"
        case .productivity: "Productivity"
        case .science: "Science"
        case .games: "Games"
        case .toys: "Toys"
        case .other: "Other"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .installed: "shippingbox"
        case .outdated: "clock"
        case .newUpdated: "sparkles"
        case .rust: "hammer"
        case .homebrew: "mug"
        case .casks: "macwindow"
        case .javascript: "curlybraces"
        case .python: "arrow.forward.to.line"
        case .skills: "wand.and.stars"
        case .developerTools: "chevron.left.forwardslash.chevron.right"
        case .cloudInfrastructure: "cloud"
        case .networking: "network"
        case .system: "gearshape"
        case .security: "shield"
        case .data: "chart.bar.doc.horizontal"
        case .languageRuntime: "curlybraces"
        case .media: "play.rectangle"
        case .productivity: "checklist"
        case .science: "atom"
        case .games: "gamecontroller"
        case .toys: "puzzlepiece"
        case .other: "ellipsis"
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
        case .rust: [.cargoInstall, .rustup]
        case .homebrew, .casks: [.homebrew]
        case .javascript: [.npm, .npx]
        case .python: [.uv, .uvx]
        case .skills: [.skills]
        default: []
        }
    }

    var categoryIdentifier: String? {
        switch self {
        case .developerTools: "developer-tools"
        case .cloudInfrastructure: "cloud-infrastructure"
        case .networking: "networking"
        case .system: "system"
        case .security: "security"
        case .data: "data"
        case .languageRuntime: "language-runtime"
        case .media: "media"
        case .productivity: "productivity"
        case .science: "science"
        case .games: "games"
        case .toys: "toys"
        case .other: "other"
        default: nil
        }
    }
}

enum MainWindowLinkTab: String, CaseIterable, Identifiable {
    case homepage
    case repo
    case docs
    case registry
    case releases

    var id: String { rawValue }
    var title: String {
        switch self {
        case .homepage: "Home"
        case .registry: "Registry"
        case .docs: "Docs"
        case .repo: "Repo"
        case .releases: "Changelog"
        }
    }

    func urlString(in package: ManagedPackage) -> String? {
        switch self {
        case .homepage: package.homepage
        case .registry: mainWindowRegistryURLString(for: package)
        case .docs: package.docs
        case .repo: package.repo
        case .releases: nil
        }
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
        if manager == .homebrew, name.hasPrefix("cask/") { return .casks }
        return switch manager {
        case .cargoInstall, .rustup: .rust
        case .homebrew: .homebrew
        case .npm, .npx: .javascript
        case .skills: .skills
        case .uv, .uvx: .python
        }
    }

    func matches(_ package: ManagedPackage) -> Bool {
        package.manager == manager && (package.identifier == identifier || package.packageToken == name)
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
    case .rustup:
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
    case outdated
    case installed

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
    @Published var selectedLinkTab: MainWindowLinkTab?
    @Published private(set) var isReloading = true
    @Published private(set) var loadingManagers = Set(PackageManagerKind.allCases)
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
    @Published private(set) var packageIDToScrollIntoView: String?
    @Published private(set) var dashboardBlogEntries: [DashboardBlogEntry] = []
    @Published private(set) var dashboardBlogEntriesAreLoading = false
    @Published private(set) var pendingInstallPackConfirmation: MainWindowInstallPackConfirmation?
    @Published var searchText = ""

    nonisolated private static let newUpdatedLastClickedAtDefaultsKey = "MainWindowModel.newUpdatedLastClickedAt"
    nonisolated private static let remoteHostsDefaultsKey = "MainWindowModel.remoteHosts"

    private var inventory = PackageInventory(packages: [])
    private var packageIndex = PackageIndex.empty
    private var installedPackageFirstSeenAtByID: [String: Date]?
    private var hasInventory = false
    private var pendingPackageURLCommand: MainWindowPackageURLCommand?
    private var newUpdatedLastClickedAt: Date?
    private var newUpdatedSelectionDisplayCount: Int?
    private let userDefaults: UserDefaults
    private let store: PackageHostStore
    private let dossierClient: PackageDossierClient?
    private let remoteClient: RemoteSSHClient
    private var dossierTask: Task<Void, Never>?
    private var dashboardBlogEntriesTask: Task<Void, Never>?
    private var remoteTasks: [UUID: Task<Void, Never>] = [:]
    private var remoteActionTask: Task<Void, Never>?
    private var remoteActionHostID: UUID?
    private let notificationCenter = DistributedNotificationCenter.default()

    init(
        userDefaults: UserDefaults = .standard,
        store: PackageHostStore = PackageHostStore(),
        dossierClient: PackageDossierClient? = nil,
        dashboardBlogURL: URL? = nil,
        remoteClient: RemoteSSHClient = RemoteSSHClient()
    ) {
        self.userDefaults = userDefaults
        newUpdatedLastClickedAt = userDefaults.object(forKey: Self.newUpdatedLastClickedAtDefaultsKey) as? Date
        remoteHosts = userDefaults.data(forKey: Self.remoteHostsDefaultsKey)
            .flatMap { try? JSONDecoder().decode([RemoteHost].self, from: $0) } ?? []
        self.store = store
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
            reloadRemoteHosts()
        }
#else
        syncFromHost()
        if let dashboardBlogURL {
            loadDashboardBlogEntries(from: dashboardBlogURL)
        }
        notificationCenter.addObserver(self, selector: #selector(hostSnapshotChanged(_:)), name: PackageHostNotifications.snapshotChanged, object: nil)
        reloadRemoteHosts()
#endif
    }

    deinit {
        dossierTask?.cancel()
        dashboardBlogEntriesTask?.cancel()
        remoteTasks.values.forEach { $0.cancel() }
        remoteActionTask?.cancel()
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

    var displayedSectionTitle: String {
        guard let host = selectedRemoteHost, let selectedRemoteSection else { return selectedSection.title }
        return "\(host.displayName) · \(selectedRemoteSection.title)"
    }

    var ecosystemsSidebarTitle: String {
        remoteHosts.isEmpty ? "Ecosystems" : ProcessInfo.processInfo.hostName
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
        MainWindowSection.categorySections.filter { (count(for: $0) ?? 0) > 0 }
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
        showsUpdateAllOutdatedPackages && !displayedPackagesAreLoading && !isPackageActionRunning && !updatableOutdatedPackages.isEmpty
    }

    func reload() {
        PackageHostNotifications.postRefreshRequested()
        reloadRemoteHosts()
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

    func reloadRemoteHosts() {
        for host in remoteHosts where remoteActionHostID != host.id {
            refreshRemoteHost(host.id)
        }
    }

    func refreshRemoteHost(_ hostID: UUID) {
        guard remoteActionHostID != hostID, let host = remoteHosts.first(where: { $0.id == hostID }) else { return }
        remoteTasks.removeValue(forKey: hostID)?.cancel()
        var state = remoteHostStates[hostID] ?? RemoteHostState()
        state.isLoading = true
        state.error = nil
        remoteHostStates[hostID] = state
        let remoteClient = remoteClient
        remoteTasks[hostID] = Task { [weak self] in
            do {
                let response = try await remoteClient.inventory(on: host)
                guard !Task.isCancelled else { return }
                self?.remoteHostStates[hostID] = RemoteHostState(inventory: response.inventory)
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
        packageIDToScrollIntoView = nil
        if section == .newUpdated {
            newUpdatedSelectionDisplayCount = newUpdatedUnreadCount
            recordNewUpdatedSidebarClick()
        } else {
            newUpdatedSelectionDisplayCount = nil
        }
        selectedRemoteHostID = nil
        selectedRemoteSection = nil
        selectedSection = section
        selectedPackage = nil
        selectedLinkTab = nil
        clearDossier()
    }

    func selectRemoteHost(_ hostID: UUID, section: RemoteHostSection) {
        guard remoteHosts.contains(where: { $0.id == hostID }) else { return }
        selectedRemoteHostID = hostID
        selectedRemoteSection = section
        selectedPackage = nil
        selectedLinkTab = nil
        clearDossier()
    }

    func select(_ package: ManagedPackage) {
        selectedPackage = package
        selectedLinkTab = nil
        loadDossier(for: package)
    }

    func openDashboardPackage(_ package: ManagedPackage) {
        let section = MainWindowSection.categorySections.first { $0.categoryIdentifier == package.category } ?? .newUpdated
        selectSection(section)
        let package = packageIndex.packagesBySection[section]?.first { $0.id == package.id } ?? package
        select(package)
        packageIDToScrollIntoView = package.id
    }

    @discardableResult
    func openPackageURL(_ url: URL) -> Bool {
        guard let command = MainWindowPackageURLCommand(url: url) else { return false }
        pendingPackageURLCommand = command
        return openPackageURLCommand(command)
    }

    func consumePackageScrollRequest() {
        packageIDToScrollIntoView = nil
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
        guard PackageUninstaller.supports(package), !isPackageActionRunning else { return }
        if let host = selectedRemoteHost {
            pendingRemoteUninstall = RemoteUninstallConfirmation(host: host, package: package)
            return
        }
        PackageHostNotifications.postUninstallRequested(packageID: package.id)
    }

    func update(_ package: ManagedPackage) {
        guard PackageUpdater.supports(package), !isPackageActionRunning else { return }
        if let host = selectedRemoteHost {
            runRemoteAction(.update, package: package, host: host)
            return
        }
        PackageHostNotifications.postUpdateRequested(packageID: package.id)
    }

    func updateAllOutdatedPackages() {
        guard canUpdateAllOutdatedPackages else { return }
        if let host = selectedRemoteHost {
            runRemoteAction(.updateAll, package: nil, host: host)
            return
        }
        PackageHostNotifications.postUpdateAllRequested()
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
        case .updateAll: break
        }
        remoteTasks.removeValue(forKey: host.id)?.cancel()
        remoteActionHostID = host.id
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
        }

        let remoteClient = remoteClient
        let progress: @Sendable (String) -> Void = { [weak self] chunk in
            Task { @MainActor in self?.packageActionOutput += chunk }
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
                }
                remoteHostStates[host.id] = RemoteHostState(
                    inventory: response.inventory,
                    error: response.failures.isEmpty ? nil : response.failures.map(\.message).joined(separator: "\n")
                )
                if !response.failures.isEmpty {
                    packageActionError = response.failures.map(\.message).joined(separator: "\n")
                }
                selectedPackage = selectedPackage.flatMap { selected in
                    self.displayedPackages.first { $0.id == selected.id }
                }
            } catch is CancellationError {
            } catch {
                var state = remoteHostStates[host.id] ?? RemoteHostState()
                state.isLoading = false
                state.error = error.localizedDescription
                remoteHostStates[host.id] = state
                packageActionError = error.localizedDescription
            }
            updatingPackageName = nil
            uninstallingPackageName = nil
            remoteActionHostID = nil
            remoteActionTask = nil
        }
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
        !isRemoteSelection && PackageInstaller.supports(package) && !packages.contains { $0.identifier == package.identifier }
    }

    private var isPackageActionRunning: Bool {
        installingPackageName != nil || uninstallingPackageName != nil || updatingPackageName != nil
    }

    private var newUpdatedUnreadCount: Int? {
        packageIndex.newUpdatedUnreadCount
    }

    private var updatableOutdatedPackages: [ManagedPackage] {
        if isRemoteSelection { return displayedPackages.filter(PackageUpdater.supports) }
        return (packageIndex.packagesBySection[.outdated] ?? []).filter(PackageUpdater.supports)
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
        let packages = packageIndex.packagesBySection[section] ?? []
        let query = searchQuery
        guard !query.isEmpty else { return packages }
        return packages.filter { matchesSearch($0, query: query) }
    }

    private func filteredCount(for section: MainWindowSection) -> Int? {
        let query = searchQuery
        guard !query.isEmpty else { return nil }
        return packageIndex.packagesBySection[section].map { packages in
            packages.filter { matchesSearch($0, query: query) }.count
        }
    }

    private func matchesSearch(_ package: ManagedPackage, query: String) -> Bool {
        package.displayName.localizedCaseInsensitiveContains(query)
            || package.identifier.localizedCaseInsensitiveContains(query)
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
        packageIDToScrollIntoView = resolvedPackage.id
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
        return MainWindowSection.categorySections.first { $0.categoryIdentifier == package.category } ?? preferred
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
        selectedPackage = selectedPackage.flatMap { selected in displayedPackages.first { $0.id == selected.id } }
        if let pendingPackageURLCommand {
            openPackageURLCommand(pendingPackageURLCommand)
        }
        if selectedPackage == nil { clearDossier() }
    }

    func syncFromHost() {
        guard let snapshot = try? store.load(), let inventory = snapshot.inventory else {
            hasInventory = false
            installedPackageFirstSeenAtByID = nil
            isReloading = true
            loadingManagers = Set(PackageManagerKind.allCases)
            return
        }
        apply(snapshot: snapshot, inventory: inventory)
    }

    func apply(snapshot: PackageHostSnapshot) {
        guard let inventory = snapshot.inventory else {
            hasInventory = false
            installedPackageFirstSeenAtByID = nil
            isReloading = true
            loadingManagers = Set(PackageManagerKind.allCases)
            installingPackageName = nil
            uninstallingPackageName = nil
            updatingPackageName = nil
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
        loadingManagers = snapshot.loadingManagers ?? (snapshot.isRefreshing ? Set(PackageManagerKind.allCases) : [])
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
        guard remoteActionHostID == nil else { return }
        installingPackageName = snapshot.runningAction?.kind == .install ? snapshot.runningAction?.displayName : nil
        uninstallingPackageName = snapshot.runningAction?.kind == .uninstall ? snapshot.runningAction?.displayName : nil
        updatingPackageName = snapshot.runningAction?.kind == .update ? snapshot.runningAction?.displayName : nil
        if let runningAction = snapshot.runningAction {
            packageActionCommand = runningAction.command
            packageActionOutput = runningAction.output ?? ""
            packageActionError = nil
        } else if packageActionWasRunning, let errorMessage = snapshot.errorMessage {
            packageActionError = errorMessage
        } else if packageActionError == nil {
            packageActionCommand = nil
            packageActionOutput = ""
        }
    }

    @objc private func hostSnapshotChanged(_ notification: Notification) {
        syncFromHost()
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
    let recommendedPackages: [ManagedPackage]
    let newUpdatedUnreadCount: Int?

    init(packages: [ManagedPackage], catalogPackages: [ManagedPackage], newUpdatedLastClickedAt: Date?) {
        var installedByIdentifier: [String: ManagedPackage] = [:]
        for package in packages where installedByIdentifier[package.identifier] == nil {
            installedByIdentifier[package.identifier] = package
        }
        let catalogPackages = catalogPackages.map { catalogPackage in
            guard let installedPackage = installedByIdentifier[catalogPackage.identifier] else { return catalogPackage }
            return Self.catalogPackage(catalogPackage, withInstalledStateFrom: installedPackage)
        }
        let newUpdated = catalogPackages
            .filter { $0.pulseKind == "new" }
            .sorted(by: Self.newestUpdatedFirst)

        var bySection: [MainWindowSection: [ManagedPackage]] = [
            .installed: packages.sorted(by: Self.alphabetical),
            .outdated: packages.filter(\.isOutdated).sorted(by: Self.mostOutdatedFirst),
            .newUpdated: newUpdated,
            .rust: packages.filter { [.cargoInstall, .rustup].contains($0.manager) }.sorted(by: Self.alphabetical),
            .homebrew: packages.filter { $0.manager == .homebrew }.sorted(by: Self.alphabetical),
            .casks: packages.filter { $0.identifier.hasPrefix("brew:cask:") }.sorted(by: Self.alphabetical),
            .javascript: packages.filter { [.npm, .npx].contains($0.manager) }.sorted(by: Self.alphabetical),
            .python: packages.filter { [.uv, .uvx].contains($0.manager) }.sorted(by: Self.alphabetical),
            .skills: packages.filter { $0.manager == .skills }.sorted(by: Self.alphabetical),
        ]

        for section in MainWindowSection.categorySections {
            bySection[section] = catalogPackages
                .filter { $0.category == section.categoryIdentifier }
                .sorted(by: Self.newestUpdatedFirst)
        }

        packagesBySection = bySection
        countsBySection = bySection.mapValues(\.count)
        recommendedPackages = MainWindowSection.categorySections
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
        ManagedPackage(
            manager: catalogPackage.manager,
            identifier: catalogPackage.identifier,
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
            executableNames: installedPackage.executableNames
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
