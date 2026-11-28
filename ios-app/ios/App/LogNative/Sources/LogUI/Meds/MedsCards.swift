import SwiftUI
import LogCore

struct MLTitrationCard: View {
    let data: Dashboard

    var body: some View {
        let steps = Analytics.titrationHistory(data.doses)
        LogCard("Titration history") {
            if steps.isEmpty {
                EmptyNote("No doses yet.")
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(steps) { s in row(s) }
                }
                .padding(.leading, 18)
                .background(alignment: .topLeading) {
                    Rectangle().fill(LogColor.hairline).frame(width: 2)
                        .padding(.leading, 4).padding(.vertical, 6)
                }
            }
        }
    }

    private func row(_ s: TitrationStep) -> some View {
        let d = s.dose
        let what = d.skipped == true ? "Skipped \(MLFmt.cap(d.compound))" : "\(Fmt.num(s.mg, 1)) mg \(MLFmt.cap(d.compound))"
        return VStack(alignment: .leading, spacing: 1) {
            Text(d.takenDate.map(MLFmt.day) ?? "—").font(.footnote).foregroundStyle(LogColor.ink2)
            HStack(spacing: 8) {
                Text(what).font(.subheadline.weight(.semibold)).foregroundStyle(LogColor.ink)
                if s.changed && s.mg != nil { MLBadge("Change", .steady) }
            }
            if let site = d.site, !site.isEmpty {
                Text(MLFmt.site(site)).font(.footnote).foregroundStyle(LogColor.ink2)
            }
        }
        .overlay(alignment: .topLeading) {
            Circle().fill(s.changed ? LogColor.s3 : LogColor.axis)
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(LogColor.surface, lineWidth: 2))
                .offset(x: -18, y: 4)
        }
        .accessibilityElement(children: .combine)
    }
}

struct MLProtocolCard: View {
    let data: Dashboard

    var body: some View {
        LogCard("Protocol") {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(data.protocols.enumerated()), id: \.offset) { i, p in
                    if i > 0 { MLHairline() }
                    item(p)
                }
            }
        }
    }

    private func item(_ p: ProtocolRow) -> some View {
        let freq = p.frequency ?? ""
        let dose: String
        if let mg = p.typicalDoseMg { dose = "\(Fmt.num(mg, 1)) mg \(freq)".trimmingCharacters(in: .whitespaces) }
        else if let u = p.units { dose = "\(Fmt.num(u, 0)) units \(freq)".trimmingCharacters(in: .whitespaces) }
        else { dose = "—" }
        let active = p.status == "active"
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(p.displayName ?? MLFmt.cap(p.compound)).font(.headline).foregroundStyle(LogColor.ink)
                if let st = p.status, !st.isEmpty { MLBadge(MLFmt.cap(st), active ? .good : .steady) }
            }
            VStack(spacing: 0) {
                PropRow("Dose", dose)
                MLHairline()
                PropRow("Half-life", p.halfLifeHours.map { "\(Fmt.num($0 / 24, 1)) days" } ?? "—")
                MLHairline()
                PropRow(active ? "Started" : "Starts", (p.startedOn ?? "").isEmpty ? "—" : MLFmt.shortKey(p.startedOn))
            }
            if let notes = p.notes, !notes.isEmpty { Caption(notes) }
        }
    }
}

struct MLVialsCard: View {
    let data: Dashboard

    struct Total { var compound: String?; var mg = 0.0; var count = 0; var unopened = 0 }
    struct VialGroup { var compound: String?; var name: String; var unopened: Bool; var vials: [Vial] }

    static func isUnopened(_ v: Vial) -> Bool { (v.openedAt ?? "").isEmpty && (v.startedOn ?? "").isEmpty }

    static func totals(_ items: [VialItem]) -> [Total] {
        var out: [Total] = []
        for i in items {
            let v = i.vial
            var idx = out.firstIndex { $0.compound == v.compound }
            if idx == nil { out.append(Total(compound: v.compound)); idx = out.count - 1 }
            if let mg = v.remainingMg ?? v.totalMg { out[idx!].mg += mg }
            out[idx!].count += 1
            if isUnopened(v) { out[idx!].unopened += 1 }
        }
        return out
    }

