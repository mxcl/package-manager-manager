import AppKit
import SwiftUI
import Testing
@testable import PMMApp

@Test(arguments: [640, 856, 1070, 1400]) @MainActor
func dashboardBlogCardsFillAvailableWidth(width: Int) throws {
    let view = DashboardBlogAndPackageSection(
        posts: ["pnpm, Bun, pipx, Go, and pkgx Join the Inventory", "Manage Macs and Linux Hosts", "Introducing Install Packs"].enumerated().map { index, title in
            DashboardBlogEntry(slug: "post-\(index)", title: title, subtitle: "Five more tools, with local installs and remote updates", category: .blog, systemImage: "shippingbox", publishedAt: "Sep 5, 2026", url: URL(string: "https://example.invalid/post-\(index)")!)
        },
        package: DiscoverFeedPackage(id: "npm:react-email", displayName: "react-email", agentSummary: "A live preview of your emails right in your browser.", manager: "npm", category: "productivity", homepage: nil, installURL: nil), isLoading: false,
        isPackageInstalled: { _ in false }, openPackage: { _ in }, installPackage: { _ in }
    )
    .frame(width: CGFloat(width))
    .environment(\.colorScheme, .light)
    let renderer = ImageRenderer(content: view)
    let image = try #require(renderer.cgImage)
    if width < 856 {
        #expect(image.height > 500, "Narrow windows must stack the package below the blog cards")
        return
    }
    #expect(image.height < 350, "The package card must stay beside the blog cards at desktop width")
    let bitmap = NSBitmapImageRep(cgImage: image)
    // This point is inside the third expanded card, but in the unused column of the broken grid.
    let color = try #require(bitmap.colorAt(x: width - 290, y: 150))
    #expect(color.alphaComponent > 0, "Blog cards must fill the space before the package card")
}
