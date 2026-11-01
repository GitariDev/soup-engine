// DarkroomEngine: the frames as the app wants them. Pictures come back rotated
// for display, long C calls run on this file's own threads, and a cancelled
// task stops its render through the bridge's cancel flag.
import CSoup
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum RenderQuality: Sendable {
    case quick, fine

    public var scale: Int {
        switch self {
        case .quick: return 4
        case .fine: return 2
        }
    }
}

public enum PrintStage: Sendable { case decoding, developing, moving }

public enum DarkroomError: Error, Equatable {
    case unreadable(String)
    case renderFailed(String)
    case printFailed(String)
    case refusedDestination(String)
    case badName(String)
}

/// A film, loaded. A class so that a render still running after its task was
/// cancelled keeps the film alive, whatever the caller has dropped.
public final class DarkroomFilm: @unchecked Sendable {
    let handle: OpaquePointer
    let id: String
    public let name: String
    public let desc: String

    public init?(url: URL) {
        guard let bytes = try? Data(contentsOf: url),
              let handle = url.withUnsafeFileSystemRepresentation({ $0.flatMap(sb_film_load) })
        else { return nil }
        self.handle = handle
        id = sha(bytes)
        name = String(cString: sb_film_name(handle))
        desc = String(cString: sb_film_desc(handle))
    }

    deinit { sb_film_free(handle) }
}

public final class Darkroom: @unchecked Sendable {
    public static let defaultCacheDirectory = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Soup Darkroom", isDirectory: true)

    private static let warmed: Void = sb_warm_up()

    private let renders = Pool(label: "soup.render", limit: 3)
    private let embedded = Pool(label: "soup.embedded", limit: 2)
    private let negatives = LRU<Negative>(maxCost: 4)
    private let images: LRU<CGImage>
    private let cacheDirectory: URL
    private let tempLock = NSLock()
    private var tempsInUse = Set<String>()

    public init(cacheDirectory: URL = Darkroom.defaultCacheDirectory,
                imageCacheBytes: Int = 512 << 20) {
        _ = Darkroom.warmed
        self.cacheDirectory = cacheDirectory
        images = LRU(maxCost: imageCacheBytes)
    }

    /// The most renders that have run together, for the tests.
    var peakRenders: Int { renders.peak }

    // MARK: Embedded pictures

    /// The embedded JPEG, small and rotated. Kept on disk under the cache
    /// directory, keyed by path, size and mtime; never beside the CR2.
    public func thumbnail(_ url: URL) async throws -> CGImage {
        let stamp = try frameStamp(url)
        let file = cacheDirectory.appendingPathComponent(sha(Data(stamp.utf8)) + ".jpg")
        let thumbnail = try await offload(embedded) { [cacheDirectory] _ in
            if let source = CGImageSourceCreateWithURL(file as CFURL, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) { return image }
            let image = try embeddedImage(url, scale: 8)
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            writeJPEG(image, to: file)
            return image
        }
        try Task.checkCancellation()
        return thumbnail
    }

    /// The embedded JPEG for the moment before the render, rotated.
    public func placeholder(_ url: URL) async throws -> CGImage {
        let key = try frameStamp(url) + "|embedded"
        if let hit = images.get(key) { return hit }
        let image = try await offload(embedded) { _ in try embeddedImage(url, scale: 4) }
        images.put(key, image, cost: image.bytesPerRow * image.height)
        try Task.checkCancellation()
        return image
    }

    // MARK: Renders

    /// `film` nil is the straight raw. Throws CancellationError if the task
    /// was cancelled, even when the work had just finished, so a stale result
    /// never reaches the caller.
    public func render(_ url: URL, film: DarkroomFilm?, quality: RenderQuality) async throws -> CGImage {
        try await render(url, film: film, scale: quality.scale)
    }

    public func render(_ url: URL, film: DarkroomFilm?, scale: Int) async throws -> CGImage {
        let stamp = try frameStamp(url)
        let key = "\(stamp)|\(film?.id ?? "straight")|\(scale)"
        if let hit = images.get(key) {
            try Task.checkCancellation()
            return hit
        }
        let image = try await offload(renders) { [self] flag in
            let negative = try negative(url, stamp: stamp)
            return try withExtendedLifetime((negative, film)) {
                let handle = try negative.open(flag)
                if flag.pointee != 0 { throw CancellationError() }
                var w: Int32 = 0, h: Int32 = 0
                sb_negative_size(handle, Int32(scale), &w, &h)
                var rgb = Data(count: Int(w) * Int(h) * 3)
                let rc = rgb.withUnsafeMutableBytes {
                    sb_render(handle, film?.handle, Int32(scale),
                              $0.bindMemory(to: UInt8.self).baseAddress, flag)
                }
                if rc == 1 { throw CancellationError() }
                guard rc == 0 else { throw DarkroomError.renderFailed(url.path) }
                return try rotated(rgb, Int(w), Int(h), negative.orientation, url)
            }
        }
        images.put(key, image, cost: image.bytesPerRow * image.height)
        try Task.checkCancellation()
        return image
    }

