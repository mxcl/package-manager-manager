import AppKit
import Combine
import PMMCore
import SwiftUI

/// AppKit owns navigation, search, toolbar, and the package table. Detail views remain hosted.
@MainActor
final class MainWindowController: NSViewController, NSToolbarDelegate {
    private let model: MainWindowModel
    private let usesNativeBrowser: Bool
    private var hosting: NSHostingController<MainWindowRootView>!
    private var sidebar: SidebarController!
    private var subscriptions: Set<AnyCancellable> = []
    private var toolbarRefreshScheduled = false
    private var showsAppUpdateButton = false
    private var updateApp: () -> Void = {}
    private let updateItem = NSToolbarItem(itemIdentifier: .init("update-packages"))
    private let browserItem = NSToolbarItem(itemIdentifier: .init("open-browser"))
    private let appUpdateItem = NSToolbarItem(itemIdentifier: .init("update-app"))
    private var nativeToolbar: NSToolbar?
    private let checkSpinner = NSProgressIndicator()
    private let updateButton = NSButton(title: "Update All", target: nil, action: nil)

    init(model: MainWindowModel? = nil,
         usesNativeBrowser: Bool = ProcessInfo.processInfo.environment["PMM_SWIFTUI_BROWSER"] != "1",
         onOutdatedPackageCountChanged: @escaping @MainActor (Int) -> Void = { _ in }) {
        self.model = model ?? MainWindowModel(dossierClient: PackageDossierClient(), dashboardBlogURL: MainWindowModel.defaultDashboardBlogURL)
        self.usesNativeBrowser = usesNativeBrowser
        super.init(nibName: nil, bundle: nil)
        self.model.$packages.map { $0.lazy.filter(\.isOutdated).count }.removeDuplicates()
            .sink(receiveValue: onOutdatedPackageCountChanged).store(in: &subscriptions)
        self.model.objectWillChange.sink { [weak self] in self?.scheduleToolbarRefresh() }.store(in: &subscriptions)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        hosting = NSHostingController(rootView: rootView)
        hosting.sizingOptions = [.minSize]
        if usesNativeBrowser {
            sidebar = SidebarController(model: model)
            let split = NSSplitViewController()
            let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
            sidebarItem.minimumThickness = 250
            sidebarItem.maximumThickness = 250
            sidebarItem.canCollapse = false
            split.addSplitViewItem(sidebarItem)
            split.addSplitViewItem(NSSplitViewItem(viewController: hosting))
            addChild(split)
            pin(split.view, to: view)
        } else {
            addChild(hosting)
            pin(hosting.view, to: view)
        }
    }

    private var rootView: MainWindowRootView {
        MainWindowRootView(usesNativeBrowser: usesNativeBrowser, model: model,
                           showsAppUpdateButton: showsAppUpdateButton, updateApp: updateApp)
    }
    override func viewDidAppear() {
        super.viewDidAppear()
        if usesNativeBrowser, nativeToolbar == nil {
            let toolbar = NSToolbar(identifier: "package-browser")
            toolbar.delegate = self
            toolbar.displayMode = .iconAndLabel
            toolbar.allowsUserCustomization = false
            nativeToolbar = toolbar
            view.window?.toolbar = toolbar
            view.window?.toolbarStyle = .unified
            refreshToolbar()
        }
        if ProcessInfo.processInfo.environment["PMM_TERMINAL_DEMO"] != "1" { model.refreshSetupOffers() }
    }

    @objc func refresh(_ sender: Any?) { model.reload() }
    func openPackageURL(_ url: URL) { model.openPackageURL(url) }
    func showHostManagement() { model.showHostManagement() }
    func setAppUpdateButtonVisible(_ visible: Bool, updateApp: @escaping () -> Void) {
        showsAppUpdateButton = visible
        self.updateApp = updateApp
        if usesNativeBrowser { refreshToolbar() }
        else if isViewLoaded { hosting.rootView = rootView }
    }
    @objc func focusSearch(_ sender: Any?) {
        func searchField(in view: NSView) -> NSSearchField? {
            if let field = view as? NSSearchField { return field }
            return view.subviews.lazy.compactMap { searchField(in: $0) }.first
        }
        if let field = usesNativeBrowser ? sidebar.search : searchField(in: hosting.view) {
            view.window?.makeFirstResponder(field)
            field.selectText(sender)
        }
    }
    override func moveUp(_ sender: Any?) { if !model.selectAdjacentPackage(offset: -1) { super.moveUp(sender) } }
    override func moveDown(_ sender: Any?) { if !model.selectAdjacentPackage(offset: 1) { super.moveDown(sender) } }

