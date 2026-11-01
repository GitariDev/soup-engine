import DarkroomCore
import XCTest

final class RollTests: XCTestCase {
    private func roll(_ lines: String...) -> RollFile { RollFile(data: Data(lines.joined().utf8)) }
    private let shot = NaiveTime(exif: "2026:11:01 12:00:00")

    private func match(_ r: RollFile, folder: String = "100CANON", number: Int? = 11, time: NaiveTime? = nil,
                       exposure: Double = 0) -> RollMatch {
        r.match(folderName: folder, number: number, time: time ?? shot, exposure: exposure)
    }

    func testPlainLineParses() throws {
        let r = roll("R1 7 100 10 101 12 3 2026 11 1 12 0 30 60 \(filmId("CLASSIC CHROME")) CLASSIC CHROME\n")
        let l = try XCTUnwrap(r.lines.first)
        XCTAssertEqual([l.roll, l.fromFolder, l.fromNo, l.toFolder, l.toNo, l.count, l.span], [7, 100, 10, 101, 12, 3, 60])
        XCTAssertEqual(String(l.filmId, radix: 16), filmId("CLASSIC CHROME"))
        XCTAssertEqual(l.film, "CLASSIC CHROME")
        XCTAssertEqual(r.skipped, 0)
    }

    func testNumberInsideRangeMatches() {
        XCTAssertEqual(match(roll(line((100, 10), (100, 12)))).film, "PORTRA")
    }

    func testNumberOutsideRangeDoesNot() {
        XCTAssertNil(match(roll(line((100, 10), (100, 12))), number: 13).film)
        XCTAssertNil(match(roll(line((100, 10), (100, 12))), number: 9).film)
    }

    func testReusedNumberOutsideTheTimeWindowLinksNothing() {
        // R1: the counter was reset, and number 11 comes round a year later.
        let later = NaiveTime(exif: "2027:11:01 12:00:00")
        let m = match(roll(line((100, 10), (100, 12))), time: later)
        XCTAssertNil(m.film)
        XCTAssertNotNil(m.reason)
    }

    func testWrapFrom9999To1() {
        let r = roll(line((100, 9998), (100, 2)))
        for n in [9998, 9999, 1, 2] { XCTAssertEqual(match(r, number: n).film, "PORTRA", "\(n)") }
        for n in [9997, 3, 0, 5000] { XCTAssertNil(match(r, number: n).film, "\(n)") }
    }

    func testFolderChangeMatchesBothFolders() {
        let r = roll(line((100, 9999), (101, 1)))
        XCTAssertEqual(match(r, folder: "100CANON", number: 9999).film, "PORTRA")
        XCTAssertEqual(match(r, folder: "101CANON", number: 1).film, "PORTRA")
        XCTAssertNil(match(r, folder: "102CANON", number: 1).film)
    }

    func testOtherFolderDoesNotMatch() {
        XCTAssertNil(match(roll(line((100, 10), (100, 12))), folder: "101CANON").film)
    }

    func testFolderWithNoNumberNeverMatchesAndSaysWhy() {
        let r = roll(line((100, 10), (100, 12)))
        for name in ["Trip", "2024 trip", "100"] {
            let m = match(r, folder: name)
            XCTAssertNil(m.film, name)
            XCTAssertTrue(m.reason?.contains(name) ?? false, name)
        }
    }

    func testPickedFolderBesideItsRollIsNoMatch() throws {
        // A single folder with no number, and a roll sitting right there.
        let t = try Rig()
        try t.cr2("IMG_0011.CR2", folder: "Trip")
        try t.put("Trip/SOUPROLL.TXT", line((100, 10), (100, 12)))
        let f = try XCTUnwrap(t.frames(of: t.root.appendingPathComponent("Trip")).first)
        XCTAssertEqual(f.state, .noRecord)
        XCTAssertTrue(f.noRecordReason?.contains("Trip") ?? false)
    }

