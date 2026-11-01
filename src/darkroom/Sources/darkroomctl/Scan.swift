// `scan` and `cards`: a card as the app would read it, from a terminal. These
// write nothing. No record is saved, and no record directory is created unless
// --record asks for a look at one, which works on a copy in the temp folder.
import DarkroomCore
import Foundation

struct ScanReport: Encodable {
    struct Roll: Encodable {
        let path: String
        let lines: Int
        let skipped: Int
        let latestRoll: Int?
    }
    struct Rejected: Encodable {
        let path: String
        let reason: String
    }
    struct Row: Encodable {
        let path: String
        let name: String
        let folder: String
        let state: String
        let shotOn: String?
        let shotOnSource: String?
        let developing: String?
        let developed: Bool
        let canPrint: Bool
        let cardPrint: String?
        let printFilm: String?
        let cutOffPrint: Bool
        let reason: String?
    }
    struct Counts: Encodable {
        let all, shotOn, printed, yourChoice, noRecord, notDeveloped: Int
    }

    let picked: String
    let folders: [String]
    let filmFolder: String?
    let films: Int
    let rejected: [Rejected]
    let roll: Roll?
    let record: String?
    let frames: [Row]
    let counts: Counts
}

func json(_ value: some Encodable) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

/// Pads each column to its widest cell. The last column is left to run on.
func table(_ rows: [[String]]) {
    let widths = (0..<(rows.first?.count ?? 0)).map { col in rows.map { $0[col].count }.max() ?? 0 }
    for row in rows {
        let cells = zip(row, widths).enumerated().map { col, cell in
            col == row.count - 1 ? cell.0 : cell.0.padding(toLength: cell.1, withPad: " ", startingAt: 0)
        }
        print(cells.joined(separator: "  "))
    }
}

/// `--stocks`, else the `stocks` folder above this program, which is src/stocks
/// in a build tree. The app's copy is Contents/Resources/stocks.
func stocksFolder(_ arg: String?) -> URL? {
    if let arg { return URL(fileURLWithPath: arg, isDirectory: true) }
    guard var at = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
    while at.path != "/" {
        at.deleteLastPathComponent()
        let stocks = at.appendingPathComponent("stocks", isDirectory: true)
        if FileManager.default.fileExists(atPath: stocks.appendingPathComponent("INDEX.TXT").path) { return stocks }
    }
    return nil
}

/// A record that is never saved. `load` may move a damaged file aside, so a
/// real record is only ever loaded from a copy.
func readOnlyRecord(_ dir: URL?) throws -> BenchRecord {
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("darkroomctl-\(getpid())")
    guard let dir else { return BenchRecord(directory: scratch) }
    let file = BenchRecord(directory: dir).file
    guard FileManager.default.fileExists(atPath: file.path) else { return BenchRecord(directory: scratch) }
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let copy = BenchRecord(directory: scratch).file
    try FileManager.default.copyItem(at: file, to: copy)
    let record = try BenchRecord.load(directory: scratch)
    if record.setAside != nil {
        FileHandle.standardError.write(Data("darkroomctl: \(file.path) cannot be read, so it is ignored\n".utf8))
    }
    return record
}

func stateLabel(_ state: FrameState) -> String {
    switch state {
    case .yourChoice: return "Your choice"
    case .printed: return "Printed"
    case .shotOn: return "Shot on"
    case .noRecord: return "No record"
    }
}

func row(_ frame: Frame) -> ScanReport.Row {
    var reason = frame.noRecordReason ?? frame.printHold
    if frame.file.cutOffPrint {
        reason = [reason, "The FLM_ beside it is empty, so it is not a print."].compactMap { $0 }.joined(separator: " ")
    }
    return ScanReport.Row(
        path: frame.file.url.path, name: frame.name, folder: frame.file.folderName,
        state: stateLabel(frame.state), shotOn: frame.shotOnFilm?.film,
        shotOnSource: frame.shotOnFilm.map { $0.source == .roll ? "roll" : "card print" },
        developing: frame.developingFilm, developed: frame.isDeveloped, canPrint: frame.canPrint,
        cardPrint: frame.cardPrint?.url.lastPathComponent, printFilm: frame.cardPrint?.film,
        cutOffPrint: frame.file.cutOffPrint, reason: reason)
}