    private func scheduleToolbarRefresh() {
        guard !toolbarRefreshScheduled else { return }
        toolbarRefreshScheduled = true
        Task { @MainActor [weak self] in
            self?.toolbarRefreshScheduled = false
            self?.refreshToolbar()
        }
    }
    private var browserLink: MainWindowBrowserLink? {
        guard let package = model.selectedPackage else { return nil }
        return mainWindowSelectedBrowserLink(in: mainWindowBrowserLinks(for: package), selectedTab: model.selectedLinkTab)
    }
    private func refreshToolbar() {
        guard usesNativeBrowser, let toolbar = nativeToolbar else { return }
        var desired: [NSToolbarItem.Identifier] = [.flexibleSpace]
        if !model.showsDashboard {
            if model.showsUpdateAllOutdatedPackages { desired.append(updateItem.itemIdentifier) }
            if browserLink != nil { desired.append(browserItem.itemIdentifier) }
        }
        if showsAppUpdateButton { desired.append(appUpdateItem.itemIdentifier) }
        if toolbar.items.map(\.itemIdentifier) != desired {
            while !toolbar.items.isEmpty { toolbar.removeItem(at: toolbar.items.count - 1) }
            for (index, id) in desired.enumerated() { toolbar.insertItem(withItemIdentifier: id, at: index) }
        }
        updateItem.label = model.updateOutdatedPackagesButtonTitle
        updateButton.title = model.updateOutdatedPackagesButtonTitle
        updateButton.isEnabled = model.canUpdateAllOutdatedPackages
        checkSpinner.isHidden = !model.isCheckingAppsBeforeUpdate
        if model.isCheckingAppsBeforeUpdate { checkSpinner.startAnimation(nil) } else { checkSpinner.stopAnimation(nil) }
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, updateItem.itemIdentifier, browserItem.itemIdentifier, appUpdateItem.itemIdentifier]
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case updateItem.itemIdentifier:
            updateButton.target = self
            updateButton.action = #selector(updatePackages)
            updateButton.bezelStyle = .rounded
            updateButton.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
            updateButton.imagePosition = .imageLeading
            checkSpinner.style = .spinning
            checkSpinner.controlSize = .small
            updateItem.view = NSStackView(views: [checkSpinner, updateButton])
            updateItem.label = "Update Packages"
            updateItem.autovalidates = false
            return updateItem
        case browserItem.itemIdentifier:
            browserItem.label = "Open in Browser"
            browserItem.image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: nil)
            browserItem.target = self
            browserItem.action = #selector(openBrowser)
            return browserItem
        case appUpdateItem.itemIdentifier:
            appUpdateItem.label = "Update pkg⋅mgr²"
            appUpdateItem.image = NSImage(systemSymbolName: "arrow.down.app", accessibilityDescription: nil)
            appUpdateItem.target = self
            appUpdateItem.action = #selector(installAppUpdate)
            return appUpdateItem
        default: return nil
        }
    }
    @objc private func updatePackages() { model.updateAllOutdatedPackages() }
    @objc private func openBrowser() { if let url = browserLink?.url { NSWorkspace.shared.open(url) } }
    @objc private func installAppUpdate() { updateApp() }
}

struct MainWindowRootView: View {
    var usesNativeBrowser = true
    @ObservedObject var model: MainWindowModel
    let showsAppUpdateButton: Bool
    let updateApp: () -> Void
    @StateObject private var discoverFeedStore = DiscoverFeedStore()
    @State private var dashboardScrollOffset: CGFloat = 0

