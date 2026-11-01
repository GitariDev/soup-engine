import DarkroomCore
import SwiftUI

struct TrayView: View {
    @ObservedObject var bench: Bench

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            if let frame = bench.current {
                head(frame)
            } else {
                Kicker("PRINT TRAY")
            }
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 11) {
                    if let frame = bench.current {
                        middle(frame)
                    } else if !bench.visible.isEmpty {
                        dimText("Choose a frame on the strip.")
                    }
                    if let batch = bench.batch, batch.finished { batchSection(batch) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            if let batch = bench.batch, !batch.finished { batchSection(batch) }
            if let frame = bench.current {
                foot(frame)
            } else {
                printedLine(nil)
            }
        }
        .padding(16)
        .frame(width: 270, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.faint).frame(width: 1) }
    }

    // MARK: The states

    @ViewBuilder private func head(_ frame: Frame) -> some View {
        Kicker(!bench.isUnreadable(frame) && frame.state == .yourChoice ? "PRINT TRAY" : "THIS FRAME")
        if bench.isUnreadable(frame) {
            Chip(text: "CANNOT BE READ", color: Theme.warn)
        } else {
            switch frame.state {
            case .shotOn: Chip(text: "SHOT ON \(upper(frame.shotOnFilm?.film))", color: Theme.accent)
            case .yourChoice: Chip(text: "YOUR CHOICE · \(upper(frame.choice))", color: Theme.blue)
            case .noRecord: Chip(text: "NO FILM RECORDED", color: Theme.dim, dashed: true)
            case .printed:
                Chip(text: frame.printedFilms.last.map { "PRINTED · \(upper($0))" } ?? "PRINTED", color: Theme.green)
            }
        }
    }

    @ViewBuilder private func middle(_ frame: Frame) -> some View {
        if bench.isUnreadable(frame) {
            dimText("\(frame.file.stem). This CR2 cannot be read. It stays as it is.")
        } else {
            switch frame.state {
            case .shotOn:
                dimText(Self.facts(frame))
                developingOn(frame)
                printControls(frame)
            case .yourChoice:
                dimText(choiceLine(frame))
                printControls(frame)
            case .noRecord: noRecord(frame)
            case .printed: printed(frame)
            }
        }
    }

    @ViewBuilder private func noRecord(_ frame: Frame) -> some View {
        dimText("\(frame.file.stem). \(frame.noRecordReason ?? "") No film is assumed.")
        Kicker("DEVELOPING ON")
        Text("No film yet").font(Theme.display(24)).foregroundColor(Theme.text)
        dimText("Straight raw, shown as a negative carrier with no film loaded.")
        saveTo
    }

    @ViewBuilder private func printed(_ frame: Frame) -> some View {
        if frame.cardPrint != nil, frame.deskPrints.isEmpty {
            dimText("\(frame.file.stem). The print on the card stays as it is.\(shotOnSentence(frame))")
        } else if let print = frame.deskPrints.last {
            dimText("\(frame.file.stem). The print is in \(bench.place(print.url.deletingLastPathComponent())).\(shotOnSentence(frame))")
            finderLink(print.url)
        }
        developingOn(frame)
        printControls(frame)
    }

    private func shotOnSentence(_ frame: Frame) -> String {
        frame.shotOnFilm.map { " Shot on \(Film.display($0.film))." } ?? ""
    }

    /// Where the print goes, what it is called and how big.
    @ViewBuilder private func printControls(_ frame: Frame) -> some View {
        saveTo
        if frame.canPrint {
            Kicker("NAME")
            NameField(bench: bench)
            Kicker("SIZE")
            sizeMenu(frame)
        }
    }

    /// Pinned: what grows here grows upward, so Print never moves, and why
    /// Print waits can never scroll away from the button it explains.
    @ViewBuilder private func foot(_ frame: Frame) -> some View {
        holdLine(frame)
        printedLine(frame.id)
        printButton(frame, printTitle(frame))
        dimText("The CR2 is not changed.").font(Theme.font(11))
    }

    private func printTitle(_ frame: Frame) -> String {
        if bench.isUnreadable(frame) { return "Print to folder" }
        switch frame.state {
        case .noRecord: return "Print ▸"
        case .printed: return "Redevelop to folder"
        default: return "Print to folder"
        }
    }

    // MARK: The parts

    private func upper(_ name: String?) -> String { name.map(Film.key) ?? "" }

    private func dimText(_ text: String) -> Text {
        Text(text).font(Theme.font(13)).foregroundColor(Theme.dim)
    }

    private func choiceLine(_ frame: Frame) -> String {
        let film = Film.display(frame.choice ?? "")
        if let shot = frame.shotOnFilm { return "Shot on \(Film.display(shot.film)). Redeveloping on \(film)." }
        return "No film was recorded. Developing on \(film)."
    }

    private static func facts(_ frame: Frame) -> String {
        var parts = [frame.file.stem]
        if let facts = frame.file.facts {
            if facts.aperture > 0 {
                let f = facts.aperture
                parts.append(f == f.rounded() ? "f/\(Int(f))" : "f/\(String(format: "%.1f", f))")
            }
            if facts.exposure > 0 {
                let e = facts.exposure
                parts.append(e < 1 ? "1/\(Int((1 / e).rounded()))" : "\(String(format: "%g", e)) s")
            }
            if facts.iso > 0 { parts.append("ISO \(facts.iso)") }
        }
        return parts.joined(separator: " · ")
    }

    private func fullName(_ film: Film) -> String {
        let iso = film.can.iso
        return iso.isEmpty || film.name.contains(iso) ? film.displayName : "\(film.displayName) \(iso)"
    }

    private func pixels(_ frame: Frame, half: Bool) -> String {
        let w = frame.file.facts?.width ?? 0, h = frame.file.facts?.height ?? 0
        return half ? "\(w / 2)×\(h / 2)" : "\(w)×\(h)"
    }

    @ViewBuilder private func developingOn(_ frame: Frame) -> some View {
        Kicker("DEVELOPING ON")
        if let film = frame.developingCan {
            Text(fullName(film)).font(Theme.display(24)).foregroundColor(Theme.text)
        } else {
            Text("No film yet").font(Theme.display(24)).foregroundColor(Theme.text)
            dimText("Straight raw, shown as a negative carrier with no film loaded.")
        }
    }

    @ViewBuilder private func holdLine(_ frame: Frame) -> some View {
        if !bench.isUnreadable(frame), frame.state == .noRecord {
            Text("Pick a can from the shelf to print")
                .font(Theme.font(13)).foregroundColor(Theme.accent).modifier(Boxed())
        } else if let hold = bench.hold(frame) {
            Text(hold).font(Theme.font(13)).foregroundColor(Theme.accent).modifier(Boxed())
        }
    }

    @ViewBuilder private var saveTo: some View {
        Kicker("SAVE TO")
        Menu {
            Button(bench.place(bench.saveFolder)) {}
            if bench.saveFolder != Destination.defaultFolder() {
                Button(bench.place(Destination.defaultFolder())) { bench.setSaveFolder(Destination.defaultFolder()) }
            }
            Divider()
            Button("Choose folder...") {
                if let url = Panels.pickFolder() { bench.setSaveFolder(url) }
            }
        } label: {
            HStack {
                Text(bench.place(bench.saveFolder)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text("▾")
            }
            .font(Theme.font(13)).foregroundColor(Theme.text)
            .modifier(Boxed())
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        if let problem = bench.saveProblem {
            Text(problem).font(Theme.font(12)).foregroundColor(Theme.warn).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sizeMenu(_ frame: Frame) -> some View {
        Menu {
            Button("Full raw · \(pixels(frame, half: false)) · JPEG 92") { bench.half = false }
            Button("Half · \(pixels(frame, half: true)) · JPEG 92") { bench.half = true }
        } label: {
            HStack {
                Text("\(bench.half ? "Half" : "Full raw") · \(pixels(frame, half: bench.half)) · JPEG 92")
                Spacer(minLength: 4)
                Text("▾")
            }
            .font(Theme.font(13)).foregroundColor(Theme.text)
            .modifier(Boxed())
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    private func finderLink(_ url: URL) -> some View {
        Button("Show in Finder") { bench.showInFinder(url) }
            .buttonStyle(.plain)
            .font(Theme.font(12, .semibold)).foregroundColor(Theme.accent)
    }

    /// Nil is the tray with no frame on it: a tab the last print just emptied.
    @ViewBuilder private func printedLine(_ frame: String?) -> some View {
        if let last = bench.lastPrint, frame == nil || last.frame == frame {
            Text("Printed \(last.url.lastPathComponent) to \(bench.place(last.url.deletingLastPathComponent())).")
                .font(Theme.font(12)).foregroundColor(Theme.green)
                .fixedSize(horizontal: false, vertical: true)
            finderLink(last.url)
        }
    }

    @ViewBuilder private func printButton(_ frame: Frame, _ title: String) -> some View {
        if let error = bench.printError {
            Text(error).font(Theme.font(12)).foregroundColor(Theme.warn)
                .fixedSize(horizontal: false, vertical: true)
        }
        Button(bench.printingIDs.contains(frame.id) ? "Printing..." : title) { bench.printCurrent() }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!bench.canPrintCurrent)
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { DriverAnchors.printRect = geo.frame(in: .global) }
                    .onChange(of: geo.frame(in: .global)) { _, rect in DriverAnchors.printRect = rect }
            })
    }

    // MARK: The batch

    @ViewBuilder private func batchSection(_ batch: BatchRun) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if batch.finished {
                Text("Printed \(batch.printed) to \(batch.place).")
                    .font(Theme.font(12, .semibold)).foregroundColor(Theme.green)
                if batch.notRun > 0 {
                    smallLine("Stopped. \(batch.notRun) not printed.")
                }
                ForEach(batch.holds, id: \.reason) { hold in
                    smallLine("Skipped \(hold.count). \(hold.reason).")
                }
                if batch.unreadable > 0 {
                    smallLine("Skipped \(batch.unreadable): cannot be read.")
                }
                if !batch.failures.isEmpty {
                    Text("\(batch.failures.count) failed").font(Theme.font(12, .semibold)).foregroundColor(Theme.warn)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(batch.failures) { failure in
                                smallLine("\(failure.name): \(failure.reason)")
                            }
                        }
                    }
                    .frame(minHeight: 44, maxHeight: 70)
                }
                Button("Show in Finder") { bench.showFolder(batch.folder) }
                    .buttonStyle(.plain)
                    .font(Theme.font(12, .semibold)).foregroundColor(Theme.accent)
            } else {
                HStack {
                    Text(batch.stopping ? "Finishing the print on the enlarger" : "Printing \(batch.started) of \(batch.total)")
                        .font(Theme.font(12, .semibold)).foregroundColor(Theme.accent)
                    Spacer()
                    Button("Stop") { bench.stopBatch() }
                        .buttonStyle(.plain)
                        .font(Theme.font(12, .bold)).foregroundColor(Theme.text)
                        .disabled(batch.stopping)
                }
                ProgressView(value: Double(batch.printed + batch.failures.count), total: Double(max(batch.total, 1)))
                    .tint(Theme.accent)
                    .controlSize(.small)
                smallLine("to \(batch.place)")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.faint))
    }

    private func smallLine(_ text: String) -> some View {
        Text(text).font(Theme.font(11)).foregroundColor(Theme.dim).fixedSize(horizontal: false, vertical: true)
    }
}

/// The print's name. Space and the arrows belong to this field while it has focus.
private struct NameField: View {
    @ObservedObject var bench: Bench

    var body: some View {
        TextField("", text: Binding(get: { bench.printName }, set: { bench.nameDraft = $0 }))
            .textFieldStyle(.plain)
            .font(Theme.font(13)).foregroundColor(Theme.text)
            .onSubmit { Panels.dropFocus() }
            .modifier(Boxed())
    }
}
