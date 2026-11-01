import DarkroomCore
import XCTest

final class StateTests: XCTestCase {
    private func frame(roll film: String? = "PORTRA", _ setup: (Rig) throws -> Void = { _ in }) throws -> Rig {
        let r = try Rig()
        try r.cr2("IMG_0001.CR2")
        if let film { try r.roll(line((100, 1), (100, 1), film: film)) }
        try setup(r)
        return r
    }

    func testShotOn() throws {
        let f = try frame().frame()
        XCTAssertEqual(f.state, .shotOn)
        XCTAssertEqual(f.shotOnFilm, ShotOn(film: "PORTRA", source: .roll))
        XCTAssertEqual(f.developingFilm, "PORTRA")      // R4
        XCTAssertTrue(f.canPrint)
    }

    func testNoRecordSaysSoAndWaits() throws {
        let f = try frame(roll: nil).frame()
        XCTAssertEqual(f.state, .noRecord)
        XCTAssertNil(f.developingFilm)
        XCTAssertFalse(f.canPrint)
        XCTAssertNotNil(f.noRecordReason)
        XCTAssertNotNil(f.printHold)
    }

    func testSoftwareTagIsTheSecondSource() throws {
        let f = try frame(roll: nil) { try $0.flm("FLM_0001.JPG", film: "ETERNA") }.frame()
        XCTAssertEqual(f.shotOnFilm, ShotOn(film: "ETERNA", source: .cardPrint))
    }

    func testRollBeatsTheSoftwareTagAndAPrintedFrameShowsShotOn() throws {
        let f = try frame { try $0.flm("FLM_0001.JPG", film: "ETERNA") }.frame()
        XCTAssertEqual(f.state, .printed)
        XCTAssertEqual(f.shotOnFilm?.film, "PORTRA")
        XCTAssertEqual(f.printedFilms, ["ETERNA"])
    }

    func testPrintWithNoTagIsPrintedWithNoRecordedFilm() throws {
        let f = try frame(roll: nil) { try $0.flm("FLM_0001.JPG", film: "NOTAG") }.frame()
        XCTAssertEqual(f.state, .printed)
        XCTAssertNil(f.shotOnFilm)
        XCTAssertFalse(f.canPrint)
    }

    func testPickingACanOnNoRecordIsYourChoice() throws {
        let r = try frame(roll: nil)
        r.record.choose(try r.can("VELVIA"), for: try r.frame())
        let f = try r.frame()
        XCTAssertEqual(f.state, .yourChoice)
        XCTAssertEqual(f.developingFilm, "VELVIA")
        XCTAssertTrue(f.canPrint)
    }

    func testAnyFilmOnAnyFrame() throws {        // G3
        let r = try frame()
        r.record.choose(try r.can("ETERNA"), for: try r.frame())
        let f = try r.frame()
        XCTAssertEqual(f.state, .yourChoice)
        XCTAssertEqual(f.developingCan?.name, "ETERNA")
        XCTAssertEqual(f.shotOnFilm?.film, "PORTRA")
    }

    func testChoiceOutranksPrinted() throws {
        let r = try frame { try $0.flm("FLM_0001.JPG", film: "PORTRA") }
        r.record.choose(try r.can("VELVIA"), for: try r.frame())
        XCTAssertEqual(try r.frame().state, .yourChoice)
    }

    func testChoicePrintedIsNoLongerPending() throws {
        let r = try frame()
        r.record.choose(try r.can("VELVIA"), for: try r.frame())
        XCTAssertEqual(try r.frame().state, .yourChoice)
        _ = try r.deskPrint(try r.frame(), film: "VELVIA")
        let f = try r.frame()
        XCTAssertEqual(f.state, .printed)
        XCTAssertEqual(f.developingFilm, "VELVIA")
    }

    func testChoosingTheShotOnFilmIsNotAChoice() throws {
        let r = try frame()
        r.record.choose(try r.can("VELVIA"), for: try r.frame())
        r.record.choose(try r.can("PORTRA"), for: try r.frame())
        XCTAssertTrue(r.record.choices.isEmpty)
        XCTAssertEqual(try r.frame().state, .shotOn)
    }

    func testAStoredChoiceThatTurnsOutRedundantDoesNotCountAndStays() throws {
        // Chosen while there was no record; the roll then arrived with the same film.
        let r = try frame(roll: nil)
        r.record.choose(try r.can("PORTRA"), for: try r.frame())
        XCTAssertEqual(r.record.choices.count, 1)
        try r.roll(line((100, 1), (100, 1), film: "portra"))
        XCTAssertEqual(try r.frame().state, .shotOn)
        XCTAssertNil(try r.frame().choice)
        XCTAssertEqual(r.record.choices.count, 1)
    }

