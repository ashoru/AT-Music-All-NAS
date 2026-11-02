import Foundation
import UIKit

/// Jellyfin 媒体服务器 REST API 客户端。
/// 接口形状与 SubsonicAPI/SynologyAPI 保持一致（songURL/coverURL/lyrics/searchAllVariants/allPlaylists），
/// 方便核心播放链路对三个新 NAS 后端使用统一的调用方式。
final class JellyfinAPI: ObservableObject {
    static let shared = JellyfinAPI()

    @Published var isLoggedIn: Bool = false
    /// 服务器完整地址，形如 "https://jellyfin.example.com"（不含末尾斜杠）
    @Published var host: String = ""
    @Published var account: String = ""

    /// 登录后拿到的 AccessToken，用于后续请求头 "X-Emby-Token"
    private(set) var accessToken: String = ""
    /// 登录后拿到的 User.Id，浏览/搜索接口需要
    private(set) var userId: String = ""

    private let defaults = UserDefaults.standard
    private let hostKey = "atmusic.jellyfin.host"
    private let accountKey = "atmusic.jellyfin.account"
    private let userIdKey = "atmusic.jellyfin.userId"
    private let deviceIdKey = "atmusic.jellyfin.deviceId"
    private(set) var storedPassword: String = ""
    private let session = URLSession(configuration: .ephemeral)

    private init() {
        host = defaults.string(forKey: hostKey) ?? ""
        account = defaults.string(forKey: accountKey) ?? ""
        userId = defaults.string(forKey: userIdKey) ?? ""
        if !host.isEmpty, !account.isEmpty {
            storedPassword = SecureCredentialStore.shared.secret(for: passwordDestination) ?? ""
            accessToken = SecureCredentialStore.shared.secret(for: tokenDestination) ?? ""
            isLoggedIn = !accessToken.isEmpty
        }
    }

    var currentServerScope: String {
        "\(host)|\(account)"
    }

    private var passwordDestination: String { "jellyfin.password." + currentServerScope }
    private var tokenDestination: String { "jellyfin.token." + currentServerScope }

    private var deviceId: String {
        if let saved = defaults.string(forKey: deviceIdKey) { return saved }
        let generated = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        defaults.set(generated, forKey: deviceIdKey)
        return generated
    }

    private var authorizationHeaderValue: String {
        "MediaBrowser Client=\"ATMusic\", Device=\"iOS\", DeviceId=\"\(deviceId)\", Version=\"1.0.0\""
    }

    func isConfigured() -> Bool {
        !host.isEmpty && !account.isEmpty
    }

