import DarkroomCore
import XCTest

final class NotDevelopedTests: XCTestCase {
    func testPrintBesideItIsDeveloped() throws {
        let r = try Rig()
        try r.cr2("IMG_0001.CR2")
        try r.flm("FLM_0001.JPG")
        XCTAssertTrue(try r.frame().isDeveloped)
    }

    func testNoPrintIsNotDeveloped() throws {
        let r = try Rig()
        try r.cr2("IMG_0001.CR2")
        XCTAssertFalse(try r.frame().isDeveloped)
    }

    func testZeroBytePrintIsNotDeveloped() throws {
        let r = try Rig()
        try r.cr2("IMG_0001.CR2")
        try r.put("DCIM/100CANON/FLM_0001.JPG", "")
        let f = try r.frame()
        XCTAssertFalse(f.isDeveloped)
        XCTAssertNil(f.cardPrint)
        XCTAssertTrue(f.file.cutOffPrint)
    }

    func testCanonJpegIsNotDeveloped() throws {
        let r = try Rig()
        try r.cr2("IMG_0001.CR2")
        try r.flm("IMG_0001.JPG", film: "Canon EOS 700D")
        XCTAssertFalse(try r.frame().isDeveloped)
    }

    func testPrintInAnotherFolderDoesNotCount() throws {
        let r = try Rig()
        try r.cr2("IMG_0001.CR2")
        try r.flm("FLM_0001.JPG", folder: "DCIM/101CANON")
        XCTAssertFalse(try r.frame().isDeveloped)
    }

    func testLowerCaseNamesPair() throws {
        let r = try Rig()
        try r.cr2("img_0001.cr2")
        try r.flm("flm_0001.jpg")
        let f = try r.frame("img_0001.cr2")
        XCTAssertTrue(f.isDeveloped)
        XCTAssertEqual(f.number, 1)
    }

    func testDotfilePrintIsNotAPrint() throws {
        let r = try Rig()
        try r.cr2("IMG_0001.CR2")
        try r.flm("._FLM_0001.JPG")
        XCTAssertFalse(try r.frame().isDeveloped)
    }

    func testNameWithNoDigitsNeverPairsUntilPrintedHere() throws {
        let r = try Rig()
        try r.cr2("HOLIDAY.CR2")
        try r.flm("FLM_DAY.JPG")
        let f = try r.frame("HOLIDAY.CR2")
        XCTAssertFalse(f.isDeveloped)
        XCTAssertNil(f.number)
        _ = try r.deskPrint(f, film: "VELVIA")
        XCTAssertTrue(try r.frame("HOLIDAY.CR2").isDeveloped)
    }

    func testDeskPrintOnDiskIsDeveloped() throws {
        let r = try Rig()
        try r.cr2("IMG_0001.CR2")
        _ = try r.deskPrint(try r.frame(), film: "VELVIA")
        XCTAssertTrue(try r.frame().isDeveloped)
        XCTAssertEqual(FilterCounts(try r.frames()).notDeveloped, 0)
    }

    func testDeletedDeskPrintBringsTheFrameBack() throws {
        let r = try Rig()
        try r.cr2("IMG_0001.CR2")
        let url = try r.deskPrint(try r.frame(), film: "VELVIA")
        try FileManager.default.removeItem(at: url)
        r.record.refresh()
        XCTAssertFalse(try r.frame().isDeveloped)
        XCTAssertEqual(FilterCounts(try r.frames()).notDeveloped, 1)
    }
}
