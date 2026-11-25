import SwiftUI
import LogCore

/// The native Log tab. Placeholder until it's built: `isReady` is false, so the app keeps
/// showing the web version of this tab.
public struct LogScreen: View {
    /// Flip to true when this screen covers everything the web version does.
    public static let isReady = false

    @Environment(LogStore.self) private var store

    public init() {}

    public var body: some View {
        ScreenScaffold("Log") {
            LogCard("Log") { EmptyNote("The native Log screen is on its way.") }
        }
    }
}
