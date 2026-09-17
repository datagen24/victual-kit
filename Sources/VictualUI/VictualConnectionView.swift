import SwiftUI
import VictualCore

/// A ready-made sign-in form for a Victual instance.
///
/// Apps that want their own connection UI can ignore this and drive
/// ``VictualSession`` directly; it is here so a new front end has something that
/// works on day one, on every Apple platform.
public struct VictualConnectionView: View {
    @Bindable private var session: VictualSession

    /// Runs once the session reaches `.connected`.
    private let onConnected: (() -> Void)?

    public init(session: VictualSession, onConnected: (() -> Void)? = nil) {
        self._session = Bindable(session)
        self.onConnected = onConnected
    }

    public var body: some View {
        Form {
            Section {
                addressField
                SecureField("API key", text: $session.apiKeyText)
                    .disabled(session.state.isConnecting)
            } header: {
                Text("Instance")
            } footer: {
                Text("Create an API key in your Victual instance under Settings › Manage API keys.")
            }

            Section {
                Button(action: session.connect) {
                    if session.state.isConnecting {
                        ProgressView()
                    } else {
                        Text("Connect")
                    }
                }
                .disabled(!session.canConnect)
            }

            statusSection
            credentialStorageSection
        }
        .onChange(of: session.state.isConnected) { _, isConnected in
            if isConnected { onConnected?() }
        }
    }

    @ViewBuilder
    private var addressField: some View {
        let field = TextField("victual.example.com", text: $session.serverText)
            .disabled(session.state.isConnecting)
        #if os(iOS) || os(visionOS)
            field
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        #else
            field.autocorrectionDisabled()
        #endif
    }

    /// Surfaced separately from the connection error: a key that could not be
    /// saved does not stop the session working, it just will not come back.
    @ViewBuilder
    private var credentialStorageSection: some View {
        if let error = session.credentialStoreError {
            Section {
                Label(
                    error.errorDescription ?? "The API key could not be saved.",
                    systemImage: "key.slash"
                )
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch session.state {
        case .connected(let information):
            Section {
                LabeledContent("Victual", value: information.victualVersion ?? "unknown")
                if let engine = information.databaseEngine {
                    LabeledContent("Database", value: engine)
                }
                Button("Disconnect", action: session.disconnect)
                Button("Forget this instance", role: .destructive) {
                    Task { await session.signOut() }
                }
            } header: {
                Text("Connected")
            } footer: {
                Text("Disconnecting keeps the API key in the Keychain. Forgetting removes it.")
            }
        case .failed(let error):
            Section {
                Label(
                    error.errorDescription ?? "Could not connect.",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.red)
            }
        case .disconnected, .connecting:
            EmptyView()
        }
    }
}

#Preview {
    VictualConnectionView(
        session: VictualSession(
            serverText: "victual.example.com",
            credentialStore: InMemoryCredentialStore()
        )
    )
}
