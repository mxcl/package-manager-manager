import PMMCore
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
            let sidebarWidth = min(290, max(270, width * 0.20))
            let packageWidth = min(390, max(330, width * 0.30))
            let dossierWidth = min(360, max(310, width * 0.25))
            HStack(spacing: 0) {
                sidebar.frame(width: sidebarWidth)
                verticalHairline
                packageList.frame(width: packageWidth)
                verticalHairline
                dossierPanel.frame(width: dossierWidth)
                verticalHairline
                linksPanel.frame(width: max(width - sidebarWidth - packageWidth - dossierWidth - 3, 300))
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 26)
            ForEach(MainWindowSection.librarySections) { sidebarRow($0) }
            if !model.visibleManagerSections.isEmpty {
                sidebarHeader("MANAGERS").padding(.top, 22)
                ForEach(model.visibleManagerSections) { sidebarRow($0) }
            }
            if !model.visibleCategorySections.isEmpty {
                sidebarHeader("CATEGORIES").padding(.top, 22)
                ForEach(model.visibleCategorySections) { sidebarRow($0) }
            }
            Spacer(minLength: 24)
            ForEach(MainWindowSection.utilitySections) { sidebarRow($0) }
        }
        .padding(.horizontal, 18)
        .background { LiquidGlassSurface(material: .ultraThinMaterial, tint: AVGlassPalette.sidebarTint) }
    }

    private func sidebarHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(AVGlassPalette.quietText)
            .tracking(0.5)
            .padding(.bottom, 6)
    }

    private func sidebarRow(_ section: MainWindowSection) -> some View {
        Button { model.selectSection(section) } label: {
            HStack(spacing: 12) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 17)
                Text(section.title)
                    .font(.system(size: 14))
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let count = model.count(for: section), count > 0 {
                    Text(count.formatted())
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AVGlassPalette.quietText)
                        .monospacedDigit()
                }
            }
            .foregroundStyle(model.activeSidebarSection == section ? AVGlassPalette.primaryText : AVGlassPalette.secondaryText)
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
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
            .padding(.horizontal, 18)
            .frame(height: 42)
            hairline
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.displayedPackages) { package in
                        PackageRow(
                            package: package,
                            selected: model.selectedPackage?.id == package.id,
                            versionText: versionText(package)
                        ) {
                            model.select(package)
                        }
                    }
                }
            }
            searchField
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
        .frame(height: 40)
        .background(AVGlassPalette.controlFill.opacity(0.58))
    }

    private var dossierPanel: some View {
        ScrollView {
            if let package = model.selectedPackage {
                VStack(alignment: .leading, spacing: 18) {
                    Text(package.name)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(AVGlassPalette.primaryText)
                        .lineLimit(3)
                    Text(package.summary ?? "No package summary available.")
                        .font(.system(size: 14))
                        .foregroundStyle(AVGlassPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
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
                        PermissionRow(label: "Install Root", value: package.installLocation ?? "unknown")
                        PermissionRow(label: "Binary", value: package.binaryPath ?? "unknown")
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

    private func versionText(_ package: ManagedPackage) -> String {
        if package.isOutdated {
            return "\(package.installedVersion ?? "?") -> \(package.latestVersion ?? "?")"
        }
        return package.installedVersion ?? package.latestVersion ?? "available"
    }

    private var hairline: some View { Rectangle().fill(AVGlassPalette.hairline).frame(height: 1) }
    private var verticalHairline: some View { Rectangle().fill(AVGlassPalette.hairline).frame(width: 1) }
}

private struct PackageRow: View {
    let package: ManagedPackage
    let selected: Bool
    let versionText: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(package.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(AVGlassPalette.primaryText).lineLimit(1)
                        if package.isOutdated { PackageBadgePill(text: "Outdated", color: AVGlassPalette.orange) }
                    }
                    Text(package.summary ?? package.manager.title)
                        .font(.system(size: 12))
                        .foregroundStyle(AVGlassPalette.quietText)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(versionText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AVGlassPalette.secondaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 13)
            .frame(height: 58)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(AVGlassPalette.packageSelectedFill)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
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
    static let sidebarTint = Color(red: 0.04, green: 0.05, blue: 0.06).opacity(0.58)
    static let primaryText = Color.white.opacity(0.92)
    static let secondaryText = Color.white.opacity(0.66)
    static let quietText = Color.white.opacity(0.42)
    static let hairline = Color.white.opacity(0.07)
    static let sidebarSelectedFill = Color.white.opacity(0.10)
    static let packageSelectedFill = Color.white.opacity(0.08)
    static let controlFill = Color.white.opacity(0.07)
    static let controlBorder = Color.white.opacity(0.18)
    static let orange = Color(red: 0.95, green: 0.72, blue: 0.20)
}
