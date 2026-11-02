import Foundation

// MARK: - 歌单管理能力矩阵（阶段 0）
//
// 全 App 歌单管理操作的统一口径：管理中心长按菜单、详情页编辑态、
// 批量操作、加歌面板都按这张表生成，不再各处手写 if/else。
// QQ/酷狗因平台加歌/删歌/改名接口未封装，相关操作走「转存本地」兜底，
// 而不是在界面上放一个点了会失败的按钮。
struct PlaylistCapabilities {
    var canCreate = false
    var canRename = false
    var canDelete = false
    var canAddSongs = false
    var canRemoveSongs = false
    /// 服务端是否支持曲目重排；不支持时用本地顺序偏好（只影响本机播放顺序，不动云端）
    var canReorderOnServer = false
    var canEditCover = false
    var canEditDescription = false

    static func forSource(_ source: SongSource) -> PlaylistCapabilities {
        switch source {
        case .netease:
            return PlaylistCapabilities(
                canCreate: true, canRename: true, canDelete: true,
                canAddSongs: true, canRemoveSongs: true, canReorderOnServer: false,
                canEditCover: false, canEditDescription: true
            )
        case .qq:
            return PlaylistCapabilities(
                canCreate: true, canRename: false, canDelete: true,
                canAddSongs: false, canRemoveSongs: false, canReorderOnServer: false,
                canEditCover: false, canEditDescription: false
            )
        case .kugou:
            return PlaylistCapabilities()
        case .synology:
            return PlaylistCapabilities(
                canCreate: true, canRename: true, canDelete: true,
                canAddSongs: true, canRemoveSongs: true, canReorderOnServer: true,
                canEditCover: false, canEditDescription: false
            )
        case .subsonic, .jellyfin, .webdav:
            // 新 NAS 后端不走通用编辑路由：该路由的 .nas 目标只懂群晖歌单 ID，
            // 误走会把新后端歌单当群晖歌单写。歌单删除走音乐库直接调用各后端
            // deletePlaylist；歌单内删曲走各后端自己的浏览页 updatePlaylist。
            return PlaylistCapabilities()
        case .local:
            return PlaylistCapabilities(
                canCreate: true, canRename: true, canDelete: true,
                canAddSongs: true, canRemoveSongs: true, canReorderOnServer: true,
                canEditCover: true, canEditDescription: true
            )
        }
    }
}

/// 可加歌也可删歌的编辑目标（本地 / 网易 / NAS）。
/// QQ、酷狗不在此列：平台接口未封装，统一走转存本地。
enum PlaylistEditTarget {
    case local(UUID)
    case netease(Playlist)
    case nas(Playlist)

    var title: String {
        switch self {
        case .local(let id):
            return LocalLibraryStore.shared.playlists.first { $0.id == id }?.name ?? "本地歌单"
        case .netease(let playlist), .nas(let playlist):
            return playlist.name
        }
    }

    var source: SongSource {
        switch self {
        case .local: return .local
        case .netease: return .netease
        case .nas: return .synology
        }
    }
}

// MARK: - 歌单内自定义曲目顺序（本地偏好）
//
// 网易/QQ/酷狗没有可验证的服务端曲目重排接口：用户在编辑态里拖出的顺序
// 只存在本机，播放与展示按它来，云端顺序原样不动。本地/NAS 不走这里，
// 它们直接改真实顺序。
final class PlaylistSongOrderStore {
    static let shared = PlaylistSongOrderStore()

    private let defaults = UserDefaults.standard
    private let key = "atmusic.playlistSongOrder.v1"
    private var orders: [String: [String]]

    private init() {
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode([String: [String]].self, from: data) {
            orders = saved
        } else {
            orders = [:]
        }
    }

    func saveOrder(_ songs: [Song], for playlistKey: String) {
        orders[playlistKey] = songs.map(\.identityKey)
        persist()
    }

    func clearOrder(for playlistKey: String) {
        orders.removeValue(forKey: playlistKey)
        persist()
    }

    /// 按保存的顺序重排；保存里没有的曲目按原顺序缀在后面，删掉的曲目自动丢弃。
    func apply(to songs: [Song], playlistKey: String) -> [Song] {
        guard let saved = orders[playlistKey], !saved.isEmpty else { return songs }
        let rank = Dictionary(uniqueKeysWithValues: saved.enumerated().map { ($0.element, $0.offset) })
        return songs.enumerated().sorted { a, b in
            let ra = rank[a.element.identityKey]
            let rb = rank[b.element.identityKey]
            switch (ra, rb) {
            case (nil, nil): return a.offset < b.offset
            case (nil, _): return false
            case (_, nil): return true
            case let (x?, y?): return x < y
            }
        }.map(\.element)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(orders) {
            defaults.set(data, forKey: key)
        }
    }
}

