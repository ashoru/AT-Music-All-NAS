import Foundation

/// 收藏管理（红心）：网易云登录后同步到网易云云端；QQ 本地持久化，
/// 登录 QQ 时尽力同步到 QQ 云端（music.srfDissong），失败不影响本地收藏。
final class FavoritesStore: ObservableObject {
    /// 统一红心状态变化通知：播放器据此把锁屏/控制中心星标与 App 内红心实时对齐。
    static let favoritesDidChange = Notification.Name("ATMusicFavoritesDidChange")

    static let shared = FavoritesStore()

    /// QQ 红心收藏（本地持久化，供音乐库展示）
    @Published private(set) var qqFavoriteSongs: [Song] = []
    /// 网易云红心收藏（本地缓存 + 云端同步）
    @Published private(set) var neteaseFavoriteSongs: [Song] = []
    /// 酷狗红心收藏（本地持久化，酷狗暂无稳定云端红心写入接口）
    @Published private(set) var kugouFavoriteSongs: [Song] = []
    /// 群晖 NAS 红心收藏（本地持久化）
    @Published private(set) var synologyFavoriteSongs: [Song] = []
    /// Subsonic 红心收藏（本地持久化，协议无跨设备红心同步能力）
    @Published private(set) var subsonicFavoriteSongs: [Song] = []
    /// Jellyfin 红心收藏（本地持久化，协议无跨设备红心同步能力）
    @Published private(set) var jellyfinFavoriteSongs: [Song] = []
    /// WebDAV 红心收藏（本地持久化，协议无跨设备红心同步能力）
    @Published private(set) var webdavFavoriteSongs: [Song] = []

    private let defaults = UserDefaults.standard
    private let neteaseKey = "atmusic.fav.netease.v1"
    private let qqKey = "atmusic.fav.qq.v1"
    private let kugouKey = "atmusic.fav.kugou.v1"
    private let synologyKey = "atmusic.fav.synology.v1"
    private let subsonicKey = "atmusic.fav.subsonic.v1"
    private let jellyfinKey = "atmusic.fav.jellyfin.v1"
    private let webdavKey = "atmusic.fav.webdav.v1"

    private init() {
        qqFavoriteSongs = Self.loadSongs(qqKey)
        neteaseFavoriteSongs = Self.loadSongs(neteaseKey)
        kugouFavoriteSongs = Self.loadSongs(kugouKey)
        synologyFavoriteSongs = Self.loadSongs(synologyKey)
        subsonicFavoriteSongs = Self.loadSongs(subsonicKey)
        jellyfinFavoriteSongs = Self.loadSongs(jellyfinKey)
        webdavFavoriteSongs = Self.loadSongs(webdavKey)
    }

    /// 该歌曲是否已收藏（包含平台云端/本地收藏，以及本地歌单收藏）
    func isSongLiked(_ song: Song?) -> Bool {
        guard let song else { return false }
        if isLiked(song) { return true }
        return LocalLibraryStore.shared.containsSong(song)
    }

    /// 该歌曲是否在平台收藏中
    func isLiked(_ song: Song?) -> Bool {
        guard let song else { return false }
        switch song.source {
        case .netease:
            return neteaseFavoriteSongs.contains { $0.id == song.id }
        case .qq:
            if let mid = song.qqMid, !mid.isEmpty {
                return qqFavoriteSongs.contains { $0.qqMid == mid || $0.identityKey == song.identityKey }
            }
            return qqFavoriteSongs.contains { $0.identityKey == song.identityKey }
        case .kugou:
            return kugouFavoriteSongs.contains { $0.identityKey == song.identityKey }
        case .local:
            return false
        case .synology:
            return synologyFavoriteSongs.contains { $0.identityKey == song.identityKey }
        case .subsonic:
            return subsonicFavoriteSongs.contains { $0.identityKey == song.identityKey }
        case .jellyfin:
            return jellyfinFavoriteSongs.contains { $0.identityKey == song.identityKey }
        case .webdav:
            return webdavFavoriteSongs.contains { $0.identityKey == song.identityKey }
        }
    }

    func contains(song: Song) -> Bool {
        isSongLiked(song)
    }

