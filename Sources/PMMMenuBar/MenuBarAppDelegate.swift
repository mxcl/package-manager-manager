import AppKit
import PMMCore
import ServiceManagement

struct MenuBarActionProgressResult: Equatable {
    let command: String?
    let output: String
}

func menuBarAction(_ action: PackageHostRunningAction, applyingStartedCommand command: String) -> PackageHostRunningAction {
    var action = action
    action.command = command
    return action
}

final class MenuBarActionProgressRelay: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "dev.mxcl.pmm.action-output", qos: .utility)
    private let limit: Int
    private let intervalNanoseconds: UInt64
    private let publish: @Sendable (String) -> Void
    private let lock = NSLock()
    private var command: String?
    private var output = ""
    private var lastPublishedAt: UInt64?
    private var pendingPublish: DispatchWorkItem?
    private var isDirty = false

    init(limit: Int = 100_000, interval: TimeInterval = 0.1, publish: @escaping @Sendable (String) -> Void) {
        self.limit = limit
        intervalNanoseconds = UInt64(interval * 1_000_000_000)
        self.publish = publish
    }

    func recordStarted(command: String) {
        lock.withLock { self.command = command }
    }

    func append(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        var immediateOutput: String?
        var scheduled: (DispatchWorkItem, UInt64)?
        lock.withLock {
            output.append(contentsOf: chunk)
            trimBufferIfNeeded()
            isDirty = true
            let now = DispatchTime.now().uptimeNanoseconds
            if lastPublishedAt == nil || now &- lastPublishedAt! >= intervalNanoseconds {
                pendingPublish?.cancel()
                pendingPublish = nil
                lastPublishedAt = now
                isDirty = false
                immediateOutput = cappedOutput()
            } else if pendingPublish == nil {
                let delay = intervalNanoseconds - (now &- lastPublishedAt!)
                let work = DispatchWorkItem { [weak self] in self?.publishPending() }
                pendingPublish = work
                scheduled = (work, delay)
            }
        }
        if let immediateOutput { publish(immediateOutput) }
        if let (work, delay) = scheduled {
            Self.queue.asyncAfter(deadline: .now() + .nanoseconds(Int(delay)), execute: work)
        }
    }

    func finish() -> MenuBarActionProgressResult {
        lock.withLock {
            pendingPublish?.cancel()
            pendingPublish = nil
            isDirty = false
            return MenuBarActionProgressResult(command: command, output: cappedOutput())
        }
    }

    private func publishPending() {
        let next: String? = lock.withLock {
            pendingPublish = nil
            guard isDirty else { return nil }
            isDirty = false
            lastPublishedAt = DispatchTime.now().uptimeNanoseconds
            return cappedOutput()
        }
        if let next { publish(next) }
    }

    private func trimBufferIfNeeded() {
        let threshold = limit + min(limit / 4, 16_384)
        if output.count > threshold { output = String(output.suffix(limit)) }
    }

    private func cappedOutput() -> String {
        output.count > limit ? String(output.suffix(limit)) : output
    }
}

