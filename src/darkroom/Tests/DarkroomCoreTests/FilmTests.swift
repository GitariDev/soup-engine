import DarkroomCore
import XCTest

final class FilmTests: XCTestCase {
    private func shelf(_ r: Rig) -> FilmShelf {
        FilmShelf(cardFolder: r.root.appendingPathComponent("ML/FILM"),
                  addedFolder: r.support.appendingPathComponent("Films"),
                  bundledFolder: r.root.appendingPathComponent("bundled"), loader: Rig.loader)
    }

    func testCardWinsOneEntryPerNameInOrder() throws {
        let r = try Rig(films: ["PORTRA", "VELVIA"])
        try r.put("ML/FILM/mine.fs", "portra")
        try r.put("../support/Films/velvia2.fs", "Velvia")
        try r.put("../support/Films/extra.fs", "EXTRA")
        let s = shelf(r)
        XCTAssertEqual(s.films.map(\.name), ["portra", "EXTRA", "Velvia"])
        XCTAssertEqual(s.films.map(\.source), [.card, .added, .added])
        XCTAssertEqual(s.film(named: "PORTRA")?.source, .card)
    }

    func testRefusedFilesAreCollectedAndDotfilesIgnored() throws {
        let r = try Rig(films: ["PORTRA"])
        let bad = try r.put("ML/FILM/bad.fs", "BAD")
        try r.put("ML/FILM/._portra.fs", "BAD")
        try r.put("ML/FILM/notes.txt", "BAD")
        let s = shelf(r)
        XCTAssertEqual(s.rejected.map(\.path), [bad])
        XCTAssertFalse(s.rejected[0].reason.isEmpty)
    }

    func testAddFilmCopiesAndValidates() throws {
        let r = try Rig(films: [])
        var s = shelf(r)
        let film = try s.addFilm(from: try r.put("downloads/new.fs", "NEW FILM"))
        XCTAssertEqual(film.source, .added)
        XCTAssertEqual(film.path.deletingLastPathComponent().lastPathComponent, "Films")
        XCTAssertEqual(s.films.map(\.name), ["NEW FILM"])
        XCTAssertThrowsError(try s.addFilm(from: try r.put("downloads/worse.fs", "BAD"))) {
            XCTAssertEqual($0 as? FilmError, .refused(r.root.appendingPathComponent("downloads/worse.fs")))
        }
        XCTAssertThrowsError(try s.addFilm(from: try r.put("downloads/x.txt", "FINE")))
    }

    func testAddFilmNeverOverwrites() throws {
        let r = try Rig(films: [])
        var s = shelf(r)
        let first = try s.addFilm(from: try r.put("a/same.fs", "SAME\none"))

        // The same bytes again: nothing happens.
        XCTAssertEqual(try s.addFilm(from: try r.put("b/same.fs", "SAME\none")).path, first.path)

        // The same name, another film: refused, and the first is untouched.
        XCTAssertThrowsError(try s.addFilm(from: try r.put("c/same.fs", "same\ntwo")))
        XCTAssertEqual(try String(contentsOf: first.path, encoding: .utf8), "SAME\none")

        // The same file name, another film: both kept.
        let other = try s.addFilm(from: try r.put("d/same.fs", "OTHER"))
        XCTAssertNotEqual(other.path, first.path)
        XCTAssertEqual(s.films.count, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: first.path.deletingLastPathComponent().path).count, 2)
    }

    func testAddFilmNeverWritesToACard() throws {
        let r = try Rig(films: [])
        var s = FilmShelf(cardFolder: nil, addedFolder: r.root.appendingPathComponent("ML/FILM"),
                          bundledFolder: nil, loader: Rig.loader)
        XCTAssertThrowsError(try s.addFilm(from: try r.put("a.fs", "NEW")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.root.appendingPathComponent("ML/FILM").path))
    }

    func testDisplay() {
        XCTAssertEqual(Film.display("CLASSIC CHROME"), "Classic Chrome")
        XCTAssertEqual(Film.display("SOUP 800"), "Soup 800")
        XCTAssertEqual(Film.display("B&W"), "B&W")
        XCTAssertEqual(Film.display("XP2"), "XP2")
        XCTAssertEqual(Film.display("My Film"), "My Film")
    }

    func testCans() {
        let portra = FilmCan.forFilm("portra")
        XCTAssertEqual([portra.brand, portra.iso, portra.c1, portra.c2, portra.c3],
                       ["KODAK", "400", "#f4f0e6", "#ef9a1e", "#1d2029"])
        XCTAssertEqual(FilmCan.forFilm("NEVER HEARD OF IT"), .unknown)
    }

    func testTheRealStocksThroughTheRealParser() throws {
        let stocks = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("stocks")
        let r = try Rig(films: [])
        let garbage = try r.put("ML/FILM/garbage.fs", "this is not a film\n")
        let s = FilmShelf(cardFolder: garbage.deletingLastPathComponent(), addedFolder: nil, bundledFolder: stocks)
        XCTAssertEqual(s.films.count, 13)
        XCTAssertEqual(s.rejected.map(\.path), [garbage])
        XCTAssertEqual(s.film(named: "classic chrome")?.displayName, "Classic Chrome")
        for film in s.films {
            XCTAssertEqual(film.source, .bundled)
            XCTAssertNotEqual(film.can, .unknown, film.name)
            XCTAssertFalse(film.description.isEmpty, film.name)
        }
    }

    func testShelfReadsInTheCamerasOrderWithUnknownFilmsAfter() throws {
        let r = try Rig(films: ["VELVIA", "ACROS", "ZED", "GOLD", "PORTRA", "ALPHA", "ETERNA"])
        XCTAssertEqual(r.shelf.ordered.map(\.name), ["PORTRA", "GOLD", "VELVIA", "ACROS", "ETERNA", "ALPHA", "ZED"])
        XCTAssertEqual(r.shelf.ordered.count, r.shelf.films.count)
    }
}
