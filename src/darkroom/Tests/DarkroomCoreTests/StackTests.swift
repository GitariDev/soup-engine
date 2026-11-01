import DarkroomCore
import XCTest

final class StackTests: XCTestCase {
    private func shotOnPortra() throws -> Rig {
        let r = try Rig()
        try r.cr2("IMG_0001.CR2")
        try r.roll(line((100, 1), (100, 1), film: "PORTRA"))
        return r
    }

    func testNoPrintNoStack() throws {
        XCTAssertEqual(try shotOnPortra().frame().stack, [])
    }

    func testTheCardsPrintIsFirstThenThisAppsInTheOrderMade() throws {
        let r = try shotOnPortra()
        let flm = try r.flm("FLM_0001.JPG", film: "ETERNA")
        let first = try r.deskPrint(try r.frame(), film: "VELVIA")
        let second = try r.deskPrint(try r.frame(), film: "PORTRA")
        let stack = try r.frame().stack
        XCTAssertEqual(stack.map(\.url.path), [flm.path, first.path, second.path])
        XCTAssertEqual(stack.map(\.film), ["ETERNA", "VELVIA", "PORTRA"])
        XCTAssertEqual(stack.map(\.isCardPrint), [true, false, false])
    }

    func testAnUntaggedCardPrintCountsAndNamesNoFilm() throws {
        let r = try shotOnPortra()
        try r.flm("FLM_0001.JPG", film: "NOTAG")
        _ = try r.deskPrint(try r.frame(), film: "VELVIA")
        let f = try r.frame()
        XCTAssertEqual(f.printedFilms, ["VELVIA"])       // why this is not the count
        XCTAssertEqual(f.stack.count, 2)
        XCTAssertNil(f.stack[0].film)
    }

    func testAZeroByteCardPrintIsNotInTheStack() throws {
        let r = try shotOnPortra()
        try r.put("DCIM/100CANON/FLM_0001.JPG")
        XCTAssertEqual(try r.frame().stack, [])
    }

    func testADeletedPrintLeavesTheStackAndTheStateFollows() throws {
        let r = try shotOnPortra()
        r.record.choose(try r.can("VELVIA"), for: try r.frame())
        let kept = try r.deskPrint(try r.frame(), film: "ETERNA")
        let print = try r.deskPrint(try r.frame(), film: "VELVIA")
        XCTAssertEqual(try r.frame().state, .printed)
        try FileManager.default.removeItem(at: print)
        r.record.refresh()
        let f = try r.frame()
        XCTAssertEqual(f.stack.map(\.url.path), [kept.path])
        XCTAssertEqual(f.state, .yourChoice)             // Velvia is not printed any more
    }

    func testAMovedPrintComesBackWhenItIsMovedBack() throws {
        let r = try shotOnPortra()
        let print = try r.deskPrint(try r.frame(), film: "VELVIA")
        let aside = print.appendingPathExtension("moved")
        try FileManager.default.moveItem(at: print, to: aside)
        r.record.refresh()
        XCTAssertEqual(try r.frame().stack, [])
        XCTAssertEqual(try r.frame().state, .shotOn)
        try FileManager.default.moveItem(at: aside, to: print)
        r.record.refresh()
        XCTAssertEqual(try r.frame().stack.count, 1)
    }

    func testAnEmptiedPrintLeavesTheStack() throws {
        let r = try shotOnPortra()
        let print = try r.deskPrint(try r.frame(), film: "VELVIA")
        try Data().write(to: print)
        r.record.refresh()
        XCTAssertEqual(try r.frame().stack, [])
    }

    /// The print is deleted and its name comes free, so the next one lands on
    /// the same path. That is one file and one print.
    func testANameThatCameFreeIsOnePrintOnItsNewFilm() throws {
        let r = try shotOnPortra()
        let f = try r.frame()
        let url = try r.deskPrint(f, film: "VELVIA")
        r.record.addPrint(DeskPrint(url: url, film: "ETERNA"), identity: f.identity)
        XCTAssertEqual(try r.frame().stack.map(\.film), ["ETERNA"])
        XCTAssertEqual(r.record.prints[f.identity]?.count, 1)
    }

    func testANameThatCameFreeBelongsToTheFrameThatPrintedIt() throws {
        let r = try shotOnPortra()
        try r.cr2("IMG_0002.CR2")
        let a = try r.frame("IMG_0001.CR2"), b = try r.frame("IMG_0002.CR2")
        let url = try r.deskPrint(a, film: "VELVIA")
        r.record.addPrint(DeskPrint(url: url, film: "ETERNA"), identity: b.identity)
        XCTAssertEqual(try r.frame("IMG_0001.CR2").stack, [])
        XCTAssertEqual(try r.frame("IMG_0002.CR2").stack.map(\.film), ["ETERNA"])
    }

