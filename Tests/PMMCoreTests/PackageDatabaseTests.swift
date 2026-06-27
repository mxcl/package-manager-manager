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
              "homepage": "https://git-scm.com/"
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
    #expect(db.metadata(for: .npm, name: "typescript")?.version == "5.9.2")
}

@Test func exposesCatalogPackagesFromDatabaseMetadata() {
    let db = PackageDatabase(
        formulas: [
            "git": PackageMetadata(summary: "Distributed revision control", category: "developer-tools", homepage: nil, version: "2.50.0")
        ],
        npms: [
            "typescript": PackageMetadata(summary: "Typed JavaScript", category: "language-runtime", homepage: nil, version: "5.9.2")
        ]
    )

    #expect(db.catalogPackages.map(\.name) == ["git", "typescript"])
    #expect(db.catalogPackages.map(\.installedVersion) == [nil, nil])
    #expect(Set(db.catalogPackages.compactMap(\.category)) == ["developer-tools", "language-runtime"])
}
