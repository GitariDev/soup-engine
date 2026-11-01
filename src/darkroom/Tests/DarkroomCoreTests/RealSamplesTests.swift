import DarkroomCore
import XCTest

/// Real CR2s through the real bridge. Set SOUP_SAMPLES to a folder of them; it
/// is only read.
final class RealSamplesTests: XCTestCase {
    func testSamplesThroughTheBridge() throws {
        guard let path = ProcessInfo.processInfo.environment["SOUP_SAMPLES"] else {
            throw XCTSkip("SOUP_SAMPLES is not set")
        }
        let source = try Bench.open(folderOrFile: URL(fileURLWithPath: path, isDirectory: true))
        let files = FrameScanner().scan(source)
        XCTAssertGreaterThan(files.count, 0)
        for f in files {
            XCTAssertTrue(f.isReadable, f.name)
            XCTAssertNotNil(f.time, f.name)
            XCTAssertNotNil(f.number, f.name)
            XCTAssertEqual(f.facts?.width, 5184, f.name)
            XCTAssertEqual(f.facts?.height, 3456, f.name)
            XCTAssertGreaterThan(f.facts?.exposure ?? 0, 0, f.name)
        }
        XCTAssertEqual(Set(files.map(\.identity)).count, files.count)
        XCTAssertEqual(files.first { $0.name == "IMG_4019.CR2" }?.facts?.orientation, 6)
        XCTAssertEqual(files.first { $0.name == "IMG_3990.CR2" }?.facts?.orientation, 1)

        // The samples have Canon JPEGs and no FLM_, so none of them is developed.
        var record = BenchRecord(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("unused-\(UUID())"))
        let shelf = FilmShelf(cardFolder: nil, addedFolder: nil, bundledFolder: nil)
        let frames = Frame.assemble(files, roll: nil, record: &record, shelf: shelf)
        XCTAssertEqual(FilterCounts(frames).notDeveloped, frames.count)
        XCTAssertEqual(FilterCounts(frames).noRecord, frames.count)
    }
}
