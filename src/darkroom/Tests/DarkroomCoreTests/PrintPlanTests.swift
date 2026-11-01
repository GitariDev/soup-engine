import DarkroomCore
import XCTest

final class PrintPlanTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/someone")
    private var dest: URL { Destination.defaultFolder(home: home) }

    func testNaming() {
        XCTAssertEqual(PrintName.requested(stem: "IMG_3990", film: "VELVIA"), "IMG_3990_VELVIA.JPG")
        XCTAssertEqual(PrintName.requested(stem: "IMG_3990", film: "classic chrome"), "IMG_3990_CLASSIC_CHROME.JPG")
        XCTAssertEqual(PrintName.requested(stem: "IMG_3990", film: "B&W/../X"), "IMG_3990_BWX.JPG")
        XCTAssertEqual(PrintName.requested(stem: "IMG_3990", film: "CAFÉ"), "IMG_3990_CAFE.JPG")
        XCTAssertEqual(PrintName.requested(stem: "IMG_3990", film: "雪"), "IMG_3990_FILM.JPG")
    }

    func testPlanSplitsAndSummarises() throws {
        let r = try Rig()
        for n in 1...5 { try r.cr2("IMG_000\(n).CR2") }
        try r.roll(line((100, 1), (100, 3), film: "VELVIA"), line((100, 4), (100, 4), film: "MYSTERY"))
        let plan = PrintPlan(frames: try r.frames(), destination: dest, home: home)
        XCTAssertEqual(plan.items.map(\.requestedName),
                       ["IMG_0001_VELVIA.JPG", "IMG_0002_VELVIA.JPG", "IMG_0003_VELVIA.JPG"])
        XCTAssertEqual(plan.waiting.map(\.name), ["IMG_0004.CR2", "IMG_0005.CR2"])
        XCTAssertEqual(plan.summary, "Print 3 of 5 to ~/Pictures/Soup Prints, 2 wait for a film")
    }

    func testSummaryWordings() throws {
        let r = try Rig()
        try r.cr2("IMG_0001.CR2")
        try r.cr2("IMG_0002.CR2")
        try r.put("DCIM/100CANON/IMG_0003.CR2", "BAD")
        try r.roll(line((100, 1), (100, 1)))
        let some = PrintPlan(frames: try r.frames(), destination: URL(fileURLWithPath: "/tmp/out"), home: home)
        XCTAssertEqual(some.summary, "Print 1 of 3 to /tmp/out, 1 waits for a film, 1 cannot be read")
        XCTAssertEqual(some.unreadable.map(\.name), ["IMG_0003.CR2"])
        let all = PrintPlan(frames: try r.frames().filter(\.canPrint), destination: dest, home: home)
        XCTAssertEqual(all.summary, "Print 1 of 1 to ~/Pictures/Soup Prints")
    }

    func testNamesAreUniqueInABatchIgnoringCase() throws {
        let r = try Rig()
        try r.cr2("IMG_0001.CR2", folder: "DCIM/100CANON")
        try r.cr2("IMG_0001.CR2", folder: "DCIM/101CANON")
        try r.cr2("IMG_0001.CR2", folder: "DCIM/102CANON")
        try r.cr2("img_0001.cr2", folder: "DCIM/103CANON")
        try r.cr2("IMG_0001-2.CR2", folder: "DCIM/104CANON")
        for f in try r.frames() { r.record.choose(try r.can("VELVIA"), for: f) }
        let names = PrintPlan(frames: try r.frames(), destination: dest, home: home).items.map(\.requestedName)
        XCTAssertEqual(names.count, 5)
        XCTAssertEqual(Set(names.map { $0.lowercased() }).count, 5, "\(names)")
    }

    func testHoldsSayWhyEachFrameWaits() throws {
        let r = try Rig()
        for n in 1...3 { try r.cr2("IMG_000\(n).CR2") }
        try r.roll(line((100, 1), (100, 1), film: "KODACHROME 64"))
        let holds = PrintPlan.holds(of: try r.frames())
        XCTAssertEqual(holds.map(\.reason), ["Kodachrome 64 is not on the shelf", "No film is recorded"])
        XCTAssertEqual(holds.map(\.count), [1, 2])
        XCTAssertEqual(try r.frame().printHold, "Kodachrome 64 is not on the shelf. Choose a can to print.")
    }

    func testAFrameListedTwiceIsOneItem() throws {
        let r = try Rig()
        try r.cr2("IMG_0001.CR2")
        try r.roll(line((100, 1), (100, 1)))
        let f = try r.frame()
        XCTAssertEqual(PrintPlan(frames: [f, f], destination: dest, home: home).items.count, 1)
    }

    func testAChoiceDevelopsOnTheChoice() throws {
        let r = try Rig()
        try r.cr2("IMG_0001.CR2")
        try r.roll(line((100, 1), (100, 1)))
        r.record.choose(try r.can("VELVIA"), for: try r.frame())
        XCTAssertEqual(PrintPlan(frames: try r.frames(), destination: dest, home: home).items.first?.film.name, "VELVIA")
    }

    // MARK: destination

    func testDefaultFolderIsFine() throws {
        let r = try Rig()
        guard case .ok = Destination.validate(Destination.defaultFolder(home: r.support)) else {
            return XCTFail("refused")
        }
    }

    func testRefusesInsideDCIMAtAnyDepthAndCase() throws {
        let r = try Rig()
        for path in ["DCIM", "DCIM/100CANON", "DCIM/100CANON/a/b/new", "dcim/x"] {
            XCTAssertNotNil(Destination.validate(r.root.appendingPathComponent(path)).reason, path)
        }
    }

    func testRefusesAnAncestorWithADCIM() throws {
        let r = try Rig()
        try r.put("ML/PRINTS/x", "x")
        for path in ["", "ML", "ML/PRINTS", "ML/PRINTS/deep/down/new"] {
            XCTAssertNotNil(Destination.validate(r.root.appendingPathComponent(path)).reason, path)
        }
    }

    func testABackupInTheHomeFolderDoesNotRefuseTheHomeFolder() throws {
        let r = try Rig()
        let pictures = r.root.appendingPathComponent("Pictures/Soup Prints")
        try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
        let check = Destination.validate(pictures, home: r.root)
        guard case .ok = check else { return XCTFail("refused: \(check.reason ?? "")") }
        XCTAssertNotNil(Destination.validate(r.dcf, home: r.root).reason, "the backup itself stays refused")
    }

    func testACardCopiedInsideTheHomeFolderRefusesOnlyItself() throws {
        let r = try Rig()
        let home = r.root.deletingLastPathComponent().appendingPathComponent("home")
        let fm = FileManager.default
        try fm.createDirectory(at: home.appendingPathComponent("Pictures/DCIM/100CANON"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent("Pictures/Trip/DCIM"), withIntermediateDirectories: true)
        XCTAssertNil(Destination.cardReason(for: Destination.defaultFolder(home: home), home: home))
        XCTAssertNil(Destination.cardReason(for: home.appendingPathComponent("Pictures/Trip/out"), home: home))
        XCTAssertNotNil(Destination.cardReason(for: home.appendingPathComponent("Pictures/DCIM/100CANON"), home: home))
        XCTAssertNotNil(Destination.cardReason(for: r.root.appendingPathComponent("ML"), home: home), "a card outside home")
    }

    func testRefusesThroughASymlink() throws {
        let r = try Rig()
        let fm = FileManager.default
        let free = r.root.deletingLastPathComponent().appendingPathComponent("free")
        try fm.createDirectory(at: free, withIntermediateDirectories: true)

        let intoDCF = free.appendingPathComponent("a")
        try fm.createSymbolicLink(at: intoDCF, withDestinationURL: r.dcf)
        XCTAssertNotNil(Destination.validate(intoDCF).reason)
        XCTAssertNotNil(Destination.validate(intoDCF.appendingPathComponent("new/deep")).reason)

        // Relative, and to the card's root rather than its DCIM.
        let intoRoot = free.appendingPathComponent("b")
        try fm.createSymbolicLink(atPath: intoRoot.path, withDestinationPath: "../card/ML")
        XCTAssertNotNil(Destination.validate(intoRoot).reason)

        // One that points at something not there yet.
        let dangling = free.appendingPathComponent("c")
        try fm.createSymbolicLink(atPath: dangling.path, withDestinationPath: r.root.path + "/ML/not/yet")
        XCTAssertNotNil(Destination.validate(dangling).reason)

        // A link to itself.
        let loop = free.appendingPathComponent("d")
        try fm.createSymbolicLink(atPath: loop.path, withDestinationPath: loop.path)
        XCTAssertNotNil(Destination.validate(loop).reason)
    }

    func testAFineFolderBehindALinkIsAllowed() throws {
        let free = FileManager.default.temporaryDirectory.appendingPathComponent("free-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: free.appendingPathComponent("real"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: free) }
        try fm.createSymbolicLink(at: free.appendingPathComponent("link"), withDestinationURL: free.appendingPathComponent("real"))
        guard case .ok(let u) = Destination.validate(free.appendingPathComponent("link")) else { return XCTFail("refused") }
        XCTAssertEqual(u.lastPathComponent, "real")
    }

    func testRefusesAFolderThatCannotBeWrittenAndAFile() throws {
        let free = FileManager.default.temporaryDirectory.appendingPathComponent("free-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: free, withIntermediateDirectories: true)
        let locked = free.appendingPathComponent("locked")
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? fm.removeItem(at: free)
        }
        XCTAssertNotNil(Destination.validate(locked).reason)
        XCTAssertNotNil(Destination.validate(locked.appendingPathComponent("new")).reason)
        let file = free.appendingPathComponent("file")
        try Data("x".utf8).write(to: file)
        XCTAssertNotNil(Destination.validate(file).reason)
        XCTAssertNotNil(Destination.validate(file.appendingPathComponent("new")).reason)
    }
}
