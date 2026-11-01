import CSoup
import Foundation

/// The art for a film's can. The .fs format has no brand or colours: this is
/// `FILMS_DEFAULT` in doc/menu-sample/index.html, which mkui.js reads.
public struct FilmCan: Sendable, Equatable {
    public let brand: String
    public let iso: String
    public let c1: String
    public let c2: String
    public let c3: String

    /// A film the table does not know: the blank can in mkui.js.
    public static let unknown = FilmCan(brand: "SOUP", iso: "", c1: "#3a3b4c", c2: "#8d8ea0", c3: "#f2f2f7")

    private static let table: [String: FilmCan] = [
        "PORTRA": .init(brand: "KODAK", iso: "400", c1: "#f4f0e6", c2: "#ef9a1e", c3: "#1d2029"),
        "GOLD": .init(brand: "KODAK", iso: "200", c1: "#f3b71c", c2: "#c9321f", c3: "#7b1712"),
        "CLASSIC NEG": .init(brand: "FUJI", iso: "400", c1: "#0f8d73", c2: "#e8f0e4", c3: "#f7fbf5"),
        "NOSTALGIC NEG": .init(brand: "FUJI", iso: "160", c1: "#b4661a", c2: "#2c2352", c3: "#fbf1df"),
        "REALA ACE": .init(brand: "FUJI", iso: "100", c1: "#eef4ee", c2: "#1f9d62", c3: "#123524"),
        "PROVIA": .init(brand: "FUJI", iso: "100", c1: "#eaf0f8", c2: "#2a66c4", c3: "#10254e"),
        "ASTIA": .init(brand: "FUJI", iso: "100", c1: "#efb7c0", c2: "#f7ebe6", c3: "#5a2333"),
        "VELVIA": .init(brand: "FUJI", iso: "50", c1: "#4b2a96", c2: "#22b37f", c3: "#f4f0ff"),
        "CLASSIC CHROME": .init(brand: "FUJI", iso: "64", c1: "#7f7022", c2: "#a52a1b", c3: "#fbf4dc"),
        "ACROS": .init(brand: "FUJI", iso: "100", c1: "#1b1c20", c2: "#c9ccd4", c3: "#f1f2f4"),
        "ETERNA": .init(brand: "FUJI", iso: "500", c1: "#123a58", c2: "#35b5b0", c3: "#e9f7f7"),
        "BLEACH BYPASS": .init(brand: "FUJI", iso: "500", c1: "#6d727d", c2: "#25272e", c3: "#f4f5f7"),
        "SOUP 800": .init(brand: "SOUP", iso: "800", c1: "#16161c", c2: "#d62a26", c3: "#f6f1ec"),
    ]

    public static func forFilm(_ name: String) -> FilmCan { table[Film.key(name)] ?? unknown }
}

public struct Film: Sendable, Equatable, Identifiable {
    public enum Source: String, Sendable, Equatable { case card, added, bundled }

    public let name: String
    public let description: String
    public let source: Source
    public let path: URL

    public init(name: String, description: String, source: Source, path: URL) {
        self.name = name
        self.description = description
        self.source = source
        self.path = path
    }

    public var id: String { Film.key(name) }
    public var can: FilmCan { .forFilm(name) }
    public var displayName: String { Film.display(name) }

    /// A name as it is compared: without regard to case.
    public static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    /// `CLASSIC CHROME` becomes `Classic Chrome`. A word that is not plain
    /// capitals (`B&W`, `XP2`, `Portra`) is left as it was written.
    public static func display(_ name: String) -> String {
        name.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
            guard word.allSatisfy({ $0.isLetter && $0.isUppercase }), let first = word.first else { return String(word) }
            return String(first) + word.dropFirst().lowercased()
        }.joined(separator: " ")
    }
}

/// A film file the shelf would not take, and why, in plain words.
public struct RejectedFilm: Sendable, Equatable {
    public let path: URL
    public let reason: String
}

public struct FilmInfo: Sendable, Equatable {
    public let name: String
    public let description: String
    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}

public typealias FilmLoader = @Sendable (URL) -> FilmInfo?

public enum FilmError: Error, Equatable, LocalizedError {
    case noAddedFolder
    case notAFilmFile(URL)
    case refused(URL)
    case sameNameDifferentFilm(name: String, existing: URL)
    case onACard(String)

    public var errorDescription: String? {
        switch self {
        case .noAddedFolder: return "There is no folder to keep added films in."
        case .notAFilmFile(let u): return "\(u.lastPathComponent) is not a .fs file."
        case .refused(let u): return "\(u.lastPathComponent) is not a film the engine can read."
        case .sameNameDifferentFilm(let name, _):
            return "A different film called \(Film.display(name)) is already added. Remove it or rename this one."
        case .onACard(let why): return why
        }
    }
}

