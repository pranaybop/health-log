import SwiftUI
import LogCore

/// "New low: 238.6 lb. Take a progress photo?" A prompt on Today when a new weigh-in shows up,
/// from any source (Apple Health, the Log tab, the bot), in the last day, with no photo yet.
/// A new low gets the stronger wording. "Not now" hides it until the next weigh-in.
struct TodayPhotoPrompt: View {
    let d: Dashboard
    let now: Date
    @AppStorage("log.photoPrompt.seen") private var seen = ""
    @State private var open = false

    struct Pick: Equatable {
        var entry: WeightEntry
        var key: String
        var isLow: Bool
    }

    /// The weigh-in to ask about, if any.
    static func pick(_ d: Dashboard, now: Date, seen: String) -> Pick? {
        let dated = d.weights.compactMap { w -> (Date, WeightEntry)? in
            guard let t = w.measuredDate, w.weightLb != nil else { return nil }
            return (t, w)
        }.sorted { $0.0 < $1.0 }
        guard let newest = dated.last else { return nil }
        let t = newest.0
        let last = newest.1
        guard now.timeIntervalSince(t) < 24 * 3600, now >= t else { return nil }
        let key = last.id ?? last.measuredAt ?? ""
        if key.isEmpty || key == seen { return nil }
        let photoed = d.progressPhotos.contains { p in
            if let id = last.id, p.weightId == id { return true }
            if let pt = p.takenDate { return abs(pt.timeIntervalSince(t)) < 6 * 3600 }
            return false
        }
        if photoed { return nil }
        let prior = dated.dropLast().compactMap { $0.1.weightLb }
        let isLow = (last.weightLb ?? .infinity) < (prior.min() ?? .infinity)
        return Pick(entry: last, key: key, isLow: isLow && !prior.isEmpty)
    }

    var body: some View {
        if let p = Self.pick(d, now: now, seen: seen) {
            let lb = Fmt.num(p.entry.weightLb, 1)
            LogCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: p.isLow ? "arrow.down.right.circle.fill" : "camera.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(p.isLow ? LogColor.good : LogColor.accent)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.isLow ? "New low: \(lb) lb" : "New weigh-in: \(lb) lb")
                                .font(.headline).foregroundStyle(LogColor.ink)
                            Text(p.isLow ? "Lowest weight you've logged. Take a progress photo to go with it?"
                                         : "Add a progress photo for this weigh-in?")
                                .font(.subheadline).foregroundStyle(LogColor.ink2)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("today.photo.prompt")
                        }
                    }
                    if open {
                        WeighPhotoOffer(offer: WeighOffer(weightLb: p.entry.weightLb ?? 0, weightId: p.entry.id,
                                                          takenAt: p.entry.measuredAt ?? MLTime.iso(now))) {
                            open = false
                        } onSaved: {
                            open = false
                            seen = p.key
                        }
                    } else {
                        HStack(spacing: 10) {
                            Button { withAnimation { open = true } } label: {
                                Text("Add photo").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 2)
                            }
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
                            .tint(LogColor.accent)
                            .accessibilityIdentifier("today.photo.add")
                            Button { withAnimation { seen = p.key } } label: {
                                Text("Not now").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 2)
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .tint(LogColor.ink2)
                            .accessibilityIdentifier("today.photo.dismiss")
                        }
                    }
                }
            }
        }
    }
}
