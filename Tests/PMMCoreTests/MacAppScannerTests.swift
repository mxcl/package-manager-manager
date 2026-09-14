import Foundation
import Testing
@testable import PMMCore

private struct MacAppFakeRunner: CommandRunning {
    let responses: [String: CommandResult]

    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        responses[([executable] + arguments).joined(separator: " ")]
            ?? CommandResult(stdout: "", stderr: "", status: 0)
    }
}

private final class MacAppURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responseData = Data()
    nonisolated(unsafe) private static var responseStatus = 200
    nonisolated(unsafe) private static var requestCount = 0

    static func configure(data: Data, status: Int = 200) {
        lock.lock()
        responseData = data
        responseStatus = status
        requestCount = 0
        lock.unlock()
    }

    static var requests: Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCount
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requestCount += 1
        let data = Self.responseData
        let status = Self.responseStatus
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Length": String(data.count)]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("macOS app scanning", .serialized)
struct MacAppScannerTests {
    @Test func discoversUserControlledAppsAndDeduplicatesCasks() async throws {
        let fixture = try MacAppFixture()
        defer { fixture.remove() }
        let direct = try fixture.app("Direct.app", id: "com.example.Direct", shortVersion: "1.2.0", build: "120")
        _ = try fixture.app("Safari.app", id: "com.apple.Safari", shortVersion: "26.0", build: "1")
        let cask = try fixture.app("Cask.app", id: "com.example.Cask", shortVersion: "3.0", build: "300")
        let store = try fixture.app("Store.app", id: "com.example.Store", shortVersion: "4.0", build: "400", receipt: true)
        let setapp = try fixture.app("Setapp/Member.app", id: "com.example.Setapp", shortVersion: "5.0", build: "500")
        let brewJSON = """
        {"casks":[{"token":"cask","artifacts":[{"app":["Cask.app"],"target":"\(cask.path)"}]}]}
        """
        let scanner = fixture.scanner(runner: MacAppFakeRunner(responses: [
            "/fake/brew info --json=v2 --installed": CommandResult(stdout: brewJSON, stderr: "", status: 0)
        ]), toolPaths: ["brew": "/fake/brew"])

        let packages = try await fixture.packages(scanner: scanner, mode: .local)

        #expect(Set(packages.compactMap(\.bundleIdentifier)) == ["com.example.Direct", "com.example.Store", "com.example.Setapp"])
        #expect(packages.first { $0.installLocation == direct.path }?.appProvenance == .direct)
        #expect(packages.first { $0.installLocation == store.path }?.appProvenance == .appStore)
        #expect(packages.first { $0.installLocation == setapp.path }?.appProvenance == .setapp)
        #expect(packages.allSatisfy { $0.manager == .macApp })
        #expect(packages.first { $0.bundleIdentifier == "com.example.Direct" }?.bundleVersion == "120")
    }

    @Test func rescanningReadsAnUpdatedAppVersion() async throws {
        let fixture = try MacAppFixture()
        defer { fixture.remove() }
        _ = try fixture.app("ScreenTune.app", id: "com.example.ScreenTune", shortVersion: "1.2.3", build: "123")
        let scanner = fixture.scanner()

        #expect(try await fixture.packages(scanner: scanner, mode: .local).first?.installedVersion == "1.2.3")

        _ = try fixture.app("ScreenTune.app", id: "com.example.ScreenTune", shortVersion: "2.0.2", build: "202")

        #expect(try await fixture.packages(scanner: scanner, mode: .local).first?.installedVersion == "2.0.2")
    }

    @Test func associatesDirectAppsWithTheirCatalogCask() async throws {
        let fixture = try MacAppFixture()
        defer { fixture.remove() }
        _ = try fixture.app("VLC.app", id: "org.videolan.vlc", shortVersion: "3.0", build: "300")
        let database = PackageDatabase(
            casks: ["vlc": PackageMetadata(summary: "Multimedia player", category: "media", homepage: nil, version: "3.1")],
            apps: ["org.videolan.vlc": MacAppCatalogEntry(bundleIdentifier: "org.videolan.vlc", cask: "vlc")]
        )

        let package = try #require(try await fixture.packages(scanner: fixture.scanner(), mode: .local, database: database).first)

        #expect(package.identifier == "mac-app:org.videolan.vlc")
        #expect(package.catalogIdentifier == "brew:cask:vlc")
        #expect(package.summary == "Multimedia player")
    }

