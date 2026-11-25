import SwiftUI
import LogCore

/// The native Today tab. Placeholder until it's built: `isReady` is false, so the app keeps
/// showing the web version of this tab.
public struct TodayScreen: View {
    /// Flip to true when this screen covers everything the web version does.
    public static let isReady = true

    @Environment(LogStore.self) private var store

    public init() {}

    public var body: some View {
        ScreenScaffold("Today") {
            LogCard("Today") { EmptyNote("The native Today screen is on its way.") }
        }
    }
}
