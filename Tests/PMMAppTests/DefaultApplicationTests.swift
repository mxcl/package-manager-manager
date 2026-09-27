import CoreServices
import Foundation
import Testing
@testable import PMMApp

@Test func defaultApplicationDetectsEditingAndShellRoles() {
    #expect(DefaultApplication.supportedKinds(documentTypes: [
        ["CFBundleTypeRole": "Editor", "LSItemContentTypes": ["public.plain-text"]],
    ]) == [.editor])
    #expect(DefaultApplication.supportedKinds(documentTypes: [
        ["CFBundleTypeRole": "Viewer", "LSItemContentTypes": ["public.plain-text"]],
        ["CFBundleTypeRole": "Editor", "LSItemContentTypes": ["public.png"]],
    ]).isEmpty)
    #expect(DefaultApplication.supportedKinds(documentTypes: [
        ["CFBundleTypeRole": "Editor", "CFBundleTypeExtensions": ["txt"]],
        ["CFBundleTypeRole": "Shell", "LSItemContentTypes": ["public.unix-executable"]],
    ]) == [.editor, .terminal])
}

@Test func defaultApplicationAssignsOnlyRequestedRolesAndReportsPartialFailures() throws {
    var assigned: [String] = []
    try DefaultApplication.assign(bundleID: "test.editor", kind: .editor, includeAdditional: false) { type, roles, bundle in
        #expect(roles == [.editor, .viewer])
        #expect(bundle == "test.editor")
        assigned.append(type)
        return noErr
    }
    #expect(assigned == ["public.text", "public.plain-text"])
    assigned = []
    #expect(throws: (any Error).self) {
        try DefaultApplication.assign(bundleID: "test.terminal", kind: .terminal, includeAdditional: true) { type, roles, _ in
            #expect(roles == .shell)
            assigned.append(type)
            return type == "public.unix-executable" ? -50 : noErr
        }
    }
    #expect(assigned.contains("com.apple.terminal.shell-script"))
    #expect(assigned.contains("public.zsh-script"))
    #expect(assigned.count == DefaultApplication.Kind.terminal.baseTypes.count + DefaultApplication.scriptTypes.count)
    assigned = []
    try DefaultApplication.assign(bundleID: "test.editor", kind: .editor, includeAdditional: true) { type, _, _ in
        assigned.append(type)
        return noErr
    }
    #expect(assigned.contains("net.daringfireball.markdown"))
    #expect(assigned.contains("public.swift-source"))
    #expect(!assigned.contains("public.mpeg-2-transport-stream"))
    #expect(Set(assigned).count == assigned.count)
}

@Test func defaultApplicationLoadsDirectAndHomebrewApps() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let app = root.appendingPathComponent("Editor.app")
    let contents = app.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let plist: [String: Any] = [
        "CFBundleIdentifier": "test.pmm.editor",
        "CFBundlePackageType": "APPL",
        "CFBundleDocumentTypes": [["CFBundleTypeRole": "Editor", "LSItemContentTypes": ["public.text"]]],
    ]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
    let direct = await DefaultApplication.load(path: app.path)
    #expect(direct?.bundleID == "test.pmm.editor")
    #expect(direct?.kinds.contains(.editor) == true)
    let cask = await DefaultApplication.load(path: root.path)
    #expect(cask?.bundleID == direct?.bundleID)
    #expect(await DefaultApplication.load(path: root.appendingPathComponent("Missing.app").path) == nil)
}
