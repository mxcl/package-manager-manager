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
        positionTrafficLights()
        DispatchQueue.main.async { [weak self] in self?.positionTrafficLights() }
    }

    private func installToolbarIfNeeded() {
        guard view.window?.toolbar == nil else { return }
        let toolbar = NSToolbar(identifier: "PMMToolbar")
        toolbar.displayMode = .iconOnly
        toolbar.delegate = self
        view.window?.toolbar = toolbar
    }

    private func positionTrafficLights() {
        guard
            let window = view.window,
            let close = window.standardWindowButton(.closeButton),
            let miniaturize = window.standardWindowButton(.miniaturizeButton),
            let zoom = window.standardWindowButton(.zoomButton),
            let superview = close.superview
        else { return }

        let topInset: CGFloat = 24
        let leftInset: CGFloat = 26
        let y = max(superview.bounds.height - close.frame.height - topInset, 0)
        close.setFrameOrigin(NSPoint(x: leftInset, y: y))
        miniaturize.setFrameOrigin(NSPoint(x: leftInset + 20, y: y))
        zoom.setFrameOrigin(NSPoint(x: leftInset + 40, y: y))
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