// MARK: - 歌单内排序偏好（按歌单记忆）

final class PlaylistSortPreferenceStore {
    static let shared = PlaylistSortPreferenceStore()

    private let defaults = UserDefaults.standard
    private let key = "atmusic.playlistSortPreference.v1"
    private var prefs: [String: String]

    private init() {
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            prefs = saved
        } else {
            prefs = [:]
        }
    }

    func sortModeRaw(for playlistKey: String) -> String? {
        prefs[playlistKey]
    }

    func save(sortModeRaw: String, for playlistKey: String) {
        prefs[playlistKey] = sortModeRaw
        if let data = try? JSONEncoder().encode(prefs) {
            defaults.set(data, forKey: key)
        }
    }
}

// MARK: - 跨来源歌单操作服务

enum PlaylistManagementError: LocalizedError {
    case operationFailed(String)
    case emptyPlaylist
    case unsupportedSource(String)

    var errorDescription: String? {
        switch self {
        case .operationFailed(let detail): return detail
        case .emptyPlaylist: return "歌单是空的"
        case .unsupportedSource(let detail): return detail
        }
    }
}

@MainActor
final class PlaylistManagementService {
    static let shared = PlaylistManagementService()

    private init() {}

    // MARK: - 账号与缓存失效

    static func cacheAccountID(for source: SongSource) -> String {
        switch source {
        case .netease:
            return "\(AuthStore.shared.user?.uid ?? 0)"
        case .qq:
            let auth = QQMusicAuth.shared
            return auth.rawUin.isEmpty ? auth.playlistUin : auth.rawUin
        case .kugou:
            return KugouMusicAuth.shared.userId
        case .local:
            return "local"
        case .synology:
            return SynologyAPI.shared.account
        case .subsonic:
            return SubsonicAPI.shared.account
        case .jellyfin:
            return JellyfinAPI.shared.account
        case .webdav:
            return WebDAVAPI.shared.account
        }
    }

    static func invalidateSongsCache(for playlist: Playlist) {
        SyncedPlaylistCache.shared.invalidateSongs(
            playlist: playlist, accountID: cacheAccountID(for: playlist.source)
        )
    }

    static func invalidateListCache(for source: SongSource) {
        SyncedPlaylistCache.shared.invalidateList(
            source: source, accountID: cacheAccountID(for: source)
        )
    }

    // MARK: - 读歌单歌曲（供合并/导出复用）

    func loadSongs(for playlist: Playlist) async -> [Song] {
        switch playlist.source {
        case .netease:
            return (try? await NetEaseAPI.shared.playlistTracks(id: playlist.id)) ?? []
        case .qq:
            return (try? await QQMusicAPI.shared.playlistSongs(listID: playlist.id)) ?? []
        case .kugou:
            return (try? await KugouMusicAPI.shared.playlistSongs(listID: playlist.id)) ?? []
        case .synology:
            return (try? await SynologyAPI.shared.playlistSongs(
                playlistId: playlist.synologyPlaylistId ?? "\(playlist.id)")) ?? []
        case .subsonic:
            return (try? await SubsonicAPI.shared.playlistSongs(playlist: playlist)) ?? []
        case .jellyfin:
            return (try? await JellyfinAPI.shared.playlistSongs(playlist: playlist)) ?? []
        case .webdav:
            return (try? await WebDAVAPI.shared.playlistSongs(playlist: playlist)) ?? []
        case .local:
            return []
        }
    }

    // MARK: - 加歌 / 删歌 / 移歌

    /// 返回实际新增数（网易/NAS 服务端可能去重，返回值为请求数，仅作提示用）。
    @discardableResult
    func addSongs(_ songs: [Song], to target: PlaylistEditTarget) async throws -> Int {
        switch target {
        case .local(let id):
            return LocalLibraryStore.shared.addSongs(songs, to: id)
        case .netease(let playlist):
            let ids = songs.map(\.id).filter { $0 != 0 }
            guard !ids.isEmpty else { return 0 }
            let ok = try await NetEaseAPI.shared.addToPlaylist(playlistID: playlist.id, songIDs: ids)
            guard ok else { throw PlaylistManagementError.operationFailed("加入网易歌单失败") }
            Self.invalidateSongsCache(for: playlist)
            return ids.count
        case .nas(let playlist):
            let pid = playlist.synologyPlaylistId ?? "\(playlist.id)"
            try await SynologyAPI.shared.appendSongsToNASPlaylist(playlistID: pid, songs: songs)
            Self.invalidateSongsCache(for: playlist)
            return songs.count
        }
    }