    static func groups(_ items: [VialItem]) -> [VialGroup] {
        var keys: [String] = []
        var map: [String: VialGroup] = [:]
        for i in items {
            let v = i.vial
            let unopened = isUnopened(v)
            let name = (v.label ?? "").replacingOccurrences(of: #"\s*#\d+$"#, with: "", options: .regularExpression)
            let key = unopened
                ? "\(v.compound ?? "")|\(name)|\(v.totalMg.map { "\($0)" } ?? "")|\(v.totalUnits.map { "\($0)" } ?? "")"
                : "open|\(v.id ?? UUID().uuidString)"
            if map[key] == nil { keys.append(key); map[key] = VialGroup(compound: v.compound, name: name, unopened: unopened, vials: []) }
            map[key]!.vials.append(v)
        }
        return keys.compactMap { map[$0] }
    }

    static func groupDetail(_ g: VialGroup) -> String {
        if g.unopened {
            let sum = g.vials.reduce(0.0) { $0 + (($1.remainingMg ?? $1.totalMg) ?? 0) }
            return "Unopened, \(MLFmt.auto(sum)) mg"
        }
        let v = g.vials[0]
        var bits: [String] = []
        if let rem = v.remainingMg { bits.append("\(Fmt.num(rem, 1)) of \(Fmt.num(v.totalMg, 1)) mg left") }
        if let u = v.remainingUnits { bits.append("\(Fmt.num(u, 0)) units left") }
        if let e = v.expiredOn, !e.isEmpty { bits.append("discard \(MLFmt.shortKey(e))") }
        return bits.isEmpty ? "Open" : bits.joined(separator: ", ")
    }

    var body: some View {
        let r = Analytics.vialRunway(data)
        if !r.ready {
            LogCard("Vials") { EmptyNote("\(r.summary) Use Start a vial on the Log tab.") }
        } else {
            let totals = Self.totals(r.items)
            let groups = Self.groups(r.items)
            LogCard("Vials") {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], alignment: .leading, spacing: 10) {
                    ForEach(Array(totals.enumerated()), id: \.offset) { _, t in
                        MLTile(label: MLFmt.cap(t.compound), value: "\(MLFmt.auto(t.mg)) mg", detail: Self.totalDetail(t))
                    }
                }
                VStack(spacing: 0) {
                    ForEach(Array(groups.enumerated()), id: \.offset) { i, g in
                        if i > 0 { MLHairline() }
                        PropRow("\(g.name.isEmpty ? MLFmt.cap(g.compound) : g.name)\(g.vials.count > 1 ? ", \(g.vials.count) vials" : "")", Self.groupDetail(g))
                    }
                }
                if let until = r.soonest?.until {
                    Caption("At the planned weekly dose, supply lasts until about \(MLFmt.day(until)).")
                }
                if let note = Self.runwayNote(data) { Caption(note) }
            }
        }
    }

    static func totalDetail(_ t: Total) -> String {
        let base = MLFmt.count(t.count, "vial")
        if t.unopened == t.count { return base + ", all unopened" }
        if t.unopened > 0 { return base + ", \(t.unopened) unopened" }
        return base
    }

    static func runwayNote(_ data: Dashboard, now: Date = Date()) -> String? {
        let tirz = Analytics.compoundRunway(data, "tirzepatide", now: now)
        let reta = Analytics.compoundRunway(data, "retatrutide", now: now)
        if !tirz.ready && !reta.ready { return nil }
        let inPlay = Analytics.compoundsInPlay(data)
        var bits: [String] = []
        if tirz.ready, inPlay.contains("tirzepatide") {
            if let switchAt = LogTime.switchStart {
                let days = MLFmt.days(until: switchAt, now: now)
                let shotsNeeded = days > 0 ? Int((Double(days) / 7).rounded(.up)) : 0
                if days <= 0 {
                    let have = tirz.mg.map { "\(MLFmt.auto($0)) mg on hand" } ?? MLFmt.count(tirz.items.count, "vial")
                    bits.append("Tirzepatide: \(have). The switch date has arrived.")
                } else if let weeks = tirz.weeks {
                    let shotsLeft = Int(weeks.rounded(.down))
                    let enough = shotsLeft >= shotsNeeded
                    let mgText = tirz.mg.map(MLFmt.auto) ?? "—"
                    let cover = enough ? " That covers the remaining tirzepatide weeks." : " That may run short before \(MLFmt.short(switchAt))."
                    bits.append("Tirzepatide: \(mgText) mg, about \(Fmt.num(weeks, 1)) weekly shot\(weeks == 1 ? "" : "s") at \(Fmt.num(tirz.weeklyMg, 1)) mg. The switch is in \(MLFmt.count(days, "day")) (about \(MLFmt.count(shotsNeeded, "shot"))).\(cover)")
                } else {
                    bits.append("Tirzepatide: \(MLFmt.count(tirz.items.count, "vial")) on hand.")
                }
            } else if let weeks = tirz.weeks {
                let mgText = tirz.mg.map(MLFmt.auto) ?? "—"
                bits.append("Tirzepatide: \(mgText) mg, about \(Fmt.num(weeks, 1)) weekly shot\(weeks == 1 ? "" : "s") at \(Fmt.num(tirz.weeklyMg, 1)) mg.")
            } else {
                bits.append("Tirzepatide: \(MLFmt.count(tirz.items.count, "vial")) on hand.")
            }
        } else if let switchAt = LogTime.switchStart, inPlay.contains("tirzepatide"), MLFmt.days(until: switchAt, now: now) > 0 {
            bits.append("No tirzepatide vials are logged, so runway before \(MLFmt.short(switchAt)) can’t be calculated.")
        }
        if inPlay.contains("retatrutide") {
            if reta.ready {
                if let weeks = reta.weeks, let wu = reta.weeklyUnits, wu != 0 {
                    bits.append("Retatrutide: \(Fmt.num(reta.units, 0)) units on hand, about \(Fmt.num(weeks, 1)) week\(weeks == 1 ? "" : "s") at \(Fmt.num(wu, 0)) units a week.")
                } else if let mg = reta.mg {
                    let wk = reta.weeks.map { ", about \(Fmt.num($0, 1)) week\($0 == 1 ? "" : "s")" } ?? ""
                    bits.append("Retatrutide: \(MLFmt.auto(mg)) mg on hand\(wk).")
                } else {
                    bits.append("Retatrutide: \(MLFmt.count(reta.items.count, "vial")) on hand.")
                }
            } else {
                bits.append("No retatrutide vials are logged yet.")
            }
        }
        return bits.isEmpty ? nil : bits.joined(separator: " ")
    }
}

struct MLDoseHistoryCard: View {
    let data: Dashboard

    var body: some View {
        LogCard("Dosing history") {
            if data.doses.isEmpty {
                EmptyNote("No doses logged yet.")
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text("When").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Dose").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Site").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(LogColor.ink2)
                    .padding(.bottom, 6)
                    ForEach(Array(data.doses.reversed().enumerated()), id: \.offset) { _, d in
                        row(d)
                    }
                }
            }
        }
    }

    private func row(_ d: Dose) -> some View {
        VStack(spacing: 0) {
            MLHairline()
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(d.takenDate.map(MLFmt.day) ?? "—")
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(d.skipped == true ? "Skipped" : "\(Fmt.num(d.doseMg, 1)) mg")
                    Text(MLFmt.cap(d.compound)).font(.footnote).foregroundStyle(LogColor.ink2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(Analytics.siteLabel(d))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.subheadline)
            .foregroundStyle(LogColor.ink)
            .padding(.vertical, 8)
        }
        .accessibilityElement(children: .combine)
    }
}
