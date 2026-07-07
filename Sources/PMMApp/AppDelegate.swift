import AppKit
import AppUpdater

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSToolbarDelegate {
    private let appUpdater = AppUpdater(owner: "mxcl", repo: "package-manager-manager")
    private var checkForUpdatesItem: NSMenuItem?
    private var updateButton: NSButton?
    private var availableUpdate: Update? {
        didSet {
            syncUpdateToolbarItem()
        }
    }
    private var window: NSWindow?
    private var isCheckingForUpdates = false {
        didSet {
            checkForUpdatesItem?.isEnabled = !isCheckingForUpdates
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        showMainWindow()
        launchMenuBarApp()
        checkForUpdates(reportCurrent: false)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func showMainWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let initialContentSize = NSSize(width: 1378, height: 824)
        let controller = MainWindowController()
        let window = PMMWindow(
            contentRect: NSRect(origin: .zero, size: initialContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.title = "Package Manager Manager"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .automatic
        let toolbar = NSToolbar(identifier: "PMMToolbar")
        toolbar.displayMode = .iconOnly
        toolbar.delegate = self
        window.toolbar = toolbar
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 1104, height: 680)
        window.setContentSize(initialContentSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate()
    }

    private func makeMainMenu() -> NSMenu {
        let menu = NSMenu(title: L10n.string("Main Menu"))
        menu.addItem(makeAppMenuItem())
        menu.addItem(makeEditMenuItem())
        menu.addItem(makeWindowMenuItem())
        return menu
    }

    private func launchMenuBarApp() {
        let helper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LoginItems/Package Manager Manager Menu.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: helper.path) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: helper, configuration: configuration)
    }

    private func makeAppMenuItem() -> NSMenuItem {
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: L10n.string("Package Manager Manager"))
        let appName = L10n.string("Package Manager Manager")

        appMenu.addItem(withTitle: L10n.format("About %@", appName), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        checkForUpdatesItem = appMenu.addItem(withTitle: L10n.string("Check for Updates…"), action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        checkForUpdatesItem?.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.format("Hide %@", appName), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: L10n.string("Hide Others"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: L10n.string("Show All"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.format("Quit %@", appName), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        return appItem
    }

    private func makeEditMenuItem() -> NSMenuItem {
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: L10n.string("Edit"))

        editMenu.addItem(withTitle: L10n.string("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = editMenu.addItem(withTitle: L10n.string("Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L10n.string("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L10n.string("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L10n.string("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L10n.string("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        editItem.submenu = editMenu
        return editItem
    }

    private func makeWindowMenuItem() -> NSMenuItem {
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: L10n.string("Window"))

        let refreshItem = windowMenu.addItem(withTitle: L10n.string("Refresh"), action: #selector(refreshPackages(_:)), keyEquivalent: "r")
        refreshItem.target = self
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: L10n.string("Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: L10n.string("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: L10n.string("Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        return windowItem
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .updatePMM]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        availableUpdate == nil ? [] : [.flexibleSpace, .updatePMM]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == .updatePMM else { return nil }
        let button = NSButton(title: "Update PM²", target: self, action: #selector(updatePMM(_:)))
        button.bezelStyle = .toolbar
        button.controlSize = .small
        button.image = NSImage(systemSymbolName: "arrow.down.app", accessibilityDescription: "Update PM²")
        button.imagePosition = .imageLeading
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = "Update PM²"
        item.paletteLabel = "Update PM²"
        item.view = button
        updateButton = button
        return item
    }

    @objc private func refreshPackages(_ sender: Any?) {
        (window?.contentViewController as? MainWindowController)?.refresh(sender)
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        checkForUpdates(reportCurrent: true)
    }

    private func checkForUpdates(reportCurrent: Bool) {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        Task { @MainActor in
            do {
                availableUpdate = try await appUpdater.check()
                if availableUpdate == nil, reportCurrent {
                    showUpdateAlert(message: "PM² is up to date.")
                }
            } catch {
                if reportCurrent {
                    showUpdateAlert(message: "Unable to check for updates.", informativeText: error.localizedDescription)
                }
            }
            isCheckingForUpdates = false
        }
    }

    private func syncUpdateToolbarItem() {
        guard let toolbar = window?.toolbar else { return }
        let ids = toolbar.items.map(\.itemIdentifier)
        let hasUpdateItem = ids.contains(.updatePMM)
        if availableUpdate != nil, !hasUpdateItem {
            toolbar.insertItem(withItemIdentifier: .flexibleSpace, at: 0)
            toolbar.insertItem(withItemIdentifier: .updatePMM, at: 1)
        } else if availableUpdate == nil, hasUpdateItem {
            for index in toolbar.items.indices.reversed()
            where [.flexibleSpace, .updatePMM].contains(toolbar.items[index].itemIdentifier) {
                toolbar.removeItem(at: index)
            }
            updateButton = nil
        }
    }

    @objc private func updatePMM(_ sender: Any?) {
        guard let update = availableUpdate else { return }
        updateButton?.isEnabled = false
        Task { @MainActor in
            do {
                try await update.installAndRelaunch()
            } catch {
                updateButton?.isEnabled = true
                showUpdateAlert(message: "Unable to install update.", informativeText: error.localizedDescription)
            }
        }
    }

    private func showUpdateAlert(message: String, informativeText: String = "") {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informativeText
        alert.runModal()
    }
}

private extension NSToolbarItem.Identifier {
    static let updatePMM = NSToolbarItem.Identifier("UpdatePMM")
}

private final class PMMWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        makeFirstResponder(nil)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, firstResponder is NSText {
            makeFirstResponder(nil)
        }
        super.sendEvent(event)
    }
}
