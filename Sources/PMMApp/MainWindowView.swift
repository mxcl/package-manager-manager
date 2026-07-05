import AppKit
import PMMCore
import Foundation
import SwiftUI
import WebKit

struct MainWindowSidebarView: View {
    @ObservedObject var model: MainWindowModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                searchField
                    .padding(.bottom, 18)
                ForEach(MainWindowSection.librarySections) { sidebarRow($0) }
                if !model.visibleManagerSections.isEmpty {
                    Spacer(minLength: 18)
                    Section("Ecosystems") {
                        ForEach(model.visibleManagerSections) { sidebarRow($0) }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                if !model.visibleCategorySections.isEmpty {
                    Spacer(minLength: 18)
                    Section("Categories") {
                        ForEach(model.visibleCategorySections) { sidebarRow($0) }
                        Spacer(minLength: 8)
                        ForEach(MainWindowSection.categoryShortcutSections) { sidebarRow($0) }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    private func sidebarHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(AVGlassPalette.quietText)
            .tracking(0.5)
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
    }

    private var sidebarDivider: some View {
        Rectangle()
            .frame(height: 1)
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
    }

    private func sidebarRow(_ section: MainWindowSection) -> some View {
        Button { model.selectSection(section) } label: {
            HStack(spacing: 8) {
                sidebarIcon(section)
                Text(section.title)
                    .font(.system(size: 14, weight: .regular))
                    .lineLimit(1)
                Spacer(minLength: 6)
                if model.isLoadingCount(for: section) {
                    ProgressView()
                        .controlSize(.small)
                        .fixedSize()
                } else if let count = model.count(for: section), count > 0 {
                    if section == .newUpdated {
                        CountPill(count: count)
                            .fixedSize()
                    } else {
                        SidebarCountText(count: count)
                            .fixedSize()
                    }
                }
            }
            .padding(.horizontal, 6)
            .foregroundStyle(model.activeSidebarSection == section ? Color.accentColor : .primary)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                if model.activeSidebarSection == section {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.selection.opacity(0.22))
                        .background {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(.ultraThinMaterial)
                        }
                }
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    private func sidebarIcon(_ section: MainWindowSection) -> some View {
        Image(systemName: section.systemImage)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(model.activeSidebarSection == section ? Color.accentColor : .primary)
            .frame(width: 20, height: 20)
    }
}

struct MainWindowPackageListView: View {
    @ObservedObject var model: MainWindowModel

    var body: some View {
        ScrollView {
            let displayedPackages = model.displayedPackages
            if model.isReloading && displayedPackages.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(displayedPackages) { package in
                        PackageRow(
                            package: package,
                            selected: model.selectedPackage?.id == package.id,
                            showsManager: model.activeSidebarSection == .outdated || (model.activeSidebarSection?.packageManagers.count ?? 0) > 1,
                            versionText: mainWindowVersionText(package, section: model.activeSidebarSection)
                        ) {
                            model.select(package)
                        }
                    }
                }
            }
        }
        .safeAreaBar(edge: .top, alignment: .leading, spacing: 0) {
            HStack {
                Text("Package (Middle) Manager")
                Spacer()
                if model.isReloading { ProgressView().controlSize(.small) }
            }
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 42)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .ignoresSafeArea(.container, edges: .top)
    }
}

struct MainWindowDossierView: View {
    @ObservedObject var model: MainWindowModel

    var body: some View {
        ZStack {
            ScrollView {
                if let package = model.selectedPackage {
                    VStack(alignment: .leading, spacing: 20) {
                        DossierHeader(package: package)
                        if PackageUninstaller.supports(package) {
                            Button { model.uninstall(package) } label: {
                                Label("Uninstall", systemImage: "trash")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .tint(.red)
                            .disabled(isPackageActionRunning)
                        }
                        if package.isOutdated {
                            PackageBadgeBanner(text: "Outdated \(mainWindowVersionText(package))", color: AVGlassPalette.orange)
                            if PackageUpdater.supports(package) {
                                Button { model.update(package) } label: {
                                    Label("Update", systemImage: "arrow.down.circle")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                                .tint(AVGlassPalette.orange)
                                .disabled(isPackageActionRunning)
                            }
                        }
                        PackagePageSection(model: model)
                        PackageConfigurationSection(locations: model.selectedPackageConfigurationLocations)
                        PackageLocationSection(package: package)
                        if !mainWindowBrowserLinks(for: package).isEmpty {
                            InfoSection(title: "External URLs") {
                                PackageLinkStack(model: model)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 28)
                    .padding(.bottom, 32)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LiquidGlassSurface(material: .ultraThinMaterial, tint: AVGlassPalette.windowTint).ignoresSafeArea())
        .sheet(isPresented: uninstallModalBinding) {
            PackageProgressView(title: "Uninstalling \(model.uninstallingPackageName ?? "package")")
                .interactiveDismissDisabled(true)
        }
        .sheet(isPresented: updateModalBinding) {
            PackageProgressView(title: "Updating \(model.updatingPackageName ?? "package")")
                .interactiveDismissDisabled(true)
        }
    }

    private var isPackageActionRunning: Bool {
        model.uninstallingPackageName != nil || model.updatingPackageName != nil
    }

    private var uninstallModalBinding: Binding<Bool> {
        Binding(get: { model.uninstallingPackageName != nil }, set: { _ in })
    }

    private var updateModalBinding: Binding<Bool> {
        Binding(get: { model.updatingPackageName != nil }, set: { _ in })
    }
}

struct MainWindowLinksView: View {
    @ObservedObject var model: MainWindowModel

    var body: some View {
        let links = mainWindowBrowserLinks(for: model.selectedPackage)
        let selectedURL = selectedLink(in: links)?.url

        Group {
            if let url = selectedURL {
                PackageWebView(url: url)
            } else {
                Spacer(minLength: 0)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(LiquidGlassSurface(material: .ultraThinMaterial, tint: AVGlassPalette.windowTint).ignoresSafeArea())
        .onChange(of: links) { _, links in
            if let selectedTab = model.selectedLinkTab, !links.contains(where: { $0.tab == selectedTab }) {
                model.selectedLinkTab = nil
            }
        }
    }

    private func selectedLink(in links: [MainWindowBrowserLink]) -> MainWindowBrowserLink? {
        mainWindowSelectedBrowserLink(in: links, selectedTab: model.selectedLinkTab)
    }
}

struct MainWindowDashboardView: View {
    @ObservedObject var model: MainWindowModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                dashboardStats
                HStack(alignment: .top, spacing: 16) {
                    dashboardMainColumn
                        .frame(minWidth: 0, maxWidth: .infinity)
                    dashboardSideColumn
                        .frame(width: 310)
                }
                DashboardProBanner()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 18)
        }
        .safeAreaBar(edge: .top, alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Dashboard")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AVGlassPalette.primaryText)
                Spacer()
                if model.dashboardIsLoadingData {
                    ProgressView()
                        .controlSize(.small)
                } else if let lastUpdated = model.dashboardLastUpdatedText {
                    Text(lastUpdated)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AVGlassPalette.quietText)
                }
                Button { model.reload() } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .help("Refresh packages")
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(LiquidGlassSurface(material: .ultraThinMaterial, tint: AVGlassPalette.windowTint))
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .ignoresSafeArea(.container, edges: .top)
        .background(LiquidGlassSurface(material: .ultraThinMaterial, tint: AVGlassPalette.windowTint).ignoresSafeArea())
    }

    private var dashboardStats: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 110), spacing: 14), count: 4), spacing: 14) {
            DashboardMetricCard(title: "Installed packages", value: model.dashboardInstalledCount, detail: "+12 this week", isLoading: model.dashboardIsLoadingData, tint: .green)
            DashboardMetricCard(title: "Outdated", value: model.dashboardOutdatedCount, detail: "View updates", isLoading: model.dashboardIsLoadingData, tint: Color.accentColor)
            DashboardMetricCard(title: "Ecosystems", value: model.dashboardActiveEcosystemCount, detail: "Active", isLoading: model.dashboardIsLoadingData, tint: AVGlassPalette.secondaryText)
            DashboardMetricCard(title: "Install packs", value: 3, detail: "1 update available", isLoading: false, tint: Color.accentColor)
        }
    }

    private var dashboardMainColumn: some View {
        VStack(spacing: 16) {
            DashboardPackageSection(
                title: "What's New",
                systemImage: "sparkle",
                packages: model.dashboardWhatsNewPackages,
                isLoading: model.dashboardIsLoadingData,
                emptyText: "No new packages yet"
            )
            DashboardRecommendationSection(
                packages: model.dashboardRecommendedPackages,
                isLoading: model.dashboardIsLoadingData
            )
        }
    }

    private var dashboardSideColumn: some View {
        VStack(spacing: 16) {
            DashboardSponsoredCard()
            DashboardUpdatesCard()
            DashboardInstallPacksCard()
        }
    }
}

private struct DashboardCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AVGlassPalette.cardFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AVGlassPalette.controlBorder, lineWidth: 1)
        }
    }
}

