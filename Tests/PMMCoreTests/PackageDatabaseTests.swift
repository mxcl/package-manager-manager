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
