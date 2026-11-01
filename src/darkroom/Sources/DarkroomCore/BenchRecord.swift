import Foundation

/// A print this app made.
public struct DeskPrint: Sendable, Equatable, Codable {
    public let path: String
    public let film: String
    public let printedAt: Date

    public init(url: URL, film: String, printedAt: Date = Date()) {
        path = url.path
        self.film = film
        self.printedAt = printedAt
    }

    public var url: URL { URL(fileURLWithPath: path) }
}

public enum BenchRecordError: Error, LocalizedError {
    case cannotSetAside(URL)
    public var errorDescription: String? {
        switch self {
        case .cannotSetAside(let u): return "\(u.lastPathComponent) cannot be read, and could not be moved aside."
        }
    }
}

/// Choices, desk prints and the save folder, in `bench.json`. Nothing goes on
/// the card. Keyed by frame identity, so a reused number starts clean.
///
/// A print whose file is gone stops counting but stays in the file, so a drive
/// that is only unplugged brings its prints back at the next refresh.
public struct BenchRecord: Sendable, Equatable {
    public let directory: URL
    public private(set) var choices: [String: String] = [:]
    public private(set) var prints: [String: [DeskPrint]] = [:]
    public var saveFolder: URL?
    /// Where an unreadable `bench.json` was moved, when that happened at load.
    public private(set) var setAside: URL?

    private var present: Set<String> = []

    private struct Stored: Codable {
        var version: Int
        var choices: [String: String]
        var prints: [String: [DeskPrint]]
        var saveFolder: String?
    }
    private static let version = 1

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Soup Darkroom", isDirectory: true)
    }

    public var file: URL { directory.appendingPathComponent("bench.json") }

    /// An empty record that has not been saved.
    public init(directory: URL = BenchRecord.defaultDirectory) {
        self.directory = directory
    }

    /// Reads `bench.json`. A file that cannot be understood is moved aside
    /// under a new name and the record starts empty; `setAside` says where.
    /// Throws only if that move fails, so the old file is never overwritten.
    public static func load(directory: URL = BenchRecord.defaultDirectory) throws -> BenchRecord {
        var record = BenchRecord(directory: directory)
        guard Paths.exists(record.file) else { return record }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: record.file),
           let stored = try? decoder.decode(Stored.self, from: data), stored.version == version {
            record.choices = stored.choices
            record.prints = stored.prints
            record.saveFolder = stored.saveFolder.map { URL(fileURLWithPath: $0, isDirectory: true) }
            record.refresh()
        } else {
            record.setAside = try moveAside(record.file)
        }
        return record
    }

    private static func moveAside(_ file: URL) throws -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dir = file.deletingLastPathComponent()
        var target = dir.appendingPathComponent("bench.corrupt-\(stamp).json")
        var n = 2
        while Paths.exists(target) {
            target = dir.appendingPathComponent("bench.corrupt-\(stamp)-\(n).json")
            n += 1
        }
        do {
            try FileManager.default.moveItem(at: file, to: target)
        } catch {
            throw BenchRecordError.cannotSetAside(file)
        }
        return target
    }

    /// Atomic: the old file stands until the new one is complete.
    public func save() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let stored = Stored(version: Self.version, choices: choices, prints: prints, saveFolder: saveFolder?.path)
        try encoder.encode(stored).write(to: file, options: .atomic)
    }

    /// Checks each desk print against the disk. An empty file is not a print.
    public mutating func refresh() {
        present = []
        for list in prints.values {
            for print in list where (Paths.fileSize(print.url) ?? 0) > 0 { present.insert(print.path) }
        }
    }

    /// The prints of a frame still on disk, as of the last refresh.
    public func deskPrints(for identity: String) -> [DeskPrint] {
        (prints[identity] ?? []).filter { present.contains($0.path) }
    }

    public mutating func addPrint(_ print: DeskPrint, identity: String) {
        prints[identity, default: []].append(print)
        if (Paths.fileSize(print.url) ?? 0) > 0 { present.insert(print.path) }
    }

    /// Picks a can for a frame. Picking the film it would develop on anyway is
    /// not a choice, so that removes any choice instead. Nil clears it.
    public mutating func choose(_ film: Film?, for frame: Frame) {
        if let film, Film.key(film.name) != frame.otherwiseFilm.map({ Film.key($0.name) }) {
            choices[frame.identity] = film.name
        } else {
            choices[frame.identity] = nil
        }
    }
}
