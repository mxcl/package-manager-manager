import AppKit
import SwiftUI

@MainActor
final class MainWindowController: NSSplitViewController {
    private let model = MainWindowModel()

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

        addSplitViewItem(sidebarItem())
        addSplitViewItem(contentItem(MainWindowPackageListView(model: model), width: 252, minimumWidth: 252, maximumWidth: 252))
        addSplitViewItem(contentItem(MainWindowDossierView(model: model), width: 252, minimumWidth: 252, maximumWidth: 252))
        addSplitViewItem(contentItem(MainWindowLinksView(model: model), width: 624, minimumWidth: 350))
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        DispatchQueue.main.async { [weak self] in
            self?.view.window?.makeFirstResponder(nil)
        }
        model.reload()
    }

    func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "PMMToolbar")
        toolbar.displayMode = .iconOnly
        toolbar.delegate = self
        return toolbar
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

    private func sidebarItem() -> NSSplitViewItem {
        let controller = NSHostingController(rootView: MainWindowSidebarView(model: model))
        let item = NSSplitViewItem(sidebarWithViewController: controller)
        item.minimumThickness = 250
        item.maximumThickness = 250
        return item
    }

    private func contentItem<Content: View>(_ rootView: Content, width: CGFloat, minimumWidth: CGFloat, maximumWidth: CGFloat? = nil) -> NSSplitViewItem {
        let controller = NSHostingController(rootView: rootView)
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

private final class NoDividerSplitView: NSSplitView {
    override var dividerThickness: CGFloat { 0 }

    override func drawDivider(in rect: NSRect) {}
}

extension MainWindowController: NSToolbarDelegate {
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.refresh, .flexibleSpace]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .refresh]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == .refresh else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        item.label = "Refresh"
        item.target = self
        item.action = #selector(refresh(_:))
        return item
    }
}

private extension NSToolbarItem.Identifier {
    static let refresh = NSToolbarItem.Identifier("PMMRefreshToolbarItem")
}
