import CoreImage
import PMMCore
import SwiftUI

private let dashboardItemCornerRadius: CGFloat = 17.5
private let dashboardCardSpacing: CGFloat = 8.5
private let dashboardBlogURL = URL(string: "https://mxcl.dev/package-manager-manager/blog/")!

struct MainWindowDashboardView: View {
    @ObservedObject var model: MainWindowModel

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: dashboardCardSpacing) {
                dashboardMainColumn
                    .frame(minWidth: 0, maxWidth: .infinity)
                dashboardSideColumn
                    .frame(width: 310)
            }
            .padding(dashboardCardSpacing)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .ignoresSafeArea(.container, edges: .top)
    }

    private var dashboardStats: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 110), spacing: dashboardCardSpacing), count: 3), spacing: dashboardCardSpacing) {
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
        }
    }

    private var dashboardMainColumn: some View {
        VStack(spacing: dashboardCardSpacing) {
            dashboardStats
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
        VStack(spacing: dashboardCardSpacing) {
            DashboardSponsoredCard()
            DashboardUpdatesCard(
                posts: model.dashboardBlogPosts,
                isLoading: model.dashboardBlogEntriesAreLoading
            )
            DashboardInstallPacksCard(
                packs: model.dashboardInstallPacks,
                isLoading: model.dashboardBlogEntriesAreLoading
            )
        }
    }
}

private struct DashboardCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if colorScheme == .light {
                RoundedRectangle(cornerRadius: dashboardItemCornerRadius, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
            } else {
                RoundedRectangle(cornerRadius: dashboardItemCornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: dashboardItemCornerRadius, style: .continuous)
                            .fill(SystemColor.cardTint)
                    }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: dashboardItemCornerRadius, style: .continuous)
                .stroke(colorScheme == .light ? Color.white : SystemColor.controlBorder, lineWidth: 1)
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
                            Divider()
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
    let showsViewAll: Bool

    init(title: String, systemImage: String? = nil, showsViewAll: Bool = true, viewAllAction: (() -> Void)? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.showsViewAll = showsViewAll
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
            } else if showsViewAll {
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
                PackageEcosystemMark(package: package, size: 22, isBaselineAligned: false)
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
            DashboardSectionHeader(title: "Recommended for You", showsViewAll: false)
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
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 130), spacing: dashboardCardSpacing), count: 3), spacing: dashboardCardSpacing) {
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
        DashboardCard {
            VStack(alignment: .leading, spacing: 9) {
                ZStack {
                    Circle().fill(SystemColor.controlFill)
                    PackageEcosystemMark(package: package, size: 22, isBaselineAligned: false)
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
        }
    }
}

private struct DashboardSponsoredCard: View {
    @Environment(\.colorScheme) private var colorScheme
    private let url = URL(string: "https://automicvault.com")!
    private static let ditherImage: CGImage? = {
        let extent = CGRect(x: 0, y: 0, width: 64, height: 64)
        guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage?
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
            .cropped(to: extent)
        else { return nil }
        return CIContext(options: [.cacheIntermediates: false]).createCGImage(noise, from: extent)
    }()

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
                Rectangle()
                    .fill(
                        .linearGradient(
                            Gradient(colors: [Color(red: 0.35, green: 0.16, blue: 0.62), Color(red: 0.98, green: 0.44, blue: 0.25), Color(red: 0.05, green: 0.06, blue: 0.10)])
                                .colorSpace(.perceptual),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        if let ditherImage = Self.ditherImage {
                            Image(decorative: ditherImage, scale: 2)
                                .resizable(resizingMode: .tile)
                                .interpolation(.none)
                                .opacity(2 / 255)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: dashboardItemCornerRadius, style: .continuous))
            }
            .overlay {
                RoundedRectangle(cornerRadius: dashboardItemCornerRadius, style: .continuous)
                    .stroke(colorScheme == .light ? Color.white : SystemColor.controlBorder, lineWidth: 1)
            }
            .shadow(color: colorScheme == .light ? .black.opacity(0.06) : .clear, radius: 6, y: 2)
        }
        .buttonStyle(.plain)
    }
}

private struct DashboardUpdatesCard: View {
    let posts: [DashboardBlogEntry]
    let isLoading: Bool

    @Environment(\.openURL) private var openURL

    var body: some View {
        DashboardCard {
            DashboardSectionHeader(title: "Blog & Updates") {
                openURL(dashboardBlogURL)
            }
            VStack(spacing: 0) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else if posts.isEmpty {
                    Text("No blog posts yet")
                        .font(.system(size: 12))
                        .foregroundStyle(SystemColor.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 92)
                } else {
                    ForEach(posts) { post in
                        Link(destination: post.url) {
                            HStack(spacing: 12) {
                                Image(systemName: post.systemImage)
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundStyle(SystemColor.primaryText)
                                    .frame(width: 48, height: 48)
                                    .background(SystemColor.controlFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(post.title)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(SystemColor.primaryText)
                                        .lineLimit(1)
                                    Text(post.subtitle)
                                        .font(.system(size: 11))
                                        .foregroundStyle(SystemColor.secondaryText)
                                        .lineLimit(1)
                                    Text(post.publishedAt)
                                        .font(.system(size: 11))
                                        .foregroundStyle(SystemColor.quietText)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        if post.id != posts.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

private struct DashboardInstallPacksCard: View {
    let packs: [DashboardBlogEntry]
    let isLoading: Bool

    @Environment(\.openURL) private var openURL

    var body: some View {
        DashboardCard {
            DashboardSectionHeader(title: "Install Packs") {
                openURL(dashboardBlogURL)
            }
            VStack(spacing: 0) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else if packs.isEmpty {
                    Text("No install packs yet")
                        .font(.system(size: 12))
                        .foregroundStyle(SystemColor.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 92)
                } else {
                    ForEach(packs) { pack in
                        HStack(spacing: 12) {
                            Link(destination: pack.url) {
                                HStack(spacing: 12) {
                                    Image(systemName: pack.systemImage)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .frame(width: 30, height: 30)
                                        .background(Color.accentColor.opacity(0.75), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(pack.title)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(SystemColor.primaryText)
                                            .lineLimit(1)
                                        Text(pack.subtitle)
                                            .font(.system(size: 11))
                                            .foregroundStyle(SystemColor.secondaryText)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            Spacer(minLength: 8)
                            Link(destination: pack.url) {
                                Text("View")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 48, height: 30)
                                    .background(SystemColor.controlFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        if pack.id != packs.last?.id {
                            Divider()
                        }
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
