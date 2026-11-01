import DarkroomCore
import Foundation
import XCTest

/// A card in a temp folder. Fixture CR2s hold their facts as text, read back by
/// `Rig.probe`, so nothing depends on real raws: `time|exposure`, or `BAD`.
final class Rig {
    /// The card. Its parent also holds `support`, off the card as it must be.
    let root: URL
    var support: URL { root.deletingLastPathComponent().appendingPathComponent("support") }
    var dcf: URL { root.appendingPathComponent("DCIM/100CANON") }
    var record: BenchRecord
    var shelf: FilmShelf

    static let time = "2026:11:01 12:00:00"

    static let probe = FrameProbe(
        cr2: { url in
            guard let s = try? String(contentsOf: url, encoding: .utf8), !s.hasPrefix("BAD"), !s.isEmpty else { return nil }
            let p = s.split(separator: "|", omittingEmptySubsequences: false)
            return CR2Facts(dateTime: String(p[0]), exposure: Double(p[1]) ?? 0)
        },
        printFilm: { url in
            guard let s = try? String(contentsOf: url, encoding: .utf8), s != "NOTAG" else { return nil }
            return s
        })

    /// A `.fs` here is a file with the name on its first line, or `BAD`.
    static let loader: FilmLoader = { url in
        guard let s = try? String(contentsOf: url, encoding: .utf8), !s.hasPrefix("BAD"),
              let line = s.split(separator: "\n").first else { return nil }
        return FilmInfo(name: String(line), description: "a film")
    }

    init(films: [String] = ["PORTRA", "VELVIA", "ETERNA"]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("core-\(UUID().uuidString)/card")
        record = BenchRecord(directory: root.deletingLastPathComponent().appendingPathComponent("support"))
        shelf = FilmShelf(cardFolder: nil, addedFolder: nil, bundledFolder: nil, loader: Rig.loader)
        try FileManager.default.createDirectory(at: dcf, withIntermediateDirectories: true)
        let bundled = root.appendingPathComponent("bundled")
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        for f in films { try f.write(to: bundled.appendingPathComponent(f.lowercased() + ".fs"), atomically: false, encoding: .utf8) }
        shelf = FilmShelf(cardFolder: nil, addedFolder: nil, bundledFolder: bundled, loader: Rig.loader)
    }

    deinit {
        _ = try? Process.run(URL(fileURLWithPath: "/bin/chmod"), arguments: ["-R", "u+w", root.path]).waitUntilExit()
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    @discardableResult
    func put(_ path: String, _ text: String = "") throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    @discardableResult
    func cr2(_ name: String, time: String = Rig.time, exposure: Double = 0.01, folder: String = "DCIM/100CANON") throws -> URL {
        try put("\(folder)/\(name)", "\(time)|\(exposure)")
    }

    @discardableResult
    func flm(_ name: String, film: String = "ETERNA", folder: String = "DCIM/100CANON") throws -> URL {
        try put("\(folder)/\(name)", film)
    }

    @discardableResult
    func roll(_ lines: String...) throws -> URL {
        try put("ML/DATA/SOUPROLL.TXT", lines.joined())
    }

    func frames(of picked: URL? = nil) throws -> [Frame] {
        let source = try Bench.open(folderOrFile: picked ?? root)
        let files = FrameScanner(probe: Rig.probe).scan(source)
        return Frame.assemble(files, roll: source.rollFile.flatMap(RollFile.read), record: &record, shelf: shelf)
    }

    func frame(_ name: String = "IMG_0001.CR2") throws -> Frame {
        try XCTUnwrap(frames().first { $0.name == name })
    }

    func can(_ name: String) throws -> Film { try XCTUnwrap(shelf.film(named: name)) }

    /// A desk print on disk, entered in the record.
    func deskPrint(_ frame: Frame, film: String, name: String = "print.JPG") throws -> URL {
        let url = try put("out/\(UUID().uuidString)-\(name)", "jpeg")
        record.addPrint(DeskPrint(url: url, film: film), identity: frame.identity)
        return url
    }
}

/// `R1 ...` for a range, clock 2026-11-01 at the time given.
func line(_ from: (Int, Int), _ to: (Int, Int), at clock: (Int, Int, Int) = (12, 0, 30), span: Int = 60,
          film: String = "PORTRA", roll: Int = 1, day: Int = 1) -> String {
    "R1 \(roll) \(from.0) \(from.1) \(to.0) \(to.1) 3 2026 11 \(day) \(clock.0) \(clock.1) \(clock.2) \(span) \(filmId(film)) \(film)\n"
}

/// `se_name_id`, in hex as the camera writes it.
func filmId(_ name: String) -> String {
    String(name.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }, radix: 16)
}