private struct DashboardMetricCard: View {
    let title: String
    let value: Int?
    let detail: String
    let isLoading: Bool
    let tint: Color

    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 8) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(height: 29, alignment: .leading)
                } else {
                    Text((value ?? 0).formatted())
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(AVGlassPalette.primaryText)
                        .monospacedDigit()
                }
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AVGlassPalette.secondaryText)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tint)
                    .lineLimit(1)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
        }
    }
}

private struct DashboardPackageSection: View {
    let title: String
    let systemImage: String
    let packages: [ManagedPackage]
    let isLoading: Bool
    let emptyText: String

    var body: some View {
        DashboardCard {
            DashboardSectionHeader(title: title, systemImage: systemImage)
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 260)
            } else if packages.isEmpty {
                Text(emptyText)
                    .font(.system(size: 13))
                    .foregroundStyle(AVGlassPalette.quietText)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(packages) { package in
                        DashboardPackageRow(package: package)
                        if package.id != packages.last?.id {
                            Divider().overlay(AVGlassPalette.hairline)
                        }
                    }
                }
            }
        }
    }
}

private struct DashboardSectionHeader: View {
    let title: String
    let systemImage: String?

    init(title: String, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AVGlassPalette.primaryText)
            Spacer()
            Text("View all")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct DashboardPackageRow: View {
    let package: ManagedPackage

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(AVGlassPalette.controlFill)
                Image(systemName: package.manager.dashboardSymbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AVGlassPalette.primaryText)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(package.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AVGlassPalette.primaryText)
                        .lineLimit(1)
                    if package.pulseKind == "new" {
                        PackageBadgePill(text: "New", color: Color.accentColor)
                    }
                    Text(package.manager.title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(AVGlassPalette.quietText)
                        .lineLimit(1)
                }
                Text(package.summary ?? mainWindowCategoryTitle(package.category) ?? "Package")
                    .font(.system(size: 12))
                    .foregroundStyle(AVGlassPalette.secondaryText)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down.right")
                        .font(.system(size: 9, weight: .bold))
                    Text(package.dashboardFooter)
                        .font(.system(size: 11))
                }
                .foregroundStyle(AVGlassPalette.quietText)
            }
            Spacer(minLength: 8)
            Text("Install")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 72, height: 30)
                .background(AVGlassPalette.controlFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(AVGlassPalette.controlBorder, lineWidth: 1)
                }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 62)
    }
}

