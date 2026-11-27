import SwiftUI
import LogCore
import LogHealth

public struct TodayScreen: View {
    @Environment(LogStore.self) private var store

    @State private var dayOffset = TodayDebug.dayOffset
    @State private var forward = true
    @State private var editTargets = TodayDebug.open == "targets"
    @State private var targetsMessage: TodayMessage?
    @State private var effectOpen = TodayDebug.open == "effect"
    @State private var checkinDay: CheckinDay?
    @State private var monthOpen = false
    @State private var toast: ToastItem?
    @State private var busy = false
    @State private var saves = 0
    @State private var debugDone = false

    public init() {}

    private var now: Date { TodayDebug.now ?? Date() }

    public var body: some View {
        let model: TodayModel? = store.dashboard.map { TodayModel($0, offset: dayOffset, now: now) }
        ScrollViewReader { proxy in
            ScreenScaffold(model.map { TodayText.dayTitle($0.key, today: $0.today, now: $0.now) } ?? "Today",
                           subtitle: model.map { LogTime.longDate(LogTime.noon($0.key), now: $0.now) }) {
                if let model {
                    content(model)
                } else {
                    loading
                }
            }
            .overlay(alignment: .top) { toastView }
            .task(id: model != nil) { await debugStart(proxy, model) }
        }
        .sheet(item: $checkinDay) { day in checkinSheet(day) }
        .sheet(isPresented: $monthOpen) {
            if let model {
                TodayMonthPicker(key: model.key, earliest: model.earliest, today: model.today) { k in
                    go(to: LogTime.dayDiff(k, model.today), model)
                }
            }
        }
        .sensoryFeedback(.selection, trigger: dayOffset)
        .sensoryFeedback(.success, trigger: saves)
        .onAppear { openCheckinReminder() }
        .onReceive(NotificationCenter.default.publisher(for: ReminderRouter.opened)) { _ in openCheckinReminder() }
    }

    private func openCheckinReminder() {
        guard ReminderRouter.pending == "checkin" else { return }
        ReminderRouter.pending = nil
        let key = LogTime.today(now)
        checkinDay = CheckinDay(key: key, isToday: true)
    }

    // MARK: Layout

