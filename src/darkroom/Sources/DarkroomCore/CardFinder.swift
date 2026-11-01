import Foundation

/// A mounted volume that holds camera folders.
public struct Card: Sendable, Equatable, Identifiable {
    public let root: URL
    public let dcfFolders: [URL]
    public let hasML: Bool
    public var id: String { root.path }
    public var name: String { root.lastPathComponent }
}

public enum CardFinder {
    /// What is in `/Volumes`.
    public static func mountedVolumes() -> [URL] {
        let root = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        return (Paths.names(in: root) ?? [])
            .filter { !$0.hasPrefix(".") }
            .map { root.appendingPathComponent($0) }
    }

    /// Every card found, best first: one with `ML/` ahead of one without.
    public static func findCards(volumes: [URL] = mountedVolumes()) -> [Card] {
        let cards: [Card] = volumes.compactMap { root in
            guard let dcim = Paths.child(of: root, named: "DCIM"), Paths.isDirectory(dcim) else { return nil }
            let folders = dcfFolders(in: dcim)
            if folders.isEmpty { return nil }
            let ml = Paths.child(of: root, named: "ML")
            return Card(root: root, dcfFolders: folders, hasML: ml.map(Paths.isDirectory) ?? false)
        }
        return cards.sorted { ($0.hasML ? 0 : 1, $0.name) < ($1.hasML ? 0 : 1, $1.name) }
    }

    /// DCF folders in a DCIM folder, sorted. `EOSMISC` does not fit the
    /// pattern, and is named here so nobody has to work that out.
    static func dcfFolders(in dcim: URL) -> [URL] {
        (Paths.names(in: dcim) ?? [])
            .filter { $0.uppercased() != "EOSMISC" && CardName.isDCFFolder($0) }
            .sorted()
            .map { dcim.appendingPathComponent($0) }
            .filter(Paths.isDirectory)
    }
}

public enum BenchError: Error, Equatable, LocalizedError {
    case notFound(URL)
    case notACR2(URL)

    public var errorDescription: String? {
        switch self {
        case .notFound(let u): return "\(u.lastPathComponent) cannot be found."
        case .notACR2(let u): return "\(u.lastPathComponent) is not a CR2 or a folder."
        }
    }
}

/// What a pick resolves to: the folders to read, and the card's films and roll
/// if they can be found.
public struct BenchSource: Sendable, Equatable {
    public let picked: URL
    public let folders: [URL]
    /// Set when a single CR2 was picked.
    public let onlyFile: URL?
    public let filmFolder: URL?
    public let rollFile: URL?
}

public enum Bench {
    /// Accepts a card root, a DCIM folder, a DCF folder, any folder of CR2s, or
    /// a single CR2. Looks upward through the parents for `ML/FILM` and
    /// `ML/DATA/SOUPROLL.TXT`, and accepts a `SOUPROLL.TXT` in the picked folder.
    public static func open(folderOrFile picked: URL) throws -> BenchSource {
        guard Paths.exists(picked) else { throw BenchError.notFound(picked) }
        let start: URL
        var folders: [URL]
        var only: URL?
        if Paths.isDirectory(picked) {
            start = picked
            folders = foldersToRead(in: picked)
        } else {
            guard CardName.isCR2(picked.lastPathComponent) else { throw BenchError.notACR2(picked) }
            start = picked.deletingLastPathComponent()
            folders = [start]
            only = picked
        }
        folders = folders.map(\.standardizedFileURL)

        var film: URL?
        var roll: URL?
        if let beside = Paths.child(of: start, named: "SOUPROLL.TXT"), Paths.fileSize(beside) != nil {
            roll = beside
        }
        for dir in Paths.upward(from: start) where film == nil || roll == nil {
            guard let ml = Paths.child(of: dir, named: "ML"), Paths.isDirectory(ml) else { continue }
            if film == nil, let f = Paths.child(of: ml, named: "FILM"), Paths.isDirectory(f) { film = f }
            if roll == nil, let d = Paths.child(of: ml, named: "DATA"),
               let r = Paths.child(of: d, named: "SOUPROLL.TXT"), Paths.fileSize(r) != nil { roll = r }
        }
        return BenchSource(picked: picked, folders: folders, onlyFile: only, filmFolder: film, rollFile: roll)
    }

    private static func foldersToRead(in dir: URL) -> [URL] {
        let name = dir.lastPathComponent.uppercased()
        if name == "DCIM" { return CardFinder.dcfFolders(in: dir) }
        if let dcim = Paths.child(of: dir, named: "DCIM"), Paths.isDirectory(dcim) {
            let found = CardFinder.dcfFolders(in: dcim)
            if !found.isEmpty { return found }
        }
        let inside = CardFinder.dcfFolders(in: dir)
        if inside.isEmpty { return [dir] }
        let ownFrames = (Paths.names(in: dir) ?? []).contains(where: CardName.isCR2)
        return ownFrames ? [dir] + inside : inside
    }
}
