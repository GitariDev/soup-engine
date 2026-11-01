import Foundation

/// Small file helpers. Nothing here writes.
enum Paths {
    /// Names in a folder, or nil if it cannot be listed.
    static func names(in dir: URL) -> [String]? {
        try? FileManager.default.contentsOfDirectory(atPath: dir.path)
    }

    /// A child by name, compared without regard to case. A card is FAT, and
    /// the real one has `ML/data` where the plan says `ML/DATA`.
    static func child(of dir: URL, named name: String) -> URL? {
        let exact = dir.appendingPathComponent(name)
        if exists(exact) { return exact }
        let want = name.lowercased()
        guard let hit = names(in: dir)?.first(where: { $0.lowercased() == want }) else { return nil }
        return dir.appendingPathComponent(hit)
    }

    static func exists(_ url: URL) -> Bool {
        var st = stat()
        return stat(url.path, &st) == 0
    }

    static func isDirectory(_ url: URL) -> Bool {
        var st = stat()
        return stat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    /// Size of a regular file, following links. Nil for anything else.
    static func fileSize(_ url: URL) -> Int64? {
        var st = stat()
        guard stat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        return Int64(st.st_size)
    }

    /// The folder and each parent up to the root.
    static func upward(from dir: URL) -> [URL] {
        var out: [URL] = []
        var at = dir.standardizedFileURL
        while true {
            out.append(at)
            if at.path == "/" { return out }
            at = at.deletingLastPathComponent().standardizedFileURL
        }
    }
}
