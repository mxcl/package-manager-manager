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
          "casks": {
            "example-editor": {
              "summary": "Example editor",
              "category": "developer-tools",
              "applications": ["Example Editor.app"]
            },
            "font-hack": {
              "applications": []
            }
          },
          "crates": {
            "ripgrep": {
              "summary": "Line-oriented search tool",
              "category": "developer-tools",
              "version": "14.1.1"
            }
          },
          "npms": {
            "typescript": {
              "summary": "TypeScript is a language for application scale JavaScript development",
              "version": "5.9.2"
            }
          },
          "apps": {
            "com.example.Editor": {
              "cask": "example-editor",
              "feed_url": "https://example.com/appcast.xml",
              "channel": "beta",
              "advisory_url": "https://example.com/download"
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
    #expect(db.metadata(for: .cargoInstall, name: "ripgrep")?.summary == "Line-oriented search tool")
    #expect(db.metadata(for: .cargoInstall, name: "ripgrep")?.version == "14.1.1")
    #expect(db.metadata(for: .npm, name: "typescript")?.summary == "TypeScript is a language for application scale JavaScript development")
    #expect(db.metadata(for: .npm, name: "typescript")?.version == "5.9.2")
    #expect(db.catalogPackages.first { $0.identifier == "brew:cask:example-editor" }?.appProvenance == .homebrew)
    #expect(db.catalogPackages.first { $0.identifier == "brew:cask:font-hack" }?.appProvenance == nil)
    let app = try #require(db.app(for: "com.example.Editor"))
    #expect(app.cask == "example-editor")
    #expect(app.feedURL == "https://example.com/appcast.xml")
    #expect(app.channel == "beta")
    #expect(app.advisoryURL == "https://example.com/download")
}

@Test func appCatalogUsesCaskMetadataAsFallback() throws {
    let db = PackageDatabase(
        casks: [
            "fork": PackageMetadata(
                summary: "Fast Git client",
                category: "developer-tools",
                homepage: "https://git-fork.com",
                version: "2.70"
            )
        ],
        apps: [
            "com.DanPristupov.Fork": MacAppCatalogEntry(
                bundleIdentifier: "com.DanPristupov.Fork",
                cask: "fork",
                versionSource: .homebrewCask
            )
        ]
    )

    let app = try #require(db.app(for: "com.DanPristupov.Fork"))
    #expect(app.summary == "Fast Git client")
    #expect(app.category == "developer-tools")
    #expect(app.homepage == "https://git-fork.com")
    #expect(app.version == "2.70")
    #expect(app.versionSource == .homebrewCask)
}

@Test func exposesCatalogPackagesFromDatabaseMetadata() {
    let db = PackageDatabase(
        formulas: [
            "git": PackageMetadata(summary: "Distributed revision control", category: "developer-tools", homepage: nil, version: "2.50.0")
        ],
        casks: [
            "git": PackageMetadata(displayName: "Git GUI", summary: nil, category: "productivity", homepage: nil, version: nil)
        ],
        crates: [
            "ripgrep": PackageMetadata(summary: "Search tool", category: "developer-tools", homepage: nil, version: "14.1.1")
        ],
        npms: [
            "typescript": PackageMetadata(summary: "Typed JavaScript", category: "language-runtime", homepage: nil, version: "5.9.2")
        ]
    )

    #expect(db.catalogPackages.map(\.identifier) == ["cargo:ripgrep", "brew:git", "brew:cask:git", "npm:typescript"])
    #expect(db.catalogPackages.map(\.displayName) == ["ripgrep", "git", "Git GUI", "typescript"])
    #expect(db.catalogPackages.map(\.installedVersion) == [nil, nil, nil, nil])
    #expect(db.catalogPackages.map(\.latestVersion) == ["14.1.1", "2.50.0", nil, "5.9.2"])
    #expect(db.catalogPackages.map(\.summary) == ["Search tool", "Distributed revision control", nil, "Typed JavaScript"])
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

@Test func loadsBundledDatabaseFile() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    try """
    {
      "sources": {
        "db": {
          "formulas": {
            "git": { "summary": "Bundled metadata" }
          }
        }
      }
    }
    """.write(to: url, atomically: true, encoding: .utf8)

    let db = try #require(PackageDatabase.bundled(at: url))
    #expect(db.metadata(for: .homebrew, name: "git")?.summary == "Bundled metadata")
    #expect(PackageDatabase.bundled(at: nil) == nil)
}
