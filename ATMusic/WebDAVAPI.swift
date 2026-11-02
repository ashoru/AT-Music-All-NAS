import Foundation

/// WebDAV 目录项（文件或子目录），解析自 PROPFIND 响应。
private struct WebDAVItem {
    let path: String   // 解码后的完整路径（相对服务器根，以 "/" 开头）
    let isCollection: Bool
    let contentLength: Int64
}

/// 扫描到的一首音频文件，承载构建 Song 所需的最小信息。
private struct WebDAVScannedSong {
    let path: String
    let fileName: String   // 不含扩展名
    let folderName: String // 所在目录名（启发式专辑名）
    let grandParentFolderName: String // 上上级目录名（启发式艺术家名）
}

/// 轻量 WebDAV PROPFIND XML 响应解析器。只识别 DAV 命名空间下的
/// href / resourcetype(collection) / getcontentlength 几个标签，足够列目录用，不追求完整 DAV 规范覆盖。
private final class WebDAVPropfindParser: NSObject, XMLParserDelegate {
    private(set) var items: [WebDAVItem] = []

    private var currentElementStack: [String] = []
    private var currentHref: String?
    private var currentIsCollection = false
    private var currentContentLength: Int64 = 0
    private var textBuffer = ""

    private func localName(_ qName: String?, _ elementName: String) -> String {
        let name = qName ?? elementName
        if let range = name.range(of: ":") {
            return String(name[range.upperBound...])
        }
        return name
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = localName(qName, elementName).lowercased()
        currentElementStack.append(local)
        textBuffer = ""
        if local == "response" {
            currentHref = nil
            currentIsCollection = false
            currentContentLength = 0
        } else if local == "collection" {
            currentIsCollection = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBuffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = localName(qName, elementName).lowercased()
        if local == "href" {
            currentHref = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if local == "getcontentlength" {
            currentContentLength = Int64(textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        } else if local == "response" {
            if let href = currentHref, let decoded = href.removingPercentEncoding {
                items.append(WebDAVItem(path: decoded, isCollection: currentIsCollection, contentLength: currentContentLength))
            }
        }
        if !currentElementStack.isEmpty { currentElementStack.removeLast() }
        textBuffer = ""
    }
}

/// 通用 WebDAV 音乐源客户端。几乎所有 NAS（群晖/威联通/铁威马等）都原生支持 WebDAV，
/// 但协议本身只有文件语义，没有专辑/艺术家/歌单等音乐元数据概念——这些需要客户端自己
/// 扫描目录树 + 用目录结构启发式模拟。歌单用 .m3u 文件承载（整篇覆盖写入，不做增量补丁）。
/// 接口形状与 SubsonicAPI/JellyfinAPI/SynologyAPI 保持一致，方便核心播放链路统一调用。
final class WebDAVAPI: ObservableObject {
    static let shared = WebDAVAPI()

    @Published var isLoggedIn: Bool = false
    /// 服务器完整地址，形如 "https://nas.example.com:5006/webdav"（不含末尾斜杠）
    @Published var host: String = ""
    @Published var account: String = ""
    /// 音乐文件所在的根目录（相对 host 的路径），用户可在登录时指定，默认 "/"
    @Published var musicRoot: String = "/"

    private let defaults = UserDefaults.standard
    private let hostKey = "atmusic.webdav.host"
    private let accountKey = "atmusic.webdav.account"
    private let musicRootKey = "atmusic.webdav.musicRoot"
    private(set) var storedPassword: String = ""

    /// 歌单 .m3u 文件统一存放的目录（相对 musicRoot），避免和用户自己的音乐文件混在一起
    let playlistFolderName = "ATMusicPlaylists"

    private let audioExtensions: Set<String> = ["mp3", "flac", "m4a", "wav", "aac", "ogg", "wma", "aiff", "alac", "ape"]
    private let session: URLSession

    /// 内存扫描索引缓存：首次浏览时递归扫描一次，后续浏览/搜索直接复用，避免反复触发 NAS 全盘 PROPFIND。
    private var scanCache: [WebDAVScannedSong] = []
    private var scanCacheBuiltAt: Date?
    private let scanCacheTTL: TimeInterval = 600
    private var scanTask: Task<[WebDAVScannedSong], Error>?

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
        host = defaults.string(forKey: hostKey) ?? ""
        account = defaults.string(forKey: accountKey) ?? ""
        musicRoot = defaults.string(forKey: musicRootKey) ?? "/"
        if !host.isEmpty, !account.isEmpty {
            storedPassword = SecureCredentialStore.shared.secret(for: passwordDestination) ?? ""
            isLoggedIn = !storedPassword.isEmpty
        }
    }

    var currentServerScope: String {
        "\(host)|\(account)"
    }

    private var passwordDestination: String { "webdav.password." + currentServerScope }

    func isConfigured() -> Bool {
        !host.isEmpty && !account.isEmpty
    }

    /// 保存配置并尝试对 musicRoot 做一次 PROPFIND 校验连通性/凭据。
    func configure(host: String, account: String, password: String, musicRoot: String) async throws {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedHost = trimmedHost.hasSuffix("/") ? String(trimmedHost.dropLast()) : trimmedHost
        self.host = normalizedHost
        self.account = account
        self.storedPassword = password
        self.musicRoot = musicRoot.isEmpty ? "/" : musicRoot
        defaults.set(normalizedHost, forKey: hostKey)
        defaults.set(account, forKey: accountKey)
        defaults.set(self.musicRoot, forKey: musicRootKey)
        _ = SecureCredentialStore.shared.setSecret(password, for: passwordDestination)
        invalidateScanCache()
        try await login()
    }

    func logout() {
        isLoggedIn = false
        _ = SecureCredentialStore.shared.deleteSecret(for: passwordDestination)
        invalidateScanCache()
    }

    func invalidateScanCache() {
        scanCache = []
        scanCacheBuiltAt = nil
        scanTask?.cancel()
        scanTask = nil
    }

    func login() async throws {
        guard !host.isEmpty, !account.isEmpty, !storedPassword.isEmpty else {
            throw WebDAVError.missingConfiguration("请先填写服务器地址、账号与密码")
        }
        _ = try await propfind(path: musicRoot, depth: "0")
        isLoggedIn = true
    }

    // MARK: - 底层请求

    private func buildURL(path: String) -> URL? {
        guard var components = URLComponents(string: host) else { return nil }
        let basePath = components.path
        let combined = (basePath + "/" + path)
            .replacingOccurrences(of: "//", with: "/")
        components.path = combined
        return components.url
    }

    private func authorizedRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        let credentials = "\(account):\(storedPassword)"
        if let data = credentials.data(using: .utf8) {
            request.setValue("Basic " + data.base64EncodedString(), forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// 对某一路径做 Depth:1（或指定深度）的 PROPFIND，返回其直接子项（不含自身，除非 depth 为 "0"）。
    private func propfind(path: String, depth: String = "1") async throws -> [WebDAVItem] {
        guard let url = buildURL(path: path) else {
            throw WebDAVError.missingConfiguration("服务器地址无效")
        }
        var request = authorizedRequest(url: url, method: "PROPFIND")
        request.setValue(depth, forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:getcontentlength/><d:getcontenttype/><d:resourcetype/><d:getlastmodified/></d:prop></d:propfind>
        """
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVError.network("无法连接服务器")
        }
        guard http.statusCode == 207 || http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw WebDAVError.server(code: http.statusCode, message: "账号或密码错误")
            }
            throw WebDAVError.server(code: http.statusCode, message: "目录读取失败")
        }
        let parser = XMLParser(data: data)
        let delegate = WebDAVPropfindParser()
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    private func getData(path: String) async throws -> Data {
        guard let url = buildURL(path: path) else {
            throw WebDAVError.missingConfiguration("服务器地址无效")
        }
        let request = authorizedRequest(url: url, method: "GET")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw WebDAVError.server(code: (response as? HTTPURLResponse)?.statusCode ?? -1, message: "文件读取失败")
        }
        return data
    }

    @discardableResult
    private func putData(_ data: Data, path: String) async throws -> Bool {
        guard let url = buildURL(path: path) else {
            throw WebDAVError.missingConfiguration("服务器地址无效")
        }
        var request = authorizedRequest(url: url, method: "PUT")
        request.httpBody = data
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw WebDAVError.server(code: (response as? HTTPURLResponse)?.statusCode ?? -1, message: "文件写入失败")
        }
        return true
    }

    /// 创建目录；服务器返回 405（已存在）时视为成功，不当作错误。
    @discardableResult
    private func makeCollection(path: String) async throws -> Bool {
        guard let url = buildURL(path: path) else {
            throw WebDAVError.missingConfiguration("服务器地址无效")
        }
        let request = authorizedRequest(url: url, method: "MKCOL")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVError.network("无法连接服务器")
        }
        if http.statusCode == 405 || (200...299).contains(http.statusCode) {
            return true
        }
        throw WebDAVError.server(code: http.statusCode, message: "目录创建失败")
    }

    private func deleteResource(path: String) async throws {
        guard let url = buildURL(path: path) else {
            throw WebDAVError.missingConfiguration("服务器地址无效")
        }
        let request = authorizedRequest(url: url, method: "DELETE")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) || http.statusCode == 404 else {
            throw WebDAVError.server(code: (response as? HTTPURLResponse)?.statusCode ?? -1, message: "删除失败")
        }
    }

    // MARK: - 播放地址 / 封面 / 歌词

    /// 同步构造流媒体直链；鉴权走请求头（由 PlayerManager/下载器自行附加），这里只返回定位该文件的 URL 字符串。
    func songURL(song: Song) -> String? {
        guard let path = song.webdavPath, let url = buildURL(path: path) else { return nil }
        return url.absoluteString
    }

    func coverURL(for song: Song) -> URL? {
        guard let path = song.webdavPath else { return nil }
        let folder = (path as NSString).deletingLastPathComponent
        // 同步接口无法等待异步 PROPFIND 结果；退而求其次猜测常见封面文件名，找不到由上层兜底占位图。
        let candidate = folder + "/cover.jpg"
        return buildURL(path: candidate)
    }

    /// 没有标准协议支持歌词；尝试读取同名 .lrc 兄弟文件，找不到返回 nil，不抛错。
    func lyrics(song: Song) async throws -> String? {
        guard let path = song.webdavPath else { return nil }
        let lrcPath = (path as NSString).deletingPathExtension + ".lrc"
        guard let data = try? await getData(path: lrcPath) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
    }

    /// 单层目录浏览（不走递归扫描缓存，反映服务器实时状态）：返回子目录路径列表与当前目录下的音频文件。
    func listFolder(path: String) async throws -> (folders: [String], songs: [Song]) {
        let items = try await propfind(path: path, depth: "1")
        let normalizedRequestPath = path.hasSuffix("/") ? String(path.dropLast()) : path
        var folders: [String] = []
        var songs: [Song] = []
        for item in items {
            let normalizedItemPath = item.path.hasSuffix("/") ? String(item.path.dropLast()) : item.path
            if normalizedItemPath.isEmpty || normalizedItemPath == normalizedRequestPath { continue }
            if item.isCollection {
                folders.append(normalizedItemPath)
            } else {
                let ext = (normalizedItemPath as NSString).pathExtension.lowercased()
                guard audioExtensions.contains(ext) else { continue }
                let fileName = ((normalizedItemPath as NSString).lastPathComponent as NSString).deletingPathExtension
                let folder = (normalizedItemPath as NSString).deletingLastPathComponent
                let folderName = (folder as NSString).lastPathComponent
                let grandParent = (folder as NSString).deletingLastPathComponent
                let grandParentName = (grandParent as NSString).lastPathComponent
                songs.append(makeSong(from: WebDAVScannedSong(
                    path: normalizedItemPath,
                    fileName: fileName,
                    folderName: folderName.isEmpty ? "未知专辑" : folderName,
                    grandParentFolderName: grandParentName.isEmpty ? "未知艺术家" : grandParentName
                )))
            }
        }
        return (folders.sorted(), songs.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }

    // MARK: - 目录递归扫描（有界深度 + 已访问去重，避免符号链接死循环）

    private func ensureScanIndex() async throws -> [WebDAVScannedSong] {
        if let builtAt = scanCacheBuiltAt, Date().timeIntervalSince(builtAt) < scanCacheTTL, !scanCache.isEmpty {
            return scanCache
        }
        if let existing = scanTask {
            return try await existing.value
        }
        let task = Task<[WebDAVScannedSong], Error> { [weak self] in
            guard let self else { return [] }
            return try await self.scanDirectory(path: self.musicRoot, depth: 0, visited: [])
        }
        scanTask = task
        do {
            let result = try await task.value
            scanCache = result
            scanCacheBuiltAt = Date()
            scanTask = nil
            return result
        } catch {
            scanTask = nil
            throw error
        }
    }

    private func scanDirectory(path: String, depth: Int, visited: Set<String>) async throws -> [WebDAVScannedSong] {
        guard depth < 6, !visited.contains(path) else { return [] }
        var visited = visited
        visited.insert(path)

        let items = try await propfind(path: path, depth: "1")
        var results: [WebDAVScannedSong] = []
        for item in items {
            // PROPFIND Depth:1 会把自身也算作一个 response，路径等于请求路径时跳过。
            let normalizedItemPath = item.path.hasSuffix("/") ? String(item.path.dropLast()) : item.path
            let normalizedRequestPath = path.hasSuffix("/") ? String(path.dropLast()) : path
            if normalizedItemPath.isEmpty || normalizedItemPath == normalizedRequestPath { continue }

            if item.isCollection {
                let children = try await scanDirectory(path: normalizedItemPath, depth: depth + 1, visited: visited)
                results.append(contentsOf: children)
            } else {
                let ext = (normalizedItemPath as NSString).pathExtension.lowercased()
                guard audioExtensions.contains(ext) else { continue }
                let fileName = ((normalizedItemPath as NSString).lastPathComponent as NSString).deletingPathExtension
                let folder = (normalizedItemPath as NSString).deletingLastPathComponent
                let folderName = (folder as NSString).lastPathComponent
                let grandParent = (folder as NSString).deletingLastPathComponent
                let grandParentName = (grandParent as NSString).lastPathComponent
                results.append(WebDAVScannedSong(
                    path: normalizedItemPath,
                    fileName: fileName,
                    folderName: folderName.isEmpty ? "未知专辑" : folderName,
                    grandParentFolderName: grandParentName.isEmpty ? "未知艺术家" : grandParentName
                ))
            }
        }
        return results
    }

    private func makeSong(from scanned: WebDAVScannedSong) -> Song {
        Song(
            id: UnifiedSong.stableNumericHash(scanned.path),
            name: scanned.fileName,
            artists: scanned.grandParentFolderName,
            album: scanned.folderName,
            coverURL: nil,
            duration: 0,
            source: .webdav,
            webdavPath: scanned.path,
            webdavServerScope: currentServerScope
        )
    }

    // MARK: - 浏览 / 搜索

    func fetchArtists() async throws -> [Artist] {
        let index = try await ensureScanIndex()
        var seen = Set<String>()
        var artists: [Artist] = []
        for item in index where seen.insert(item.grandParentFolderName).inserted {
            artists.append(Artist(id: item.grandParentFolderName, name: item.grandParentFolderName, coverURL: nil, source: .webdav))
        }
        return artists.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func fetchAlbums(for artist: Artist?) async throws -> [Album] {
        let index = try await ensureScanIndex()
        let filtered = artist == nil ? index : index.filter { $0.grandParentFolderName == artist!.name }
        var seen = Set<String>()
        var albums: [Album] = []
        for item in filtered where seen.insert(item.folderName + "|" + item.grandParentFolderName).inserted {
            albums.append(Album(id: item.folderName + "|" + item.grandParentFolderName, name: item.folderName, artistName: item.grandParentFolderName, coverURL: nil, source: .webdav, trackCount: nil))
        }
        return albums.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func fetchSongs(for album: Album) async throws -> [Song] {
        let index = try await ensureScanIndex()
        let filtered = index.filter { $0.folderName == album.name && $0.grandParentFolderName == album.artistName }
        return filtered.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }.map(makeSong)
    }

    /// 没有服务器端搜索接口，退化为对已扫描本地索引的关键词包含匹配。
    func searchAllVariants(keyword: String, limit: Int) async throws -> NASSearchResult {
        let index = try await ensureScanIndex()
        let lowered = keyword.lowercased()
        let matchedSongs = index.filter {
            $0.fileName.lowercased().contains(lowered)
                || $0.folderName.lowercased().contains(lowered)
                || $0.grandParentFolderName.lowercased().contains(lowered)
        }
        .prefix(limit)
        .map(makeSong)

        let matchedArtists = try await fetchArtists().filter { $0.name.lowercased().contains(lowered) }
        let matchedAlbums = try await fetchAlbums(for: nil).filter { $0.name.lowercased().contains(lowered) }
        return NASSearchResult(songs: Array(matchedSongs), artists: matchedArtists, albums: matchedAlbums)
    }

    // MARK: - 歌单（存成 playlistFolderName 目录下的 .m3u 文件，整篇覆盖写入）

    private var playlistFolderPath: String {
        let base = musicRoot.hasSuffix("/") ? String(musicRoot.dropLast()) : musicRoot
        return base + "/" + playlistFolderName
    }

    func allPlaylists() async throws -> [Playlist] {
        let items: [WebDAVItem]
        do {
            items = try await propfind(path: playlistFolderPath, depth: "1")
        } catch {
            // 目录可能尚不存在（从未创建过歌单），这是正常状态，不当作错误上抛。
            return []
        }
        return items.filter { !$0.isCollection && $0.path.lowercased().hasSuffix(".m3u") }
            .map { item in
                let name = ((item.path as NSString).lastPathComponent as NSString).deletingPathExtension
                return Playlist(id: UnifiedSong.stableNumericHash(item.path), name: name, coverURL: nil, trackCount: 0, source: .webdav, webdavPlaylistPath: item.path)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func playlistSongs(playlist: Playlist) async throws -> [Song] {
        guard let path = playlist.webdavPlaylistPath else { return [] }
        let data = try await getData(path: path)
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let paths = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        let index = try await ensureScanIndex()
        let byPath = Dictionary(uniqueKeysWithValues: index.map { ($0.path, $0) })
        return paths.compactMap { byPath[$0] }.map(makeSong)
    }

    private func m3uContent(for songs: [Song]) -> String {
        songs.compactMap { $0.webdavPath }.joined(separator: "\n") + "\n"
    }

    @discardableResult
    func createPlaylist(name: String, songs: [Song]) async throws -> Playlist? {
        try? await makeCollection(path: playlistFolderPath)
        let safeName = name.isEmpty ? "新建歌单" : name
        let path = playlistFolderPath + "/" + safeName + ".m3u"
        try await putData(Data(m3uContent(for: songs).utf8), path: path)
        return Playlist(id: UnifiedSong.stableNumericHash(path), name: safeName, coverURL: nil, trackCount: songs.count, source: .webdav, webdavPlaylistPath: path)
    }

    @discardableResult
    func updatePlaylist(_ playlist: Playlist, songs: [Song]) async throws -> Bool {
        guard let path = playlist.webdavPlaylistPath else { return false }
        try await putData(Data(m3uContent(for: songs).utf8), path: path)
        return true
    }

    @discardableResult
    func deletePlaylist(_ playlist: Playlist) async throws -> Bool {
        guard let path = playlist.webdavPlaylistPath else { return false }
        try await deleteResource(path: path)
        return true
    }
}

enum WebDAVError: LocalizedError {
    case notImplemented
    case missingConfiguration(String)
    case network(String)
    case server(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .notImplemented: return "WebDAV 功能尚未实现"
        case .missingConfiguration(let msg): return msg
        case .network(let msg): return msg
        case .server(let code, let message): return "WebDAV 服务器错误(\(code))：\(message)"
        }
    }
}
