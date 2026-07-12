import AppKit
import PMMCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = PackageHostStore()
    private let notificationCenter = DistributedNotificationCenter.default()
    private var checkForUpdatesItem: NSMenuItem?
    private var appUpdatePresentation = AppUpdatePresentationState() {
        didSet {
            checkForUpdatesItem?.isEnabled = !appUpdatePresentation.host.isChecking
            syncToolbarItems()
        }
    }
    private var window: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        PostHogTelemetry.shared.captureAppOpened()
        NSApp.mainMenu = makeMainMenu()
        observeAppUpdateHost()
#if DEBUG
        let isTerminalDemo = ProcessInfo.processInfo.environment["PMM_TERMINAL_DEMO"] == "1"
        if !isTerminalDemo {
            launchMenuBarApp()
        }
#else
        launchMenuBarApp()
#endif
        showMainWindow()
        syncAppUpdateState()
    }

    func applicationWillTerminate(_ notification: Notification) {
        notificationCenter.removeObserver(self)
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
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 1104, height: 680)
        window.setContentSize(initialContentSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        syncToolbarItems()
        NSApp.activate()
    }

    private func makeMainMenu() -> NSMenu {
        let menu = NSMenu(title: L10n.string("Main Menu"))
        menu.addItem(makeAppMenuItem())
        menu.addItem(makePackageMenuItem())
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
        let manageHostsItem = appMenu.addItem(withTitle: L10n.string("Add / Edit Hosts…"), action: #selector(showHostManagement(_:)), keyEquivalent: "")
        manageHostsItem.target = self
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

    private func makePackageMenuItem() -> NSMenuItem {
        let packageItem = NSMenuItem()
        let packageMenu = NSMenu(title: L10n.string("Package"))

        let refreshItem = packageMenu.addItem(withTitle: L10n.string("Refresh"), action: #selector(refreshPackages(_:)), keyEquivalent: "r")
        refreshItem.target = self
        packageItem.submenu = packageMenu
        return packageItem
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

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard
            let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
            let url = URL(string: string)
        else { return }
        showMainWindow()
        mainWindowController?.openPackageURL(url)
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        guard appUpdatePresentation.beginManualCheck() else { return }
        PackageHostNotifications.postAppUpdateCheckRequested()
    }

    @objc private func showHostManagement(_ sender: Any?) {
        showMainWindow()
        mainWindowController?.showHostManagement()
    }

    private func syncToolbarItems() {
        mainWindowController?.setAppUpdateButtonVisible(appUpdatePresentation.host.isAvailable) { [weak self] in
            self?.requestAppUpdateInstall()
        }
    }

    private var mainWindowController: MainWindowController? {
        window?.contentViewController as? MainWindowController
    }

    private func observeAppUpdateHost() {
        notificationCenter.addObserver(self, selector: #selector(hostSnapshotChanged(_:)), name: PackageHostNotifications.snapshotChanged, object: nil)
        notificationCenter.addObserver(self, selector: #selector(appUpdateQuitRequested(_:)), name: PackageHostNotifications.appUpdateQuitRequested, object: nil)
    }

    @objc private func hostSnapshotChanged(_ notification: Notification) {
        syncAppUpdateState()
    }

    @objc private func appUpdateQuitRequested(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    private func syncAppUpdateState() {
        guard let state = try? store.load()?.appUpdate else { return }
        switch appUpdatePresentation.apply(state) {
        case .available:
            showUpdateAvailableAlert()
        case .current:
            showUpdateAlert(message: "pkg⋅mgr² is up to date.")
        case .checkFailed(let errorMessage):
            showUpdateAlert(message: "Unable to check for updates.", informativeText: errorMessage)
        case .installFailed(let errorMessage):
            showUpdateAlert(message: "Unable to install update.", informativeText: errorMessage)
        case nil:
            break
        }
    }

    private func showUpdateAvailableAlert() {
        let alert = NSAlert()
        alert.messageText = "A pkg⋅mgr² update is available."
        alert.informativeText = "Install it now?"
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            requestAppUpdateInstall()
        }
    }

    private func requestAppUpdateInstall() {
        appUpdatePresentation.beginInstall()
        PackageHostNotifications.postAppUpdateInstallRequested()
    }

    private func showUpdateAlert(message: String, informativeText: String = "") {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informativeText
        alert.runModal()
    }
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
