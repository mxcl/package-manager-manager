import Foundation

public struct RemoteHost: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String?
    public var destination: String

    public init(id: UUID = UUID(), name: String? = nil, destination: String) throws {
        let destination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidDestination(destination) else { throw RemoteHostError.invalidDestination }
        let normalizedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = id
        self.name = normalizedName?.isEmpty == false ? normalizedName : nil
        self.destination = destination
    }

    public var displayName: String { Self.capitalizingHost(Self.droppingLocalSuffix(name ?? destination)) }

    public static func isValidDestination(_ destination: String) -> Bool {
        guard !destination.isEmpty, destination.count <= 255, !destination.hasPrefix("-") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._@:%+-[]"))
        return destination.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func droppingLocalSuffix(_ value: String) -> String {
        value.lowercased().hasSuffix(".local") ? String(value.dropLast(6)) : value
    }

    private static func capitalizingHost(_ value: String) -> String {
        value.prefix(1).uppercased() + value.dropFirst()
    }
}

public struct RemoteSSHClient: Sendable {
    public static let controlExecutable = "/Applications/Package Manager Manager.app/Contents/Helpers/pmmctl"

    private let runner: CommandRunning
    private let sshExecutable: String

    public init(runner: CommandRunning = SystemCommandRunner(), sshExecutable: String = "/usr/bin/ssh") {
        self.runner = runner
        self.sshExecutable = sshExecutable
    }

    public func inventory(on host: RemoteHost, ignoringAppCache: Bool = false) async throws -> RemoteControlResponse {
        var arguments = ["inventory", "--protocol", String(remoteControlProtocolVersion)]
        if ignoringAppCache { arguments.append("--ignore-app-cache") }
        return try await run(host, arguments: arguments, linuxScript: Self.linuxInventoryScript)
    }

