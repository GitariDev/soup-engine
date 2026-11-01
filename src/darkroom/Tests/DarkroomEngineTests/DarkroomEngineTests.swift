// These read real frames from SOUP_SAMPLES, which stays out of the repository,
// and write only to temporary folders. Without it they skip, and say so.
import CSoup
import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import DarkroomEngine

final class DarkroomEngineTests: XCTestCase {
    var samples: URL!
    var dir: URL!
    var before: [String: String] = [:]
    var listing: [String] = []

    let stocks = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("stocks")

    var landscape: URL { samples.appendingPathComponent("IMG_3990.CR2") }
    var portrait: URL { samples.appendingPathComponent("IMG_4020.CR2") }

    func film(_ name: String) throws -> DarkroomFilm {
        try XCTUnwrap(DarkroomFilm(url: stocks.appendingPathComponent(name + ".fs")))
    }

    func room(cache: Int = 0) -> Darkroom {
        Darkroom(cacheDirectory: dir.appendingPathComponent("cache"), imageCacheBytes: cache)
    }

    func folder(_ name: String = "out") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func names(_ url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }

    func bytes(_ image: CGImage) -> Data { image.dataProvider!.data! as Data }

    func hash(_ url: URL) throws -> String { sha(try Data(contentsOf: url)) }

    func properties(_ url: URL) throws -> [String: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
    }

    func tiff(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(try properties(url)[kCGImagePropertyTIFFDictionary as String] as? [String: Any])
    }

    // Every test ends by proving the samples were only read.
    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["SOUP_SAMPLES"] else {
            throw XCTSkip("SOUP_SAMPLES is not set: no real frames to test on")
        }
        samples = URL(fileURLWithPath: path)
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("soup-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        listing = try names(samples)
        for url in [landscape, portrait] { before[url.path] = try hash(url) }
    }

