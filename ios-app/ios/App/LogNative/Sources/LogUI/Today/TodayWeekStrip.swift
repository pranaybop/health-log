import SwiftUI
import LogCore

struct TodayWeekStrip: View {
    let key: String
    let today: String
    let earliest: String
    let logged: Set<String>
    let now: Date
    let select: (String) -> Void
    let openMonth: () -> Void

    private static let monthFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = LogTime.zone
        f.dateFormat = "MMMM yyyy"
        return f
    }()

    private static let letters = ["M", "T", "W", "T", "F", "S", "S"]

    var body: some View {
        let monday = LogTime.monday(key)
        let month = Self.monthFormat.string(from: LogTime.noon(key))
        VStack(spacing: 8) {
            HStack {
                Button(action: openMonth) {
                    HStack(spacing: 6) {
                        Text(month).font(.body.weight(.semibold)).foregroundStyle(LogColor.ink)
                        Image(systemName: "chevron.down").font(.footnote.weight(.semibold)).foregroundStyle(LogColor.ink2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(month). Jump to a day")
                Spacer(minLength: 8)
                if key != today {
                    Button { select(today) } label: {
                        Text("Today")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(LogColor.link)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(LogColor.accentSoft, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(minHeight: 32)
            .padding(.horizontal, 6)
            HStack(spacing: 4) {
                ForEach(0..<7, id: \.self) { i in
                    dayButton(LogTime.shift(monday, i), letter: Self.letters[i])
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Days of this week")
        }
        .padding(.top, 12)
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .background(LogColor.surface, in: RoundedRectangle(cornerRadius: LogMetric.cardRadius, style: .continuous))
    }

    private func dayButton(_ k: String, letter: String) -> some View {
        let on = k == key
        let off = k > today || k < earliest
        let isToday = k == today
        let has = logged.contains(k)
        let number = Int(k.suffix(2)) ?? 0
        let dot: Color = has ? (on ? LogColor.surface : LogColor.ink2) : Color.clear
        return Button { select(k) } label: {
            VStack(spacing: 2) {
                Text(letter).font(.caption.weight(.semibold)).foregroundStyle(on ? LogColor.surface : LogColor.ink2)
                Text("\(number)").font(.logNumber(18, weight: .semibold))
                    .foregroundStyle(on ? LogColor.surface : (isToday ? LogColor.link : LogColor.ink))
                Circle().fill(dot).frame(width: 5, height: 5)
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(on ? LogColor.ink : Color.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(off)
        .opacity(off ? 0.3 : 1)
        .accessibilityLabel(LogTime.longDate(LogTime.noon(k), now: now))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct TodayMonthPicker: View {
    let key: String
    let earliest: String
    let today: String
    let pick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var ready = false

    init(key: String, earliest: String, today: String, pick: @escaping (String) -> Void) {
        self.key = key
        self.earliest = earliest
        self.today = today
        self.pick = pick
    }

    var body: some View {
        NavigationStack {
            DatePicker("Day", selection: $date, in: LogTime.noon(min(earliest, today))...LogTime.noon(today), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .tint(LogColor.accent)
                .padding(.horizontal)
                .environment(\.timeZone, LogTime.zone)
                .environment(\.calendar, LogTime.calendar)
                .frame(maxHeight: .infinity, alignment: .top)
                .navigationTitle("Jump to a day")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
                .onAppear {
                    date = LogTime.noon(key)
                    ready = true
                }
                .onChange(of: date) { _, value in
                    let k = LogTime.dayKey(value)
                    guard ready, k != key else { return }
                    pick(k)
                    dismiss()
                }
        }
        .presentationDetents([.medium, .large])
    }
}