    /// 统一红心切换逻辑：同时同步到本地收藏歌单与对应平台的云端/本地收藏
    /// 批量添加歌曲到收藏（阶段 3 批量操作）
    @MainActor
    func addFavorites(_ songs: [Song]) async {
        guard !songs.isEmpty else { return }
        for song in songs {
            if !isSongLiked(song) {
                _ = LocalLibraryStore.shared.addToDefaultFavorites(song)
                if !isLiked(song) {
                    _ = await toggle(song)
                }
            }
        }
        NotificationCenter.default.post(name: Self.favoritesDidChange, object: self)
        ToastCenter.shared.show("已将 \(songs.count) 首歌曲加入收藏")
        ATMusicHaptics.success()
    }

    /// 批量取消收藏（阶段 3 批量操作）
    @MainActor
    func removeFavorites(_ songs: [Song]) async {
        guard !songs.isEmpty else { return }
        for song in songs {
            if isSongLiked(song) {
                _ = LocalLibraryStore.shared.removeSongFromAllPlaylists(song)
                if isLiked(song) {
                    _ = await toggle(song)
                }
            }
        }
        NotificationCenter.default.post(name: Self.favoritesDidChange, object: self)
        ToastCenter.shared.show("已将 \(songs.count) 首歌曲取消收藏")
        ATMusicHaptics.success()
    }

    @MainActor
    func toggleFavorite(_ song: Song) async {
        let currentlyLiked = isSongLiked(song)
        if currentlyLiked {
            // 取消收藏：从本地歌单和平台收藏中同时移除
            _ = LocalLibraryStore.shared.removeSongFromAllPlaylists(song)
            if isLiked(song) {
                _ = await toggle(song)
            }
            ToastCenter.shared.show("已取消收藏")
            ATMusicHaptics.success()
        } else {
            // 添加收藏：同时加入本地默认收藏歌单与对应平台收藏
            _ = LocalLibraryStore.shared.addToDefaultFavorites(song)
            if !isLiked(song) {
                _ = await toggle(song)
            }
            ToastCenter.shared.show("已添加到收藏")
            ATMusicHaptics.success()
        }
        NotificationCenter.default.post(name: Self.favoritesDidChange, object: self)
    }

    /// 切换平台收藏状态；返回是否成功
    @discardableResult
    func toggle(_ song: Song) async -> Bool {
        switch song.source {
        case .netease:
            let liked = !isLiked(song)
            updateNetease(song, liked: liked)
            // 未登录：只加本地红心，不同步云端。
            guard NetEaseAPI.shared.isLoggedIn else { return true }
            do {
                let ok = try await NetEaseAPI.shared.like(id: song.id, liked: liked)
                if !ok {
                    ATMusicLogger.shared.log("网易云红心云端同步未成功，已保留本地收藏：\(song.name) liked=\(liked)", level: .warn)
                }
                return true
            } catch {
                ATMusicLogger.shared.log("网易云红心云端同步异常，已保留本地收藏：\(song.name) error=\(error.localizedDescription)", level: .warn)
                return true
            }
        case .qq:
            let liked = !isLiked(song)
            updateQQ(song, liked: liked)
            guard let mid = song.qqMid, !mid.isEmpty else {
                ATMusicLogger.shared.log("QQ 红心缺少 songmid，已保留本地收藏：\(song.name) liked=\(liked)", level: .warn)
                return true
            }
            if QQMusicAuth.shared.isLoggedIn {
                let ok = (try? await QQMusicAPI.shared.like(songmid: mid, liked: liked)) ?? false
                if !ok {
                    ATMusicLogger.shared.log("QQ 红心云端同步失败，已保留本地收藏：\(song.name) liked=\(liked)", level: .warn)
                }
            }
            return true
        case .kugou:
            let liked = !isLiked(song)
            updateKugou(song, liked: liked)
            return true
        case .local:
            return true
        case .synology:
            let liked = !isLiked(song)
            updateSynology(song, liked: liked)
            return true
        case .subsonic:
            let liked = !isLiked(song)
            updateSubsonic(song, liked: liked)
            return true
        case .jellyfin:
            let liked = !isLiked(song)
            updateJellyfin(song, liked: liked)
            return true
        case .webdav:
            let liked = !isLiked(song)
            updateWebdav(song, liked: liked)
            return true
        }
    }

    /// 移除 QQ 收藏（音乐库侧滑删除）
    func removeQQFavorite(_ song: Song) {
        updateQQ(song, liked: false)
    }

    /// 登录 QQ / 微信后从 QQ 音乐云端同步“我的喜欢”。
    /// 只有云端明确返回歌曲时才覆盖本地，避免接口空响应误清空收藏。
    @MainActor
    func syncQQFromCloud() async {
        guard QQMusicAuth.shared.isLoggedIn else { return }
        guard let songs = try? await QQMusicAPI.shared.favoriteSongs(), !songs.isEmpty else { return }
        qqFavoriteSongs = songs
        saveSongs(qqFavoriteSongs, key: qqKey)
    }

