import UIKit
import WebKit
import Capacitor
import LogCore
import LogUI
import LogHealth

// The native shell around Log's screens (going native in stages, from 1.2).
//
// - A native UITabBarController with the four tabs (Liquid Glass with the iOS 26 SDK).
// - Each tab shows its native SwiftUI screen once that screen is ready (the LogNative package,
//   NativeScreens.isReady). Until then it shows the web version, from one Capacitor web view that
//   moves between those tabs, so nothing reloads.
// - The passcode lives in the Keychain (LogCore.PasscodeStore). With any native screen on, the lock
//   screen is native too, and locking or unlocking on either side keeps the other in step.
// - Apple Health sync runs natively once NativeHealthSync.isReady; the web sync then turns itself off
//   (window.LOG_NATIVE.healthSync).
// - The page talks to the shell through `window.webkit.messageHandlers.logShell` (with replies), and
//   learns it's inside the shell from `window.LOG_NATIVE`, set before any of its scripts run.

enum LogTab: Int, CaseIterable {
    case today, meds, trends, log

    var id: String { ["today", "meds", "trends", "log"][rawValue] }
    var title: String { ["Today", "Meds", "Trends", "Log"][rawValue] }
    var symbol: String {
        switch self {
        case .today: return "calendar"
        case .meds: return "syringe"
        case .trends: return "chart.xyaxis.line"
        case .log: return "plus.circle"
        }
    }
}

// MARK: - Messages from the page

@MainActor
final class ShellMessages: NSObject, WKScriptMessageHandlerWithReply {
    weak var shell: ShellTabBarController?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else {
            replyHandler(nil, "bad message")
            return
        }
        switch type {
        case "tab":
            shell?.select(tabId: body["tab"] as? String ?? "")
            replyHandler(true, nil)
        case "locked":
            shell?.webLockChanged(body["locked"] as? Bool ?? false)
            replyHandler(true, nil)
        case "getPasscode":
            replyHandler(PasscodeStore.read() ?? "", nil)
        case "setPasscode":
            if let code = body["passcode"] as? String, !code.isEmpty { PasscodeStore.write(code) }
            shell?.keychainChanged()
            replyHandler(true, nil)
        case "clearPasscode":
            PasscodeStore.clear()
            shell?.keychainChanged()
            replyHandler(true, nil)
        case "syncHealth":
            // Pull to refresh on a web tab, with the native Apple Health sync on: last 2 days.
            guard let sync = LogStore.shared.healthSync, !LogStore.shared.isDemo else {
                replyHandler(false, nil)
                return
            }
            Task { @MainActor in
                await sync(2)
                replyHandler(true, nil)
            }
        default:
            replyHandler(nil, "unknown message \(type)")
        }
    }
}

// MARK: - The web view (for tabs that aren't native yet)

final class LogBridgeViewController: CAPBridgeViewController {
    let messages = ShellMessages()

    override func capacitorDidLoad() {
        super.capacitorDidLoad()
        // Behind the page (and under the glass tab bar), follow light and dark mode instead of black.
        if let webView = webView {
            webView.isOpaque = false
            webView.backgroundColor = .systemGroupedBackground
            webView.scrollView.backgroundColor = .systemGroupedBackground
            webView.underPageBackgroundColor = .systemGroupedBackground
        }
        guard let controller = webView?.configuration.userContentController else { return }
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? ""
        let source = "window.LOG_NATIVE = Object.freeze({ tabs: true, keychain: true, healthSync: \(NativeHealthSync.isReady), version: \(jsString(version)), build: \(jsString(build)) });"
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addScriptMessageHandler(messages, contentWorld: .page, name: "logShell")
        #if DEBUG
        // For the simulator check in CI: "-demo <tab>" opens made-up data (demo.json) on that tab.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-demo") {
            let tab = i + 1 < args.count ? args[i + 1] : "today"
            controller.addUserScript(WKUserScript(source: "window.LOG_DEMO = { tab: \(jsString(tab)) };", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        #endif
    }

    private func jsString(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"\"]".utf8)
        let array = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }

    func run(_ script: String) {
        webView?.evaluateJavaScript(script, completionHandler: nil)
    }
}

/// A tab whose screen is still the web version: the shared web view moves in when it's picked.
final class WebHost: UIViewController {}

// MARK: - Tabs

final class ShellTabBarController: UITabBarController, UITabBarControllerDelegate {
    private var store: LogStore { LogStore.shared }
    private var hosts: [UIViewController] = []
    private var bridge: LogBridgeViewController?
    private weak var lockScreen: UIViewController?
    /// With any native screen, the lock screen is native as well.
    private var nativeLock: Bool { NativeScreens.anyReady }

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        view.backgroundColor = .systemGroupedBackground

