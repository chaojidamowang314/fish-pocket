import CryptoKit
import Foundation
import UIKit

/// The plugin store's copy on disk of what it last read: the index sources, each index's first page
/// in default order, README documents and remote icons. The store opens on it at once, offline too,
/// and reads again behind it. It lives under Caches: the system may clear it whenever it likes, and
/// nothing here is the only copy of anything.
enum PluginStoreCache {
    /// A change to what is written here moves to a new folder; the old ones are removed.
    private static let format = "v1"
    private static let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("plugin-store", isDirectory: true)
    private static let base = root.appendingPathComponent(format, isDirectory: true)
    /// One queue for every read and write, so a read never sees half a file and writes never pile up on the main thread.
    private static let queue = DispatchQueue(label: "plugin-store-cache", qos: .utility)

    /// Ceilings per folder; past one, the least recently used files go first.
    private static let limits: [String: (files: Int, bytes: Int64)] = [
        "listings": (32, 32 << 20),
        "readmes": (200, 32 << 20),
        "icons": (2_000, 64 << 20),
    ]

    // MARK: Documents

    static func indexes() async -> [JSON]? { await read("indexes.json")?.array }
    static func saveIndexes(_ indexes: [JSON]) { write("indexes.json", .array(indexes)) }

    /// An index's first page in default order, as `pluginMarket/search` answered it.
    static func listing(_ url: String) async -> JSON? { await read("listings/\(key(url)).json") }
    static func saveListing(_ url: String, _ result: JSON) { write("listings/\(key(url)).json", result) }

    /// A `pluginMarket/readEntryDetail` answer, per index, plugin, version and language.
    static func readme(_ parts: [String]) async -> JSON? { await read("readmes/\(key(parts.joined(separator: "\n"))).json") }
    static func saveReadme(_ parts: [String], _ detail: JSON) { write("readmes/\(key(parts.joined(separator: "\n"))).json", detail) }

    // MARK: Icons

    /// The bytes of a remote icon: from disk while they are fresh, else from the network, and from
    /// disk again when the network fails.
    static func icon(_ url: URL) async -> Data? {
        let path = "icons/\(key(url.absoluteString))"
        let stored: (data: Data, age: TimeInterval)? = await onQueue {
            let file = base.appendingPathComponent(path)
            guard let data = try? Data(contentsOf: file) else { return nil }
            let written = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            touch(file)
            return (data, Date().timeIntervalSince(written))
        }
        if let stored, stored.age < iconLifetime { return stored.data }
        if let fetched = await fetchIcon(url) {
            writeData(path, fetched)
            return fetched
        }
        return stored?.data
    }

    /// Icons rarely change under the same address; a week keeps the store from asking every visit.
    private static let iconLifetime: TimeInterval = 7 * 24 * 3600
    private static let iconMaxBytes = 2 << 20

    private static func fetchIcon(_ url: URL) async -> Data? {
        let request = URLRequest(url: url, timeoutInterval: 20)
        guard let reply = try? await URLSession.shared.data(for: request),
              (reply.1 as? HTTPURLResponse)?.statusCode == 200,
              !reply.0.isEmpty, reply.0.count <= iconMaxBytes,
              UIImage(data: reply.0) != nil || isSVG(reply.0) else { return nil }
        return reply.0
    }

    static func isSVG(_ data: Data) -> Bool {
        String(decoding: data.prefix(1024), as: UTF8.self).lowercased().contains("<svg")
    }

    // MARK: Files

    private static func key(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func read(_ path: String) async -> JSON? {
        await onQueue {
            let file = base.appendingPathComponent(path)
            guard let data = try? Data(contentsOf: file), let value = try? JSONDecoder().decode(JSON.self, from: data) else { return nil }
            touch(file)
            return value
        }
    }

    private static func write(_ path: String, _ value: JSON) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        writeData(path, data)
    }

    private static func writeData(_ path: String, _ data: Data) {
        queue.async {
            tidyOnce()
            let file = base.appendingPathComponent(path)
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard (try? data.write(to: file, options: .atomic)) != nil else { return }
            let folder = path.components(separatedBy: "/").first ?? ""
            if let limit = limits[folder] { trim(base.appendingPathComponent(folder, isDirectory: true), limit) }
        }
    }

    private static func onQueue<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    /// Marks a file as used, for `trim`.
    private static func touch(_ file: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
    }

    /// Drop the least recently used files until the folder is within its limits.
    private static func trim(_ folder: URL, _ limit: (files: Int, bytes: Int64)) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .totalFileAllocatedSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return }
        var entries = files.map { file -> (url: URL, used: Date, size: Int64) in
            let values = try? file.resourceValues(forKeys: Set(keys))
            return (file, values?.contentModificationDate ?? .distantPast, Int64(values?.totalFileAllocatedSize ?? 0))
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard entries.count > limit.files || total > limit.bytes else { return }
        entries.sort { $0.used < $1.used }
        var count = entries.count
        for entry in entries where count > limit.files || total > limit.bytes {
            try? FileManager.default.removeItem(at: entry.url)
            count -= 1
            total -= entry.size
        }
    }

    private static var tidied = false

    /// Once per launch, on the queue: remove folders an older format wrote.
    private static func tidyOnce() {
        guard !tidied else { return }
        tidied = true
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where folder.lastPathComponent != format {
            try? FileManager.default.removeItem(at: folder)
        }
    }
}

/// Decoded remote icons, shared by every row, so a list scrolled back up draws them without waiting.
enum PluginIconMemory {
    enum Art { case image(UIImage), svg(String) }

    final class Box {
        let art: Art
        init(_ art: Art) { self.art = art }
    }

    private static let cache: NSCache<NSURL, Box> = {
        let cache = NSCache<NSURL, Box>()
        cache.countLimit = 300
        return cache
    }()

    static func cached(_ url: URL) -> Art? { cache.object(forKey: url as NSURL)?.art }

    /// From memory, else from `PluginStoreCache.icon`; SVG becomes a data URL for the web view.
    static func load(_ url: URL) async -> Art? {
        if let hit = cached(url) { return hit }
        guard let data = await PluginStoreCache.icon(url) else { return nil }
        let art: Art
        if PluginStoreCache.isSVG(data) {
            art = .svg("data:image/svg+xml;base64,\(data.base64EncodedString())")
        } else if let image = UIImage(data: data) {
            art = .image(image)
        } else {
            return nil
        }
        cache.setObject(Box(art), forKey: url as NSURL)
        return art
    }
}
