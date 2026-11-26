import SwiftUI
import UIKit
import UserNotifications
import Observation
import LogCore
import LogActivity

// Local notifications only. The app is sideloaded with a free Apple ID, so there is no push,
// no APNs, and no paid entitlement. Scheduling is decided by ReminderPlanner; this file asks
// permission, stores the toggles, and opens the right screen when a notification is tapped.

enum ReminderRouter {
    static let opened = Notification.Name("logReminderOpened")
    /// "meds", "checkin", or "weigh" until the screen consumes it.
    static var pending: String?

    @MainActor
    static func open(_ route: String) {
        if route == "progress" {
            TrendsRouter.open("weight", card: "progress")
            return
        }
        pending = route
        switch route {
        case "checkin": TodayTabs.select(0)
        case "weigh": TodayTabs.select(3)
        default: TodayTabs.select(1)
        }
        NotificationCenter.default.post(name: opened, object: route)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard pending == route else { return }
            NotificationCenter.default.post(name: opened, object: route)
        }
    }
}

public final class ReminderScheduler: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    public static let shared = ReminderScheduler()
    private let lock = NSLock()
    private var token = 0
    private var observing = false
    /// What was last handed to iOS, so the minute-by-minute refresh doesn't redo identical work.
    private var applied: String?

    private override init() { super.init() }

    public func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Reschedule whenever the dashboard changes, and once with whatever is already loaded.
    @MainActor
    public func bind() {
        reschedule(LogStore.shared.dashboard)
        if let d = LogStore.shared.dashboard, !LogStore.shared.isDemo {
            HomeWidgets.publish(d)
            ProgressNotifier.check(d)
        }
        guard !observing else { return }
        observing = true
        observe()
    }

    @MainActor
    public func reschedule(_ dashboard: Dashboard?) {
        let settings = ReminderSettings.load()
        let now = TodayDebug.now ?? Date()
        let planned = dashboard.map { ReminderPlanner.requests($0, settings: settings, now: now) } ?? []
        let signature = planned.map { "\($0.id)|\($0.hour):\($0.minute)|\($0.body)" }.joined(separator: "\n")
        if signature == appliedSignature() { return }
        let generation = bump()
        Task {
            await apply(planned, signature: signature, generation: generation)
        }
    }

    /// Ask only when someone turns a reminder on. Returns false if they decline or previously denied.
    public func authorize() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        @unknown default:
            return false
        }
    }

    public func authorization() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let route = response.notification.request.content.userInfo["route"] as? String ?? "meds"
        DispatchQueue.main.async { ReminderRouter.open(route) }
        completionHandler()
    }

    private func bump() -> Int {
        lock.lock()
        token += 1
        let generation = token
        lock.unlock()
        return generation
    }

    private func appliedSignature() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return applied
    }

    private func setApplied(_ signature: String?, generation: Int) {
        lock.lock()
        if token == generation { applied = signature }
        lock.unlock()
    }

    private func isCurrent(_ generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return token == generation
    }

    @MainActor
    private func observe() {
        withObservationTracking {
            _ = LogStore.shared.dashboard
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.reschedule(LogStore.shared.dashboard)
                // The hunger Live Activity follows the same data.
                if let d = LogStore.shared.dashboard, !LogStore.shared.isDemo {
                    await HungerActivity.sync(d)
                    // Home and Lock Screen widgets read a snapshot from the shared app group.
                    HomeWidgets.publish(d)
                    ProgressNotifier.check(d)
                }
                self.observe()
            }
        }
    }

    private func apply(_ planned: [ReminderRequest], signature: String, generation: Int) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        guard isCurrent(generation) else { return }
        // Includes the older repeating "log.checkin" / "log.weigh" ids from before one-per-day reminders.
        let ours = pending.map(\.identifier).filter { $0.hasPrefix("log.checkin") || $0.hasPrefix("log.weigh") || $0.hasPrefix("log.shot.") }
        center.removePendingNotificationRequests(withIdentifiers: ours)
        let status = await center.notificationSettings().authorizationStatus
        guard isCurrent(generation) else { return }
        guard status == .authorized || status == .provisional || status == .ephemeral else {
            setApplied(nil, generation: generation)
            return
        }
        let now = Date()
        for req in planned {
            if let day = req.day, let at = ReminderPlanner.fireDate(day, req.hour, req.minute), at <= now { continue }
            let content = UNMutableNotificationContent()
            content.title = req.title
            content.body = req.body
            content.sound = .default
            content.userInfo = ["route": req.route]
            var comps = DateComponents()
            comps.calendar = LogTime.calendar
            comps.timeZone = LogTime.zone
            comps.hour = req.hour
            comps.minute = req.minute
            if let day = req.day {
                let parts = LogTime.calendar.dateComponents([.year, .month, .day], from: LogTime.noon(day))
                comps.year = parts.year
                comps.month = parts.month
                comps.day = parts.day
            }
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: req.day == nil)
            try? await center.add(UNNotificationRequest(identifier: req.id, content: content, trigger: trigger))
        }
        setApplied(signature, generation: generation)
    }
}

@MainActor
@Observable
final class ReminderModel {
    static let shared = ReminderModel()
    private(set) var settings = ReminderSettings.load()
    /// nil until iOS has been asked. False means notifications are denied.
    private(set) var allowed: Bool?