private struct DashboardRecommendationSection: View {
    let packages: [ManagedPackage]
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DashboardSectionHeader(title: "Recommended for You")
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else if packages.isEmpty {
                Text("No recommendations yet")
                    .font(.system(size: 13))
                    .foregroundStyle(AVGlassPalette.quietText)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 130), spacing: 12), count: 3), spacing: 12) {
                    ForEach(packages) { package in
                        DashboardRecommendationCard(package: package)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DashboardRecommendationCard: View {
    let package: ManagedPackage

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack {
                Circle().fill(AVGlassPalette.controlFill)
                Image(systemName: package.manager.dashboardSymbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(AVGlassPalette.primaryText)
            }
            .frame(width: 38, height: 38)
            Text(package.displayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AVGlassPalette.primaryText)
                .lineLimit(1)
            Text(package.summary ?? package.manager.title)
                .font(.system(size: 11))
                .foregroundStyle(AVGlassPalette.secondaryText)
                .lineLimit(2)
                .frame(minHeight: 28, alignment: .topLeading)
            Spacer(minLength: 0)
            Text("Install")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(AVGlassPalette.controlFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .padding(12)
        .frame(minHeight: 150, alignment: .topLeading)
        .background(AVGlassPalette.controlFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AVGlassPalette.controlBorder, lineWidth: 1)
        }
    }
}

private struct DashboardSponsoredCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Spacer(minLength: 0)
            Image(systemName: "lock.shield")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
            Text("Secure every install.")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
            Text("Zero-trust for the tools you use every day.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(2)
            Text("Learn more")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.black.opacity(0.86))
                .padding(.horizontal, 18)
                .frame(height: 32)
                .background(.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            HStack {
                Spacer()
                Text("SPONSORED")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 200, alignment: .leading)
        .background {
            LinearGradient(
                colors: [Color(red: 0.35, green: 0.16, blue: 0.62), Color(red: 0.98, green: 0.44, blue: 0.25), Color(red: 0.05, green: 0.06, blue: 0.10)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AVGlassPalette.controlBorder, lineWidth: 1)
        }
    }
}

private struct DashboardUpdatesCard: View {
    private let updates = [
        ("Introducing Install Packs", "Ship complete workflows in one click", "May 28, 2025", "shippingbox"),
        ("Hermes in a Box: Safer agents", "Contain, approve, control", "May 22, 2025", "lock.cube"),
        ("10,000 packages. One mission.", "Securing the open source supply chain", "May 15, 2025", "network.badge.shield.half.filled"),
    ]

    var body: some View {
        DashboardCard {
            DashboardSectionHeader(title: "Blog & Updates")
            VStack(spacing: 12) {
                ForEach(updates, id: \.0) { update in
                    HStack(spacing: 12) {
                        Image(systemName: update.3)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(AVGlassPalette.primaryText)
                            .frame(width: 48, height: 48)
                            .background(AVGlassPalette.controlFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(update.0)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(AVGlassPalette.primaryText)
                                .lineLimit(1)
                            Text(update.1)
                                .font(.system(size: 11))
                                .foregroundStyle(AVGlassPalette.secondaryText)
                                .lineLimit(1)
                            Text(update.2)
                                .font(.system(size: 11))
                                .foregroundStyle(AVGlassPalette.quietText)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
    }
}

private struct DashboardInstallPacksCard: View {
    private let packs = [
        ("Agent Assistant", "18 tools for AI agent workflows", "sparkles"),
        ("Web Developer", "12 essential web dev tools", "curlybraces"),
        ("Data Scientist", "15 tools for data analysis", "chart.xyaxis.line"),
    ]

    var body: some View {
        DashboardCard {
            DashboardSectionHeader(title: "Install Packs")
            VStack(spacing: 0) {
                ForEach(packs, id: \.0) { pack in
                    HStack(spacing: 12) {
                        Image(systemName: pack.2)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Color.accentColor.opacity(0.75), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(pack.0)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(AVGlassPalette.primaryText)
                                .lineLimit(1)
                            Text(pack.1)
                                .font(.system(size: 11))
                                .foregroundStyle(AVGlassPalette.secondaryText)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text("Install")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 58, height: 30)
                            .background(AVGlassPalette.controlFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    if pack.0 != packs.last?.0 {
                        Divider().overlay(AVGlassPalette.hairline)
                    }
                }
            }
        }
    }
}

private struct DashboardProBanner: View {
    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Upgrade to Pro")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color(red: 0.70, green: 0.42, blue: 1.00))
                Text("Get advanced security scanning, private packages, and team features.")
                    .font(.system(size: 12))
                    .foregroundStyle(AVGlassPalette.secondaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            VStack(alignment: .leading, spacing: 6) {
                DashboardCheckmarkText(text: "Security scanning")
                DashboardCheckmarkText(text: "Private repositories")
                DashboardCheckmarkText(text: "Team management")
            }
            Text("Learn more")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(height: 34)
                .background(Color(red: 0.52, green: 0.28, blue: 0.90), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: 78)
        .background(Color(red: 0.18, green: 0.13, blue: 0.28).opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(red: 0.45, green: 0.29, blue: 0.70).opacity(0.58), lineWidth: 1)
        }
    }
}

private struct DashboardCheckmarkText: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
            Text(text)
                .font(.system(size: 11))
        }
        .foregroundStyle(AVGlassPalette.secondaryText)
    }
}

struct MainWindowBrowserLink: Equatable, Identifiable {
    let title: String
    let tab: MainWindowLinkTab?
    let url: URL

    var id: String { tab?.rawValue ?? url.absoluteString }
}

struct MainWindowConfigurationLocation: Equatable, Identifiable {
    let path: String

    var id: String { path }
}

struct MainWindowPackageLocation: Equatable, Identifiable {
    let label: String
    let path: String

    var id: String { "\(label):\(path)" }
    var displayValue: String { mainWindowHomeRelativePath(path) }
}

func mainWindowPackageLocations(for package: ManagedPackage) -> [MainWindowPackageLocation] {
    [
        package.installLocation.map { MainWindowPackageLocation(label: "Install Root", path: $0) },
        package.binaryPath.map { MainWindowPackageLocation(label: "Binary", path: $0) },
    ].compactMap { $0 }
}

func mainWindowConfigurationLocations(for dossier: PackageDossierPage?, resolve: (String) -> String = { $0 }) -> [MainWindowConfigurationLocation] {
    let paths = mainWindowRawConfigurationPaths(for: dossier)
        .map(resolve)
        .filter(mainWindowIsAbsolutePath)
    var seen = Set<String>()
    return paths.filter { seen.insert($0).inserted }.map { MainWindowConfigurationLocation(path: $0) }
}

func mainWindowResolvedConfigurationLocations(for dossier: PackageDossierPage?) async -> [MainWindowConfigurationLocation] {
    await Task.detached {
        let resolvedPaths = mainWindowResolveShellPaths(mainWindowRawConfigurationPaths(for: dossier))
            .filter(mainWindowIsAbsolutePath)
        var seen = Set<String>()
        return resolvedPaths.filter { seen.insert($0).inserted }.map { MainWindowConfigurationLocation(path: $0) }
    }.value
}

private func mainWindowRawConfigurationPaths(for dossier: PackageDossierPage?) -> [String] {
    guard let dossier else { return [] }
    return [dossier.configFileLocations, dossier.credentialsFileLocations].flatMap { locations in
        ["macos", "unix"].flatMap { platform in
            locations[platform] ?? []
        }
    }
}

private func mainWindowIsAbsolutePath(_ path: String) -> Bool {
    path.hasPrefix("/")
}

func mainWindowResolveShellPaths(_ paths: [String]) -> [String] {
    let paths = paths.filter { !mainWindowReferencesUnsetEnvironmentVariable($0) }
    guard !paths.isEmpty else { return [] }
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-lc", #"for p in "$@"; do print -r -- ${(e)p}; done"#, "--"] + paths.map(mainWindowShellExpandablePath)
    process.standardOutput = output
    guard (try? process.run()) != nil else { return paths.map(mainWindowExpandTilde) }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return paths.map(mainWindowExpandTilde) }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let resolved = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let resolvedPaths = resolved.last == "" ? Array(resolved.dropLast()) : resolved
    return resolvedPaths.map(mainWindowExpandTilde)
}

private func mainWindowShellExpandablePath(_ path: String) -> String {
    let unsafe = CharacterSet(charactersIn: "`();&|<>\n\r")
    return path.rangeOfCharacter(from: unsafe) == nil ? path : mainWindowExpandTilde(path)
}

private func mainWindowExpandTilde(_ path: String) -> String {
    NSString(string: path).expandingTildeInPath
}

func mainWindowReferencesUnsetEnvironmentVariable(_ path: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
    var index = path.startIndex
    while index < path.endIndex {
        guard path[index] == "$" else {
            index = path.index(after: index)
            continue
        }

        let next = path.index(after: index)
        guard next < path.endIndex else { return false }

        if path[next] == "{" {
            guard let close = path[next...].firstIndex(of: "}") else { return false }
            let nameStart = path.index(after: next)
            let name = String(path[nameStart..<close])
            if mainWindowIsEnvironmentName(name), environment[name]?.isEmpty != false { return true }
            index = path.index(after: close)
        } else if mainWindowIsEnvironmentNameStart(path[next]) {
            var end = next
            while end < path.endIndex, mainWindowIsEnvironmentNameCharacter(path[end]) {
                end = path.index(after: end)
            }
            let name = String(path[next..<end])
            if environment[name]?.isEmpty != false { return true }
            index = end
        } else {
            index = next
        }
    }
    return false
}

private func mainWindowIsEnvironmentName(_ name: String) -> Bool {
    guard let first = name.first, mainWindowIsEnvironmentNameStart(first) else { return false }
    return name.allSatisfy(mainWindowIsEnvironmentNameCharacter)
}

private func mainWindowIsEnvironmentNameStart(_ character: Character) -> Bool {
    character == "_" || character.isLetter
}

private func mainWindowIsEnvironmentNameCharacter(_ character: Character) -> Bool {
    character == "_" || character.isLetter || character.isNumber
}

func mainWindowBrowserLinks(for package: ManagedPackage?) -> [MainWindowBrowserLink] {
    let links = mainWindowLinks(for: package).map {
        MainWindowBrowserLink(title: $0.tab.title, tab: $0.tab, url: $0.url)
    }
    if let releaseNotesURL = mainWindowReleaseNotesURL(for: package) {
        return [MainWindowBrowserLink(title: "Releases", tab: nil, url: releaseNotesURL)] + links
    }
    return links
}

func mainWindowSelectedBrowserLink(in links: [MainWindowBrowserLink], selectedTab: MainWindowLinkTab?) -> MainWindowBrowserLink? {
    if let selectedTab {
        return links.first { $0.tab == selectedTab } ?? links.first
    }
    return links.first
}

func mainWindowBrowserDisplayURL(_ url: URL) -> String {
    var string = url.absoluteString
    for prefix in ["https://", "http://"] where string.hasPrefix(prefix) {
        string.removeFirst(prefix.count)
        break
    }
    if string.count > 1, string.hasSuffix("/") {
        string.removeLast()
    }
    return string
}

private func mainWindowVersionText(_ package: ManagedPackage, section: MainWindowSection? = nil) -> String {
    if section == .newUpdated, let pulseKind = package.pulseKind {
        return pulseKind.capitalized
    }
    if package.isOutdated {
        if section == nil || section == .outdated {
            return "\(package.installedVersion ?? "?") → \(package.latestVersion ?? "?")"
        }
        return package.installedVersion ?? package.latestVersion ?? "available"
    }
    if section?.categoryIdentifier != nil, package.installedVersion == nil, package.latestVersion == nil {
        return package.manager.title
    }
    return package.installedVersion ?? package.latestVersion ?? "available"
}

private func mainWindowHomeRelativePath(_ path: String?) -> String {
    guard let path else { return "unknown" }
    let home = NSHomeDirectory()
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~/" + String(path.dropFirst(home.count + 1)) }
    return path
}

func mainWindowCategoryTitle(_ category: String?) -> String? {
    guard let category, !category.isEmpty else { return nil }
    if let section = MainWindowSection.categorySections.first(where: { $0.categoryIdentifier == category }) {
        return section.title
    }
    return category.split(separator: "-").map { word in
        word.prefix(1).uppercased() + word.dropFirst()
    }.joined(separator: " ")
}

private extension PackageManagerKind {
    var dashboardSymbol: String {
        switch self {
        case .cargoInstall, .rustup: "hammer"
        case .homebrew: "mug"
        case .npm, .npx: "curlybraces"
        case .uv, .uvx: "shippingbox.circle"
        }
    }
}

private extension ManagedPackage {
    var dashboardFooter: String {
        if let category = mainWindowCategoryTitle(category) {
            return "Popular in \(category)"
        }
        if let latestVersion {
            return "Latest \(latestVersion)"
        }
        return manager.title
    }
}

private extension MainWindowSidebarView {
    var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
            TextField("Search", text: $model.searchText)
                .textFieldStyle(.plain)
        }
        .font(.system(size: 13))
        .foregroundStyle(AVGlassPalette.secondaryText)
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(AVGlassPalette.searchFill, in: Capsule(style: .continuous))
    }
}

private struct PackageLinkStack: View {
    @ObservedObject var model: MainWindowModel

    var body: some View {
        let links = mainWindowBrowserLinks(for: model.selectedPackage)
        let selected = mainWindowSelectedBrowserLink(in: links, selectedTab: model.selectedLinkTab)

        if !links.isEmpty {
            VStack(spacing: 2) {
                ForEach(links) { link in
                    PackageLinkRow(
                        link: link,
                        selected: link.id == selected?.id
                    ) {
                        model.selectedLinkTab = link.tab
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct PackageLinkRow: View {
    let link: MainWindowBrowserLink
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(link.title.uppercased())
                    .font(.system(size: 9, weight: .medium))
                    .tracking(1)
                    .foregroundStyle(selected ? AVGlassPalette.primaryText : AVGlassPalette.quietText)
                    .fixedSize(horizontal: true, vertical: false)
                Text(mainWindowBrowserDisplayURL(link.url))
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? AVGlassPalette.secondaryText : AVGlassPalette.quietText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(AVGlassPalette.linkSelectedFill)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct PackageLocationSection: View {
    let package: ManagedPackage

    var body: some View {
        InfoSection(title: "Location") {
            if let installLocation = package.installLocation {
                LocationButton(label: "Install Root", path: installLocation, action: revealInFinder)
            } else {
                InfoRow(label: "Install Root", value: "unknown")
            }
            if let binaryPath = package.binaryPath {
                LocationButton(label: "Binary", path: binaryPath, action: revealInFinder)
            } else {
                InfoRow(label: "Binary", value: "unknown")
            }
        }
    }

    private func revealInFinder(_ path: String) {
        let expandedPath = NSString(string: path).expandingTildeInPath
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: expandedPath)])
    }
}

private struct LocationButton: View {
    let label: String
    let path: String
    let action: (String) -> Void

    var body: some View {
        Button {
            action(path)
        } label: {
            InfoRow(label: label, value: mainWindowHomeRelativePath(path))
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

private struct PackageConfigurationSection: View {
    let locations: [MainWindowConfigurationLocation]

    var body: some View {
        if !locations.isEmpty {
            InfoSection(title: "Configuration") {
                VStack(spacing: 2) {
                    ForEach(locations) { location in
                        ConfigurationLocationRow(location: location) {
                            openConfigurationFile(at: location.path)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func openConfigurationFile(at path: String) {
        Task.detached {
            let expandedPath = (try? mainWindowPrepareEditableFile(at: path)) ?? NSString(string: path).expandingTildeInPath
            _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/open"), arguments: ["-t", expandedPath])
        }
    }
}

func mainWindowPrepareEditableFile(at path: String) throws -> String {
    let expandedPath = NSString(string: path).expandingTildeInPath
    let url = URL(fileURLWithPath: expandedPath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: expandedPath) {
        _ = FileManager.default.createFile(atPath: expandedPath, contents: Data())
    }
    return expandedPath
}

private struct ConfigurationLocationRow: View {
    let location: MainWindowConfigurationLocation
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(mainWindowHomeRelativePath(location.path))
                    .font(.system(size: 12))
                    .foregroundStyle(AVGlassPalette.quietText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct PackagePageSection: View {
    @ObservedObject var model: MainWindowModel

    var body: some View {
        if model.isLoadingSelectedPackageMetadata {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        } else if let dossier = model.selectedPackageDossier {
            VStack(alignment: .leading, spacing: 12) {
                if let license = nonEmpty(dossier.license) {
                    InfoRow(label: "License", value: license)
                }
                if !dossier.executables.isEmpty {
                    InfoRow(label: "Executables", value: dossier.executables.joined(separator: "\n"), valueLineLimit: nil)
                }
                if !dossier.dependencies.isEmpty {
                    InfoRow(label: "Dependencies", value: dossier.dependencies.prefix(12).joined(separator: ", "))
                }
                if !dossier.alsoAvailableVia.isEmpty {
                    InfoRow(label: "Also Available", value: dossier.alsoAvailableVia.prefix(5).compactMap(formatRelatedPackage).joined(separator: "\n"))
                }
                if let registry = dossier.registryInsights, let text = formatRegistryInsights(registry) {
                    InfoRow(label: "Registry", value: text)
                }
            }
        } else if let error = model.selectedPackageDossierError {
            InfoRow(label: "Package Page", value: error)
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private func formatRelatedPackage(_ package: PackageDossierRelatedPackage) -> String? {
        let label = nonEmpty(package.label) ?? nonEmpty(package.name)
        guard let label else { return nil }
        return [nonEmpty(package.provider), label].compactMap { $0 }.joined(separator: ": ")
    }

    private func formatRegistryInsights(_ registry: PackageDossierRegistryInsights) -> String? {
        var rows = [String]()
        if let source = nonEmpty(registry.sourceDatabase) { rows.append(source) }
        if let publisher = nonEmpty(registry.publisher) { rows.append("publisher: \(publisher)") }
        if let versionCount = registry.versionCount { rows.append("\(versionCount) versions") }
        if let latestPublishedAt = nonEmpty(registry.latestPublishedAt) { rows.append("latest: \(latestPublishedAt)") }
        if let maintainers = registry.maintainers?.prefix(4).joined(separator: ", "), !maintainers.isEmpty {
            rows.append("maintainers: \(maintainers)")
        }
        let text = rows.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }
}

private struct PackageRow: View {
    let package: ManagedPackage
    let selected: Bool
    let showsManager: Bool
    let versionText: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(package.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AVGlassPalette.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if package.isOutdated && !showsManager { PackageBadgePill(text: "Outdated", color: AVGlassPalette.orange) }
                    Spacer(minLength: 8)
                    Text(versionText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AVGlassPalette.secondaryText)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(AVGlassPalette.quietText)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(height: 66, alignment: .topLeading)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(AVGlassPalette.packageSelectedFill)
                }
            }
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var subtitle: String {
        if showsManager, let summary = package.summary {
            return "\(package.manager.title) · \(summary)"
        }
        return package.summary ?? package.manager.title
    }
}

private enum SidebarCountMetrics {
    static let columnWidth: CGFloat = 18
    static let pillHorizontalPadding: CGFloat = 8
}

private struct SidebarCountText: View {
    let count: Int

    var body: some View {
        Text(count.formatted())
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(AVGlassPalette.quietText)
            .monospacedDigit()
            .lineLimit(1)
            .frame(minWidth: SidebarCountMetrics.columnWidth, alignment: .trailing)
    }
}

private struct CountPill: View {
    let count: Int

    var body: some View {
        Text(count.formatted())
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(AVGlassPalette.secondaryText)
            .monospacedDigit()
            .padding(.horizontal, SidebarCountMetrics.pillHorizontalPadding)
            .frame(height: 20)
            .background(AVGlassPalette.controlFill, in: Capsule())
            .padding(.trailing, -SidebarCountMetrics.pillHorizontalPadding)
    }
}

private struct PackageBadgePill: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .tracking(0.5)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}

private struct PackageBadgeBanner: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct DossierHeader: View {
    let package: ManagedPackage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(package.displayName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(AVGlassPalette.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                if let version = package.installedVersion ?? package.latestVersion {
                    Text(version)
                        .font(.system(size: 14, weight: .thin))
                        .foregroundStyle(AVGlassPalette.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(package.manager.title.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(AVGlassPalette.quietText)
                    .tracking(0.8)
                if let category = mainWindowCategoryTitle(package.category) {
                    Text("·")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.tertiary)
                    Text(category)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            if let summary = package.summary {
                Text(summary)
                    .font(.system(size: 13))
                    .foregroundStyle(AVGlassPalette.secondaryText)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct InfoSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            VStack(alignment: .leading, spacing: 7) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(AVGlassPalette.quietText)
                    .tracking(0.8)
                Rectangle()
                    .fill(AVGlassPalette.hairline)
                    .frame(height: 1)
            }
            content
        }
    }
}

private struct InfoRow: View {
    let label: String
    let value: String
    var valueLineLimit: Int? = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AVGlassPalette.quietText)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(AVGlassPalette.secondaryText)
                .lineLimit(valueLineLimit)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PackageProgressView: View {
    let title: String

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AVGlassPalette.primaryText)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(width: 260)
        .background(LiquidGlassSurface(material: .ultraThinMaterial, tint: AVGlassPalette.windowTint))
    }
}

private struct PackageWebView: NSViewRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .white
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.loadedURL != url {
            context.coordinator.loadedURL = url
            context.coordinator.allowsEmbeddedNavigation = true
            webView.setValue(true, forKey: "drawsBackground")
            webView.load(URLRequest(url: initialBrowserURL(for: url)))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedURL: URL?
        var allowsEmbeddedNavigation = false

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            allowsEmbeddedNavigation = false
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard shouldOpenNavigationInSystemBrowser(allowsEmbeddedNavigation: allowsEmbeddedNavigation, targetFrameIsMainFrame: navigationAction.targetFrame?.isMainFrame) else {
                decisionHandler(.allow)
                return
            }

            if let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }
}

func shouldOpenNavigationInSystemBrowser(allowsEmbeddedNavigation: Bool, targetFrameIsMainFrame: Bool?) -> Bool {
    targetFrameIsMainFrame == nil || (targetFrameIsMainFrame == true && !allowsEmbeddedNavigation)
}

func initialBrowserURL(for url: URL) -> URL {
    guard url.host() == "github.com", url.fragment() == nil else { return url }
    let parts = url.pathComponents.filter { $0 != "/" }
    guard parts.count == 2, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
    components.fragment = "readme"
    return components.url ?? url
}

private struct LiquidGlassSurface: View {
    let material: Material
    let tint: Color
    var body: some View {
        Rectangle().fill(material).overlay(tint)
    }
}

private enum AVGlassPalette {
    static let windowTint = Color(red: 0.05, green: 0.06, blue: 0.07).opacity(0.50)
    static let sidebarTint = Color(red: 0.06, green: 0.07, blue: 0.07).opacity(0.72)
    static let primaryText = Color.white.opacity(0.92)
    static let secondaryText = Color.white.opacity(0.72)
    static let quietText = Color.white.opacity(0.42)
    static let hairline = Color.white.opacity(0.07)
    static let sidebarBorder = Color.white.opacity(0.14)
    static let sidebarSelectedFill = Color(red: 0.00, green: 0.38, blue: 0.86)
    static let packageSelectedFill = Color.white.opacity(0.08)
    static let linkSelectedFill = Color(red: 0.14, green: 0.16, blue: 0.16)
    static let controlFill = Color.white.opacity(0.07)
    static let cardFill = Color.white.opacity(0.055)
    static let searchFill = Color.white.opacity(0.11)
    static let controlBorder = Color.white.opacity(0.18)
    static let orange = Color(red: 0.95, green: 0.72, blue: 0.20)
}

#Preview("MainWindowSidebarView.sidebarRow") {
    // We need MainWindowModel and MainWindowSection to construct the view.
    // Please provide these types or accessible fixtures/mocks to proceed.
}
