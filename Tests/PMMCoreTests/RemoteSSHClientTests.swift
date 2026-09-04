import Foundation
import Testing
@testable import PMMCore

@Test func remoteHostValidatesAndNormalizesConfiguration() throws {
    let host = try RemoteHost(name: "  Build Mac  ", destination: "  max@mac-mini  ")
    #expect(host.name == "Build Mac")
    #expect(host.destination == "max@mac-mini")
    #expect(host.displayName == "Build Mac")
    #expect(try RemoteHost(destination: "pangolin.local").displayName == "Pangolin")
    #expect(try RemoteHost(destination: "max@pangolin.local").displayName == "Max@pangolin")
    #expect(throws: RemoteHostError.invalidDestination) { try RemoteHost(destination: "-oProxyCommand=bad") }
    #expect(throws: RemoteHostError.invalidDestination) { try RemoteHost(destination: "host; touch /tmp/bad") }
}

@Test func remoteSSHArgumentsUseStrictNonInteractiveSSHAndQuoteEveryRemoteArgument() throws {
    let host = try RemoteHost(destination: "mac-mini")
    let arguments = RemoteSSHClient().sshArguments(
        for: host,
        remoteArguments: ["update", "--id", "npm:it's-a-package"]
    )
    #expect(arguments.contains("BatchMode=yes"))
    #expect(arguments.contains("StrictHostKeyChecking=yes"))
    #expect(arguments.contains("--"))
    #expect(arguments[arguments.count - 2] == "mac-mini")
    #expect(arguments.last?.contains("'/Applications/Package Manager Manager.app/Contents/Helpers/pmmctl' 'remote' 'update' '--id' 'npm:it'\"'\"'s-a-package'") == true)
    #expect(arguments.last?.contains("uname -s") == true)
}