    /// 保存配置并通过 AuthenticateByName 接口登录。
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
        accessToken = ""
        _ = SecureCredentialStore.shared.deleteSecret(for: passwordDestination)
        _ = SecureCredentialStore.shared.deleteSecret(for: tokenDestination)
    }

    func login() async throws {
        guard !host.isEmpty, !account.isEmpty, !storedPassword.isEmpty else {
            throw JellyfinError.missingConfiguration("服务器地址/账号/密码未填写完整")
        }
        guard let url = URL(string: "\(host)/Users/AuthenticateByName") else {
            throw JellyfinError.missingConfiguration("服务器地址无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authorizationHeaderValue, forHTTPHeaderField: "X-Emby-Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["Username": account, "Pw": storedPassword])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw JellyfinError.network("无法连接到服务器")
        }
        guard http.statusCode == 200 else {
            isLoggedIn = false
            throw JellyfinError.server(code: http.statusCode, message: "用户名或密码错误")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["AccessToken"] as? String,
              let user = json["User"] as? [String: Any],
              let uid = user["Id"] as? String else {
            throw JellyfinError.network("服务器返回数据格式异常")
        }
        accessToken = token
        userId = uid
        defaults.set(uid, forKey: userIdKey)
        _ = SecureCredentialStore.shared.setSecret(token, for: tokenDestination)
        isLoggedIn = true
    }

    // MARK: - 通用请求

    private func authorizedRequest(path: String, method: String = "GET", queryItems: [URLQueryItem] = [], jsonBody: [String: Any]? = nil) throws -> URLRequest {
        guard var components = URLComponents(string: host + path) else {
            throw JellyfinError.missingConfiguration("服务器地址无效")
        }
        if !queryItems.isEmpty {
            components.queryItems = (components.queryItems ?? []) + queryItems
        }
        guard let url = components.url else {
            throw JellyfinError.missingConfiguration("服务器地址无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(accessToken, forHTTPHeaderField: "X-Emby-Token")
        request.setValue(authorizationHeaderValue, forHTTPHeaderField: "X-Emby-Authorization")
        if let jsonBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        }
        return request
    }

    private func getJSON(path: String, queryItems: [URLQueryItem] = []) async throws -> [String: Any] {
        guard isLoggedIn, !accessToken.isEmpty else { throw JellyfinError.missingConfiguration("尚未登录") }
        let request = try authorizedRequest(path: path, queryItems: queryItems)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw JellyfinError.server(code: code, message: "请求失败")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JellyfinError.network("服务器返回数据格式异常")
        }
        return json
    }

    @discardableResult
    private func send(path: String, method: String, queryItems: [URLQueryItem] = [], jsonBody: [String: Any]? = nil) async throws -> Data {
        guard isLoggedIn, !accessToken.isEmpty else { throw JellyfinError.missingConfiguration("尚未登录") }
        let request = try authorizedRequest(path: path, method: method, queryItems: queryItems, jsonBody: jsonBody)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw JellyfinError.server(code: code, message: "请求失败")
        }
        return data
    }

    // MARK: - 播放地址 / 封面 / 歌词

    func songURL(song: Song) -> String? {
        guard let itemId = song.jellyfinId, !itemId.isEmpty, !host.isEmpty, !accessToken.isEmpty else { return nil }
        var components = URLComponents(string: "\(host)/Audio/\(itemId)/stream")
        components?.queryItems = [
            URLQueryItem(name: "static", value: "true"),
            URLQueryItem(name: "api_key", value: accessToken)
        ]
        return components?.url?.absoluteString
    }

    func coverURL(for song: Song) -> URL? {
        guard let itemId = song.jellyfinId, !itemId.isEmpty, !host.isEmpty else { return nil }
        return URL(string: "\(host)/Items/\(itemId)/Images/Primary?api_key=\(accessToken)")
    }

    /// Jellyfin 10.9+ 支持 /Audio/{id}/Lyrics；旧版本服务器没有该能力时应返回 nil 而不是抛错。
    func lyrics(song: Song) async throws -> String? {
        guard let itemId = song.jellyfinId, !itemId.isEmpty else { return nil }
        guard let data = try? await send(path: "/Items/\(itemId)/Lyrics", method: "GET") else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lines = json["Lyrics"] as? [[String: Any]] else {
            return nil
        }
        var result = ""
        for line in lines {
            let text = line["Text"] as? String ?? ""
            if let ticks = line["Start"] as? Double {
                let totalSeconds = ticks / 10_000_000.0
                let minutes = Int(totalSeconds) / 60
                let seconds = totalSeconds.truncatingRemainder(dividingBy: 60)
                result += String(format: "[%02d:%05.2f]%@\n", minutes, seconds, text)
            } else {
                result += text + "\n"
            }
        }
        return result.isEmpty ? nil : result
    }

    // MARK: - 浏览 / 搜索

    private func mapArtist(_ item: [String: Any]) -> Artist? {
        guard let id = item["Id"] as? String else { return nil }
        let name = item["Name"] as? String ?? ""
        return Artist(id: id, name: name, coverURL: coverImageURL(itemId: id), source: .jellyfin)
    }

    private func mapAlbum(_ item: [String: Any]) -> Album? {
        guard let id = item["Id"] as? String else { return nil }
        let name = item["Name"] as? String ?? ""
        let artistName = (item["AlbumArtist"] as? String) ?? (item["Artists"] as? [String])?.first ?? ""
        return Album(id: id, name: name, artistName: artistName, coverURL: coverImageURL(itemId: id), source: .jellyfin, trackCount: item["ChildCount"] as? Int)
    }

    private func mapSong(_ item: [String: Any]) -> Song? {
        guard let id = item["Id"] as? String else { return nil }
        let name = item["Name"] as? String ?? ""
        let artists = (item["Artists"] as? [String])?.joined(separator: " / ") ?? (item["AlbumArtist"] as? String) ?? ""
        let album = item["Album"] as? String ?? ""
        let ticks = item["RunTimeTicks"] as? Double ?? 0
        let duration = ticks / 10_000_000.0
        let indexNumber = item["IndexNumber"] as? Int ?? 0
        let discNumber = item["ParentIndexNumber"] as? Int ?? 1
        let coverItemId = (item["AlbumId"] as? String) ?? id
        return Song(
            id: UnifiedSong.stableNumericHash(id),
            name: name,
            artists: artists,
            album: album,
            coverURL: coverImageURL(itemId: coverItemId),
            duration: duration,
            source: .jellyfin,
            jellyfinId: id,
            jellyfinServerScope: currentServerScope,
            discNumber: max(discNumber, 1),
            trackNumber: indexNumber
        )
    }

    private func coverImageURL(itemId: String) -> URL? {
        guard !host.isEmpty else { return nil }
        return URL(string: "\(host)/Items/\(itemId)/Images/Primary")
    }

    func fetchArtists() async throws -> [Artist] {
        let json = try await getJSON(path: "/Users/\(userId)/Items", queryItems: [
            URLQueryItem(name: "IncludeItemTypes", value: "MusicArtist"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: "SortName")
        ])
        let items = (json["Items"] as? [[String: Any]]) ?? []
        return items.compactMap(mapArtist)
    }

    func fetchAlbums(for artist: Artist?) async throws -> [Album] {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "IncludeItemTypes", value: "MusicAlbum"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: "SortName")
        ]
        if let artist {
            query.append(URLQueryItem(name: "ParentId", value: artist.id))
        }
        let json = try await getJSON(path: "/Users/\(userId)/Items", queryItems: query)
        let items = (json["Items"] as? [[String: Any]]) ?? []
        return items.compactMap(mapAlbum)
    }

    func fetchSongs(for album: Album) async throws -> [Song] {
        let json = try await getJSON(path: "/Users/\(userId)/Items", queryItems: [
            URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "ParentId", value: album.id),
            URLQueryItem(name: "SortBy", value: "IndexNumber")
        ])
        let items = (json["Items"] as? [[String: Any]]) ?? []
        return items.compactMap(mapSong)
    }

    func searchAllVariants(keyword: String, limit: Int) async throws -> NASSearchResult {
        let json = try await getJSON(path: "/Users/\(userId)/Items", queryItems: [
            URLQueryItem(name: "searchTerm", value: keyword),
            URLQueryItem(name: "IncludeItemTypes", value: "Audio,MusicAlbum,MusicArtist"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "Limit", value: "\(limit)")
        ])
        let items = (json["Items"] as? [[String: Any]]) ?? []
        var songs: [Song] = []
        var artists: [Artist] = []
        var albums: [Album] = []
        for item in items {
            switch item["Type"] as? String {
            case "Audio": if let s = mapSong(item) { songs.append(s) }
            case "MusicAlbum": if let a = mapAlbum(item) { albums.append(a) }
            case "MusicArtist": if let a = mapArtist(item) { artists.append(a) }
            default: break
            }
        }
        return NASSearchResult(songs: songs, artists: artists, albums: albums)
    }

    // MARK: - 歌单（Jellyfin 原生支持服务端播放列表 CRUD）

    func allPlaylists() async throws -> [Playlist] {
        let json = try await getJSON(path: "/Users/\(userId)/Items", queryItems: [
            URLQueryItem(name: "IncludeItemTypes", value: "Playlist"),
            URLQueryItem(name: "Recursive", value: "true")
        ])
        let items = (json["Items"] as? [[String: Any]]) ?? []
        return items.compactMap { item -> Playlist? in
            guard let id = item["Id"] as? String else { return nil }
            let name = item["Name"] as? String ?? ""
            return Playlist(id: UnifiedSong.stableNumericHash(id), name: name, coverURL: coverImageURL(itemId: id), trackCount: item["ChildCount"] as? Int ?? 0, source: .jellyfin, jellyfinPlaylistId: id)
        }
    }

    func playlistSongs(playlist: Playlist) async throws -> [Song] {
        guard let playlistId = playlist.jellyfinPlaylistId else { return [] }
        let json = try await getJSON(path: "/Playlists/\(playlistId)/Items", queryItems: [
            URLQueryItem(name: "UserId", value: userId)
        ])
        let items = (json["Items"] as? [[String: Any]]) ?? []
        return items.compactMap(mapSong)
    }

    @discardableResult
    func createPlaylist(name: String, songs: [Song]) async throws -> Playlist? {
        let ids = songs.compactMap { $0.jellyfinId }
        let data = try await send(path: "/Playlists", method: "POST", jsonBody: [
            "Name": name,
            "Ids": ids,
            "UserId": userId
        ])
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["Id"] as? String else {
            return nil
        }
        return Playlist(id: UnifiedSong.stableNumericHash(id), name: name, coverURL: nil, trackCount: songs.count, source: .jellyfin, jellyfinPlaylistId: id)
    }

    /// Jellyfin 的增量追加/删除接口需要先查 PlaylistItemId 才能精确删除，容易出错；
    /// 整体重建（删除旧的再按新顺序创建同名歌单）优先保证正确性而不是追求增量效率。
    @discardableResult
    func updatePlaylist(_ playlist: Playlist, songs: [Song]) async throws -> Bool {
        guard let playlistId = playlist.jellyfinPlaylistId else { return false }
        _ = try? await send(path: "/Items/\(playlistId)", method: "DELETE")
        let created = try await createPlaylist(name: playlist.name, songs: songs)
        return created != nil
    }

    @discardableResult
    func deletePlaylist(_ playlist: Playlist) async throws -> Bool {
        guard let playlistId = playlist.jellyfinPlaylistId else { return false }
        _ = try await send(path: "/Items/\(playlistId)", method: "DELETE")
        return true
    }
}

enum JellyfinError: LocalizedError {
    case notImplemented
    case missingConfiguration(String)
    case network(String)
    case server(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .notImplemented: return "Jellyfin 功能尚未实现"
        case .missingConfiguration(let msg): return msg
        case .network(let msg): return msg
        case .server(let code, let message): return "Jellyfin 服务器错误(\(code))：\(message)"
        }
    }
}
