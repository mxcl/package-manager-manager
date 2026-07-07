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
    static let managerSections: [MainWindowSection] = [.rust, .homebrew, .casks, .javascript, .python]
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
        case .python: "shippingbox.circle"
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

    var packageManagers: Set<PackageManagerKind> {
        switch self {
        case .rust: [.cargoInstall, .rustup]
        case .homebrew, .casks: [.homebrew]
        case .javascript: [.npm, .npx]
        case .python: [.uv, .uvx]
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
    case releases

    var id: String { rawValue }
    var title: String {
        switch self {
        case .homepage: "Home"
        case .docs: "Docs"
        case .repo: "Repo"
        case .releases: "Releases"
        }
    }

    func urlString(in package: ManagedPackage) -> String? {
        switch self {
        case .homepage: package.homepage
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

func mainWindowLinks(for package: ManagedPackage?) -> [MainWindowPackageLink] {
    guard let package else { return [] }
    let links = MainWindowLinkTab.allCases.compactMap { tab in
        mainWindowWebURL(tab.urlString(in: package)).map { MainWindowPackageLink(tab: tab, url: $0) }
    }
    let specificURLs = Set(links.filter { $0.tab != .homepage }.map(\.url))
    return links.filter { $0.tab != .homepage || !specificURLs.contains($0.url) }
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

@MainActor
final class MainWindowModel: NSObject, ObservableObject {
    @Published var selectedSection: MainWindowSection = .home
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
    @Published private(set) var uninstallingPackageName: String?
    @Published private(set) var updatingPackageName: String?
    @Published private(set) var packageIDToScrollIntoView: String?
    @Published var searchText = ""

    nonisolated private static let newUpdatedLastClickedAtDefaultsKey = "MainWindowModel.newUpdatedLastClickedAt"

    private var inventory = PackageInventory(packages: [])
    private var packageIndex = PackageIndex.empty
    private var installedPackageFirstSeenAtByID: [String: Date]?
    private var hasInventory = false
    private var newUpdatedLastClickedAt: Date?
    private var newUpdatedSelectionDisplayCount: Int?
    private let userDefaults: UserDefaults
    private let store: PackageHostStore
    private let dossierClient: PackageDossierClient?
    private var dossierTask: Task<Void, Never>?
    private let notificationCenter = DistributedNotificationCenter.default()

    init(
        userDefaults: UserDefaults = .standard,
        store: PackageHostStore = PackageHostStore(),
        dossierClient: PackageDossierClient? = nil
    ) {
        self.userDefaults = userDefaults
        newUpdatedLastClickedAt = userDefaults.object(forKey: Self.newUpdatedLastClickedAtDefaultsKey) as? Date
        self.store = store
        self.dossierClient = dossierClient
        super.init()
        syncFromHost()
        notificationCenter.addObserver(self, selector: #selector(hostSnapshotChanged(_:)), name: PackageHostNotifications.snapshotChanged, object: nil)
    }

    deinit {
        dossierTask?.cancel()
        notificationCenter.removeObserver(self)
    }

    var activeSidebarSection: MainWindowSection? { selectedSection }

    var dashboardIsLoadingData: Bool {
        isReloading || !hasInventory
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

    var visibleManagerSections: [MainWindowSection] {
        if isReloading { return MainWindowSection.managerSections }
        return MainWindowSection.managerSections.filter { isLoadingCount(for: $0) || (count(for: $0) ?? 0) > 0 }
    }

    var visibleCategorySections: [MainWindowSection] {
        MainWindowSection.categorySections.filter { (count(for: $0) ?? 0) > 0 }
    }

    var displayedPackages: [ManagedPackage] {
        let base = packageIndex.packagesBySection[selectedSection] ?? []
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return base }
        return base.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.identifier.localizedCaseInsensitiveContains(query)
                || ($0.summary?.localizedCaseInsensitiveContains(query) == true)
        }
    }

    func reload() {
        PackageHostNotifications.postRefreshRequested()
    }

    func selectSection(_ section: MainWindowSection) {
        packageIDToScrollIntoView = nil
        if section == .newUpdated {
            newUpdatedSelectionDisplayCount = newUpdatedUnreadCount
            recordNewUpdatedSidebarClick()
        } else {
            newUpdatedSelectionDisplayCount = nil
        }
        selectedSection = section
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
        switch section {
        case .home, .about: nil
        case .newUpdated: newUpdatedSelectionDisplayCount ?? newUpdatedUnreadCount
        default: packageIndex.countsBySection[section]
        }
    }

    func isLoadingCount(for section: MainWindowSection) -> Bool {
        !section.packageManagers.isDisjoint(with: loadingManagers)
    }

    func uninstall(_ package: ManagedPackage) {
        guard PackageUninstaller.supports(package), uninstallingPackageName == nil, updatingPackageName == nil else { return }
        PackageHostNotifications.postUninstallRequested(packageID: package.id)
    }

    func update(_ package: ManagedPackage) {
        guard PackageUpdater.supports(package), uninstallingPackageName == nil, updatingPackageName == nil else { return }
        PackageHostNotifications.postUpdateRequested(packageID: package.id)
    }

    private var newUpdatedUnreadCount: Int? {
        packageIndex.newUpdatedUnreadCount
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
            uninstallingPackageName = nil
            updatingPackageName = nil
            return
        }
        apply(snapshot: snapshot, inventory: inventory)
    }

    private func apply(snapshot: PackageHostSnapshot, inventory: PackageInventory) {
        isReloading = snapshot.isRefreshing
        loadingManagers = snapshot.isRefreshing ? Set(PackageManagerKind.allCases) : []
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
        uninstallingPackageName = snapshot.runningAction?.kind == .uninstall ? snapshot.runningAction?.displayName : nil
        updatingPackageName = snapshot.runningAction?.kind == .update ? snapshot.runningAction?.displayName : nil
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
        isLoadingSelectedPackageMetadata = true
        dossierTask = Task { [dossierClient] in
            do {
                let dossier = try await dossierClient.dossier(for: package)
                let configurationLocations = await mainWindowResolvedConfigurationLocations(for: dossier)
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
