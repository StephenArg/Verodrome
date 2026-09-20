import SwiftUI
import VerodromeKit

struct LoginView: View {
    @EnvironmentObject private var account: AccountStore
    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var errorTitle = "Connection Failed"
    @State private var detectedAPI: ApiType?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Server URL", text: $serverURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .onChange(of: serverURL) { _, newValue in
                            Task { detectedAPI = await account.detectApiType(for: newValue) }
                        }

                    if let detectedAPI {
                        LabeledContent("Detected API") {
                            Text(detectedAPI.displayName).foregroundStyle(.secondary)
                        }
                    }

                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SecureField("Password", text: $password)
                } header: {
                    Text("Connect to your library")
                } footer: {
                    Text("Verodrome works with Subsonic-compatible servers including Navidrome and Ampache.")
                }

                Section {
                    Button { connect() } label: {
                        HStack {
                            Spacer()
                            if isConnecting { ProgressView().padding(.trailing, 8) }
                            Text(isConnecting ? "Connecting…" : "Connect").fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(isConnecting || serverURL.isEmpty || username.isEmpty)
                }
            }
            .navigationTitle("Welcome")
            .alert(errorTitle, isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
            .onAppear {
                if let creds = account.credentials {
                    serverURL = creds.serverURL
                    username = creds.username
                } else if let prefill = account.loginPrefill {
                    serverURL = prefill.serverURL
                    username = prefill.username
                }
                if let message = account.consumeLastError() {
                    errorTitle = "Signed Out"
                    errorMessage = message
                    showError = true
                }
            }
        }
    }

    private func connect() {
        isConnecting = true
        Task {
            do {
                try await account.login(serverURL: serverURL, username: username, password: password)
            } catch {
                errorTitle = "Connection Failed"
                errorMessage = error.localizedDescription
                showError = true
            }
            isConnecting = false
        }
    }
}
