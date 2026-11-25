import SwiftUI
import LogCore
import LogHealth

/// The native Log tab (web: renderLogTab in forms.js): Apple Health, today's check-in, weigh-in,
/// Earn It, then the dose, side effect, measurement and vial forms, the reconstitution calculator
/// and the app version.
public struct LogScreen: View {
    /// Flip to true when this screen covers everything the web version does.
    public static let isReady = true

    @Environment(LogStore.self) private var store
    @State private var open: [String: Bool] = LogScreen.initialOpen

    public init() {}

    static let folds = ["dose", "side", "measure", "vial", "recon"]

    /// Folds start closed, like the web; a debug `-scrollTo <fold>` opens that one for screenshots.
    static var initialOpen: [String: Bool] {
        guard let t = MLDebug.scrollTo, folds.contains(t) else { return [:] }
        return [t: true]
    }

    private func folded(_ id: String) -> Binding<Bool> {
        Binding(get: { open[id] ?? false }, set: { open[id] = $0 })
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScreenScaffold("Log") {
                if NativeHealthSync.isReady {
                    LogCard("Apple Health") {
                        Caption("Activity, sleep stages, heart rate, breathing, blood oxygen, blood pressure, glucose, temperature, energy, water, weigh-ins, body fat and workouts. When the app opens it catches up on recent days and keeps backfilling your history.")
                        HealthSyncPanel()
                    }
                    .id("health")
                }
                LogCard("Today’s check-in") {
                    Caption("How the day went. Everything is optional, and saving again updates today’s answers.")
                    CheckinForm(day: LogTime.today())
                }
                .id("checkin")
                MLWeighInCard().id("weigh")
                MLEarnItCard().id("earn")
                Text("More to log")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(LogColor.ink)
                    .padding(.horizontal, 4)
                    .padding(.top, 10)
                    .accessibilityAddTraits(.isHeader)
                    .id("more")
                Group {
                    MLDoseForm(open: folded("dose")).id("dose")
                    MLSideEffectForm(open: folded("side")).id("side")
                    MLMeasurementForm(open: folded("measure")).id("measure")
                    MLVialForm(open: folded("vial")).id("vial")
                    MLReconForm(open: folded("recon")).id("recon")
                }
                Text(MLAppVersion.text)
                    .font(.footnote)
                    .foregroundStyle(LogColor.ink2)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .id("version")
            }
            .scrollDismissesKeyboard(.interactively)
            .environment(\.mlKeyboardDoneShown, true)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { MLKeyboard.dismiss() }
                }
            }
            .modifier(MLScrollOnLaunch(proxy: proxy, ready: store.dashboard != nil))
        }
    }
}
