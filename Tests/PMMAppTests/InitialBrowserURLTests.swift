import Foundation
import Testing
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
