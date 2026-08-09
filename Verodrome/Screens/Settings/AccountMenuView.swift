import SwiftUI
import VerodromeKit

/// Compact account switcher shown from Home's person button.
struct AccountMenuView: View {
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
        VStack(alignment: .leading, spacing: 0) {
            Text("Accounts")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)

            ForEach(accounts, id: \.info.id) { stored in
                accountRow(stored)
            }

            menuButton("Add Account", systemImage: "plus.circle") {
                showAddAccount = true
            }

            Divider().padding(.vertical, 6)

            if activeKey != nil {
                Toggle(isOn: autoCacheBinding) {
                    Label("Auto-cache Newest", systemImage: "arrow.down.circle")
                        .font(.body)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                HStack {
                    Label("Accent Color", systemImage: "paintpalette")
                        .font(.body)
                    Spacer(minLength: 12)
                    ColorPicker(
                        "",
                        selection: accentColorBinding,
                        supportsOpacity: false
                    )
                    .labelsHidden()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                menuButton("Reset Accent Color", systemImage: "arrow.uturn.backward") {
                    themeManager.setAccountThemeColor(nil)
                }

                Divider().padding(.vertical, 6)
            }

            Button(role: .destructive) {
                showLogoutConfirm = true
            } label: {
                Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 8)
        }
        .frame(minWidth: 280, idealWidth: 300)
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

    @ViewBuilder
    private func accountRow(_ stored: StoredAccount) -> some View {
        let isActive = stored.info.key == activeKey
        Button {
            guard !isActive else { return }
            Task { await switchAccount(stored.info) }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(stored.info.username)
                        .font(.body.weight(isActive ? .semibold : .regular))
                        .foregroundStyle(.primary)
                    Text(stored.info.serverURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !isActive {
                Button("Remove", role: .destructive) {
                    accountPendingRemoval = stored
                }
            }
        }
    }

    private func menuButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var autoCacheBinding: Binding<Bool> {
        Binding(
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
    }

    private var accentColorBinding: Binding<Color> {
        Binding(
            get: {
                if let key = activeKey,
                   let hex = settings.loadAccountSettings(for: key).themeColorHex,
                   let color = Color(hex: hex) {
                    return color
                }
                return themeManager.accentColor
            },
            set: { themeManager.setAccountThemeColor($0) }
        )
    }

    @MainActor
    private func switchAccount(_ info: AccountInfo) async {
        isSwitching = true
        defer { isSwitching = false }
        try? await VerodromeKit.shared.switchToAccount(info)
    }
}

/// Leading Home control — circle with a person silhouette; opens the account menu.
struct HomeAccountButton: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @State private var showMenu = false

    var body: some View {
        Button {
            showMenu = true
        } label: {
            Image(systemName: "person.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(themeManager.accentColor)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color(uiColor: .secondarySystemFill)))
                .overlay {
                    Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Accounts")
        .popover(isPresented: $showMenu, arrowEdge: .top) {
            AccountMenuView()
                .presentationCompactAdaptation(.popover)
        }
    }
}
