import AppKit
import AppUpdater
import PMMCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var checkForUpdatesItem: NSMenuItem?
    private var appUpdateTask: Task<Void, Never>?
    private var pendingAppUpdateInstall = false
    private var appUpdateProgressWindow: NSWindow?
    private var appUpdatePresentation = AppUpdatePresentationState() {
        didSet {
            checkForUpdatesItem?.isEnabled = !appUpdatePresentation.host.isChecking
            syncToolbarItems()
        }
    }
    private var window: NSWindow?
    private lazy var appUpdater = AppUpdater(
        owner: "mxcl",
        repo: "package-manager-manager"
    )
    private lazy var appUpdateController = AppUpdateController(
        checkForUpdate: { [weak self] in
            guard let self, let update = try await self.appUpdater.check() else { return nil }
            return AppUpdateInstallation {
                let prepared = try await update.prepareInstallation()
                return PreparedAppUpdateInstallation(
                    install: { try await prepared.installAndRelaunch() },
                    discard: { await prepared.discard() }
                )
            }
        },
        publish: { [weak self] state in self?.applyAppUpdateState(state) },
        requestHelperQuit: PackageHostNotifications.postAppUpdateQuitRequested,
        waitForHelperExit: { [weak self] in await self?.waitForMenuBarAppExit() ?? false },
        quiesce: { [weak self] in self?.quiesceForAppUpdate() }
    )

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
#if DEBUG
        let isTerminalDemo = ProcessInfo.processInfo.environment["PMM_TERMINAL_DEMO"] == "1"
        if !isTerminalDemo {
            launchMenuBarApp()
        }
#else
        launchMenuBarApp()
#endif
        showMainWindow()
        startAppUpdateCheck()
    }

    func applicationWillTerminate(_ notification: Notification) {
        appUpdateTask?.cancel()
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
        startAppUpdateCheck()
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

    private func applyAppUpdateState(_ state: AppUpdateHostState) {
        switch appUpdatePresentation.apply(state) {
        case .available:
            showUpdateAvailableAlert()
        case .current:
            hideAppUpdateProgress()
            showUpdateAlert(message: "pkg⋅mgr² is up to date.")
        case .checkFailed(let errorMessage):
            showUpdateAlert(message: "Unable to check for updates.", informativeText: errorMessage)
        case .installFailed(let errorMessage):
            hideAppUpdateProgress()
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
        showAppUpdateProgress()
        guard appUpdateTask == nil else {
            pendingAppUpdateInstall = true
            return
        }
        startAppUpdateTask { await $0.install() }
    }

    private func startAppUpdateCheck() {
        startAppUpdateTask { await $0.check() }
    }

    private func startAppUpdateTask(_ operation: @escaping (AppUpdateController) async -> Void) {
        guard appUpdateTask == nil else { return }
        appUpdateTask = Task { [weak self] in
            guard let self else { return }
            await operation(self.appUpdateController)
            self.appUpdateTask = nil
            if self.pendingAppUpdateInstall {
                self.pendingAppUpdateInstall = false
                self.startAppUpdateTask { await $0.install() }
            }
        }
    }

    private func waitForMenuBarAppExit() async -> Bool {
        let helper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LoginItems/Package Manager Manager Menu.app", isDirectory: true)
        guard let identifier = Bundle(url: helper)?.bundleIdentifier else { return true }
        for _ in 0..<100 {
            if NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return false }
        }
        return false
    }

    private func quiesceForAppUpdate() {
        hideAppUpdateProgress()
        NSAppleEventManager.shared().removeEventHandler(
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
        window?.orderOut(nil)
        window?.contentViewController = nil
        NSApp.mainMenu = nil
    }

    private func showAppUpdateProgress() {
        guard let window, appUpdateProgressWindow == nil else { return }
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .large
        spinner.startAnimation(nil)

        let message = NSTextField(labelWithString: "Updating…")
        message.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let stack = NSStackView(views: [spinner, message])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets.top = 20

        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 110),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        sheet.titleVisibility = .hidden
        sheet.titlebarAppearsTransparent = true
        sheet.standardWindowButton(.closeButton)?.isHidden = true
        sheet.contentView = stack
        appUpdateProgressWindow = sheet
        window.beginSheet(sheet)
    }

    private func hideAppUpdateProgress() {
        guard let sheet = appUpdateProgressWindow else { return }
        sheet.sheetParent?.endSheet(sheet)
        appUpdateProgressWindow = nil
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
