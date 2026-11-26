import SwiftUI
import UIKit
import LogCore

/// Which tabs are native yet, and the view controller for each. The shell (LogShell.swift in the
/// app) asks here: a tab that isn't ready keeps showing the web version.
///
/// Each screen flips its own `isReady` in its own file (Today/, Meds/, Log/, Trends/), so the
/// stages can land independently.
public enum NativeScreens {
    public static func isReady(_ tab: String) -> Bool {
        switch tab {
        case "today": return TodayScreen.isReady
        case "meds": return MedsScreen.isReady
        case "trends": return TrendsScreen.isReady
        case "log": return LogScreen.isReady
        default: return false
        }
    }

    /// True once any tab is native (then the lock screen is native too).
    public static var anyReady: Bool { ["today", "meds", "trends", "log"].contains(where: isReady) }

    @MainActor
    public static func make(_ tab: String, store: LogStore = .shared) -> UIViewController? {
        guard isReady(tab) else { return nil }
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