    var body: some View {
        browser
        .sheet(isPresented: $model.showsHostManagement) {
            RemoteHostsManagementView(model: model)
        }
        .sheet(isPresented: packageActionModalBinding) {
            PackageCommandProgressView(
                command: model.packageActionCommand,
                output: model.packageActionOutput,
                error: model.packageActionError,
                failureTitle: model.updateAllFailureMessage == nil ? "Action failed" : "Some updates failed",
                dismiss: model.dismissPackageAction
            )
            .interactiveDismissDisabled(true)
        }
        .alert("Close apps before updating", isPresented: Binding(
            get: { model.appsToCloseMessage != nil },
            set: { if !$0 { model.appsToCloseMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.appsToCloseMessage = nil }
        } message: {
            Text(model.appsToCloseMessage ?? "")
        }
        .alert("Install \(model.pendingInstallPackConfirmation?.packageCount ?? 0) packages?", isPresented: installPackConfirmationBinding) {
            Button("Cancel", role: .cancel) {
                model.cancelPendingInstallPack()
            }
            Button("Install") {
                model.confirmPendingInstallPack()
            }
        } message: {
            Text("pkg⋅mgr² will install them one at a time through the existing package managers.")
        }
        .alert(
            "Uninstall \(model.pendingRemoteUninstall?.package.displayName ?? "package")?",
            isPresented: remoteUninstallConfirmationBinding
        ) {
            Button("Cancel", role: .cancel) { model.cancelRemoteUninstall() }
            Button("Uninstall", role: .destructive) { model.confirmRemoteUninstall() }
        } message: {
            Text("This will uninstall the package from \(model.pendingRemoteUninstall?.host.displayName ?? "the remote Mac").")
        }
    }

    @ViewBuilder
    private var browser: some View {
        if usesNativeBrowser {
            content
        } else {
            NavigationSplitView {
                sidebar
            } detail: {
                content
                    .navigationSplitViewColumnWidth(min: model.showsDashboard ? 602 : 854, ideal: 1128)
                    .toolbar {
                        if !model.showsDashboard {
                            updateAllToolbarItem
                            ToolbarSpacer()
                            openInBrowserToolbarItem
                        }
                        appUpdateToolbarItem
                    }
            }
            .searchable(text: $model.searchText, placement: .sidebar, prompt: "Search")
            .toolbar(removing: .title)
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.showsDashboard {
            MainWindowDashboardView(model: model, store: discoverFeedStore, scrollOffset: $dashboardScrollOffset)
        } else {
            HStack(spacing: 0) {
                Group {
                    if usesNativeBrowser { NativePackageList(model: model) }
                    else { MainWindowPackageListView(model: model) }
                }
                .frame(width: 252)
                Divider()
                Group {
                    if model.hasMultipleSelectedPackages {
                        ContentUnavailableView {
                            Label("\(model.selectedPackageIDs.count) Packages Selected", systemImage: "shippingbox")
                        } description: {
                            Text("Use Update Selected to update these packages.")
                        }
                    } else {
                        HStack(spacing: 0) {
                            MainWindowDossierView(model: model).frame(width: 252)
                            MainWindowLinksView(model: model).frame(minWidth: 350, maxWidth: .infinity)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var currentBrowserLink: MainWindowBrowserLink? {
        guard let package = model.selectedPackage else { return nil }
        let links = mainWindowBrowserLinks(for: package)
        return mainWindowSelectedBrowserLink(in: links, selectedTab: model.selectedLinkTab)
    }

    @ToolbarContentBuilder
    private var openInBrowserToolbarItem: some ToolbarContent {
        if let link = currentBrowserLink {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    NSWorkspace.shared.open(link.url)
                } label: {
                    Label("Open in Browser", systemImage: "arrow.up.forward.app")
                }
                .help("Open in Browser")
            }
        }
    }

    @ToolbarContentBuilder
    private var updateAllToolbarItem: some ToolbarContent {
        if model.showsUpdateAllOutdatedPackages {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.updateAllOutdatedPackages()
                } label: {
                    HStack {
                        if model.isCheckingAppsBeforeUpdate { ProgressView().controlSize(.small) }
                        Label(model.updateOutdatedPackagesButtonTitle, systemImage: "arrow.down.circle")
                    }
                }
                .disabled(!model.canUpdateAllOutdatedPackages)
                .labelStyle(.titleAndIcon)
            }
        }
    }

    @ToolbarContentBuilder
    private var appUpdateToolbarItem: some ToolbarContent {
        if showsAppUpdateButton {
            ToolbarSpacer(.flexible)
            ToolbarItem(placement: .primaryAction) {
                Button(action: updateApp) {
                    Label("Update pkg⋅mgr²", systemImage: "arrow.down.app")
                }.labelStyle(.titleAndIcon)
            }
        }
    }

    private var sidebar: some View {
        MainWindowSidebarView(model: model)
            .navigationSplitViewColumnWidth(min: 250, ideal: 250, max: 250)
    }

    private var installPackConfirmationBinding: Binding<Bool> {
        Binding(
            get: { model.pendingInstallPackConfirmation != nil },
            set: { isPresented in
                if !isPresented {
                    model.cancelPendingInstallPack()
                }
            }
        )
    }

    private var packageActionModalBinding: Binding<Bool> {
        Binding(
            get: {
                model.installingPackageName != nil
                    || model.uninstallingPackageName != nil
                    || model.updatingPackageName != nil
                    || model.packageActionError != nil
            },
            set: { _ in }
        )
    }

    private var remoteUninstallConfirmationBinding: Binding<Bool> {
        Binding(
            get: { model.pendingRemoteUninstall != nil },
            set: { if !$0 { model.cancelRemoteUninstall() } }
        )
    }
}
