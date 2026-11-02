import Foundation

// MARK: - NAS 远程歌单写入（Audio Station Playlist）

enum SynologyPlaylistWriteError: LocalizedError {
    case unsupported(String)
    case verificationFailed(String)
    case missingPlaylistID
    case emptyName

    var errorDescription: String? {
        switch self {
        case .unsupported(let detail):
            return "当前 DSM 不适合在 App 内写歌单：\(detail)"
        case .verificationFailed(let detail):
            return "歌单写入未通过回读校验：\(detail)"
        case .missingPlaylistID:
            return "该歌单缺少 NAS 歌单标识，无法写入"
        case .emptyName:
            return "歌单名称不能为空"
        }
    }
}

/// 歌单写入能力缓存：不同 DSM 版本的 `updatesongs` 语义存在差异，
/// 与其让用户点一下就把歌单写坏，不如第一次写入前先做一次「新建临时歌单 → 写一首 → 回读校验 → 删除」的自检，
/// 结果按服务器作用域缓存整个会话。
enum SynologyPlaylistCapability {
    private static let lock = NSLock()
    private static var cache: [String: Bool] = [:]
    private static var detail: [String: String] = [:]

    static func support(for scope: String) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return cache[scope]
    }

    static func failureDetail(for scope: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return detail[scope]
    }

    static func mark(scope: String, supported: Bool, detail text: String = "") {
        lock.lock()
        cache[scope] = supported
        if supported { self.detail.removeValue(forKey: scope) } else { self.detail[scope] = text }
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        cache.removeAll()
        detail.removeAll()
        lock.unlock()
    }
}

extension SynologyAPI {

    // MARK: 能力自检

    /// 写歌单前的一次性自检；已确认过的服务器直接返回。
    func ensurePlaylistWriteSupport(sampleSong: Song) async throws {
        let scope = currentServerScope
        if SynologyPlaylistCapability.support(for: scope) == true { return }
        if SynologyPlaylistCapability.support(for: scope) == false {
            throw SynologyPlaylistWriteError.unsupported(
                SynologyPlaylistCapability.failureDetail(for: scope) ?? "该 DSM 拒绝了歌单写入接口"
            )
        }
        do {
            try await selfCheckPlaylistWrite(sampleSong: sampleSong)
            SynologyPlaylistCapability.mark(scope: scope, supported: true)
            ATMusicLogger.shared.log("✅ NAS 歌单写入自检通过（新建/写入/回读/删除全链路）", level: .info)
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            SynologyPlaylistCapability.mark(scope: scope, supported: false, detail: text)
            ATMusicLogger.shared.log("⚠️ NAS 歌单写入自检失败：\(text)", level: .warn)
            throw SynologyPlaylistWriteError.unsupported(text)
        }
    }

    /// 打开歌单编辑器时顺手探一次，失败也不抛（真正写入时会再校验并给明确提示）。
    func ensurePlaylistWriteSupportIfPossible(sampleSong: Song?) async {
        guard let sampleSong else { return }
        _ = try? await ensurePlaylistWriteSupport(sampleSong: sampleSong)
    }

    private func selfCheckPlaylistWrite(sampleSong: Song) async throws {
        let probeName = "ATMusic 写入自检（可删除）"
        guard let created = try await createNASPlaylist(name: probeName) else {
            throw SynologyPlaylistWriteError.verificationFailed("新建临时歌单失败")
        }
        let playlistID = created.synologyPlaylistId ?? "\(created.id)"
        defer {
            Task { try? await self.deleteNASPlaylist(id: playlistID) }
        }
        _ = try await playlistUpdateSongs(playlistID: playlistID, songs: [sampleSong], offset: 0, limit: 0)
        let after = try await playlistSongs(playlistId: playlistID, limit: 50)
        guard !after.isEmpty else {
            throw SynologyPlaylistWriteError.verificationFailed("写入后回读为空，说明该版本 updatesongs 语义不同")
        }
    }

    // MARK: 歌单增删改