    // MARK: Prints

    /// Print into `folder` as `name`, or as `name-2`, `name-3` if that is
    /// taken. An existing file is never touched. Full size, or half.
    /// Returns where the print landed. A cancel or a failure leaves nothing.
    public func print(_ url: URL, film: DarkroomFilm?, to folder: URL, name: String,
                      half: Bool = false, quality: Int = 92,
                      progress: (@Sendable (PrintStage) -> Void)? = nil) async throws -> URL {
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains("\0") else {
            throw DarkroomError.badName(name)
        }
        try refuseCard(folder)
        let stamp = try frameStamp(url)
        let temp = reserveTemp(folder, name)
        defer { releaseTemp(temp) }

        return try await offload(renders) { [self] flag in
            progress?(.decoding)
            let negative = try negative(url, stamp: stamp)
            return try withExtendedLifetime((negative, film)) {
                let handle = try negative.open(flag)
                if flag.pointee != 0 { throw CancellationError() }
                progress?(.developing)
                let rc = temp.withCString {
                    sb_print(handle, film?.handle, half ? 2 : 1, Int32(quality),
                             Int32(negative.orientation), $0, flag)
                }
                if rc == 1 { throw CancellationError() }
                guard rc == 0 else { throw DarkroomError.printFailed(temp) }
                do {
                    if flag.pointee != 0 { throw CancellationError() }
                    progress?(.moving)
                    return try moveIntoPlace(temp, folder: folder, name: name)
                } catch {
                    unlink(temp)
                    throw error
                }
            }
        }
    }

    /// One temporary name per print: two prints to one name must not share it.
    private func reserveTemp(_ folder: URL, _ name: String) -> String {
        tempLock.lock()
        defer { tempLock.unlock() }
        var n = 1
        while true {
            let leaf = n == 1 ? ".\(name).soup-tmp" : ".\(name)-\(n).soup-tmp"
            let path = folder.appendingPathComponent(leaf).path
            if tempsInUse.insert(path).inserted { return path }
            n += 1
        }
    }

    private func releaseTemp(_ path: String) {
        tempLock.lock()
        tempsInUse.remove(path)
        tempLock.unlock()
    }

    // MARK: Negatives

    /// A stat is what tells frames apart. A frame that has gone with its card
    /// still answers to the negative held for it.
    private func frameStamp(_ url: URL) throws -> String {
        var st = stat()
        if stat(url.path, &st) == 0 {
            return "\(url.path)|\(st.st_size)|\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)"
        }
        if let held = negatives.peek(url.path) { return held.stamp }
        throw DarkroomError.unreadable(url.path)
    }

    private func negative(_ url: URL, stamp: String) throws -> Negative {
        negatives.getOrPut(url.path, cost: 1, matching: { $0.stamp == stamp }) {
            Negative(path: url.path, stamp: stamp) { [negatives] in negatives.remove(url.path) }
        }
    }
}

// MARK: - a decoded negative

/// Decoded on first use, once, whoever asks first: the lock makes a second
/// render of the same frame wait rather than decode it again.
private final class Negative: @unchecked Sendable {
    let path: String
    let stamp: String
    private(set) var orientation = 1
    private let lock = NSLock()
    private var handle: OpaquePointer?
    private let failed: () -> Void

    init(path: String, stamp: String, failed: @escaping () -> Void) {
        self.path = path
        self.stamp = stamp
        self.failed = failed
    }

    /// A cancelled open leaves nothing behind: the next one to ask starts again.
    func open(_ cancel: UnsafePointer<Int32>) throws -> OpaquePointer {
        lock.lock()
        defer { lock.unlock() }
        if let handle { return handle }
        var facts = sb_cr2_facts()
        guard sb_cr2_probe(path, &facts) == 0, let opened = sb_negative_open(path, cancel) else {
            if cancel.pointee != 0 { throw CancellationError() }
            failed()
            throw DarkroomError.unreadable(path)
        }
        orientation = Int(facts.orientation)
        handle = opened
        return opened
    }

    deinit { if let handle { sb_negative_close(handle) } }
}

// MARK: - the thread pool

/// Long C calls run here and not on the cooperative pool. Waiting work is held
/// in a list, not on a thread, so a cancelled job costs nothing and is gone.
private final class Job {
    let flag = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    var cancelled = false
    var run: ((UnsafePointer<Int32>) -> Void)?
    var drop: (() -> Void)?

