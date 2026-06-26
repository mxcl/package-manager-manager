import AppKit
import SwiftUI

@MainActor
final class MainWindowController: NSHostingController<MainWindowView> {
    private let model = MainWindowModel()

    init() {
        super.init(rootView: MainWindowView(model: model))
    }

    @MainActor @preconcurrency required dynamic init?(coder: NSCoder) {
        super.init(coder: coder, rootView: MainWindowView(model: model))
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        model.reload()
        installToolbarIfNeeded()
    }

    private func installToolbarIfNeeded() {
        guard view.window?.toolbar == nil else { return }
        let toolbar = NSToolbar(identifier: "PMMToolbar")
        toolbar.displayMode = .iconOnly
        toolbar.delegate = self
        view.window?.toolbar = toolbar
    }

    @objc private func refresh(_ sender: Any?) {
        model.reload()
    }
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
