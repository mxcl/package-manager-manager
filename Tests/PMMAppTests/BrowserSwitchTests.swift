import AppKit
import PMMCore
import SwiftUI
import Testing
import WebKit
@testable import PMMApp

@MainActor
@Test func switchingPackagesReplacesTheEmbeddedWebView() throws {
    let first = ManagedPackage(manager: .macApp, identifier: "mac-app:first", installedVersion: "1", latestVersion: nil,
        homepage: "http://127.0.0.1:9/first")
    let second = ManagedPackage(manager: .macApp, identifier: "mac-app:second", installedVersion: "1", latestVersion: nil,
        advisoryURL: "http://127.0.0.1:9/update.dmg")
    let model = MainWindowModel(userDefaults: UserDefaults(suiteName: UUID().uuidString)!, usesPackageHostNotifications: false)
    model.apply(snapshot: PackageHostSnapshot(inventory: PackageInventory(packages: [first, second])))
    model.selectSection(.installed)
    model.select(first)

    let view = NSHostingView(rootView: MainWindowLinksView(model: model))
    view.frame = NSRect(x: 0, y: 0, width: 500, height: 500)
    view.layoutSubtreeIfNeeded()
    let original = try #require(webView(in: view))

    model.select(second)
    view.layoutSubtreeIfNeeded()
    let current = try #require(webView(in: view))
    #expect(current !== original)
}

private func webView(in view: NSView) -> WKWebView? {
    if let webView = view as? WKWebView { return webView }
    return view.subviews.lazy.compactMap(webView(in:)).first
}
