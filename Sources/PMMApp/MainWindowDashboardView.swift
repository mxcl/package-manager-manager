import CoreImage
import PMMCore
import SwiftUI

private let dashboardItemCornerRadius: CGFloat = 17.5
private let dashboardBlogURL = URL(string: "https://mxcl.dev/package-manager-manager/blog/")!

struct MainWindowDashboardView: View {
    @ObservedObject var model: MainWindowModel

    var body: some View {
        ScrollView {
            dashboardMainColumn
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(28)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .ignoresSafeArea(.container, edges: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var dashboardMainColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Discover")
                .font(.largeTitle.bold())
                .foregroundStyle(SystemColor.primaryText)
                .padding(.horizontal, 8)
            DashboardDiscoverFeedView(
                posts: model.dashboardBlogPosts,
                packs: model.dashboardInstallPacks,
                supportingContentIsLoading: model.dashboardBlogEntriesAreLoading
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

private struct DashboardDiscoverFeedView: View {
    let posts: [DashboardBlogEntry]
    let packs: [DashboardBlogEntry]
    let supportingContentIsLoading: Bool

    @StateObject private var store = DiscoverFeedStore()
    @State private var selectedEditorial: DiscoverFeedContent?

    var body: some View {
        Group {
            if !store.pages.isEmpty {
                LazyVStack(spacing: 24) {
                    ForEach(store.newestBatch) { item in
                        discoverBlock(item, isInNewestBatch: true)
                    }

                    HStack(alignment: .top, spacing: 24) {
                        DashboardUpdatesCard(posts: posts, isLoading: supportingContentIsLoading)
                        DashboardInstallPacksCard(packs: packs, isLoading: supportingContentIsLoading)
                    }

                    ForEach(store.olderContent) { item in
                        discoverBlock(item, isInNewestBatch: false)
                    }

                    paginationFooter
                }
            } else if store.initialLoadFailed {
                DashboardCard {
                    ContentUnavailableView {
                        Label("Discover is unavailable", systemImage: "wifi.exclamationmark")
                    } actions: {
                        Button("Retry") { Task { await store.loadInitial() } }
                    }
                        .frame(maxWidth: .infinity, minHeight: 180)
                }
            } else {
                DashboardCard {
                    ProgressView("Loading Discover")
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 180)
                }
            }
        }
        .task {
            await store.loadInitial()
        }
        .sheet(item: $selectedEditorial) { editorial in
            DashboardDiscoverEditorialReader(editorial: editorial, package: editorial.package)
        }
    }

    @ViewBuilder
    private func discoverBlock(_ item: DiscoverFeedContent, isInNewestBatch: Bool) -> some View {
        switch item.type {
        case "editorial":
            DashboardDiscoverEditorialCard(editorial: item) { selectedEditorial = item }
        case "newPackages":
            if isInNewestBatch {
                HStack(alignment: .top, spacing: 24) {
                    DashboardDiscoverPackageSection(title: item.title ?? "New Packages", packages: item.packages ?? [])
                    DashboardSponsoredCard()
                        .frame(width: 310)
                }
            } else {
                DashboardDiscoverPackageSection(title: item.title ?? "New Packages", packages: item.packages ?? [])
            }
        case "personalizedRecommendations":
            DashboardDiscoverPackageSection(title: item.title ?? "Recommended", packages: item.packages ?? [])
        case "recentlyUpdated":
            DashboardDiscoverPackageSection(title: item.title ?? "Recently Updated", packages: item.packages ?? [])
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var paginationFooter: some View {
        if store.nextPageLoadFailed {
            Button("Retry older stories") { Task { await store.loadNext() } }
                .buttonStyle(.bordered)
        } else if store.hasNextPage {
            ProgressView("Loading more")
                .controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: 72)
                .task(id: store.pages.count) { await store.loadNext() }
        }
    }
}

private struct DashboardDiscoverEditorialCard: View {
    let editorial: DiscoverFeedContent
    let read: () -> Void

    private var boxColors: DiscoverFeedArtwork.BoxColors? { editorial.artwork?.boxColors }
    private var foreground: Color { Color(feedHex: boxColors?.foreground ?? "#FFFFFF") }

    var body: some View {
        Button(action: read) {
            LinearGradient(
                colors: [
                    Color(feedHex: boxColors?.backgroundStart ?? "#1F1638").opacity(0.98),
                    Color(feedHex: boxColors?.backgroundStart ?? "#1F1638").opacity(0.7),
                    .clear
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(maxWidth: .infinity)
            .frame(height: 360)
            .background {
                editorialArtwork
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("EDITORIAL")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(foreground.opacity(0.7))
                    Text(editorial.title ?? "Featured")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(foreground)
                        .lineLimit(4)
                    if let deck = editorial.deck {
                        Text(deck)
                            .font(.title3)
                            .foregroundStyle(foreground.opacity(0.78))
                            .lineLimit(4)
                    }
                }
                .frame(width: 320, alignment: .leading)
                .padding(36)
            }
            .background(LinearGradient(colors: [Color(feedHex: boxColors?.backgroundStart ?? "#1F1638"), Color(feedHex: boxColors?.backgroundEnd ?? "#481488")], startPoint: .topLeading, endPoint: .bottomTrailing))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Read \(editorial.title ?? "featured article")")
        .accessibilityHint("Opens the full editorial")
    }

    @ViewBuilder
    private var editorialArtwork: some View {
        if let url = editorial.artworkURL {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.white.opacity(0.08)
            }
            .clipped()
        } else {
            LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.03)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

private extension Color {
    init(feedHex value: String) {
        let hex = value.dropFirst()
        let integer = UInt64(hex, radix: 16) ?? 0
        self.init(
            .sRGB,
            red: Double((integer >> 16) & 0xFF) / 255,
            green: Double((integer >> 8) & 0xFF) / 255,
            blue: Double(integer & 0xFF) / 255
        )
    }
}

private struct DashboardDiscoverEditorialReader: View {
    let editorial: DiscoverFeedContent
    let package: DiscoverFeedPackage?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(editorial.title ?? "Discover")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let deck = editorial.deck {
                        Text(deck)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    if let body = editorial.body {
                        DashboardDiscoverMarkdown(markdown: body)
                    }
                    if !relatedPackages.isEmpty {
                        DashboardDiscoverPackageSection(title: "Related Packages", packages: relatedPackages)
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(24)
            }
        }
        .frame(minWidth: 620, minHeight: 620)
    }

    private var relatedPackages: [DiscoverFeedPackage] {
        editorial.relatedPackages ?? package.map { [$0] } ?? []
    }
}

private struct DashboardDiscoverMarkdown: View {
    let markdown: String

    private var blocks: [String] {
        markdown.components(separatedBy: "\n\n").filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                if block.hasPrefix("## ") {
                    Text(block.dropFirst(3))
                        .font(.title2.bold())
                        .padding(.top, 8)
                } else if block.split(separator: "\n").allSatisfy({ $0.hasPrefix("- ") }) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(block.split(separator: "\n").enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•")
                                Text(.init(String(line.dropFirst(2))))
                            }
                        }
                    }
                } else {
                    Text(.init(block.replacingOccurrences(of: "\n", with: " ")))
                }
            }
        }
        .font(.body)
        .textSelection(.enabled)
    }
}

private struct DashboardDiscoverPackageSection: View {
    let title: String
    let packages: [DiscoverFeedPackage]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.weight(.bold))
                .foregroundStyle(SystemColor.primaryText)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                ForEach(packages) { DashboardDiscoverPackageLink(package: $0) }
            }
        }
    }
}