/// ML/FILM, then the films the user added, then the bundled stocks. One entry
/// per name, compared without regard to case, and the card's copy wins.
public struct FilmShelf: Sendable {
    public private(set) var films: [Film] = []
    public private(set) var rejected: [RejectedFilm] = []

    public let cardFolder: URL?
    public let addedFolder: URL?
    public let bundledFolder: URL?
    private let loader: FilmLoader
    private var byKey: [String: Film] = [:]

    public init(cardFolder: URL?, addedFolder: URL? = FilmShelf.defaultAddedFolder,
                bundledFolder: URL?, loader: @escaping FilmLoader = FilmShelf.bridgeLoader) {
        self.cardFolder = cardFolder
        self.addedFolder = addedFolder
        self.bundledFolder = bundledFolder
        self.loader = loader
        reload()
    }

    /// Application Support/Soup Darkroom/Films.
    public static var defaultAddedFolder: URL {
        BenchRecord.defaultDirectory.appendingPathComponent("Films", isDirectory: true)
    }

    public static let bridgeLoader: FilmLoader = { url in
        guard let f = sb_film_load(url.path) else { return nil }
        defer { sb_film_free(f) }
        return FilmInfo(name: String(cString: sb_film_name(f)), description: String(cString: sb_film_desc(f)))
    }

    public func film(named name: String) -> Film? { byKey[Film.key(name)] }

    /// Reads the shelf again from disk.
    public mutating func reload() {
        films = []
        rejected = []
        byKey = [:]
        let tiers: [(URL?, Film.Source)] = [(cardFolder, .card), (addedFolder, .added), (bundledFolder, .bundled)]
        for (folder, source) in tiers {
            guard let folder else { continue }
            var here = Set<String>()
            for (url, info) in read(folder) {
                let key = Film.key(info.name)
                if !here.insert(key).inserted {
                    rejected.append(.init(path: url, reason: "Another film in this folder is already called \(Film.display(info.name))."))
                } else if byKey[key] == nil {
                    let film = Film(name: info.name, description: info.description, source: source, path: url)
                    byKey[key] = film
                    films.append(film)
                }
            }
        }
    }

    /// The `.fs` files in a folder that the engine accepts, in name order. The
    /// ones it refuses go on `rejected`.
    private mutating func read(_ folder: URL) -> [(URL, FilmInfo)] {
        var out: [(URL, FilmInfo)] = []
        for (url, info) in Self.films(in: folder, loader: loader) {
            if let info {
                out.append((url, info))
            } else {
                rejected.append(.init(path: url, reason: "The engine could not read this as a film."))
            }
        }
        return out
    }

    private static func films(in folder: URL, loader: FilmLoader) -> [(URL, FilmInfo?)] {
        (Paths.names(in: folder) ?? [])
            .filter { !$0.hasPrefix(".") && $0.lowercased().hasSuffix(".fs") }
            .sorted()
            .map { folder.appendingPathComponent($0) }
            .map { url in
                let info = loader(url)
                return (url, info?.name.isEmpty == false ? info : nil)
            }
    }

    /// Copies a `.fs` into the app's own folder after validating it. Adding the
    /// same film again is a no-op. A different film of the same name is refused,
    /// and no file is ever replaced. Returns the film that is on the shelf
    /// under that name, which is the card's copy if the card has one.
    @discardableResult
    public mutating func addFilm(from source: URL) throws -> Film {
        guard let dir = addedFolder else { throw FilmError.noAddedFolder }
        if let why = Destination.cardReason(for: dir) { throw FilmError.onACard(why) }
        guard source.pathExtension.lowercased() == "fs", !source.lastPathComponent.hasPrefix("."),
              Paths.fileSize(source) != nil else { throw FilmError.notAFilmFile(source) }
        guard let info = loader(source), !info.name.isEmpty else { throw FilmError.refused(source) }
        let data = try Data(contentsOf: source)

        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let key = Film.key(info.name)
        for case let (url, known?) in Self.films(in: dir, loader: loader) where Film.key(known.name) == key {
            guard (try? Data(contentsOf: url)) == data else {
                throw FilmError.sameNameDifferentFilm(name: info.name, existing: url)
            }
            return try shelved(info, from: source)
        }

        let temp = dir.appendingPathComponent(".adding-\(UUID().uuidString)")
        try data.write(to: temp, options: .withoutOverwriting)
        defer { try? fm.removeItem(at: temp) }
        guard loader(temp) != nil else { throw FilmError.refused(source) }
        let stem = source.deletingPathExtension().lastPathComponent
        var target = dir.appendingPathComponent(stem + ".fs")
        var n = 2
        while Paths.exists(target) {
            target = dir.appendingPathComponent("\(stem)-\(n).fs")
            n += 1
        }
        try fm.moveItem(at: temp, to: target)
        return try shelved(info, from: source)
    }

    private mutating func shelved(_ info: FilmInfo, from source: URL) throws -> Film {
        reload()
        guard let found = film(named: info.name) else { throw FilmError.refused(source) }
        return found
    }
}
