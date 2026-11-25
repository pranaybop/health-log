import SwiftUI
import LogCore

/// The tirzepatide → retatrutide switch card (web: renderSwitchCard in focus.js). Meds shows it in
/// its list; Today shows it on today's page.
///
/// Owned by the Meds & Log stage, which replaces this placeholder body. Keep `init()`, and draw
/// nothing when the web version would show nothing (it returns null).
public struct SwitchCard: View {
    public init() {}

    public var body: some View {
        EmptyView()
    }
}