    @Test func caskVersionsKeepMetadataAndCompareOnlyComparableAppVersions() async throws {
        let fixture = try MacAppFixture()
        defer { fixture.remove() }
        _ = try fixture.app("Docker.app", id: "com.docker.docker", shortVersion: "4.86.0", build: "236216")
        _ = try fixture.app("Unknown.app", id: "com.example.Unknown", shortVersion: "1.0", build: "100")
        let database = PackageDatabase(apps: [
            "com.docker.docker": MacAppCatalogEntry(bundleIdentifier: "com.docker.docker", cask: "docker-desktop",
                versionSource: .homebrewCask, advisoryURL: "https://example.com/docker", version: "4.91.0,239619"),
            "com.example.Unknown": MacAppCatalogEntry(bundleIdentifier: "com.example.Unknown", cask: "unknown",
                versionSource: .homebrewCask, version: "latest"),
        ])

        var scanner = MacAppScanner(
            runner: MacAppFakeRunner(responses: [:]),
            fileManager: .default,
            applicationDirectories: [fixture.applications],
            brew: nil,
            mdls: "/usr/bin/mdls",
            session: .shared,
            cacheURL: fixture.cache,
            now: { Date() },
            storefrontCountry: "US"
        )
        scanner.nativeManager = NativeCaskManager(
            directory: fixture.directory,
            preferences: PackagePreferencesStore(url: fixture.directory.appendingPathComponent("preferences.json")),
            applicationDirectories: [fixture.applications]
        )
        let packages = try await scanner.scan(database: database, mode: .fresh)
        let docker = try #require(packages.first { $0.bundleIdentifier == "com.docker.docker" })
        #expect(docker.latestVersion == "4.91.0")
        #expect(docker.versionSource == .homebrewCask)
        #expect(docker.advisoryURL == "https://example.com/docker")
        let unknown = try #require(packages.first { $0.bundleIdentifier == "com.example.Unknown" })
        #expect(unknown.latestVersion == nil)
        #expect(unknown.versionSource == .homebrewCask)
        #expect(unknown.versionCheckedAt != nil)
    }

    @Test func sparkleUsesBundleBuildForAdvisoryAndCachesTheCheck() async throws {
        let fixture = try MacAppFixture()
        defer { fixture.remove() }
        _ = try fixture.app(
            "Editor.app",
            id: "com.example.Editor",
            shortVersion: "1.0",
            build: "100",
            feedURL: "https://updates.example.com/appcast.xml"
        )
        MacAppURLProtocol.configure(data: Data("""
        <?xml version="1.0"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
          <item>
            <sparkle:version>200</sparkle:version>
            <sparkle:shortVersionString>2.0</sparkle:shortVersionString>
            <enclosure url="https://example.com/app.zip"/>
            <sparkle:deltas><enclosure url="https://example.com/delta.zip" sparkle:deltaFrom="100"/></sparkle:deltas>
            <sparkle:releaseNotesLink>https://example.com/releases/2</sparkle:releaseNotesLink>
          </item>
        </channel></rss>
        """.utf8))
        let scanner = fixture.scanner(session: testSession())

        let first = try #require(try await fixture.packages(scanner: scanner, mode: .fresh).first)
        #expect(first.latestVersion == "2.0")
        #expect(first.isOutdated)
        #expect(first.versionSource == .sparkle)
        #expect(first.advisoryURL == "https://example.com/releases/2")
        #expect(first.updateDownloadURL == "https://example.com/app.zip")
        #expect(PackageActions.canUpdate(first, nativeEnabled: false))
        #expect(try JSONDecoder().decode(ManagedPackage.self, from: JSONEncoder().encode(first)) == first)
        #expect(MacAppURLProtocol.requests == 1)

        _ = try await fixture.packages(scanner: scanner, mode: .fresh)
        #expect(MacAppURLProtocol.requests == 1)

        _ = try await fixture.packages(scanner: scanner, mode: .freshIgnoringCache)
        #expect(MacAppURLProtocol.requests == 2)
    }

    @Test func appStoreUsesAdamIDAndStoreVersion() async throws {
        let fixture = try MacAppFixture()
        defer { fixture.remove() }
        let app = try fixture.app("Store.app", id: "com.example.Store", shortVersion: "1.0", build: "10", receipt: true)
        MacAppURLProtocol.configure(data: Data("""
        {"resultCount":1,"results":[{"version":"1.2","trackViewUrl":"https://apps.apple.com/app/id123","description":"A useful Mac app."}]}
        """.utf8))
        let mdls = "/fake/mdls -raw -name kMDItemAppStoreAdamID \(app.path)"
        let scanner = fixture.scanner(
            runner: MacAppFakeRunner(responses: [
                mdls: CommandResult(stdout: "123\n", stderr: "", status: 0)
            ]),
            toolPaths: ["mdls": "/fake/mdls"],
            session: testSession()
        )

        let package = try #require(try await fixture.packages(scanner: scanner, mode: .fresh).first)
        #expect(package.latestVersion == "1.2")
        #expect(package.versionSource == .appStore)
        #expect(package.advisoryURL == "https://apps.apple.com/app/id123")
        #expect(package.summary == "A useful Mac app.")

        let cached = try #require(try await fixture.packages(scanner: scanner, mode: .fresh).first)
        #expect(cached.summary == "A useful Mac app.")
        #expect(MacAppURLProtocol.requests == 1)
    }

