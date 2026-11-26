import SwiftUI
import LogCore

/// The native Meds tab (web: renderMedsTab in app.js): drug level, injection sites, dose plan,
/// titration, the retatrutide switch, protocol, vials and dosing history.
public struct MedsScreen: View {
    @Environment(LogStore.self) private var store

    public init() {}

    public var body: some View {
        ScrollViewReader { proxy in
            ScreenScaffold("Meds") {
                if let d = store.dashboard {
                    MLLevelCard(data: d).id("level")
                    MLSitesCard(data: d).id("sites")
                    if MLDosePlanCard.shows(d) { MLDosePlanCard(data: d).id("plan") }
                    MLTitrationCard(data: d).id("titration")
                    SwitchCard().id("switch")
                    if !d.protocols.isEmpty { MLProtocolCard(data: d).id("protocol") }
                    MLVialsCard(data: d).id("vials")
                    MLDoseHistoryCard(data: d).id("history")
                } else {
                    LogCard { HStack(spacing: 10) { ProgressView(); EmptyNote("Loading your log…") } }
                }
            }
            .modifier(MLScrollOnLaunch(proxy: proxy, ready: store.dashboard != nil))
            .onAppear { openDoseReminder(proxy) }
            .onReceive(NotificationCenter.default.publisher(for: ReminderRouter.opened)) { _ in openDoseReminder(proxy) }
        }
    }

    private func openDoseReminder(_ proxy: ScrollViewProxy) {
        guard ReminderRouter.pending == "meds" else { return }
        ReminderRouter.pending = nil
        DispatchQueue.main.async { proxy.scrollTo("plan", anchor: .top) }
    }
}
