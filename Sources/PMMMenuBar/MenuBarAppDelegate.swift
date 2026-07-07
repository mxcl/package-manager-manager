import AppKit
import AppUpdater
import PMMCore
import ServiceManagement

@MainActor
final class MenuBarAppDelegate: NSObject, NSApplicationDelegate {
    private let appUpdater = AppUpdater(owner: "mxcl", repo: "package-manager-manager")
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let store = PackageHostStore()
    private let notificationCenter = DistributedNotificationCenter.default()
    private var availableUpdate: Update?
    private var state = MenuBarMenuState()
    private var snapshot = PackageHostSnapshot()
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private lazy var updateActivity: NSBackgroundActivityScheduler = {
        let activity = NSBackgroundActivityScheduler(identifier: "dev.mxcl.pmm.app-update-check")
        activity.repeats = true
        activity.interval = 24 * 60 * 60
        return activity
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadSnapshot()
        observeCommands()
        configureStatusButton()
        rebuildMenu()
        scheduleAppUpdateChecks()
        timer = Timer.scheduledTimer(withTimeInterval: 3300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        if menuBarShouldRefreshOnLaunch(snapshot: snapshot) {
            refresh()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        refreshTask?.cancel()
        actionTask?.cancel()
        updateActivity.invalidate()
        notificationCenter.removeObserver(self)
    }

    private func refresh() {
        guard refreshTask == nil, actionTask == nil else { return }
        snapshot.isRefreshing = true
        snapshot.errorMessage = nil
        publishSnapshot()
        let previousLastBrewUpdateAt = snapshot.lastBrewUpdateAt

        refreshTask = Task { [weak self] in
            let next = await Task.detached(priority: .background) {
                let lastBrewUpdateAt: Date?
                let brewError: String?
                do {
                    try HomebrewMaintenance().update()
                    lastBrewUpdateAt = Date()
                    brewError = nil
                } catch {
                    lastBrewUpdateAt = nil
                    brewError = error.localizedDescription
                }
                return await Self.scanSnapshot(errorMessage: brewError, lastBrewUpdateAt: lastBrewUpdateAt)
            }.value

            guard let self, !Task.isCancelled else { return }
            self.refreshTask = nil
            self.snapshot = next
            if self.snapshot.lastBrewUpdateAt == nil {
                self.snapshot.lastBrewUpdateAt = previousLastBrewUpdateAt
            }
            self.publishSnapshot()
        }
    }

    private func rescanAfterAction(errorMessage: String? = nil) {
        let lastBrewUpdateAt = snapshot.lastBrewUpdateAt
        actionTask = Task { [weak self] in
            let next = await Task.detached(priority: .background) {
                await Self.scanSnapshot(errorMessage: errorMessage, lastBrewUpdateAt: lastBrewUpdateAt)
            }.value

            guard let self, !Task.isCancelled else { return }
            self.actionTask = nil
            self.snapshot = next
            self.publishSnapshot()
        }
    }

    private func runAction(kind: PackageHostActionKind, packageID: String) {
        guard refreshTask == nil, actionTask == nil,
              let package = menuBarCommandPackage(id: packageID, kind: kind, snapshot: snapshot) else { return }
        snapshot.runningAction = PackageHostRunningAction(kind: kind, packageID: package.id, displayName: package.displayName)
        snapshot.errorMessage = nil
        publishSnapshot()

        actionTask = Task { [weak self] in
            let result = await Task.detached(priority: .background) {
                Result {
                    switch kind {
                    case .update:
                        try PackageUpdater().update(package)
                    case .uninstall:
                        try PackageUninstaller().uninstall(package)
                    }
                }
            }.value

            guard let self, !Task.isCancelled else { return }
            self.snapshot.runningAction = nil
            self.publishSnapshot()
            switch result {
            case .success:
                self.rescanAfterAction()
            case .failure(let error):
                self.rescanAfterAction(errorMessage: error.localizedDescription)
            }
        }
    }

    private func loadSnapshot() {
        if var saved = try? store.load() {
            saved.isRefreshing = false
            saved.runningAction = nil
            snapshot = saved
        }
        publishSnapshot()
    }

    private func publishSnapshot() {
        state = MenuBarMenuState(
            inventory: snapshot.inventory,
            isRefreshing: snapshot.isRefreshing,
            errorMessage: snapshot.errorMessage ?? snapshot.inventory?.errors.first
        )
        try? store.save(snapshot)
        PackageHostNotifications.postSnapshotChanged()
        rebuildMenu()
    }

    private nonisolated static func scanSnapshot(errorMessage: String?, lastBrewUpdateAt: Date?) async -> PackageHostSnapshot {
        let database = await PackageDatabase.load()
        let inventory = await PackageScanner().inventory(database: database)
        let errors = [errorMessage].compactMap { $0 } + inventory.errors
        return PackageHostSnapshot(
            inventory: PackageInventory(packages: inventory.packages, errors: errors),
            catalogPackages: database.catalogPackages,
            isRefreshing: false,
            runningAction: nil,
            errorMessage: errorMessage ?? inventory.errors.first,
            lastBrewUpdateAt: lastBrewUpdateAt
        )
    }

    private func observeCommands() {
        notificationCenter.addObserver(self, selector: #selector(refreshRequested(_:)), name: PackageHostNotifications.refreshRequested, object: nil)
        notificationCenter.addObserver(self, selector: #selector(updateRequested(_:)), name: PackageHostNotifications.updateRequested, object: nil)
        notificationCenter.addObserver(self, selector: #selector(uninstallRequested(_:)), name: PackageHostNotifications.uninstallRequested, object: nil)
    }

    private func rebuildMenu() {
        updateStatusButton()

        let menu = NSMenu()
        for row in state.rows {
            switch row {
            case .loading:
                menu.addItem(loadingItem())
            case .empty:
                menu.addItem(disabledItem("No outdated packages"))
            case .error(let message):
                menu.addItem(disabledItem("Error: \(message)"))
            case .package(let package):
                menu.addItem(disabledItem("\(package.managerTitle): \(package.name) \(package.installedVersion) -> \(package.latestVersion)"))
            }
        }

        menu.addItem(.separator())
        if availableUpdate != nil {
            let updatePMMItem = menu.addItem(withTitle: "Update PM²", action: #selector(updatePMM(_:)), keyEquivalent: "")
            updatePMMItem.target = self
        }

        let refreshItem = menu.addItem(withTitle: "Refresh Now", action: #selector(refreshNow(_:)), keyEquivalent: "")
        refreshItem.target = self
        refreshItem.isEnabled = !state.isRefreshing && snapshot.runningAction == nil

        let openItem = menu.addItem(withTitle: "Open Main Window", action: #selector(openMainWindow(_:)), keyEquivalent: "")
        openItem.target = self

        let loginItem = menu.addItem(withTitle: "Start at Login", action: #selector(toggleStartAtLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off

        menu.addItem(.separator())
        let quitItem = menu.addItem(withTitle: "Quit PM²", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp

        statusItem.menu = menu
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageOnly
        button.toolTip = "Package Manager Manager"
        button.setAccessibilityLabel("Package Manager Manager")
        updateStatusButton()
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: state.statusSymbolName, accessibilityDescription: "Package Manager Manager")
            ?? NSImage(systemSymbolName: "shippingbox.fill", accessibilityDescription: "Package Manager Manager")
        image?.isTemplate = true
        button.image = image
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func loadingItem() -> NSMenuItem {
        let item = NSMenuItem()
        let spinner = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let label = NSTextField(labelWithString: "Loading outdated packages...")
        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        item.view = stack
        return item
    }

    private func scheduleAppUpdateChecks() {
        updateActivity.schedule { [weak self] completion in
            Task { @MainActor in
                guard let self else {
                    completion(.finished)
                    return
                }
                guard !self.updateActivity.shouldDefer else {
                    completion(.deferred)
                    return
                }
                do {
                    self.availableUpdate = try await self.appUpdater.check()
                    self.rebuildMenu()
                } catch {
                    // Background update checks are best-effort; keep any staged update visible.
                }
                completion(.finished)
            }
        }
    }

    @objc private func refreshNow(_ sender: Any?) {
        refresh()
    }

    @objc private func updatePMM(_ sender: Any?) {
        guard let update = availableUpdate else { return }
        availableUpdate = nil
        rebuildMenu()
        Task { @MainActor in
            do {
                try await update.installAndRelaunch()
            } catch {
                self.availableUpdate = update
                self.snapshot.errorMessage = error.localizedDescription
                self.publishSnapshot()
            }
        }
    }

    @objc private func refreshRequested(_ notification: Notification) {
        refresh()
    }

    @objc private func updateRequested(_ notification: Notification) {
        guard let packageID = PackageHostNotifications.packageID(from: notification) else { return }
        runAction(kind: .update, packageID: packageID)
    }

    @objc private func uninstallRequested(_ notification: Notification) {
        guard let packageID = PackageHostNotifications.packageID(from: notification) else { return }
        runAction(kind: .uninstall, packageID: packageID)
    }

    @objc private func openMainWindow(_ sender: Any?) {
        let mainApp = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: mainApp, configuration: configuration)
    }

    @objc private func toggleStartAtLogin(_ sender: Any?) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            snapshot.errorMessage = error.localizedDescription
        }
        publishSnapshot()
    }
}
