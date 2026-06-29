import AppKit
import Foundation
import PMMCore

enum MainWindowSection: String, CaseIterable, Identifiable, Sendable {
    case installed
    case outdated
    case newUpdated
    case homebrew
    case npm
    case npx
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
    static let managerSections: [MainWindowSection] = [.homebrew, .npm, .npx]
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
        case .homebrew: "Homebrew"
        case .npm: "npm"
        case .npx: "npx"
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
        case .homebrew: "mug"
        case .npm: "shippingbox.circle"
        case .npx: "terminal"
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
    var id: String { rawValue }
    var title: String { "Home" }
}

@MainActor
final class MainWindowModel: ObservableObject {
    @Published var selectedSection: MainWindowSection = .installed
    @Published private(set) var packages: [ManagedPackage] = []
    @Published private(set) var selectedPackage: ManagedPackage?
    @Published private(set) var isReloading = false
    @Published private(set) var loadingManagerSections = Set(MainWindowSection.managerSections)
    @Published private(set) var errors: [String] = []
    @Published var searchText = ""

    nonisolated private static let newUpdatedLastClickedAtDefaultsKey = "MainWindowModel.newUpdatedLastClickedAt"

    private var inventory = PackageInventory(packages: [])
    private var packageIndex = PackageIndex.empty
    private var newUpdatedLastClickedAt: Date?
    private var newUpdatedSelectionDisplayCount: Int?
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
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
        selectedPackage = displayedPackages.first
    }

    func select(_ package: ManagedPackage) {
        selectedPackage = package
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

    private var newUpdatedUnreadCount: Int? {
        packageIndex.newUpdatedUnreadCount
    }

    private func recordNewUpdatedSidebarClick() {
        let clickedAt = Date()
        newUpdatedLastClickedAt = clickedAt
        userDefaults.set(clickedAt, forKey: Self.newUpdatedLastClickedAtDefaultsKey)
    }

    private func apply(inventory next: PackageInventory, index: PackageIndex) {
        inventory = next
        packageIndex = index
        packages = next.packages
        errors = next.errors
        selectedPackage = selectedPackage.flatMap { selected in displayedPackages.first { $0.id == selected.id } } ?? displayedPackages.first
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
                do { return PackageScanBatch(managers: [.homebrew], packages: try scanner.scanHomebrew(database: database)) }
                catch { return PackageScanBatch(managers: [.homebrew], errors: [error.localizedDescription]) }
            }
            group.addTask {
                let scanner = PackageScanner()
                do { return PackageScanBatch(managers: [.npm], packages: try scanner.scanNPM(database: database)) }
                catch { return PackageScanBatch(managers: [.npm], errors: [error.localizedDescription]) }
            }
            group.addTask {
                let scanner = PackageScanner()
                do { return PackageScanBatch(managers: [.npx], packages: try scanner.scanNPX(database: database)) }
                catch { return PackageScanBatch(managers: [.npx], errors: [error.localizedDescription]) }
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
            case .homebrew: .homebrew
            case .npm: .npm
            case .npx: .npx
            }
        })
    }
}

private struct PackageIndex: Sendable {
    static let empty = PackageIndex(packages: [], catalogPackages: [], newUpdatedLastClickedAt: nil)

    let packagesBySection: [MainWindowSection: [ManagedPackage]]
    let countsBySection: [MainWindowSection: Int]
    let newUpdatedUnreadCount: Int?

    init(packages: [ManagedPackage], catalogPackages: [ManagedPackage], newUpdatedLastClickedAt: Date?) {
        let newUpdated = catalogPackages
            .filter { $0.pulseKind != nil }
            .sorted { ($0.lastUpdatedAt ?? "") > ($1.lastUpdatedAt ?? "") }

        var bySection: [MainWindowSection: [ManagedPackage]] = [
            .installed: packages,
            .outdated: packages.filter(\.isOutdated),
            .newUpdated: newUpdated,
            .homebrew: packages.filter { $0.manager == .homebrew },
            .npm: packages.filter { $0.manager == .npm },
            .npx: packages.filter { $0.manager == .npx },
        ]

        for section in MainWindowSection.categorySections {
            bySection[section] = catalogPackages.filter { $0.category == section.categoryIdentifier }
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
}
