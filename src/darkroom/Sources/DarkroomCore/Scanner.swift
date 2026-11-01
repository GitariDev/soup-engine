import CSoup
import Foundation

/// What the engine reads from a CR2 without decoding it.
public struct CR2Facts: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var orientation: Int
    public var make: String
    public var model: String
    /// `YYYY:MM:DD HH:MM:SS`, empty if unknown.
    public var dateTime: String
    /// Seconds.
    public var exposure: Double
    public var aperture: Double
    public var iso: Int

    public init(width: Int = 5184, height: Int = 3456, orientation: Int = 1, make: String = "Canon",
                model: String = "Canon EOS 700D", dateTime: String, exposure: Double = 0.01,
                aperture: Double = 2.8, iso: Int = 100) {
        self.width = width
        self.height = height
        self.orientation = orientation
        self.make = make
        self.model = model
        self.dateTime = dateTime
        self.exposure = exposure
        self.aperture = aperture
        self.iso = iso
    }
}

/// The two reads a scan needs, as closures so tests can fake them.
public struct FrameProbe: Sendable {
    /// The CR2's facts, or nil if the engine cannot read it.
    public var cr2: @Sendable (URL) -> CR2Facts?
    /// The film in a print's Software tag, or nil.
    public var printFilm: @Sendable (URL) -> String?

    public init(cr2: @escaping @Sendable (URL) -> CR2Facts?, printFilm: @escaping @Sendable (URL) -> String?) {
        self.cr2 = cr2
        self.printFilm = printFilm
    }

    public static let bridge = FrameProbe(
        cr2: { url in
            var f = sb_cr2_facts()
            guard sb_cr2_probe(url.path, &f) == 0 else { return nil }
            return CR2Facts(width: Int(f.width), height: Int(f.height), orientation: Int(f.orientation),
                            make: text(f.make), model: text(f.model), dateTime: text(f.datetime),
                            exposure: Double(f.exposure_time), aperture: Double(f.aperture), iso: Int(f.iso))
        },
        printFilm: { url in
            var buf = [CChar](repeating: 0, count: 128)
            guard sb_jpeg_software(url.path, &buf, buf.count) == 0 else { return nil }
            let s = String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        })

    /// A fixed C char array to a String, stopping at the first NUL.
    private static func text<T>(_ field: T) -> String {
        withUnsafeBytes(of: field) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

/// An `FLM_nnnn.JPG` beside a CR2, and not empty.
public struct CardPrint: Sendable, Equatable {
    public let url: URL
    public let bytes: Int64
    /// The film in its Software tag.
    public let film: String?

    public init(url: URL, bytes: Int64, film: String?) {
        self.url = url
        self.bytes = bytes
        self.film = film
    }
}

/// One folder as listed, before any file is opened.
public struct FolderListing: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let url: URL
        public let bytes: Int64
    }
    public let folder: URL
    /// Sorted by name.
    public let cr2s: [Entry]
    /// By the four digits. When two names differ only in case, a non-empty one is kept.
    public let prints: [String: Entry]
    /// Why the folder could not be listed, if it could not.
    public let problem: String?
}

/// One CR2 on disk, with what the card says about it.
public struct FrameFile: Sendable, Equatable {
    public let url: URL
    public let bytes: Int64
    /// Nil when the engine could not read it. It stays in the list.
    public let facts: CR2Facts?
    public let cardPrint: CardPrint?
    /// An `FLM_` of zero bytes is beside it: an output the power cut off.
    public let cutOffPrint: Bool

    public init(url: URL, bytes: Int64, facts: CR2Facts?, cardPrint: CardPrint?, cutOffPrint: Bool = false) {
        self.url = url
        self.bytes = bytes
        self.facts = facts
        self.cardPrint = cardPrint
        self.cutOffPrint = cutOffPrint
    }

    public var name: String { url.lastPathComponent }
    public var stem: String { url.deletingPathExtension().lastPathComponent }
    public var folderName: String { url.deletingLastPathComponent().lastPathComponent }
    /// The four digits before the extension.
    public var digits: String? { CardName.digits(name) }
    public var number: Int? { digits.flatMap { Int($0) } }
    public var isReadable: Bool { facts != nil }
    public var dateTime: String { facts?.dateTime ?? "" }
    public var time: NaiveTime? { NaiveTime(exif: dateTime) }
    /// R1: `<stem>|<CR2 date and time>|<bytes>`. A number alone is not an identity.
    public var identity: String { "\(stem)|\(dateTime)|\(bytes)" }
}

