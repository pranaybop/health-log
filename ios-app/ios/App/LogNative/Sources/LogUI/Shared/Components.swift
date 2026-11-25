import SwiftUI
import LogCore

/// A white (graphite in dark) rounded card with an optional title row, like the web app's .card.
public struct LogCard<Content: View, Accessory: View>: View {
    let title: String?
    let accessory: Accessory
    let content: Content

    public init(_ title: String? = nil, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || !(accessory is EmptyView) {
                HStack(alignment: .firstTextBaseline) {
                    if let title { Text(title).font(.logCardTitle).foregroundStyle(LogColor.ink).accessibilityAddTraits(.isHeader) }
                    Spacer(minLength: 8)
                    accessory
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(LogMetric.cardPad)
        .background(LogColor.surface, in: RoundedRectangle(cornerRadius: LogMetric.cardRadius, style: .continuous))
    }
}

extension LogCard where Accessory == EmptyView {
    public init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, accessory: { EmptyView() }, content: content)
    }
}

/// A small caption under a card's content.
public struct Caption: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text).font(.footnote).foregroundStyle(LogColor.ink2).fixedSize(horizontal: false, vertical: true)
    }
}

/// A label-value row, like the web app's .prop.
public struct PropRow: View {
    let label: String
    let value: String
    public init(_ label: String, _ value: String) { self.label = label; self.value = value }
    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(LogColor.ink2)
            Spacer(minLength: 8)
            Text(value).foregroundStyle(LogColor.ink).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

/// A big number with a unit and a detail line (the web app's .metric / readout).
public struct BigNumber: View {
    let value: String
    let unit: String?
    let detail: String?
    let size: CGFloat
    public init(_ value: String, unit: String? = nil, detail: String? = nil, size: CGFloat = 34) {
        self.value = value; self.unit = unit; self.detail = detail; self.size = size
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.logNumber(size)).foregroundStyle(LogColor.ink)
                if let unit { Text(unit).font(.logNumber(size * 0.5, weight: .semibold)).foregroundStyle(LogColor.ink2) }
            }
            if let detail { Text(detail).font(.subheadline).foregroundStyle(LogColor.ink2) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// An empty state inside a card: what's missing and what fills it.
public struct EmptyNote: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text).font(.subheadline).foregroundStyle(LogColor.ink2).fixedSize(horizontal: false, vertical: true)
    }
}

/// The frame every native tab uses: large title, scrolling cards on the grouped background,
/// pull to refresh (which also syncs Apple Health), and a Lock button.
public struct ScreenScaffold<Content: View>: View {
    @Environment(LogStore.self) private var store
    let title: String
    let subtitle: String?
    let content: Content

    public init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LogMetric.stack) {
                if let line = subtitle ?? statusLine {
                    Text(line).font(.subheadline).foregroundStyle(store.refreshFailed ? LogColor.critInk : LogColor.ink2)
                        .padding(.horizontal, 4)
                }
                content
            }
            .padding(.horizontal, LogMetric.gutter)
            .padding(.bottom, 24)
        }
        .background(LogColor.bg.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
        .refreshable { await store.refresh(syncHealth: true) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { store.lock() } label: { Image(systemName: "lock") }
                    .accessibilityLabel("Lock")
            }
        }
    }

    private var statusLine: String? {
        guard let t = store.dataTime else { return nil }
        if store.refreshFailed { return "Couldn’t refresh. Showing data from \(LogTime.time(t))." }
        if store.fromCache && store.isRefreshing { return "Saved data from \(LogTime.time(t)), refreshing…" }
        if store.isRefreshing { return "Refreshing…" }
        return "Updated \(LogTime.time(t))"
    }
}
