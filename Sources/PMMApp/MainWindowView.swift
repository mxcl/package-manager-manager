import PMMCore
import Foundation
import SwiftUI
import WebKit

struct MainWindowView: View {
    @ObservedObject var model: MainWindowModel
    @State private var linkTab: MainWindowLinkTab = .homepage

    var body: some View {
        ZStack {
            background
            mainContent
        }
        .frame(minWidth: 1060, minHeight: 680)
        .background(Color.clear)
        .preferredColorScheme(.dark)
    }

    private var background: some View {
        LiquidGlassSurface(material: .ultraThinMaterial, tint: AVGlassPalette.windowTint)
            .backgroundExtensionEffect()
            .ignoresSafeArea()
    }

    private var mainContent: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let sidebarWidth = min(290, max(270, width * 0.20))
            let packageWidth = min(273, max(231, width * 0.21))
            let dossierWidth = packageWidth
            HStack(alignment: .top, spacing: 0) {
                sidebar.frame(width: sidebarWidth, height: height)
                packageList.frame(width: packageWidth, height: height, alignment: .top)
                verticalHairline.frame(height: height)
                dossierPanel.frame(width: dossierWidth, height: height, alignment: .top)
                verticalHairline.frame(height: height)
                linksPanel.frame(width: max(width - sidebarWidth - packageWidth - dossierWidth - 2, 300), height: height)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 28)
            searchField
                .padding(.bottom, 18)
            ForEach(MainWindowSection.librarySections) { sidebarRow($0) }
            if !model.visibleManagerSections.isEmpty {
                sidebarHeader("MANAGERS").padding(.top, 22)
                ForEach(model.visibleManagerSections) { sidebarRow($0) }
            }
            if !model.visibleCategorySections.isEmpty {
                sidebarHeader("CATEGORIES").padding(.top, 22)
                ForEach(model.visibleCategorySections) { sidebarRow($0) }
                sidebarDivider
                ForEach(MainWindowSection.categoryShortcutSections) { sidebarRow($0) }
            }
            Spacer(minLength: 24)
            ForEach(MainWindowSection.utilitySections) { sidebarRow($0) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(AVGlassPalette.sidebarTint)
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AVGlassPalette.sidebarBorder)
        }
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
    }

    private func sidebarHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(AVGlassPalette.quietText)
            .tracking(0.5)
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
    }

    private var sidebarDivider: some View {
        Rectangle()
            .fill(AVGlassPalette.hairline)
            .frame(height: 1)
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
    }

    private func sidebarRow(_ section: MainWindowSection) -> some View {
        Button { model.selectSection(section) } label: {
            HStack(spacing: 12) {
                sidebarIcon(section)
                Text(section.title)
                    .font(.system(size: 14, weight: .medium))
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
            .foregroundStyle(model.activeSidebarSection == section ? AVGlassPalette.primaryText : AVGlassPalette.secondaryText)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .background {
                if model.activeSidebarSection == section {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(AVGlassPalette.sidebarSelectedFill)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    private func sidebarIcon(_ section: MainWindowSection) -> some View {
        Image(systemName: section.systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(sidebarIconFill(for: section), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func sidebarIconFill(for section: MainWindowSection) -> Color {
        if section.categoryIdentifier != nil {
            return Color(red: 0.46, green: 0.49, blue: 0.53)
        }

        return switch section {
        case .outdated, .newUpdated: AVGlassPalette.orange
        case .cargoInstall, .homebrew, .npm, .npx, .uv, .uvx: Color(red: 0.00, green: 0.48, blue: 1.00)
        default: Color(red: 0.46, green: 0.49, blue: 0.53)
        }
    }

    private var packageList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Package")
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 11, weight: .bold))
                Spacer()
                if model.isReloading { ProgressView().controlSize(.small) }
            }
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(AVGlassPalette.quietText)
            .padding(.horizontal, 12)
            .frame(height: 42)
            hairline
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
                                showsManager: model.activeSidebarSection == .outdated,
                                versionText: versionText(package, section: model.activeSidebarSection)
                            ) {
                                model.select(package)
                            }
                        }
                    }
                }
            }
        }
    }

    private var searchField: some View {
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

    private var dossierPanel: some View {
        ScrollView {
            if let package = model.selectedPackage {
                VStack(alignment: .leading, spacing: 18) {
                    Text(package.name)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(AVGlassPalette.primaryText)
                        .lineLimit(3)
                    if model.isLoadingSelectedPackageMetadata && package.summary == nil {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(package.summary ?? "No package summary available.")
                            .font(.system(size: 14))
                            .foregroundStyle(AVGlassPalette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if package.isOutdated {
                        PackageBadgeBanner(text: "Outdated \(versionText(package))", color: AVGlassPalette.orange)
                    }
                    InfoSection(title: "Package") {
                        PermissionRow(label: "Manager", value: package.manager.title)
                        PermissionRow(label: "Installed", value: package.installedVersion ?? "unknown")
                        PermissionRow(label: "Latest", value: package.latestVersion ?? "unknown")
                        PermissionRow(label: "Category", value: package.category ?? "uncategorized")
                    }
                    InfoSection(title: "Location") {
                        PermissionRow(label: "Install Root", value: homeRelativePath(package.installLocation))
                        PermissionRow(label: "Binary", value: homeRelativePath(package.binaryPath))
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 32)
                .padding(.bottom, 28)
            } else {
                Text(model.isReloading ? "Loading packages..." : "No package selected")
                    .foregroundStyle(AVGlassPalette.quietText)
                    .frame(maxWidth: .infinity, minHeight: 300)
            }
        }
    }

    private var linksPanel: some View {
        VStack(spacing: 0) {
            LinkURLBar(url: selectedURL) { model.open(url: selectedURL) }
                .padding(.horizontal, 12)
                .frame(height: 42)
            hairline
            if let url = selectedURL {
                PackageWebView(url: url)
            } else if model.isLoadingSelectedPackageMetadata {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("No homepage")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AVGlassPalette.quietText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var selectedURL: URL? {
        model.selectedPackage?.homepage.flatMap(URL.init(string:))
    }

    private func versionText(_ package: ManagedPackage, section: MainWindowSection? = nil) -> String {
        if package.isOutdated {
            return "\(package.installedVersion ?? "?") → \(package.latestVersion ?? "?")"
        }
        if section?.categoryIdentifier != nil, package.installedVersion == nil, package.latestVersion == nil {
            return package.manager.title
        }
        return package.installedVersion ?? package.latestVersion ?? "available"
    }

    private func homeRelativePath(_ path: String?) -> String {
        guard let path else { return "unknown" }
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~/" + String(path.dropFirst(home.count + 1)) }
        return path
    }

    private var hairline: some View { Rectangle().fill(AVGlassPalette.hairline).frame(height: 1) }
    private var verticalHairline: some View { Rectangle().fill(AVGlassPalette.hairline).frame(width: 1) }
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
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(package.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(AVGlassPalette.primaryText).lineLimit(1)
                    if package.isOutdated { PackageBadgePill(text: "Outdated", color: AVGlassPalette.orange) }
                    Spacer(minLength: 8)
                    Text(versionText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AVGlassPalette.secondaryText)
                        .lineLimit(1)
                }
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(AVGlassPalette.quietText)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 13)
            .frame(height: 72)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(AVGlassPalette.packageSelectedFill)
                }
            }
            .padding(.horizontal, 2)
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
            .font(.system(size: 11, weight: .medium))
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
            .font(.system(size: 11, weight: .semibold))
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
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(color)
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
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct InfoSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.system(size: 11, weight: .bold)).foregroundStyle(AVGlassPalette.quietText).tracking(0.7)
            content
        }
    }
}