public enum ScanEvent: Sendable, Equatable {
    /// Listing is done: how many frames there will be.
    case listed(total: Int, problems: [String])
    /// Frames probed since the last event, in folder and name order.
    case frames([FrameFile])
    case finished
}

/// Reads frames. Never writes, and a CR2 it cannot probe is flagged, not dropped.
public struct FrameScanner: Sendable {
    public var probe: FrameProbe
    public var batchSize: Int

    public init(probe: FrameProbe = .bridge, batchSize: Int = 32) {
        self.probe = probe
        self.batchSize = max(1, batchSize)
    }

    /// Names and sizes only: fast, and enough to lay out a grid.
    public func list(_ folder: URL) -> FolderListing {
        guard let names = Paths.names(in: folder) else {
            return FolderListing(folder: folder, cr2s: [], prints: [:],
                                 problem: "\(folder.lastPathComponent) cannot be read.")
        }
        var cr2s: [FolderListing.Entry] = []
        var prints: [String: FolderListing.Entry] = [:]
        for name in names.sorted() where !name.hasPrefix(".") {
            let url = folder.appendingPathComponent(name)
            if CardName.isCR2(name) {
                if let size = Paths.fileSize(url) { cr2s.append(.init(url: url, bytes: size)) }
            } else if let d = CardName.printDigits(name), let size = Paths.fileSize(url) {
                if (prints[d]?.bytes ?? 0) == 0 { prints[d] = .init(url: url, bytes: size) }
            }
        }
        return FolderListing(folder: folder, cr2s: cr2s, prints: prints, problem: nil)
    }

    /// Opens one listed CR2 and the print beside it.
    public func read(_ entry: FolderListing.Entry, in listing: FolderListing) -> FrameFile {
        let beside = CardName.digits(entry.url.lastPathComponent).flatMap { listing.prints[$0] }
        var print: CardPrint?
        if let beside, beside.bytes > 0 {
            print = CardPrint(url: beside.url, bytes: beside.bytes, film: probe.printFilm(beside.url))
        }
        return FrameFile(url: entry.url, bytes: entry.bytes, facts: probe.cr2(entry.url), cardPrint: print,
                         cutOffPrint: beside?.bytes == 0)
    }

    /// Everything, at once. Blocks: call it off the main thread.
    public func scan(_ source: BenchSource) -> [FrameFile] {
        var out: [FrameFile] = []
        for listing in listings(source) {
            for entry in entries(listing, source) { out.append(read(entry, in: listing)) }
        }
        return out
    }

    /// Frames in batches, read on a background task. Stop consuming to cancel.
    public func stream(_ source: BenchSource) -> AsyncStream<ScanEvent> {
        AsyncStream { out in
            let task = Task.detached(priority: .userInitiated) {
                let all = listings(source)
                out.yield(.listed(total: all.reduce(0) { $0 + entries($1, source).count },
                                  problems: all.compactMap(\.problem)))
                var batch: [FrameFile] = []
                for listing in all {
                    for entry in entries(listing, source) {
                        if Task.isCancelled { out.finish(); return }
                        batch.append(read(entry, in: listing))
                        if batch.count >= batchSize {
                            out.yield(.frames(batch))
                            batch.removeAll(keepingCapacity: true)
                        }
                    }
                }
                if !batch.isEmpty { out.yield(.frames(batch)) }
                out.yield(.finished)
                out.finish()
            }
            out.onTermination = { _ in task.cancel() }
        }
    }

    private func listings(_ source: BenchSource) -> [FolderListing] { source.folders.map(list) }

    private func entries(_ listing: FolderListing, _ source: BenchSource) -> [FolderListing.Entry] {
        guard let only = source.onlyFile?.lastPathComponent else { return listing.cr2s }
        return listing.cr2s.filter { $0.url.lastPathComponent == only }
    }
}
