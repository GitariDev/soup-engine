import DarkroomCore
import XCTest

final class RecordTests: XCTestCase {
    func testRoundTrip() throws {
        let r = try Rig()
        try r.cr2("IMG_0001.CR2")
        let f = try r.frame()
        r.record.choose(try r.can("VELVIA"), for: f)
        let print = try r.deskPrint(f, film: "VELVIA")
        r.record.saveFolder = URL(fileURLWithPath: "/tmp/Soup Prints", isDirectory: true)
        try r.record.save()

        let back = try BenchRecord.load(directory: r.record.directory)
        XCTAssertEqual(back.choices, [f.identity: "VELVIA"])
        XCTAssertEqual(back.deskPrints(for: f.identity).map(\.url.path), [print.path])
        XCTAssertEqual(back.saveFolder?.path, "/tmp/Soup Prints")
        XCTAssertNil(back.setAside)
    }

    func testNoFileIsAnEmptyRecord() throws {
        let r = try Rig()
        XCTAssertEqual(try BenchRecord.load(directory: r.root.appendingPathComponent("nowhere")).choices, [:])
    }

    func testAPrintGoneAtLoadDoesNotCountAndComesBackWithItsFile() throws {
        let r = try Rig()
        try r.cr2("IMG_0001.CR2")
        let f = try r.frame()
        let print = try r.deskPrint(f, film: "VELVIA")
        try r.record.save()
        let bytes = try Data(contentsOf: print)
        try FileManager.default.removeItem(at: print)

        var back = try BenchRecord.load(directory: r.record.directory)
        XCTAssertTrue(back.deskPrints(for: f.identity).isEmpty)
        try bytes.write(to: print)                  // the drive was only unplugged
        back.refresh()
        XCTAssertEqual(back.deskPrints(for: f.identity).count, 1)
    }

    func testAnEmptyDeskPrintDoesNotCount() throws {
        let r = try Rig()
        try r.cr2("IMG_0001.CR2")
        let f = try r.frame()
        let print = try r.deskPrint(f, film: "VELVIA")
        try Data().write(to: print)
        r.record.refresh()
        XCTAssertTrue(r.record.deskPrints(for: f.identity).isEmpty)
    }

    func testCorruptFileIsMovedAsideNotLost() throws {
        let r = try Rig()
        let dir = r.record.directory
        try r.put("../support/bench.json", "{ not json")
        let first = try BenchRecord.load(directory: dir)
        let aside = try XCTUnwrap(first.setAside)
        XCTAssertEqual(try String(contentsOf: aside, encoding: .utf8), "{ not json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.file.path))
        XCTAssertEqual(first.choices, [:])

        // A second bad file in the same second does not replace the first aside.
        try r.put("../support/bench.json", "also bad")
        let second = try XCTUnwrap(try BenchRecord.load(directory: dir).setAside)
        XCTAssertNotEqual(second, aside)
        XCTAssertEqual(try String(contentsOf: aside, encoding: .utf8), "{ not json")
    }

    func testNewerVersionIsNotDiscarded() throws {
        let r = try Rig()
        let text = #"{"version":99,"choices":{},"prints":{}}"#
        try r.put("../support/bench.json", text)
        let back = try BenchRecord.load(directory: r.record.directory)
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(back.setAside), encoding: .utf8), text)
    }

    func testSaveLeavesNoTemporaryFiles() throws {
        let r = try Rig()
        try r.record.save()
        try r.record.save()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: r.record.directory.path), ["bench.json"])
    }
}
