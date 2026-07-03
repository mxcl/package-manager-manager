import AppKit
import SwiftUI

@MainActor
final class MainWindowController: NSHostingController<MainWindowRootView> {
    private let model: MainWindowModel

    init() {
        let model = MainWindowModel()
        self.model = model
        super.init(rootView: MainWindowRootView(model: model))
    }

    @MainActor @preconcurrency required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        DispatchQueue.main.async { [weak self] in
            self?.view.window?.makeFirstResponder(nil)
        }
        model.reload()
    }

    @objc func refresh(_ sender: Any?) {
        model.reload()
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
        HStack(spacing: 0) {
            MainWindowSidebarView(model: model)
                .frame(width: 250)
            MainWindowPackageListView(model: model)
                .frame(width: 252)
            MainWindowDossierView(model: model)
                .frame(width: 252)
            MainWindowLinksView(model: model)
                .frame(minWidth: 350, maxWidth: .infinity)
        }
        .ignoresSafeArea(.container, edges: .top)
    }
}
