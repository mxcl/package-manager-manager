import PMMCore
import SwiftUI

struct NativeCaskSettingsView: View {
    @State private var enabled = false
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var error: String?
    private let store = PackagePreferencesStore()

    var body: some View {
        Form {
            if isLoading {
                ProgressView("Loading settings…")
            } else {
                Toggle("Manage apps without Homebrew", isOn: Binding(get: { enabled }, set: save))
                    .disabled(isSaving)
                Text("Install apps and manage recognized direct-download apps automatically with PMM. Existing Homebrew installs stay managed by Homebrew. Turning this off keeps PMM apps visible as read-only.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if isSaving { ProgressView("Saving…") }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 470, height: 220)
        .task {
            enabled = await Task.detached { store.load().nativeCaskManagementEnabled }.value
            isLoading = false
        }
    }

    private func save(_ value: Bool) {
        isSaving = true
        error = nil
        Task {
            do {
                try await store.setNativeCaskManagementEnabled(value)
                enabled = value
            } catch { self.error = error.localizedDescription }
            isSaving = false
        }
    }
}
