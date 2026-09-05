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

@Test func remoteBunActionFallsBackToNoninteractiveSudoForSystemGlobalPackages() async throws {
    let response = RemoteControlResponse(inventory: PackageInventory(packages: []))
    let runner = RecordingRemoteRunner(result: CommandResult(
        stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self),
        stderr: "",
        status: 0
    ))
    let package = ManagedPackage(
        manager: .bun,
        identifier: "bun:@openai/codex",
        installedVersion: "0.146.0",
        latestVersion: "0.147.0"
    )

    _ = try await RemoteSSHClient(runner: runner).update(package, on: RemoteHost(destination: "atlas"))

    #expect(runner.arguments?.last?.contains(#"bun pm bin -g"#) == true)
    #expect(runner.arguments?.last?.contains(#"sudo -n "$(command -v bun)" update -g --latest"#) == true)
}

@Test func remoteLinuxActionRunsPipxCommands() async throws {
    let response = RemoteControlResponse(inventory: PackageInventory(packages: []))
    let runner = RecordingRemoteRunner(result: CommandResult(
        stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self),
        stderr: "",
        status: 0
    ))
    let package = ManagedPackage(
        manager: .pipx,
        identifier: "pipx:cowsay",
        installedVersion: "5.0",
        latestVersion: "6.1"
    )

    _ = try await RemoteSSHClient(runner: runner).update(package, on: RemoteHost(destination: "atlas"))
    #expect(runner.arguments?.last?.contains("pipx upgrade") == true)
    #expect(runner.arguments?.last?.contains("cowsay") == true)

    _ = try await RemoteSSHClient(runner: runner).uninstall(package, on: RemoteHost(destination: "atlas"))
    #expect(runner.arguments?.last?.contains("pipx uninstall") == true)
    #expect(runner.arguments?.last?.contains("cowsay") == true)
}

@Test func remoteLinuxActionRunsGoCommands() async throws {
    let response = RemoteControlResponse(inventory: PackageInventory(packages: []))
    let runner = RecordingRemoteRunner(result: CommandResult(
        stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self),
        stderr: "",
        status: 0
    ))
    let package = ManagedPackage(
        manager: .goInstall,
        identifier: "go:github.com/rakyll/hey",
        installedVersion: "0.1.5",
        latestVersion: "0.1.6",
        binaryPath: "/home/user/go/bin/hey"
    )

    _ = try await RemoteSSHClient(runner: runner).update(package, on: RemoteHost(destination: "atlas"))
    #expect(runner.arguments?.last?.contains("go install") == true)
    #expect(runner.arguments?.last?.contains("github.com/rakyll/hey@latest") == true)

    _ = try await RemoteSSHClient(runner: runner).uninstall(package, on: RemoteHost(destination: "atlas"))
    #expect(runner.arguments?.last?.contains("rm -f") == true)
    #expect(runner.arguments?.last?.contains("/home/user/go/bin/hey") == true)
    #expect(runner.arguments?.last?.contains("awk") == true)
    #expect(runner.arguments?.last?.contains("$1==\"path\"") == true)
    #expect(runner.arguments?.last?.contains("github.com/rakyll/hey") == true)
}

@Test func remoteLinuxInventoryParsesBunPackages() async throws {
    let listOutput = """
    /home/user node_modules (2)
    ├── prettier@3.0.0
    └── @openai/codex@0.146.0
    """
    let outdatedOutput = """
    |--------------------------------------|
    | Package      | Current | Update | Latest |
    |--------------|---------|--------|--------|
    | prettier     | 3.0.0   | 3.0.0  | 3.9.6  |
    |--------------------------------------|
    """
    let payload = """
    __PMM_LINUX_V1__
    __PMM_PROFILE__
    Linux:debian:1:apt
    __PMM_BUN_BIN__
    /home/user/.bun/bin
    __PMM_BUN_INSTALLED__
    \(listOutput)
    __PMM_BUN_OUTDATED__
    \(outdatedOutput)
    __PMM_END__
    """
    let runner = RecordingRemoteRunner(result: CommandResult(stdout: payload, stderr: "", status: 0))
    let response = try await RemoteSSHClient(runner: runner).inventory(on: RemoteHost(destination: "atlas"))
    let bunPackages = response.inventory.packages.filter { $0.manager == .bun }
    #expect(bunPackages.count == 2)
    #expect(bunPackages.first { $0.displayName == "prettier" }?.latestVersion == "3.9.6")
    #expect(bunPackages.first { $0.displayName == "@openai/codex" }?.installedVersion == "0.146.0")
}

