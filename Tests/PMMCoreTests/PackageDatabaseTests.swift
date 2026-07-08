import Foundation
import Testing
@testable import PMMCore

@Test func decodesAutomicVaultDatabaseShape() throws {
    let data = """
    {
      "sources": {
        "db": {
          "formulas": {
            "git": {
              "summary": "Distributed revision control system",
              "category": "developer-tools",
              "homepage": "https://git-scm.com/",
              "docs": ["https://git-scm.com/docs", "https://git-scm.com/book"],
              "repository": "https://github.com/git/git",
              "version": "2.50.0",
              "last_updated_at": "2026-06-26T22:01:54Z",
              "pulse_kind": "updated"
            }
          },
          "casks": {},
          "npms": {
            "typescript": {
              "summary": "TypeScript is a language for application scale JavaScript development",
              "version": "5.9.2"
            }
          }
        }
      }
    }
    """.data(using: .utf8)!

    let db = try PackageDatabase.decode(data)
    #expect(db.metadata(for: .homebrew, name: "git")?.category == "developer-tools")
    #expect(db.metadata(for: .homebrew, name: "git")?.summary == "Distributed revision control system")
    #expect(db.metadata(for: .homebrew, name: "git")?.homepage == "https://git-scm.com/")
    #expect(db.metadata(for: .homebrew, name: "git")?.docs == "https://git-scm.com/docs")
    #expect(db.metadata(for: .homebrew, name: "git")?.repo == "https://github.com/git/git")
    #expect(db.metadata(for: .homebrew, name: "git")?.version == "2.50.0")
    #expect(db.metadata(for: .homebrew, name: "git")?.lastUpdatedAt == "2026-06-26T22:01:54Z")
    #expect(db.metadata(for: .homebrew, name: "git")?.pulseKind == "updated")
    #expect(db.metadata(for: .npm, name: "typescript")?.summary == "TypeScript is a language for application scale JavaScript development")
    #expect(db.metadata(for: .npm, name: "typescript")?.version == "5.9.2")
}

@Test func exposesCatalogPackagesFromDatabaseMetadata() {
    let db = PackageDatabase(
        formulas: [
            "git": PackageMetadata(summary: "Distributed revision control", category: "developer-tools", homepage: nil, version: "2.50.0")
        ],
        casks: [
            "git": PackageMetadata(summary: nil, category: "productivity", homepage: nil, version: nil)
        ],
        npms: [
            "typescript": PackageMetadata(summary: "Typed JavaScript", category: "language-runtime", homepage: nil, version: "5.9.2")
        ]
    )

    #expect(db.catalogPackages.map(\.identifier) == ["brew:cask:git", "brew:git", "npm:typescript"])
    #expect(db.catalogPackages.map(\.displayName) == ["git", "git", "typescript"])
    #expect(db.catalogPackages.map(\.installedVersion) == [nil, nil, nil])
    #expect(db.catalogPackages.map(\.latestVersion) == [nil, "2.50.0", "5.9.2"])
    #expect(db.catalogPackages.map(\.summary) == [nil, "Distributed revision control", "Typed JavaScript"])
    #expect(Set(db.catalogPackages.compactMap(\.category)) == ["developer-tools", "language-runtime", "productivity"])
}

@Test func catalogPackagesCanIncludeKnownHomebrewInstallLocations() {
    let db = PackageDatabase(
        formulas: ["git": PackageMetadata(summary: nil, category: nil, homepage: nil, version: "2.50.0")],
        casks: ["visual-studio-code": PackageMetadata(summary: nil, category: nil, homepage: nil, version: "1.101.2")]
    )

    let packages = db.catalogPackages(homebrewPrefix: "/opt/homebrew")

    #expect(packages.first { $0.identifier == "brew:git" }?.installLocation == "/opt/homebrew/opt/git")
    #expect(packages.first { $0.identifier == "brew:cask:visual-studio-code" }?.installLocation == "/opt/homebrew/Caskroom/visual-studio-code/1.101.2")
}

@Test func loadsCachedDatabaseResponse() throws {
    let url = URL(string: "https://example.com/db.json")!
    let data = """
    {
      "sources": {
        "db": {
          "formulas": {
            "git": { "summary": "Distributed revision control system" }
          }
        }
      }
    }
    """.data(using: .utf8)!
    let cache = URLCache(memoryCapacity: 1_000_000, diskCapacity: 0, diskPath: nil)
    let response = URLResponse(url: url, mimeType: "application/json", expectedContentLength: data.count, textEncodingName: nil)
    cache.storeCachedResponse(CachedURLResponse(response: response, data: data), for: URLRequest(url: url))

    let db = try #require(PackageDatabase.cached(from: url, cache: cache))
    #expect(db.metadata(for: .homebrew, name: "git")?.summary == "Distributed revision control system")
}
