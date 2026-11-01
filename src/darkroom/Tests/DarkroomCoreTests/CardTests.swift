import CryptoKit
import DarkroomCore
import XCTest

final class CardTests: XCTestCase {
    func testFinderSeesCardsAndPrefersML() throws {
        let plain = try Rig(), ml = try Rig(), none = try Rig()
        try plain.cr2("IMG_0001.CR2")
        try ml.put("ML/README", "x")
        try FileManager.default.removeItem(at: none.root.appendingPathComponent("DCIM/100CANON"))
        try none.put("DCIM/EOSMISC/x", "x")
        let cards = CardFinder.findCards(volumes: [plain.root, none.root, ml.root])
        XCTAssertEqual(cards.map(\.root), [ml.root, plain.root])
        XCTAssertEqual(cards[1].dcfFolders.map(\.lastPathComponent), ["100CANON"])
    }

    func testDCFNames() {
        for n in ["100CANON", "101_0101", "999abcde"] { XCTAssertTrue(CardName.isDCFFolder(n), n) }
        for n in ["EOSMISC", "100CANO", "100CANONX", "10XCANON", "100 CANO"] { XCTAssertFalse(CardName.isDCFFolder(n), n) }
    }

    func testOpenCardRootDcimAndDcf() throws {
        let r = try Rig()
        try r.cr2("IMG_0001.CR2", folder: "DCIM/101CANON")
        try r.put("DCIM/EOSMISC/M0001.CTG", "x")
        try r.put("ML/FILM/portra.fs", "PORTRA")
        try r.roll(line((100, 1), (100, 1)))
        for pick in ["", "DCIM"] {
            let s = try Bench.open(folderOrFile: r.root.appendingPathComponent(pick))
            XCTAssertEqual(s.folders.map(\.lastPathComponent), ["100CANON", "101CANON"], pick)
            XCTAssertEqual(s.filmFolder?.lastPathComponent, "FILM")
            XCTAssertEqual(s.rollFile?.lastPathComponent, "SOUPROLL.TXT")
        }
        let dcf = try Bench.open(folderOrFile: r.dcf)
        XCTAssertEqual(dcf.folders.map(\.lastPathComponent), ["100CANON"])
        XCTAssertNotNil(dcf.rollFile)
    }

    func testOpenSingleCR2() throws {
        let r = try Rig()
        let one = try r.cr2("IMG_0001.CR2")
        try r.cr2("IMG_0002.CR2")
        try r.flm("FLM_0001.JPG")
        try r.roll(line((100, 1), (100, 1)))
        let frames = try r.frames(of: one)
        XCTAssertEqual(frames.map(\.name), ["IMG_0001.CR2"])
        XCTAssertEqual(frames[0].state, .printed)
        XCTAssertEqual(frames[0].shotOnFilm?.source, .roll)
        XCTAssertThrowsError(try Bench.open(folderOrFile: r.put("notes.txt", "x")))
    }

    func testOpenPlainFolderAcceptsARollInIt() throws {
        let r = try Rig()
        try r.cr2("IMG_0001.CR2", folder: "Backup")
        let roll = try r.put("Backup/SOUPROLL.TXT", "")
        let s = try Bench.open(folderOrFile: roll.deletingLastPathComponent())
        XCTAssertEqual(s.folders.map(\.lastPathComponent), ["Backup"])
        XCTAssertEqual(s.rollFile?.lastPathComponent, "SOUPROLL.TXT")
    }

    func testOpenFindsMLWhatEverItsCase() throws {
        let r = try Rig()
        try r.put("ml/data/souproll.txt", "")
        try r.put("ml/film/a.fs", "A")
        let s = try Bench.open(folderOrFile: r.dcf)
        XCTAssertNotNil(s.rollFile)
        XCTAssertNotNil(s.filmFolder)
    }

    func testScanListsPrintsIgnoresDotfilesKeepsTheUnreadable() throws {
        let r = try Rig()
        try r.cr2("IMG_0001.CR2")
        try r.cr2("._IMG_0001.CR2")
        try r.put("DCIM/100CANON/IMG_0002.CR2", "BAD")
        try r.put("DCIM/100CANON/IMG_0003.cr2", "")
        try r.flm("FLM_0001.JPG")
        try FileManager.default.createDirectory(at: r.dcf.appendingPathComponent("IMG_0009.CR2"), withIntermediateDirectories: true)
        let listing = FrameScanner(probe: Rig.probe).list(r.dcf)
        XCTAssertEqual(listing.prints.keys.sorted(), ["0001"])
        let frames = try r.frames()
        XCTAssertEqual(frames.map(\.name), ["IMG_0001.CR2", "IMG_0002.CR2", "IMG_0003.cr2"])
        XCTAssertEqual(frames.map(\.isReadable), [true, false, false])
    }

    func testStreamDeliversEveryFrame() async throws {
        let r = try Rig()
        for n in 1...7 { try r.cr2("IMG_000\(n).CR2") }
        let source = try Bench.open(folderOrFile: r.root)
        var got: [FrameFile] = [], total = 0, finished = false
        for await e in FrameScanner(probe: Rig.probe, batchSize: 3).stream(source) {
            switch e {
            case .listed(let t, _): total = t
            case .frames(let f): got += f
            case .finished: finished = true
            }
        }
        XCTAssertEqual(total, 7)
        XCTAssertEqual(got, FrameScanner(probe: Rig.probe).scan(source))
        XCTAssertTrue(finished)
    }

    func testScanningAReadOnlyTreeChangesNothing() throws {
        let r = try Rig()
        for n in 1...4 {
            try r.cr2("IMG_000\(n).CR2")
            try r.flm("FLM_000\(n).JPG")
        }
        try r.cr2("._IMG_0001.CR2")
        try r.roll(line((100, 1), (100, 4)))
        try r.put("ML/FILM/portra.fs", "PORTRA")
        let card = [r.root.appendingPathComponent("DCIM"), r.root.appendingPathComponent("ML")]

        func snapshot() throws -> [String: String] {
            var out: [String: String] = [:]
            for top in card {
                out[top.path] = "dir"
                for case let url as URL in try XCTUnwrap(FileManager.default.enumerator(at: top, includingPropertiesForKeys: nil)) {
                    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                    let mtime = "\(attrs[.modificationDate]!)"
                    if attrs[.type] as? FileAttributeType == .typeDirectory {
                        out[url.path] = "dir \(mtime)"
                    } else {
                        let hash = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
                        out[url.path] = "\(hash) \(mtime)"
                    }
                }
            }
            return out
        }

        for top in card {
            let p = try Process.run(URL(fileURLWithPath: "/bin/chmod"), arguments: ["-R", "a-w", top.path])
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0)
        }
        let before = try snapshot()
        XCTAssertEqual(try r.frames().count, 4)
        _ = FilmShelf(cardFolder: try Bench.open(folderOrFile: r.root).filmFolder, addedFolder: nil, bundledFolder: nil, loader: Rig.loader)
        XCTAssertEqual(try snapshot(), before)
    }
}
