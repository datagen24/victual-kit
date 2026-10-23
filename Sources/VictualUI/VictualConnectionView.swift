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

    /// Whether the Cloudflare Access fields are showing. Most instances never
    /// need them, so they start folded away unless a token is already entered.
    @State private var showsEdgeFields = false

    public init(session: VictualSession, onConnected: (() -> Void)? = nil) {
        self._session = Bindable(session)
        self.onConnected = onConnected
    }

    public var body: some View {
        Form {
            Section {
                addressField
                apiKeyField
            } header: {
                Text("Instance")
            } footer: {
                Text("Create an API key in your Victual instance under Settings › Manage API keys.")
            }

            edgeSection

            Section {
                Button(action: session.connect) {
                    if session.state.isConnecting {
                        ProgressView()
                    } else {
                        Text("Connect")
                    }
                }
                .disabled(!session.canConnect)

                // An unreachable host takes the request timeout to fail; the
                // user should not have to sit through it.
                if session.state.isConnecting {
                    Button("Cancel", role: .cancel, action: session.disconnect)
                }
            }

            statusSection
            credentialStorageSection
        }
        .onChange(of: session.state.isConnected) { _, isConnected in
            if isConnected { onConnected?() }
        }
        .onAppear {
            if !session.edgeClientIDText.isEmpty { showsEdgeFields = true }
        }
        .onChange(of: session.edgeClientIDText.isEmpty) { _, isEmpty in
            // A restore fills the fields after the form is already showing.
            if !isEmpty { showsEdgeFields = true }
        }
        .onChange(of: session.state.error == .edgeAccessRequired) { _, needsToken in
            if needsToken { showsEdgeFields = true }
        }
    }

    /// The service token for an instance behind Cloudflare Access.
    ///
    /// Folded with a plain button rather than a `DisclosureGroup`, which
    /// watchOS does not have.
    private var edgeSection: some View {
        Section {
            Button {
                showsEdgeFields.toggle()
            } label: {
                LabeledContent("Cloudflare Access") {
                    Image(systemName: showsEdgeFields ? "chevron.down" : "chevron.right")
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityValue(showsEdgeFields ? "Shown" : "Hidden")
            if showsEdgeFields {
                edgeClientIDField
                edgeClientSecretField
            }
        } footer: {
            if showsEdgeFields {
                Text("Only for a server behind Cloudflare Access. Its administrator issues a service token for this device.")
            }
        }
    }

    @ViewBuilder
    private var edgeClientIDField: some View {
        let field = TextField("Client ID", text: $session.edgeClientIDText)
            .disabled(session.state.isConnecting)
        #if os(iOS) || os(visionOS)
            field
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        #else
            field.autocorrectionDisabled()
        #endif
    }

    /// Masked, with the same way to empty it as the API key field.
    private var edgeClientSecretField: some View {
        HStack {
            SecureField("Client Secret", text: $session.edgeClientSecretText)
                .autocorrectionDisabled()
                .disabled(session.state.isConnecting)
            if !session.edgeClientSecretText.isEmpty && !session.state.isConnecting {
                Button {
                    session.edgeClientSecretText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Clear Client Secret")
            }
        }
    }

    /// The key field, with a way to empty it.
    ///
    /// A secure field cannot be selected into and the key it holds is masked,
    /// so after a disconnect a person had no way to replace it: typing and
    /// pasting both append. The button empties it.
    private var apiKeyField: some View {
        HStack {
            keyField
                .disabled(session.state.isConnecting)
            if !session.apiKeyText.isEmpty && !session.state.isConnecting {
                Button {
                    session.apiKeyText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Clear API key")
            }
        }
    }

    /// A standard secure field.
    ///
    /// iOS may offer to save what is typed here as a password. That is left
    /// in place: content types and showing the field only while typing did not
    /// stop it in the simulator, and whether a device offers it is unchecked.
    @ViewBuilder
    private var keyField: some View {
        let field = SecureField("API key", text: $session.apiKeyText)
        #if os(iOS) || os(visionOS)
            field
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        #else
            field.autocorrectionDisabled()
        #endif
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
                if let warning = information.versionWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
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
                Text("Disconnecting keeps the API key in the Keychain. Forgetting removes it, and any Cloudflare Access token.")
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
