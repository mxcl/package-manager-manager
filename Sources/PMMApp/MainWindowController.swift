import AppKit
import PMMCore
import SwiftUI

@MainActor
final class MainWindowController: NSHostingController<MainWindowRootView> {
    private let model = MainWindowModel(
        dossierClient: PackageDossierClient(),
        dashboardBlogURL: MainWindowModel.defaultDashboardBlogURL
    )
    private var showsAppUpdateButton = false

    init() {
        super.init(rootView: MainWindowRootView(model: model, showsAppUpdateButton: false, updateApp: {}))
    }

    @MainActor @preconcurrency required dynamic init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        DispatchQueue.main.async { [weak self] in
            self?.view.window?.makeFirstResponder(nil)
        }
#if DEBUG
        if ProcessInfo.processInfo.environment["PMM_TERMINAL_DEMO"] != "1" {
            model.syncFromHost()
        }
#else
        model.syncFromHost()
#endif
    }

    @objc func refresh(_ sender: Any?) {
        model.reload()
    }

    func openPackageURL(_ url: URL) {
        model.openPackageURL(url)
    }

    func showHostManagement() {
        model.showHostManagement()
    }

    func setAppUpdateButtonVisible(_ isVisible: Bool, updateApp: @escaping () -> Void) {
        guard showsAppUpdateButton != isVisible else { return }
        showsAppUpdateButton = isVisible
        rootView = MainWindowRootView(model: model, showsAppUpdateButton: isVisible, updateApp: updateApp)
    }

    override func moveUp(_ sender: Any?) {
        if !model.selectAdjacentPackage(offset: -1) {
            super.moveUp(sender)
        }
    }

    override func moveDown(_ sender: Any?) {
        if !model.selectAdjacentPackage(offset: 1) {
            super.moveDown(sender)
        }
    }
}

struct MainWindowRootView: View {
    @ObservedObject var model: MainWindowModel
    let showsAppUpdateButton: Bool
    let updateApp: () -> Void

    var body: some View {
        Group {
            if model.showsDashboard {
                NavigationSplitView {
                    sidebar
                } detail: {
                    MainWindowDashboardView(model: model)
                        .navigationSplitViewColumnWidth(min: 602, ideal: 1128)
                        .toolbar { appUpdateToolbarItem }
                }
                .searchable(text: $model.searchText, placement: .sidebar, prompt: "Search")
                .toolbar(removing: .title)

            } else {
                NavigationSplitView {
                    sidebar
                } content: {
                    MainWindowPackageListView(model: model)
                        .navigationSplitViewColumnWidth(min: 252, ideal: 252, max: 252)
                        .toolbar {
                            ToolbarSpacer() //TODO I only want to space it to the edge of this column! :-/
                            updateAllToolbarItem
                        }
                } detail: {
                    HStack(spacing: 0) {
                        MainWindowDossierView(model: model)
                            .frame(width: 252)
                        MainWindowLinksView(model: model)
                            .frame(minWidth: 350, maxWidth: .infinity)
                    }
                    .navigationSplitViewColumnWidth(min: 602, ideal: 876)
                    .toolbar {
                        ToolbarSpacer() // or updateAllToolbarItem comes over here
                        appUpdateToolbarItem
                    }
                }
                .searchable(text: $model.searchText, placement: .sidebar, prompt: "Search")
                .toolbar(removing: .title)
            }
        }
        .sheet(isPresented: $model.showsHostManagement) {
            RemoteHostsManagementView(model: model)
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

    @ToolbarContentBuilder
    private var updateAllToolbarItem: some ToolbarContent {
        if model.showsUpdateAllOutdatedPackages {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.updateAllOutdatedPackages()
                } label: {
                    Label("Update All", systemImage: "arrow.down.circle")
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

    private var remoteUninstallConfirmationBinding: Binding<Bool> {
        Binding(
            get: { model.pendingRemoteUninstall != nil },
            set: { if !$0 { model.cancelRemoteUninstall() } }
        )
    }
}