@MainActor
final class MenuBarAppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let store = PackageHostStore()
    private let notificationCenter = DistributedNotificationCenter.default()
    private var state = MenuBarMenuState()
    private var snapshot = PackageHostSnapshot()
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var rescanTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadSnapshot()
        observeCommands()
        configureStatusButton()
        rebuildMenu()
        let now = Date()
        let shouldRefresh = menuBarShouldRefreshOnLaunch(snapshot: snapshot, now: now)
        let firstRefreshAt = shouldRefresh
            ? now.addingTimeInterval(menuBarRefreshInterval)
            : min(snapshot.inventory!.generatedAt.addingTimeInterval(menuBarRefreshInterval), now.addingTimeInterval(menuBarRefreshInterval))
        let timer = Timer(fire: firstRefreshAt, interval: menuBarRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        if shouldRefresh {
            refresh()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        refreshTask?.cancel()
        actionTask?.cancel()
        rescanTask?.cancel()
        notificationCenter.removeObserver(self)
    }

    private func refresh(ignoringAppCache: Bool = false) {
        guard refreshTask == nil, actionTask == nil else { return }
        rescanTask?.cancel()
        rescanTask = nil
        let missingManagers = snapshot.inventory == nil
            ? Set(PackageManagerKind.allCases)
            : (snapshot.loadingManagers ?? [])
        let generatedAt = Date()
        snapshot.isRefreshing = true
        snapshot.loadingManagers = missingManagers
        snapshot.errorMessage = nil
        publishSnapshot(updateFirstSeen: false)
        let previousLastBrewUpdateAt = snapshot.lastBrewUpdateAt
        let previousFirstSeen = snapshot.installedPackageFirstSeenAtByID
        let bootstrapDatabaseTask = Task.detached(priority: .utility) {
            PackageDatabase.bundled() ?? PackageDatabase.cached() ?? PackageDatabase()
        }
        let databaseTask = Task.detached(priority: .utility) {
            await PackageDatabase.load()
        }

        refreshTask = Task { [weak self] in
            guard let self else { return }
            var errorsByManager: [PackageManagerKind: [String]] = [:]
            let bootstrapDatabase = await bootstrapDatabaseTask.value
            let catalogPackages = await Task.detached(priority: .utility) {
                let scanner = PackageScanner()
                return bootstrapDatabase.catalogPackages(homebrewPrefix: scanner.homebrewPrefix())
            }.value
            guard !Task.isCancelled else { return }
            self.snapshot.catalogPackages = catalogPackages
            self.publishSnapshot(updateFirstSeen: false)

            let scanner = PackageScanner()
            for await result in scanner.results(
                for: Set(PackageManagerKind.allCases),
                database: bootstrapDatabase,
                mode: .local
            ) {
                guard !Task.isCancelled else { return }
                self.applyScanResult(result, generatedAt: generatedAt, errorsByManager: &errorsByManager)
                self.snapshot.loadingManagers?.remove(result.manager)
                self.publishSnapshot(updateFirstSeen: false)
            }

            guard !Task.isCancelled else { return }
            self.refreshTask = nil
            self.snapshot.installedPackageFirstSeenAtByID = previousFirstSeen
            self.snapshot.loadingManagers = []
            self.publishSnapshot()
            self.startFreshness(
                databaseTask: databaseTask,
                generatedAt: generatedAt,
                previousLastBrewUpdateAt: previousLastBrewUpdateAt,
                errorsByManager: errorsByManager,
                appScanMode: ignoringAppCache ? .freshIgnoringCache : .fresh
            )
        }
    }

    private func startFreshness(
        databaseTask: Task<PackageDatabase, Never>,
        generatedAt: Date,
        previousLastBrewUpdateAt: Date?,
        errorsByManager initialErrors: [PackageManagerKind: [String]],
        appScanMode: PackageScanMode
    ) {
        rescanTask?.cancel()
        rescanTask = Task { [weak self] in
            guard let self else { return }
            var errorsByManager = initialErrors
            let database = await databaseTask.value
            guard !Task.isCancelled else { return }

            let packages = self.snapshot.inventory?.packages ?? []
            let enriched = await Task.detached(priority: .utility) {
                let scanner = PackageScanner()
                return (
                    packages.map { package in
                        package.applying(metadata: database.metadata(for: package.manager, name: package.packageToken))
                    },
                    database.catalogPackages(homebrewPrefix: scanner.homebrewPrefix())
                )
            }.value
            guard !Task.isCancelled else { return }
            self.snapshot.inventory = PackageInventory(
                generatedAt: generatedAt,
                packages: enriched.0,
                errors: Self.scanErrors(errorsByManager)
            )
            self.snapshot.catalogPackages = enriched.1
            self.snapshot.loadingManagers?.insert(.macApp)
            self.publishSnapshot()

            let brewUpdateTask = Task.detached(priority: .background) { () -> (Date?, String?) in
                do {
                    try HomebrewMaintenance().update()
                    return (Date(), nil)
                } catch {
                    return (nil, error.localizedDescription)
                }
            }
            let scanner = PackageScanner()
            for await result in scanner.results(for: [.macApp], database: database, mode: appScanMode) {
                guard !Task.isCancelled else { return }
                self.applyScanResult(
                    result,
                    generatedAt: generatedAt,
                    errorsByManager: &errorsByManager,
                    preserveExistingOnError: true
                )
                self.snapshot.loadingManagers?.remove(result.manager)
                self.publishSnapshot()
            }
            for await result in scanner.results(for: [.npm, .npx, .uv], database: database, mode: .fresh) {
                guard !Task.isCancelled else { return }
                self.applyScanResult(
                    result,
                    generatedAt: generatedAt,
                    errorsByManager: &errorsByManager,
                    preserveExistingOnError: true
                )
                self.snapshot.loadingManagers?.remove(result.manager)
                self.publishSnapshot()
            }

            let (lastBrewUpdateAt, brewError) = await brewUpdateTask.value
            guard !Task.isCancelled else { return }
            errorsByManager[.homebrew] = [brewError].compactMap { $0 }
            for await result in scanner.results(for: [.homebrew], database: database, mode: .fresh) {
                guard !Task.isCancelled else { return }
                let result = PackageManagerScanResult(
                    manager: result.manager,
                    packages: result.packages,
                    errors: (errorsByManager[.homebrew] ?? []) + result.errors
                )
                self.applyScanResult(
                    result,
                    generatedAt: generatedAt,
                    errorsByManager: &errorsByManager,
                    preserveExistingOnError: true
                )
            }

            guard !Task.isCancelled else { return }
            self.rescanTask = nil
            self.snapshot.lastBrewUpdateAt = lastBrewUpdateAt ?? previousLastBrewUpdateAt
            self.snapshot.isRefreshing = false
            self.snapshot.errorMessage = Self.scanErrors(errorsByManager).first
            self.publishSnapshot()
        }
    }

    private func applyScanResult(
        _ result: PackageManagerScanResult,
        generatedAt: Date,
        errorsByManager: inout [PackageManagerKind: [String]],
        preserveExistingOnError: Bool = false
    ) {
        errorsByManager[result.manager] = result.errors
        let errors = Self.scanErrors(errorsByManager)
        if preserveExistingOnError, !result.errors.isEmpty {
            snapshot.inventory = PackageInventory(
                generatedAt: generatedAt,
                packages: snapshot.inventory?.packages ?? [],
                errors: errors
            )
        } else {
            snapshot = menuBarSnapshot(snapshot, merging: result, generatedAt: generatedAt, errors: errors)
        }
        snapshot.errorMessage = errors.first
    }

    private nonisolated static func scanErrors(_ errorsByManager: [PackageManagerKind: [String]]) -> [String] {
        PackageManagerKind.allCases.flatMap { errorsByManager[$0] ?? [] }
    }

    private func rescanAfterAction(errorMessage: String? = nil) {
        let lastBrewUpdateAt = snapshot.lastBrewUpdateAt
        let previousFirstSeen = snapshot.installedPackageFirstSeenAtByID
        rescanTask?.cancel()
        rescanTask = Task { [weak self] in
            let next = await Task.detached(priority: .background) {
                await Self.scanSnapshot(errorMessage: errorMessage, lastBrewUpdateAt: lastBrewUpdateAt)
            }.value

            guard let self, !Task.isCancelled else { return }
            self.rescanTask = nil
            let appUpdate = self.snapshot.appUpdate
            self.snapshot = next
            self.snapshot.installedPackageFirstSeenAtByID = previousFirstSeen
            self.snapshot.appUpdate = appUpdate
            self.publishSnapshot()
        }
    }

    private func runAction(kind: PackageHostActionKind, packageID: String) {
        guard refreshTask == nil, actionTask == nil,
              let package = menuBarCommandPackage(id: packageID, kind: kind, snapshot: snapshot) else { return }
        cancelBackgroundRefresh()
        let runID = UUID()
        snapshot.runningAction = PackageHostRunningAction(runID: runID, kind: kind, packageID: package.id, displayName: package.displayName)
        snapshot.errorMessage = nil
        publishSnapshot()
        let relay = actionProgressRelay(runID: runID, kind: kind, packageID: package.id)
        let progressHandler = actionProgressHandler(runID: runID, kind: kind, packageID: package.id, relay: relay)

        actionTask = Task { [weak self] in
            let result = await Task.detached(priority: .background) {
                Result {
                    switch kind {
                    case .install:
                        try PackageInstaller().install(package, onProgress: progressHandler)
                    case .update:
                        try PackageUpdater().update(package, onProgress: progressHandler)
                    case .uninstall:
                        try PackageUninstaller().uninstall(package, onProgress: progressHandler)
                    }
                }
            }.value

            guard let self, !Task.isCancelled else { return }
            self.finishActionProgress(relay, runID: runID, kind: kind, packageID: package.id)
            self.actionTask = nil
            self.snapshot.runningAction = nil
            switch result {
            case .success:
                self.snapshot = menuBarSnapshot(self.snapshot, applyingSuccessfulAction: kind, package: package)
                self.publishSnapshot()
                self.rescanAfterAction()
            case .failure(let error):
                self.snapshot.errorMessage = error.localizedDescription
                self.publishSnapshot()
                self.rescanAfterAction(errorMessage: error.localizedDescription)
            }
        }
    }

    private func loadSnapshot() {
        if var saved = try? store.load() {
            saved.isRefreshing = false
            if saved.loadingManagers == nil {
                saved.loadingManagers = []
            }
            saved.runningAction = nil
            snapshot = saved
        }
        publishSnapshot()
    }

    private func publishSnapshot(updateFirstSeen: Bool = true) {
        if updateFirstSeen {
            snapshot.updateInstalledPackageFirstSeenAtByID()
        }
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
        let scanner = PackageScanner()
        let inventory = await scanner.inventory(database: database)
        let errors = [errorMessage].compactMap { $0 } + inventory.errors
        return PackageHostSnapshot(
            inventory: PackageInventory(packages: inventory.packages, errors: errors),
            catalogPackages: database.catalogPackages(homebrewPrefix: scanner.homebrewPrefix()),
            isRefreshing: false,
            loadingManagers: [],
            runningAction: nil,
            errorMessage: errorMessage ?? inventory.errors.first,
            lastBrewUpdateAt: lastBrewUpdateAt
        )
    }

    private func observeCommands() {
        notificationCenter.addObserver(self, selector: #selector(refreshRequested(_:)), name: PackageHostNotifications.refreshRequested, object: nil)
        notificationCenter.addObserver(self, selector: #selector(installRequested(_:)), name: PackageHostNotifications.installRequested, object: nil)
        notificationCenter.addObserver(self, selector: #selector(installManyRequested(_:)), name: PackageHostNotifications.installManyRequested, object: nil)
        notificationCenter.addObserver(self, selector: #selector(updateRequested(_:)), name: PackageHostNotifications.updateRequested, object: nil)
        notificationCenter.addObserver(self, selector: #selector(updateAllRequested(_:)), name: PackageHostNotifications.updateAllRequested, object: nil)
        notificationCenter.addObserver(self, selector: #selector(uninstallRequested(_:)), name: PackageHostNotifications.uninstallRequested, object: nil)
        notificationCenter.addObserver(self, selector: #selector(appUpdateQuitRequested(_:)), name: PackageHostNotifications.appUpdateQuitRequested, object: nil)
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
                menu.addItem(packageItem(package))
            }
        }

        menu.addItem(.separator())
        let refreshItem = menu.addItem(withTitle: "Refresh Now", action: #selector(refreshNow(_:)), keyEquivalent: "")
        refreshItem.target = self
        refreshItem.isEnabled = !state.isRefreshing && snapshot.runningAction == nil

        let openItem = menu.addItem(withTitle: "Open Package Manager Manager", action: #selector(openMainWindow(_:)), keyEquivalent: "")
        openItem.target = self

        let loginItem = menu.addItem(withTitle: "Start at Login", action: #selector(toggleStartAtLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off

        menu.addItem(.separator())
        let quitItem = menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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

    private func runUpdateAll() {
        guard refreshTask == nil, actionTask == nil else { return }
        let packages = menuBarCommandUpdateAllPackages(snapshot: snapshot)
        guard !packages.isEmpty else { return }
        cancelBackgroundRefresh()
        snapshot.errorMessage = nil
        publishSnapshot()
        actionTask = Task { [weak self] in
            var errors: [String] = []
            for package in packages {
                guard let self, !Task.isCancelled else { return }
                let runID = UUID()
                self.snapshot.runningAction = PackageHostRunningAction(runID: runID, kind: .update, packageID: package.id, displayName: package.displayName)
                self.publishSnapshot()
                let relay = self.actionProgressRelay(runID: runID, kind: .update, packageID: package.id)
                let progressHandler = self.actionProgressHandler(runID: runID, kind: .update, packageID: package.id, relay: relay)

                let result = await Task.detached(priority: .background) {
                    Result {
                        try PackageUpdater().update(package, onProgress: progressHandler)
                    }
                }.value
                self.finishActionProgress(relay, runID: runID, kind: .update, packageID: package.id)
                if case .success = result {
                    self.snapshot = menuBarSnapshot(self.snapshot, applyingSuccessfulAction: .update, package: package)
                } else if case .failure(let error) = result {
                    errors.append(error.localizedDescription)
                }
            }

            guard let self, !Task.isCancelled else { return }
            let errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
            self.actionTask = nil
            self.snapshot.runningAction = nil
            self.snapshot.errorMessage = errorMessage
            self.publishSnapshot()
            self.rescanAfterAction(errorMessage: errorMessage)
        }
    }

    private func actionProgressRelay(runID: UUID, kind: PackageHostActionKind, packageID: String) -> MenuBarActionProgressRelay {
        MenuBarActionProgressRelay { [weak self] output in
            Task { @MainActor in self?.publishActionOutput(output, runID: runID, kind: kind, packageID: packageID) }
        }
    }

    private func actionProgressHandler(
        runID: UUID,
        kind: PackageHostActionKind,
        packageID: String,
        relay: MenuBarActionProgressRelay
    ) -> @Sendable (PackageCommandProgress) -> Void {
        { [weak self, relay] progress in
            switch progress {
        case .started(let command):
                relay.recordStarted(command: command)
                Task { @MainActor in
                    self?.applyActionStarted(command, runID: runID, kind: kind, packageID: packageID)
                }
        case .output(let text):
                relay.append(text)
            }
        }
    }

    private func applyActionStarted(_ command: String, runID: UUID, kind: PackageHostActionKind, packageID: String) {
        guard let action = currentAction(runID: runID, kind: kind, packageID: packageID) else { return }
        snapshot.runningAction = menuBarAction(action, applyingStartedCommand: command)
        publishSnapshot()
    }

    private func publishActionOutput(_ output: String, runID: UUID, kind: PackageHostActionKind, packageID: String) {
        guard var action = currentAction(runID: runID, kind: kind, packageID: packageID) else { return }
        action.output = output
        snapshot.runningAction = action
        PackageHostNotifications.postActionOutputChanged(
            runID: runID,
            kind: kind,
            packageID: packageID,
            output: output
        )
    }

    private func finishActionProgress(
        _ relay: MenuBarActionProgressRelay,
        runID: UUID,
        kind: PackageHostActionKind,
        packageID: String
    ) {
        let final = relay.finish()
        guard var action = currentAction(runID: runID, kind: kind, packageID: packageID) else { return }
        action.command = final.command ?? action.command
        action.output = final.output
        snapshot.runningAction = action
        PackageHostNotifications.postActionOutputChanged(
            runID: runID,
            kind: kind,
            packageID: packageID,
            output: final.output
        )
    }

    private func currentAction(runID: UUID, kind: PackageHostActionKind, packageID: String) -> PackageHostRunningAction? {
        guard let action = snapshot.runningAction,
              action.runID == runID,
              action.kind == kind,
              action.packageID == packageID else { return nil }
        return action
    }

    private func runInstallMany(packageIDs: [String]) {
        guard refreshTask == nil, actionTask == nil else { return }
        let packages = menuBarCommandInstallPackages(ids: packageIDs, snapshot: snapshot)
        guard !packages.isEmpty else { return }
        cancelBackgroundRefresh()
        snapshot.errorMessage = nil
        publishSnapshot()
        actionTask = Task { [weak self] in
            var errors: [String] = []
            for package in packages {
                guard let self, !Task.isCancelled else { return }
                let runID = UUID()
                self.snapshot.runningAction = PackageHostRunningAction(runID: runID, kind: .install, packageID: package.id, displayName: package.displayName)
                self.publishSnapshot()
                let relay = self.actionProgressRelay(runID: runID, kind: .install, packageID: package.id)
                let progressHandler = self.actionProgressHandler(runID: runID, kind: .install, packageID: package.id, relay: relay)

                let result = await Task.detached(priority: .background) {
                    Result {
                        try PackageInstaller().install(package, onProgress: progressHandler)
                    }
                }.value
                self.finishActionProgress(relay, runID: runID, kind: .install, packageID: package.id)
                if case .success = result {
                    self.snapshot = menuBarSnapshot(self.snapshot, applyingSuccessfulAction: .install, package: package)
                } else if case .failure(let error) = result {
                    errors.append(error.localizedDescription)
                }
            }

            guard let self, !Task.isCancelled else { return }
            let errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
            self.actionTask = nil
            self.snapshot.runningAction = nil
            self.snapshot.errorMessage = errorMessage
            self.publishSnapshot()
            self.rescanAfterAction(errorMessage: errorMessage)
        }
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func packageItem(_ package: MenuBarPackageRow) -> NSMenuItem {
        let title = "\(package.name) \(package.installedVersion) -> \(package.latestVersion)"
        let item = disabledItem(title)
        item.image = ecosystemImage(package.ecosystemIcon, accessibilityDescription: package.ecosystemTitle)
        item.toolTip = package.ecosystemTitle
        item.setAccessibilityLabel("\(package.ecosystemTitle): \(title)")
        return item
    }

    private func ecosystemImage(
        _ icon: MenuBarEcosystemIcon,
        accessibilityDescription: String
    ) -> NSImage? {
        let source: NSImage?
        switch icon {
        case .asset(let name, let fallbackSystemName):
            source = NSImage(named: name)
                ?? NSImage(systemSymbolName: fallbackSystemName, accessibilityDescription: accessibilityDescription)
        case .system(let name):
            source = NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription)
        }
        guard let image = source?.copy() as? NSImage else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 16, height: 16)
        return image
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

    private func cancelBackgroundRefresh() {
        rescanTask?.cancel()
        rescanTask = nil
        snapshot.isRefreshing = false
        snapshot.loadingManagers = []
    }

    @objc private func refreshNow(_ sender: Any?) {
        refresh(ignoringAppCache: true)
    }

    @objc private func refreshRequested(_ notification: Notification) {
        refresh(ignoringAppCache: true)
    }

    @objc private func installRequested(_ notification: Notification) {
        guard let packageID = PackageHostNotifications.packageID(from: notification) else { return }
        runAction(kind: .install, packageID: packageID)
    }

    @objc private func installManyRequested(_ notification: Notification) {
        runInstallMany(packageIDs: PackageHostNotifications.packageIDs(from: notification))
    }

    @objc private func updateRequested(_ notification: Notification) {
        guard let packageID = PackageHostNotifications.packageID(from: notification) else { return }
        runAction(kind: .update, packageID: packageID)
    }

    @objc private func updateAllRequested(_ notification: Notification) {
        runUpdateAll()
    }

    @objc private func uninstallRequested(_ notification: Notification) {
        guard let packageID = PackageHostNotifications.packageID(from: notification) else { return }
        runAction(kind: .uninstall, packageID: packageID)
    }

    @objc private func appUpdateQuitRequested(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    @objc private func openMainWindow(_ sender: Any?) {
        let mainApp = mainAppURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: mainApp, configuration: configuration)
    }

    private var mainAppURL: URL {
        Self.mainAppURL(containing: Bundle.main.bundleURL)
    }

    nonisolated static func mainAppURL(containing helperBundleURL: URL) -> URL {
        helperBundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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
