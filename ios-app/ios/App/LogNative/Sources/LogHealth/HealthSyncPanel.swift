import SwiftUI
import UIKit
import LogCore

/// Apple Health status and controls for the native screens (app.js renderHealthSync).
///
/// - Full (the Log tab's Apple Health card): "Sync the last 30 days", the backfill button
///   ("Backfill history", "Continue backfill", "Backfill again"), the last sync or what the last
///   sync did, and the backfill progress.
/// - Compact (Today): one line with the last sync and a Sync button (the last 7 days).
///
/// Owned by the Health stage (LogHealth/). Other screens only place it.
public struct HealthSyncPanel: View {
    public var compact: Bool

    public init(compact: Bool = false) {
        self.compact = compact
    }

    public var body: some View {
        if compact {
            HealthSyncCompactRow(status: HealthSyncStatus.shared)
        } else {
            HealthSyncFullPanel(status: HealthSyncStatus.shared)
        }
    }
}

enum HealthPanelStyle {
    /// LogColor.critInk (styles.css --crit-ink), for errors.
    static let errorInk = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0xF0 / 255, green: 0x71 / 255, blue: 0x67 / 255, alpha: 1)
            : UIColor(red: 0xB4 / 255, green: 0x23 / 255, blue: 0x18 / 255, alpha: 1)
    })
}

struct HealthSyncFullPanel: View {
    let status: HealthSyncStatus

    var body: some View {
        let blocked = status.blockedReason
        VStack(alignment: .leading, spacing: 10) {
            Button {
                Task { _ = await NativeHealthSync.shared.syncNow(days: 30) }
            } label: {
                Text(status.isSyncing ? "Syncing…" : "Sync the last 30 days")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(status.isSyncing || blocked != nil)

            Button {
                let restart = status.backfill.done
                Task { await NativeHealthSync.shared.backfill(restart: restart) }
            } label: {
                Text(status.backfillButtonTitle)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(status.backfill.running || blocked != nil)

            Text(blocked ?? status.statusLine)
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(status.isError && blocked == nil ? HealthPanelStyle.errorInk : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)

            let line = blocked == nil ? status.backfillLine : ""
            if !line.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if status.backfill.running {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Text(line)
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .sensoryFeedback(.success, trigger: status.manualSyncs)
    }
}

struct HealthSyncCompactRow: View {
    let status: HealthSyncStatus

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(label: "Sync Apple Health", lines: 1)
            row(label: "Sync", lines: 1)
            row(label: "Sync", lines: 3)
        }
        .sensoryFeedback(.success, trigger: status.manualSyncs)
    }

    private func row(label: String, lines: Int) -> some View {
        let blocked = status.blockedReason
        return HStack(spacing: 10) {
            Text(blocked ?? status.statusLine)
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(status.isError && blocked == nil ? HealthPanelStyle.errorInk : Color.secondary)
                .lineLimit(lines)
            Spacer(minLength: 8)
            Button {
                Task { _ = await NativeHealthSync.shared.syncNow(days: 7) }
            } label: {
                Text(status.isSyncing ? "Syncing…" : label)
                    .lineLimit(1)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(status.isSyncing || blocked != nil)
        }
    }
}
