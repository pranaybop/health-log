import UIKit
import WebKit
import Security
import Capacitor

// The native shell around Log's screens (stage 1 of going native, Nov 2026).
//
// - A native UITabBarController with the four tabs. Built with the iOS 26 SDK it gets Liquid Glass
//   on iOS 26, and older systems get the standard translucent bar.
// - One Capacitor web view shows the screens. Picking a tab moves it into that tab and tells the
//   page to switch, so nothing reloads and every screen keeps its state.
// - The passcode lives in the Keychain, not in the web view's storage.
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

// MARK: - Keychain

enum PasscodeStore {
    private static let service = "com.pranaybop.log"
    private static let account = "passcode"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else { return nil }
        return text
    }

    static func write(_ passcode: String) {
        let data = Data(passcode.utf8)
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(query as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            var add = query
            add.merge(attrs) { $1 }
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func clear() {
        SecItemDelete(query as CFDictionary)
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
            shell?.setLocked(body["locked"] as? Bool ?? false)
            replyHandler(true, nil)
        case "getPasscode":
            replyHandler(PasscodeStore.read() ?? "", nil)
        case "setPasscode":
            if let code = body["passcode"] as? String, !code.isEmpty { PasscodeStore.write(code) }
            replyHandler(true, nil)
        case "clearPasscode":
            PasscodeStore.clear()
            replyHandler(true, nil)
        default:
            replyHandler(nil, "unknown message \(type)")
        }
    }
}

// MARK: - The web view

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
        let source = "window.LOG_NATIVE = Object.freeze({ tabs: true, keychain: true, version: \(jsString(version)), build: \(jsString(build)) });"
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

// MARK: - Tabs

final class ShellTabBarController: UITabBarController, UITabBarControllerDelegate {
    let bridgeController = LogBridgeViewController()
    private var hosts: [UIViewController] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        bridgeController.messages.shell = self
        view.backgroundColor = .systemGroupedBackground

        hosts = LogTab.allCases.map { tab in
            let host = UIViewController()
            host.view.backgroundColor = .systemGroupedBackground
            let image = UIImage(systemName: tab.symbol) ?? UIImage(systemName: "circle")
            host.tabBarItem = UITabBarItem(title: tab.title, image: image, tag: tab.rawValue)
            return host
        }
        setViewControllers(hosts, animated: false)
        tabBar.tintColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.42, green: 0.67, blue: 0.95, alpha: 1)
                : UIColor(red: 0.11, green: 0.39, blue: 0.75, alpha: 1)
        }
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            tabBarMinimizeBehavior = .onScrollDown
        }
        #endif
        embedBridge(in: hosts[0])
    }

    private func embedBridge(in host: UIViewController) {
        guard bridgeController.parent !== host else { return }
        if bridgeController.parent != nil {
            bridgeController.willMove(toParent: nil)
            bridgeController.view.removeFromSuperview()
            bridgeController.removeFromParent()
        }
        host.addChild(bridgeController)
        bridgeController.view.frame = host.view.bounds
        bridgeController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.addSubview(bridgeController.view)
        bridgeController.didMove(toParent: host)
        if let scroll = bridgeController.webView?.scrollView {
            host.setContentScrollView(scroll, for: .bottom)
        }
    }

    // Picking a tab (or the current one again, which scrolls to the top) tells the page.
    func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
        guard let index = hosts.firstIndex(of: viewController), let tab = LogTab(rawValue: index) else { return true }
        embedBridge(in: viewController)
        bridgeController.run("window.logShellSelectTab && window.logShellSelectTab('\(tab.id)')")
        return true
    }

    // The page switched tabs on its own (a "Details" link, say): follow it.
    func select(tabId: String) {
        guard let tab = LogTab.allCases.first(where: { $0.id == tabId }), selectedIndex != tab.rawValue else { return }
        embedBridge(in: hosts[tab.rawValue])
        selectedIndex = tab.rawValue
    }

    // No tabs on the lock screen.
    func setLocked(_ locked: Bool) {
        if #available(iOS 18.0, *) {
            setTabBarHidden(locked, animated: true)
        } else {
            tabBar.isHidden = locked
        }
    }
}
