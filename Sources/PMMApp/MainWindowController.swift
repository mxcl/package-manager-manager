import AppKit
import Combine
import PMMCore
import SwiftUI

@MainActor
final class MainWindowController: NSSplitViewController {
    private let model = MainWindowModel(dossierClient: PackageDossierClient())
    private var toolbarStateCancellable: AnyCancellable?
    var onToolbarStateChanged: (() -> Void)?

    init() {
        super.init(nibName: nil, bundle: nil)
        splitView = NoDividerSplitView()
    }

    @MainActor @preconcurrency required dynamic init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true
        toolbarStateCancellable = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.onToolbarStateChanged?()
            }
        }

        addSplitViewItem(sidebarItem())
        addSplitViewItem(contentItem(MainWindowContentColumnsView(model: model), width: 1128, minimumWidth: 854))
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

    private func sidebarItem() -> NSSplitViewItem {
        let controller = NSHostingController(rootView: MainWindowSidebarView(model: model)
            .accentColor(SystemColor.packageBrown)
            .tint(SystemColor.packageBrown))
        let item = NSSplitViewItem(sidebarWithViewController: controller)
        item.minimumThickness = 250
        item.maximumThickness = 250
        item.allowsFullHeightLayout = true
        return item
    }

    private func contentItem<Content: View>(_ rootView: Content, width: CGFloat, minimumWidth: CGFloat, maximumWidth: CGFloat? = nil) -> NSSplitViewItem {
        let controller = NSHostingController(rootView: rootView
            .accentColor(SystemColor.packageBrown)
            .tint(SystemColor.packageBrown))
        let item = NSSplitViewItem(viewController: controller)
        item.minimumThickness = minimumWidth
        if let maximumWidth {
            item.maximumThickness = maximumWidth
        }
        item.preferredThicknessFraction = 0
        item.holdingPriority = maximumWidth == nil ? .defaultLow : .defaultHigh
        controller.view.widthAnchor.constraint(greaterThanOrEqualToConstant: minimumWidth).isActive = true
        let widthConstraint = controller.view.widthAnchor.constraint(equalToConstant: width)
        widthConstraint.priority = maximumWidth == nil ? .defaultLow : .required
        widthConstraint.isActive = true
        return item
    }
}

private struct MainWindowContentColumnsView: View {
    @ObservedObject var model: MainWindowModel

    var body: some View {
        if model.selectedSection == .home {
            MainWindowDashboardView(model: model)
        } else {
            HStack(spacing: 0) {
                MainWindowPackageListView(model: model)
                    .frame(width: 252)
                Rectangle()
                    .fill(SystemColor.hairline)
                    .frame(width: 1)
                    .ignoresSafeArea(.container, edges: .vertical)
                MainWindowDossierView(model: model)
                    .frame(width: 252)
                MainWindowLinksView(model: model)
                    .frame(minWidth: 350, maxWidth: .infinity)
            }
        }
    }
}

private final class NoDividerSplitView: NSSplitView {
    override var dividerThickness: CGFloat { 0 }

    override func drawDivider(in rect: NSRect) {}
}
