import PMMCore
import SwiftUI

private let dashboardItemCornerRadius: CGFloat = 18

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
            }
            .padding(8.5)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .ignoresSafeArea(.container, edges: .top)
    }

    private var dashboardStats: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 110), spacing: 14), count: 4), spacing: 14) {
            DashboardMetricCard(title: "Installed packages", value: model.dashboardInstalledCount, detail: model.dashboardInstalledThisWeekText, isLoading: model.dashboardIsLoadingData, tint: AnyShapeStyle(.tertiary)) {
                model.selectSection(.installed)
            }
            DashboardMetricCard(title: "Outdated", value: model.dashboardOutdatedCount, detail: (model.dashboardOutdatedCount ?? 0) > 0 ? "View updates" : nil, isLoading: model.dashboardIsLoadingData, tint: AnyShapeStyle(Color.accentColor)) {
                model.selectSection(.outdated)
            }
            DashboardMetricCard(title: "Ecosystems", value: model.dashboardActiveEcosystemCount, detail: "Active", isLoading: model.dashboardIsLoadingData, tint: AnyShapeStyle(.tertiary)) {
                if let section = model.visibleManagerSections.first {
                    model.selectSection(section)
                }
            }
            DashboardMetricCard(title: "Install packs", value: 3, detail: "1 update available", isLoading: false, tint: AnyShapeStyle(Color.accentColor))
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
            ) {
                model.openDashboardPackage($0)
            } viewAllAction: {
                model.selectSection(.newUpdated)
            }
            DashboardRecommendationSection(
                packages: model.dashboardRecommendedPackages,
                isLoading: model.dashboardIsLoadingData
            ) {
                model.openDashboardPackage($0)
            }
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
        .background {
            RoundedRectangle(cornerRadius: dashboardItemCornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: dashboardItemCornerRadius, style: .continuous)
                        .fill(SystemColor.cardTint)
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: dashboardItemCornerRadius, style: .continuous)
                .stroke(SystemColor.controlBorder, lineWidth: 1)
        }
    }
}

private struct DashboardMetricCard: View {
    let title: String
    let value: Int?
    let detail: String?
    let isLoading: Bool
    let tint: AnyShapeStyle
    var action: (() -> Void)?

    @ViewBuilder
    var body: some View {
        if let action {
            Button(action: action) {
                card
            }
            .buttonStyle(.plain)
        } else {
            card
        }
    }

    private var card: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 8) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(height: 29, alignment: .leading)
                } else {
                    Text((value ?? 0).formatted())
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(SystemColor.primaryText)
                        .monospacedDigit()
                }
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SystemColor.secondaryText)
                    .lineLimit(1)
                Text(detail ?? "")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tint)
                    .lineLimit(1)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
            .contentShape(Rectangle())
        }
    }
}

private struct DashboardPackageSection: View {
    let title: String
    let systemImage: String
    let packages: [ManagedPackage]
    let isLoading: Bool
    let emptyText: String
    let action: (ManagedPackage) -> Void
    let viewAllAction: () -> Void