@Test func remoteLinuxInventoryParsesPipxPackages() async throws {
    let listJson = """
    {
        "pipx_spec_version": "0.1",
        "venvs": {
            "cowsay": {
                "metadata": {
                    "main_package": {
                        "package": "cowsay",
                        "package_version": "5.0",
                        "apps": ["cowsay"],
                        "app_paths": [
                            {
                                "__Path__": "/home/user/.local/pipx/venvs/cowsay/bin/cowsay",
                                "__type__": "Path"
                            }
                        ]
                    }
                }
            }
        }
    }
    """
    let outdatedText = "cowsay: 5.0 -> 6.1\n"
    let payload = """
    __PMM_LINUX_V1__
    __PMM_PROFILE__
    Linux:debian:1:apt
    __PMM_PIPX_LIST__
    \(listJson)
    __PMM_PIPX_OUTDATED__
    \(outdatedText)
    __PMM_END__
    """
    let runner = RecordingRemoteRunner(result: CommandResult(stdout: payload, stderr: "", status: 0))
    let response = try await RemoteSSHClient(runner: runner).inventory(on: RemoteHost(destination: "atlas"))
    let pipxPackages = response.inventory.packages.filter { $0.manager == .pipx }
    #expect(pipxPackages.count == 1)
    #expect(pipxPackages.first?.displayName == "cowsay")
    #expect(pipxPackages.first?.installedVersion == "5.0")
    #expect(pipxPackages.first?.latestVersion == "6.1")
    #expect(pipxPackages.first?.binaryPath == "/home/user/.local/pipx/venvs/cowsay/bin/cowsay")
}

@Test func remoteLinuxInventoryParsesGoPackages() async throws {
    let versionOutput = """
    /home/user/go/bin/hey: go1.27.1
    \tpath\tgithub.com/rakyll/hey
    \tmod\tgithub.com/rakyll/hey\tv0.1.5\th1:abc
    """
    let outdatedJson = """
    {
        "Path": "github.com/rakyll/hey",
        "Version": "v0.1.6"
    }
    """
    let payload = """
    __PMM_LINUX_V1__
    __PMM_PROFILE__
    Linux:debian:1:apt
    __PMM_GO_VERSION__
    \(versionOutput)
    __PMM_GO_OUTDATED__
    \(outdatedJson)
    __PMM_END__
    """
    let runner = RecordingRemoteRunner(result: CommandResult(stdout: payload, stderr: "", status: 0))
    let response = try await RemoteSSHClient(runner: runner).inventory(on: RemoteHost(destination: "atlas"))
    let goPackages = response.inventory.packages.filter { $0.manager == .goInstall }
    #expect(goPackages.count == 1)
    #expect(goPackages.first?.displayName == "hey")
    #expect(goPackages.first?.installedVersion == "0.1.5")
    #expect(goPackages.first?.latestVersion == "0.1.6")
    #expect(goPackages.first?.isOutdated == true)
    #expect(goPackages.first?.homepage == "https://pkg.go.dev/github.com/rakyll/hey")
}

@Test func remoteLinuxInventoryParsesPkgxPackages() async throws {
    let payload = """
    __PMM_LINUX_V1__
    __PMM_PROFILE__
    Linux\tx86_64\t1\tapt
    __PMM_PKGX__
    charm.sh/gum\t2.0.0\t/home/user/.pkgx/charm.sh/gum/v2.0.0
    gnu.org/coreutils\t9.5.0\t/home/user/.pkgx/gnu.org/coreutils/v9.5.0
    __PMM_END__
    """
    let runner = RecordingRemoteRunner(result: CommandResult(stdout: payload, stderr: "", status: 0))
    let response = try await RemoteSSHClient(runner: runner).inventory(on: RemoteHost(destination: "atlas"))
    let pkgxPackages = response.inventory.packages.filter { $0.manager == .pkgx }
    #expect(pkgxPackages.count == 2)
    let gum = pkgxPackages.first(where: { $0.identifier == "pkgx:charm.sh/gum" })
    #expect(gum?.displayName == "gum")
    #expect(gum?.installedVersion == "2.0.0")
    #expect(gum?.installLocation == "/home/user/.pkgx/charm.sh/gum/v2.0.0")
    #expect(gum?.homepage == "https://pkgx.dev/pkgs/charm.sh/gum/")
}

@Test func remoteLinuxActionScriptRunsPkgxUpdateAndUninstall() async throws {
    let response = RemoteControlResponse(inventory: PackageInventory(packages: []))
    let runner = RecordingRemoteRunner(result: CommandResult(
        stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self),
        stderr: "",
        status: 0
    ))
    let package = ManagedPackage(
        manager: .pkgx,
        identifier: "pkgx:charm.sh/gum",
        installedVersion: "2.0.0",
        latestVersion: "2.1.0",
        installLocation: "/home/user/.pkgx/charm.sh/gum/v2.0.0"
    )

    _ = try await RemoteSSHClient(runner: runner).update(package, on: RemoteHost(destination: "atlas"))
    #expect(runner.arguments?.last?.contains("pkgx +") == true)
    #expect(runner.arguments?.last?.contains("charm.sh/gum") == true)
    #expect(runner.arguments?.last?.contains("true") == true)

    _ = try await RemoteSSHClient(runner: runner).uninstall(package, on: RemoteHost(destination: "atlas"))
    #expect(runner.arguments?.last?.contains("charm.sh/gum") == true)
    #expect(runner.arguments?.last?.contains("rm -rf") == true)
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
