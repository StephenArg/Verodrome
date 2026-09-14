import SwiftUI
import VerodromeKit

struct DeveloperSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var accountStore: AccountStore

    @State private var isRerunningIdMigration = false
    @State private var idMigrationMessage: String?

    var body: some View {
        Form {
            Section("Diagnostics") {
                Toggle("Show Window Sizes", isOn: $settings.developerWindowSizes)
                    .onChange(of: settings.developerWindowSizes) { _, _ in settings.save() }
            }

            navidromeIdSection

            if settings.developerWindowSizes {
                Section("Window") {
                    GeometryReader { proxy in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Size: \(Int(proxy.size.width)) × \(Int(proxy.size.height))")
                            Text("Safe Area Top: \(Int(proxy.safeAreaInsets.top))")
                            Text("Safe Area Bottom: \(Int(proxy.safeAreaInsets.bottom))")
                        }
                        .font(.caption.monospaced())
                    }
                    .frame(height: 80)
                }
            }
        }
        .verodromePlainList()
        .navigationTitle("Developer")
    }

    @ViewBuilder
    private var navidromeIdSection: some View {
        let account = accountSettings
        Section {
            LabeledContent("Server") {
                Text(account?.serverTypeName ?? "unknown")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Version") {
                Text(account?.serverVersion ?? "unknown")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("IDs verified at") {
                Text(account?.canonicalIdsVerifiedAtVersion ?? "never")
                    .foregroundStyle(.secondary)
            }
            Button(isRerunningIdMigration ? "Re-checking…" : "Re-check Navidrome IDs") {
                rerunIdMigration()
            }
            .disabled(isRerunningIdMigration)
            if let idMigrationMessage {
                Text(idMigrationMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Navidrome IDs")
        } footer: {
            Text("Clears the local ID-verification marker (not the server type or version) and re-probes. Use this if the app thinks it already moved to 0.64 but library IDs were never rewritten. Downloads keep their files; only IDs and filenames are remapped.")
        }
    }

    private var accountSettings: AccountSettings? {
        guard let key = accountStore.activeAccountKey() else { return nil }
        return settings.loadAccountSettings(for: key)
    }

    private func rerunIdMigration() {
        isRerunningIdMigration = true
        idMigrationMessage = nil
        Task {
            defer {
                VerodromeKit.shared.dismissCanonicalIdMigrationOverlay()
                isRerunningIdMigration = false
            }
            await VerodromeKit.shared.presentCanonicalIdMigrationOverlay("Checking library IDs…")
            NavidromeIdMigrationHook.clearVerificationMarker(kit: .shared)
            _ = try? await VerodromeKit.shared.ensureActiveLibrarySyncer()
            let after = accountSettings
            idMigrationMessage = "Re-check finished. IDs verified at \(after?.canonicalIdsVerifiedAtVersion ?? "never"). See Event Log for details."
        }
    }
}
