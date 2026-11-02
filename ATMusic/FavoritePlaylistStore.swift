import SwiftUI

/// 在线歌单收藏管理（本地持久化，供音乐库“收藏歌单”板块单独展示）
@MainActor
final class FavoritePlaylistStore: ObservableObject {
    static let shared = FavoritePlaylistStore()

    @Published private(set) var playlists: [Playlist] = []

    private let key = "atmusic.favoritePlaylists.v1"
    private let defaults = UserDefaults.standard

    private init() {
        playlists = Self.load(key: key)
    }

    private static func load(key: String) -> [Playlist] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([Playlist].self, from: data) else {
            return []
        }
        return list
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(playlists) else { return }
        defaults.set(data, forKey: key)
    }

    func isFavorite(_ playlist: Playlist) -> Bool {
        playlists.contains { $0.identityKey == playlist.identityKey }
    }

    func toggle(_ playlist: Playlist) {
        if isFavorite(playlist) {
            remove(playlist)
            ToastCenter.shared.show("已取消收藏歌单")
            ATMusicHaptics.tap()
        } else {
            add(playlist)
            ToastCenter.shared.show("已收藏歌单")
            ATMusicHaptics.success()
        }
    }

    func add(_ playlist: Playlist) {
        guard !isFavorite(playlist) else { return }
        playlists.insert(playlist, at: 0)
        save()
    }

    func remove(_ playlist: Playlist) {
        playlists.removeAll { $0.identityKey == playlist.identityKey }
        save()
    }

    /// 跨设备云端同步：并集无损合并在线收藏歌单
    func mergeRemotePlaylists(_ remotePlaylists: [Playlist]) {
        var existingKeys = Set(playlists.map { $0.identityKey })
        var updated = playlists
        for p in remotePlaylists {
            if !existingKeys.contains(p.identityKey) {
                updated.append(p)
                existingKeys.insert(p.identityKey)
            }
        }
        playlists = updated
        save()
    }
}