    @discardableResult
    func removeSongs(_ songs: [Song], from source: PlaylistEditTarget) async throws -> Int {
        switch source {
        case .local(let id):
            let before = LocalLibraryStore.shared.playlists.first { $0.id == id }?.songs.count ?? 0
            for song in songs {
                LocalLibraryStore.shared.removeSong(playlistID: id, song: song)
            }
            let after = LocalLibraryStore.shared.playlists.first { $0.id == id }?.songs.count ?? before
            return before - after
        case .netease(let playlist):
            let ids = songs.map(\.id).filter { $0 != 0 }
            guard !ids.isEmpty else { return 0 }
            let ok = try await NetEaseAPI.shared.removeFromPlaylist(playlistID: playlist.id, songIDs: ids)
            guard ok else { throw PlaylistManagementError.operationFailed("从网易歌单移除失败") }
            Self.invalidateSongsCache(for: playlist)
            return ids.count
        case .nas(let playlist):
            let pid = playlist.synologyPlaylistId ?? "\(playlist.id)"
            let keys = Set(songs.map { SynologyAPI.playlistSongKey($0) })
            try await SynologyAPI.shared.removeSongsFromNASPlaylist(playlistID: pid, removing: keys)
            Self.invalidateSongsCache(for: playlist)
            return songs.count
        }
    }

    /// 先加后删：目标加入成功才动来源，避免歌丢了。
    @discardableResult
    func moveSongs(_ songs: [Song], from source: PlaylistEditTarget, to target: PlaylistEditTarget) async throws -> Int {
        let added = try await addSongs(songs, to: target)
        _ = try await removeSongs(songs, from: source)
        return added
    }

    /// 转存：把任意来源的歌曲复制成一个本地歌单（QQ/酷狗的编辑兜底就靠它）。
    func copyToLocal(songs: [Song], named name: String) -> LocalPlaylist {
        let playlist = LocalLibraryStore.shared.createPlaylist(name: name)
        _ = LocalLibraryStore.shared.addSongs(songs, to: playlist.id)
        return playlist
    }

    // MARK: - 去重

    func deduplicateLocalPlaylist(id: UUID) -> Int {
        LocalLibraryStore.shared.deduplicatePlaylist(id: id)
    }

    func deduplicateNetEasePlaylist(_ playlist: Playlist) async throws -> Int {
        let songs = await loadSongs(for: playlist)
        var seen = Set<Int>()
        var duplicateIDs: [Int] = []
        for song in songs where song.id != 0 {
            if !seen.insert(song.id).inserted {
                duplicateIDs.append(song.id)
            }
        }
        guard !duplicateIDs.isEmpty else { return 0 }
        let ok = try await NetEaseAPI.shared.removeFromPlaylist(playlistID: playlist.id, songIDs: duplicateIDs)
        guard ok else { throw PlaylistManagementError.operationFailed("网易歌单去重失败") }
        Self.invalidateSongsCache(for: playlist)
        return duplicateIDs.count
    }

    func deduplicateNASPlaylist(_ playlist: Playlist) async throws -> Int {
        let pid = playlist.synologyPlaylistId ?? "\(playlist.id)"
        let songs = try await SynologyAPI.shared.playlistSongs(playlistId: pid)
        var seen = Set<String>()
        var unique: [Song] = []
        for song in songs where seen.insert(SynologyAPI.playlistSongKey(song)).inserted {
            unique.append(song)
        }
        guard unique.count != songs.count else { return 0 }
        try await SynologyAPI.shared.replaceNASPlaylistSongs(playlistID: pid, with: unique)
        Self.invalidateSongsCache(for: playlist)
        return songs.count - unique.count
    }

    // MARK: - 导出到 NAS

    func exportToNAS(name: String, songs: [Song]) async throws -> Playlist? {
        guard let sample = songs.first else { throw PlaylistManagementError.emptyPlaylist }
        try await SynologyAPI.shared.ensurePlaylistWriteSupport(sampleSong: sample)
        guard let created = try await SynologyAPI.shared.createNASPlaylist(name: name) else {
            throw PlaylistManagementError.operationFailed("在 NAS 上创建歌单失败")
        }
        let pid = created.synologyPlaylistId ?? "\(created.id)"
        try await SynologyAPI.shared.appendSongsToNASPlaylist(playlistID: pid, songs: songs)
        Self.invalidateListCache(for: .synology)
        return created
    }
}
