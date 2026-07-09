import AppKit
import PMMCore
import SwiftUI

@MainActor
final class MainWindowController: NSHostingController<MainWindowRootView> {
    private let model = MainWindowModel(
        dossierClient: PackageDossierClient(),
        dashboardInstallPacksURL: MainWindowModel.defaultDashboardInstallPacksURL
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
        model.syncFromHost()
    }

    @objc func refresh(_ sender: Any?) {
        model.reload()
    }

    func openPackageURL(_ url: URL) {
        model.openPackageURL(url)
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
            if model.selectedSection == .home {
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
                        .toolbar { updateAllToolbarItem }
                } detail: {
                    HStack(spacing: 0) {
                        MainWindowDossierView(model: model)
                            .frame(width: 252)
                        MainWindowLinksView(model: model)
                            .frame(minWidth: 350, maxWidth: .infinity)
                    }
                    .navigationSplitViewColumnWidth(min: 602, ideal: 876)
                    .toolbar { appUpdateToolbarItem }
                }
                .searchable(text: $model.searchText, placement: .sidebar, prompt: "Search")
                .toolbar(removing: .title)
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
}
