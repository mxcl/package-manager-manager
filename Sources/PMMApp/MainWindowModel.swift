import AppKit
import Foundation
import PMMCore

enum MainWindowSection: String, CaseIterable, Identifiable {
    case installed
    case outdated
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
    static let utilitySections: [MainWindowSection] = [.about]

    var title: String {
        switch self {
        case .installed: "Installed"
        case .outdated: "Outdated"
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
    @Published private(set) var errors: [String] = []
    @Published var searchText = ""

    private var inventory = PackageInventory(packages: [])

    var activeSidebarSection: MainWindowSection? { selectedSection }

    var visibleManagerSections: [MainWindowSection] {
        MainWindowSection.managerSections.filter { (count(for: $0) ?? 0) > 0 }
    }

    var visibleCategorySections: [MainWindowSection] {
        MainWindowSection.categorySections.filter { (count(for: $0) ?? 0) > 0 }
    }

    var displayedPackages: [ManagedPackage] {
        let base: [ManagedPackage] = switch selectedSection {
        case .installed:
            packages
        case .outdated:
            packages.filter(\.isOutdated)
        case .homebrew:
            packages.filter { $0.manager == .homebrew }
        case .npm:
            packages.filter { $0.manager == .npm }
        case .npx:
            packages.filter { $0.manager == .npx }
        case .about:
            []
        default:
            packages.filter { $0.category == selectedSection.categoryIdentifier }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return base }
        return base.filter { $0.name.localizedCaseInsensitiveContains(query) || ($0.summary?.localizedCaseInsensitiveContains(query) == true) }
    }

    func reload() {
        isReloading = true
        Task {
            let db = await PackageDatabase.load()
            let next = await PackageScanner().inventory(database: db)
            inventory = next
            packages = next.packages
            errors = next.errors
            selectedPackage = selectedPackage.flatMap { selected in packages.first { $0.id == selected.id } } ?? packages.first
            isReloading = false
        }
    }

    func selectSection(_ section: MainWindowSection) {
        selectedSection = section
        selectedPackage = displayedPackages.first
    }

    func select(_ package: ManagedPackage) {
        selectedPackage = package
    }

    func count(for section: MainWindowSection) -> Int? {
        switch section {
        case .about: nil
        case .installed: packages.count
        case .outdated: packages.filter(\.isOutdated).count
        case .homebrew: packages.filter { $0.manager == .homebrew }.count
        case .npm: packages.filter { $0.manager == .npm }.count
        case .npx: packages.filter { $0.manager == .npx }.count
        default:
            packages.filter { $0.category == section.categoryIdentifier }.count
        }
    }

    func open(url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}
