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
                    sidebarHeader("ECOSYSTEMS").padding(.top, 22)
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
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: 44)
        }
        .scrollIndicators(.hidden)
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.dark)
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
        case .rust, .homebrew, .casks, .javascript, .python: Color(red: 0.00, green: 0.48, blue: 1.00)
        default: Color(red: 0.46, green: 0.49, blue: 0.53)
        }
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
                Text("Package Manager Manager")
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
        .preferredColorScheme(.dark)
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
                        InfoSection(title: "Package") {
                            InfoRow(label: "Installed", value: package.installedVersion ?? "unknown")
                            if !package.otherInstalledVersions.isEmpty {
                                InfoRow(label: "Other", value: package.otherInstalledVersions.joined(separator: ", "))
                            }
                            InfoRow(label: "Latest", value: package.latestVersion ?? "unknown")
                            InfoRow(label: "Category", value: package.category ?? "uncategorized")
                        }
                        InfoSection(title: "Location") {
                            InfoRow(label: "Install Root", value: mainWindowHomeRelativePath(package.installLocation))
                            InfoRow(label: "Binary", value: mainWindowHomeRelativePath(package.binaryPath))
                        }
                        if package.installedVersion != nil {
                            Button { model.uninstall(package) } label: {
                                Label("Uninstall", systemImage: "trash")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .tint(.red)
                            .disabled(isPackageActionRunning)
                        }
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
        .preferredColorScheme(.dark)
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
        .preferredColorScheme(.dark)
    }

    private func selectedLink(in links: [MainWindowBrowserLink]) -> MainWindowBrowserLink? {
        mainWindowSelectedBrowserLink(in: links, selectedTab: model.selectedLinkTab)
    }
}

struct MainWindowBrowserLink: Equatable, Identifiable {
    let title: String
    let tab: MainWindowLinkTab?
    let url: URL

    var id: String { tab?.rawValue ?? url.absoluteString }
}

func mainWindowBrowserLinks(for package: ManagedPackage?) -> [MainWindowBrowserLink] {
    if let releaseNotesURL = mainWindowReleaseNotesURL(for: package) {
        return [MainWindowBrowserLink(title: "Releases", tab: nil, url: releaseNotesURL)]
    }
    return mainWindowLinks(for: package).map {
        MainWindowBrowserLink(title: $0.tab.title, tab: $0.tab, url: $0.url)
    }
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
        return pulseKind
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
            Text(package.displayName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(AVGlassPalette.primaryText)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            Text(package.manager.title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(AVGlassPalette.quietText)
                .tracking(0.8)
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
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AVGlassPalette.quietText)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(AVGlassPalette.secondaryText)
                .lineLimit(5)
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
        .preferredColorScheme(.dark)
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
    static let searchFill = Color.white.opacity(0.11)
    static let controlBorder = Color.white.opacity(0.18)
    static let orange = Color(red: 0.95, green: 0.72, blue: 0.20)
}