    @Test(arguments: [
        ("1.2", "1.2.0", ComparisonResult.orderedSame),
        ("99", "100", .orderedAscending),
        ("2.0", "1.9.9", .orderedDescending),
        ("1.0-beta", "1.0", nil),
        ("latest", "2.0", nil),
    ])
    func comparesOnlyUnambiguousNumericVersions(
        installed: String,
        remote: String,
        expected: ComparisonResult?
    ) {
        #expect(numericVersionComparison(installed, remote) == expected)
    }

    @Test func missingInstalledVersionIsNeverOutdated() {
        #expect(numericVersionComparison(nil, "2.0") == nil)
    }

    @Test func parsesSparkleElementsAndEnclosureAttributes() {
        let parser = SparkleAppcastParser()
        #expect(parser.parse(Data("""
        <rss xmlns:sparkle="https://sparkle-project.org/xml-namespaces/sparkle"><channel>
          <item><enclosure url="https://example.com/app.zip" sparkle:version="42" sparkle:shortVersionString="4.2" /></item>
        </channel></rss>
        """.utf8)))
        #expect(parser.items == [SparkleAppcastItem(version: "42", shortVersion: "4.2", channel: nil, infoURL: "https://example.com/app.zip", downloadURL: "https://example.com/app.zip")])
    }

    @Test func parsesSparkleEnclosuresWithVersionInSiblingElements() {
        let parser = SparkleAppcastParser()
        #expect(parser.parse(Data("""
        <rss xmlns:sparkle="https://sparkle-project.org/xml-namespaces/sparkle"><channel>
          <item><enclosure url="https://example.com/app.zip"/><sparkle:version>42</sparkle:version></item>
        </channel></rss>
        """.utf8)))
        #expect(parser.items == [SparkleAppcastItem(version: "42", shortVersion: nil, channel: nil, infoURL: "https://example.com/app.zip", downloadURL: "https://example.com/app.zip")])
    }

    private func testSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MacAppURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private struct MacAppFixture {
    let directory: URL
    let applications: URL
    let cache: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        applications = directory.appendingPathComponent("Applications", isDirectory: true)
        cache = directory.appendingPathComponent("cache.json")
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
    }

    func app(
        _ relativePath: String,
        id: String,
        shortVersion: String,
        build: String,
        feedURL: String? = nil,
        receipt: Bool = false
    ) throws -> URL {
        let app = applications.appendingPathComponent(relativePath, isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: Any] = [
            "CFBundleIdentifier": id,
            "CFBundleName": app.deletingPathExtension().lastPathComponent,
            "CFBundleShortVersionString": shortVersion,
            "CFBundleVersion": build,
            "CFBundlePackageType": "APPL",
        ]
        info["SUFeedURL"] = feedURL
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        if receipt {
            let receiptDirectory = contents.appendingPathComponent("_MASReceipt", isDirectory: true)
            try FileManager.default.createDirectory(at: receiptDirectory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: receiptDirectory.appendingPathComponent("receipt").path, contents: Data("receipt".utf8))
        }
        return app
    }

    func scanner(
        runner: CommandRunning = MacAppFakeRunner(responses: [:]),
        toolPaths: [String: String] = [:],
        session: URLSession = .shared
    ) -> PackageScanner {
        PackageScanner(
            runner: runner,
            homeDirectory: directory,
            toolPaths: toolPaths,
            environment: [:],
            applicationDirectories: [applications],
            urlSession: session,
            appVersionCacheURL: cache
        )
    }

    func packages(scanner: PackageScanner, mode: PackageScanMode, database: PackageDatabase = PackageDatabase()) async throws -> [ManagedPackage] {
        for await result in scanner.results(for: [.macApp], database: database, mode: mode) {
            if let error = result.errors.first { throw FixtureError(message: error) }
            return result.packages
        }
        return []
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct FixtureError: Error {
    let message: String
}