func scan(_ args: [String]) async throws {
    guard let path = args.first, !path.hasPrefix("--") else { throw UsageError() }
    var asJSON = false, useRecord = false, recordDir: URL?, stocksArg: String?
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--json": asJSON = true
        case "--stocks":
            i += 1
            guard i < args.count else { throw UsageError() }
            stocksArg = args[i]
        case "--record":
            useRecord = true
            if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                i += 1
                recordDir = URL(fileURLWithPath: args[i], isDirectory: true)
            }
        default: throw UsageError()
        }
        i += 1
    }

    let source = try Bench.open(folderOrFile: URL(fileURLWithPath: path))
    let shelf = FilmShelf(cardFolder: source.filmFolder, bundledFolder: stocksFolder(stocksArg))
    let roll = source.rollFile.flatMap(RollFile.read)
    let recordAt = useRecord ? (recordDir ?? BenchRecord.defaultDirectory) : nil
    var record = try readOnlyRecord(recordAt)
    let frames = Frame.assemble(FrameScanner().scan(source), roll: roll, record: &record, shelf: shelf)
    let counts = FilterCounts(frames)

    let report = ScanReport(
        picked: source.picked.path, folders: source.folders.map(\.path), filmFolder: source.filmFolder?.path,
        films: shelf.films.count,
        rejected: shelf.rejected.map { .init(path: $0.path.path, reason: $0.reason) },
        roll: source.rollFile.flatMap { url in
            roll.map { .init(path: url.path, lines: $0.lines.count, skipped: $0.skipped, latestRoll: $0.latestRoll) }
        },
        record: recordAt?.path, frames: frames.map(row),
        counts: .init(all: counts.all, shotOn: counts.shotOn, printed: counts.printed,
                      yourChoice: counts.yourChoice, noRecord: counts.noRecord, notDeveloped: counts.notDeveloped))

    if asJSON {
        try json(report)
    } else {
        printReport(report)
    }
    if frames.isEmpty {
        FileHandle.standardError.write(Data("darkroomctl: no frames in \(path)\n".utf8))
        exit(1)
    }
}

func printReport(_ r: ScanReport) {
    var head = [["source", r.picked],
                ["folders", r.folders.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")],
                ["film folder", r.filmFolder ?? "none"],
                ["films", "\(r.films) on the shelf, \(r.rejected.count) rejected"]]
    head += r.rejected.map { ["rejected", "\($0.path): \($0.reason)"] }
    if let roll = r.roll {
        let latest = roll.latestRoll.map(String.init) ?? "none"
        head.append(["roll file", roll.path])
        head.append(["roll", "\(roll.lines) lines, \(roll.skipped) skipped, latest roll \(latest)"])
    } else {
        head.append(["roll file", "none"])
    }
    head.append(["record", r.record ?? "none"])
    table(head)
    print()

    table([["FRAME", "STATE", "SHOT ON", "FROM", "DEVELOPS ON", "DEVELOPED", "PRINT", "REASON"]]
        + r.frames.map {
            ["\($0.folder)/\($0.name)", $0.state, $0.shotOn ?? "-", $0.shotOnSource ?? "-", $0.developing ?? "-",
             $0.developed ? "yes" : "no", $0.canPrint ? "yes" : "no", $0.reason ?? ""]
        })
    print()

    let c = r.counts
    table([["All", "Shot on", "Printed", "Your choice", "No record", "Not developed"],
           [c.all, c.shotOn, c.printed, c.yourChoice, c.noRecord, c.notDeveloped].map(String.init)])
}

func cards(_ args: [String]) async throws {
    guard args.isEmpty || args == ["--json"] else { throw UsageError() }
    struct Row: Encodable {
        let name: String
        let root: String
        let hasML: Bool
        let folders: [String]
        let frames: Int
    }
    let scanner = FrameScanner()
    let found = CardFinder.findCards().map { card in
        Row(name: card.name, root: card.root.path, hasML: card.hasML,
            folders: card.dcfFolders.map(\.lastPathComponent),
            frames: card.dcfFolders.reduce(0) { $0 + scanner.list($1).cr2s.count })
    }
    if args == ["--json"] { return try json(found) }
    if found.isEmpty { return print("no cards") }
    table([["CARD", "ROOT", "ML", "FRAMES", "FOLDERS"]]
        + found.map { [$0.name, $0.root, $0.hasML ? "yes" : "no", String($0.frames), $0.folders.joined(separator: ", ")] })
}
