import AppKit
import Combine
import PMMCore
import SwiftUI

@MainActor
final class MainWindowController: NSHostingController<MainWindowRootView> {
    private let model = MainWindowModel(dossierClient: PackageDossierClient())
    private var toolbarStateCancellable: AnyCancellable?
    var onToolbarStateChanged: (() -> Void)?

    init() {
        super.init(rootView: MainWindowRootView(model: model))
    }

    @MainActor @preconcurrency required dynamic init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        toolbarStateCancellable = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.onToolbarStateChanged?()
            }
        }
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

    var showsUpdateAllToolbarButton: Bool {
        model.showsUpdateAllOutdatedPackages
    }

    var canUpdateAllPackages: Bool {
        model.canUpdateAllOutdatedPackages
    }

    @objc func updateAllPackages(_ sender: Any?) {
        model.updateAllOutdatedPackages()
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

    var body: some View {
        Group {
            if model.selectedSection == .home {
                NavigationSplitView {
                    sidebar
                } detail: {
                    MainWindowDashboardView(model: model)
                        .navigationSplitViewColumnWidth(min: 602, ideal: 1128)
                }
                .searchable(text: $model.searchText, placement: .sidebar, prompt: "Search")
            } else {
                NavigationSplitView {
                    sidebar
                } content: {
                    MainWindowPackageListView(model: model)
                        .navigationSplitViewColumnWidth(min: 252, ideal: 252, max: 252)
                } detail: {
                    HStack(spacing: 0) {
                        MainWindowDossierView(model: model)
                            .frame(width: 252)
                        MainWindowLinksView(model: model)
                            .frame(minWidth: 350, maxWidth: .infinity)
                    }
                    .navigationSplitViewColumnWidth(min: 602, ideal: 876)
                }
                .searchable(text: $model.searchText, placement: .sidebar, prompt: "Search")
            }
        }
        .accentColor(SystemColor.packageBrown)
        .tint(SystemColor.packageBrown)
    }

    private var sidebar: some View {
        MainWindowSidebarView(model: model)
            .navigationSplitViewColumnWidth(min: 250, ideal: 250, max: 250)
    }
}