    init() { flag.initialize(to: 0) }
    deinit { flag.deallocate() }
}

private final class Pool: @unchecked Sendable {
    private let queue: DispatchQueue
    private let limit: Int
    private let lock = NSLock()
    private var waiting: [Job] = []
    private var running = 0
    private(set) var peak = 0

    init(label: String, limit: Int) {
        queue = DispatchQueue(label: label, qos: .userInitiated, attributes: .concurrent)
        self.limit = limit
    }

    func submit(_ job: Job) {
        lock.lock()
        if job.cancelled {
            lock.unlock()
            job.drop?()
            return
        }
        waiting.append(job)
        lock.unlock()
        pump()
    }

    func cancel(_ job: Job) {
        lock.lock()
        job.cancelled = true
        job.flag.pointee = 1
        let index = waiting.firstIndex { $0 === job }
        if let index { waiting.remove(at: index) }
        lock.unlock()
        if index != nil { job.drop?() }
    }

    private func pump() {
        lock.lock()
        defer { lock.unlock() }
        while running < limit, !waiting.isEmpty {
            let job = waiting.removeFirst()
            running += 1
            peak = max(peak, running)
            queue.async { [self] in
                job.run?(UnsafePointer(job.flag))
                lock.lock()
                running -= 1
                lock.unlock()
                pump()
            }
        }
    }
}

/// Run `work` on the pool. A job already running sees the flag and stops, and
/// this returns once it has: its temporary file is gone by then.
private func offload<T>(_ pool: Pool, _ work: @escaping (UnsafePointer<Int32>) throws -> T) async throws -> T {
    let job = Job()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            job.run = { flag in continuation.resume(with: Result { try work(flag) }) }
            job.drop = { continuation.resume(throwing: CancellationError()) }
            pool.submit(job)
        }
    } onCancel: {
        pool.cancel(job)
    }
}

// MARK: - the caches

/// Least recently used first. Short enough that a list is the plain answer.
private final class LRU<V>: @unchecked Sendable {
    private var items: [(key: String, value: V, cost: Int)] = []
    private var total = 0
    private let maxCost: Int
    private let lock = NSLock()

    init(maxCost: Int) { self.maxCost = maxCost }

    func get(_ key: String) -> V? {
        lock.lock()
        defer { lock.unlock() }
        return touch(key)
    }

    func peek(_ key: String) -> V? {
        lock.lock()
        defer { lock.unlock() }
        return items.first { $0.key == key }?.value
    }

    func put(_ key: String, _ value: V, cost: Int) {
        lock.lock()
        defer { lock.unlock() }
        insert(key, value, cost)
    }

    func getOrPut(_ key: String, cost: Int, matching: (V) -> Bool, make: () -> V) -> V {
        lock.lock()
        defer { lock.unlock() }
        if let hit = touch(key), matching(hit) { return hit }
        let value = make()
        insert(key, value, cost)
        return value
    }

    func remove(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        drop(key)
    }

    private func touch(_ key: String) -> V? {
        guard let i = items.firstIndex(where: { $0.key == key }) else { return nil }
        let item = items.remove(at: i)
        items.append(item)
        return item.value
    }

    private func insert(_ key: String, _ value: V, _ cost: Int) {
        drop(key)
        guard cost <= maxCost else { return }
        items.append((key, value, cost))
        total += cost
        while total > maxCost { total -= items.removeFirst().cost }
    }

    private func drop(_ key: String) {
        if let i = items.firstIndex(where: { $0.key == key }) { total -= items.remove(at: i).cost }
    }
}

// MARK: - pictures