    var offersShotPrompt: Bool { !settings.shot && !settings.shotPromptDismissed }

    func reload() {
        settings = ReminderSettings.load()
    }

    func refreshAuthorization() async {
        switch await ReminderScheduler.shared.authorization() {
        case .authorized, .provisional, .ephemeral: allowed = true
        case .denied: allowed = false
        case .notDetermined: allowed = nil
        @unknown default: allowed = nil
        }
    }

    func setShot(_ on: Bool) async { await set(on) { $0.shot = on } }
    func setCheckin(_ on: Bool) async { await set(on) { $0.checkin = on } }
    func setWeigh(_ on: Bool) async { await set(on) { $0.weighIn = on } }

    func enableShot() async {
        guard await ReminderScheduler.shared.authorize() else {
            allowed = false
            return
        }
        allowed = true
        update {
            $0.shot = true
            $0.shotPromptDismissed = true
        }
    }

    func dismissShotPrompt() {
        update { $0.shotPromptDismissed = true }
    }

    func setShotClock(_ date: Date) { setClock(date) { $0.shotHour = $1; $0.shotMinute = $2 } }
    func setCheckinClock(_ date: Date) { setClock(date) { $0.checkinHour = $1; $0.checkinMinute = $2 } }
    func setWeighClock(_ date: Date) { setClock(date) { $0.weighHour = $1; $0.weighMinute = $2 } }

    private func set(_ on: Bool, _ apply: (inout ReminderSettings) -> Void) async {
        if on {
            let ok = await ReminderScheduler.shared.authorize()
            allowed = ok
            guard ok else { return }
        }
        update(apply)
    }

    private func setClock(_ date: Date, _ apply: (inout ReminderSettings, Int, Int) -> Void) {
        let parts = LogTime.calendar.dateComponents([.hour, .minute], from: date)
        update { apply(&$0, parts.hour ?? 0, parts.minute ?? 0) }
    }

    private func update(_ body: (inout ReminderSettings) -> Void) {
        var next = settings
        body(&next)
        next.save()
        settings = next
        ReminderScheduler.shared.reschedule(LogStore.shared.dashboard)
    }
}

struct ReminderSettingsCard: View {
    @State private var model = ReminderModel.shared

    var body: some View {
        LogCard("Reminders") {
            Caption("Shot day, an evening check-in, a morning weigh-in, and progress alerts. They stay on this phone.")
            row("Shot day", "The planned dose, including one you missed",
                on: model.settings.shot, time: model.settings.shotHour, minute: model.settings.shotMinute,
                toggle: { await model.setShot($0) }, clock: { model.setShotClock($0) })
            MLHairline()
            row("Evening check-in", "How the day went",
                on: model.settings.checkin, time: model.settings.checkinHour, minute: model.settings.checkinMinute,
                toggle: { await model.setCheckin($0) }, clock: { model.setCheckinClock($0) })
            MLHairline()
            row("Morning weigh-in", "Log your weight",
                on: model.settings.weighIn, time: model.settings.weighHour, minute: model.settings.weighMinute,
                toggle: { await model.setWeigh($0) }, clock: { model.setWeighClock($0) })
            MLHairline()
            ProgressAlertsRow()
            if model.allowed == false {
                Text("Notifications are off for Log. Turn them on in iOS Settings to use these.")
                    .font(.footnote).foregroundStyle(LogColor.ink2).fixedSize(horizontal: false, vertical: true)
                Button("Open Settings") { openSystemSettings() }
                    .buttonStyle(.bordered)
            } else {
                Caption("Times are Central. Log asks before the first one.")
            }
        }
        .task { await model.refreshAuthorization() }
        .onAppear { model.reload() }
    }

    private func row(_ title: String, _ detail: String, on: Bool, time hour: Int, minute: Int,
                     toggle: @escaping (Bool) async -> Void, clock: @escaping (Date) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { on }, set: { value in Task { await toggle(value) } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(LogColor.ink)
                    Text(detail).font(.footnote).foregroundStyle(LogColor.ink2).fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(LogColor.good)
            HStack {
                Text("Time").font(.subheadline).foregroundStyle(LogColor.ink2)
                Spacer(minLength: 8)
                DatePicker(title, selection: Binding(get: { Self.date(hour, minute) }, set: clock), displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .environment(\.timeZone, LogTime.zone)
            }
        }
        .padding(.vertical, 6)
    }

    private static func date(_ hour: Int, _ minute: Int) -> Date {
        var parts = DateComponents()
        parts.hour = hour
        parts.minute = minute
        return LogTime.calendar.date(from: parts) ?? Date()
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// Log › Reminders: milestone alerts and the Sunday recap (ProgressNotifier).
struct ProgressAlertsRow: View {
    @State private var on = ProgressNotifier.enabled

    var body: some View {
        Toggle(isOn: Binding(get: { on }, set: { value in
            Task { @MainActor in on = await ProgressNotifier.setEnabled(value) }
        })) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Milestones and weekly recap").foregroundStyle(LogColor.ink)
                Text("When a weigh-in passes the next 5 lb mark, and Sunday at 6 PM with your trend, pace and goal date")
                    .font(.footnote).foregroundStyle(LogColor.ink2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(LogColor.good)
    }
}