    /// 从网易云云端同步“我喜欢的音乐”
    @MainActor
    func syncNetEaseFromCloud() async {
        guard NetEaseAPI.shared.isLoggedIn, let uid = AuthStore.shared.user?.uid else { return }
        guard let playlists = try? await NetEaseAPI.shared.userPlaylists(uid: uid) else { return }
        guard let liked = playlists.first(where: { $0.specialType == 5 || $0.name == "我喜欢的音乐" || $0.name.contains("喜欢") }) else { return }
        guard let songs = try? await NetEaseAPI.shared.playlistTracks(id: liked.id), !songs.isEmpty else { return }
        neteaseFavoriteSongs = songs
        saveSongs(neteaseFavoriteSongs, key: neteaseKey)
    }

    /// 从酷狗音乐云端同步“我的喜欢 / 默认收藏”
    @MainActor
    func syncKugouFromCloud() async {
        guard KugouMusicAuth.shared.isLoggedIn else { return }
        guard let playlists = try? await KugouMusicAPI.shared.userPlaylists() else { return }
        guard let liked = playlists.first(where: {
            let name = $0.name.replacingOccurrences(of: " ", with: "")
            return name.contains("喜欢") || name.contains("收藏") || name.contains("红心")
        }) else { return }
        guard let songs = try? await KugouMusicAPI.shared.playlistSongs(listID: liked.id), !songs.isEmpty else { return }
        kugouFavoriteSongs = songs
        saveSongs(kugouFavoriteSongs, key: kugouKey)
    }

    /// 自动并发同步已登录各在线平台的红心收藏歌曲
    @MainActor
    func syncAllFromCloud() async {
        async let qq: () = syncQQFromCloud()
        async let netease: () = syncNetEaseFromCloud()
        async let kugou: () = syncKugouFromCloud()
        _ = await (qq, netease, kugou)
    }

    /// 聚合全平台与本地的所有红心收藏歌曲（严格聚合本地收藏歌单、一键同步歌单与多平台云端红心）
    @MainActor
    func unifiedFavoriteSongs() -> [Song] {
        var songs: [Song] = []
        var seen = Set<String>()
        // 1. 本地所有包含“喜欢”、“收藏”、“红心”的歌单（包括一键同步生成的三平台喜欢、网易云+QQ喜欢等）
        for localFav in LocalLibraryStore.shared.playlists where (localFav.name.contains("喜欢") || localFav.name.contains("收藏") || localFav.name.contains("红心")) {
            for song in localFav.songs where seen.insert(song.identityKey).inserted {
                songs.append(song)
            }
        }
        // 2. 网易云已同步红心
        for song in neteaseFavoriteSongs where seen.insert(song.identityKey).inserted {
            songs.append(song)
        }
        // 3. QQ 音乐已同步红心
        for song in qqFavoriteSongs where seen.insert(song.identityKey).inserted {
            songs.append(song)
        }
        // 4. 酷狗音乐已同步红心
        for song in kugouFavoriteSongs where seen.insert(song.identityKey).inserted {
            songs.append(song)
        }
        // 5. 群晖 NAS 收藏
        for song in synologyFavoriteSongs where seen.insert(song.identityKey).inserted {
            songs.append(song)
        }
        // 6. Subsonic 收藏
        for song in subsonicFavoriteSongs where seen.insert(song.identityKey).inserted {
            songs.append(song)
        }
        // 7. Jellyfin 收藏
        for song in jellyfinFavoriteSongs where seen.insert(song.identityKey).inserted {
            songs.append(song)
        }
        // 8. WebDAV 收藏
        for song in webdavFavoriteSongs where seen.insert(song.identityKey).inserted {
            songs.append(song)
        }
        return songs
    }

    private func updateNetease(_ song: Song, liked: Bool) {
        if liked {
            neteaseFavoriteSongs.removeAll { $0.id == song.id }
            neteaseFavoriteSongs.insert(song, at: 0)
        } else {
            neteaseFavoriteSongs.removeAll { $0.id == song.id }
        }
        saveSongs(neteaseFavoriteSongs, key: neteaseKey)
    }

