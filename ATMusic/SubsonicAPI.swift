import Foundation
import CryptoKit

/// Subsonic / OpenSubsonic REST API 客户端（兼容 Navidrome、Airsonic、Gonic、Ampache 等自建音乐服务器）。
/// 接口形状刻意与 SynologyAPI 对齐（songURL/coverURL/lyrics/searchAllVariants/allPlaylists 等同名方法），
/// 方便上层（PlayerManager/FavoritesStore/SongLyricsLoader/AggregatedSearchService/DownloadManager）
/// 用完全一致的调用方式接入三个新后端，减少重复判断逻辑。
final class SubsonicAPI: ObservableObject {
    static let shared = SubsonicAPI()

    @Published var isLoggedIn: Bool = false
    /// 服务器完整地址，形如 "https://navidrome.example.com"（不含末尾斜杠）
    @Published var host: String = ""
    @Published var account: String = ""

    private let defaults = UserDefaults.standard
    private let hostKey = "atmusic.subsonic.host"
    private let accountKey = "atmusic.subsonic.account"
    private(set) var storedPassword: String = ""

    private let apiVersion = "1.16.1"
    private let clientName = "ATMusic"
    private let session: URLSession

    private init() {
        host = defaults.string(forKey: hostKey) ?? ""
        account = defaults.string(forKey: accountKey) ?? ""
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
        if !host.isEmpty, !account.isEmpty {
            storedPassword = SecureCredentialStore.shared.secret(for: passwordDestination) ?? ""
            isLoggedIn = !storedPassword.isEmpty
        }
    }

    /// host+account 共同确定的作用域；用于 Song/Playlist 的 identityKey 去重与多服务器隔离。
    var currentServerScope: String {
        "\(host)|\(account)"
    }

    private var passwordDestination: String { "subsonic.password." + currentServerScope }

    func isConfigured() -> Bool {
        !host.isEmpty && !account.isEmpty
    }

    /// 保存配置并尝试登录校验（ping.view）。
    func configure(host: String, account: String, password: String) async throws {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedHost = trimmedHost.hasSuffix("/") ? String(trimmedHost.dropLast()) : trimmedHost
        self.host = normalizedHost
        self.account = account
        self.storedPassword = password
        defaults.set(normalizedHost, forKey: hostKey)
        defaults.set(account, forKey: accountKey)
        _ = SecureCredentialStore.shared.setSecret(password, for: passwordDestination)
        try await login()
    }

    func logout() {
        isLoggedIn = false
        _ = SecureCredentialStore.shared.deleteSecret(for: passwordDestination)
    }

    /// 校验凭据是否可用（调用 ping.view）。失败则抛出错误，不修改 isLoggedIn。
    func login() async throws {
        _ = try await get("ping.view")
        await MainActor.run { self.isLoggedIn = true }
    }

    // MARK: - 鉴权与请求构造