    func testTwoLinesWithDifferentFilmsAreNoRecord() throws {
        let t = try Rig()
        try t.cr2("IMG_0011.CR2")
        try t.flm("FLM_0011.JPG", film: "ETERNA")
        try t.roll(line((100, 10), (100, 12)), line((100, 11), (100, 11), film: "VELVIA"))
        let f = try t.frame("IMG_0011.CR2")
        guard case .conflict(let films, _) = f.rollMatch else { return XCTFail("\(f.rollMatch)") }
        XCTAssertEqual(films, ["PORTRA", "VELVIA"])
        XCTAssertNil(f.shotOnFilm)                  // not the Software tag either
        XCTAssertNil(f.developingFilm)
        XCTAssertNotNil(f.noRecordReason)
    }

    func testTwoLinesWithOneFilmAreFine() {
        let m = match(roll(line((100, 10), (100, 12)), line((100, 11), (100, 11), film: "portra")))
        XCTAssertEqual(m.film, "PORTRA")
    }

    func testCutOffFinalLineIsSkipped() {
        let whole = line((100, 10), (100, 12), film: "VELVIA")
        let r = roll(line((100, 1), (100, 2)), String(whole.dropLast()))
        XCTAssertEqual(r.lines.count, 1)
        XCTAssertEqual(r.skippedCutOff, 1)
        XCTAssertNil(match(r).film)
    }

    func testGoldenLineAsTheCameraWritesIt() {
        // 7f794de7 worked out by hand from se_name_id, not by the code under test.
        let r = roll("R1 0 100 3990 100 3990 1 2026 11 1 12 0 30 2 7f794de7 PORTRA\n")
        XCTAssertEqual(r.lines.first?.film, "PORTRA")
        XCTAssertEqual(r.skipped, 0)
    }

    func testTornLineGivenANewlineByTheCameraIsNotAShorterFilm() {
        // se_roll_write puts a newline after a tear, so this looks complete.
        let torn = "R1 1 100 10 100 12 3 2026 11 1 12 0 30 60 \(filmId("CLASSIC CHROME")) CLASSIC\n"
        let r = roll(torn, "\n", line((100, 20), (100, 21)))
        XCTAssertEqual(r.lines.map(\.film), ["PORTRA"])
        XCTAssertEqual(r.skippedMalformed, 1)
        XCTAssertNil(match(r).film)
    }

    func testNextLineLandingOnATornNameIsNotAFilm() {
        // A power cut forgets the tear, so the next line runs straight on from it.
        let whole = line((100, 10), (100, 12), film: "VELVIA")
        let torn = String(whole.dropLast(3))
        let r = roll(torn + line((100, 20), (100, 21)))
        XCTAssertEqual(r.lines.count, 0)
        XCTAssertEqual(r.skippedMalformed, 1)
    }

    func testTornIdIsNotAnId() {
        let id = filmId("PORTRA")
        let r = roll("R1 1 100 10 100 12 3 2026 11 1 12 0 30 60 \(id.dropLast(2)) PORTRA\n")
        XCTAssertEqual(r.lines.count, 0)
        XCTAssertEqual(r.skippedMalformed, 1)
    }

    func testUnknownTagIsSkippedAndCounted() {
        let r = roll("R2 a line from a newer camera\n", line((100, 10), (100, 12)))
        XCTAssertEqual(r.lines.count, 1)
        XCTAssertEqual(r.skippedUnknownTag, 1)
    }

    func testMalformedLinesAreSkippedAndCounted() {
        let id = filmId("PORTRA")
        let bad = [
            "R1 1 100 10\n",                                                    // short
            "R1 x 100 10 100 12 3 2026 11 1 12 0 30 60 \(id) PORTRA\n",      // not a number
            "R1 1 100 10 100 12 3 2026 13 1 12 0 30 60 \(id) PORTRA\n",      // month 13
            "R1 1 100 10 100 12 3 2026 2 30 12 0 30 60 \(id) PORTRA\n",      // 30 February
            "R1 1 100 10 100 12 3 2026 11 1 12 0 30 -5 \(id) PORTRA\n",      // negative span
            "R1 1 100 10 100 12 3 2026 11 1 12 0 30 60 nothex PORTRA\n",
            "R1 1 100 10 100 12 3 2026 11 1 12 0 30 60 \(id)\n",             // no film
            "\u{1}\u{2}junk\n",
        ]
        let r = RollFile(data: Data(bad.joined().utf8))
        XCTAssertEqual(r.lines.count, 0)
        XCTAssertEqual(r.skippedMalformed, bad.count)
    }

