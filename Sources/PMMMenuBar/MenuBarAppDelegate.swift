import AppKit
import PMMCore
import ServiceManagement

@MainActor
final class MenuBarAppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var state = MenuBarMenuState()
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusButton()
        rebuildMenu()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        refreshTask?.cancel()
    }

    private func refresh() {
        guard refreshTask == nil else { return }
        state.isRefreshing = true
        rebuildMenu()

        refreshTask = Task { [weak self] in
            let result = await Task.detached(priority: .background) {
                do {
                    try HomebrewMaintenance().update()
                    let database = await PackageDatabase.load()
                    let inventory = await PackageScanner().inventory(database: database)
                    return Result<PackageInventory, Error>.success(inventory)
                } catch {
                    return .failure(error)
                }
            }.value

            guard let self, !Task.isCancelled else { return }
            self.refreshTask = nil
            self.state.isRefreshing = false
            switch result {
            case .success(let inventory):
                self.state.inventory = inventory
                self.state.errorMessage = inventory.errors.first
            case .failure(let error):
                self.state.errorMessage = error.localizedDescription
            }
            self.rebuildMenu()
        }
    }

    private func rebuildMenu() {
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
        let refreshItem = menu.addItem(withTitle: "Refresh Now", action: #selector(refreshNow(_:)), keyEquivalent: "")
        refreshItem.target = self
        refreshItem.isEnabled = !state.isRefreshing

        let openItem = menu.addItem(withTitle: "Open Main Window", action: #selector(openMainWindow(_:)), keyEquivalent: "")
        openItem.target = self

        let loginItem = menu.addItem(withTitle: "Start at Login", action: #selector(toggleStartAtLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off

        menu.addItem(.separator())
        let quitItem = menu.addItem(withTitle: "Quit Menu Bar App", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp

        statusItem.menu = menu
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: "shippingbox.fill", accessibilityDescription: "Package Manager Manager")
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageOnly
        button.toolTip = "Package Manager Manager"
        button.setAccessibilityLabel("Package Manager Manager")
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

    @objc private func refreshNow(_ sender: Any?) {
        refresh()
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
            state.errorMessage = error.localizedDescription
        }
        rebuildMenu()
    }
}
