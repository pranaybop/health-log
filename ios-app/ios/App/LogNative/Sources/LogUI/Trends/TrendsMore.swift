import SwiftUI
import UIKit
import CoreTransferable
import UniformTypeIdentifiers
import LogCore

// More section: pattern explorer (renderExplorer), Earn It wall (renderEarnWall), weekly summary
// (renderWeekly) and the prescriber export (renderExport: CSV, print views, 4-week coach pack).

struct TrMoreSectionView: View {
    var m: TrMoreModel
    var dashboard: Dashboard
    var targets: TrTargets

    var body: some View {
        VStack(alignment: .leading, spacing: LogMetric.stack) {
            TrExplorerCard(series: m.series).id("explorer")
            TrEarnWallCard(cells: m.earn).id("earn-wall")
            if !m.weekly.isEmpty {
                LogCard("Weekly summary") {
                    TrTable(headers: ["Week of", "kcal/day", "Protein", "Avg lb"], rows: m.weekly)
                }
                .id("weekly")
            }
            TrExportCard(dashboard: dashboard, today: m.today, proteinTarget: targets.protein).id("export")
        }
    }
}

struct TrExplorerCard: View {
    var series: [String: [String: Double]]
    @State var xID: String = "weight"
    @State var yID: String = "steps"

    var body: some View {
        let catalog = TrendsCalc.catalog
        let x = catalog.first { $0.id == xID } ?? catalog[0]
        let y = catalog.first { $0.id == yID } ?? catalog[1]
        let pairs = TrendsCalc.alignedPair(series[x.id] ?? [:], series[y.id] ?? [:])
        let need = max(0, 3 - pairs.count)
        return LogCard("Pattern explorer") {
            HStack(spacing: 10) {
                picker("Across", selection: $xID)
                picker("Up", selection: $yID)
            }
            if pairs.count >= 3 {
                TrScatter(pairs: pairs, main: "\(pairs.count) overlapping days", sub: "Each dot is a day where both were logged",
                          scrub: { p in ("\(TrendsCalc.num(p.x, 1)) and \(TrendsCalc.num(p.y, 1))", "\(TrendsCalc.short(p.day)): \(x.label) and \(y.label)") },
                          aria: "\(x.label) vs \(y.label)")
            } else {
                EmptyNote("Needs \(need) more overlapping day\(TrendsCalc.s(need)) for \(x.label) and \(y.label).")
            }
        }
    }

    func picker(_ title: String, selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(LogColor.ink2)
            Menu {
                Picker(title, selection: selection) {
                    ForEach(TrendsCalc.catalog) { m in Text(m.label).tag(m.id) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(TrendsCalc.catalog.first { $0.id == selection.wrappedValue }?.label ?? "")
                        .font(.subheadline.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
                }
                .foregroundStyle(LogColor.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(LogColor.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .accessibilityLabel(title)
        }
        .frame(maxWidth: .infinity)
    }
}

struct TrEarnWallCard: View {
    var cells: [TrendsCalc.EarnCell]

    var body: some View {
        let earned = cells.filter { $0.earned == true }.count
        let hasAny = cells.contains { $0.earned != nil }
        let pad = cells.first.map { LogTime.calendar.component(.weekday, from: LogTime.noon($0.day)) - 1 } ?? 0
        let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: 7)
        return LogCard("Earn It wall") {
            if hasAny {
                TrLead("\(earned) earned day\(TrendsCalc.s(earned)) in the last 8 weeks.")
                LazyVGrid(columns: columns, spacing: 5) {
                    ForEach(0..<7, id: \.self) { i in
                        Text(["S", "M", "T", "W", "T", "F", "S"][i]).font(.caption2.weight(.semibold)).foregroundStyle(LogColor.ink2)
                    }
                    ForEach(0..<pad, id: \.self) { _ in Color.clear.frame(height: 1) }
                    ForEach(cells) { c in cell(c) }
                }
                TrLegend(items: [
                    TrLegendItem(key: .rect(LogColor.good), label: "Earned"),
                    TrLegendItem(key: .outlined(LogColor.critSoft, LogColor.crit), label: "Not earned"),
                    TrLegendItem(key: .rect(LogColor.surface2), label: "Not marked"),
                ])
            } else {
                EmptyNote("Mark Earn It on the Log tab to start the wall.")
            }
        }
    }

    func cell(_ c: TrendsCalc.EarnCell) -> some View {
        let missed = c.has && c.earned == false
        let fill: Color = c.earned == true ? LogColor.good : missed ? LogColor.critSoft : LogColor.surface2
        return RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(fill)
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(missed ? LogColor.crit : Color.clear, lineWidth: 1))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(c.isToday ? LogColor.link : Color.clear, lineWidth: 2).padding(-2))
            .aspectRatio(1, contentMode: .fit)
            .accessibilityLabel("\(TrendsCalc.short(c.day)): \(c.earned == true ? "earned" : missed ? "not earned" : "not marked")")
    }
}

/// The prescriber CSV, made when it's shared.
struct TrCSVFile: Transferable {
    var name: String
    var dashboard: Dashboard

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { file in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(file.name)
            try Data(Analytics.Trends.prescriberCSV(file.dashboard).utf8).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}

/// The whole payload as JSON, made when it's shared.
struct TrJSONFile: Transferable {
    var name: String
    var dashboard: Dashboard

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { file in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(file.name)
            try Analytics.Trends.exportJSON(file.dashboard).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}

struct TrExportCard: View {
    var dashboard: Dashboard
    var today: String
    var proteinTarget: Double?

    var body: some View {
        let csvName = "log-prescriber-\(today).csv"
        let jsonName = "log-\(today).json"
        return LogCard("Prescriber export") {
            TrLead("Files stay on this phone. Save a print view as a PDF from the print sheet.")
            VStack(spacing: 10) {
                ShareLink(item: TrCSVFile(name: csvName, dashboard: dashboard), preview: SharePreview(csvName)) {
                    Label("Share CSV", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                ShareLink(item: TrJSONFile(name: jsonName, dashboard: dashboard), preview: SharePreview(jsonName)) {
                    Label("Share JSON", systemImage: "curlybraces").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button {
                    Self.printHTML(Analytics.Trends.prescriberHTML(dashboard, now: Date()), job: "Log prescriber report")
                } label: {
                    Label("Print or save PDF", systemImage: "printer").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button {
                    Self.printHTML(Analytics.Trends.coachPackHTML(dashboard, now: Date(), proteinTarget: proteinTarget), job: "Log 4-week coach pack")
                } label: {
                    Label("4-week coach pack", systemImage: "doc.text").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .tint(LogColor.accent)
            Caption("CSV has meals, weigh-ins, doses, check-ins, side effects and measurements. JSON has everything the app loaded.")
            Caption("The 4-week pack is a one-pager of recent weight, doses, protein hit rate, food thoughts and side effects, meant for a doctor.")
        }
    }

    /// The system print sheet for an HTML page (it can also save a PDF).
    @MainActor
    static func printHTML(_ html: String, job: String) {
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .general
        info.jobName = job
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printFormatter = UIMarkupTextPrintFormatter(markupText: html)
        controller.present(animated: true, completionHandler: nil)
    }
}