func sha(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func embeddedImage(_ url: URL, scale: Int) throws -> CGImage {
    var facts = sb_cr2_facts()
    var pixels: UnsafeMutablePointer<UInt8>?
    var w: Int32 = 0, h: Int32 = 0
    guard sb_cr2_probe(url.path, &facts) == 0,
          sb_cr2_embedded(url.path, Int32(scale), &pixels, &w, &h) == 0, let pixels else {
        throw DarkroomError.unreadable(url.path)
    }
    defer { sb_free(pixels) }
    let rgb = Data(bytes: pixels, count: Int(w) * Int(h) * 3)
    return try rotated(rgb, Int(w), Int(h), Int(facts.orientation), url)
}

/// Stored pixels as the viewer should see them, per EXIF orientation 1..8.
func rotated(_ rgb: Data, _ w: Int, _ h: Int, _ orientation: Int, _ url: URL) throws -> CGImage {
    if orientation == 1 { return try image(rgb, w, h, url) }
    let swaps = orientation >= 5
    let ow = swaps ? h : w, oh = swaps ? w : h
    var out = Data(count: ow * oh * 3)
    out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
        rgb.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            let d = dst.bindMemory(to: UInt8.self), s = src.bindMemory(to: UInt8.self)
            var at = 0
            for y in 0..<oh {
                for x in 0..<ow {
                    let sx: Int, sy: Int
                    switch orientation {
                    case 2: (sx, sy) = (w - 1 - x, y)
                    case 3: (sx, sy) = (w - 1 - x, h - 1 - y)
                    case 4: (sx, sy) = (x, h - 1 - y)
                    case 5: (sx, sy) = (y, x)
                    case 6: (sx, sy) = (y, h - 1 - x)
                    case 7: (sx, sy) = (w - 1 - y, h - 1 - x)
                    case 8: (sx, sy) = (w - 1 - y, x)
                    default: (sx, sy) = (x, y)
                    }
                    let from = (sy * w + sx) * 3
                    d[at] = s[from]
                    d[at + 1] = s[from + 1]
                    d[at + 2] = s[from + 2]
                    at += 3
                }
            }
        }
    }
    return try image(out, ow, oh, url)
}

private func image(_ rgb: Data, _ w: Int, _ h: Int, _ url: URL) throws -> CGImage {
    guard let provider = CGDataProvider(data: rgb as CFData),
          let space = CGColorSpace(name: CGColorSpace.sRGB),
          let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 24,
                              bytesPerRow: w * 3, space: space,
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: true,
                              intent: .defaultIntent)
    else { throw DarkroomError.renderFailed(url.path) }
    return image
}

/// A failed cache write costs a thumbnail next time and nothing else.
private func writeJPEG(_ image: CGImage, to file: URL) {
    let temp = file.appendingPathExtension("tmp-\(UUID().uuidString)")
    guard let out = CGImageDestinationCreateWithURL(temp as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(out, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    if !CGImageDestinationFinalize(out) || rename(temp.path, file.path) != 0 { unlink(temp.path) }
}

// MARK: - into place

/// A folder on a card, or inside a DCIM tree, is never written to.
private func refuseCard(_ folder: URL) throws {
    let real = folder.resolvingSymlinksInPath().standardizedFileURL
    let volume = (try? real.resourceValues(forKeys: [.volumeURLKey]))?.volume
    let onCard = volume.map {
        FileManager.default.fileExists(atPath: $0.appendingPathComponent("DCIM").path)
    } ?? false
    if onCard || real.pathComponents.contains(where: { $0.uppercased() == "DCIM" }) {
        throw DarkroomError.refusedDestination(folder.path)
    }
}

/// `name`, then `name-2`, `name-3` in front of the extension, until one is
/// free. Each try is exclusive at the file system, so nothing can race it.
private func moveIntoPlace(_ temp: String, folder: URL, name: String) throws -> URL {
    let stem = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    var n = 1
    while true {
        var leaf = n == 1 ? stem : "\(stem)-\(n)"
        if !ext.isEmpty { leaf += "." + ext }
        let final = folder.appendingPathComponent(leaf)
        if try claim(temp, final.path) { return final }
        n += 1
    }
}

/// True if `temp` is now at `path`, false if `path` was taken.
private func claim(_ temp: String, _ path: String) throws -> Bool {
    if renamex_np(temp, path, UInt32(RENAME_EXCL)) == 0 { return true }
    if errno == EEXIST { return false }
    guard errno == ENOTSUP || errno == EINVAL || errno == ENOSYS else {
        throw DarkroomError.printFailed(String(cString: strerror(errno)))
    }
    if link(temp, path) == 0 {
        unlink(temp)
        return true
    }
    if errno == EEXIST { return false }
    guard errno == ENOTSUP || errno == EPERM || errno == ENOSYS else {
        throw DarkroomError.printFailed(String(cString: strerror(errno)))
    }
    return try copyExclusive(temp, path)
}

/// For a volume with neither exclusive rename nor hard links, such as exFAT:
/// the name is taken with O_EXCL first, so this cannot overwrite either.
private func copyExclusive(_ temp: String, _ path: String) throws -> Bool {
    let out = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
    if out < 0 {
        if errno == EEXIST { return false }
        throw DarkroomError.printFailed(String(cString: strerror(errno)))
    }
    defer { close(out) }
    guard let bytes = FileManager.default.contents(atPath: temp),
          bytes.withUnsafeBytes({ write(out, $0.baseAddress, $0.count) }) == bytes.count,
          fsync(out) == 0 else {
        unlink(path)
        throw DarkroomError.printFailed("copy to \(path)")
    }
    unlink(temp)
    return true
}