        hosts = LogTab.allCases.map { tab in
            let host = NativeScreens.make(tab.id, store: store) ?? WebHost()
            host.view.backgroundColor = .systemGroupedBackground
            let image = UIImage(systemName: tab.symbol) ?? UIImage(systemName: "circle")
            host.tabBarItem = UITabBarItem(title: tab.title, image: image, tag: tab.rawValue)
            return host
        }
        setViewControllers(hosts, animated: false)
        tabBar.tintColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.36, green: 0.83, blue: 0.72, alpha: 1)
                : UIColor(red: 0.06, green: 0.48, blue: 0.41, alpha: 1)
        }
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            tabBarMinimizeBehavior = .onScrollDown
        }
        #endif

        if NativeHealthSync.isReady {
            store.healthSync = { days in _ = await NativeHealthSync.shared.sync(days: days) }
        }
        store.onLockChange = { [weak self] locked in self?.nativeLockChanged(locked) }
        ReminderScheduler.shared.bind()

        var start = 0
        #if DEBUG
        if let demo = store.demoTab, let tab = LogTab.allCases.first(where: { $0.id == demo }) { start = tab.rawValue }
        #endif
        selectedIndex = start

        // The web view loads up front while any tab still uses it.
        if let firstWeb = hosts.first(where: { $0 is WebHost }) {
            embedBridge(in: hosts[start] is WebHost ? hosts[start] : firstWeb)
        } else if !NativeHealthSync.isReady {
            // Every screen is native but Apple Health still syncs through the web app: keep it, hidden.
            let b = webBridge()
            addChild(b)
            b.view.isHidden = true
            view.insertSubview(b.view, at: 0)
            b.didMove(toParent: self)
        }
        if nativeLock {
            Task { await store.start() }
            // Like the web app: refresh every minute while open, and on coming back to the app
            // (with an Apple Health catch-up when the native sync is on).
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
            center.addObserver(self, selector: #selector(appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
            center.addObserver(self, selector: #selector(appWillResignActive), name: UIApplication.willResignActiveNotification, object: nil)
        }
    }

    private var refreshTimer: Timer?

    @objc private func appWillEnterForeground() {
        Task { await store.refresh(syncHealth: true) }
        ReminderScheduler.shared.reschedule(store.dashboard)
    }

    @objc private func appDidBecomeActive() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in await LogStore.shared.refresh() }
        }
    }

    @objc private func appWillResignActive() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if nativeLock && store.isLocked { presentLock() }
    }

    private func webBridge() -> LogBridgeViewController {
        if let b = bridge { return b }
        let b = LogBridgeViewController()
        b.messages.shell = self
        bridge = b
        return b
    }

    private func embedBridge(in host: UIViewController) {
        let b = webBridge()
        guard b.parent !== host else { return }
        if b.parent != nil {
            b.willMove(toParent: nil)
            b.view.removeFromSuperview()
            b.removeFromParent()
        }
        host.addChild(b)
        b.view.frame = host.view.bounds
        b.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.addSubview(b.view)
        b.didMove(toParent: host)
        if let scroll = b.webView?.scrollView {
            host.setContentScrollView(scroll, for: .bottom)
        }
    }

    // Picking a web tab (or the current one again, which scrolls to the top) tells the page.
    func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
        guard let index = hosts.firstIndex(of: viewController), let tab = LogTab(rawValue: index) else { return true }
        if viewController is WebHost {
            embedBridge(in: viewController)
            bridge?.run("window.logShellSelectTab && window.logShellSelectTab('\(tab.id)')")
        }
        return true
    }

    // The page switched tabs on its own (a "Details" link, say): follow it.
    func select(tabId: String) {
        guard let tab = LogTab.allCases.first(where: { $0.id == tabId }), selectedIndex != tab.rawValue else { return }
        if hosts[tab.rawValue] is WebHost { embedBridge(in: hosts[tab.rawValue]) }
        selectedIndex = tab.rawValue
    }

    // MARK: Lock

    /// The page showed or left its lock screen. With a native lock screen, that one covers everything.
    func webLockChanged(_ locked: Bool) {
        if nativeLock {
            keychainChanged()
            return
        }
        if #available(iOS 18.0, *) {
            setTabBarHidden(locked, animated: true)
        } else {
            tabBar.isHidden = locked
        }
    }

    /// The page saved or cleared the passcode (or locked after a rejected one).
    func keychainChanged() {
        store.syncLockFromKeychain()
        guard nativeLock else { return }
        if store.isLocked { presentLock() } else { dismissLock() }
    }

    /// The native side locked or unlocked: show or hide the lock screen and tell the page.
    private func nativeLockChanged(_ locked: Bool) {
        if locked {
            presentLock()
            bridge?.run("typeof lock === 'function' && lock()")
        } else {
            dismissLock()
            bridge?.run("typeof boot === 'function' && boot()")
            Task { await store.start() }
        }
    }

    private func presentLock() {
        guard nativeLock, lockScreen == nil, view.window != nil else { return }
        let lock = NativeScreens.makeLockScreen(store: store)
        lockScreen = lock
        present(lock, animated: false)
    }

    private func dismissLock() {
        guard let lock = lockScreen else { return }
        lock.dismiss(animated: true)
        lockScreen = nil
    }
}
