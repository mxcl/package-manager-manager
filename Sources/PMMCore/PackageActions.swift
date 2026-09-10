import Foundation

/// Shared execution entry point for the menu bar host and SSH helper.
public enum PackageActions {
    public static func canUpdate(_ package: ManagedPackage, nativeEnabled: Bool) -> Bool {
        NativeCaskManager.supportsDirectUpdate(package) || (usesNativeManagement(package) ? nativeEnabled && package.isOutdated : PackageUpdater.supports(package))
    }

    public static func canUninstall(_ package: ManagedPackage, nativeEnabled: Bool) -> Bool {
        usesNativeManagement(package) ? nativeEnabled && package.installedVersion != nil : PackageUninstaller.supports(package)
    }

    public static func usesNativeManagement(_ package: ManagedPackage) -> Bool {
        package.nativeCaskInstallation != nil || canAdopt(package)
    }

    public static func canAdopt(_ package: ManagedPackage) -> Bool {
        package.manager == .macApp && package.appProvenance == .direct && package.nativeCaskInstallation == nil
            && package.installedVersion != nil && package.installLocation != nil && package.bundleIdentifier != nil
            && token(for: package) != nil
    }

    private static func token(for package: ManagedPackage) -> String? { NativeCaskManager.token(for: package) }

    public static func perform(_ kind: PackageHostActionKind, package: ManagedPackage,
                               onProgress: (@Sendable (PackageCommandProgress) -> Void)? = nil) async throws {
        if kind == .update {
            try await nativeCaskWork { try PackageUpdater.requireAppsClosed(package) }
            if NativeCaskManager.supportsDirectUpdate(package) {
                try await NativeCaskManager().updateDirectApp(package, onProgress: onProgress)
                return
            }
        }
        let enabled = try await nativeCaskWork { PackagePreferencesStore().load().nativeCaskManagementEnabled }
        let native = NativeCaskManager()
        if usesNativeManagement(package) || kind == .adopt {
            try await native.perform(kind, package: package, onProgress: onProgress)
            return
        }
        if kind == .install, enabled, let token = NativeCaskManager.token(for: package) {
            do { _ = try await native.recipe(for: token) }
            catch {
                let brew = try await nativeCaskWork { firstExecutable(named: "brew") }
                guard brew != nil else { throw error }
                onProgress?(.output("Native installation unavailable: \(error.localizedDescription)\nUsing Homebrew.\n"))
                try await nativeCaskWork { try PackageInstaller().install(package, onProgress: onProgress) }
                return
            }
            try await native.perform(.install, package: package, onProgress: onProgress)
            return
        }
        try await nativeCaskWork {
            switch kind {
            case .install: try PackageInstaller().install(package, onProgress: onProgress)
            case .update: try PackageUpdater().update(package, onProgress: onProgress)
            case .uninstall: try PackageUninstaller().uninstall(package, onProgress: onProgress)
            case .adopt: throw NativeCaskError("Enable native cask management before adopting apps.")
            }
        }
    }
}
