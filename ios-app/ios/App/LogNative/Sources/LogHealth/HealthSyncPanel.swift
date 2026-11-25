import SwiftUI
import LogCore

/// Apple Health status and controls for the native screens: last sync, a "Sync now" button and the
/// history backfill. The Log tab shows the full panel in its Apple Health card; Today may show the
/// compact one-line status. Placeholder until NativeHealthSync.isReady: it draws nothing.
///
/// Owned by the Health stage (LogHealth/). Other screens only place it; they don't depend on how
/// it works.
public struct HealthSyncPanel: View {
    public var compact: Bool

    public init(compact: Bool = false) {
        self.compact = compact
    }

    public var body: some View {
        if NativeHealthSync.isReady {
            Text(compact ? "Apple Health" : "Apple Health sync")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
