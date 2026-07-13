import AppKit
import PMMCore
import Foundation
import SwiftUI
import WebKit

struct MainWindowSidebarView: View {
    @ObservedObject var model: MainWindowModel

    var body: some View {
        List(selection: sidebarSelection) {
            if model.hasMultipleHosts {
                Section {
                    sidebarRow(.home)
                }
                Section(MainWindowModel.localSidebarHostName) {
                    sidebarRow(.installed)
                    ForEach(model.visibleManagerSections) {
                        sidebarRow($0)
                            .padding(.leading)
                    }
                    sidebarRow(.outdated)
                }
            } else {
                Section {
                    ForEach(MainWindowSection.librarySections) { sidebarRow($0) }
                }
            }
            if !model.visibleManagerSections.isEmpty {
                if model.hasMultipleHosts {
                    // Section {
                    //     ForEach(model.visibleManagerSections) { sidebarRow($0) }
                    // }
                } else {
                    Section("Ecosystems") {
                        ForEach(model.visibleManagerSections) { sidebarRow($0) }
                    }
                }
            }
            ForEach(model.remoteHosts) { host in
                Section {
                    ForEach(RemoteHostSection.allCases) { section in
                        remoteSidebarRow(section, host: host)
                    }
                } header: {
                    remoteHostLabel(host)
                }
            }
            if !model.visibleCategorySections.isEmpty {
                Section("Categories") {
                    ForEach(model.visibleCategorySections) { sidebarRow($0) }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var sidebarSelection: Binding<MainWindowSidebarSelection?> {
        Binding {
            model.sidebarSelection
        } set: { selection in
            switch selection {
            case .local(let section):
                model.selectSection(section)
            case .remote(let hostID, let section):
                model.selectRemoteHost(hostID, section: section)
            case nil:
                break
            }
        }
    }

    private func sidebarRow(_ section: MainWindowSection) -> some View {
        HStack(spacing: 8) {
            sidebarIcon(section)
            Text(section.title)
                .lineLimit(1)
                .foregroundStyle(model.activeSidebarSection == section ? Color.accentColor : .primary)
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
        .tag(MainWindowSidebarSelection.local(section))
    }

    private func remoteSidebarRow(_ section: RemoteHostSection, host: RemoteHost) -> some View {
        let selected = model.sidebarSelection == .remote(hostID: host.id, section: section)
        return HStack(spacing: 8) {
            Image(systemName: section.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 20, height: 20)
            Text(section.title)
                .foregroundStyle(selected ? Color.accentColor : .primary)
            Spacer(minLength: 6)
            if model.isLoading(host.id) {
                ProgressView().controlSize(.small).fixedSize()
            } else if let count = model.count(for: section, on: host.id), count > 0 {
                SidebarCountText(count: count).fixedSize()
            }
        }
        .tag(MainWindowSidebarSelection.remote(hostID: host.id, section: section))
    }

    private func remoteHostLabel(_ host: RemoteHost) -> some View {
        HStack(spacing: 8) {
            Text(host.displayName).lineLimit(1)
            Image(systemName: "globe")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Spacer(minLength: 6)
            if let error = model.error(for: host.id) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(error)
                    .accessibilityLabel("Connection error: \(error)")
            }
        }
    }

    @ViewBuilder
    private func sidebarIcon(_ section: MainWindowSection) -> some View {
        Group {
            if let image = section.sidebarImage {
                Image(image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
            } else {
                Image(systemName: section.systemImage)
                    .font(.system(size: 14, weight: .semibold))
            }
        }
        .foregroundStyle(model.activeSidebarSection == section ? Color.accentColor : .primary)
        .frame(width: 20, height: 20)
    }
}

struct RemoteHostsManagementView: View {
    @ObservedObject var model: MainWindowModel
    @Environment(\.dismiss) private var dismiss
    @State private var editingHost: RemoteHostEditorItem?

    var body: some View {
        NavigationStack {
            Group {
                if model.remoteHosts.isEmpty {
                    ContentUnavailableView {
                        Label("No Remote Hosts", systemImage: "desktopcomputer")
                    } description: {
                        Text("Add a Mac you can already access with SSH.")
                    } actions: {
                        Button("Add Host") { editingHost = RemoteHostEditorItem(host: nil) }
                    }
                } else {
                    List(model.remoteHosts) { host in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(host.displayName)
                                if host.name != nil {
                                    Text(host.destination)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if model.isLoading(host.id) {
                                ProgressView().controlSize(.small)
                            } else if let error = model.error(for: host.id) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .help(error)
                            }
                            Button { editingHost = RemoteHostEditorItem(host: host) } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)
                            .help("Edit \(host.displayName)")
                            .disabled(model.isRunningAction(on: host.id))
                            Button(role: .destructive) { model.removeRemoteHost(host.id) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove \(host.displayName)")
                            .disabled(model.isRunningAction(on: host.id))
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Add / Edit Hosts")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if !model.remoteHosts.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button { editingHost = RemoteHostEditorItem(host: nil) } label: {
                            Label("Add Host", systemImage: "plus")
                        }
                    }
                }
            }
        }
        .frame(width: 520, height: 340)
        .sheet(item: $editingHost) { item in
            RemoteHostEditorView(model: model, host: item.host)
        }
    }
}

private struct RemoteHostEditorItem: Identifiable {
    let id = UUID()
    let host: RemoteHost?
}

private struct RemoteHostEditorView: View {
    @ObservedObject var model: MainWindowModel
    let host: RemoteHost?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var destination: String
    @State private var error: String?

    init(model: MainWindowModel, host: RemoteHost?) {
        self.model = model
        self.host = host
        name = host?.name ?? ""
        destination = host?.destination ?? ""
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name (optional)", text: $name)
                TextField("SSH host or alias", text: $destination)
                    .textContentType(.URL)
                Text("PMM uses your existing SSH config, keys, agent, and known_hosts. Connect successfully in Terminal before adding the host here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(host == nil ? "Add SSH Host" : "Edit SSH Host")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!RemoteHost.isValidDestination(destination.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
        }
        .frame(width: 460, height: 250)
    }

    private func save() {
        do {
            _ = try model.saveRemoteHost(id: host?.id, name: name, destination: destination)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct MainWindowPackageListView: View {
    @ObservedObject var model: MainWindowModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                let displayedPackages = model.displayedPackages
                if model.displayedPackagesAreLoading && displayedPackages.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else if let error = model.displayedPackagesError, displayedPackages.isEmpty {
                    ContentUnavailableView {
                        Label("Host Unavailable", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
                    } description: {
                        Text(error)
                    } actions: {
                        if let hostID = model.selectedRemoteHostID {
                            Button("Retry") { model.refreshRemoteHost(hostID) }
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(displayedPackages) { package in
                            PackageRow(
                                package: package,
                                selected: model.selectedPackage?.id == package.id,
                                showsManager: model.isRemoteSelection || model.activeSidebarSection == .outdated || (model.activeSidebarSection?.packageManagers.count ?? 0) > 1,
                                versionText: mainWindowVersionText(
                                    package,
                                    section: model.selectedRemoteSection == .outdated ? .outdated : model.activeSidebarSection
                                )
                            ) {
                                model.select(package)
                            }
                            .id(package.id)
                        }
                    }
                }
            }
            .onChange(of: model.packageIDToScrollIntoView) { _, id in
                scrollToSelectedPackage(id, proxy: proxy)
                model.consumePackageScrollRequest()
            }
        }
        .safeAreaBar(edge: .top, alignment: .leading, spacing: 0) {
            HStack {
                Text(model.displayedSectionTitle)
                Spacer()
                if model.displayedPackagesAreLoading { ProgressView().controlSize(.small) }
            }
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Color.secondary)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 42)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .ignoresSafeArea(.container, edges: .top)
    }

    private func scrollToSelectedPackage(_ id: String?, proxy: ScrollViewProxy) {
        guard let id else { return }
        DispatchQueue.main.async {
            withAnimation {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }
}

struct MainWindowDossierView: View {
    @ObservedObject var model: MainWindowModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            ScrollView {
                if let package = model.selectedPackage {
                    VStack(alignment: .leading, spacing: 20) {
                        DossierHeader(package: package)
                        if model.canInstall(package) {
                            Button {
                                model.install(package)
                            } label: {
                                Label("Install", systemImage: "square.and.arrow.down")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(isPackageActionRunning)
                        }
                        if package.isOutdated {
                            if PackageUpdater.supports(package) {
                                Button {
                                    model.update(package)
                                } label: {
                                    Label(updateButtonTitle(for: package), systemImage: "arrow.down.circle")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                                .tint(SystemColor.orange)
                                .disabled(isPackageActionRunning)
                            }
                        }
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
                        PackagePageSection(model: model)
                        if model.showsLocalFilesystemActions {
                            PackageConfigurationSection(locations: model.selectedPackageConfigurationLocations)
                            PackageLocationSection(package: package)
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
        .background((colorScheme == .dark ? Color.black.opacity(0.08) : Color.white.opacity(0.1)))
        .sheet(isPresented: packageActionModalBinding) {
            PackageCommandProgressView(
                command: model.packageActionCommand,
                output: model.packageActionOutput,
                error: model.packageActionError,
                dismiss: model.dismissPackageAction
            )
                .interactiveDismissDisabled(true)
        }
    }

    private var isPackageActionRunning: Bool {
        model.installingPackageName != nil || model.uninstallingPackageName != nil || model.updatingPackageName != nil
    }

    private var packageActionModalBinding: Binding<Bool> {
        Binding(get: { isPackageActionRunning || model.packageActionError != nil }, set: { _ in })
    }

    private func updateButtonTitle(for package: ManagedPackage) -> String {
        package.latestVersion.map { "Update → \($0)" } ?? "Update"
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
        .background(LiquidGlassSurface(material: .ultraThinMaterial, tint: SystemColor.windowTint).ignoresSafeArea())
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

func mainWindowExecutablePath(
    named name: String,
    for package: ManagedPackage,
    fileManager: FileManager = .default,
    findExecutable: (String) -> String? = { firstExecutable(named: $0) }
) -> String? {
    guard !name.isEmpty, !name.contains("/") else { return nil }

    let binaryPath = package.binaryPath.map(mainWindowExpandTilde)
    let binaryURL = binaryPath.map { URL(fileURLWithPath: $0) }
    let installLocation = package.installLocation.map(mainWindowExpandTilde)
    let candidates = [
        binaryURL?.lastPathComponent == name ? binaryPath : nil,
        binaryURL?.deletingLastPathComponent().appendingPathComponent(name).path,
        installLocation.map { URL(fileURLWithPath: $0).appendingPathComponent("bin").appendingPathComponent(name).path },
    ].compactMap { $0 }

    if let path = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
        return path
    }
    guard let path = findExecutable(name), fileManager.isExecutableFile(atPath: path) else { return nil }
    return path
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
        return links + [MainWindowBrowserLink(title: MainWindowLinkTab.releases.title, tab: .releases, url: releaseNotesURL)]
    }
    return links
}

func mainWindowSelectedBrowserLink(in links: [MainWindowBrowserLink], selectedTab: MainWindowLinkTab?) -> MainWindowBrowserLink? {
    if let selectedTab {
        return links.first { $0.tab == selectedTab } ?? links.first
    }
    return links.first { $0.tab == .releases } ?? links.first
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

func mainWindowVersionText(_ package: ManagedPackage, section: MainWindowSection? = nil) -> String {
    if section == .newUpdated, let pulseKind = package.pulseKind {
        return pulseKind.capitalized
    }
    if section?.categoryIdentifier != nil, package.installedVersion == nil {
        return package.manager == .npm ? "NPM" : package.manager.title
    }
    if package.isOutdated {
        if section == nil || section == .outdated {
            return "\(package.installedVersion ?? "?") → \(package.latestVersion ?? "?")"
        }
        return package.installedVersion ?? package.latestVersion ?? "available"
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
                    .foregroundStyle(selected ? SystemColor.primaryText : SystemColor.quietText)
                    .fixedSize(horizontal: true, vertical: false)
                Text(mainWindowBrowserDisplayURL(link.url))
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? SystemColor.secondaryText : SystemColor.quietText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.selection.opacity(0.22))
                        .background {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(.ultraThinMaterial)
                        }
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
                LocationButton(label: "Install Root", path: installLocation, action: mainWindowRevealInFinder)
            } else {
                InfoRow(label: "Install Root", value: "unknown")
            }
            if let binaryPath = package.binaryPath {
                LocationButton(label: "Binary", path: binaryPath, action: mainWindowRevealInFinder)
            } else {
                InfoRow(label: "Binary", value: "unknown")
            }
        }
    }
}

private func mainWindowRevealInFinder(_ path: String) {
    let expandedPath = mainWindowExpandTilde(path)
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: expandedPath)])
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
                    .foregroundStyle(SystemColor.quietText)
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
                    DossierExecutableStack(
                        executables: dossier.executables,
                        package: model.selectedPackage,
                        allowsReveal: model.showsLocalFilesystemActions
                    )
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

private struct DossierExecutableStack: View {
    let executables: [String]
    let package: ManagedPackage?
    let allowsReveal: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Executables")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SystemColor.quietText)
            VStack(spacing: 2) {
                ForEach(executables, id: \.self) { executable in
                    Button {
                        guard allowsReveal else { return }
                        revealExecutableInFinder(executable)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(executable)
                                .font(.system(size: 12))
                                .foregroundStyle(SystemColor.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!allowsReveal)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func revealExecutableInFinder(_ executable: String) {
        guard let package else { return }
        Task.detached {
            guard let path = mainWindowExecutablePath(named: executable, for: package) else { return }
            await MainActor.run { mainWindowRevealInFinder(path) }
        }
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
                        .foregroundStyle(SystemColor.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    PackageEcosystemMark(package: package)
                    if package.isOutdated && !showsManager { PackageBadgePill(text: "Outdated", color: SystemColor.orange) }
                    Spacer(minLength: 8)
                    Text(versionText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(SystemColor.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(SystemColor.quietText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(height: 66, alignment: .topLeading)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.selection.opacity(0.22))
                        .background {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(.ultraThinMaterial)
                        }
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

struct PackageEcosystemMark: View {
    let package: ManagedPackage
    var size: CGFloat = 15
    var isBaselineAligned = true

    var body: some View {
        Group {
            if let image = section.sidebarImage {
                Image(image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .offset(y: isBaselineAligned ? imageOffset : 0)
            } else {
                Image(systemName: section.systemImage)
                    .font(.system(size: size * 0.73, weight: .semibold))
            }
        }
        .foregroundStyle(color)
        .frame(
            width: section.sidebarImage == nil ? size - 1 : size + 1,
            height: section.sidebarImage == nil ? size - 1 : size + 1
        )
        .accessibilityLabel(section.title)
    }

    private var section: MainWindowSection {
        if package.identifier.hasPrefix("brew:cask:") { return .casks }
        switch package.manager {
        case .cargoInstall, .rustup: return .rust
        case .homebrew: return .homebrew
        case .npm, .npx: return .javascript
        case .skills: return .skills
        case .uv, .uvx: return .python
        }
    }

    private var color: Color {
        switch section {
        case .casks: .teal
        case .homebrew: .orange
        case .javascript: .yellow
        case .python: .blue
        case .rust: .red
        case .skills: .purple
        default: SystemColor.secondaryText
        }
    }

    private var imageOffset: CGFloat {
        section == .homebrew ? 3 : 4.5
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
            .foregroundStyle(SystemColor.quietText)
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
            .foregroundStyle(SystemColor.secondaryText)
            .monospacedDigit()
            .padding(.horizontal, SidebarCountMetrics.pillHorizontalPadding)
            .frame(height: 20)
            .background(SystemColor.controlFill, in: Capsule())
            .padding(.trailing, -SidebarCountMetrics.pillHorizontalPadding)
    }
}

struct PackageBadgePill: View {
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

private struct DossierHeader: View {
    let package: ManagedPackage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(package.displayName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(SystemColor.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                if let version = package.installedVersion ?? package.latestVersion {
                    Text(version)
                        .font(.system(size: 14, weight: .thin))
                        .foregroundStyle(SystemColor.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(package.manager.title.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(SystemColor.quietText)
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
                    .foregroundStyle(SystemColor.secondaryText)
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
                    .foregroundStyle(SystemColor.quietText)
                    .tracking(0.8)
                Rectangle()
                    .fill(SystemColor.hairline)
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
                .foregroundStyle(SystemColor.quietText)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(SystemColor.secondaryText)
                .lineLimit(valueLineLimit)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PackageCommandProgressView: View {
    let command: String?
    let output: String
    let error: String?
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let command {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("$")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(.green)
                    Text(command)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(SystemColor.primaryText)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            TerminalOutputTextView(output: output)
                .frame(width: TerminalOutputTextView.scrollViewWidth, height: 300)
            if let error {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Dismiss", action: dismiss)
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .frame(width: TerminalOutputTextView.scrollViewWidth)
        .padding(5)
        .background(LiquidGlassSurface(material: .ultraThinMaterial, tint: SystemColor.windowTint))
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

struct LiquidGlassSurface: View {
    let material: Material
    let tint: Color
    var body: some View {
        Rectangle().fill(material).overlay(tint)
    }
}

enum SystemColor {
    static let packageBrown = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.97, green: 0.75, blue: 0.50, alpha: 1)
            : NSColor(red: 0.85, green: 0.54, blue: 0.25, alpha: 1)
    })
    static let windowTint = Color.clear
    static let primaryText = Color.primary
    static let secondaryText = Color.secondary
    static let quietText = Color(nsColor: .tertiaryLabelColor)
    static let hairline = Color(nsColor: .separatorColor)
    static let controlFill = Color(nsColor: .controlBackgroundColor)
    static let cardTint = Color(nsColor: .controlBackgroundColor).opacity(0.5)
    static let controlBorder = Color(nsColor: .separatorColor)
    static let orange = Color.orange
}

#Preview("MainWindowSidebarView.sidebarRow") {
    // We need MainWindowModel and MainWindowSection to construct the view.
    // Please provide these types or accessible fixtures/mocks to proceed.
}