private struct DashboardDiscoverPackageLink: View {
    let package: DiscoverFeedPackage
    var label: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label ?? package.displayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SystemColor.primaryText)
                .lineLimit(2)
            Text(package.agentSummary)
                .font(.system(size: 11))
                .foregroundStyle(SystemColor.secondaryText)
                .lineLimit(4)
            if let ecosystem = package.ecosystem {
                Label(ecosystem, systemImage: "shippingbox")
                    .font(.caption)
                    .foregroundStyle(SystemColor.secondaryText)
            }
            if let category = package.category {
                Label(category.replacingOccurrences(of: "-", with: " ").capitalized, systemImage: "tag")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
            Spacer(minLength: 0)
            HStack {
                if let homepage = package.homepage {
                    Link("Details", destination: homepage)
                }
                Spacer()
                if let installURL = package.installURL {
                    Link("Install", destination: installURL)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
            .font(.caption.weight(.semibold))
        }
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .padding(18)
        .background(SystemColor.controlFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
                MeshGradient(
                    width: 2,
                    height: 2,
                    points: [[0, 0], [1, 0], [0, 1], [1, 1]],
                    colors: [
                        Color(red: 0.35, green: 0.16, blue: 0.62),
                        Color(red: 0.98, green: 0.44, blue: 0.25),
                        Color(red: 0.80, green: 0.26, blue: 0.18),
                        Color(red: 0.05, green: 0.06, blue: 0.10),
                    ],
                    smoothsColors: true,
                    colorSpace: .perceptual
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
