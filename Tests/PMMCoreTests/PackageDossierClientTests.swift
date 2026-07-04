import Foundation
import Testing
@testable import PMMCore

@Test func packageDossierURLUsesAutomicVaultProviderPath() {
    let brew = ManagedPackage(manager: .homebrew, identifier: "brew:caddy", installedVersion: nil, latestVersion: nil)
    let npm = ManagedPackage(manager: .npm, identifier: "npm:semver", installedVersion: nil, latestVersion: nil)
    let scoped = ManagedPackage(manager: .npm, identifier: "npm:@scope/tool", installedVersion: nil, latestVersion: nil)

    #expect(PackageDossierClient.url(for: brew)?.absoluteString == "https://automicvault.com/pkg/brew/caddy.json")
    #expect(PackageDossierClient.url(for: npm)?.absoluteString == "https://automicvault.com/pkg/npm/semver.json")
    #expect(PackageDossierClient.url(for: scoped)?.absoluteString == "https://automicvault.com/pkg/npm/@scope%2Ftool.json")
}

@Test func decodesPackageDossierPageSubset() throws {
    let data = Data("""
    {
      "category": "networking",
      "data": {
        "displayName": "caddy",
        "summary": "Web server",
        "version": "2.11.4",
        "license": "Apache-2.0",
        "homepage": "https://caddyserver.com/",
        "repository": "https://github.com/caddyserver/caddy",
        "upstreamDocs": "https://caddyserver.com/docs/",
        "executablesDetailed": [{ "name": "caddy", "kind": "cli" }],
        "dependencies": ["go"],
        "buildDependencies": ["make"],
        "configFileLocations": { "unix": "Caddyfile" },
        "credentialsFileLocations": { "macos": "~/Library/Application Support/Caddy" },
        "alsoAvailableVia": [{ "provider": "npm", "name": "caddy", "label": "caddy" }],
        "externalPackageManagerMatches": [{ "displayName": "Nix", "command": "nix profile install nixpkgs#caddy", "platform": "linux" }],
        "extra": {
          "registryInsights": {
            "sourceDatabase": "npm registry",
            "publisher": "GitHub Actions",
            "latestPublishedAt": "2026-06-09T23:50:03.612Z",
            "versionCount": 118,
            "maintainers": ["saquibkhan"]
          }
        }
      }
    }
    """.utf8)

    let dossier = try JSONDecoder().decode(PackageDossierPage.self, from: data)

    #expect(dossier.displayName == "caddy")
    #expect(dossier.category == "networking")
    #expect(dossier.version == "2.11.4")
    #expect(dossier.license == "Apache-2.0")
    #expect(dossier.executables == ["caddy"])
    #expect(dossier.configFileLocations["unix"] == "Caddyfile")
    #expect(dossier.alsoAvailableVia.first?.provider == "npm")
    #expect(dossier.externalPackageManagerMatches.first?.command == "nix profile install nixpkgs#caddy")
    #expect(dossier.registryInsights?.versionCount == 118)
}