private struct PermissionRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(AVGlassPalette.quietText).frame(width: 82, alignment: .leading)
            Text(value).font(.system(size: 12)).foregroundStyle(AVGlassPalette.secondaryText).lineLimit(3).textSelection(.enabled)
        }
    }
}

private struct LinkURLBar: View {
    let url: URL?
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "link")
                Text(url?.absoluteString ?? "No URL").lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(AVGlassPalette.secondaryText)
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
    }
}

private struct PackageWebView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }
    func updateNSView(_ webView: WKWebView, context: Context) {
        if webView.url != url {
            webView.load(URLRequest(url: url))
        }
    }
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
    static let topBarTint = Color(red: 0.07, green: 0.08, blue: 0.09).opacity(0.36)
    static let sidebarTint = Color(red: 0.06, green: 0.07, blue: 0.07).opacity(0.72)
    static let primaryText = Color.white.opacity(0.92)
    static let secondaryText = Color.white.opacity(0.72)
    static let quietText = Color.white.opacity(0.42)
    static let hairline = Color.white.opacity(0.07)
    static let sidebarBorder = Color.white.opacity(0.14)
    static let sidebarSelectedFill = Color(red: 0.00, green: 0.38, blue: 0.86)
    static let packageSelectedFill = Color.white.opacity(0.08)
    static let controlFill = Color.white.opacity(0.07)
    static let searchFill = Color.white.opacity(0.11)
    static let controlBorder = Color.white.opacity(0.18)
    static let orange = Color(red: 0.95, green: 0.72, blue: 0.20)
}
