import AppKit
import Foundation
import PMMCore

enum MainWindowSection: String, CaseIterable, Identifiable, Sendable {
    case installed
    case outdated
    case newUpdated
    case cargoInstall
    case homebrew
    case npm
    case npx
    case uv
    case uvx
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

    static let librarySections: [MainWindowSection] = [.installed, .outdated]
    static let managerSections: [MainWindowSection] = [.cargoInstall, .homebrew, .npm, .npx, .uv, .uvx]
    static let categorySections: [MainWindowSection] = [
        .developerTools, .cloudInfrastructure, .networking, .system, .security,
        .data, .languageRuntime, .media, .productivity, .science, .games, .toys, .other
    ].sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    static let categoryShortcutSections: [MainWindowSection] = [.newUpdated]
    static let utilitySections: [MainWindowSection] = []

    var title: String {
        switch self {
        case .installed: "Installed"
        case .outdated: "Outdated"
        case .newUpdated: "New / Updated"
        case .cargoInstall: "cargo install"
        case .homebrew: "Homebrew"
        case .npm: "npm"
        case .npx: "npx"
        case .uv: "uv"
        case .uvx: "uvx"
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
        case .installed: "shippingbox"
        case .outdated: "clock"
        case .newUpdated: "sparkles"
        case .cargoInstall: "hammer"
        case .homebrew: "mug"
        case .npm: "shippingbox.circle"
        case .npx: "terminal"
        case .uv: "bolt"
        case .uvx: "terminal.fill"
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

    var id: String { rawValue }
    var title: String {
        switch self {
        case .homepage: "Home"
        case .docs: "Docs"
        case .repo: "Repo"
        }
    }

    func urlString(in package: ManagedPackage) -> String? {
        switch self {
        case .homepage: package.homepage
        case .docs: package.docs
        case .repo: package.repo
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
    return MainWindowLinkTab.allCases.compactMap { tab in
        mainWindowWebURL(tab.urlString(in: package)).map { MainWindowPackageLink(tab: tab, url: $0) }
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

@MainActor
final class MainWindowModel: ObservableObject {
    @Published var selectedSection: MainWindowSection = .installed
    @Published private(set) var packages: [ManagedPackage] = []
    @Published private(set) var selectedPackage: ManagedPackage?
    @Published private(set) var isReloading = false
    @Published private(set) var loadingManagerSections = Set(MainWindowSection.managerSections)
    @Published private(set) var errors: [String] = []
    @Published private(set) var isLoadingSelectedPackageMetadata = false
    @Published private(set) var uninstallingPackageName: String?
    @Published private(set) var updatingPackageName: String?
    @Published var searchText = ""

    nonisolated private static let newUpdatedLastClickedAtDefaultsKey = "MainWindowModel.newUpdatedLastClickedAt"

    private var inventory = PackageInventory(packages: [])
    private var packageIndex = PackageIndex.empty
    private var newUpdatedLastClickedAt: Date?
    private var newUpdatedSelectionDisplayCount: Int?
    private let userDefaults: UserDefaults
    private let cratesIOClient: CratesIOClient
    private let npmRegistryClient: NPMRegistryClient
    private let packageUninstaller: PackageUninstaller
    private let packageUpdater: PackageUpdater
    private var packageMetadataCache: [String: PackageMetadata] = [:]
    private var selectedMetadataTask: Task<Void, Never>?

    init(
        userDefaults: UserDefaults = .standard,
        cratesIOClient: CratesIOClient = CratesIOClient(),
        npmRegistryClient: NPMRegistryClient = NPMRegistryClient(),
        packageUninstaller: PackageUninstaller = PackageUninstaller(),
        packageUpdater: PackageUpdater = PackageUpdater()
    ) {
        self.userDefaults = userDefaults
        self.cratesIOClient = cratesIOClient
        self.npmRegistryClient = npmRegistryClient
        self.packageUninstaller = packageUninstaller
        self.packageUpdater = packageUpdater
        newUpdatedLastClickedAt = userDefaults.object(forKey: Self.newUpdatedLastClickedAtDefaultsKey) as? Date
    }

    var activeSidebarSection: MainWindowSection? { selectedSection }

    var visibleManagerSections: [MainWindowSection] {
        if isReloading { return MainWindowSection.managerSections }
        return MainWindowSection.managerSections.filter { loadingManagerSections.contains($0) || (count(for: $0) ?? 0) > 0 }
    }

    var visibleCategorySections: [MainWindowSection] {
        MainWindowSection.categorySections.filter { (count(for: $0) ?? 0) > 0 }
    }

    var displayedPackages: [ManagedPackage] {
        let base = packageIndex.packagesBySection[selectedSection] ?? []
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return base }
        return base.filter { $0.name.localizedCaseInsensitiveContains(query) || ($0.summary?.localizedCaseInsensitiveContains(query) == true) }
    }

    func reload() {
        isReloading = true
        loadingManagerSections = Set(MainWindowSection.managerSections)
        Task {
            let clickedAt = newUpdatedLastClickedAt
            let remoteDatabase = Task.detached(priority: .background, operation: { () -> PackageDatabase? in
                guard let db = try? await PackageDatabase.fetch() else { return nil }
                return db
            })

            if let cached = await Task.detached(operation: { PackageDatabase.cached() }).value {
                await scanAndApply(database: cached, newUpdatedLastClickedAt: clickedAt)
            }

            if let db = await remoteDatabase.value {
                await scanAndApply(database: db, newUpdatedLastClickedAt: clickedAt)
            }
            loadingManagerSections.removeAll()
            isReloading = false
        }
    }

    func selectSection(_ section: MainWindowSection) {
        if section == .newUpdated {
            newUpdatedSelectionDisplayCount = newUpdatedUnreadCount
            recordNewUpdatedSidebarClick()
        } else {
            newUpdatedSelectionDisplayCount = nil
        }
        selectedSection = section
        selectedPackage = nil
        loadSelectedPackageMetadata()
    }

    func select(_ package: ManagedPackage) {
        selectedPackage = package.applying(metadata: cachedMetadata(for: package))
        loadSelectedPackageMetadata()
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
        case .about: nil
        case .newUpdated: newUpdatedSelectionDisplayCount ?? newUpdatedUnreadCount
        default: packageIndex.countsBySection[section]
        }
    }

    func isLoadingCount(for section: MainWindowSection) -> Bool {
        loadingManagerSections.contains(section)
    }

    func open(url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    func uninstall(_ package: ManagedPackage) {
        guard package.installedVersion != nil, uninstallingPackageName == nil, updatingPackageName == nil else { return }
        uninstallingPackageName = package.name
        Task {
            let result = await Task.detached { [packageUninstaller] in
                Result { try packageUninstaller.uninstall(package) }
            }.value
            uninstallingPackageName = nil
            switch result {
            case .success:
                selectedPackage = nil
                reload()
            case .failure(let error):
                errors.append(error.localizedDescription)
            }
        }
    }

    func update(_ package: ManagedPackage) {
        guard PackageUpdater.supports(package), uninstallingPackageName == nil, updatingPackageName == nil else { return }
        updatingPackageName = package.name
        Task {
            let result = await Task.detached { [packageUpdater] in
                Result { try packageUpdater.update(package) }
            }.value
            updatingPackageName = nil
            switch result {
            case .success:
                reload()
            case .failure(let error):
                errors.append(error.localizedDescription)
            }
        }
    }

    private var newUpdatedUnreadCount: Int? {
        packageIndex.newUpdatedUnreadCount
    }

    private func recordNewUpdatedSidebarClick() {
        let clickedAt = Date()
        newUpdatedLastClickedAt = clickedAt
        userDefaults.set(clickedAt, forKey: Self.newUpdatedLastClickedAtDefaultsKey)
    }

    func apply(inventory next: PackageInventory, index: PackageIndex) {
        inventory = next
        packageIndex = index
        packages = next.packages
        errors = next.errors
        selectedPackage = selectedPackage.flatMap { selected in displayedPackages.first { $0.id == selected.id } }
        if let selectedPackage {
            self.selectedPackage = selectedPackage.applying(metadata: cachedMetadata(for: selectedPackage))
        }
        loadSelectedPackageMetadata()
    }

    private func loadSelectedPackageMetadata() {
        selectedMetadataTask?.cancel()
        guard let package = selectedPackage, shouldLoadMetadata(for: package) else {
            isLoadingSelectedPackageMetadata = false
            return
        }
        if let metadata = cachedMetadata(for: package) {
            selectedPackage = package.applying(metadata: metadata)
            isLoadingSelectedPackageMetadata = false
            return
        }

        isLoadingSelectedPackageMetadata = true
        let key = metadataKey(for: package)
        selectedMetadataTask = Task.detached { [cratesIOClient, npmRegistryClient] in
            let name = package.name
            let metadata = try? await {
                switch package.manager {
                case .cargoInstall:
                    return try await cratesIOClient.metadata(for: name)
                case .npm, .npx:
                    return try await npmRegistryClient.metadata(for: name)
                case .homebrew, .uv, .uvx:
                    return nil
                }
            }()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.selectedPackage?.id == package.id else { return }
                if let metadata {
                    self.packageMetadataCache[key] = metadata
                    self.selectedPackage = self.selectedPackage?.applying(metadata: metadata)
                }
                self.isLoadingSelectedPackageMetadata = false
            }
        }
    }

    private func shouldLoadMetadata(for package: ManagedPackage) -> Bool {
        switch package.manager {
        case .cargoInstall, .npm, .npx: true
        case .homebrew, .uv, .uvx: false
        }
    }

    private func cachedMetadata(for package: ManagedPackage) -> PackageMetadata? {
        packageMetadataCache[metadataKey(for: package)]
    }

    private func metadataKey(for package: ManagedPackage) -> String {
        "\(package.manager.rawValue):\(package.name)"
    }

    private func scanAndApply(database: PackageDatabase, newUpdatedLastClickedAt: Date?) async {
        let catalogPackages = await Task.detached(priority: .background, operation: { database.catalogPackages }).value
        let previousPackages = packages
        var scannedPackages: [ManagedPackage] = []
        var scannedErrors: [String] = []
        var scannedManagers = Set<PackageManagerKind>()

        await apply(packages: previousPackages, errors: errors, catalogPackages: catalogPackages, newUpdatedLastClickedAt: newUpdatedLastClickedAt)

        await withTaskGroup(of: PackageScanBatch.self) { group in
            group.addTask {
                let scanner = PackageScanner()
                do { return PackageScanBatch(managers: [.cargoInstall], packages: try scanner.scanCargoInstall(database: database)) }
                catch { return PackageScanBatch(managers: [.cargoInstall], errors: [error.localizedDescription]) }
            }
            group.addTask {
                let scanner = PackageScanner()
                do { return PackageScanBatch(managers: [.homebrew], packages: try scanner.scanHomebrew(database: database)) }
                catch { return PackageScanBatch(managers: [.homebrew], errors: [error.localizedDescription]) }
            }
            group.addTask {
                let scanner = PackageScanner()
                do { return PackageScanBatch(managers: [.npm], packages: try scanner.scanNPM(database: database)) }
                catch { return PackageScanBatch(managers: [.npm], errors: [error.localizedDescription]) }
            }
            group.addTask { [npmRegistryClient] in
                let scanner = PackageScanner()
                do { return PackageScanBatch(managers: [.npx], packages: try await scanner.scanNPX(database: database, npmRegistryClient: npmRegistryClient)) }
                catch { return PackageScanBatch(managers: [.npx], errors: [error.localizedDescription]) }
            }
            group.addTask {
                let scanner = PackageScanner()
                do { return PackageScanBatch(managers: [.uv], packages: try scanner.scanUV(database: database)) }
                catch { return PackageScanBatch(managers: [.uv], errors: [error.localizedDescription]) }
            }
            group.addTask {
                let scanner = PackageScanner()
                do { return PackageScanBatch(managers: [.uvx], packages: try scanner.scanUVX(database: database)) }
                catch { return PackageScanBatch(managers: [.uvx], errors: [error.localizedDescription]) }
            }

            for await batch in group {
                scannedManagers.formUnion(batch.managers)
                loadingManagerSections.subtract(batch.sections)
                scannedPackages.removeAll { batch.managers.contains($0.manager) }
                scannedPackages += batch.packages
                scannedErrors += batch.errors
                let visiblePackages = previousPackages.filter { !scannedManagers.contains($0.manager) } + scannedPackages
                await apply(packages: visiblePackages, errors: scannedErrors, catalogPackages: catalogPackages, newUpdatedLastClickedAt: newUpdatedLastClickedAt)
            }
        }
    }

    private func apply(packages nextPackages: [ManagedPackage], errors nextErrors: [String], catalogPackages: [ManagedPackage], newUpdatedLastClickedAt: Date?) async {
        let (next, index) = await Task.detached(priority: .background) {
            let sortedPackages = nextPackages.sorted {
                if $0.manager != $1.manager { return $0.manager.rawValue < $1.manager.rawValue }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            let next = PackageInventory(packages: sortedPackages, errors: nextErrors)
            let index = PackageIndex(packages: sortedPackages, catalogPackages: catalogPackages, newUpdatedLastClickedAt: newUpdatedLastClickedAt)
            return (next, index)
        }.value
        apply(inventory: next, index: index)
    }
}

private struct PackageScanBatch: Sendable {
    let managers: Set<PackageManagerKind>
    var packages: [ManagedPackage] = []
    var errors: [String] = []

    var sections: Set<MainWindowSection> {
        Set(managers.map {
            switch $0 {
            case .cargoInstall: .cargoInstall
            case .homebrew: .homebrew
            case .npm: .npm
            case .npx: .npx
            case .uv: .uv
            case .uvx: .uvx
            }
        })
    }
}

struct PackageIndex: Sendable {
    static let empty = PackageIndex(packages: [], catalogPackages: [], newUpdatedLastClickedAt: nil)

    let packagesBySection: [MainWindowSection: [ManagedPackage]]
    let countsBySection: [MainWindowSection: Int]
    let newUpdatedUnreadCount: Int?

    init(packages: [ManagedPackage], catalogPackages: [ManagedPackage], newUpdatedLastClickedAt: Date?) {
        let newUpdated = catalogPackages
            .filter { $0.pulseKind != nil }
            .sorted(by: Self.newestUpdatedFirst)

        var bySection: [MainWindowSection: [ManagedPackage]] = [
            .installed: packages.sorted(by: Self.alphabetical),
            .outdated: packages.filter(\.isOutdated).sorted(by: Self.mostOutdatedFirst),
            .newUpdated: newUpdated,
            .cargoInstall: packages.filter { $0.manager == .cargoInstall }.sorted(by: Self.alphabetical),
            .homebrew: packages.filter { $0.manager == .homebrew }.sorted(by: Self.alphabetical),
            .npm: packages.filter { $0.manager == .npm }.sorted(by: Self.alphabetical),
            .npx: packages.filter { $0.manager == .npx }.sorted(by: Self.alphabetical),
            .uv: packages.filter { $0.manager == .uv }.sorted(by: Self.alphabetical),
            .uvx: packages.filter { $0.manager == .uvx }.sorted(by: Self.alphabetical),
        ]

        for section in MainWindowSection.categorySections {
            bySection[section] = catalogPackages
                .filter { $0.category == section.categoryIdentifier }
                .sorted(by: Self.newestUpdatedFirst)
        }

        packagesBySection = bySection
        countsBySection = bySection.mapValues(\.count)

        let clickedAt = newUpdatedLastClickedAt.map { ISO8601DateFormatter().string(from: $0) }
        let unread = newUpdated.filter {
            guard let clickedAt else { return $0.pulseKind == "new" }
            return ($0.lastUpdatedAt ?? "") > clickedAt
        }.count
        newUpdatedUnreadCount = unread > 0 ? unread : nil
    }

    private static func alphabetical(_ lhs: ManagedPackage, _ rhs: ManagedPackage) -> Bool {
        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
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