    var body: some View {
        DashboardCard {
            DashboardSectionHeader(title: title, systemImage: systemImage, viewAllAction: viewAllAction)
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 260)
            } else if packages.isEmpty {
                Text(emptyText)
                    .font(.system(size: 13))
                    .foregroundStyle(SystemColor.quietText)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(packages) { package in
                        DashboardPackageRow(package: package) {
                            action(package)
                        }
                        if package.id != packages.last?.id {
                            Divider().overlay(SystemColor.hairline)
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
    let viewAllAction: (() -> Void)?

    init(title: String, systemImage: String? = nil, viewAllAction: (() -> Void)? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.viewAllAction = viewAllAction
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
                .foregroundStyle(SystemColor.primaryText)
            Spacer()
            if let viewAllAction {
                Button("View all", action: viewAllAction)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            } else {
                Text("View all")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

private struct DashboardPackageRow: View {
    let package: ManagedPackage
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(SystemColor.controlFill)
                Image(systemName: package.manager.dashboardSymbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(SystemColor.primaryText)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(package.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SystemColor.primaryText)
                        .lineLimit(1)
                    if package.pulseKind == "new" {
                        PackageBadgePill(text: "New", color: Color.accentColor)
                    }
                    Text(package.manager.title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(SystemColor.quietText)
                        .lineLimit(1)
                }
                Text(package.summary ?? mainWindowCategoryTitle(package.category) ?? "Package")
                    .font(.system(size: 12))
                    .foregroundStyle(SystemColor.secondaryText)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down.right")
                        .font(.system(size: 9, weight: .bold))
                    Text(package.dashboardFooter)
                        .font(.system(size: 11))
                }
                .foregroundStyle(SystemColor.quietText)
            }
            Spacer(minLength: 8)
            Button("View Package", action: action)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 98, height: 30)
                .background(SystemColor.controlFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(SystemColor.controlBorder, lineWidth: 1)
                }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(minHeight: 62)
    }
}

private struct DashboardRecommendationSection: View {
    let packages: [ManagedPackage]
    let isLoading: Bool
    let action: (ManagedPackage) -> Void

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
                    .foregroundStyle(SystemColor.quietText)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 130), spacing: 12), count: 3), spacing: 12) {
                    ForEach(packages) { package in
                        DashboardRecommendationCard(package: package) {
                            action(package)
                        }
                    }
                }
                .padding(.bottom, 18)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DashboardRecommendationCard: View {
    let package: ManagedPackage
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack {
                Circle().fill(SystemColor.controlFill)
                Image(systemName: package.manager.dashboardSymbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(SystemColor.primaryText)
            }
            .frame(width: 38, height: 38)
            Text(package.displayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SystemColor.primaryText)
                .lineLimit(1)
            Text(package.summary ?? package.manager.title)
                .font(.system(size: 11))
                .foregroundStyle(SystemColor.secondaryText)
                .lineLimit(2)
                .frame(minHeight: 28, alignment: .topLeading)
            Spacer(minLength: 0)
            Button("View Package Details", action: action)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(SystemColor.controlFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(SystemColor.controlBorder, lineWidth: 1)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(16)
        .frame(minHeight: 150, alignment: .topLeading)
        .background(SystemColor.controlFill, in: RoundedRectangle(cornerRadius: dashboardItemCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: dashboardItemCornerRadius, style: .continuous)
                .stroke(SystemColor.controlBorder, lineWidth: 1)
        }
    }
}

private struct DashboardSponsoredCard: View {
    private let url = URL(string: "https://automicvault.com")!

    var body: some View {
        Link(destination: url) {
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
                .clipShape(RoundedRectangle(cornerRadius: dashboardItemCornerRadius, style: .continuous))
            }
            .overlay {
                RoundedRectangle(cornerRadius: dashboardItemCornerRadius, style: .continuous)
                    .stroke(SystemColor.controlBorder, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
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
                            .foregroundStyle(SystemColor.primaryText)
                            .frame(width: 48, height: 48)
                            .background(SystemColor.controlFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(update.0)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(SystemColor.primaryText)
                                .lineLimit(1)
                            Text(update.1)
                                .font(.system(size: 11))
                                .foregroundStyle(SystemColor.secondaryText)
                                .lineLimit(1)
                            Text(update.2)
                                .font(.system(size: 11))
                                .foregroundStyle(SystemColor.quietText)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
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
                                .foregroundStyle(SystemColor.primaryText)
                                .lineLimit(1)
                            Text(pack.1)
                                .font(.system(size: 11))
                                .foregroundStyle(SystemColor.secondaryText)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text("Install")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 58, height: 30)
                            .background(SystemColor.controlFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    if pack.0 != packs.last?.0 {
                        Divider().overlay(SystemColor.hairline)
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
                    .foregroundStyle(SystemColor.secondaryText)
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
        .background(Color(red: 0.18, green: 0.13, blue: 0.28).opacity(0.72), in: RoundedRectangle(cornerRadius: dashboardItemCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: dashboardItemCornerRadius, style: .continuous)
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
        .foregroundStyle(SystemColor.secondaryText)
    }
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