    func testBlankAndCRLFLines() {
        let r = roll("\n", line((100, 10), (100, 12)).replacingOccurrences(of: "\n", with: "\r\n"))
        XCTAssertEqual(r.lines.first?.film, "PORTRA")
        XCTAssertEqual(r.skipped, 0)
    }

    func testTimeWindowEdges() {
        // Clock 12:00:30, span 60: window is 11:59:25 to 12:00:35.
        let r = roll(line((100, 10), (100, 12)))
        func at(_ t: String) -> String? { match(r, time: NaiveTime(exif: "2026:11:01 \(t)")).film }
        XCTAssertEqual(at("11:59:25"), "PORTRA")
        XCTAssertNil(at("11:59:24"))
        XCTAssertEqual(at("12:00:35"), "PORTRA")
        XCTAssertNil(at("12:00:36"))
    }

    func testLongExposureWidensTheWindowByTwiceE() {
        // Clock 12:00:30, span 60, E 30: the window now opens at 11:58:25.
        let r = roll(line((100, 10), (100, 12)))
        let early = NaiveTime(exif: "2026:11:01 11:58:25")
        XCTAssertNil(match(r, time: early).film)
        XCTAssertEqual(match(r, time: early, exposure: 30).film, "PORTRA")
        XCTAssertNil(match(r, time: NaiveTime(exif: "2026:11:01 11:58:24"), exposure: 30).film)
    }

    func testWindowCrossesMidnight() {
        let r = roll(line((100, 10), (100, 12), at: (0, 0, 10), span: 30, day: 2))
        XCTAssertEqual(match(r, time: NaiveTime(exif: "2026:11:01 23:59:50")).film, "PORTRA")
    }

    func testTimesAreNaiveAcrossAClockChange() {
        // 02:30 on 2026-03-08 does not exist in New York, and the zone must not care.
        let saved = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "America/New_York")!
        defer { NSTimeZone.default = saved }
        let a = NaiveTime(exif: "2026:03:08 01:59:59")!, b = NaiveTime(exif: "2026:03:08 02:30:00")!
        XCTAssertEqual(b.seconds - a.seconds, 1801)
    }

    func testBadExifTimesAreNil() {
        for s in ["", "0000:00:00 00:00:00", "2026-11-01 12:00:00", "2026:11:31 12:00:00", "2026:11:01 12:00"] {
            XCTAssertNil(NaiveTime(exif: s), s)
        }
    }

    func testNoTimeOrNoNumberIsNoMatch() {
        let r = roll(line((100, 10), (100, 12)))
        XCTAssertNil(r.match(folderName: "100CANON", number: 11, time: nil, exposure: 0).film)
        XCTAssertNil(r.match(folderName: "100CANON", number: nil, time: shot, exposure: 0).film)
    }

    func testLatestRollSkipsLinesWithTheRollOff() {
        XCTAssertEqual(roll(line((100, 1), (100, 2), roll: 4), line((100, 3), (100, 4), roll: 9), line((100, 5), (100, 6), roll: 0)).latestRoll, 9)
        XCTAssertNil(roll(line((100, 1), (100, 2), roll: 0)).latestRoll)
    }

    func testAnOldShootInTheSameFolderDoesNotHideALine() {
        // A very long span on one line must only widen the search, not change the answer.
        let r = roll(line((100, 500), (100, 600), at: (9, 0, 0), span: 7200, film: "ETERNA"),
                     line((100, 10), (100, 12)))
        XCTAssertEqual(match(r).film, "PORTRA")
    }

    func testManyLinesAreQuick() {
        let id = filmId("PORTRA")
        var text = ""
        for i in 0..<20000 { text += "R1 1 100 \(i % 9000 + 1) 100 \(i % 9000 + 1) 1 2026 10 \(i % 28 + 1) \(i % 24) \(i % 60) 0 5 \(id) PORTRA\n" }
        let r = RollFile(data: Data(text.utf8))
        XCTAssertEqual(r.lines.count, 20000)
        let start = Date()
        for i in 0..<20000 {
            _ = r.match(folderName: "100CANON", number: i % 9000 + 1, time: shot, exposure: 0)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
}
