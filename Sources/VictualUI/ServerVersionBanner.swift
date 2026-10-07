import SwiftUI

/// A one-line warning that the server is newer than the app.
///
/// Shown above the app's content, because the connection form that also reports
/// it is replaced the moment the connection succeeds.
public struct ServerVersionBanner: View {
    private let session: VictualSession

    public init(session: VictualSession) {
        self.session = session
    }

    public var body: some View {
        if let warning = session.serverVersionWarning {
            Label {
                Text(warning)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .font(.footnote)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Not `.bar`: that material is unavailable on tvOS and watchOS, which this
            // target also builds for.
            .background(Color.secondary.opacity(0.15))
        }
    }
}
