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

@Test func packageWebViewNavigationPolicyAllowsEmbeddedInitialLoadAndSubframes() {
    // Initial page load in the main frame is permitted
    #expect(packageWebViewNavigationPolicy(allowsEmbeddedNavigation: true, targetFrameIsMainFrame: true) == .allow)

    // Ordinary subframe (iframe) loading and navigation is always permitted
    #expect(packageWebViewNavigationPolicy(allowsEmbeddedNavigation: false, targetFrameIsMainFrame: false) == .allow)
    #expect(packageWebViewNavigationPolicy(allowsEmbeddedNavigation: true, targetFrameIsMainFrame: false) == .allow)
    #expect(packageWebViewNavigationPolicy(navigationType: .other, allowsEmbeddedNavigation: false, targetFrameIsMainFrame: false) == .allow)
    #expect(packageWebViewNavigationPolicy(navigationType: .linkActivated, allowsEmbeddedNavigation: false, targetFrameIsMainFrame: false) == .allow)
}

@Test func packageWebViewNavigationPolicyBlocksNilTargetPopupsEvenForProgrammaticClicks() {
    // WKNavigationType.linkActivated can be synthesized via JS `anchor.click()`.
    // Nil-target popup creations must always be cancelled regardless of navigationType.
    #expect(packageWebViewNavigationPolicy(navigationType: .linkActivated, allowsEmbeddedNavigation: true, targetFrameIsMainFrame: nil) == .cancel)
    #expect(packageWebViewNavigationPolicy(navigationType: .linkActivated, allowsEmbeddedNavigation: false, targetFrameIsMainFrame: nil) == .cancel)
    #expect(packageWebViewNavigationPolicy(navigationType: .other, allowsEmbeddedNavigation: true, targetFrameIsMainFrame: nil) == .cancel)
    #expect(packageWebViewNavigationPolicy(navigationType: .other, allowsEmbeddedNavigation: false, targetFrameIsMainFrame: nil) == .cancel)
}

@Test func packageWebViewNavigationPolicyBlocksPostLoadMainFrameNavigationEvenForProgrammaticClicks() {
    // Post-load navigations in the main frame are cancelled, including programmatic anchor.click()
    #expect(packageWebViewNavigationPolicy(navigationType: .linkActivated, allowsEmbeddedNavigation: false, targetFrameIsMainFrame: true) == .cancel)
    #expect(packageWebViewNavigationPolicy(navigationType: .other, allowsEmbeddedNavigation: false, targetFrameIsMainFrame: true) == .cancel)
}