    public func update(
        _ package: ManagedPackage,
        on host: RemoteHost,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> RemoteControlResponse {
        try await run(host, arguments: [
            "update", "--protocol", String(remoteControlProtocolVersion),
            "--manager", package.manager.rawValue, "--id", package.id,
        ], linuxScript: Self.linuxActionScript("update", package: package), onProgress: onProgress)
    }

    public func uninstall(
        _ package: ManagedPackage,
        on host: RemoteHost,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> RemoteControlResponse {
        try await run(host, arguments: [
            "uninstall", "--protocol", String(remoteControlProtocolVersion),
            "--manager", package.manager.rawValue, "--id", package.id,
        ], linuxScript: Self.linuxActionScript("uninstall", package: package), onProgress: onProgress)
    }

    public func updateAll(
        on host: RemoteHost,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> RemoteControlResponse {
        try await run(
            host,
            arguments: ["update-all", "--protocol", String(remoteControlProtocolVersion)],
            linuxScript: Self.linuxUpdateAllScript,
            onProgress: onProgress
        )
    }

    public func sshArguments(for host: RemoteHost, remoteArguments: [String]) -> [String] {
        sshArguments(for: host, remoteArguments: remoteArguments, linuxScript: "echo 'Unsupported Linux command.' >&2; exit 64")
    }

    private func sshArguments(for host: RemoteHost, remoteArguments: [String], linuxScript: String) -> [String] {
        let controlArguments = ["remote"] + remoteArguments
        let macCommand = ([Self.controlExecutable] + controlArguments).map(Self.shellQuote).joined(separator: " ")
        let remoteCommand = "if [ -x \(Self.shellQuote(Self.controlExecutable)) ]; then exec \(macCommand); "
            + "elif [ \"$(uname -s 2>/dev/null)\" = Linux ]; then /bin/sh -c \(Self.shellQuote(linuxScript)); "
            + "else echo 'Package Manager Manager is not installed on this Mac.' >&2; exit 127; fi"
        return [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=3",
            "--",
            host.destination,
            remoteCommand,
        ]
    }

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func run(
        _ host: RemoteHost,
        arguments: [String],
        linuxScript: String,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> RemoteControlResponse {
        let runner = runner
        let executable = sshExecutable
        let sshArguments = sshArguments(for: host, remoteArguments: arguments, linuxScript: linuxScript)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let result = try runner.run(
                        executable,
                        sshArguments,
                        options: CommandRunOptions(streamsStandardOutput: false),
                        onOutput: onProgress
                    )
                    if let response = Self.response(from: result.stdout) {
                        guard response.protocolVersion == remoteControlProtocolVersion else {
                            throw RemoteSSHError.incompatibleProtocol
                        }
                        continuation.resume(returning: response)
                    } else if result.status == 0, result.stdout.contains("__PMM_LINUX_ACTION_OK__") {
                        let inventoryResult = try runner.run(
                            executable,
                            self.sshArguments(for: host, remoteArguments: ["inventory", "--protocol", String(remoteControlProtocolVersion)], linuxScript: Self.linuxInventoryScript),
                            options: CommandRunOptions(streamsStandardOutput: false),
                            onOutput: onProgress
                        )
                        if let response = Self.response(from: inventoryResult.stdout) {
                            continuation.resume(returning: response)
                        } else {
                            throw Self.error(for: inventoryResult, host: host)
                        }
                    } else {
                        throw Self.error(for: result, host: host)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func response(from output: String) -> RemoteControlResponse? {
        if let data = output.data(using: .utf8),
           let response = try? JSONDecoder().decode(RemoteControlResponse.self, from: data) {
            return response
        }
        return parseLinuxInventory(output)
    }

    static func parseLinuxInventory(_ output: String) -> RemoteControlResponse? {
        guard output.contains("__PMM_LINUX_V1__") else { return nil }
        let sections = linuxSections(output)
        let profile = sections["PROFILE"]?.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) ?? []
        let description = profile.first.map { profile.count > 1 ? "\($0) (\(profile[1]))" : $0 }
        let canManage = profile.count > 2 ? profile[2] == "1" : false
        let manager = profile.count > 3 ? PackageManagerKind(rawValue: profile[3]) : nil
        var packages = manager.map { linuxSystemPackages($0, sections: sections) } ?? []
        packages += linuxNPM(sections: sections)
        packages += linuxPNPM(sections: sections)
        packages += linuxBun(sections: sections)
        packages += linuxCargo(sections["CARGO"])
        packages += linuxUV(sections: sections)
        packages += linuxPipx(sections: sections)
        packages += linuxGo(version: sections["GO_VERSION"], outdated: sections["GO_OUTDATED"])
        packages += linuxPkgx(sections["PKGX"])

        let failures = lines(sections["ERRORS"]).map { RemoteControlFailure(message: $0) }
        return RemoteControlResponse(
            inventory: PackageInventory(packages: packages.sorted(by: linuxPackageOrder), errors: failures.map(\.message)),
            failures: failures,
            hostDescription: description,
            systemPackageManager: manager,
            canManageSystemPackages: manager == nil ? nil : canManage
        )
    }

    private static func linuxSystemPackages(
        _ manager: PackageManagerKind,
        sections: [String: String]
    ) -> [ManagedPackage] {
        var nativePackages: [String: LinuxNativePackage] = [:]
        let latest: [String: String]

        switch manager {
        case .dnf, .zypper:
            latest = tabMap(sections["SYSTEM_UPDATES"] ?? sections["DNF_UPDATES"])
            for line in lines(sections["RPM_FILES"] ?? sections["DNF_FILES"]) {
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard fields.count == 4,
                      fields[2].contains("x"),
                      linuxCommandDirectories.contains(URL(fileURLWithPath: fields[3]).deletingLastPathComponent().path) else { continue }
                nativePackages[fields[0], default: LinuxNativePackage(version: fields[1])].paths.append(fields[3])
            }
        case .apt:
            latest = aptLatest(sections["APT_UPDATES"])
            let versions = tabMap(sections["APT_VERSIONS"])
            for line in lines(sections["APT_FILES"]) {
                guard let delimiter = line.range(of: ": /", options: .backwards) else { continue }
                let path = String(line[line.index(after: delimiter.lowerBound)...]).trimmed
                guard linuxCommandDirectories.contains(URL(fileURLWithPath: path).deletingLastPathComponent().path) else { continue }
                for name in line[..<delimiter.lowerBound].split(separator: ",").map({ String($0).trimmed }) {
                    guard let version = versions[name] else { continue }
                    nativePackages[name, default: LinuxNativePackage(version: version)].paths.append(path)
                }
            }
        case .apk:
            let installed = tabMap(sections["APK_VERSIONS"])
            latest = apkLatest(sections["APK_UPDATES"], installed: installed)
            for line in lines(sections["APK_FILES"]) {
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard fields.count == 3,
                      linuxCommandDirectories.contains(URL(fileURLWithPath: fields[2]).deletingLastPathComponent().path) else { continue }
                nativePackages[fields[0], default: LinuxNativePackage(version: fields[1])].paths.append(fields[2])
            }
        default:
            return []
        }

        return nativePackages.map { name, package in
            let paths = Array(Set(package.paths)).sorted()
            return ManagedPackage(
                manager: manager,
                identifier: "\(manager.rawValue):\(name)",
                displayName: name,
                installedVersion: package.version,
                latestVersion: latest[name],
                summary: "\(manager.title) package providing command-line tools",
                category: "system",
                binaryPath: paths.first,
                executableNames: paths.map { URL(fileURLWithPath: $0).lastPathComponent }
            )
        }
    }

    private static func aptLatest(_ output: String?) -> [String: String] {
        lines(output).reduce(into: [:]) { result, line in
            let fields = line.split(separator: " ")
            guard fields.count >= 4, fields[0] == "Inst", let open = line.firstIndex(of: "(") else { return }
            result[String(fields[1])] = line[line.index(after: open)...].split(separator: " ").first.map(String.init)
        }
    }

    private static func apkLatest(_ output: String?, installed: [String: String]) -> [String: String] {
        lines(output).reduce(into: [:]) { result, line in
            guard let pair = installed.first(where: { line.hasPrefix("\($0.key)-\($0.value) ") }),
                  let marker = line.range(of: " < ") else { return }
            result[pair.key] = String(line[marker.upperBound...]).trimmed
        }
    }

    private static func linuxNPM(sections: [String: String]) -> [ManagedPackage] {
        guard let data = sections["NPM_INSTALLED"]?.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dependencies = root["dependencies"] as? [String: Any] else { return [] }
        let installRoot = sections["NPM_ROOT"]?.trimmed
        let latest: [String: String] = {
            guard let data = sections["NPM_OUTDATED"]?.data(using: .utf8),
                  let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return values.reduce(into: [:]) { result, pair in
                guard let body = pair.value as? [String: Any], let version = body["latest"] as? String else { return }
                result[pair.key] = version
            }
        }()
        return dependencies.compactMap { name, value in
            guard let body = value as? [String: Any] else { return nil }
            return ManagedPackage(
                manager: .npm,
                identifier: "npm:\(name)",
                displayName: name,
                installedVersion: body["version"] as? String,
                latestVersion: latest[name],
                summary: "Globally installed npm package",
                category: "developer-tools",
                installLocation: installRoot.map { "\($0)/\(name)" }
            )
        }
    }

    private static func linuxPNPM(sections: [String: String]) -> [ManagedPackage] {
        let root = sections["PNPM_ROOT"]?.trimmed
        guard let output = sections["PNPM_INSTALLED"], !output.isEmpty else { return [] }
        let deps = PackageScanner.parsePNPMDependencies(output)
        guard !deps.isEmpty else { return [] }

        let outdated = sections["PNPM_OUTDATED"].map { PackageScanner.parsePNPMOutdated($0) } ?? [:]

        return deps.map { name, info in
            ManagedPackage(
                manager: .pnpm,
                identifier: "pnpm:\(name)",
                displayName: name,
                installedVersion: info.version,
                latestVersion: outdated[name],
                summary: "Globally installed pnpm package",
                category: "developer-tools",
                installLocation: info.path ?? root.map { "\($0)/\(name)" }
            )
        }
    }

    private static func linuxBun(sections: [String: String]) -> [ManagedPackage] {
        guard let output = sections["BUN_INSTALLED"], !output.isEmpty else { return [] }
        let parsed = PackageScanner.parseBunList(output)
        guard !parsed.packages.isEmpty else { return [] }

        let outdated = sections["BUN_OUTDATED"].map(PackageScanner.parseBunOutdated) ?? [:]
        let installRoot = parsed.rootDirectory ?? sections["BUN_BIN"]?.trimmed

        return parsed.packages.map { name, version in
            ManagedPackage(
                manager: .bun,
                identifier: "bun:\(name)",
                displayName: name,
                installedVersion: version,
                latestVersion: outdated[name],
                summary: "Globally installed Bun package",
                category: "developer-tools",
                installLocation: installRoot.map { "\($0)/node_modules/\(name)" }
            )
        }
    }

    private static func linuxCargo(_ output: String?) -> [ManagedPackage] {
        var packages: [ManagedPackage] = []
        var current: (name: String, version: String, bins: [String])?
        func flush() {
            guard let crate = current else { return }
            packages.append(ManagedPackage(
                manager: .cargoInstall,
                identifier: "cargo:\(crate.name)",
                displayName: crate.name,
                installedVersion: crate.version,
                latestVersion: nil,
                summary: "cargo-installed Rust binary",
                category: "developer-tools",
                installLocation: "~/.cargo",
                binaryPath: crate.bins.first.map { "~/.cargo/bin/\($0)" },
                executableNames: crate.bins
            ))
        }
        for line in lines(output) {
            let trimmed = line.trimmed
            let parts = trimmed.dropLast().split(separator: " ").map(String.init)
            if trimmed.hasSuffix(":"), parts.count >= 2, parts.last?.hasPrefix("v") == true {
                flush()
                current = (parts.dropLast().joined(separator: " "), String(parts.last!.dropFirst()), [])
            } else if line.first?.isWhitespace == true, !trimmed.isEmpty {
                current?.bins.append(trimmed)
            }
        }
        flush()
        return packages
    }

    private static func linuxUV(sections: [String: String]) -> [ManagedPackage] {
        let toolDir = sections["UV_TOOL_DIR"]?.trimmed
        let outdated = uvLatest(sections["UV_OUTDATED"])
        var packages: [ManagedPackage] = []
        var current: (name: String, version: String?, paths: [String])?
        func flush() {
            guard let tool = current else { return }
            packages.append(ManagedPackage(
                manager: .uv,
                identifier: "uv:tool:\(tool.name)",
                displayName: tool.name,
                installedVersion: tool.version,
                latestVersion: outdated[tool.name],
                summary: "uv-installed tool",
                category: "developer-tools",
                installLocation: tool.paths.first { toolDir.map($0.hasPrefix) ?? false },
                binaryPath: tool.paths.first,
                executableNames: tool.paths.map { URL(fileURLWithPath: $0).lastPathComponent }
            ))
        }
        for line in lines(sections["UV_TOOLS"]) {
            let trimmed = line.trimmed
            let parts = trimmed.split(separator: " ").map(String.init)
            if line.first?.isWhitespace != true, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("-"),
               let name = parts.first, name != "No" {
                flush()
                current = (name, parts.dropFirst().first(where: { $0.hasPrefix("v") }).map { String($0.dropFirst()) }, [])
            } else if let slash = trimmed.firstIndex(of: "/") {
                current?.paths.append(String(trimmed[slash...]))
            }
        }
        flush()

        guard let pythonDir = sections["UV_PYTHON_DIR"]?.trimmed,
              let data = sections["UV_PYTHONS"]?.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return packages }
        packages += rows.compactMap { row in
            guard let path = row["path"] as? String,
                  path == pythonDir || path.hasPrefix("\(pythonDir)/"),
                  let implementation = row["implementation"] as? String,
                  let version = row["version"] as? String,
                  let parts = row["version_parts"] as? [String: Any],
                  let major = parts["major"] as? Int,
                  let minor = parts["minor"] as? Int else { return nil }
            return ManagedPackage(
                manager: .uv,
                identifier: "uv:\(implementation):\(major).\(minor)",
                displayName: "uv Managed Python \(major).\(minor)",
                installedVersion: version,
                latestVersion: nil,
                summary: "uv-managed Python",
                category: "language-runtime",
                installLocation: URL(fileURLWithPath: path).deletingLastPathComponent().path,
                binaryPath: path
            )
        }
        return ManagedPackage.consolidatingInstalledVersions(in: packages)
    }

    private static func uvLatest(_ output: String?) -> [String: String] {
        lines(output).reduce(into: [:]) { result, line in
            let parts = line.trimmed.split(separator: " ").map(String.init)
            guard let name = parts.first,
                  let arrow = parts.firstIndex(of: "->"),
                  parts.indices.contains(arrow + 1) else { return }
            result[name] = parts[arrow + 1].trimmingCharacters(in: CharacterSet(charactersIn: "v)"))
        }
    }

    private static func linuxPipx(sections: [String: String]) -> [ManagedPackage] {
        guard let output = sections["PIPX_LIST"], !output.isEmpty else { return [] }
        let outdated = sections["PIPX_OUTDATED"].map(PackageScanner.parsePipxOutdated) ?? [:]
        return PackageScanner.parsePipxList(output, outdated: outdated)
    }

    private static func linuxGo(version: String?, outdated: String?) -> [ManagedPackage] {
        guard let version, !version.isEmpty else { return [] }
        let latest = outdated.map(PackageScanner.parseGoListJSON) ?? [:]
        return PackageScanner.parseGoVersionList(version, latestVersions: latest)
    }

    private static func linuxPkgx(_ output: String?) -> [ManagedPackage] {
        guard let output, !output.isEmpty else { return [] }
        var rawPackages: [ManagedPackage] = []
        for line in lines(output) {
            let parts = line.split(separator: "\t").map(String.init)
            guard parts.count >= 3 else { continue }
            let project = parts[0]
            let version = parts[1]
            let vdir = parts[2]
            let shortName = URL(fileURLWithPath: project).lastPathComponent
            let repo: String? = project.hasPrefix("github.com/") ? "https://" + project : nil
            rawPackages.append(ManagedPackage(
                manager: .pkgx,
                identifier: "pkgx:\(project)",
                catalogIdentifier: "pkgx:\(project)",
                displayName: shortName,
                installedVersion: version,
                latestVersion: nil,
                summary: "Package run and managed with pkgx",
                category: "developer-tools",
                homepage: "https://pkgx.dev/pkgs/\(project)/",
                docs: "https://docs.pkgx.sh",
                repo: repo,
                installLocation: vdir
            ))
        }
        return ManagedPackage.consolidatingInstalledVersions(in: rawPackages)
    }

    private static func linuxSections(_ output: String) -> [String: String] {
        var sections: [String: [String]] = [:]
        var current: String?
        for line in output.components(separatedBy: .newlines) {
            if line.hasPrefix("__PMM_"), line.hasSuffix("__"), line != "__PMM_LINUX_V1__" {
                current = String(line.dropFirst(6).dropLast(2))
            } else if let current {
                sections[current, default: []].append(line)
            }
        }
        return sections.mapValues { $0.joined(separator: "\n").trimmed }
    }

    private static func tabMap(_ output: String?) -> [String: String] {
        lines(output).reduce(into: [:]) { result, line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if fields.count >= 2 { result[fields[0]] = fields[1] }
        }
    }

    private static func lines(_ output: String?) -> [String] {
        output?.split(whereSeparator: \.isNewline).map(String.init) ?? []
    }

    private static func linuxPackageOrder(_ lhs: ManagedPackage, _ rhs: ManagedPackage) -> Bool {
        lhs.manager == rhs.manager
            ? lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            : lhs.manager.rawValue < rhs.manager.rawValue
    }

    private struct LinuxNativePackage {
        let version: String
        var paths: [String] = []
    }

    private static let linuxCommandDirectories: Set<String> = [
        "/bin", "/sbin", "/usr/bin", "/usr/sbin", "/usr/local/bin", "/usr/local/sbin",
    ]

    private static let linuxInventoryScript = #"""
    export PATH="$HOME/.bun/bin:$HOME/.local/bin:$HOME/bin:/usr/local/bin:/usr/bin:/usr/local/sbin:/usr/sbin:$PATH"
    printf '__PMM_LINUX_V1__\n__PMM_PROFILE__\n'
    pretty=Linux
    if [ -r /etc/os-release ]; then . /etc/os-release; pretty=${PRETTY_NAME:-${NAME:-Linux}}; fi
    pretty=$(printf '%s' "$pretty" | tr '\t\r\n' '   ')
    can_sudo=0; sudo -n true >/dev/null 2>&1 && can_sudo=1
    system_manager=''
    case " ${ID:-} ${ID_LIKE:-} " in
      *" alpine "*) command -v apk >/dev/null 2>&1 && system_manager=apk ;;
      *" debian "*|*" ubuntu "*) command -v apt-get >/dev/null 2>&1 && command -v dpkg-query >/dev/null 2>&1 && system_manager=apt ;;
      *" suse "*) command -v zypper >/dev/null 2>&1 && command -v rpm >/dev/null 2>&1 && system_manager=zypper ;;
      *" fedora "*|*" rhel "*|*" centos "*|*" amzn "*) command -v dnf >/dev/null 2>&1 && command -v rpm >/dev/null 2>&1 && system_manager=dnf ;;
    esac
    if [ -z "$system_manager" ]; then
      if command -v dnf >/dev/null 2>&1 && command -v rpm >/dev/null 2>&1; then system_manager=dnf
      elif command -v apt-get >/dev/null 2>&1 && command -v dpkg-query >/dev/null 2>&1; then system_manager=apt
      elif command -v zypper >/dev/null 2>&1 && command -v rpm >/dev/null 2>&1; then system_manager=zypper
      elif command -v apk >/dev/null 2>&1; then system_manager=apk
      fi
    fi
    printf '%s\t%s\t%s\t%s\n' "$pretty" "$(uname -m)" "$can_sudo" "$system_manager"
    if [ "$system_manager" = dnf ] || [ "$system_manager" = zypper ]; then
      printf '__PMM_RPM_FILES__\n'
      rpm -qa --qf '[%{=NAME}\t%{=EPOCHNUM}:%{=VERSION}-%{=RELEASE}.%{=ARCH}\t%{FILEMODES:perms}\t%{FILENAMES}\n]' 2>/dev/null |
        awk -F '\t' '$3 ~ /x/ && $4 ~ /^\/(bin|sbin|usr\/bin|usr\/sbin|usr\/local\/bin|usr\/local\/sbin)\/[^\/]+$/'
      printf '__PMM_SYSTEM_UPDATES__\n'
    fi
    if [ "$system_manager" = dnf ]; then
      if dnf -q makecache >/dev/null 2>&1; then
        dnf -q repoquery --upgrades --qf '%{name}\t%{epoch}:%{version}-%{release}.%{arch}' 2>/dev/null || true
      else
        printf '__PMM_ERRORS__\nDNF could not refresh repository metadata.\n'
      fi
    fi
    if [ "$system_manager" = zypper ]; then
      refreshed=1
      [ "$can_sudo" = 0 ] || sudo -n zypper --non-interactive refresh >/dev/null 2>&1 || refreshed=0
      zypper --non-interactive --no-refresh list-updates 2>/dev/null |
        awk -F '|' 'NF >= 6 { name=$3; version=$5; gsub(/^[ \t]+|[ \t]+$/, "", name); gsub(/^[ \t]+|[ \t]+$/, "", version); if (name != "" && name != "Name" && version != "" && version != "Available Version") print name "\t" version }' || true
      [ "$refreshed" = 1 ] || printf '__PMM_ERRORS__\nZypper could not refresh repository metadata.\n'
    fi
    if [ "$system_manager" = apt ]; then
      printf '__PMM_APT_VERSIONS__\n'
      dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Abbrev}\n' 2>/dev/null |
        awk -F '\t' '$3 ~ /^ii/ { print $1 "\t" $2 }'
      printf '__PMM_APT_FILES__\n'
      dpkg-query -S '/bin/*' '/sbin/*' '/usr/bin/*' '/usr/sbin/*' '/usr/local/bin/*' '/usr/local/sbin/*' 2>/dev/null |
        while IFS= read -r line; do path=${line#*: }; [ -f "$path" ] && [ -x "$path" ] && printf '%s\n' "$line"; done || true
      printf '__PMM_APT_UPDATES__\n'
      refreshed=1
      [ "$can_sudo" = 0 ] || sudo -n apt-get update >/dev/null 2>&1 || refreshed=0
      LC_ALL=C apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null | awk '/^Inst /' || true
      [ "$refreshed" = 1 ] || printf '__PMM_ERRORS__\nAPT could not refresh repository metadata.\n'
    fi
    if [ "$system_manager" = apk ]; then
      printf '__PMM_APK_VERSIONS__\n'
      apk info 2>/dev/null | while IFS= read -r package; do
        versioned=$(apk info -v "$package" 2>/dev/null | head -n 1)
        printf '%s\t%s\n' "$package" "${versioned#"$package"-}"
      done
      printf '__PMM_APK_FILES__\n'
      # ponytail: one apk info call per package; parse /lib/apk/db/installed if this is slow on very large hosts.
      apk info 2>/dev/null | while IFS= read -r package; do
        versioned=$(apk info -v "$package" 2>/dev/null | head -n 1); version=${versioned#"$package"-}
        apk info -L "$package" 2>/dev/null | while IFS= read -r path; do
          path=${path#/}
          case "/$path" in
            /bin/*|/sbin/*|/usr/bin/*|/usr/sbin/*|/usr/local/bin/*|/usr/local/sbin/*)
              [ -f "/$path" ] && [ -x "/$path" ] && printf '%s\t%s\t/%s\n' "$package" "$version" "$path"
              ;;
          esac
        done
      done
      printf '__PMM_APK_UPDATES__\n'
      refreshed=1
      [ "$can_sudo" = 0 ] || sudo -n apk update >/dev/null 2>&1 || refreshed=0
      apk version -v -l '<' 2>/dev/null || true
      [ "$refreshed" = 1 ] || printf '__PMM_ERRORS__\napk could not refresh repository metadata.\n'
    fi
    if command -v npm >/dev/null 2>&1; then
      printf '__PMM_NPM_ROOT__\n'; npm root -g 2>/dev/null || true
      printf '__PMM_NPM_INSTALLED__\n'; npm ls -g --depth=0 --json 2>/dev/null || true
      printf '__PMM_NPM_OUTDATED__\n'; npm outdated -g --json 2>/dev/null || true
    fi
    if command -v pnpm >/dev/null 2>&1; then
      printf '__PMM_PNPM_ROOT__\n'; pnpm root -g 2>/dev/null || true
      printf '__PMM_PNPM_INSTALLED__\n'; pnpm list -g --depth=0 --json 2>/dev/null || true
      printf '__PMM_PNPM_OUTDATED__\n'; pnpm outdated -g --json 2>/dev/null || true
    fi
    if command -v bun >/dev/null 2>&1; then
      printf '__PMM_BUN_BIN__\n'; bun pm bin -g 2>/dev/null || true
      printf '__PMM_BUN_INSTALLED__\n'; bun pm ls -g 2>/dev/null || true
      printf '__PMM_BUN_OUTDATED__\n'; bun outdated -g 2>/dev/null || true
    fi
    if command -v cargo >/dev/null 2>&1; then
      printf '__PMM_CARGO__\n'; cargo install --list --color never 2>/dev/null || true
    fi
    if command -v uv >/dev/null 2>&1; then
      printf '__PMM_UV_TOOL_DIR__\n'; uv tool dir --color never 2>/dev/null || true
      printf '__PMM_UV_TOOLS__\n'; uv tool list --show-paths --show-version-specifiers --show-python --offline --color never 2>/dev/null || true
      printf '__PMM_UV_OUTDATED__\n'; uv tool list --outdated --show-paths --show-version-specifiers --show-python --color never 2>/dev/null || true
      printf '__PMM_UV_PYTHON_DIR__\n'; uv python dir --color never 2>/dev/null || true
      printf '__PMM_UV_PYTHONS__\n'; uv python list --only-installed --output-format json --offline --color never 2>/dev/null || true
    fi
    if command -v pipx >/dev/null 2>&1; then
      printf '__PMM_PIPX_LIST__\n'; pipx list --json 2>/dev/null || true
      printf '__PMM_PIPX_OUTDATED__\n'; pipx list --outdated --json 2>/dev/null || pipx list --outdated 2>/dev/null || true
    fi
    if command -v go >/dev/null 2>&1; then
      gobin=$(go env GOBIN 2>/dev/null || true)
      if [ -z "$gobin" ]; then
        gopath=$(go env GOPATH 2>/dev/null || true)
        if [ -n "$gopath" ]; then
          gobin="${gopath%%:*}/bin"
        else
          gobin="$HOME/go/bin"
        fi
      fi
      if [ -d "$gobin" ]; then
        go_ver=$(find -L "$gobin" -maxdepth 1 -type f ! -name '.*' -exec go version -m {} + 2>/dev/null || true)
        if [ -n "$go_ver" ]; then
          printf '__PMM_GO_VERSION__\n'
          printf '%s\n' "$go_ver"
          printf '__PMM_GO_OUTDATED__\n'
          if command -v awk >/dev/null 2>&1; then
            for mod in $(printf '%s\n' "$go_ver" | awk '$1=="mod"{print $2}' | sort -u); do
              go list -m -json "$mod@latest" 2>/dev/null || true
            done
          fi
        fi
      fi
    fi
    if command -v pkgx >/dev/null 2>&1; then
      pkgx_dir="${PKGX_DIR:-$HOME/.pkgx}"
      [ ! -d "$pkgx_dir" ] && [ -d "$HOME/.local/share/pkgx" ] && pkgx_dir="$HOME/.local/share/pkgx"
      if [ -d "$pkgx_dir" ]; then
        # Matches local PackageScanner depth limit of 6 for nested namespaces
        pkgx_pkgs=$(find "$pkgx_dir" -mindepth 2 -maxdepth 6 -type d -name 'v[0-9]*' 2>/dev/null || true)
        if [ -n "$pkgx_pkgs" ]; then
          printf '__PMM_PKGX__\n'
          printf '%s\n' "$pkgx_pkgs" | while read -r vdir; do
            [ -z "$vdir" ] && continue
            pdir=$(dirname "$vdir")
            proj=${pdir#$pkgx_dir/}
            ver=${vdir##*/v}
            printf '%s\t%s\t%s\n' "$proj" "$ver" "$vdir"
          done
        fi
      fi
    fi
    printf '__PMM_END__\n'
    """#

    private static func linuxActionScript(_ action: String, package: ManagedPackage) -> String {
        let token = shellQuote(package.packageToken)
        let systemToken = shellQuote(package.displayName)
        let command: String
        switch (action, package.manager) {
        case ("update", .apk): command = "sudo -n apk -U upgrade \(systemToken)"
        case ("uninstall", .apk): command = "sudo -n apk del \(systemToken)"
        case ("update", .apt): command = "sudo -n apt-get update 1>&2 && sudo -n apt-get -y --only-upgrade install \(systemToken)"
        case ("uninstall", .apt): command = "sudo -n apt-get -y remove \(systemToken)"
        case ("update", .dnf): command = "sudo -n dnf -y upgrade \(systemToken)"
        case ("uninstall", .dnf): command = "sudo -n dnf -y remove \(systemToken)"
        case ("update", .zypper): command = "sudo -n zypper --non-interactive refresh 1>&2 && sudo -n zypper --non-interactive update \(systemToken)"
        case ("uninstall", .zypper): command = "sudo -n zypper --non-interactive remove \(systemToken)"
        case ("update", .npm):
            let arguments = "install -g \(shellQuote(package.packageToken + "@latest"))"
            command = "if [ -w \"$(npm root -g)\" ]; then npm \(arguments); else sudo -n \"$(command -v npm)\" \(arguments); fi"
        case ("uninstall", .npm):
            let arguments = "uninstall -g \(token)"
            command = "if [ -w \"$(npm root -g)\" ]; then npm \(arguments); else sudo -n \"$(command -v npm)\" \(arguments); fi"
        case ("update", .pnpm):
            let arguments = "update -g --latest \(shellQuote(package.packageToken))"
            command = "if [ -w \"$(pnpm root -g 2>/dev/null || echo ~/.local/share/pnpm)\" ]; then pnpm \(arguments); else sudo -n \"$(command -v pnpm)\" \(arguments); fi"
        case ("uninstall", .pnpm):
            let arguments = "remove -g \(token)"
            command = "if [ -w \"$(pnpm root -g 2>/dev/null || echo ~/.local/share/pnpm)\" ]; then pnpm \(arguments); else sudo -n \"$(command -v pnpm)\" \(arguments); fi"
        case ("update", .bun):
            let arguments = "update -g --latest \(token)"
            command = "if [ -w \"$(bun pm bin -g 2>/dev/null || echo ~/.bun/bin)\" ]; then bun \(arguments); else sudo -n \"$(command -v bun)\" \(arguments); fi"
        case ("uninstall", .bun):
            let arguments = "remove -g \(token)"
            command = "if [ -w \"$(bun pm bin -g 2>/dev/null || echo ~/.bun/bin)\" ]; then bun \(arguments); else sudo -n \"$(command -v bun)\" \(arguments); fi"
        case ("update", .pipx): command = "pipx upgrade \(token)"
        case ("uninstall", .pipx): command = "pipx uninstall \(token)"
        case ("update", .goInstall):
            command = "go install \(shellQuote(package.packageToken + "@latest"))"
        case ("uninstall", .goInstall):
            let bin = shellQuote(package.binaryPath ?? package.installLocation ?? "")
            let expectedPath = package.identifier.hasPrefix("go:") ? String(package.identifier.dropFirst(3)) : package.packageToken
            let token = shellQuote(expectedPath)
            command = """
            if command -v go >/dev/null 2>&1; then
              gobin=$(go env GOBIN 2>/dev/null || true)
              if [ -z "$gobin" ]; then
                gopath=$(go env GOPATH 2>/dev/null || true)
                [ -n "$gopath" ] && gobin="${gopath%%:*}/bin" || gobin="$HOME/go/bin"
              fi
              target_dir=$(cd "$(dirname \(bin))" 2>/dev/null && pwd || true)
              expected_dir=$(cd "$gobin" 2>/dev/null && pwd || true)
              if [ -n "$target_dir" ] && [ "$target_dir" = "$expected_dir" ] && [ -f \(bin) ] && [ ! -d \(bin) ]; then
                bin_path=$(go version -m \(bin) 2>/dev/null | awk '$1=="path"{print $2; exit}')
                if [ "$bin_path" = \(token) ]; then
                  rm -f \(bin)
                else
                  echo "Binary at \(bin) has Go path '$bin_path', does not match package \(token)" >&2; exit 1
                fi
              else
                echo "Binary \(bin) not found or is a directory in Go bin directory $gobin" >&2; exit 1
              fi
            else
              echo "go command not found" >&2; exit 1
            fi
            """
        case ("update", .pkgx):
            command = "pkgx +\(token) true"
        case ("uninstall", .pkgx):
            let location = shellQuote(package.installLocation ?? "")
            let expectedProject = package.identifier.hasPrefix("pkgx:") ? String(package.identifier.dropFirst(5)) : package.packageToken
            let token = shellQuote(expectedProject)
            command = """
            pkgx_dir="${PKGX_DIR:-$HOME/.pkgx}"
            [ ! -d "$pkgx_dir" ] && [ -d "$HOME/.local/share/pkgx" ] && pkgx_dir="$HOME/.local/share/pkgx"
            if [ -n "$pkgx_dir" ] && [ -d "$pkgx_dir" ]; then
              target_dir=$(cd \(location) 2>/dev/null && pwd || true)
              root_dir=$(cd "$pkgx_dir" 2>/dev/null && pwd || true)
              if [ -n "$target_dir" ] && [ -n "$root_dir" ] && [ "${target_dir#$root_dir/}" != "$target_dir" ] && [ -d "$target_dir" ]; then
                rel="${target_dir#$root_dir/}"
                expected_project=\(token)
                case "$rel" in
                  "$expected_project"/v*|"$expected_project")
                    rm -rf "$target_dir"
                    pdir=$(dirname "$target_dir")
                    if [ "$pdir" != "$root_dir" ] && [ -d "$pdir" ] && [ -z "$(find "$pdir" -mindepth 1 -type d 2>/dev/null)" ]; then
                      rm -rf "$pdir"
                    fi
                    ;;
                  *)
                    echo "Target at $target_dir does not match package \(token)" >&2; exit 1
                    ;;
                esac
              else
                echo "Directory \(location) not found or not in pkgx directory $pkgx_dir" >&2; exit 1
              fi
            else
              echo "pkgx directory not found" >&2; exit 1
            fi
            """
        case ("update", .uv) where package.summary == "uv-managed Python":
            command = "uv python install \(shellQuote(package.latestVersion ?? package.packageToken)) --color always"
        case ("uninstall", .uv) where package.summary == "uv-managed Python":
            command = "uv python uninstall \(shellQuote(package.installedVersion ?? package.packageToken)) --color always"
        case ("update", .uv): command = "uv tool upgrade \(token) --color always"
        case ("uninstall", .uv): command = "uv tool uninstall \(token) --color always"
        case ("uninstall", .cargoInstall): command = "cargo uninstall \(token) --color always"
        default: command = "echo 'This package action is not supported on Linux.' >&2; exit 64"
        }
        return "set -e; export PATH=\"$HOME/.bun/bin:$HOME/.local/bin:$HOME/bin:/usr/local/bin:/usr/bin:/usr/local/sbin:/usr/sbin:$PATH\"; \(command) 1>&2; printf '\\n__PMM_LINUX_ACTION_OK__\\n'"
    }

    private static let linuxUpdateAllScript = #"""
    set -e
    export PATH="$HOME/.bun/bin:$HOME/.local/bin:$HOME/bin:/usr/local/bin:/usr/bin:/usr/local/sbin:/usr/sbin:$PATH"
    [ ! -r /etc/os-release ] || . /etc/os-release
    manager=''
    case " ${ID:-} ${ID_LIKE:-} " in
      *" alpine "*) manager=apk ;;
      *" debian "*|*" ubuntu "*) manager=apt ;;
      *" suse "*) manager=zypper ;;
      *" fedora "*|*" rhel "*|*" centos "*|*" amzn "*) manager=dnf ;;
    esac
    if [ -z "$manager" ]; then
      if command -v dnf >/dev/null 2>&1; then manager=dnf
      elif command -v apt-get >/dev/null 2>&1; then manager=apt
      elif command -v zypper >/dev/null 2>&1; then manager=zypper
      elif command -v apk >/dev/null 2>&1; then manager=apk
      fi
    fi
    case "$manager" in
      apk) sudo -n apk -U upgrade 1>&2 ;;
      apt) sudo -n apt-get update 1>&2; sudo -n apt-get -y upgrade 1>&2 ;;
      dnf) sudo -n dnf -y upgrade 1>&2 ;;
      zypper) sudo -n zypper --non-interactive refresh 1>&2; sudo -n zypper --non-interactive update 1>&2 ;;
      *) echo 'No supported Linux system package manager was found.' >&2; exit 64 ;;
    esac
    printf '\n__PMM_LINUX_ACTION_OK__\n'
    """#

    private static func error(for result: CommandResult, host: RemoteHost) -> RemoteSSHError {
        let output = (result.stderr + "\n" + result.stdout).lowercased()
        if output.contains("host key verification failed")
            || output.contains("no host key is known")
            || output.contains("remote host identification has changed") {
            return .untrustedHost(host.destination)
        }
        if result.status == 255 && (output.contains("permission denied") || output.contains("authentication failed")) {
            return .authenticationFailed(host.destination)
        }
        if output.contains("package manager manager is not installed on this mac") {
            return .missingRemotePMM
        }
        let detail = (result.stderr.isEmpty ? result.stdout : result.stderr).trimmed
        return result.status == 255
            ? .connectionFailed(host.destination, detail)
            : .remoteCommandFailed(host.destination, detail)
    }
}

public enum RemoteHostError: LocalizedError, Equatable {
    case invalidDestination

    public var errorDescription: String? {
        "Enter an SSH host or alias without options or spaces, such as mac-mini or max@server."
    }
}

public enum RemoteSSHError: LocalizedError, Equatable {
    case authenticationFailed(String)
    case connectionFailed(String, String)
    case incompatibleProtocol
    case missingRemotePMM
    case remoteCommandFailed(String, String)
    case untrustedHost(String)

    public var errorDescription: String? {
        switch self {
        case .authenticationFailed(let host):
            "SSH authentication failed for \(host). Configure key or agent authentication first."
        case .connectionFailed(let host, let detail):
            detail.isEmpty ? "Could not connect to \(host) over SSH." : "Could not connect to \(host): \(detail)"
        case .incompatibleProtocol:
            "Update Package Manager Manager on the remote Mac."
        case .missingRemotePMM:
            "Package Manager Manager was not found in /Applications on the remote Mac."
        case .remoteCommandFailed(let host, let detail):
            detail.isEmpty ? "The command failed on \(host)." : "The command failed on \(host): \(detail)"
        case .untrustedHost(let host):
            "The SSH host key for \(host) is not trusted. Connect with ssh in Terminal once, verify the key, and try again."
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