    @discardableResult
    func createNASPlaylist(name: String) async throws -> Playlist? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SynologyPlaylistWriteError.emptyName }
        let json = try await postForm(
            "/webapi/AudioStation/playlist.cgi",
            form: [
                "api": "SYNO.AudioStation.Playlist",
                "version": "2",
                "method": "createlist",
                "name": trimmed,
                "library": "all"
            ],
            authenticated: true,
            acceptsMissingSuccess: true
        )
        let data = json["data"] as? [String: Any]
        // 有的 DSM 回 playlists 数组，有的直接回 id
        if let list = data?["playlists"] as? [[String: Any]], let first = list.first,
           let idStr = Self.playlistIDString(first) {
            return Playlist(id: Self.stableID(idStr), name: trimmed, coverURL: nil, trackCount: 0,
                            source: .synology, synologyPlaylistId: idStr)
        }
        if let idStr = data.flatMap({ Self.playlistIDString($0) }) {
            return Playlist(id: Self.stableID(idStr), name: trimmed, coverURL: nil, trackCount: 0,
                            source: .synology, synologyPlaylistId: idStr)
        }
        // 兜底：重新拉一次列表按名字找
        let all = (try? await allPlaylists()) ?? []
        return all.first { $0.name == trimmed }
    }

    func renameNASPlaylist(id: String, name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SynologyPlaylistWriteError.emptyName }
        guard !id.isEmpty else { throw SynologyPlaylistWriteError.missingPlaylistID }
        _ = try await postForm(
            "/webapi/AudioStation/playlist.cgi",
            form: [
                "api": "SYNO.AudioStation.Playlist",
                "version": "2",
                "method": "edit",
                "id": id,
                "name": trimmed,
                "library": "all"
            ],
            authenticated: true,
            acceptsMissingSuccess: true
        )
    }

    func deleteNASPlaylist(id: String) async throws {
        guard !id.isEmpty else { throw SynologyPlaylistWriteError.missingPlaylistID }
        _ = try await postForm(
            "/webapi/AudioStation/playlist.cgi",
            form: [
                "api": "SYNO.AudioStation.Playlist",
                "version": "2",
                "method": "delete",
                "id": id,
                "library": "all"
            ],
            authenticated: true,
            acceptsMissingSuccess: true
        )
    }

    // MARK: 曲目增删与重排（统一用「提交目标顺序」实现，最少语义假设）

    /// 整体写入目标曲目顺序，并回读校验；校验失败会尝试把原顺序写回去。
    func replaceNASPlaylistSongs(playlistID: String, with songs: [Song]) async throws {
        guard !playlistID.isEmpty else { throw SynologyPlaylistWriteError.missingPlaylistID }
        let previous = (try? await playlistSongs(playlistId: playlistID, limit: 500)) ?? []
        _ = try await playlistUpdateSongs(playlistID: playlistID, songs: songs, offset: 0, limit: previous.count)
        let after = try await playlistSongs(playlistId: playlistID, limit: 500)
        let expected = songs.map(Self.playlistSongKey)
        let actual = after.map(Self.playlistSongKey)
        guard actual == expected else {
            _ = try? await playlistUpdateSongs(playlistID: playlistID, songs: previous, offset: 0, limit: songs.count)
            throw SynologyPlaylistWriteError.verificationFailed(
                "期望 \(expected.count) 首、实际 \(actual.count) 首，已尝试恢复原顺序。"
                + "若反复出现，请用 DSM 网页端管理歌单（该版本 updatesongs 语义与通用实现不同）。"
            )
        }
    }

    func appendSongsToNASPlaylist(playlistID: String, songs: [Song]) async throws {
        guard !songs.isEmpty else { return }
        let current = try await playlistSongs(playlistId: playlistID, limit: 500)
        let merged = current + songs.filter { newSong in
            !current.contains { Self.playlistSongKey($0) == Self.playlistSongKey(newSong) }
        }
        try await replaceNASPlaylistSongs(playlistID: playlistID, with: merged)
    }

    func removeSongsFromNASPlaylist(playlistID: String, removing songs: Set<String>) async throws {
        guard !songs.isEmpty else { return }
        let current = try await playlistSongs(playlistId: playlistID, limit: 500)
        let kept = current.filter { !songs.contains(Self.playlistSongKey($0)) }
        try await replaceNASPlaylistSongs(playlistID: playlistID, with: kept)
    }

    /// 把 `tracks`（界面上的完整顺序）提交上去。
    func moveNASPlaylistSongs(playlistID: String, reordered tracks: [Song]) async throws {
        try await replaceNASPlaylistSongs(playlistID: playlistID, with: tracks)
    }

    // MARK: 工具

    func playlistUpdateSongs(playlistID: String, songs: [Song], offset: Int, limit: Int) async throws -> [String: Any] {
        let payload = songs.map { song -> [String: Any] in
            var item: [String: Any] = ["title": song.name]
            if let id = song.synologyId, !id.isEmpty { item["id"] = id }
            if let path = song.synologyPath, !path.isEmpty { item["path"] = path }
            return item
        }
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        let json = String(decoding: data, as: UTF8.self)
        return try await postForm(
            "/webapi/AudioStation/playlist.cgi",
            form: [
                "api": "SYNO.AudioStation.Playlist",
                "version": "2",
                "method": "updatesongs",
                "id": playlistID,
                "library": "all",
                "offset": "\(max(0, offset))",
                "limit": "\(max(0, limit))",
                "songs": json
            ],
            authenticated: true,
            acceptsMissingSuccess: true
        )
    }

    static func playlistSongKey(_ song: Song) -> String {
        if let id = song.synologyId, !id.isEmpty { return "id:\(id)" }
        if let path = song.synologyPath, !path.isEmpty { return "path:\(path)" }
        return "local:\(song.identityKey)"
    }

    private static func playlistIDString(_ dict: [String: Any]) -> String? {
        for key in ["id", "playlist_id", "playlistid"] {
            if let value = dict[key] as? String, !value.isEmpty { return value }
            if let value = dict[key] as? Int { return String(value) }
        }
        return nil
    }
}
