import SwiftUI
import VerodromeKit

struct AccountSettingsView: View {
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var themeManager: ThemeManager
    @State private var showLogoutConfirm = false
    @State private var accountPendingRemoval: StoredAccount?
    @State private var showAddAccount = false
    @State private var isSwitching = false

    private var accounts: [StoredAccount] { account.allAccounts() }
    private var activeKey: AccountInfo.Key? { account.activeAccountKey() }

    var body: some View {
        Form {
            Section("Accounts") {
                ForEach(accounts, id: \.info.id) { stored in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(stored.info.username).fontWeight(.semibold)
                            Text(stored.info.serverURL)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if stored.info.key == activeKey {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard stored.info.key != activeKey else { return }
                        Task { await switchAccount(stored.info) }
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) {
                            accountPendingRemoval = stored
                        }
                    }
                }

                Button {
                    showAddAccount = true
                } label: {
                    Label("Add Account", systemImage: "plus.circle")
                }
            }

            if let credentials = account.credentials {
                Section("Active Server") {
                    LabeledContent("URL", value: credentials.serverURL)
                    LabeledContent("Username", value: credentials.username)
                    if let api = account.detectedApiType {
                        LabeledContent("API", value: api.displayName)
                    }
                    Toggle(
                        "Auto-cache Newest",
                        isOn: Binding(
                            get: {
                                guard let key = activeKey else { return false }
                                return settings.loadAccountSettings(for: key).autoCacheNewest
                            },
                            set: { newValue in
                                guard let key = activeKey else { return }
                                var accountSettings = settings.loadAccountSettings(for: key)
                                accountSettings.autoCacheNewest = newValue
                                settings.saveAccountSettings(accountSettings, for: key)
                                VerodromeKit.shared.observableSettings.reload(accountKey: key)
                            }
                        )
                    )
                }

                Section("Theme Color") {
                    ColorPicker(
                        "Accent Color",
                        selection: Binding(
                            get: {
                                if let key = activeKey,
                                   let hex = settings.loadAccountSettings(for: key).themeColorHex,
                                   let color = Color(hex: hex) {
                                    return color
                                }
                                return themeManager.accentColor
                            },
                            set: { themeManager.setAccountThemeColor($0) }
                        ),
                        supportsOpacity: false
                    )
                    Button("Reset to Default") {
                        themeManager.setAccountThemeColor(nil)
                    }
                }
            }

            Section {
                Button("Log Out", role: .destructive) {
                    showLogoutConfirm = true
                }
            }
        }
        .navigationTitle("Account")
        .disabled(isSwitching)
        .confirmationDialog("Log out of Verodrome?", isPresented: $showLogoutConfirm) {
            Button("Log Out", role: .destructive) {
                account.logout()
                settings.isLibrarySynced = false
                settings.save()
            }
        }
        .confirmationDialog(
            "Remove this account?",
            isPresented: Binding(
                get: { accountPendingRemoval != nil },
                set: { if !$0 { accountPendingRemoval = nil } }
            )
        ) {
            Button("Remove", role: .destructive) {
                if let pending = accountPendingRemoval {
                    Task { await VerodromeKit.shared.removeAccount(pending.info) }
                }
                accountPendingRemoval = nil
            }
        }
        .sheet(isPresented: $showAddAccount) {
            NavigationStack {
                LoginView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showAddAccount = false }
                        }
                    }
            }
        }
    }

    @MainActor
    private func switchAccount(_ info: AccountInfo) async {
        isSwitching = true
        defer { isSwitching = false }
        try? await VerodromeKit.shared.switchToAccount(info)
    }
}