    private func updateQQ(_ song: Song, liked: Bool) {
        if liked {
            qqFavoriteSongs.removeAll { existing in
                existing.identityKey == song.identityKey
                    || (existing.qqMid != nil && song.qqMid != nil && existing.qqMid == song.qqMid)
            }
            qqFavoriteSongs.insert(song, at: 0)
        } else {
            qqFavoriteSongs.removeAll { existing in
                existing.identityKey == song.identityKey
                    || (existing.qqMid != nil && song.qqMid != nil && existing.qqMid == song.qqMid)
            }
        }
        saveSongs(qqFavoriteSongs, key: qqKey)
    }

    private func updateKugou(_ song: Song, liked: Bool) {
        if liked {
            kugouFavoriteSongs.removeAll { $0.identityKey == song.identityKey }
            kugouFavoriteSongs.insert(song, at: 0)
        } else {
            kugouFavoriteSongs.removeAll { $0.identityKey == song.identityKey }
        }
        saveSongs(kugouFavoriteSongs, key: kugouKey)
    }

    private func updateSynology(_ song: Song, liked: Bool) {
        if liked {
            synologyFavoriteSongs.removeAll { $0.identityKey == song.identityKey }
            synologyFavoriteSongs.insert(song, at: 0)
        } else {
            synologyFavoriteSongs.removeAll { $0.identityKey == song.identityKey }
        }
        saveSongs(synologyFavoriteSongs, key: synologyKey)
    }

    private func updateSubsonic(_ song: Song, liked: Bool) {
        if liked {
            subsonicFavoriteSongs.removeAll { $0.identityKey == song.identityKey }
            subsonicFavoriteSongs.insert(song, at: 0)
        } else {
            subsonicFavoriteSongs.removeAll { $0.identityKey == song.identityKey }
        }
        saveSongs(subsonicFavoriteSongs, key: subsonicKey)
    }

    private func updateJellyfin(_ song: Song, liked: Bool) {
        if liked {
            jellyfinFavoriteSongs.removeAll { $0.identityKey == song.identityKey }
            jellyfinFavoriteSongs.insert(song, at: 0)
        } else {
            jellyfinFavoriteSongs.removeAll { $0.identityKey == song.identityKey }
        }
        saveSongs(jellyfinFavoriteSongs, key: jellyfinKey)
    }

    private func updateWebdav(_ song: Song, liked: Bool) {
        if liked {
            webdavFavoriteSongs.removeAll { $0.identityKey == song.identityKey }
            webdavFavoriteSongs.insert(song, at: 0)
        } else {
            webdavFavoriteSongs.removeAll { $0.identityKey == song.identityKey }
        }
        saveSongs(webdavFavoriteSongs, key: webdavKey)
    }

    private static func loadSongs(_ key: String) -> [Song] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode([Song].self, from: data) else { return [] }
        return saved
    }

    private func saveSongs(_ songs: [Song], key: String) {
        if let data = try? JSONEncoder().encode(songs) {
            defaults.set(data, forKey: key)
        }
    }

    /// 退出网易云登录时清空本地网易云收藏缓存（保留 QQ 收藏）
    func resetNetease() {
        neteaseFavoriteSongs = []
        defaults.removeObject(forKey: neteaseKey)
    }

    /// 跨设备云端同步：双向并集无损合并红心收藏
    func mergeRemoteFavorites(qq: [Song], netease: [Song], kugou: [Song], synology: [Song]) {
        func mergeList(local: [Song], remote: [Song]) -> [Song] {
            var map: [String: Song] = [:]
            var order: [String] = []
            for song in local {
                if map[song.identityKey] == nil {
                    map[song.identityKey] = song
                    order.append(song.identityKey)
                }
            }
            for song in remote {
                if map[song.identityKey] == nil {
                    map[song.identityKey] = song
                    order.append(song.identityKey)
                }
            }
            return order.compactMap { map[$0] }
        }
        qqFavoriteSongs = mergeList(local: qqFavoriteSongs, remote: qq)
        saveSongs(qqFavoriteSongs, key: qqKey)
        neteaseFavoriteSongs = mergeList(local: neteaseFavoriteSongs, remote: netease)
        saveSongs(neteaseFavoriteSongs, key: neteaseKey)
        kugouFavoriteSongs = mergeList(local: kugouFavoriteSongs, remote: kugou)
        saveSongs(kugouFavoriteSongs, key: kugouKey)
        synologyFavoriteSongs = mergeList(local: synologyFavoriteSongs, remote: synology)
        saveSongs(synologyFavoriteSongs, key: synologyKey)
    }
}
