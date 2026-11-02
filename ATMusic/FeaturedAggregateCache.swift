import Foundation

/// 精选页聚合模式本地快照缓存（Stale-While-Revalidate），保证精选页 0 毫秒秒开，避免网络等待白屏
@MainActor
final class FeaturedAggregateCache {
    static let shared = FeaturedAggregateCache()

    private let userDefaultsKey = "atmusic.featured.aggregate.snapshot"
    private var memoryCache: [String: [Playlist]] = [:]

    private init() {}

    /// 获取缓存歌单（优先内存缓存，其次持久化快照）
    func get(category: String = "全部") -> [Playlist]? {
        if let mem = memoryCache[category], !mem.isEmpty {
            return mem
        }
        guard category == "全部" else { return nil }
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let list = try? JSONDecoder().decode([Playlist].self, from: data),
              !list.isEmpty else {
            return nil
        }
        memoryCache["全部"] = list
        return list
    }

    /// 保存聚合歌单快照（最多保留前 36 首，保证极速解码与渲染）
    func set(_ playlists: [Playlist], category: String = "全部") {
        guard !playlists.isEmpty else { return }
        let snapshot = Array(playlists.prefix(36))
        memoryCache[category] = snapshot
        if category == "全部" {
            if let data = try? JSONEncoder().encode(snapshot) {
                UserDefaults.standard.set(data, forKey: userDefaultsKey)
            }
        }
    }
}
