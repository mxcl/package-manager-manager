import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var sidebarToggleAccessory: NSTitlebarAccessoryViewController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        showMainWindow()
        launchMenuBarApp()
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
        window.toolbar = toolbar
        installSidebarToggleAccessory(in: window, target: controller)
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

    @objc private func refreshPackages(_ sender: Any?) {
        (window?.contentViewController as? MainWindowController)?.refresh(sender)
    }

    private func installSidebarToggleAccessory(in window: NSWindow, target: NSSplitViewController) {
        let width: CGFloat = 170
        let height: CGFloat = 52
        let container = TitlebarAccessoryView(size: NSSize(width: width, height: height))
        let title = L10n.string("Toggle Sidebar")
        let button = NSButton(image: NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: title) ?? NSImage(), target: target, action: #selector(NSSplitViewController.toggleSidebar(_:)))
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        button.toolTip = title
        button.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .left
        accessory.view = container
        window.addTitlebarAccessoryViewController(accessory)
        sidebarToggleAccessory = accessory
    }
}

private final class TitlebarAccessoryView: NSView {
    private let size: NSSize

    init(size: NSSize) {
        self.size = size
        super.init(frame: NSRect(origin: .zero, size: size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize { size }
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
