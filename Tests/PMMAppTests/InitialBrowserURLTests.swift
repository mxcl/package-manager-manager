import Foundation
import Testing
import WebKit
@testable import PMMApp

@Test func initialBrowserURLAddsReadmeToGitHubRepoRoots() throws {
    let url = URL(string: "https://github.com/foo/bar")!
    #expect(initialBrowserURL(for: url).absoluteString == "https://github.com/foo/bar#readme")
}

@Test func initialBrowserURLLeavesExistingReadmeFragmentsAlone() throws {
    let url = URL(string: "https://github.com/foo/bar#readme")!
    #expect(initialBrowserURL(for: url) == url)
}

@Test func initialBrowserURLLeavesGitHubNavigationURLsAlone() throws {
    let url = URL(string: "https://github.com/foo/bar/issues")!
    #expect(initialBrowserURL(for: url) == url)
}

@Test func browserNavigationPolicyOpensOnlyPostLoadMainFrameNavigationExternally() {
    #expect(!shouldOpenNavigationInSystemBrowser(allowsEmbeddedNavigation: true, targetFrameIsMainFrame: true))
    #expect(!shouldOpenNavigationInSystemBrowser(allowsEmbeddedNavigation: false, targetFrameIsMainFrame: false))
    #expect(shouldOpenNavigationInSystemBrowser(allowsEmbeddedNavigation: false, targetFrameIsMainFrame: true))
    #expect(shouldOpenNavigationInSystemBrowser(allowsEmbeddedNavigation: true, targetFrameIsMainFrame: nil))
    #expect(shouldOpenNavigationInSystemBrowser(allowsEmbeddedNavigation: false, targetFrameIsMainFrame: nil))

    // Automated script redirects or popups must never open in system browser
    #expect(!shouldOpenNavigationInSystemBrowser(navigationType: .other, allowsEmbeddedNavigation: true, targetFrameIsMainFrame: nil))
    #expect(!shouldOpenNavigationInSystemBrowser(navigationType: .other, allowsEmbeddedNavigation: false, targetFrameIsMainFrame: nil))
    #expect(!shouldOpenNavigationInSystemBrowser(navigationType: .other, allowsEmbeddedNavigation: false, targetFrameIsMainFrame: true))
}
