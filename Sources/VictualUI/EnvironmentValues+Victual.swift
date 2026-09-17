import SwiftUI

extension EnvironmentValues {
    /// The Victual session for the surrounding view hierarchy.
    ///
    /// `nil` until a view calls ``SwiftUI/View/victualSession(_:)``, which lets a
    /// view distinguish "no session installed" from "session not connected".
    @Entry public var victualSession: VictualSession?
}

extension View {
    /// Makes `session` available to this view and its descendants.
    public func victualSession(_ session: VictualSession) -> some View {
        environment(\.victualSession, session)
    }
}