    private func randomSalt() -> String {
        let chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<12).compactMap { _ in chars.randomElement() })
    }

    private func token(forSalt salt: String) -> String {
        let digest = Insecure.MD5.hash(data: Data((storedPassword + salt).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func authQueryItems() -> [URLQueryItem] {
        let salt = randomSalt()
        return [
            URLQueryItem(name: "u", value: account),
            URLQueryItem(name: "t", value: token(forSalt: salt)),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "c", value: clientName),
            URLQueryItem(name: "f", value: "json")
        ]
    }

    /// 同步构造任意 Subsonic REST 直链（供 stream/getCoverArt 这类不需要解析 JSON 响应的场景使用）。
    private func buildDirectURL(_ endpoint: String, extra: [URLQueryItem] = []) -> URL? {
        guard isConfigured(), !storedPassword.isEmpty else { return nil }
        guard var comps = URLComponents(string: host + "/rest/" + endpoint) else { return nil }
        comps.queryItems = authQueryItems() + extra
        return comps.url
    }

    /// 拆开 `{"subsonic-response": {...}}` 外层包裹，并检查 status 字段。
    @discardableResult
    private func get(_ endpoint: String, extra: [URLQueryItem] = []) async throws -> [String: Any] {
        guard isConfigured(), !storedPassword.isEmpty else {
            throw SubsonicError.missingConfiguration("未配置 Subsonic 服务器地址或密码")
        }
        guard let url = buildDirectURL(endpoint, extra: extra) else {
            throw SubsonicError.network("无效的服务器地址")
        }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SubsonicError.network("HTTP 请求失败")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let root = json["subsonic-response"] as? [String: Any] else {
            throw SubsonicError.network("响应格式不正确")
        }
        let status = root["status"] as? String ?? "failed"
        guard status == "ok" else {
            let err = root["error"] as? [String: Any]
            let code = err?["code"] as? Int ?? -1
            let message = err?["message"] as? String ?? "未知错误"
            throw SubsonicError.server(code: code, message: message)
        }
        return root
    }

    /// Subsonic/OpenSubsonic 的经典 JSON 怪癖：只有一个子元素时，数组字段会被序列化成裸对象而不是单元素数组。
    private func arrayOrSingle(_ value: Any?) -> [[String: Any]] {
        if let arr = value as? [[String: Any]] { return arr }
        if let single = value as? [String: Any] { return [single] }
        return []
    }

    // MARK: - 播放地址 / 封面 / 歌词

    /// 同步构造流媒体直链（token 鉴权参数可提前算好，无需网络往返），镜像 SynologyAPI.songURL 的调用方式。
    func songURL(song: Song) -> String? {
        guard let subsonicId = song.subsonicId, !subsonicId.isEmpty else { return nil }
        return buildDirectURL("stream.view", extra: [
            URLQueryItem(name: "id", value: subsonicId),
            URLQueryItem(name: "format", value: "raw")
        ])?.absoluteString
    }

    func coverURL(for song: Song) -> URL? {
        guard let subsonicId = song.subsonicId, !subsonicId.isEmpty else { return nil }
        return buildDirectURL("getCoverArt.view", extra: [URLQueryItem(name: "id", value: subsonicId)])
    }

    private func coverArtURL(coverArtId: String?) -> URL? {
        guard let coverArtId, !coverArtId.isEmpty else { return nil }
        return buildDirectURL("getCoverArt.view", extra: [URLQueryItem(name: "id", value: coverArtId)])
    }

    /// 歌词：优先尝试 OpenSubsonic 扩展 getLyricsBySongId，失败/为空再退回旧版 getLyrics(按歌手+标题)。
    func lyrics(song: Song) async throws -> String? {
        guard let subsonicId = song.subsonicId, !subsonicId.isEmpty else { return nil }
        if let root = try? await get("getLyricsBySongId.view", extra: [URLQueryItem(name: "id", value: subsonicId)]),
           let lyricsList = root["lyricsList"] as? [String: Any] {
            let structured = arrayOrSingle(lyricsList["structuredLyrics"])
            if let first = structured.first {
                let lines = arrayOrSingle(first["line"])
                let synced = first["synced"] as? Bool ?? false
                let text = lines.compactMap { line -> String? in
                    guard let value = line["value"] as? String else { return nil }
                    if synced, let startMs = line["start"] as? Int {
                        let totalSeconds = Double(startMs) / 1000.0
                        let minutes = Int(totalSeconds) / 60
                        let seconds = totalSeconds.truncatingRemainder(dividingBy: 60)
                        return String(format: "[%02d:%05.2f]%@", minutes, seconds, value)
                    }
                    return value
                }.joined(separator: "\n")
                if !text.isEmpty { return text }
            }
        }
        if let root = try? await get("getLyrics.view", extra: [
            URLQueryItem(name: "artist", value: song.artists),
            URLQueryItem(name: "title", value: song.name)
        ]), let lyricsObj = root["lyrics"] as? [String: Any], let value = lyricsObj["value"] as? String, !value.isEmpty {
            return value
        }
        return nil
    }

    // MARK: - 浏览 / 搜索

    private func makeSong(from dict: [String: Any], albumNameFallback: String? = nil) -> Song? {
        guard let subsonicId = dict["id"] as? String, !subsonicId.isEmpty else { return nil }
        let title = dict["title"] as? String ?? ""
        let artist = dict["artist"] as? String ?? ""
        let album = dict["album"] as? String ?? albumNameFallback ?? ""
        let duration = (dict["duration"] as? NSNumber)?.doubleValue ?? 0
        let track = dict["track"] as? Int ?? 0
        let disc = dict["discNumber"] as? Int ?? 1
        let year = (dict["year"] as? NSNumber).map { String($0.intValue) }
        let genre = dict["genre"] as? String
        let coverArt = dict["coverArt"] as? String
        return Song(
            id: UnifiedSong.stableNumericHash("subsonic:\(subsonicId)"),
            name: title,
            artists: artist,
            album: album,
            coverURL: coverArtURL(coverArtId: coverArt),
            duration: duration,
            source: .subsonic,
            subsonicId: subsonicId,
            subsonicServerScope: currentServerScope,
            genre: genre,
            year: year,
            discNumber: disc,
            trackNumber: track
        )
    }

    private func makeArtist(from dict: [String: Any]) -> Artist? {
        guard let id = dict["id"] as? String else { return nil }
        let name = dict["name"] as? String ?? ""
        let coverArt = dict["coverArt"] as? String
        return Artist(id: id, name: name, coverURL: coverArtURL(coverArtId: coverArt), source: .subsonic)
    }

    private func makeAlbum(from dict: [String: Any]) -> Album? {
        guard let id = dict["id"] as? String else { return nil }
        let name = dict["name"] as? String ?? dict["album"] as? String ?? ""
        let artistName = dict["artist"] as? String ?? ""
        let coverArt = dict["coverArt"] as? String
        let songCount = dict["songCount"] as? Int
        return Album(id: id, name: name, artistName: artistName, coverURL: coverArtURL(coverArtId: coverArt), source: .subsonic, trackCount: songCount)
    }

    func fetchArtists() async throws -> [Artist] {
        let root = try await get("getArtists.view")
        guard let artistsObj = root["artists"] as? [String: Any] else { return [] }
        let index = arrayOrSingle(artistsObj["index"])
        var result: [Artist] = []
        for group in index {
            let entries = arrayOrSingle(group["artist"])
            result.append(contentsOf: entries.compactMap { makeArtist(from: $0) })
        }
        return result
    }

    func fetchAlbums(for artist: Artist?) async throws -> [Album] {
        guard let artist, !artist.id.isEmpty else { return [] }
        let root = try await get("getArtist.view", extra: [URLQueryItem(name: "id", value: artist.id)])
        guard let artistObj = root["artist"] as? [String: Any] else { return [] }
        let albums = arrayOrSingle(artistObj["album"])
        return albums.compactMap { makeAlbum(from: $0) }
    }

    func fetchSongs(for album: Album) async throws -> [Song] {
        let root = try await get("getAlbum.view", extra: [URLQueryItem(name: "id", value: album.id)])
        guard let albumObj = root["album"] as? [String: Any] else { return [] }
        let songs = arrayOrSingle(albumObj["song"])
        return songs.compactMap { makeSong(from: $0, albumNameFallback: album.name) }
    }

    func searchAllVariants(keyword: String, limit: Int) async throws -> NASSearchResult {
        guard !keyword.isEmpty else { return NASSearchResult(songs: [], artists: [], albums: []) }
        let count = max(1, min(limit, 200))
        let root = try await get("search3.view", extra: [
            URLQueryItem(name: "query", value: keyword),
            URLQueryItem(name: "songCount", value: "\(count)"),
            URLQueryItem(name: "artistCount", value: "\(count)"),
            URLQueryItem(name: "albumCount", value: "\(count)")
        ])
        guard let result = root["searchResult3"] as? [String: Any] else {
            return NASSearchResult(songs: [], artists: [], albums: [])
        }
        let songs = arrayOrSingle(result["song"]).compactMap { makeSong(from: $0) }
        let artists = arrayOrSingle(result["artist"]).compactMap { makeArtist(from: $0) }
        let albums = arrayOrSingle(result["album"]).compactMap { makeAlbum(from: $0) }
        return NASSearchResult(songs: songs, artists: artists, albums: albums)
    }

    // MARK: - 歌单（Subsonic 原生支持服务端播放列表 CRUD）

    private func makePlaylist(from dict: [String: Any]) -> Playlist? {
        guard let id = dict["id"] as? String else { return nil }
        let name = dict["name"] as? String ?? ""
        let coverArt = dict["coverArt"] as? String
        let songCount = dict["songCount"] as? Int ?? 0
        return Playlist(
            id: UnifiedSong.stableNumericHash("subsonic-playlist:\(id)"),
            name: name,
            coverURL: coverArtURL(coverArtId: coverArt),
            trackCount: songCount,
            source: .subsonic,
            subsonicPlaylistId: id
        )
    }

    func allPlaylists() async throws -> [Playlist] {
        let root = try await get("getPlaylists.view")
        guard let obj = root["playlists"] as? [String: Any] else { return [] }
        let list = arrayOrSingle(obj["playlist"])
        return list.compactMap { makePlaylist(from: $0) }
    }

    func playlistSongs(playlist: Playlist) async throws -> [Song] {
        guard let id = playlist.subsonicPlaylistId else { return [] }
        let root = try await get("getPlaylist.view", extra: [URLQueryItem(name: "id", value: id)])
        guard let obj = root["playlist"] as? [String: Any] else { return [] }
        let entries = arrayOrSingle(obj["entry"])
        return entries.compactMap { makeSong(from: $0) }
    }

    @discardableResult
    func createPlaylist(name: String, songs: [Song]) async throws -> Playlist? {
        let songIds = songs.compactMap { $0.subsonicId }
        var extra = [URLQueryItem(name: "name", value: name)]
        extra.append(contentsOf: songIds.map { URLQueryItem(name: "songId", value: $0) })
        let root = try await get("createPlaylist.view", extra: extra)
        guard let obj = root["playlist"] as? [String: Any] else { return nil }
        return makePlaylist(from: obj)
    }

    /// Subsonic 的 updatePlaylist 是"删除指定下标/新增指定id"的增量式接口，语义在各实现上不完全一致。
    /// 为了不冒出错风险，这里采用整体重建：删除旧歌单再用同名创建新的，牺牲原歌单的隐藏元数据换取正确性。
    @discardableResult
    func updatePlaylist(_ playlist: Playlist, songs: [Song]) async throws -> Bool {
        guard let id = playlist.subsonicPlaylistId else { return false }
        _ = try? await get("deletePlaylist.view", extra: [URLQueryItem(name: "id", value: id)])
        let created = try await createPlaylist(name: playlist.name, songs: songs)
        return created != nil
    }

    @discardableResult
    func deletePlaylist(_ playlist: Playlist) async throws -> Bool {
        guard let id = playlist.subsonicPlaylistId else { return false }
        _ = try await get("deletePlaylist.view", extra: [URLQueryItem(name: "id", value: id)])
        return true
    }
}

enum SubsonicError: LocalizedError {
    case notImplemented
    case missingConfiguration(String)
    case network(String)
    case server(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .notImplemented: return "Subsonic 功能尚未实现"
        case .missingConfiguration(let msg): return msg
        case .network(let msg): return msg
        case .server(let code, let message): return "Subsonic 服务器错误(\(code))：\(message)"
        }
    }
}
