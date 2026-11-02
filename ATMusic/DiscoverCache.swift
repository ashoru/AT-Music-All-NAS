import Foundation

/// 主页数据缓存：内存 + Library/Caches 磁盘快照。
/// 冷启动先读上次快照立即展示，再按 TTL 静默刷新；缓存可被系统随时清理，不影响用户数据。
final class DiscoverCache {
    static let shared = DiscoverCache()

    struct Snapshot: Codable {
        var dailySongs: [Song] = []
        var topLists: [TopList] = []
        var personalized: [Playlist] = []
        var qqTopLists: [QQTopInfo] = []
        var kugouTopLists: [KugouTopInfo] = []
        var savedAt: Date = .distantPast

        var isEmpty: Bool {
            dailySongs.isEmpty && topLists.isEmpty && personalized.isEmpty
                && qqTopLists.isEmpty && kugouTopLists.isEmpty
        }
    }

    /// 排行榜 / 歌单广场缓存时长（秒）
    let listTTL: TimeInterval = 3600
    /// 每日推荐缓存时长（秒）
    let dailyTTL: TimeInterval = 6 * 3600

    private var store: [String: Snapshot] = [:]
    private let fm = FileManager.default
    private let directory: URL

    private init() {
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("ATMusicDiscoverCache", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cached(for source: SearchProvider) -> Snapshot? {
        if let snapshot = store[source.rawValue] {
            return snapshot
        }
        let url = fileURL(for: source)
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              !snapshot.isEmpty else {
            return nil
        }
        store[source.rawValue] = snapshot
        return snapshot
    }

    func save(_ snapshot: Snapshot, for source: SearchProvider) {
        guard !snapshot.isEmpty else { return }
        store[source.rawValue] = snapshot
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL(for: source), options: .atomic)
    }

    func remove(for source: SearchProvider) {
        store.removeValue(forKey: source.rawValue)
        try? fm.removeItem(at: fileURL(for: source))
    }

    /// 缓存是否仍然新鲜：每日推荐单独放宽到 6 小时，其余按 1 小时。
    func isFresh(_ snapshot: Snapshot) -> Bool {
        let age = Date().timeIntervalSince(snapshot.savedAt)
        let ttl = snapshot.dailySongs.isEmpty ? listTTL : dailyTTL
        return age < ttl
    }

    private func fileURL(for source: SearchProvider) -> URL {
        let safeName = source.rawValue
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return directory.appendingPathComponent("\(safeName).json")
    }
}

