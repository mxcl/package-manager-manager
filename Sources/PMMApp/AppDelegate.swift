import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        showMainWindow()
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

        let controller = MainWindowController()
        let window = NSWindow(contentViewController: controller)
        window.title = "Package Manager Manager"
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = true
        window.delegate = self
        window.setContentSize(NSSize(width: 1380, height: 760))
        window.minSize = NSSize(width: 1060, height: 680)
        window.center()
        window.makeKeyAndOrderFront(nil)
        positionTrafficLights(in: window)
        DispatchQueue.main.async { self.positionTrafficLights(in: window) }
        self.window = window
        NSApp.activate()
    }

    private func positionTrafficLights(in window: NSWindow) {
        guard
            let close = window.standardWindowButton(.closeButton),
            let miniaturize = window.standardWindowButton(.miniaturizeButton),
            let zoom = window.standardWindowButton(.zoomButton),
            let superview = close.superview
        else { return }

        let y = max(superview.bounds.height - close.frame.height - 30, 0)
        close.setFrameOrigin(NSPoint(x: 30, y: y))
        miniaturize.setFrameOrigin(NSPoint(x: 50, y: y))
        zoom.setFrameOrigin(NSPoint(x: 70, y: y))
    }

    private func makeMainMenu() -> NSMenu {
        let menu = NSMenu(title: "Main Menu")
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Package Manager Manager")
        appMenu.addItem(withTitle: "About Package Manager Manager", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Package Manager Manager", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        return menu
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        DispatchQueue.main.async { self.positionTrafficLights(in: window) }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        positionTrafficLights(in: window)
    }
}
