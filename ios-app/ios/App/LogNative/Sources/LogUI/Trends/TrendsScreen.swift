import SwiftUI
import UIKit
import LogCore

/// The native Trends tab (web: renderTrendsTab in app.js). One section at a time, picked from a
/// row of chips and remembered in "log.trendsSection" like the web app's localStorage key.
/// Each section's numbers are worked out once per payload (TrendsCache), not on every render.
public struct TrendsScreen: View {
    @Environment(LogStore.self) var store
    @AppStorage("log.trendsSection") var savedSection: String = "summary"
    @State var picked: String? = nil
    @State var cache = TrendsCache()
    @State var didDebugScroll = false

    public init() {}

    var active: String {
        let s = picked ?? store.demoSection ?? savedSection
        return TrSection.all.contains { $0.id == s } ? s : "summary"
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScreenScaffold("Trends") {
                TrSectionPicker(active: active) { id in select(id, proxy: proxy) }
                    .id("trends-top")
                if let d = store.dashboard {
                    section(d)
                } else {
                    LogCard { EmptyNote(store.errorMessage ?? "Loading the log…") }
                }
            }
            .task(id: store.dataTime) { await debugScroll(proxy) }
        }
    }

    func select(_ id: String, proxy: ScrollViewProxy) {
        guard id != active else { return }
        picked = id
        savedSection = id
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo("trends-top", anchor: .top) }
    }

    @ViewBuilder
    func section(_ d: Dashboard) -> some View {
        let now = TodayDebug.now ?? Date()
        let stamp = "\(store.dataTime?.timeIntervalSince1970 ?? 0)|\(LogTime.today(now))"
        let t = TrendsCalc.targets(d)
        let targets = TrTargets(calories: t.calories, protein: t.protein)
        let open: (String) -> Void = { id in
            picked = id
            savedSection = id
        }
        switch active {
        case "weight":
            TrWeightSectionView(m: cache.get("weight", stamp: stamp) {
                TrWeightSection(weight: TrWeightModel(d, now: now), stall: TrendsCalc.stallCheck(d, now: now), body: TrendsCalc.bodyComp(d))
            }, photos: d.progressPhotos)
        case "food":
            TrFoodSectionView(m: cache.get("food", stamp: stamp) { TrFoodModel(d, now: now, targets: targets) })
        case "meds":
            TrMedsSectionView(m: cache.get("meds", stamp: stamp) { TrMedsModel(d, now: now) })
        case "body":
            TrBodySectionView(m: cache.get("body", stamp: stamp) { TrBodyModel(d, now: now) }, canSync: !store.isDemo)
        case "training":
            TrTrainingSectionView(m: cache.get("training", stamp: stamp) { TrTrainingModel(d, now: now) })
        case "more":
            TrMoreSectionView(m: cache.get("more", stamp: stamp) { TrMoreModel(d, now: now) }, dashboard: d, targets: targets)
        default:
            TrSummarySectionView(m: cache.get("summary", stamp: stamp) {
                TrSummaryModel(tiles: TrendsCalc.summary(d, now: now, calorieTarget: targets.calories, proteinTarget: targets.protein),
                               weight: TrWeightModel(d, now: now))
            }, open: open)
        }
    }

    /// Debug builds: `-scrollTo <card id>` scrolls to a card for the CI screenshots.
    func debugScroll(_ proxy: ScrollViewProxy) async {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard !didDebugScroll, store.dashboard != nil, let i = args.firstIndex(of: "-scrollTo"), i + 1 < args.count else { return }
        didDebugScroll = true
        try? await Task.sleep(nanoseconds: 900_000_000)
        proxy.scrollTo(args[i + 1], anchor: .top)
        #endif
    }
}

/// The section chips: a sideways-scrolling row that keeps the chosen one in view.
struct TrSectionPicker: View {
    var active: String
    var onPick: (String) -> Void

    var body: some View {
        ScrollViewReader { p in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(TrSection.all) { s in
                        Button { onPick(s.id) } label: {
                            Text(s.label)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(s.id == active ? Color.white : LogColor.ink)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(s.id == active ? LogColor.accent : LogColor.surface, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .id("chip-\(s.id)")
                        .accessibilityAddTraits(s.id == active ? [.isSelected] : [])
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()
            .onAppear { p.scrollTo("chip-\(active)", anchor: .center) }
            .onChange(of: active) { _, v in withAnimation { p.scrollTo("chip-\(v)", anchor: .center) } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Trends sections")
    }
}
