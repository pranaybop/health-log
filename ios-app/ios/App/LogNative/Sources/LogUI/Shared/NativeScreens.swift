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

    /// Sign-in, then first-run setup for a new account, full screen over everything.
    @MainActor
    public static func makeLockScreen(store: LogStore = .shared) -> UIViewController {
        let host = UIHostingController(rootView: GateView().environment(store).tint(LogColor.link))
        host.modalPresentationStyle = .fullScreen
        return host
    }

    /// The Face ID cover shown when coming back to the app (Account > Require Face ID).
    @MainActor
    public static func makeAppLock(onUnlock: @escaping () -> Void) -> UIViewController {
        let host = UIHostingController(rootView: AppLockCover(onUnlock: onUnlock))
        host.modalPresentationStyle = .overFullScreen
        return host
    }
}
