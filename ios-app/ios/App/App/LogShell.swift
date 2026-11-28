import UIKit
import LogCore
import LogUI
import LogHealth

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

// MARK: - Tabs

final class ShellTabBarController: UITabBarController {
    private var store: LogStore { LogStore.shared }
    private weak var lockScreen: UIViewController?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        let hosts: [UIViewController] = LogTab.allCases.map { tab in
            let host = NativeScreens.make(tab.id, store: store)!
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

        store.healthSync = { days in _ = await NativeHealthSync.shared.sync(days: days) }
        store.onLockChange = { [weak self] locked in self?.nativeLockChanged(locked) }
        store.onDataChange = { [weak self] in self?.gateChanged() }
        ReminderProbe.install(on: view)
        ReminderScheduler.shared.bind()

        var start = 0
        #if DEBUG
        if let demo = store.demoTab, let tab = LogTab.allCases.first(where: { $0.id == demo }) { start = tab.rawValue }
        #endif
        selectedIndex = start

        Task { await store.start() }
        // Refresh every minute while open, and on coming back to the app (with an Apple Health catch-up).
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        center.addObserver(self, selector: #selector(appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(appWillResignActive), name: UIApplication.willResignActiveNotification, object: nil)
    }

    private var refreshTimer: Timer?
    private var leftAt: Date?
    private weak var appLock: UIViewController?

    @objc private func appWillEnterForeground() {
        Task { await store.refresh(syncHealth: true) }
        ReminderScheduler.shared.reschedule(store.dashboard)
        // Face ID after a minute away (Account > Require Face ID).
        if AppLock.enabled, !store.isLocked, !store.isDemo, let left = leftAt, Date().timeIntervalSince(left) > 60 {
            presentAppLock()
        }
    }

    private func presentAppLock() {
        guard appLock == nil else { return }
        let cover = NativeScreens.makeAppLock { [weak self] in
            self?.appLock?.dismiss(animated: true)
            self?.appLock = nil
        }
        appLock = cover
        (presentedViewController ?? self).present(cover, animated: false)
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
        leftAt = Date()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        ReminderProbe.install(on: view)
        if store.isLocked || store.needsOnboarding { presentLock() }
    }

    /// New data: a new account shows first-run setup until it's done.
    private func gateChanged() {
        if store.isLocked || store.needsOnboarding { presentLock() } else { dismissLock() }
    }

    private func nativeLockChanged(_ locked: Bool) {
        if locked {
            presentLock()
        } else {
            dismissLock()
            Task { await store.start() }
        }
    }

    private func presentLock() {
        guard lockScreen == nil, view.window != nil else { return }
        let lock = NativeScreens.makeLockScreen(store: store)
        lockScreen = lock
        present(lock, animated: false)
    }

    private func dismissLock() {
        guard let lock = lockScreen, !store.needsOnboarding, !store.isLocked else { return }
        lock.dismiss(animated: true)
        lockScreen = nil
    }
}
