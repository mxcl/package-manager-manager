import CoreImage
import PMMCore
import SwiftUI

private let dashboardItemCornerRadius: CGFloat = 17.5
private let dashboardBlogURL = URL(string: "https://mxcl.dev/package-manager-manager/blog/")!
private let dashboardBlogColumns = [
    GridItem(.flexible(), spacing: 12),
    GridItem(.flexible(), spacing: 12),
]

struct MainWindowDashboardView: View {
    @ObservedObject var model: MainWindowModel
    @ObservedObject var store: DiscoverFeedStore
    @Binding var scrollOffset: CGFloat
    @State private var scrollPosition: ScrollPosition

    init(model: MainWindowModel, store: DiscoverFeedStore, scrollOffset: Binding<CGFloat>) {
        self.model = model
        self.store = store
        _scrollOffset = scrollOffset
        _scrollPosition = State(initialValue: ScrollPosition(y: scrollOffset.wrappedValue))
    }

    var body: some View {
        ScrollView {
            dashboardMainColumn
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(28)
        }
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            max(0, geometry.contentOffset.y + geometry.contentInsets.top)
        } action: { _, offset in
            scrollOffset = offset
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
                store: store,
                posts: model.dashboardBlogPosts,
                supportingContentIsLoading: model.dashboardBlogEntriesAreLoading,
                isPackageInstalled: model.isDiscoverPackageInstalled,
                openPackage: { model.openDiscoverPackage($0) },
                installPackage: { model.openDiscoverPackage($0, installing: true) }
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

private struct DashboardDiscoverFeedView: View {
    @ObservedObject var store: DiscoverFeedStore
    let posts: [DashboardBlogEntry]
    let supportingContentIsLoading: Bool
    let isPackageInstalled: (DiscoverFeedPackage) -> Bool
    let openPackage: (DiscoverFeedPackage) -> Void
    let installPackage: (DiscoverFeedPackage) -> Void

    @State private var selectedEditorial: DiscoverFeedContent?

    var body: some View {
        Group {
            if !store.pages.isEmpty {
                LazyVStack(spacing: 24) {
                    leadContent

                    ForEach(newestContentAfterLead) { item in
                        discoverBlock(item)
                    }

                    DashboardBlogAndPackageSection(
                        posts: Array(posts.prefix(4)),
                        package: spotlightPackage,
                        isLoading: supportingContentIsLoading,
                        isPackageInstalled: isPackageInstalled,
                        openPackage: openPackage,
                        installPackage: installPackage
                    )

                    ForEach(store.olderContent) { item in
                        discoverBlock(item)
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
            DashboardDiscoverEditorialReader(
                editorial: editorial,
                package: editorial.package,
                isPackageInstalled: isPackageInstalled,
                openPackage: openPackage,
                installPackage: installPackage
            )
        }
    }

    @ViewBuilder
    private var leadContent: some View {
        if let editorial = leadEditorial {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) {
                    DashboardDiscoverEditorialCard(editorial: editorial) { selectedEditorial = editorial }
                    DashboardSponsoredCard()
                        .frame(width: 310, height: 360)
                }
                VStack(spacing: 24) {
                    DashboardSponsoredCard()
                    DashboardDiscoverEditorialCard(editorial: editorial) { selectedEditorial = editorial }
                }
            }
        } else {
            DashboardSponsoredCard()
        }
    }

    private var leadEditorial: DiscoverFeedContent? {
        store.newestBatch.first { $0.type == "editorial" }
    }

    private var newestContentAfterLead: [DiscoverFeedContent] {
        guard let leadEditorial else { return store.newestBatch }
        return store.newestBatch.filter { $0.id != leadEditorial.id }
    }

    @ViewBuilder
    private func discoverBlock(_ item: DiscoverFeedContent) -> some View {
        switch item.type {
        case "editorial":
            DashboardDiscoverEditorialCard(editorial: item) { selectedEditorial = item }
        case "newPackages":
            let packages = item.packages ?? []
            let title = dashboardDiscoverSectionTitle(
                item.title ?? "New Packages",
                packages: packages
            )
            packageSection(title: title, packages: packages)
        case "personalizedRecommendations":
            let packages = item.packages ?? []
            packageSection(
                title: dashboardDiscoverSectionTitle(item.title ?? "For You", packages: packages),
                packages: packages
            )
        case "recentlyUpdated":
            packageSection(title: item.title ?? "Recently Updated", packages: item.packages ?? [])
        case "installPack":
            packageSection(
                title: item.title ?? "Install Pack",
                packages: item.packages ?? [],
                maximumPackageCount: nil
            )
        default:
            EmptyView()
        }
    }

    private var spotlightPackage: DiscoverFeedPackage? {
        (store.newestBatch + store.olderContent)
            .first { $0.type == "personalizedRecommendations" }?
            .packages?.first
    }

    private func packageSection(
        title: String,
        packages: [DiscoverFeedPackage],
        maximumPackageCount: Int? = 5
    ) -> some View {
        DashboardDiscoverPackageSection(
            title: title,
            packages: packages,
            maximumPackageCount: maximumPackageCount,
            isPackageInstalled: isPackageInstalled,
            openPackage: openPackage,
            installPackage: installPackage
        )
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

func dashboardDiscoverSectionTitle(
    _ title: String,
    packages: [DiscoverFeedPackage]
) -> String {
    let genericTitles = ["for you", "new packages", "recommended"]
    guard genericTitles.contains(title.lowercased()) else { return title }

    let categories = Set(packages.compactMap(\.category).filter { !$0.isEmpty })
    guard categories.count == 1,
          let category = categories.first,
          let categoryTitle = mainWindowCategoryTitle(category)
    else { return title }

    return "\(title) in \(categoryTitle)"
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
            DiscoverRemoteImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .empty, .failure:
                    Color.white.opacity(0.08)
                }
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
    let isPackageInstalled: (DiscoverFeedPackage) -> Bool
    let openPackage: (DiscoverFeedPackage) -> Void
    let installPackage: (DiscoverFeedPackage) -> Void
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
                    editorialHeaderImage
                    if let deck = editorial.deck {
                        Text(deck)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    if let body = editorial.body {
                        DashboardDiscoverMarkdown(markdown: body)
                    }
                    if !relatedPackages.isEmpty {
                        DashboardDiscoverPackageSection(
                            title: "Related Packages",
                            packages: relatedPackages,
                            maximumPackageCount: 5,
                            isPackageInstalled: isPackageInstalled,
                            openPackage: { package in
                                dismiss()
                                openPackage(package)
                            },
                            installPackage: { package in
                                dismiss()
                                installPackage(package)
                            }
                        )
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

    @ViewBuilder
    private var editorialHeaderImage: some View {
        if let url = editorial.artworkURL {
            DiscoverRemoteImage(url: url) { phase in
                switch phase {
                case .empty:
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 280)
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure:
                    Color.secondary.opacity(0.12)
                        .overlay { Image(systemName: "photo") }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 320)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .clipped()
        }
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
    let maximumPackageCount: Int?
    let isPackageInstalled: (DiscoverFeedPackage) -> Bool
    let openPackage: (DiscoverFeedPackage) -> Void
    let installPackage: (DiscoverFeedPackage) -> Void

    private var visiblePackages: [DiscoverFeedPackage] {
        maximumPackageCount.map { Array(packages.prefix($0)) } ?? packages
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.weight(.bold))
                .foregroundStyle(SystemColor.primaryText)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                ForEach(visiblePackages) { package in
                    DashboardDiscoverPackageLink(
                        package: package,
                        isInstalled: isPackageInstalled(package),
                        open: { openPackage(package) },
                        install: { installPackage(package) }
                    )
                }
            }
        }
    }
}

private struct DashboardDiscoverPackageLink: View {
    let package: DiscoverFeedPackage
    var eyebrow: String? = nil
    let isInstalled: Bool
    let open: () -> Void
    let install: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 7) {
                    if let eyebrow {
                        Text(eyebrow)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.accentColor)
                    }
                    Text(package.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SystemColor.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(package.agentSummary)
                        .font(.system(size: 11))
                        .foregroundStyle(SystemColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
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
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                Button("Details", action: open)
                    .buttonStyle(.plain)
                Spacer()
                if isInstalled {
                    Button("Installed", action: {})
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(true)
                } else if package.installURL != nil {
                    Button("Install", action: install)
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

private struct DashboardBlogAndPackageSection: View {
    let posts: [DashboardBlogEntry]
    let package: DiscoverFeedPackage?
    let isLoading: Bool
    let isPackageInstalled: (DiscoverFeedPackage) -> Bool
    let openPackage: (DiscoverFeedPackage) -> Void
    let installPackage: (DiscoverFeedPackage) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DashboardFeedSectionHeading(title: "Blog & Updates")
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    blogContent
                        .frame(minWidth: 420)
                    packageContent
                        .frame(width: 220)
                }
                VStack(alignment: .leading, spacing: 12) {
                    blogContent
                    packageContent
                }
            }
        }
    }

    @ViewBuilder
    private var blogContent: some View {
        if isLoading {
            LazyVGrid(columns: dashboardBlogColumns, spacing: 12) {
                ForEach(0..<4, id: \.self) { _ in
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 250)
                        .background(SystemColor.controlFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
        } else if !posts.isEmpty {
            LazyVGrid(columns: dashboardBlogColumns, spacing: 12) {
                ForEach(posts) { post in
                    DashboardBlogPostCard(post: post)
                }
            }
        } else {
            Text("No blog posts yet")
                .font(.callout)
                .foregroundStyle(SystemColor.secondaryText)
                .frame(maxWidth: .infinity, minHeight: 250)
                .background(SystemColor.controlFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    @ViewBuilder
    private var packageContent: some View {
        if let package {
            DashboardDiscoverPackageLink(
                package: package,
                eyebrow: "FOR YOU",
                isInstalled: isPackageInstalled(package),
                open: { openPackage(package) },
                install: { installPackage(package) }
            )
            .frame(minHeight: 250)
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: 250)
                .background(SystemColor.controlFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

private struct DashboardFeedSectionHeading: View {
    let title: String

    var body: some View {
        HStack {
            Text(title)
                .font(.title2.weight(.bold))
                .foregroundStyle(SystemColor.primaryText)
            Spacer()
            Link("View all", destination: dashboardBlogURL)
                .font(.caption.weight(.semibold))
        }
    }
}

private struct DashboardBlogPostCard: View {
    let post: DashboardBlogEntry

    var body: some View {
        Link(destination: post.url) {
            VStack(alignment: .leading, spacing: 0) {
                DiscoverRemoteImage(url: post.imageURL) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(SystemColor.controlFill)
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        Image(systemName: post.systemImage)
                            .font(.system(size: 30, weight: .medium))
                            .foregroundStyle(SystemColor.secondaryText)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(SystemColor.controlFill)
                    }
                }
                .frame(height: 140)
                .clipped()

                VStack(alignment: .leading, spacing: 6) {
                    Text(post.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(SystemColor.primaryText)
                        .lineLimit(2)
                    Text(post.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(SystemColor.secondaryText)
                        .lineLimit(2)
                    Text(post.publishedAt)
                        .font(.caption)
                        .foregroundStyle(SystemColor.quietText)
                }
                .padding(16)
            }
            .frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
            .background(SystemColor.controlFill)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
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