    func testAChoiceOnACopyWithNoRecordSurvivesTheCopyWithOne() throws {
        let r = try frame(roll: "VELVIA")
        try r.cr2("IMG_0001.CR2", folder: "DCIM/102CANON")
        let bare = try XCTUnwrap(try r.frames().first { $0.shotOnFilm == nil })
        r.record.choose(try r.can("VELVIA"), for: bare)
        for _ in 0..<2 {
            let frames = try r.frames()
            XCTAssertEqual(frames.first { $0.id == bare.id }?.choice, "VELVIA")
            XCTAssertEqual(frames.first { $0.id != bare.id }?.choice, nil)
            XCTAssertEqual(frames.first { $0.id != bare.id }?.state, .shotOn)
        }
        XCTAssertEqual(r.record.choices.count, 1)
    }

    func testClearingOnTheFramesOwnFilmRemovesARedundantChoice() throws {
        let r = try frame(roll: nil)
        r.record.choose(try r.can("PORTRA"), for: try r.frame())
        try r.roll(line((100, 1), (100, 1), film: "PORTRA"))
        r.record.choose(try r.can("PORTRA"), for: try r.frame())
        XCTAssertTrue(r.record.choices.isEmpty)

        try FileManager.default.removeItem(at: r.root.appendingPathComponent("ML/DATA/SOUPROLL.TXT"))
        r.record.choose(try r.can("PORTRA"), for: try r.frame())
        try r.roll(line((100, 1), (100, 1), film: "PORTRA"))
        r.record.choose(nil, for: try r.frame())
        XCTAssertTrue(r.record.choices.isEmpty)
    }

    func testRecordedFilmOffTheShelfShowsItsNameAndHoldsPrint() throws {
        let r = try frame(roll: "MYSTERY")
        var f = try r.frame()
        XCTAssertEqual(f.state, .shotOn)
        XCTAssertEqual(f.shotOnFilm?.film, "MYSTERY")
        XCTAssertNil(f.developingFilm)
        XCTAssertFalse(f.canPrint)
        XCTAssertTrue(try XCTUnwrap(f.printHold).contains("Mystery"))
        r.record.choose(try r.can("VELVIA"), for: f)
        f = try r.frame()
        XCTAssertEqual(f.state, .yourChoice)
        XCTAssertTrue(f.canPrint)
    }

    func testAChoiceThatLeftTheShelfHoldsPrint() throws {
        let r = try frame()
        r.record.choose(try r.can("VELVIA"), for: try r.frame())
        r.shelf = FilmShelf(cardFolder: nil, addedFolder: nil, bundledFolder: nil, loader: Rig.loader)
        let f = try r.frame()
        XCTAssertEqual(f.developingFilm, "VELVIA")
        XCTAssertFalse(f.canPrint)
    }

    func testUnreadableFrameStaysListedAndCannotPrint() throws {
        let r = try frame(roll: nil)
        try r.put("DCIM/100CANON/IMG_0002.CR2", "BAD")
        let f = try r.frame("IMG_0002.CR2")
        XCTAssertFalse(f.isReadable)
        XCTAssertFalse(f.canPrint)
        XCTAssertEqual(f.state, .noRecord)
        r.record.choose(try r.can("VELVIA"), for: f)
        XCTAssertFalse(try r.frame("IMG_0002.CR2").canPrint)
    }

    func testIdentityDiffersOnAReusedNumber() throws {
        let r = try Rig()
        try r.cr2("IMG_0001.CR2", time: "2026:11:01 12:00:00")
        let first = try r.frame()
        r.record.choose(try r.can("VELVIA"), for: first)
        try r.cr2("IMG_0001.CR2", time: "2027:01:01 12:00:00")
        let second = try r.frame()
        XCTAssertNotEqual(first.identity, second.identity)
        XCTAssertNil(second.choice)
        XCTAssertEqual(second.identity.split(separator: "|").first, "IMG_0001")
    }

    func testCountsAddUpAndNotDevelopedIsASeparateAxis() throws {
        let r = try Rig()
        for n in 1...5 { try r.cr2("IMG_000\(n).CR2") }
        try r.roll(line((100, 1), (100, 3)))
        try r.flm("FLM_0002.JPG")
        r.record.choose(try r.can("VELVIA"), for: try r.frame("IMG_0003.CR2"))
        let frames = try r.frames()
        let c = FilterCounts(frames)
        XCTAssertEqual(c.all, 5)
        XCTAssertEqual(c.shotOn, 1)
        XCTAssertEqual(c.printed, 1)
        XCTAssertEqual(c.yourChoice, 1)
        XCTAssertEqual(c.noRecord, 2)
        XCTAssertEqual(c.shotOn + c.printed + c.yourChoice + c.noRecord, c.all)
        XCTAssertEqual(c.notDeveloped, 4)
        for filter in Filter.allCases { XCTAssertEqual(filter.apply(to: frames).count, c[filter], "\(filter)") }
        // It cuts across the states.
        XCTAssertEqual(Set(Filter.notDeveloped.apply(to: frames).map(\.state)), [.shotOn, .yourChoice, .noRecord])
    }
}
