import SwiftUI
import WidgetKit
import ActivityKit
import AppIntents
import LogActivity

@main
struct LogWidgetsBundle: WidgetBundle {
    var body: some Widget {
        HungerLiveActivity()
        WeightWidget()
        ReadinessWidget()
        FoodWidget()
    }
}

// Colors match the app's theme (Log 2.0).
private enum HColor {
    static let teal = Color(red: 0.07, green: 0.60, blue: 0.50)
    static let tealBright = Color(red: 0.18, green: 0.71, blue: 0.59)
    static let orange = Color(red: 0.84, green: 0.42, blue: 0.12)
    static let magenta = Color(red: 0.82, green: 0.38, blue: 0.71)

    static func strength(_ s: Int) -> Color {
        switch s {
        case 3: return magenta
        case 2: return orange
        default: return tealBright
        }
    }
}

/// Today's food thoughts on Lock Screen and Dynamic Island, with buttons to log one.
struct HungerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HungerAttributes.self) { context in
            LockScreenHunger(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hunger today").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        Text("\(s.count)").font(.system(.title2, design: .rounded).weight(.bold)).monospacedDigit()
                    }
                    .padding(.leading, 8)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Calories left").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        Text(s.caloriesLeft.map { "\($0)" } ?? "—").font(.system(.title2, design: .rounded).weight(.bold)).monospacedDigit()
                    }
                    .padding(.trailing, 8)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        HungerTimeline(thoughts: s.thoughts, height: 18)
                        LogButtons(compact: true)
                    }
                }
            } compactLeading: {
                Image(systemName: "fork.knife").foregroundStyle(HColor.tealBright)
            } compactTrailing: {
                Text("\(s.count)").font(.system(.body, design: .rounded).weight(.semibold)).monospacedDigit()
                    .foregroundStyle(s.cravings > 0 ? HColor.magenta : .white)
            } minimal: {
                Text("\(s.count)").font(.system(.caption, design: .rounded).weight(.bold)).foregroundStyle(HColor.tealBright)
            }
        }
    }
}

private struct LockScreenHunger: View {
    let state: HungerAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Hunger today").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                    Text(state.lastLine ?? "No food thoughts yet").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                stat(state.caloriesLeft.map { "\($0)" } ?? "—", "kcal left")
                if let level = state.levelMg {
                    stat(String(format: "%.1f", level), "mg level")
                }
            }
            HungerTimeline(thoughts: state.thoughts, height: 22)
            LogButtons(compact: false)
        }
        .padding(14)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(value).font(.system(.title3, design: .rounded).weight(.bold)).monospacedDigit().foregroundStyle(.white)
            Text(label).font(.caption2).foregroundStyle(.white.opacity(0.7))
        }
        .padding(.leading, 10)
    }
}

/// A track from 6 AM (earlier if a thought came before then) to midnight, with a dot per food
/// thought: bigger and warmer for stronger pulls. Dots stay inside the track's ends.
private struct HungerTimeline: View {
    let thoughts: [HungerAttributes.Thought]
    let height: CGFloat

    var body: some View {
        GeometryReader { geo in
            let first = Double(thoughts.map(\.minute).min() ?? 360)
            let start = min(360.0, (first / 60).rounded(.down) * 60), end = 24 * 60.0
            let pad: CGFloat = 8
            let span = max(1, geo.size.width - pad * 2)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18)).frame(height: 4)
                ForEach([12, 18], id: \.self) { h in
                    Rectangle().fill(Color.white.opacity(0.3)).frame(width: 1, height: height * 0.6)
                        .offset(x: pad + span * (Double(h * 60) - start) / (end - start))
                }
                ForEach(Array(thoughts.enumerated()), id: \.offset) { _, t in
                    let x = max(0, min(1, (Double(t.minute) - start) / (end - start)))
                    let d = CGFloat(6 + t.strength * 3)
                    Circle().fill(HColor.strength(t.strength)).frame(width: d, height: d)
                        .offset(x: pad + span * x - d / 2)
                }
            }
            .frame(height: height)
        }
        .frame(height: height)
        .accessibilityLabel("\(thoughts.count) food thoughts today")
    }
}

/// Passing / Strong / Craving: logs a food thought from the Lock Screen or Dynamic Island.
private struct LogButtons: View {
    let compact: Bool

    var body: some View {
        HStack(spacing: 6) {
            button(1, compact ? "Passing" : "Passing", HColor.tealBright)
            button(2, compact ? "Strong" : "Strong pull", HColor.orange)
            button(3, "Craving", HColor.magenta)
        }
    }

    private func button(_ strength: Int, _ label: String, _ color: Color) -> some View {
        Button(intent: LogFoodThoughtIntent(strength: strength)) {
            Text(label)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, compact ? 4 : 6)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(color.opacity(0.85), in: Capsule())
    }
}