    override func tearDownWithError() throws {
        guard let samples else { return }
        XCTAssertEqual(try names(samples), listing, "the samples folder changed")
        for url in [landscape, portrait] {
            XCTAssertEqual(try hash(url), before[url.path], "\(url.lastPathComponent) changed")
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }

    func testRenderSizeAtEachScale() async throws {
        let room = room()
        for (quality, w, h) in [(RenderQuality.quick, 1296, 864), (.fine, 2592, 1728)] {
            let image = try await room.render(landscape, film: film("eterna"), quality: quality)
            XCTAssertEqual([image.width, image.height], [w, h])
            let straight = try await room.render(landscape, film: nil, quality: quality)
            XCTAssertEqual([straight.width, straight.height], [w, h])
        }
    }

    func testStraightIsNotAFilm() async throws {
        let room = room()
        let straight = try await room.render(landscape, film: nil, quality: .quick)
        let eterna = try await room.render(landscape, film: film("eterna"), quality: .quick)
        XCTAssertNotEqual(bytes(straight), bytes(eterna))

        let url = try await room.print(landscape, film: nil, to: folder(), name: "straight.jpg", half: true)
        XCTAssertEqual(try tiff(url)[kCGImagePropertyTIFFSoftware as String] as? String, "STRAIGHT RAW")
    }

    func testPrintIsFullSizeWithSoftwareAndDate() async throws {
        let url = try await room().print(landscape, film: film("velvia"), to: folder(), name: "IMG_3990_VELVIA.JPG")
        XCTAssertEqual(url.lastPathComponent, "IMG_3990_VELVIA.JPG")
        let props = try properties(url)
        XCTAssertEqual(props[kCGImagePropertyPixelWidth as String] as? Int, 5184)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight as String] as? Int, 3456)
        let tags = try tiff(url)
        XCTAssertEqual(tags[kCGImagePropertyTIFFSoftware as String] as? String, "VELVIA")
        XCTAssertEqual(tags[kCGImagePropertyTIFFDateTime as String] as? String, "2024:07:06 13:47:10")
        XCTAssertEqual(tags[kCGImagePropertyTIFFOrientation as String] as? Int, 1)
        var software = [CChar](repeating: 0, count: 64)
        XCTAssertEqual(sb_jpeg_software(url.path, &software, 64), 0)
        XCTAssertEqual(String(cString: software), "VELVIA")
    }

    func testPortraitIsCarriedAndRotated() async throws {
        let room = room()
        let url = try await room.print(portrait, film: film("portra"), to: folder(), name: "p.jpg")
        let props = try properties(url)
        XCTAssertEqual(props[kCGImagePropertyPixelWidth as String] as? Int, 5184)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight as String] as? Int, 3456)
        XCTAssertEqual(try tiff(url)[kCGImagePropertyTIFFOrientation as String] as? Int, 6)

        let image = try await room.render(portrait, film: nil, quality: .quick)
        XCTAssertEqual([image.width, image.height], [864, 1296])
        let thumb = try await room.thumbnail(portrait)
        XCTAssertGreaterThan(thumb.height, thumb.width)
        let held = try await room.placeholder(portrait)
        XCTAssertGreaterThan(held.height, held.width)
    }

    func testOrientationsMapTheCorners() throws {
        // stored 2x3, values 1...6: row one is 1 2, row two is 3 4, row three 5 6
        let stored = Data([1, 2, 3, 4, 5, 6].flatMap { [UInt8($0), 0, 0] })
        let want: [Int: (Int, Int, [UInt8])] = [
            1: (2, 3, [1, 2, 3, 4, 5, 6]), 2: (2, 3, [2, 1, 4, 3, 6, 5]),
            3: (2, 3, [6, 5, 4, 3, 2, 1]), 4: (2, 3, [5, 6, 3, 4, 1, 2]),
            5: (3, 2, [1, 3, 5, 2, 4, 6]), 6: (3, 2, [5, 3, 1, 6, 4, 2]),
            7: (3, 2, [6, 4, 2, 5, 3, 1]), 8: (3, 2, [2, 4, 6, 1, 3, 5]),
        ]
        for (orientation, (w, h, values)) in want {
            let image = try rotated(stored, 2, 3, orientation, landscape)
            XCTAssertEqual([image.width, image.height], [w, h], "orientation \(orientation)")
            let got = stride(from: 0, to: w * h * 3, by: 3).map { bytes(image)[$0] }
            XCTAssertEqual(got, values, "orientation \(orientation)")
        }
    }

    func testNeverOverwrites() async throws {
        let out = try folder()
        let sentinel = Data("the print already here".utf8)
        try sentinel.write(to: out.appendingPathComponent("x.JPG"))
        let room = room()
        let second = try await room.print(landscape, film: nil, to: out, name: "x.JPG", half: true)
        let third = try await room.print(landscape, film: nil, to: out, name: "x.JPG", half: true)
        XCTAssertEqual(second.lastPathComponent, "x-2.JPG")
        XCTAssertEqual(third.lastPathComponent, "x-3.JPG")
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("x.JPG")), sentinel)
        XCTAssertEqual(try names(out), ["x-2.JPG", "x-3.JPG", "x.JPG"])
    }

    func testPrintsAtOnceToOneNameBothLand() async throws {
        let out = try folder()
        let room = room()
        async let a = room.print(landscape, film: nil, to: out, name: "x.JPG", half: true)
        async let b = room.print(landscape, film: nil, to: out, name: "x.JPG", half: true)
        _ = try await [a, b]
        XCTAssertEqual(try names(out), ["x-2.JPG", "x.JPG"])
        XCTAssertEqual(try hash(out.appendingPathComponent("x.JPG")),
                       try hash(out.appendingPathComponent("x-2.JPG")))
    }

    func testFailedPrintLeavesNothing() async throws {
        let out = try folder()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: out.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: out.path) }
        let room = room()
        do {
            _ = try await room.print(landscape, film: nil, to: out, name: "x.jpg", half: true)
            XCTFail("printed into a read-only folder")
        } catch {
            XCTAssertEqual(try names(out), [])
        }

        do {
            _ = try await room.print(landscape, film: nil, to: dir.appendingPathComponent("absent"), name: "x.jpg")
            XCTFail("printed into a folder that is not there")
        } catch {}
    }

    /// The disk fills part way through: the file limit stands in for it.
    func testPrintFailingPartWayLeavesNothing() throws {
        let out = try folder().appendingPathComponent("x.jpg")
        sb_warm_up()
        let negative = try XCTUnwrap(sb_negative_open(landscape.path, nil))
        defer { sb_negative_close(negative) }
        var old = rlimit()
        getrlimit(RLIMIT_FSIZE, &old)
        var low = old
        low.rlim_cur = 200_000
        let sigxfsz = signal(SIGXFSZ, SIG_IGN)
        setrlimit(RLIMIT_FSIZE, &low)
        let rc = sb_print(negative, nil, 1, 92, 1, out.path, nil)
        setrlimit(RLIMIT_FSIZE, &old)
        signal(SIGXFSZ, sigxfsz)
        XCTAssertEqual(rc, -1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    func testRefusesACard() async throws {
        let dcim = try folder("DCIM/100CANON")
        do {
            _ = try await room().print(landscape, film: nil, to: dcim, name: "x.jpg", half: true)
            XCTFail("printed inside a DCIM tree")
        } catch {
            XCTAssertEqual(error as? DarkroomError, .refusedDestination(dcim.path))
            XCTAssertEqual(try names(dcim), [])
        }
    }

    func testRefusesAFolderBesideADCIM() async throws {
        let root = try folder()
        let dcim = root.appendingPathComponent("DCIM")
        try FileManager.default.createDirectory(at: dcim, withIntermediateDirectories: true)
        let beside = root.appendingPathComponent("beside")
        try FileManager.default.createDirectory(at: beside, withIntermediateDirectories: true)
        do {
            _ = try await room().print(landscape, film: nil, to: beside, name: "x.jpg", half: true)
            XCTFail("printed beside a DCIM")
        } catch {
            XCTAssertEqual(error as? DarkroomError, .refusedDestination(beside.path))
            XCTAssertEqual(try names(beside), [])
        }
    }

    func testBridgeCancelStopsAndLeavesNothing() throws {
        let out = try folder().appendingPathComponent("x.jpg")
        sb_warm_up()
        let negative = try XCTUnwrap(sb_negative_open(landscape.path, nil))
        defer { sb_negative_close(negative) }
        var cancel: Int32 = 1
        XCTAssertEqual(sb_print(negative, nil, 1, 92, 1, out.path, &cancel), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
        var w: Int32 = 0, h: Int32 = 0
        sb_negative_size(negative, 4, &w, &h)
        var rgb = [UInt8](repeating: 0, count: Int(w) * Int(h) * 3)
        XCTAssertEqual(sb_render(negative, nil, 4, &rgb, &cancel), 1)
    }

    func testCancelledPrintLeavesNothing() async throws {
        let out = try folder()
        let room = room()
        let can = try film("eterna")
        _ = try await room.render(landscape, film: nil, quality: .quick)   // decoded, so the print is in the develop
        let task = Task { try await room.print(landscape, film: can, to: out, name: "x.jpg") }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("the print outran the cancel")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(try names(out), [])
    }

    func testCancelledRenderStopsAndIsNotReturned() async throws {
        let room = room()
        let can = try film("eterna")
        let start = Date()
        _ = try await room.render(landscape, film: can, scale: 1)
        let whole = Date().timeIntervalSince(start)

        let again = Date()
        let task = Task { try await room.render(landscape, film: can, scale: 1) }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled render returned a picture")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(again), whole * 0.6)
    }

    func testSkimmingDoesNotQueue() async throws {
        let room = room()
        let can = try film("eterna")
        _ = try await room.render(landscape, film: nil, quality: .quick)
        let tasks = (0..<24).map { _ in Task { try await room.render(landscape, film: can, scale: 1) } }
        for task in tasks { task.cancel() }
        let start = Date()
        var cancelled = 0
        for task in tasks where (try? await task.value) == nil { cancelled += 1 }
        XCTAssertGreaterThanOrEqual(cancelled, 21)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testRendersAtOnceMatchOneAtATime() async throws {
        let room = room()
        let cans = try ["eterna", "velvia", "portra", "acros"].map(film)
        var alone: [Data] = []
        for can in cans {
            alone.append(bytes(try await room.render(landscape, film: can, quality: .fine)))
        }
        alone.append(bytes(try await room.render(landscape, film: nil, quality: .fine)))
        let all: [DarkroomFilm?] = cans + [nil]
        let url = landscape
        let together = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            for round in 0..<2 {
                for (i, can) in all.enumerated() {
                    group.addTask {
                        _ = round
                        let image = try await room.render(url, film: can, quality: .fine)
                        return (i, image.dataProvider!.data! as Data)
                    }
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(together.count, 10)
        for (i, data) in together { XCTAssertEqual(data, alone[i], "film \(i) differed at once") }
        XCTAssertEqual(room.peakRenders, 3)
    }

    func testCachesAreUsed() async throws {
        let room = room(cache: 64 << 20)
        let can = try film("gold")
        let first = try await room.render(landscape, film: can, quality: .quick)
        let second = try await room.render(landscape, film: can, quality: .quick)
        XCTAssertTrue(first === second)

        let cache = dir.appendingPathComponent("cache")
        let thumb = try await room.thumbnail(landscape)
        XCTAssertLessThanOrEqual(max(thumb.width, thumb.height), 1000)
        XCTAssertEqual(try names(cache).count, 1)
        _ = try await room.thumbnail(landscape)
        XCTAssertEqual(try names(cache).count, 1)
    }

    /// A read-only copy in a read-only folder: anything the app wrote beside
    /// a frame would fail here, and the folder's listing would show it.
    func testReadsOnly() async throws {
        let shelf = try folder("card")
        let copy = shelf.appendingPathComponent("IMG_3990.CR2")
        try FileManager.default.copyItem(at: landscape, to: copy)
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: copy.path)
        try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: shelf.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shelf.path) }
        let mark = try hash(copy)
        let room = room()
        _ = try await room.thumbnail(copy)
        _ = try await room.placeholder(copy)
        _ = try await room.render(copy, film: nil, quality: .quick)
        _ = try await room.print(copy, film: nil, to: folder(), name: "x.jpg", half: true)
        XCTAssertEqual(try names(shelf), ["IMG_3990.CR2"])
        XCTAssertEqual(try hash(copy), mark)
    }

    /// The negative outlives the file, as it must outlive a pulled card.
    func testNegativeOutlivesTheFile() async throws {
        let shelf = try folder("card")
        let copy = shelf.appendingPathComponent("IMG_3990.CR2")
        try FileManager.default.copyItem(at: landscape, to: copy)
        let room = room()
        let can = try film("provia")
        _ = try await room.render(copy, film: nil, quality: .quick)
        try FileManager.default.removeItem(at: copy)
        let after = try await room.render(copy, film: can, quality: .quick)
        XCTAssertEqual(after.width, 1296)
        let printed = try await room.print(copy, film: can, to: folder(), name: "x.jpg", half: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: printed.path))
    }

    func testEmbeddedAtEachScale() throws {
        for (scale, w, h) in [(1, 5184, 3456), (2, 2592, 1728), (4, 1296, 864), (8, 648, 432)] {
            var pixels: UnsafeMutablePointer<UInt8>?
            var pw: Int32 = 0, ph: Int32 = 0
            XCTAssertEqual(sb_cr2_embedded(landscape.path, Int32(scale), &pixels, &pw, &ph), 0)
            XCTAssertEqual([Int(pw), Int(ph)], [w, h])
            sb_free(pixels)
        }
    }

    func testNotACR2() async throws {
        let junk = dir.appendingPathComponent("junk.CR2")
        try Data(repeating: 7, count: 4096).write(to: junk)
        do {
            _ = try await room().render(junk, film: nil, quality: .quick)
            XCTFail("rendered junk")
        } catch {
            XCTAssertEqual(error as? DarkroomError, .unreadable(junk.path))
        }
    }
}
