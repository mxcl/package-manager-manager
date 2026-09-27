import AppKit
import CoreServices
import SwiftUI
import UniformTypeIdentifiers

struct DefaultApplication: Sendable {
    let bundleID: String
    let kinds: [Kind]

    enum Kind: String, CaseIterable, Sendable {
        case editor, terminal

        var roles: LSRolesMask { self == .editor ? [.editor, .viewer] : .shell }
        var baseTypes: [String] {
            self == .editor ? ["public.text", "public.plain-text"] : ["public.unix-executable", "com.apple.terminal.shell-script"]
        }
        var additionalTypes: [String] {
            if self == .terminal { return DefaultApplication.scriptTypes }
            return DefaultApplication.textTypes
        }
    }

    // Launch Services role assignments and programmer formats follow teaBASE's
    // Sources/teaBASE+DevTools.m. Keep editor/viewer and shell roles separate.
    static let scriptTypes = [
        "public.shell-script", "public.bash-script", "public.csh-script",
        "public.ksh-script", "public.tcsh-script", "public.zsh-script",
        "public.python-script", "public.ruby-script", "public.perl-script", "public.php-script",
    ]
    static let textTypes = [
        "public.source-code", "public.swift-source", "public.geojson", "public.protobuf-source",
        "com.apple.property-list", "com.apple.xml-property-list", "com.apple.ascii-property-list",
        "public.c-header", "public.c-plus-plus-header", "public.c-source", "public.c-source.preprocessed",
        "public.opencl-source", "public.module-map", "public.objective-c-source",
        "public.objective-c-source.preprocessed", "public.objective-c-plus-plus-source",
        "public.objective-c-plus-plus-source.preprocessed", "public.c-plus-plus-source",
        "public.c-plus-plus-source.preprocessed", "public.assembly-source", "public.nasm-assembly-source",
        "public.yacc-source", "public.lex-source", "public.mig-source", "public.make-source",
        "public.xml", "net.daringfireball.markdown", "public.json", "public.json.jsonc", "public.yaml",
        "public.css", "com.microsoft.typescript", "org.python.restructuredtext", "org.lua.lua-source",
        "com.netscape.javascript-source", "org.rust-lang.rust-script", "org.rust-lang.rust", "public.html",
        "org.golang.go-script", "public.comma-separated-values-text", "org.iso.sql", "com.sun.java-source",
        "com.microsoft.c-sharp", "org.tug.tex", "public.toml", "com.microsoft.ini", "public.patch-file",
        "dev.dart.dart-script",
        // Unlike teaBASE, do not claim MPEG transport streams just to capture .ts.
    ] + scriptTypes

    static func supportedKinds(documentTypes: [[String: Any]]) -> [Kind] {
        Kind.allCases.filter { kind in
            documentTypes.contains { document in
                let role = document["CFBundleTypeRole"] as? String
                let identifiers = document["LSItemContentTypes"] as? [String] ?? []
                if kind == .terminal { return role == "Shell" }
                guard role == "Editor" else { return false }
                let extensions = document["CFBundleTypeExtensions"] as? [String] ?? []
                return identifiers.contains { UTType($0)?.conforms(to: .text) == true || textTypes.contains($0) }
                    || extensions.contains { UTType(filenameExtension: $0)?.conforms(to: .text) == true }
            }
        }
    }

    @concurrent static func load(path: String) async -> DefaultApplication? {
        var root = URL(fileURLWithPath: path)
        if root.pathExtension.lowercased() == "app" { return inspect(root) }
        // A self-update can change the reported version without moving Homebrew's app link.
        if !FileManager.default.fileExists(atPath: root.path),
           root.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Caskroom" {
            root.deleteLastPathComponent()
        }
        // Cask dossiers point at a versioned Caskroom directory, containing app symlinks.
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        while let url = entries.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "app" else { continue }
            entries.skipDescendants()
            if let application = inspect(url), !application.kinds.isEmpty { return application }
        }
        return nil
    }

    private static func inspect(_ url: URL) -> DefaultApplication? {
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return nil }
        var kinds = supportedKinds(documentTypes: bundle.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]] ?? [])
        for kind in Kind.allCases where !kinds.contains(kind) {
            let handlers = LSCopyAllRoleHandlersForContentType(kind.baseTypes[0] as CFString, kind == .editor ? .editor : .shell)?.takeRetainedValue() as? [String] ?? []
            if handlers.contains(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame }) { kinds.append(kind) }
        }
        return DefaultApplication(bundleID: bundleID, kinds: kinds)
    }

    @concurrent func setDefault(kind: Kind, includeAdditional: Bool) async throws {
        try Self.assign(bundleID: bundleID, kind: kind, includeAdditional: includeAdditional) { type, roles, bundle in
            LSSetDefaultRoleHandlerForContentType(type as CFString, roles, bundle as CFString)
        }
    }

    static func assign(bundleID: String, kind: Kind, includeAdditional: Bool,
                       setHandler: (String, LSRolesMask, String) -> OSStatus) throws {
        let types = kind.baseTypes + (includeAdditional ? kind.additionalTypes : [])
        var failures: [String] = []
        for type in types {
            let status = setHandler(type, kind.roles, bundleID)
            if status != noErr { failures.append("\(type) (\(status))") }
        }
        if !failures.isEmpty {
            throw NSError(domain: NSOSStatusErrorDomain, code: -1, userInfo: [NSLocalizedDescriptionKey:
                "Some associations could not be changed: \(failures.joined(separator: ", ")). Other associations may have been updated."])
        }
    }
}

struct DefaultApplicationSection: View {
    let path: String
    @State private var application: DefaultApplication?
    @State private var isLoading = true
    @State private var isApplying = false
    @State private var message: String?
    @State private var error: String?

    var body: some View {
        Group {
            if isLoading {
                InfoSection(title: "Default App") {
                    ProgressView("Checking default app support…").controlSize(.small)
                }
            } else if let application, !application.kinds.isEmpty {
                InfoSection(title: "Default App") {
                    ForEach(application.kinds, id: \.self) { kind in
                        Button(kind == .editor ? "Set as Default Text Editor" : "Set as Default Terminal") {
                            apply(application, kind: kind, additional: false)
                        }
                        Button(kind == .editor ? "Use for All Other Text Formats" : "Use for All Other Script Formats") {
                            apply(application, kind: kind, additional: true)
                        }
                        .help(kind == .editor ? "Also assigns source code, markup, configuration and script formats to this editor." : "Also assigns shell and interpreter script formats to this terminal.")
                    }
                    .disabled(isApplying)
                    if isApplying { ProgressView("Updating defaults…").controlSize(.small) }
                    if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
                    if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                }
            }
        }
        .task(id: path) {
            isLoading = true
            application = nil
            message = nil
            error = nil
            let result = await DefaultApplication.load(path: path)
            guard !Task.isCancelled else { return }
            application = result
            isLoading = false
        }
    }

    private func apply(_ application: DefaultApplication, kind: DefaultApplication.Kind, additional: Bool) {
        isApplying = true
        message = nil
        error = nil
        Task {
            defer { isApplying = false }
            do {
                try await application.setDefault(kind: kind, includeAdditional: additional)
                message = additional ? "Default app and additional formats updated." : "Default app updated."
            } catch { self.error = error.localizedDescription }
        }
    }
}