    @ViewBuilder private func content(_ m: TodayModel) -> some View {
        TodayWeekStrip(key: m.key, today: m.today, earliest: m.earliest, logged: Analytics.loggedDays(m.d), now: m.now,
                       select: { k in go(to: LogTime.dayDiff(k, m.today), m) },
                       openMonth: { monthOpen = true })
            .id("week")
        ZStack(alignment: .top) {
            dayBody(m)
                .id(m.key)
                .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity), removal: .opacity))
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .simultaneousGesture(swipe(m), including: editTargets || effectOpen ? .subviews : .all)
        .accessibilityAction(named: "Previous day") { go(to: m.offset - 1, m) }
        .accessibilityAction(named: "Next day") { go(to: m.offset + 1, m) }
    }

    private func dayBody(_ m: TodayModel) -> some View {
        VStack(alignment: .leading, spacing: LogMetric.stack) {
            TodayHero(m: m).id("hero")
            if let r = ReadinessCache.day(m.key, in: m.d) {
                TodayReadiness(day: r, week: ReadinessCache.week(ending: m.key, in: m.d), isToday: m.isToday)
                    .id("readiness")
            }
            if m.isToday {
                TodayPhotoPrompt(d: m.d, now: m.now).id("photo")
            }
            TodayFoodCard(m: m, editing: $editTargets, message: $targetsMessage, save: { c, p in await saveTargets(c, p) })
                .id("food")
            if m.isToday, let low = UnderEating.check(m.d, now: m.now) {
                UnderEatingCard(low: low).id("undereating")
            }
            if m.isToday {
                ForEach(Analytics.regimenStatuses(m.d, now: m.now).filter { $0.dueToday && !$0.loggedToday }, id: \.self) { s in
                    RegimenCard(status: s, compact: true).id("regimen")
                }
            }
            if TodayCheckinNudge.shows(m) {
                TodayCheckinNudge(m: m) { checkinDay = CheckinDay(key: m.key, isToday: m.isToday) }.id("checkin")
            }
            if TodayFeelNow.shows(m) {
                TodayFeelNow(m: m, effectOpen: $effectOpen, busy: busy, send: send).id("feel")
            }
            let checks = Analytics.offNormal(m.d, on: m.key)
            if TodayOffNormal.shows(checks) {
                TodayOffNormal(checks: checks).id("offnormal")
            }
            if m.isToday {
                TodayCountdowns(m: m).id("counts")
                SwitchCard()
                TodayVerdict(m: m).id("verdict")
                TodayMedSummary(m: m).id("meds")
            } else if TodayDayMeds.shows(m) {
                TodayDayMeds(m: m).id("meds")
            }
            Group {
                TodaySleepCard(m: m).id("sleep")
                TodayBodyCard(m: m).id("body")
                if m.isToday {
                    updatedLine(m).id("updated")
                }
            }
        }
    }

    private func updatedLine(_ m: TodayModel) -> some View {
        let t = m.d.asOfDate ?? store.dataTime ?? Date()
        let failed = store.refreshFailed
        return Text(failed ? "Couldn’t refresh. Showing data from \(TodayText.timeCT(t))." : "Updated \(TodayText.timeCT(t)). Refreshes every minute.")
            .font(.footnote)
            .foregroundStyle(failed ? LogColor.critInk : LogColor.ink2)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
    }

    @ViewBuilder private var loading: some View {
        if let error = store.errorMessage {
            LogCard { EmptyNote(error) }
        } else {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 48)
        }
    }

    // MARK: Moving between days

    /// Go to a day by its offset from today, kept between the first logged day and today.
    private func go(to offset: Int, _ m: TodayModel) {
        let next = max(m.minOffset, min(0, offset))
        guard next != m.offset else { return }
        forward = next > m.offset
        editTargets = false
        targetsMessage = nil
        toast = nil
        withAnimation(.snappy(duration: 0.3)) { dayOffset = next }
    }

    private func swipe(_ m: TodayModel) -> some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { v in
                let dx = v.translation.width
                let dy = v.translation.height
                guard abs(dx) >= 60, abs(dx) >= abs(dy) * 1.8 else { return }
                go(to: m.offset + (dx < 0 ? 1 : -1), m)
            }
    }

    // MARK: Writes

    private func send(_ action: String, _ payload: [String: Any], _ success: String) async -> Bool {
        busy = true
        defer { busy = false }
        do {
            let result = try await store.write(action, payload)
            if let ok = result["ok"] as? Bool, !ok { throw LogError.server((result["error"] as? String) ?? "write_failed") }
            show(TodayMessage(ok: true, text: success))
            saves += 1
            return true
        } catch {
            show(TodayMessage(ok: false, text: TodayText.writeError(error)))
            return false
        }
    }

    private func saveTargets(_ calories: Int?, _ protein: Int?) async {
        targetsMessage = nil
        var jobs: [(String, Int)] = []
        if let calories { jobs.append(("calories", calories)) }
        if let protein { jobs.append(("protein", protein)) }
        var failed: String?
        for (kind, target) in jobs {
            do {
                let result = try await store.write("goal_set", ["kind": kind, "target": target])
                if let ok = result["ok"] as? Bool, !ok { throw LogError.server((result["error"] as? String) ?? "write_failed") }
            } catch {
                failed = TodayText.writeError(error)
                break
            }
        }
        if let failed {
            targetsMessage = TodayMessage(ok: false, text: failed)
        } else {
            editTargets = false
            targetsMessage = TodayMessage(ok: true, text: "Targets saved to your log.")
            saves += 1
        }
    }

    // MARK: Toast

    private struct ToastItem: Equatable {
        let id = UUID()
        let message: TodayMessage
    }

    private func show(_ message: TodayMessage) {
        let item = ToastItem(message: message)
        withAnimation(.snappy) { toast = item }
        AccessibilityNotification.Announcement(message.text).post()
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if toast?.id == item.id {
                withAnimation(.snappy) { toast = nil }
            }
        }
    }

    @ViewBuilder private var toastView: some View {
        if let t = toast {
            Text(t.message.text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(t.message.ok ? LogColor.goodInk : LogColor.critInk)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(t.message.ok ? LogColor.goodSoft : LogColor.critSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: Color.black.opacity(0.08), radius: 8, y: 2)
                .padding(.horizontal, LogMetric.gutter)
                .padding(.top, 8)
                .onTapGesture { withAnimation(.snappy) { toast = nil } }
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: Check-in sheet

    private struct CheckinDay: Identifiable {
        let key: String
        let isToday: Bool
        var id: String { key }
    }

    private func checkinSheet(_ day: CheckinDay) -> some View {
        NavigationStack {
            ScrollView {
                LogCard {
                    CheckinForm(day: day.key, onSaved: {
                        checkinDay = nil
                        show(TodayMessage(ok: true, text: day.isToday ? "Saved today’s check-in." : "Saved the check-in for \(LogTime.shortDate(key: day.key))."))
                        saves += 1
                    })
                }
                .padding(LogMetric.gutter)
            }
            .background(LogColor.bg.ignoresSafeArea())
            .navigationTitle(day.isToday ? "Today’s check-in" : "Check-in for \(LogTime.shortDate(key: day.key))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { checkinDay = nil }
                }
            }
        }
        .environment(store)
        .tint(LogColor.link)
    }

    // MARK: Debug launch arguments

    private func debugStart(_ proxy: ScrollViewProxy, _ m: TodayModel?) async {
        guard let m, !debugDone else { return }
        debugDone = true
        if TodayDebug.open == "checkin" { checkinDay = CheckinDay(key: m.key, isToday: m.isToday) }
        if TodayDebug.open == "month" { monthOpen = true }
        guard let id = TodayDebug.scrollTo else { return }
        try? await Task.sleep(nanoseconds: 800_000_000)
        proxy.scrollTo(id, anchor: .top)
    }
}

/// What the Today cards need for the day showing, worked out once per redraw.
struct TodayModel {
    let d: Dashboard
    let now: Date
    let today: String
    let key: String
    let earliest: String
    /// Offsets run from minOffset (the first logged day) to 0 (today).
    let minOffset: Int
    let offset: Int
    let points: [WeightPoint]
    let journey: WeightJourney?
    let pace: WeightPace?
    let totals: DailyTotal?
    let meals: [Meal]
    let targets: TodayTargets
    let checkin: Checkin?
    let thoughts: [FoodThought]
    let effects: [SideEffect]

    var isToday: Bool { key == today }

    init(_ d: Dashboard, offset requested: Int, now: Date) {
        self.d = d
        self.now = now
        let today = LogTime.today(now)
        self.today = today
        let earliest = Analytics.earliestDay(d, now: now)
        self.earliest = earliest
        let minOffset = min(0, LogTime.dayDiff(earliest, today))
        self.minOffset = minOffset
        let offset = max(minOffset, min(0, requested))
        self.offset = offset
        let key = LogTime.shift(today, offset)
        self.key = key
        let points = Analytics.smoothWeights(d)
        self.points = points
        journey = Analytics.journey(d, points: points)
        pace = Analytics.recentPace(points)
        totals = Analytics.totals(on: key, d)
        meals = Analytics.meals(on: key, d)
        targets = TodayTargets.current(d)
        checkin = d.checkins.first { $0.day == key }
        thoughts = d.foodThoughts.filter { $0.thoughtDate.map(LogTime.dayKey) == key }
        effects = d.sideEffects.filter { $0.recordedOn == key }
    }
}