@Test func remoteLinuxInventoryFindsDNFCommandsAndExistingUserManagers() throws {
    let response = try #require(RemoteSSHClient.parseLinuxInventory(#"""
    __PMM_LINUX_V1__
    __PMM_PROFILE__
    Amazon Linux 2023	aarch64	1	dnf
    __PMM_DNF_FILES__
    bash	0:5.2-1.aarch64	-rwxr-xr-x	/usr/bin/bash
    bash	0:5.2-1.aarch64	-rw-r--r--	/usr/share/licenses/bash/COPYING
    hidden-tool	0:1.0-1.aarch64	-rwxr-xr-x	/usr/libexec/hidden-tool
    __PMM_DNF_UPDATES__
    bash	0:5.3-1.aarch64
    __PMM_NPM_ROOT__
    /usr/local/lib/node_modules
    __PMM_NPM_INSTALLED__
    {"dependencies":{"@openai/codex":{"version":"0.146.0"}}}
    __PMM_NPM_OUTDATED__
    {"@openai/codex":{"latest":"0.147.0"}}
    __PMM_PNPM_ROOT__
    /home/ec2-user/.local/share/pnpm/global/5/node_modules
    __PMM_PNPM_INSTALLED__
    [{"dependencies":{"tsx":{"version":"4.19.0"}}}]
    __PMM_PNPM_OUTDATED__
    {"tsx":{"latest":"4.20.0"}}
    __PMM_CARGO__
    ripgrep v14.1.1:
        rg
    __PMM_UV_PYTHON_DIR__
    /home/ec2-user/.local/share/uv/python
    __PMM_UV_PYTHONS__
    [{"path":"/home/ec2-user/.local/share/uv/python/cpython-3.10/bin/python3.10","implementation":"cpython","version":"3.10.19","version_parts":{"major":3,"minor":10}}]
    __PMM_END__
    """#))

    #expect(response.hostDescription == "Amazon Linux 2023 (aarch64)")
    #expect(response.systemPackageManager == .dnf)
    #expect(response.canManageSystemPackages == true)
    #expect(response.inventory.packages.map(\.identifier) == ["cargo:ripgrep", "dnf:bash", "npm:@openai/codex", "pnpm:tsx", "uv:cpython:3.10"])
    #expect(response.inventory.packages.first(where: { $0.identifier == "dnf:bash" })?.latestVersion == "0:5.3-1.aarch64")
    #expect(response.inventory.packages.contains(where: { $0.identifier == "dnf:hidden-tool" }) == false)
    #expect(response.inventory.packages.first(where: { $0.identifier == "npm:@openai/codex" })?.isOutdated == true)
    #expect(response.inventory.packages.first(where: { $0.identifier == "pnpm:tsx" })?.isOutdated == true)
}

@Test func remoteLinuxInventoryParsesAPTAPKAndZypperCommands() throws {
    let apt = try #require(RemoteSSHClient.parseLinuxInventory(#"""
    __PMM_LINUX_V1__
    __PMM_PROFILE__
    Debian GNU/Linux 13	x86_64	1	apt
    __PMM_APT_VERSIONS__
    bash:amd64	5.2.15-2
    __PMM_APT_FILES__
    bash:amd64: /usr/bin/bash
    bash:amd64: /usr/share/doc/bash/README
    __PMM_APT_UPDATES__
    Inst bash:amd64 [5.2.15-2] (5.2.15-3 Debian:stable [amd64])
    __PMM_END__
    """#))
    let apk = try #require(RemoteSSHClient.parseLinuxInventory(#"""
    __PMM_LINUX_V1__
    __PMM_PROFILE__
    Alpine Linux v3.22	x86_64	0	apk
    __PMM_APK_VERSIONS__
    busybox	1.36.1-r7
    __PMM_APK_FILES__
    busybox	1.36.1-r7	/bin/sh
    busybox	1.36.1-r7	/usr/libexec/hidden-tool
    __PMM_APK_UPDATES__
    busybox-1.36.1-r7 < 1.36.1-r8
    __PMM_END__
    """#))
    let zypper = try #require(RemoteSSHClient.parseLinuxInventory(#"""
    __PMM_LINUX_V1__
    __PMM_PROFILE__
    openSUSE Tumbleweed	x86_64	1	zypper
    __PMM_RPM_FILES__
    bash	0:5.2-2.x86_64	-rwxr-xr-x	/usr/bin/bash
    __PMM_SYSTEM_UPDATES__
    bash	5.3-1
    __PMM_END__
    """#))

    #expect(apt.inventory.packages.first?.identifier == "apt:bash:amd64")
    #expect(apt.inventory.packages.first?.latestVersion == "5.2.15-3")
    #expect(apk.inventory.packages.first?.identifier == "apk:busybox")
    #expect(apk.inventory.packages.first?.latestVersion == "1.36.1-r8")
    #expect(apk.canManageSystemPackages == false)
    #expect(zypper.inventory.packages.first?.identifier == "zypper:bash")
    #expect(zypper.inventory.packages.first?.latestVersion == "5.3-1")
}

@Test func remoteLinuxSystemActionsUseEachNativeManager() async throws {
    let response = RemoteControlResponse(inventory: PackageInventory(packages: []))
    let expected: [(PackageManagerKind, String)] = [
        (.apt, "apt-get -y --only-upgrade install"),
        (.apk, "apk -U upgrade"),
        (.dnf, "dnf -y upgrade"),
        (.zypper, "zypper --non-interactive update"),
    ]

    for (manager, command) in expected {
        let runner = RecordingRemoteRunner(result: CommandResult(
            stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self),
            stderr: "",
            status: 0
        ))
        let package = ManagedPackage(
            manager: manager,
            identifier: "\(manager.rawValue):curl",
            displayName: "curl",
            installedVersion: "1",
            latestVersion: "2"
        )

        _ = try await RemoteSSHClient(runner: runner).update(package, on: RemoteHost(destination: "server"))
        #expect(runner.arguments?.last?.contains(command) == true)
    }
}

@Test @MainActor func remoteSSHExecutionLeavesMainThreadAndDecodesResponse() async throws {
    let response = RemoteControlResponse(inventory: PackageInventory(packages: []))
    let runner = RecordingRemoteRunner(result: CommandResult(
        stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self),
        stderr: "progress",
        status: 0
    ))
    let host = try RemoteHost(destination: "mac-mini")
    let decoded = try await RemoteSSHClient(runner: runner).inventory(on: host)

    #expect(decoded == response)
    #expect(runner.ranOnMainThread == false)
    #expect(runner.options?.streamsStandardOutput == false)
}

@Test func remoteSSHCanRequestAnUncachedAppInventory() async throws {
    let response = RemoteControlResponse(inventory: PackageInventory(packages: []))
    let runner = RecordingRemoteRunner(result: CommandResult(
        stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self),
        stderr: "",
        status: 0
    ))

    _ = try await RemoteSSHClient(runner: runner).inventory(
        on: RemoteHost(destination: "mac-mini"),
        ignoringAppCache: true
    )

    #expect(runner.arguments?.last?.contains("'--ignore-app-cache'") == true)
}

@Test func remoteSSHDecodesPartialFailureResponseDespiteNonzeroStatus() async throws {
    let response = RemoteControlResponse(
        inventory: PackageInventory(packages: []),
        failures: [RemoteControlFailure(message: "one package failed")]
    )
    let runner = RecordingRemoteRunner(result: CommandResult(
        stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self),
        stderr: "failure detail",
        status: 1
    ))
    let decoded = try await RemoteSSHClient(runner: runner).inventory(on: try RemoteHost(destination: "mac-mini"))
    #expect(decoded == response)
}

@Test func remoteSSHExplainsUntrustedHostKeys() async {
    let runner = RecordingRemoteRunner(result: CommandResult(
        stdout: "",
        stderr: "Host key verification failed.",
        status: 255
    ))
    await #expect(throws: RemoteSSHError.untrustedHost("mac-mini")) {
        try await RemoteSSHClient(runner: runner).inventory(on: RemoteHost(destination: "mac-mini"))
    }
}

@Test func remoteSSHDoesNotMislabelPackageManagerPermissionErrorsAsAuthenticationFailures() async {
    let runner = RecordingRemoteRunner(result: CommandResult(
        stdout: "",
        stderr: "npm ERR! EACCES: permission denied, rename",
        status: 243
    ))
    await #expect(throws: RemoteSSHError.remoteCommandFailed("atlas", "npm ERR! EACCES: permission denied, rename")) {
        try await RemoteSSHClient(runner: runner).inventory(on: RemoteHost(destination: "atlas"))
    }
}

@Test func remoteNPMActionFallsBackToNoninteractiveSudoForSystemGlobalPackages() async throws {
    let response = RemoteControlResponse(inventory: PackageInventory(packages: []))
    let runner = RecordingRemoteRunner(result: CommandResult(
        stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self),
        stderr: "",
        status: 0
    ))
    let package = ManagedPackage(
        manager: .npm,
        identifier: "npm:@openai/codex",
        installedVersion: "0.146.0",
        latestVersion: "0.147.0"
    )

    _ = try await RemoteSSHClient(runner: runner).update(package, on: RemoteHost(destination: "atlas"))

    #expect(runner.arguments?.last?.contains(#"[ -w "$(npm root -g)" ]"#) == true)
    #expect(runner.arguments?.last?.contains(#"sudo -n "$(command -v npm)" install -g"#) == true)
}

@Test func remotePNPMActionFallsBackToNoninteractiveSudoForSystemGlobalPackages() async throws {
    let response = RemoteControlResponse(inventory: PackageInventory(packages: []))
    let runner = RecordingRemoteRunner(result: CommandResult(
        stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self),
        stderr: "",
        status: 0
    ))
    let package = ManagedPackage(
        manager: .pnpm,
        identifier: "pnpm:tsx",
        installedVersion: "4.19.0",
        latestVersion: "4.20.0"
    )

    _ = try await RemoteSSHClient(runner: runner).update(package, on: RemoteHost(destination: "atlas"))

    #expect(runner.arguments?.last?.contains(#"[ -w "$(pnpm root -g 2>/dev/null || echo ~/.local/share/pnpm)" ]"#) == true)
    #expect(runner.arguments?.last?.contains(#"sudo -n "$(command -v pnpm)" update -g --latest"#) == true)
}

private final class RecordingRemoteRunner: CommandRunning, @unchecked Sendable {
    private let result: CommandResult
    private let lock = NSLock()
    private var _ranOnMainThread: Bool?
    private var _options: CommandRunOptions?
    private var _arguments: [String]?

    init(result: CommandResult) {
        self.result = result
    }

    var ranOnMainThread: Bool? { lock.withLock { _ranOnMainThread } }
    var options: CommandRunOptions? { lock.withLock { _options } }
    var arguments: [String]? { lock.withLock { _arguments } }

    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult { result }

    func run(
        _ executable: String,
        _ arguments: [String],
        options: CommandRunOptions,
        onOutput: (@Sendable (String) -> Void)?
    ) throws -> CommandResult {
        lock.withLock {
            _ranOnMainThread = Thread.isMainThread
            _options = options
            _arguments = arguments
        }
        onOutput?(result.stderr)
        return result
    }
}