    func testARecordThatHoldsAPathTwiceLoadsAsOnePrint() throws {
        let r = try shotOnPortra()
        let f = try r.frame()
        let url = try r.put("out/print.JPG", "jpeg")
        let old = Date(timeIntervalSince1970: 1_000_000), new = Date(timeIntervalSince1970: 2_000_000)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let list = [DeskPrint(url: url, film: "VELVIA", printedAt: old), DeskPrint(url: url, film: "ETERNA", printedAt: new)]
        let body = String(decoding: try encoder.encode([f.identity: list]), as: UTF8.self)
        try r.put("../support/bench.json", #"{"version":1,"choices":{},"prints":\#(body)}"#)
        r.record = try BenchRecord.load(directory: r.record.directory)
        XCTAssertEqual(try r.frame().stack.map(\.film), ["ETERNA"])
    }

    /// A print saved beside the CR2 under the camera's name is also the card's.
    func testOneFileThatIsBothACardPrintAndADeskPrintCountsOnce() throws {
        let r = try shotOnPortra()
        let flm = try r.flm("FLM_0001.JPG", film: "VELVIA")
        r.record.addPrint(DeskPrint(url: flm, film: "VELVIA"), identity: try r.frame().identity)
        XCTAssertEqual(try r.frame().stack.count, 1)
    }

    /// The film of a print is about that print, never about the frame.
    func testAStackNeverGivesAFrameItsFilm() throws {
        let r = try Rig()
        try r.cr2("IMG_0001.CR2")
        r.record.choose(try r.can("VELVIA"), for: try r.frame())
        _ = try r.deskPrint(try r.frame(), film: "VELVIA")
        XCTAssertEqual(try r.frame().state, .printed)
        r.record.choose(nil, for: try r.frame())
        let f = try r.frame()
        XCTAssertEqual(f.state, .printed)
        XCTAssertEqual(f.stack.count, 1)
        XCTAssertNil(f.shotOnFilm)
        XCTAssertNil(f.developingFilm)
        XCTAssertNil(f.developingCan)
        XCTAssertFalse(f.canPrint)
        XCTAssertEqual(f.printHold, "No film is recorded. Choose a can to print.")
    }

    func testAPrintAddedWhileTheDiskWasBeingReadStays() throws {
        let r = try shotOnPortra()
        let f = try r.frame()
        let old = try r.deskPrint(f, film: "VELVIA")
        let look = r.record.presence()                  // off the main actor, in the app
        let new = try r.deskPrint(f, film: "ETERNA")
        try FileManager.default.removeItem(at: old)
        var found = look
        found[old.path] = false
        r.record.take(found)
        XCTAssertEqual(try r.frame().stack.map(\.url.path), [new.path])
    }

    func testNotCheckingPrintsCountsNoneUntilTheyAreTaken() throws {
        let r = try shotOnPortra()
        _ = try r.deskPrint(try r.frame(), film: "VELVIA")
        try r.record.save()
        r.record = try BenchRecord.load(directory: r.record.directory, checkPrints: false)
        XCTAssertEqual(try r.frame().stack, [])
        r.record.take(r.record.presence())
        XCTAssertEqual(try r.frame().stack.count, 1)
    }

    func testTwoCopiesOfAFrameShareThisAppsPrintsAndKeepTheirOwnCardPrints() throws {
        let r = try Rig()
        try r.cr2("IMG_0001.CR2")
        try r.cr2("IMG_0001.CR2", folder: "DCIM/101CANON")
        let flm = try r.flm("FLM_0001.JPG", film: "ETERNA", folder: "DCIM/101CANON")
        let frames = try r.frames()
        XCTAssertEqual(frames.count, 2)
        _ = try r.deskPrint(frames[0], film: "VELVIA")
        let after = try r.frames()
        XCTAssertEqual(after[0].stack.count, 1)
        XCTAssertEqual(after[1].stack.count, 2)
        XCTAssertEqual(after[1].stack.first?.url.path, flm.path)
    }

    /// The default folder has a space in it, and a place on the stack is a path.
    func testAPrintsIdIsThePathItWasPrintedTo() throws {
        let r = try shotOnPortra()
        let url = try r.put("Soup Prints/IMG_0001_é 100%.JPG", "jpeg")
        r.record.addPrint(DeskPrint(url: url, film: "VELVIA"), identity: try r.frame().identity)
        XCTAssertEqual(try r.frame().stack.map(\.id), [url.path])
        XCTAssertEqual(r.record.presence(), [url.path: true])
    }

    func testOnDiskIsAFileWithSomethingInIt() throws {
        let r = try shotOnPortra()
        let print = try r.deskPrint(try r.frame(), film: "VELVIA")
        let stack = try r.frame().stack
        XCTAssertTrue(stack[0].isOnDisk)
        try Data().write(to: print)
        XCTAssertFalse(stack[0].isOnDisk)
        try FileManager.default.removeItem(at: print)
        XCTAssertFalse(stack[0].isOnDisk)
    }
}
