import SwiftUI
import LogCore

/// The native Meds tab. Placeholder until it's built: `isReady` is false, so the app keeps
/// showing the web version of this tab.
public struct MedsScreen: View {
    /// Flip to true when this screen covers everything the web version does.
    public static let isReady = false

    @Environment(LogStore.self) private var store

    public init() {}

    public var body: some View {
        ScreenScaffold("Meds") {
            LogCard("Meds") { EmptyNote("The native Meds screen is on its way.") }
        }
    }
}
