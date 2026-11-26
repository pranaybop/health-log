import SwiftUI
import UIKit
import LogCore

public enum NativeScreens {
    @MainActor
    public static func make(_ tab: String, store: LogStore = .shared) -> UIViewController? {
        let root: AnyView
        switch tab {
        case "today": root = AnyView(TodayScreen())
        case "meds": root = AnyView(MedsScreen())
        case "trends": root = AnyView(TrendsScreen())
        case "log": root = AnyView(LogScreen())
        default: return nil
        }
        let host = UIHostingController(rootView: AnyView(NavigationStack { root }.environment(store).tint(LogColor.link)))
        host.view.backgroundColor = .clear
        return host
    }

    /// The native lock screen, full screen over everything.
    @MainActor
    public static func makeLockScreen(store: LogStore = .shared) -> UIViewController {
        let host = UIHostingController(rootView: LockScreen().environment(store))
        host.modalPresentationStyle = .fullScreen
        return host
    }
}
