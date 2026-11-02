import Foundation
import CryptoKit
import UIKit

struct SynologyFolderItem: Identifiable, Hashable, Codable {
    enum Kind: String, Hashable, Codable {
        case folder
        case song
    }

    let id: String
    let name: String
    let kind: Kind
    let song: Song?
    var path: String? = nil
}

struct SynologySearchResult {
    let songs: [Song]
    let artists: [Artist]
    let albums: [Album]
}

/// 文件夹直接与十级深度内容概要：是否含可支持音频文件、取到的第一首歌（封面预览用）。
struct SynologyFolderOverview: Hashable, Codable {
    var hasSupportedAudio: Bool = false
    var previewSong: Song? = nil

    var hasSong: Bool { hasSupportedAudio }
    var hasFolder: Bool = false
}

/// NAS 文件当前在编辑器中展示的标签快照。
struct SynologyTagMetadata: Equatable {
    var title: String
    var artist: String
    var album: String
    var albumArtist: String = ""
    var genre: String = ""
    var year: String = ""
    /// 盘号 / 音轨号用字符串承载：空串表示「本文件没有该标签」，与数字 0 区分开。
    var track: String = ""
    var disc: String = ""
    var comment: String = ""

    func patch(comparedTo original: SynologyTagMetadata) -> SynologyTagPatch {
        SynologyTagPatch(
            title: title == original.title ? nil : title,
            artist: artist == original.artist ? nil : artist,
            album: album == original.album ? nil : album,
            albumArtist: albumArtist == original.albumArtist ? nil : albumArtist,
            genre: genre == original.genre ? nil : genre,
            year: year == original.year ? nil : year,
            comment: comment == original.comment ? nil : comment,
            track: track == original.track ? nil : track,
            disc: disc == original.disc ? nil : disc
        )
    }
}

/// 只包含用户实际修改过的 NAS 标签。`nil` 表示完全不触碰该标签，空字符串则表示用户明确清空它。
struct SynologyTagPatch {
    let title: String?
    let artist: String?
    let album: String?
    let albumArtist: String?
    let genre: String?
    let year: String?
    let comment: String?
    var track: String? = nil
    var disc: String? = nil

    var isEmpty: Bool {
        [title, artist, album, albumArtist, genre, year, comment, track, disc].allSatisfy { $0 == nil }
    }
}

struct SynologyMetadataCandidate: Identifiable, Hashable {
    let id: String
    let song: Song
    let providerName: String
}

/// 可播种随机数生成器（按小时确定性打乱用，与 QQ 每日推荐的 SeededRNG 同款 LCG）
private struct HourlySeedRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

final class SynologyAPI: ObservableObject {
    static let shared = SynologyAPI()

    @Published var isLoggedIn: Bool = false
    @Published var host: String = ""
    @Published var port: Int = 5000
    @Published var isHTTPS: Bool = false
    @Published var account: String = ""

    // MARK: - 局域网 (LAN) 与公网 (WAN) 双通道智能路由
    @Published var lanHost: String = ""
    @Published var lanPort: Int = 5000
    @Published var lanHTTPS: Bool = false
    @Published var wanHost: String = ""
    @Published var wanPort: Int = 5000
    @Published var wanHTTPS: Bool = false
    @Published var isLanActive: Bool = false
    @Published var lanLatencyMs: Int? = nil
    @Published var wanLatencyMs: Int? = nil

    /// 全库索引完成后递增，搜索页可据此把首屏远程结果替换为完整本地结果。
    @Published private(set) var libraryIndexRevision: Int = 0

    func bumpLibraryIndexRevision() {
        libraryIndexRevision &+= 1
    }
    @Published private(set) var isLibraryIndexLoading: Bool = false

    private let defaults = UserDefaults.standard
    private let hostKey = "atmusic.synology.host"
    private let portKey = "atmusic.synology.port"
    private let httpsKey = "atmusic.synology.https"
    private let accountKey = "atmusic.synology.account"
    private let sidKey = "atmusic.synology.sid"
    private let passwordKey = "atmusic.synology.password"

    private(set) var sid: String = ""
    private var storedPassword: String = ""
    private var configurationGeneration = UUID()
    private let session: URLSession
    private let uploadSession: URLSession
    /// 搜索索引缓存：首次搜索建立，后续输入关键词只在内存中匹配，不再反复分页请求 NAS。
    private(set) var librarySongsCache: [Song] = []
    private var librarySongsCacheUpdatedAt = Date.distantPast
    private var librarySongsLoadingTask: Task<[Song], Error>?
    private let librarySongsCacheTTL: TimeInterval = 600
    /// 歌单歌曲数缓存：点数要逐张请求 NAS，缓存 10 分钟避免每次进列表都全量重数。
    private var playlistCountCache: [String: (count: Int, at: Date)] = [:]
    private var didRestorePersistentLibraryIndex = false
    private var librarySongsIndex: [String: Song] = [:]
    private var knownMusicFolderPaths: Set<String> = []
    private var folderPreviewSongsByPath: [String: Song] = [:]
    private let indexLock = NSLock()

    private let uploadedCoverLock = NSLock()
    private var uploadedCoverFolders: [String: String] = [:]

    func clearLibraryCache() {
        librarySongsCache.removeAll()
        librarySongsCacheUpdatedAt = .distantPast
        indexLock.lock()
        librarySongsIndex.removeAll()
        knownMusicFolderPaths.removeAll()
        folderPreviewSongsByPath.removeAll()
        indexLock.unlock()
        uploadedCoverLock.lock()
        uploadedCoverFolders.removeAll()
        uploadedCoverLock.unlock()
    }

    private func rebuildLibrarySongsIndex() {
        var map: [String: Song] = [:]
        var folderPaths = Set<String>()
        var previewMap: [String: Song] = [:]

        for s in librarySongsCache {
            map[s.identityKey] = s
            if let synoId = s.synologyId {
                map["syno_\(synoId)"] = s
            }
            if s.id != 0 {
                map["id_\(s.id)"] = s
            }
            if let rawPath = s.synologyPath, !rawPath.isEmpty {
                var parent = (rawPath as NSString).deletingLastPathComponent
                while !parent.isEmpty && parent != "/" && parent != "." {
                    folderPaths.insert(parent)
                    let trimmed = parent.hasPrefix("/") ? String(parent.dropFirst()) : parent
                    folderPaths.insert(trimmed)
                    if previewMap[parent] == nil {
                        previewMap[parent] = s
                        previewMap[trimmed] = s
                    }
                    parent = (parent as NSString).deletingLastPathComponent
                }
            }
        }
        indexLock.lock()
        librarySongsIndex = map
        knownMusicFolderPaths = folderPaths
        folderPreviewSongsByPath = previewMap
        indexLock.unlock()
    }

    private func indexSong(_ song: Song) {
        indexLock.lock()
        librarySongsIndex[song.identityKey] = song
        if let synoId = song.synologyId {
            librarySongsIndex["syno_\(synoId)"] = song
        }
        if song.id != 0 {
            librarySongsIndex["id_\(song.id)"] = song
        }
        if let rawPath = song.synologyPath, !rawPath.isEmpty {
            var parent = (rawPath as NSString).deletingLastPathComponent
            while !parent.isEmpty && parent != "/" && parent != "." {
                knownMusicFolderPaths.insert(parent)
                let trimmed = parent.hasPrefix("/") ? String(parent.dropFirst()) : parent
                knownMusicFolderPaths.insert(trimmed)
                if folderPreviewSongsByPath[parent] == nil {
                    folderPreviewSongsByPath[parent] = song
                    folderPreviewSongsByPath[trimmed] = song
                }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        indexLock.unlock()
    }

    /// O(1) 毫秒级根据歌曲实体或 identityKey 查询已缓存的 NAS 歌曲元数据（杜绝视图刷新时的 O(N) 遍历卡顿）
    func cachedSong(for song: Song) -> Song? {
        restorePersistentLibraryIndexIfNeeded()
        indexLock.lock()
        defer { indexLock.unlock() }
        if let direct = librarySongsIndex[song.identityKey] { return direct }
        if let synoId = song.synologyId, let bySyno = librarySongsIndex["syno_\(synoId)"] { return bySyno }
        if song.id != 0, let byId = librarySongsIndex["id_\(song.id)"] { return byId }
        return nil
    }

    /// 获取当前已有的本地音乐库歌曲（若尚未读入内存，自动从本地磁盘索引轻量恢复，绝不发起网络阻塞）
    var cachedLibrarySongs: [Song] {
        restorePersistentLibraryIndexIfNeeded()
        return librarySongsCache
    }

    /// 标签或封面修改后，原地同步更新内存及本地磁盘中的歌曲快照
    func updateCachedLibrarySong(_ updated: Song) {
        restorePersistentLibraryIndexIfNeeded()
        var changed = false
        for idx in librarySongsCache.indices {
            let s = librarySongsCache[idx]
            if s.identityKey == updated.identityKey || (s.synologyId != nil && s.synologyId == updated.synologyId) || (s.id == updated.id && s.id != 0) {
                librarySongsCache[idx] = updated
                changed = true
            }
        }
        if changed {
            indexSong(updated)
            persistLibraryIndex()
            Task { @MainActor in
                self.libraryIndexRevision &+= 1
            }
        }
    }

    /// 批量更新 NAS 歌曲快照与索引（单次落盘与单次版本递增，杜绝循环更新时的重复 I/O 与视图频繁刷新）
    func updateCachedLibrarySongs(_ updatedList: [Song]) {
        restorePersistentLibraryIndexIfNeeded()
        guard !updatedList.isEmpty else { return }
        var anyChanged = false
        for updated in updatedList {
            for idx in librarySongsCache.indices {
                let s = librarySongsCache[idx]
                if s.identityKey == updated.identityKey || (s.synologyId != nil && s.synologyId == updated.synologyId) || (s.id == updated.id && s.id != 0) {
                    librarySongsCache[idx] = updated
                    anyChanged = true
                }
            }
            indexSong(updated)
        }
        if anyChanged {
            persistLibraryIndex()
            Task { @MainActor in
                self.libraryIndexRevision &+= 1
            }
        }
    }

    private struct FolderCacheEntry: Codable {
        let serverScope: String
        let folderID: String
        let updatedAt: Date
        let items: [SynologyFolderItem]
    }

    private let folderCacheLock = NSLock()
    private var folderMemoryCache: [String: FolderCacheEntry] = [:]
    private let folderCacheFreshTTL: TimeInterval = 300
    private let folderCacheStaleTTL: TimeInterval = 86_400

    private struct LibraryIndexSnapshot: Codable {
        let version: Int
        let updatedAt: Date
        let songs: [Song]

        init(updatedAt: Date, songs: [Song]) {
            self.version = 2
            self.updatedAt = updatedAt
            self.songs = songs
        }
    }

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)

        let uploadConfig = URLSessionConfiguration.default
        uploadConfig.timeoutIntervalForRequest = 180
        uploadConfig.timeoutIntervalForResource = 3600
        uploadSession = URLSession(configuration: uploadConfig)

        host = defaults.string(forKey: hostKey) ?? ""
        port = defaults.integer(forKey: portKey) == 0 ? 5000 : defaults.integer(forKey: portKey)
        isHTTPS = defaults.bool(forKey: httpsKey)
        account = defaults.string(forKey: accountKey) ?? ""

        lanHost = defaults.string(forKey: "atmusic.synology.lanHost") ?? defaults.string(forKey: hostKey) ?? ""
        lanPort = defaults.integer(forKey: "atmusic.synology.lanPort") == 0 ? (defaults.integer(forKey: portKey) == 0 ? 5000 : defaults.integer(forKey: portKey)) : defaults.integer(forKey: "atmusic.synology.lanPort")
        lanHTTPS = defaults.object(forKey: "atmusic.synology.lanHTTPS") != nil ? defaults.bool(forKey: "atmusic.synology.lanHTTPS") : defaults.bool(forKey: httpsKey)

        wanHost = defaults.string(forKey: "atmusic.synology.wanHost") ?? ""
        wanPort = defaults.integer(forKey: "atmusic.synology.wanPort") == 0 ? 5000 : defaults.integer(forKey: "atmusic.synology.wanPort")
        wanHTTPS = defaults.bool(forKey: "atmusic.synology.wanHTTPS")
        let credentials = SecureCredentialStore.shared
        let passwordDestination = "synology.password." + currentServerScope
        _ = credentials.migrateLegacyPassword(defaults: defaults, destinationKey: passwordDestination)
        // 兼容 Gemini 开发版的单槽钥匙串；仅针对启动时已保存的连接迁移。
        if credentials.secret(for: passwordDestination) == nil,
           let old = credentials.secret(for: "synology.password"),
           credentials.setSecret(old, for: passwordDestination) {
            credentials.deleteSecret(for: "synology.password")
        }
        storedPassword = credentials.secret(for: passwordDestination) ?? defaults.string(forKey: passwordKey) ?? ""
        sid = credentials.secret(for: "synology.sid." + currentServerScope) ?? defaults.string(forKey: sidKey) ?? ""
        if !sid.isEmpty {
            rememberLegacySession(sid)
            if credentials.setSecret(sid, for: "synology.sid." + currentServerScope) {
                defaults.removeObject(forKey: sidKey)
            }
        }
        isLoggedIn = !sid.isEmpty && !host.isEmpty

        NetworkMonitor.shared.onPathUpdate = { [weak self] in
            self?.checkNetworkRoute()
        }
        checkNetworkRoute()
    }

    var baseURL: String {
        let activeHost: String
        let activePort: Int
        let activeHTTPS: Bool

        if isLanActive && !lanHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            activeHost = lanHost
            activePort = lanPort
            activeHTTPS = lanHTTPS
        } else if !wanHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            activeHost = wanHost
            activePort = wanPort
            activeHTTPS = wanHTTPS
        } else {
            activeHost = host
            activePort = port
            activeHTTPS = isHTTPS
        }

        let cleaned = activeHost.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
        let scheme = activeHTTPS ? "https" : "http"
        return "\(scheme)://\(cleaned):\(activePort)"
    }

    /// 局域网/公网自适应测速探测（<= 500ms 快速判别，切勿长耗时阻塞）
    func checkNetworkRoute() {
        let trimmedLan = lanHost.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")

        guard !trimmedLan.isEmpty else {
            DispatchQueue.main.async {
                self.isLanActive = false
                self.lanLatencyMs = nil
            }
            return
        }

        let lanScheme = lanHTTPS ? "https" : "http"
        guard let probeURL = URL(string: "\(lanScheme)://\(trimmedLan):\(lanPort)/webapi/query.cgi?api=SYNO.API.Info&version=1&method=query&query=SYNO.API.Auth") else { return }

        Task {
            let start = Date()
            var request = URLRequest(url: probeURL)
            request.timeoutInterval = 0.6
            request.httpMethod = "GET"

            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, (200...399).contains(http.statusCode) {
                    let rtt = Int(Date().timeIntervalSince(start) * 1000)
                    await MainActor.run {
                        self.isLanActive = true
                        self.lanLatencyMs = max(1, rtt)
                    }
                    return
                }
            } catch {
                // LAN 探测超时或不可达，降级到公网
            }

            await MainActor.run {
                self.isLanActive = false
                self.lanLatencyMs = nil
            }
        }
    }

    // MARK: - 鉴权

    var currentServerScope: String {
        NASSourceScope.make(host: host, port: port, https: isHTTPS, account: account)
    }
    var savedPassword: String { storedPassword }

    private func sessionFingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func rememberLegacySession(_ token: String) {
        // 只记录会话摘要和已知所属连接，帮助旧歌单安全升级；绝不把历史歌单猜配到新服务器。
        defaults.set(currentServerScope, forKey: "atmusic.synology.sessionScope." + sessionFingerprint(token))
    }
    func accepts(song: Song) -> Bool {
        guard song.source == .synology else { return false }
        if let scope = song.synologyServerScope { return scope == currentServerScope }
        guard let cover = song.coverURL,
              let parts = URLComponents(url: cover, resolvingAgainstBaseURL: false),
              let base = URLComponents(string: baseURL), parts.host == base.host,
              parts.port == base.port, parts.scheme == base.scheme,
              let token = parts.queryItems?.first(where: { $0.name == "_sid" })?.value else { return false }
        return defaults.string(forKey: "atmusic.synology.sessionScope." + sessionFingerprint(token)) == currentServerScope
    }

    func saveDualConfiguration(
        lanHost: String,
        lanPort: Int,
        lanHTTPS: Bool,
        wanHost: String,
        wanPort: Int,
        wanHTTPS: Bool,
        account: String,
        password: String
    ) throws {
        let primaryHost = !lanHost.isEmpty ? lanHost : wanHost
        let primaryPort = !lanHost.isEmpty ? lanPort : wanPort
        let primaryHTTPS = !lanHost.isEmpty ? lanHTTPS : wanHTTPS

        let scope = NASSourceScope.make(host: primaryHost, port: primaryPort, https: primaryHTTPS, account: account)
        guard SecureCredentialStore.shared.setSecret(password, for: "synology.password." + scope) else {
            throw SynologyError.loginFailed("密码未能安全保存，请解锁设备后重试；原连接和密码未删除")
        }
        if scope != currentServerScope {
            configurationGeneration = UUID()
            librarySongsLoadingTask?.cancel()
            librarySongsLoadingTask = nil
            clearLibraryCache()
            didRestorePersistentLibraryIndex = false
            sid = ""
            isLoggedIn = false
            defaults.removeObject(forKey: sidKey)
        }

        self.lanHost = lanHost.trimmingCharacters(in: .whitespacesAndNewlines)
        self.lanPort = lanPort
        self.lanHTTPS = lanHTTPS
        self.wanHost = wanHost.trimmingCharacters(in: .whitespacesAndNewlines)
        self.wanPort = wanPort
        self.wanHTTPS = wanHTTPS

        self.host = primaryHost.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = primaryPort
        self.isHTTPS = primaryHTTPS
        self.account = account.trimmingCharacters(in: .whitespacesAndNewlines)
        self.storedPassword = password

        defaults.set(self.lanHost, forKey: "atmusic.synology.lanHost")
        defaults.set(self.lanPort, forKey: "atmusic.synology.lanPort")
        defaults.set(self.lanHTTPS, forKey: "atmusic.synology.lanHTTPS")
        defaults.set(self.wanHost, forKey: "atmusic.synology.wanHost")
        defaults.set(self.wanPort, forKey: "atmusic.synology.wanPort")
        defaults.set(self.wanHTTPS, forKey: "atmusic.synology.wanHTTPS")

        defaults.set(self.host, forKey: hostKey)
        defaults.set(self.port, forKey: portKey)
        defaults.set(self.isHTTPS, forKey: httpsKey)
        defaults.set(self.account, forKey: accountKey)
        defaults.removeObject(forKey: passwordKey)

        checkNetworkRoute()
    }

    func saveConfiguration(host: String, port: Int, isHTTPS: Bool, account: String, password: String) throws {
        try saveDualConfiguration(
            lanHost: host,
            lanPort: port,
            lanHTTPS: isHTTPS,
            wanHost: wanHost,
            wanPort: wanPort,
            wanHTTPS: wanHTTPS,
            account: account,
            password: password
        )
    }

    /// 登录群晖 Audio Station (SYNO.API.Auth)
    func login(otpCode: String? = nil) async throws {
        guard !host.isEmpty else { throw SynologyError.missingConfiguration("服务器地址未配置") }
        guard !account.isEmpty else { throw SynologyError.missingConfiguration("账号未填写") }
        guard !storedPassword.isEmpty else { throw SynologyError.missingConfiguration("密码未填写") }

        let queryItems: [URLQueryItem] = [
            URLQueryItem(name: "api", value: "SYNO.API.Auth"),
            URLQueryItem(name: "version", value: "3"),
            URLQueryItem(name: "method", value: "login"),
            URLQueryItem(name: "account", value: account),
            URLQueryItem(name: "passwd", value: storedPassword),
            URLQueryItem(name: "session", value: "AudioStation"),
            URLQueryItem(name: "format", value: "sid"),
            URLQueryItem(name: "otp_code", value: otpCode)
        ].filter { $0.value != nil }

        let json = try await get("/webapi/auth.cgi", query: queryItems, authenticated: false)
        guard let data = json["data"] as? [String: Any], let newSid = data["sid"] as? String, !newSid.isEmpty else {
            throw SynologyError.loginFailed("未能获取到有效会话令牌")
        }

        guard SecureCredentialStore.shared.setSecret(newSid, for: "synology.sid." + currentServerScope) else {
            throw SynologyError.loginFailed("会话无法安全保存，请解锁设备后重试")
        }
        self.sid = newSid
        rememberLegacySession(newSid)
        defaults.removeObject(forKey: sidKey)
        clearLibraryCache()
        didRestorePersistentLibraryIndex = false
        await MainActor.run {
            self.isLoggedIn = true
        }
        ATMusicLogger.shared.log("群晖 NAS 登录成功", level: .info)
    }

    /// 退出登录
    func logout() async {
        let scope = currentServerScope
        if !sid.isEmpty {
            let query = [
                URLQueryItem(name: "api", value: "SYNO.API.Auth"),
                URLQueryItem(name: "version", value: "1"),
                URLQueryItem(name: "method", value: "logout"),
                URLQueryItem(name: "session", value: "AudioStation")
            ]
            _ = try? await get("/webapi/auth.cgi", query: query, authenticated: true)
        }
        guard scope == currentServerScope else { return }
        configurationGeneration = UUID()
        librarySongsLoadingTask?.cancel()
        librarySongsLoadingTask = nil
        sid = ""
        SecureCredentialStore.shared.deleteSecret(for: "synology.sid." + scope)
        clearLibraryCache()
        didRestorePersistentLibraryIndex = false
        defaults.removeObject(forKey: sidKey)
        await MainActor.run {
            isLoggedIn = false
        }
        ATMusicLogger.shared.log("群晖 NAS 已注销登录", level: .info)
    }

    // MARK: - 资源地址构造

    /// 构造音频播放直链 (SYNO.AudioStation.Stream)
    func songURL(song: Song) -> String? {
        guard accepts(song: song), isLoggedIn, !sid.isEmpty, let synoId = song.synologyId ?? (song.source == .synology ? "\(song.id)" : nil) else {
            return nil
        }

        let transcodeCellular = UserDefaults.standard.bool(forKey: "atmusic.nas.transcodeOnCellular")
        let isCellular = NetworkMonitor.shared.isCellular
        let path = song.synologyPath ?? ""
        let ext = ((path as NSString).pathExtension).lowercased()
        let unsupportedAppleFormats: Set<String> = ["ogg", "ape", "wma"]

        if (transcodeCellular && isCellular) || unsupportedAppleFormats.contains(ext) {
            // 蜂窝移动网络下按用户要求自动转码，或原文件为 iOS 无法原生硬解的格式（如 ogg, ape, wma）时自动请求 NAS 转码为 320kbps MP3
            var url = URLComponents(string: baseURL + "/webapi/AudioStation/stream.cgi/0.mp3")
            url?.queryItems = [
                URLQueryItem(name: "api", value: "SYNO.AudioStation.Stream"),
                URLQueryItem(name: "version", value: "2"),
                URLQueryItem(name: "method", value: "stream"),
                URLQueryItem(name: "id", value: synoId),
                URLQueryItem(name: "_sid", value: sid),
                URLQueryItem(name: "format", value: "mp3")
            ]
            return url?.url?.absoluteString
        } else {
            // 原盘无损直出 (Bit-Perfect Direct Output，动态探测原始扩展名)
            let streamExt = ext.isEmpty ? "flac" : ext
            var url = URLComponents(string: baseURL + "/webapi/AudioStation/stream.cgi/0.\(streamExt)")
            url?.queryItems = [
                URLQueryItem(name: "api", value: "SYNO.AudioStation.Stream"),
                URLQueryItem(name: "version", value: "2"),
                URLQueryItem(name: "method", value: "stream"),
                URLQueryItem(name: "id", value: synoId),
                URLQueryItem(name: "_sid", value: sid),
                URLQueryItem(name: "format", value: "original")
            ]
            return url?.url?.absoluteString
        }
    }

    /// 构造封面图直链 (SYNO.AudioStation.Cover)
    func coverURL(songId: String, cacheBust: String? = nil) -> URL? {
        guard !sid.isEmpty else { return nil }
        let encodedId = songId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? songId
        var urlStr = "\(baseURL)/webapi/AudioStation/cover.cgi?api=SYNO.AudioStation.Cover&version=1&method=getsongcover&library=all&id=\(encodedId)&_sid=\(sid)"
        if let cacheBust, !cacheBust.isEmpty {
            urlStr += "&_atmusic_refresh=\(cacheBust.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cacheBust)"
        }
        return URL(string: urlStr)
    }

    func coverURL(albumName: String, artistName: String) -> URL? {
        guard !sid.isEmpty else { return nil }
        let albumEnc = albumName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? albumName
        let artistEnc = artistName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? artistName
        let urlStr = "\(baseURL)/webapi/AudioStation/cover.cgi?api=SYNO.AudioStation.Cover&version=1&method=getcover&library=all&album_name=\(albumEnc)&artist_name=\(artistEnc)&_sid=\(sid)"
        return URL(string: urlStr)
    }

    // MARK: - 数据读取

    /// 获取歌曲列表 (SYNO.AudioStation.Song)
    func songs(offset: Int = 0, limit: Int = 100, sort: String = "title") async throws -> [Song] {
        let query: [URLQueryItem] = [
            URLQueryItem(name: "api", value: "SYNO.AudioStation.Song"),
            URLQueryItem(name: "version", value: "3"),
            URLQueryItem(name: "method", value: "list"),
            URLQueryItem(name: "offset", value: "\(offset)"),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "sort_by", value: sort),
            URLQueryItem(name: "sort_direction", value: "ASC"),
            URLQueryItem(name: "library", value: "all"),
            URLQueryItem(name: "additional", value: "song_tag,song_audio")
        ]

        let json = try await get("/webapi/AudioStation/song.cgi", query: query, authenticated: true)
        guard let data = json["data"] as? [String: Any], let songsArray = data["songs"] as? [[String: Any]] else {
            return []
        }

        return songsArray.compactMap { self.parseSong($0) }
    }

    /// 最近添加的专辑 (SYNO.AudioStation.Album, sort_by=time)。
    /// 与 Audio Station 官方「最近添加」同款查法：服务端索引存有专辑入库时间，
    /// 按 time 倒序即入库顺序（该排序值未见于公开文档，取自官方网页版客户端的实际调用）。
    /// 失败返回空数组，不让首页因为这一块加载失败。
    func recentlyAddedAlbums(limit: Int = 50) async -> [Album] {
        let query: [URLQueryItem] = [
            URLQueryItem(name: "api", value: "SYNO.AudioStation.Album"),
            URLQueryItem(name: "version", value: "3"),
            URLQueryItem(name: "method", value: "list"),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "sort_by", value: "time"),
            URLQueryItem(name: "sort_direction", value: "DESC"),
            URLQueryItem(name: "library", value: "all"),
            URLQueryItem(name: "additional", value: "avg_rating")
        ]

        guard let json = try? await get("/webapi/AudioStation/album.cgi", query: query, authenticated: true),
              let data = json["data"] as? [String: Any],
              let items = data["albums"] as? [[String: Any]] else {
            return []
        }

        return items.compactMap { item -> Album? in
            guard let name = Self.stringValue(item["name"]), !name.isEmpty else { return nil }
            let artist = Self.stringValue(item["display_artist"]) ?? Self.stringValue(item["album_artist"]) ?? Self.stringValue(item["artist"]) ?? ""
            return Album(
                id: "synology-album-\(Self.stableID(name + artist))",
                name: name,
                artistName: artist,
                coverURL: coverURL(albumName: name, artistName: artist),
                source: .synology,
                trackCount: nil
            )
        }
    }

    /// 分页读取完整音乐库。Audio Station 的搜索接口在不同 DSM/Audio Station 版本上
    /// 返回字段并不一致，因此搜索时会用这份完整目录做本地兜底匹配。
    /// NAS 今日推荐的按小时轮换挑选：以当前小时为种子确定性洗牌——同一小时内
    /// 多次进入/刷新结果一致，跨过整点自动换一批。NAS 首页与聚合首页共用，
    /// 避免聚合页永远取排序后的前 30 首、NAS 首页每 10 分钟乱换一轮的问题。
    static func hourlyRecommendedSongs(from songs: [Song], count: Int) -> [Song] {
        guard songs.count > count else { return songs }
        let hourBucket = UInt64(Date().timeIntervalSince1970 / 3600)
        var rng = HourlySeedRNG(state: hourBucket &* 2862933555777941757 &+ 3037000493)
        var shuffled = songs
        shuffled.shuffle(using: &rng)
        return Array(shuffled.prefix(count))
    }

    func librarySongs(pageSize: Int = 500, forceRefresh: Bool = false) async throws -> [Song] {
        restorePersistentLibraryIndexIfNeeded()
        if !forceRefresh,
           !librarySongsCache.isEmpty,
           Date().timeIntervalSince(librarySongsCacheUpdatedAt) < librarySongsCacheTTL {
            return librarySongsCache
        }

        if let loadingTask = librarySongsLoadingTask {
            return try await loadingTask.value
        }

        let safePageSize = max(50, min(pageSize, 1000))
        await MainActor.run {
            self.isLibraryIndexLoading = true
        }
        let loadingTask = Task { [weak self] () throws -> [Song] in
            guard let self else { return [] }
            var result: [Song] = []
            var offset = 0
            // 不用固定 20,000 首截断；只用较高安全上限防止异常 NAS 无限返回同一页。
            while result.count < 100_000 {
                let page = try await self.songs(offset: offset, limit: safePageSize, sort: "title")
                if page.isEmpty { break }
                result.append(contentsOf: page)
                offset += page.count
                if page.count < safePageSize { break }
            }
            var seen = Set<String>()
            return result.filter { seen.insert($0.identityKey).inserted }
        }
        librarySongsLoadingTask = loadingTask
        defer {
            librarySongsLoadingTask = nil
            Task { @MainActor in
                self.isLibraryIndexLoading = false
            }
        }
        do {
            let result = try await loadingTask.value
            librarySongsCache = result
            librarySongsCacheUpdatedAt = Date()
            rebuildLibrarySongsIndex()
            persistLibraryIndex()
            await MainActor.run {
                self.libraryIndexRevision &+= 1
            }
            return result
        } catch {
            throw error
        }
    }

    private var persistentLibraryIndexFile: AtomicLibraryFile<LibraryIndexSnapshot> {
        let key = sessionFingerprint(currentServerScope)
        let directory = AtomicLibraryFile<LibraryIndexSnapshot>.defaultDirectory
            .appendingPathComponent("NASIndexes", isDirectory: true)
        return AtomicLibraryFile(url: directory.appendingPathComponent("\(key).json"))
    }

    private func restorePersistentLibraryIndexIfNeeded() {
        guard !didRestorePersistentLibraryIndex else { return }
        didRestorePersistentLibraryIndex = true
        guard !currentServerScope.isEmpty,
              let snapshot = try? persistentLibraryIndexFile.read(),
              snapshot.version == 2,
              !snapshot.songs.isEmpty else { return }
        librarySongsCache = snapshot.songs
        librarySongsCacheUpdatedAt = snapshot.updatedAt
        rebuildLibrarySongsIndex()
    }

    private func persistLibraryIndex() {
        guard !librarySongsCache.isEmpty else { return }
        let snapshot = LibraryIndexSnapshot(updatedAt: librarySongsCacheUpdatedAt, songs: librarySongsCache)
        try? persistentLibraryIndexFile.write(snapshot)
    }

    /// 搜索群晖音乐
    func search(keyword: String, limit: Int = 50) async throws -> [Song] {
        try await searchAll(keyword: keyword, limit: limit).songs
    }

    /// 搜索歌曲、歌手、专辑。Audio Station Search 接口一次返回三类结果。
    func searchAll(keyword: String, limit: Int = 50) async throws -> SynologySearchResult {
        guard !keyword.isEmpty else {
            return SynologySearchResult(songs: [], artists: [], albums: [])
        }
        let query: [URLQueryItem] = [
            URLQueryItem(name: "api", value: "SYNO.AudioStation.Search"),
            URLQueryItem(name: "version", value: "1"),
            URLQueryItem(name: "method", value: "list"),
            URLQueryItem(name: "keyword", value: keyword),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "sort_by", value: "title"),
            URLQueryItem(name: "sort_direction", value: "ASC"),
            URLQueryItem(name: "library", value: "all"),
            URLQueryItem(name: "additional", value: "song_tag,song_audio")
        ]

        let json = try await get("/webapi/AudioStation/search.cgi", query: query, authenticated: true)
        guard let data = json["data"] as? [String: Any] else {
            return SynologySearchResult(songs: [], artists: [], albums: [])
        }

        let songs = (data["songs"] as? [[String: Any]] ?? []).compactMap { self.parseSong($0) }
        let artists = (data["artists"] as? [[String: Any]] ?? []).compactMap { item -> Artist? in
            guard let name = Self.stringValue(item["name"]), !name.isEmpty else { return nil }
            return Artist(id: "synology-artist-\(Self.stableID(name))", name: name, coverURL: nil, source: .synology)
        }
        let albums = (data["albums"] as? [[String: Any]] ?? []).compactMap { item -> Album? in
            guard let name = Self.stringValue(item["name"]), !name.isEmpty else { return nil }
            let artist = Self.stringValue(item["display_artist"]) ?? Self.stringValue(item["album_artist"]) ?? Self.stringValue(item["artist"]) ?? ""
            return Album(id: "synology-album-\(Self.stableID(name + artist))", name: name, artistName: artist, coverURL: nil, source: .synology, trackCount: nil)
        }
        return SynologySearchResult(songs: songs, artists: artists, albums: albums)
    }

    /// 同时尝试常见的简繁体/英文别名，再合并结果。
    func searchAllVariants(keyword: String, limit: Int = 50) async throws -> SynologySearchResult {
        restorePersistentLibraryIndexIfNeeded()
        if !librarySongsCache.isEmpty,
           Date().timeIntervalSince(librarySongsCacheUpdatedAt) >= librarySongsCacheTTL,
           librarySongsLoadingTask == nil {
            // 先用旧索引完成当前输入，再后台刷新，避免 TTL 到期造成搜索卡顿。
            Task { [weak self] in
                _ = try? await self?.librarySongs(forceRefresh: true)
            }
        }
        let variants = Self.searchVariants(for: keyword)
        if librarySongsCache.isEmpty {
            // 首次搜索先返回 Audio Station 结果，完整目录索引放到后台建立，避免首搜卡住界面。
            let remoteResult = await remoteSearchResult(variants: variants, limit: limit)
            if librarySongsLoadingTask == nil {
                Task { [weak self] in
                    _ = try? await self?.librarySongs()
                }
            }
            return remoteResult
        }

        // 先查本地索引：建立过索引后，普通搜索直接内存命中，避免每次输入都等待 NAS 网络请求。
        let localResult = (try? await librarySearchResult(keyword: keyword, limit: max(limit, 200)))
            ?? SynologySearchResult(songs: [], artists: [], albums: [])
        if !localResult.songs.isEmpty || !localResult.artists.isEmpty || !localResult.albums.isEmpty {
            return localResult
        }

        // 本地没有命中时再查远程简繁体变体；某个变体失败不会影响其它结果。
        return await remoteSearchResult(variants: variants, limit: limit)
    }

    private func remoteSearchResult(variants: [String], limit: Int) async -> SynologySearchResult {
        guard let primary = variants.first else {
            return SynologySearchResult(songs: [], artists: [], albums: [])
        }

        // 首次搜索先使用原始关键词；Audio Station 的搜索接口本身支持繁简体和标题匹配，
        // 不再为了等待所有变体而延迟首屏。只有原始关键词无结果时才尝试其它变体。
        if let result = try? await searchAll(keyword: primary, limit: limit),
           !result.songs.isEmpty || !result.artists.isEmpty || !result.albums.isEmpty {
            return result
        }

        var songs: [Song] = []
        var artists: [Artist] = []
        var albums: [Album] = []
        for variant in variants.dropFirst() {
            guard let result = try? await searchAll(keyword: variant, limit: limit) else { continue }
            songs.append(contentsOf: result.songs)
            artists.append(contentsOf: result.artists)
            albums.append(contentsOf: result.albums)
            if !songs.isEmpty || !artists.isEmpty || !albums.isEmpty { break }
        }
        return SynologySearchResult(
            songs: Self.uniqueSongs(songs),
            artists: Self.uniqueArtists(artists),
            albums: Self.uniqueAlbums(albums)
        )
    }

    private func librarySearchResult(keyword: String, limit: Int) async throws -> SynologySearchResult {
        // 搜索优先使用已落盘索引，不因为索引超过 10 分钟就阻塞当前结果；
        // 新索引由后续的库刷新流程更新，保证输入关键词时始终保持即时响应。
        restorePersistentLibraryIndexIfNeeded()
        let library = librarySongsCache
        let variants = Self.searchVariants(for: keyword).map(Self.normalizedSearchValue)
        guard !variants.isEmpty else { return SynologySearchResult(songs: [], artists: [], albums: []) }

        func matches(_ value: String) -> Bool {
            let normalized = Self.normalizedSearchValue(value)
            return variants.contains { query in
                !query.isEmpty && (normalized.contains(query) || query.contains(normalized))
            }
        }

        let matchedSongs = library.filter { song in
            matches(song.name) || matches(song.artists) || matches(song.album)
        }.sorted { lhs, rhs in
            let leftScore = SearchResultRelevance.score(keyword: keyword, primary: lhs.name, secondary: [lhs.artists, lhs.album])
            let rightScore = SearchResultRelevance.score(keyword: keyword, primary: rhs.name, secondary: [rhs.artists, rhs.album])
            if leftScore != rightScore { return leftScore < rightScore }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        // 歌手和专辑必须从完整命中集合生成，不能再用 limit * 3 截断，
        // 否则同一歌手后面的歌曲/专辑会永远不会出现在搜索结果里。
        let limitedSongs = matchedSongs
        var artists: [Artist] = []
        var seenArtists = Set<String>()
        for song in limitedSongs {
            for name in song.artists.components(separatedBy: " / ") where !name.isEmpty {
                guard seenArtists.insert(name.lowercased()).inserted else { continue }
                artists.append(Artist(
                    id: "synology-artist-\(Self.stableID(name))",
                    name: name,
                    coverURL: song.coverURL,
                    source: .synology
                ))
            }
        }

        var albums: [Album] = []
        var seenAlbums = Set<String>()
        for song in limitedSongs where !song.album.isEmpty {
            let key = "\(song.album)|\(song.artists)".lowercased()
            guard seenAlbums.insert(key).inserted else { continue }
            albums.append(Album(
                id: "synology-album-\(Self.stableID(key))",
                name: song.album,
                artistName: song.artists,
                coverURL: song.coverURL,
                source: .synology,
                trackCount: nil
            ))
        }
        return SynologySearchResult(
            songs: Array(limitedSongs.prefix(max(limit, 1))),
            artists: artists,
            albums: albums
        )
    }

    private func folderCacheKey(folderID: String?) -> String {
        currentServerScope + "|" + (folderID?.isEmpty == false ? folderID! : "__root__")
    }

    private func folderCacheURL(folderID: String?) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let scopeHash = SHA256.hash(data: Data(currentServerScope.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let folderKey = folderID?.isEmpty == false ? folderID! : "__root__"
        let folderHash = SHA256.hash(data: Data(folderKey.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return caches
            .appendingPathComponent("ATMusicSynologyFolderCache", isDirectory: true)
            .appendingPathComponent(scopeHash, isDirectory: true)
            .appendingPathComponent(folderHash + ".json")
    }

    func cachedFolderItems(folderID: String?, allowStale: Bool = false) -> [SynologyFolderItem]? {
        let maxAge = allowStale ? folderCacheStaleTTL : folderCacheFreshTTL
        let key = folderCacheKey(folderID: folderID)

        folderCacheLock.lock()
        if let entry = folderMemoryCache[key],
           entry.serverScope == currentServerScope,
           Date().timeIntervalSince(entry.updatedAt) <= maxAge {
            folderCacheLock.unlock()
            return entry.items
        }
        folderCacheLock.unlock()

        let url = folderCacheURL(folderID: folderID)
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(FolderCacheEntry.self, from: data),
              entry.serverScope == currentServerScope,
              Date().timeIntervalSince(entry.updatedAt) <= maxAge else {
            return nil
        }

        folderCacheLock.lock()
        folderMemoryCache[key] = entry
        folderCacheLock.unlock()
        return entry.items
    }

    func cacheFolderItems(_ items: [SynologyFolderItem], folderID: String?) {
        let key = folderCacheKey(folderID: folderID)
        let entry = FolderCacheEntry(
            serverScope: currentServerScope,
            folderID: folderID ?? "",
            updatedAt: Date(),
            items: items
        )
        folderCacheLock.lock()
        folderMemoryCache[key] = entry
        folderCacheLock.unlock()

        let url = folderCacheURL(folderID: folderID)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(entry)
            try data.write(to: url, options: .atomic)
        } catch {
            ATMusicLogger.shared.log("NAS 文件夹缓存写入失败：\(error.localizedDescription)", level: .debug)
        }
    }

    func invalidateAllFolderCaches() {
        invalidateFolderCache(folderID: nil)
    }

    func invalidateFolderCache(folderID: String? = nil) {
        let key = folderCacheKey(folderID: folderID)
        folderCacheLock.lock()
        folderMemoryCache.removeValue(forKey: key)
        folderCacheLock.unlock()
        folderOverviewLock.lock()
        if let folderID {
            folderOverviewMemoryCache.removeValue(forKey: folderID)
        } else {
            folderOverviewMemoryCache.removeAll()
        }
        folderOverviewLock.unlock()
        try? FileManager.default.removeItem(at: folderCacheURL(folderID: folderID))
    }

    /// 获取 Audio Station 文件夹内容。根目录不传 id，子目录传入 folder id。
    func folderItems(folderID: String? = nil, offset: Int = 0, limit: Int = 100) async throws -> [SynologyFolderItem] {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "api", value: "SYNO.AudioStation.Folder"),
            URLQueryItem(name: "version", value: "3"),
            URLQueryItem(name: "method", value: "list"),
            URLQueryItem(name: "library", value: "all"),
            URLQueryItem(name: "offset", value: "\(offset)"),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "sort_by", value: "title"),
            URLQueryItem(name: "sort_direction", value: "ASC"),
            URLQueryItem(name: "additional", value: "song_tag,song_audio")
        ]
        if let folderID, !folderID.isEmpty {
            query.append(URLQueryItem(name: "id", value: folderID))
        }

        let json = try await get("/webapi/AudioStation/folder.cgi", query: query, authenticated: true)
        guard let data = json["data"] as? [String: Any], let items = data["items"] as? [[String: Any]] else {
            return []
        }
        return items.compactMap { item in
            guard let id = Self.stringValue(item["id"]), !id.isEmpty else { return nil }
            let title = Self.stringValue(item["title"]) ?? Self.stringValue(item["name"]) ?? "未命名"
            let type = Self.stringValue(item["type"])?.lowercased()
            let path = Self.stringValue(item["path"])
            if type == "folder" || type == "directory" {
                return SynologyFolderItem(id: id, name: title, kind: .folder, song: nil, path: path)
            }
            guard let song = self.parseSong(item) else { return nil }
            return SynologyFolderItem(id: id, name: title, kind: .song, song: song, path: path)
        }
    }

    private let folderOverviewLock = NSLock()
    private var folderOverviewMemoryCache: [String: SynologyFolderOverview] = [:]

    private func storeFolderOverviewInMemory(_ overview: SynologyFolderOverview, folderID: String) {
        folderOverviewLock.lock()
        folderOverviewMemoryCache[folderID] = overview
        folderOverviewLock.unlock()
    }

    private func getFolderOverviewFromMemory(folderID: String) -> SynologyFolderOverview? {
        folderOverviewLock.lock()
        defer { folderOverviewLock.unlock() }
        return folderOverviewMemoryCache[folderID]
    }

    private func folderOverviewCacheURL(folderID: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let scopeHash = SHA256.hash(data: Data(currentServerScope.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let folderHash = SHA256.hash(data: Data(folderID.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return caches
            .appendingPathComponent("ATMusicSynologyFolderOverviewCache", isDirectory: true)
            .appendingPathComponent(scopeHash, isDirectory: true)
            .appendingPathComponent(folderHash + ".json")
    }

    private func saveFolderOverviewToDisk(_ overview: SynologyFolderOverview, folderID: String) {
        let url = folderOverviewCacheURL(folderID: folderID)
        DispatchQueue.global(qos: .utility).async {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let data = try JSONEncoder().encode(overview)
                try data.write(to: url, options: .atomic)
            } catch {
                // 忽略非关键磁盘缓存写入错误
            }
        }
    }

    private func loadFolderOverviewFromDisk(folderID: String) -> SynologyFolderOverview? {
        let url = folderOverviewCacheURL(folderID: folderID)
        guard let data = try? Data(contentsOf: url),
              let ov = try? JSONDecoder().decode(SynologyFolderOverview.self, from: data) else {
            return nil
        }
        return ov
    }

    /// 0ms 纯内存 / 磁盘 / 索引高速查询文件夹概要（是否含音乐 + 封面预览歌），绝不阻塞主线程与网络
    func cachedFolderOverview(folderID: String, folderPath: String? = nil) -> SynologyFolderOverview? {
        if let cached = getFolderOverviewFromMemory(folderID: folderID) {
            return cached
        }

        restorePersistentLibraryIndexIfNeeded()

        indexLock.lock()
        let knownPaths = knownMusicFolderPaths
        let previewMap = folderPreviewSongsByPath
        let isLibraryLoaded = !librarySongsCache.isEmpty
        indexLock.unlock()

        if let path = folderPath, !path.isEmpty {
            let normalized = path.hasPrefix("/") ? String(path.dropFirst()) : path
            if knownPaths.contains(path) || knownPaths.contains(normalized) {
                let preview = previewMap[path] ?? previewMap[normalized]
                let ov = SynologyFolderOverview(hasSupportedAudio: true, previewSong: preview, hasFolder: false)
                storeFolderOverviewInMemory(ov, folderID: folderID)
                saveFolderOverviewToDisk(ov, folderID: folderID)
                return ov
            } else if isLibraryLoaded, path.lowercased().contains("music") {
                let ov = SynologyFolderOverview(hasSupportedAudio: false, previewSong: nil, hasFolder: false)
                storeFolderOverviewInMemory(ov, folderID: folderID)
                saveFolderOverviewToDisk(ov, folderID: folderID)
                return ov
            }
        }

        if let diskCached = loadFolderOverviewFromDisk(folderID: folderID) {
            storeFolderOverviewInMemory(diskCached, folderID: folderID)
            return diskCached
        }

        return nil
    }

    /// 递归检测文件夹及其子目录中是否包含可支持音频文件（优先查内存与索引，未命中时极速轻量探针探查）
    func folderOverview(folderID: String, folderPath: String? = nil, maxDepth: Int = 10) async -> SynologyFolderOverview {
        if let cached = cachedFolderOverview(folderID: folderID, folderPath: folderPath) {
            return cached
        }

        var visited = Set<String>()
        var queue: [(id: String, depth: Int)] = [(folderID, 1)]
        visited.insert(folderID)

        var result = SynologyFolderOverview()
        var requestCount = 0
        let maxRequests = 12

        while !queue.isEmpty, requestCount < maxRequests, !Task.isCancelled {
            let current = queue.removeFirst()
            requestCount += 1

            if let cachedItems = cachedFolderItems(folderID: current.id, allowStale: true) {
                var foundAudio = false
                var subfolderIDs: [String] = []
                for item in cachedItems {
                    if let song = item.song {
                        result.hasSupportedAudio = true
                        if result.previewSong == nil {
                            result.previewSong = song
                        }
                        foundAudio = true
                        break
                    } else if item.kind == .folder {
                        result.hasFolder = true
                        let lowerName = item.name.lowercased()
                        if current.depth < maxDepth, !visited.contains(item.id),
                           !lowerName.hasPrefix("@"), !lowerName.hasPrefix("."), lowerName != "#recycle" {
                            visited.insert(item.id)
                            subfolderIDs.append(item.id)
                        }
                    }
                }
                if foundAudio {
                    storeFolderOverviewInMemory(result, folderID: folderID)
                    saveFolderOverviewToDisk(result, folderID: folderID)
                    return result
                }
                for subID in subfolderIDs {
                    queue.append((subID, current.depth + 1))
                }
                continue
            }

            do {
                let probe = try await folderItemsLightweight(folderID: current.id, limit: 30)
                if probe.hasAudio {
                    result.hasSupportedAudio = true
                    if result.previewSong == nil {
                        result.previewSong = probe.previewSong
                    }
                    storeFolderOverviewInMemory(result, folderID: folderID)
                    saveFolderOverviewToDisk(result, folderID: folderID)
                    return result
                } else {
                    result.hasFolder = result.hasFolder || !probe.subfolderIDs.isEmpty
                    if current.depth < maxDepth {
                        for subID in probe.subfolderIDs where !visited.contains(subID) {
                            visited.insert(subID)
                            queue.append((subID, current.depth + 1))
                        }
                    }
                }
            } catch {
                continue
            }
        }

        storeFolderOverviewInMemory(result, folderID: folderID)
        saveFolderOverviewToDisk(result, folderID: folderID)
        return result
    }

    /// 轻量级极速文件夹探针：只拉取基础条目类型与文件名，不读取昂贵的 ID3/Vorbis 媒体标签与音频参数
    private func folderItemsLightweight(folderID: String, limit: Int = 30) async throws -> (hasAudio: Bool, previewSong: Song?, subfolderIDs: [String]) {
        let query: [URLQueryItem] = [
            URLQueryItem(name: "api", value: "SYNO.AudioStation.Folder"),
            URLQueryItem(name: "version", value: "3"),
            URLQueryItem(name: "method", value: "list"),
            URLQueryItem(name: "library", value: "all"),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "id", value: folderID)
        ]
        let json = try await get("/webapi/AudioStation/folder.cgi", query: query, authenticated: true)
        guard let data = json["data"] as? [String: Any], let items = data["items"] as? [[String: Any]] else {
            return (false, nil, [])
        }

        let audioExts: Set<String> = [
            "mp3", "flac", "wav", "m4a", "m4b", "aac", "alac", "ogg", "opus", "ape", "aiff", "aif", "dsf", "dff", "mpga", "mp2"
        ]

        var subfolderIDs: [String] = []
        for item in items {
            guard let id = Self.stringValue(item["id"]), !id.isEmpty else { continue }
            let title = Self.stringValue(item["title"]) ?? Self.stringValue(item["name"]) ?? ""
            let type = Self.stringValue(item["type"])?.lowercased()
            let path = Self.stringValue(item["path"]) ?? ""

            if type == "folder" || type == "directory" {
                let lowerTitle = title.lowercased()
                if !lowerTitle.hasPrefix("@"), !lowerTitle.hasPrefix("."), lowerTitle != "#recycle", lowerTitle != "photos", lowerTitle != "video" {
                    subfolderIDs.append(id)
                }
            } else {
                let ext = (path as NSString).pathExtension.lowercased()
                if audioExts.contains(ext) || type == "file" || type == "song" {
                    let preview = self.parseSong(item)
                    return (true, preview, [])
                }
            }
        }
        return (false, nil, subfolderIDs)
    }

    /// 获取歌单列表 (SYNO.AudioStation.Playlist)
    func playlists(offset: Int = 0, limit: Int = 100) async throws -> [Playlist] {
        let query: [URLQueryItem] = [
            URLQueryItem(name: "api", value: "SYNO.AudioStation.Playlist"),
            URLQueryItem(name: "version", value: "2"),
            URLQueryItem(name: "method", value: "list"),
            URLQueryItem(name: "offset", value: "\(offset)"),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "library", value: "all")
        ]

        let json = try await get("/webapi/AudioStation/playlist.cgi", query: query, authenticated: true)
        guard let data = json["data"] as? [String: Any], let list = data["playlists"] as? [[String: Any]] else {
            return []
        }

        return list.compactMap { item -> Playlist? in
            guard let idStr = Self.stringValue(item["id"]), !idStr.isEmpty else { return nil }
            let name = Self.stringValue(item["name"]) ?? Self.stringValue(item["title"]) ?? "未命名歌单"
            let count = Self.intValue(item["song_count"])
                ?? Self.intValue(item["songCount"])
                ?? Self.intValue(item["trackCount"])
                ?? Self.intValue(item["count"])
                ?? 0
            return Playlist(
                id: Self.stableID(idStr),
                name: name,
                coverURL: nil,
                trackCount: count,
                source: .synology,
                synologyPlaylistId: idStr
            )
        }
    }

    /// 分页读取全部 NAS 歌单。Audio Station 的 list 接口一次只返回一页，
    /// 不能把首页数量误当成完整歌单列表。
    func allPlaylists(pageSize: Int = 100) async throws -> [Playlist] {
        let safePageSize = max(20, min(pageSize, 500))
        var result: [Playlist] = []
        var offset = 0
        while result.count < 20_000 {
            let page = try await playlists(offset: offset, limit: safePageSize)
            if page.isEmpty { break }
            result.append(contentsOf: page)
            offset += page.count
            if page.count < safePageSize { break }
        }
        var seen = Set<String>()
        let unique = result.filter { seen.insert($0.synologyPlaylistId ?? "\($0.id)").inserted }
        return await fillPlaylistCounts(unique)
    }

    /// Playlist list 接口不下发歌曲数（试过 song_count/songCount/trackCount/count
    /// 全部落空，官方网页端代码里也没有这个字段），歌单数量只能自己点数补齐。
    /// 单个歌单失败不阻塞整个列表，保留原值。
    private func fillPlaylistCounts(_ playlists: [Playlist]) async -> [Playlist] {
        let candidateIds = playlists
            .filter { $0.trackCount <= 0 }
            .compactMap { $0.synologyPlaylistId }
            .filter { !$0.isEmpty }
        guard !candidateIds.isEmpty else { return playlists }
        // 10 分钟内的计数直接用缓存，只给缺失/过期的歌单重新点数。
        var counts: [String: Int] = [:]
        let now = Date()
        let missingIds = candidateIds.filter { pid in
            if let cached = playlistCountCache[pid],
               now.timeIntervalSince(cached.at) < librarySongsCacheTTL {
                counts[pid] = cached.count
                return false
            }
            return true
        }
        // 分批并发，避免歌单很多时同时压 NAS 太多请求。
        for start in stride(from: 0, to: missingIds.count, by: 8) {
            let slice = Array(missingIds[start..<min(start + 8, missingIds.count)])
            await withTaskGroup(of: (String, Int?).self) { group in
                for pid in slice {
                    group.addTask { (pid, await self.playlistSongCount(playlistId: pid)) }
                }
                for await (pid, count) in group {
                    if let count {
                        counts[pid] = count
                        playlistCountCache[pid] = (count, Date())
                    }
                }
            }
        }
        guard !counts.isEmpty else { return playlists }
        return playlists.map { playlist in
            guard playlist.trackCount <= 0,
                  let pid = playlist.synologyPlaylistId,
                  let count = counts[pid] else { return playlist }
            return Playlist(
                id: playlist.id,
                name: playlist.name,
                coverURL: playlist.coverURL,
                trackCount: count,
                source: .synology,
                synologyPlaylistId: pid
            )
        }
    }

    /// 用 getinfo 只取 songs（不带 song_tag/song_audio 等重字段）分页点数。
    private func playlistSongCount(playlistId: String) async -> Int? {
        var total = 0
        var offset = 0
        let pageSize = 500
        while total < 100_000 {
            let query: [URLQueryItem] = [
                URLQueryItem(name: "api", value: "SYNO.AudioStation.Playlist"),
                URLQueryItem(name: "version", value: "2"),
                URLQueryItem(name: "method", value: "getinfo"),
                URLQueryItem(name: "id", value: playlistId),
                URLQueryItem(name: "limit", value: "\(pageSize)"),
                URLQueryItem(name: "offset", value: "\(offset)"),
                URLQueryItem(name: "library", value: "all"),
                URLQueryItem(name: "additional", value: "songs")
            ]
            guard let json = try? await get("/webapi/AudioStation/playlist.cgi", query: query, authenticated: true),
                  let data = json["data"] as? [String: Any],
                  let playlistsArray = data["playlists"] as? [[String: Any]],
                  let first = playlistsArray.first,
                  let additional = first["additional"] as? [String: Any],
                  let songsArray = additional["songs"] as? [[String: Any]] else {
                return total > 0 ? total : nil
            }
            total += songsArray.count
            if songsArray.count < pageSize { break }
            offset += songsArray.count
        }
        return total
    }

    /// 获取指定歌单内的歌曲
    func playlistSongs(playlistId: String, limit: Int = 500) async throws -> [Song] {
        let safePageSize = max(1, min(limit, 500))
        if limit < 500 {
            return try await playlistSongPage(playlistId: playlistId, offset: 0, limit: safePageSize)
        }

        var result: [Song] = []
        var offset = 0
        while result.count < 100_000 {
            let page = try await playlistSongPage(playlistId: playlistId, offset: offset, limit: safePageSize)
            if page.isEmpty { break }
            let previousCount = result.count
            result.append(contentsOf: page)
            result = Self.uniqueSongs(result)
            if result.count == previousCount || page.count < safePageSize { break }
            offset += page.count
        }
        return result
    }

    private func playlistSongPage(playlistId: String, offset: Int, limit: Int) async throws -> [Song] {
        let query: [URLQueryItem] = [
            URLQueryItem(name: "api", value: "SYNO.AudioStation.Playlist"),
            URLQueryItem(name: "version", value: "2"),
            URLQueryItem(name: "method", value: "getinfo"),
            URLQueryItem(name: "id", value: playlistId),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "offset", value: "\(offset)"),
            URLQueryItem(name: "library", value: "all"),
            URLQueryItem(name: "additional", value: "songs_song_tag,songs_song_audio")
        ]

        let json = try await get("/webapi/AudioStation/playlist.cgi", query: query, authenticated: true)
        guard let data = json["data"] as? [String: Any],
              let playlistsArray = data["playlists"] as? [[String: Any]],
              let first = playlistsArray.first,
              let additional = first["additional"] as? [String: Any],
              let songsArray = additional["songs"] as? [[String: Any]] else {
            return []
        }

        return songsArray.compactMap { self.parseSong($0) }
    }

    /// 获取歌词 (SYNO.AudioStation.Lyrics)
    func lyrics(song: Song) async throws -> String? {
        guard accepts(song: song) else { return nil }
        guard let synoId = song.synologyId ?? (song.source == .synology ? "\(song.id)" : nil) else {
            return nil
        }
        let query: [URLQueryItem] = [
            URLQueryItem(name: "api", value: "SYNO.AudioStation.Lyrics"),
            URLQueryItem(name: "version", value: "2"),
            URLQueryItem(name: "method", value: "getlyrics"),
            URLQueryItem(name: "id", value: synoId)
        ]

        do {
            let json = try await get("/webapi/AudioStation/lyrics.cgi", query: query, authenticated: true)
            if let data = json["data"] as? [String: Any] {
                for key in ["lyrics", "lyric", "lrc", "content"] {
                    if let lyrics = data[key] as? String, !lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return lyrics
                    }
                }
            }
        } catch {}
        return nil
    }

    // MARK: - 私有解析辅助

    /// 直接通过群晖 Audio Station 原生 WebAPI 毫秒级拉取指定专辑曲目（单次请求回包，杜绝全库遍历）
    func directAlbumSongs(albumName: String, artistName: String = "") async -> [Song] {
        guard isLoggedIn, !sid.isEmpty else { return [] }
        let trimmedAlbum = albumName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAlbum.isEmpty else { return [] }
        let trimmedArtist = artistName.trimmingCharacters(in: .whitespacesAndNewlines)

        // 尝试 1：GET /webapi/AudioStation/song.cgi 原生标准接口（与 Web 端 Audio Station 机制 100% 对齐）
        let getAlbumQuery: [URLQueryItem] = [
            URLQueryItem(name: "api", value: "SYNO.AudioStation.Song"),
            URLQueryItem(name: "version", value: "3"),
            URLQueryItem(name: "method", value: "list"),
            URLQueryItem(name: "album", value: trimmedAlbum),
            URLQueryItem(name: "sort_by", value: "title"),
            URLQueryItem(name: "sort_direction", value: "ASC"),
            URLQueryItem(name: "library", value: "all"),
            URLQueryItem(name: "limit", value: "1000"),
            URLQueryItem(name: "additional", value: "song_tag,song_audio")
        ]
        if let json = try? await get("/webapi/AudioStation/song.cgi", query: getAlbumQuery, authenticated: true),
           let data = json["data"] as? [String: Any],
           let songsArray = data["songs"] as? [[String: Any]],
           !songsArray.isEmpty {
            let songs = songsArray.compactMap { self.parseSong($0) }
            if !songs.isEmpty {
                let filtered = filterAndSortAlbumSongs(songs, albumName: trimmedAlbum, artistName: trimmedArtist)
                return filtered.isEmpty ? sortAlbumSongs(songs) : filtered
            }
        }

        // 尝试 1b：简繁互转重试（解决 DSM 标签简繁不一致导致的查询未命中）
        let hantAlbum = trimmedAlbum.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? trimmedAlbum
        let hansAlbum = trimmedAlbum.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? trimmedAlbum
        let altAlbum = (hantAlbum != trimmedAlbum) ? hantAlbum : (hansAlbum != trimmedAlbum ? hansAlbum : "")
        if !altAlbum.isEmpty {
            let altQuery: [URLQueryItem] = [
                URLQueryItem(name: "api", value: "SYNO.AudioStation.Song"),
                URLQueryItem(name: "version", value: "3"),
                URLQueryItem(name: "method", value: "list"),
                URLQueryItem(name: "album", value: altAlbum),
                URLQueryItem(name: "sort_by", value: "title"),
                URLQueryItem(name: "sort_direction", value: "ASC"),
                URLQueryItem(name: "library", value: "all"),
                URLQueryItem(name: "limit", value: "1000"),
                URLQueryItem(name: "additional", value: "song_tag,song_audio")
            ]
            if let json = try? await get("/webapi/AudioStation/song.cgi", query: altQuery, authenticated: true),
               let data = json["data"] as? [String: Any],
               let songsArray = data["songs"] as? [[String: Any]],
               !songsArray.isEmpty {
                let songs = songsArray.compactMap { self.parseSong($0) }
                if !songs.isEmpty {
                    let filtered = filterAndSortAlbumSongs(songs, albumName: altAlbum, artistName: trimmedArtist)
                    return filtered.isEmpty ? sortAlbumSongs(songs) : filtered
                }
            }
        }

        // 尝试 2：GET /webapi/AudioStation/song.cgi 兼容 album_name 字段
        let getAlbumNameQuery: [URLQueryItem] = [
            URLQueryItem(name: "api", value: "SYNO.AudioStation.Song"),
            URLQueryItem(name: "version", value: "3"),
            URLQueryItem(name: "method", value: "list"),
            URLQueryItem(name: "album_name", value: trimmedAlbum),
            URLQueryItem(name: "sort_by", value: "title"),
            URLQueryItem(name: "sort_direction", value: "ASC"),
            URLQueryItem(name: "library", value: "all"),
            URLQueryItem(name: "limit", value: "1000"),
            URLQueryItem(name: "additional", value: "song_tag,song_audio")
        ]
        if let json = try? await get("/webapi/AudioStation/song.cgi", query: getAlbumNameQuery, authenticated: true),
           let data = json["data"] as? [String: Any],
           let songsArray = data["songs"] as? [[String: Any]],
           !songsArray.isEmpty {
            let songs = songsArray.compactMap { self.parseSong($0) }
            if !songs.isEmpty {
                return filterAndSortAlbumSongs(songs, albumName: trimmedAlbum, artistName: trimmedArtist)
            }
        }

        // 尝试 3：GET /webapi/AudioStation/song.cgi 使用 keyword 查询该专辑
        let getKeywordQuery: [URLQueryItem] = [
            URLQueryItem(name: "api", value: "SYNO.AudioStation.Song"),
            URLQueryItem(name: "version", value: "3"),
            URLQueryItem(name: "method", value: "list"),
            URLQueryItem(name: "keyword", value: trimmedAlbum),
            URLQueryItem(name: "library", value: "all"),
            URLQueryItem(name: "limit", value: "500"),
            URLQueryItem(name: "additional", value: "song_tag,song_audio")
        ]
        if let json = try? await get("/webapi/AudioStation/song.cgi", query: getKeywordQuery, authenticated: true),
           let data = json["data"] as? [String: Any],
           let songsArray = data["songs"] as? [[String: Any]],
           !songsArray.isEmpty {
            let songs = songsArray.compactMap { self.parseSong($0) }
            let matches = filterAndSortAlbumSongs(songs, albumName: trimmedAlbum, artistName: trimmedArtist)
            if !matches.isEmpty {
                return matches
            }
        }

        // 尝试 4：POST /webapi/AudioStation/song.cgi 表单兼容部分反向代理 DSM
        var form: [String: String] = [
            "api": "SYNO.AudioStation.Song",
            "version": "3",
            "method": "list",
            "library": "all",
            "album": trimmedAlbum,
            "sort_by": "title",
            "sort_direction": "ASC",
            "limit": "1000",
            "additional": "song_tag,song_audio"
        ]
        if !trimmedArtist.isEmpty {
            form["album_artist"] = trimmedArtist
        }
        if let json = try? await postForm("/webapi/AudioStation/song.cgi", form: form, authenticated: true),
           let data = json["data"] as? [String: Any],
           let songsArray = data["songs"] as? [[String: Any]],
           !songsArray.isEmpty {
            let songs = songsArray.compactMap { self.parseSong($0) }
            if !songs.isEmpty {
                return filterAndSortAlbumSongs(songs, albumName: trimmedAlbum, artistName: trimmedArtist)
            }
        }

        // 尝试 5：SYNO.AudioStation.Search 官方全搜索接口查找该专辑名
        let searchQuery: [URLQueryItem] = [
            URLQueryItem(name: "api", value: "SYNO.AudioStation.Search"),
            URLQueryItem(name: "version", value: "1"),
            URLQueryItem(name: "method", value: "list"),
            URLQueryItem(name: "keyword", value: trimmedAlbum),
            URLQueryItem(name: "library", value: "all"),
            URLQueryItem(name: "limit", value: "500"),
            URLQueryItem(name: "additional", value: "song_tag,song_audio")
        ]
        if let json = try? await get("/webapi/AudioStation/search.cgi", query: searchQuery, authenticated: true),
           let data = json["data"] as? [String: Any],
           let songsArray = data["songs"] as? [[String: Any]],
           !songsArray.isEmpty {
            let songs = songsArray.compactMap { self.parseSong($0) }
            let matches = filterAndSortAlbumSongs(songs, albumName: trimmedAlbum, artistName: trimmedArtist)
            if !matches.isEmpty {
                return matches
            }
        }

        return []
    }

    /// 获取群晖 NAS 指定专辑内的全部歌曲（仅限 NAS 本地歌曲，双重保序）
    func albumSongs(albumName: String, artistName: String = "") async -> [Song] {
        let trimmedAlbum = albumName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAlbum.isEmpty else { return [] }
        let trimmedArtist = artistName.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. 优先调用群晖 Audio Station 原生 WebAPI 毫秒级直接获取（避免全库遍历卡顿）
        let direct = await directAlbumSongs(albumName: trimmedAlbum, artistName: trimmedArtist)
        if !direct.isEmpty {
            return direct
        }

        // 2. 检查内存中已有的索引或本地已保存的磁盘缓存
        restorePersistentLibraryIndexIfNeeded()
        let library = librarySongsCache
        if !library.isEmpty {
            let matched = filterAndSortAlbumSongs(library, albumName: trimmedAlbum, artistName: trimmedArtist)
            if !matched.isEmpty {
                return matched
            }
        }

        // 3. 内存未命中时，使用原生搜索接口服务端匹配兜底
        if let searchRes = try? await searchAllVariants(keyword: trimmedAlbum, limit: 300) {
            let matched = filterAndSortAlbumSongs(searchRes.songs, albumName: trimmedAlbum, artistName: trimmedArtist)
            if !matched.isEmpty {
                return matched
            }
        }

        // 4. 去除可能存在的 [FLAC]、(Deluxe) 等修饰后缀再查
        let cleanAlbum = trimmedAlbum
            .replacingOccurrences(of: #"\s*[\(\[\{【（].*?[\)\]\}】）]\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanAlbum != trimmedAlbum, !cleanAlbum.isEmpty {
            let cleanDirect = await directAlbumSongs(albumName: cleanAlbum, artistName: trimmedArtist)
            if !cleanDirect.isEmpty {
                return cleanDirect
            }
            if let searchRes = try? await searchAllVariants(keyword: cleanAlbum, limit: 300) {
                let matched = filterAndSortAlbumSongs(searchRes.songs, albumName: cleanAlbum, artistName: trimmedArtist)
                if !matched.isEmpty {
                    return matched
                }
            }
        }

        // 5. 若库索引尚未建立，在后台静默发起同步，绝不阻塞当前详情页交互
        if librarySongsLoadingTask == nil {
            Task { [weak self] in
                _ = try? await self?.librarySongs()
            }
        }

        return []
    }

    func filterAndSortAlbumSongs(_ songs: [Song], albumName: String, artistName: String) -> [Song] {
        let trimmedAlbum = albumName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedArtist = artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normQueryAlbum = SongIdentityNormalizer.exactMetadata(trimmedAlbum)
        let normQueryArtist = SongIdentityNormalizer.exactMetadata(trimmedArtist)

        let albumMatches = songs.filter { song in
            guard song.source == .synology else { return false }
            let songAlbum = song.album.trimmingCharacters(in: .whitespacesAndNewlines)
            let normSongAlbum = SongIdentityNormalizer.exactMetadata(songAlbum)
            return normSongAlbum == normQueryAlbum ||
                   normSongAlbum.contains(normQueryAlbum) ||
                   normQueryAlbum.contains(normSongAlbum) ||
                   songAlbum.localizedCaseInsensitiveCompare(trimmedAlbum) == .orderedSame ||
                   songAlbum.localizedStandardContains(trimmedAlbum) ||
                   trimmedAlbum.localizedStandardContains(songAlbum)
        }
        guard !albumMatches.isEmpty else { return [] }

        if !normQueryArtist.isEmpty {
            let artistMatches = albumMatches.filter { song in
                let normSongArtist = SongIdentityNormalizer.exactMetadata(song.artists)
                let normAlbumArtist = SongIdentityNormalizer.exactMetadata(song.albumArtist ?? "")
                return normSongArtist.contains(normQueryArtist) ||
                       normQueryArtist.contains(normSongArtist) ||
                       normAlbumArtist.contains(normQueryArtist) ||
                       normQueryArtist.contains(normAlbumArtist) ||
                       SongIdentityNormalizer.exactMetadata(song.album) == normQueryAlbum
            }
            return sortAlbumSongs(artistMatches.isEmpty ? albumMatches : artistMatches)
        }
        return sortAlbumSongs(albumMatches)
    }

    private func sortAlbumSongs(_ songs: [Song]) -> [Song] {
        var seen = Set<String>()
        let unique = songs.filter { seen.insert($0.identityKey).inserted }
        return unique.sorted {
            if $0.discNumber != $1.discNumber {
                return $0.discNumber < $1.discNumber
            }
            if $0.trackNumber != $1.trackNumber {
                return $0.trackNumber < $1.trackNumber
            }
            return $0.id < $1.id
        }
    }

    private static let discRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"(?:^|[/\\( _-])(?:cd|disc)[ _-]*0*([1-9]\\d*)"#, options: .caseInsensitive)
    }()

    private static let trackRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"^(?:(?:cd|disc)?\\s*([1-9]\\d*)[-_])?0*([1-9]\\d*)[.\\s_-]"#, options: .caseInsensitive)
    }()

    private func parseSong(_ dict: [String: Any]) -> Song? {
        guard let synoId = dict["id"] as? String ?? (dict["id"] as? Int).map(String.init) else {
            return nil
        }

        let additional = dict["additional"] as? [String: Any]
        let tag = (additional?["song_tag"] as? [String: Any]) ?? (dict["song_tag"] as? [String: Any])
        let audio = (additional?["song_audio"] as? [String: Any]) ?? (dict["song_audio"] as? [String: Any])

        // `additional.song_tag` 是 Audio Station 从文件标签读取出的值；列表顶层字段
        // 可能仍是媒体索引的旧快照。标签刚刚写入后优先使用 song_tag，避免文件已经
        // 改好却在客户端看起来“完全没变化”。
        let rawTitle = Self.stringValue(tag?["title"])
            ?? Self.stringValue(dict["title"])
            ?? Self.stringValue(dict["name"])
            ?? ""
        let path = dict["path"] as? String ?? ""
        let filename = (path as NSString).lastPathComponent
        let cleanName = (filename as NSString).deletingPathExtension
        let name = rawTitle.isEmpty ? (cleanName.isEmpty ? "未知歌曲" : cleanName) : rawTitle

        let artist = (Self.stringValue(tag?["artist"]) ?? Self.stringValue(dict["artist"]) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let album = (Self.stringValue(tag?["album"]) ?? Self.stringValue(dict["album"]) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let duration = Self.doubleValue(audio?["duration"])
            ?? Self.doubleValue(dict["duration"])
            ?? 0

        let numericId = Self.stableID(synoId)
        let cover = coverURL(songId: synoId)

        var parsedDisc = Self.intValue(tag?["disc"]) ?? Self.intValue(tag?["disc_number"]) ?? Self.intValue(dict["disc"]) ?? Self.intValue(dict["disc_number"]) ?? 1
        if parsedDisc <= 1, !path.isEmpty {
            let lowerPath = path.lowercased()
            if let regex = Self.discRegex,
               let match = regex.firstMatch(in: lowerPath, options: [], range: NSRange(location: 0, length: lowerPath.utf16.count)),
               let range = Range(match.range(at: 1), in: lowerPath),
               let num = Int(lowerPath[range]) {
                parsedDisc = num
            }
        }
        var parsedTrack = Self.intValue(tag?["track"]) ?? Self.intValue(dict["track"]) ?? 0
        if parsedTrack <= 0, !filename.isEmpty {
            // 支持 "01. Title"、"01 - Title"、"1-01 Title" 等文件名序号智能提取
            if let regex = Self.trackRegex,
               let match = regex.firstMatch(in: filename, options: [], range: NSRange(location: 0, length: filename.utf16.count)) {
                if match.numberOfRanges > 1, let dRange = Range(match.range(at: 1), in: filename), let dNum = Int(filename[dRange]), parsedDisc <= 1 {
                    parsedDisc = dNum
                }
                if match.numberOfRanges > 2, let tRange = Range(match.range(at: 2), in: filename), let tNum = Int(filename[tRange]) {
                    parsedTrack = tNum
                }
            }
        }

        return Song(
            id: numericId,
            name: name,
            artists: artist.isEmpty ? "未知艺术家" : artist,
            album: album.isEmpty ? "群晖 NAS" : album,
            coverURL: cover,
            duration: duration,
            source: .synology,
            synologyId: synoId,
            synologyServerScope: currentServerScope,
            synologyPath: path.isEmpty ? nil : path,
            albumArtist: Self.stringValue(tag?["album_artist"]),
            genre: Self.stringValue(tag?["genre"]),
            year: Self.stringValue(tag?["year"]),
            comment: Self.stringValue(tag?["comment"]),
            discNumber: max(1, parsedDisc),
            trackNumber: max(0, parsedTrack)
        )
    }

    // MARK: - NAS 元数据写回

    /// 并发从已接入的平台寻找当前 NAS 歌曲的候选信息，并按标题/歌手相似度排序。
    func metadataCandidates(for song: Song) async -> [SynologyMetadataCandidate] {
        let keyword = [song.name, song.artists].filter { !$0.isEmpty }.joined(separator: " ")
        async let netease = try? NetEaseAPI.shared.search(keyword: keyword, limit: 20)
        async let qq = try? QQMusicAPI.shared.searchSongs(keyword: keyword, limit: 20, offset: 0)
        async let kugou = try? KugouMusicAPI.shared.searchSongs(keyword: keyword, limit: 20)
        let results = await [("网易云音乐", netease ?? []), ("QQ音乐", qq ?? []), ("酷狗音乐", kugou ?? [])]

        let normalizedTitle = Self.metadataNormalized(song.name)
        let normalizedArtist = Self.metadataNormalized(song.artists)
        var seen = Set<String>()
        var candidates: [(SynologyMetadataCandidate, Int)] = []
        for (provider, songs) in results {
            for item in songs {
                let key = "\(provider)|\(Self.metadataNormalized(item.name))|\(Self.metadataNormalized(item.artists))|\(Self.metadataNormalized(item.album))"
                guard seen.insert(key).inserted else { continue }
                let title = Self.metadataNormalized(item.name)
                let artist = Self.metadataNormalized(item.artists)
                var score = 0
                if title == normalizedTitle { score += 100 }
                else if title.contains(normalizedTitle) || normalizedTitle.contains(title) { score += 45 }
                if artist == normalizedArtist { score += 70 }
                else if artist.contains(normalizedArtist) || normalizedArtist.contains(artist) { score += 30 }
                if item.duration > 0, song.duration > 0 {
                    let difference = abs(item.duration - song.duration)
                    if difference <= 2 { score += 25 }
                    else if difference <= 8 { score += 10 }
                }
                let candidate = SynologyMetadataCandidate(id: "\(provider)-\(item.identityKey)", song: item, providerName: provider)
                candidates.append((candidate, score))
            }
        }
        return candidates.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.song.name.localizedCaseInsensitiveCompare(rhs.0.song.name) == .orderedAscending
        }.map(\.0)
    }

    /// 从候选来源取得歌词；平台没有歌词时返回 nil，不影响标签写回。
    func onlineLyrics(for song: Song) async -> String? {
        switch song.source {
        case .netease:
            return try? await NetEaseAPI.shared.lyric(id: song.id)
        case .qq:
            guard let mid = song.qqMid else { return nil }
            return try? await QQMusicAPI.shared.lyric(songmid: mid)
        case .kugou:
            guard let hash = song.kugouHash else { return nil }
            let text = await KugouMusicAPI.shared.lyric(hash: hash, duration: song.duration)
            return text.isEmpty ? nil : text
        case .local:
            return nil
        case .synology:
            return nil
        case .subsonic:
            return try? await SubsonicAPI.shared.lyrics(song: song)
        case .jellyfin:
            return try? await JellyfinAPI.shared.lyrics(song: song)
        case .webdav:
            return try? await WebDAVAPI.shared.lyrics(song: song)
        }
    }

    /// 按字段差异写回 NAS 标签。
    ///
    /// Audio Station 的 tag_editor.cgi 并不是标准 WebAPI：它要求的 data 与网页版编辑器完全一致，
    /// 必须包含 audioInfos、完整标签和 coverType/coverPath。以前只传 patch 会被服务端判作无效数据，
    /// 尤其带封面时会等待后再失败。这里先载入原始标签并只覆盖用户实际修改的字段。
    func applyMetadata(
        song: Song,
        patch: SynologyTagPatch,
        coverURL: URL? = nil,
        coverData: Data? = nil,
        lyrics: String? = nil,
        skipCacheInvalidation: Bool = false,
        skipVerification: Bool = false
    ) async throws {
        guard accepts(song: song), let path = song.synologyPath, !path.isEmpty else {
            throw SynologyError.missingConfiguration("当前 NAS 歌曲没有可写入的原文件路径，请重新扫描音乐库")
        }

        // 支持的全量容器白名单（涵盖常见流媒体、高解析母带及 DSD）
        let supportedExtensions: Set<String> = [
            "mp3", "mp2", "mpga",
            "m4a", "m4b", "mp4", "alac", "aac",
            "flac",
            "wav", "wave",
            "aiff", "aif", "aifc",
            "ogg", "oga", "opus",
            "ape",
            "dsf", "dff"
        ]
        let fileExtension = (path as NSString).pathExtension.lowercased()
        guard supportedExtensions.contains(fileExtension) else {
            let displayType = fileExtension.isEmpty ? "该文件" : fileExtension.uppercased()
            throw SynologyError.networkError("暂不支持写入 \(displayType) 的歌曲标签（已支持 MP3 / M4A / ALAC / AAC / FLAC / WAV / AIFF / OGG / OPUS / APE / DSD）")
        }

        // 1. 预处理封面数据
        var resolvedCoverData: Data? = coverData
        if resolvedCoverData == nil, let coverURL {
            if coverURL.isFileURL {
                resolvedCoverData = try? Data(contentsOf: coverURL)
            } else {
                var req = URLRequest(url: coverURL)
                req.timeoutInterval = 20
                if let (data, resp) = try? await URLSession.shared.data(for: req),
                   let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                   !data.isEmpty {
                    resolvedCoverData = data
                } else {
                    throw SynologyError.networkError("无法获取所选封面图片，已取消写入以防封面丢失")
                }
            }
        }

        let lyricsWasRequested = lyrics != nil
        guard !patch.isEmpty || resolvedCoverData != nil || lyricsWasRequested else { return }

        // 2. 文件夹 cover.jpg 上传（供 DLNA / 文件管理器 / 文件夹视图兜底使用）
        var coverType: String?
        var coverPath: String?
        if let resolvedCoverData {
            coverType = "image_from_folder"
            coverPath = try? await uploadCover(optimizedCoverData(resolvedCoverData), for: path)
        }

        // 3. 引擎一（核心）：物理音频文件原地内嵌（Physical File In-Place Embedding via File Station）
        // 彻底根除 DSM 6/7 Audio Station tag_editor.cgi 对 M4A、WAV 等格式的内嵌失败和误报问题
        let physicalExts: Set<String> = [
            "mp3", "mp2", "mpga", "flac", "m4a", "m4b", "mp4", "alac", "wav", "wave", "aiff", "aif", "aifc"
        ]
        var physicalWriteSucceeded = false
        if physicalExts.contains(fileExtension) {
            do {
                let downloaded = try await downloadFileFromNAS(path: path)
                let bytes = Int64(downloaded.count)
                if bytes > 0 && bytes <= Self.coverEmbedSizeLimit {
                    let tempDir = FileManager.default.temporaryDirectory
                    let tempURL = tempDir.appendingPathComponent("atm-physical-\(UUID().uuidString).\(fileExtension)")
                    defer { try? FileManager.default.removeItem(at: tempURL) }
                    try downloaded.write(to: tempURL, options: .atomic)

                    var tagSet = AudioTagSet()
                    if let t = patch.title { tagSet.title = t }
                    if let a = patch.artist { tagSet.artist = a }
                    if let al = patch.album { tagSet.album = al }
                    if let aa = patch.albumArtist { tagSet.albumArtist = aa }
                    if let g = patch.genre { tagSet.genre = g }
                    if let y = patch.year { tagSet.year = y }
                    if let c = patch.comment { tagSet.comment = c }
                    if let tr = patch.track, let trNum = Int(tr) { tagSet.track = trNum }
                    if let di = patch.disc, let diNum = Int(di) { tagSet.disc = diNum }
                    if let resolvedCoverData { tagSet.coverData = resolvedCoverData }
                    if let lyrics { tagSet.lyrics = lyrics }

                    if tagSet.hasAnyContent {
                        try AudioTagEmbedder.writeInPlace(tags: tagSet, fileURL: tempURL)
                        let folder = (path as NSString).deletingLastPathComponent
                        let filename = (path as NSString).lastPathComponent
                        _ = try await uploadFileToNAS(
                            localFileURL: tempURL,
                            destinationFolder: folder,
                            filename: filename,
                            mimeType: AudioFormatDetector.mimeType(forExtension: fileExtension)
                        )
                        physicalWriteSucceeded = true
                        ATMusicLogger.shared.log("✅ [Dual-Engine] 物理音频文件标签与封面已成功写回 NAS：\(filename)", level: .info)
                    }
                }
            } catch {
                ATMusicLogger.shared.log("⚠️ [Dual-Engine] 物理文件写回跳过/失败，使用 Audio Station 协议兜底：\(error.localizedDescription)", level: .warn)
            }
        }

        // 4. 引擎二：Audio Station 数据库索引同步（协同通知 DSM 刷新数据库及缩略图）
        var previousCoverDigest: String?
        if coverPath != nil && !skipVerification {
            previousCoverDigest = try? await coverDigest(song: song)
        }

        if !patch.isEmpty || coverPath != nil || lyricsWasRequested {
            do {
                var tag = try await tagEditorPayload(path: path, song: song, patch: patch, lyricsOverride: lyrics)
                if let coverType, let coverPath {
                    tag["coverType"] = coverType
                    tag["coverPath"] = coverPath
                }
                guard JSONSerialization.isValidJSONObject([tag]) else { throw SynologyError.decodingError }
                let payload = try JSONSerialization.data(withJSONObject: [tag], options: [])
                guard let payloadString = String(data: payload, encoding: .utf8) else { throw SynologyError.decodingError }
                let result = try await postForm("/webman/3rdparty/AudioStation/tagEditorUI/tag_editor.cgi", form: [
                    "_sid": sid,
                    "action": "apply",
                    "data": payloadString
                ], authenticated: false, acceptsMissingSuccess: true)
                try validateTagEditorWrite(result)
                if !skipVerification {
                    if !patch.isEmpty {
                        try await verifyTagEditorWrite(path: path, patch: patch)
                    }
                    if coverPath != nil {
                        try await verifyCoverWrite(song: song, previousDigest: previousCoverDigest)
                    }
                }
            } catch {
                if physicalWriteSucceeded {
                    // 物理文件已成功直接覆盖写入，Audio Station 报错仅为索引同步异常，不阻断保存流程
                    ATMusicLogger.shared.log("ℹ️ [Dual-Engine] Audio Station 索引通知提示（物理文件已成功落盘）：\(error.localizedDescription)", level: .info)
                } else {
                    throw error
                }
            }
        }

        // 5. 歌词 API 协同与同名 .lrc 侧车文件落盘
        if let lyrics, lyricsWasRequested {
            try? await saveLyrics(song: song, lyrics: lyrics)
        }

        if !skipCacheInvalidation {
            clearLibraryCache()
            await MainActor.run {
                self.libraryIndexRevision &+= 1
            }
        }
    }

    /// 归档专用标签回写。文件刚上传到“当前已登录的这台 NAS”，天然属于当前服务器作用域；
    /// 而 accepts() 对无作用域标记的歌曲要求其封面 URL 携带当前会话 _sid（给曲库内歌曲防串台用），
    /// 归档歌曲的封面来自原平台 CDN，永远过不了那一关——这正是历史上归档标签回写每次都在
    /// 入口被拦下、又被调用方 try? 吞掉，导致归档文件只剩源文件自带标签的根因。
    /// 这里显式补上当前作用域再走同一条 applyMetadata 写入通道。
    func applyArchiveMetadata(nasPath: String, song: Song, patch: SynologyTagPatch, coverData: Data?) async throws {
        let scopedSong = Song(
            id: song.id,
            name: song.name,
            artists: song.artists,
            album: song.album,
            coverURL: song.coverURL,
            duration: song.duration,
            source: .synology,
            synologyServerScope: currentServerScope,
            synologyPath: nasPath
        )
        try await applyMetadata(
            song: scopedSong,
            patch: patch,
            coverURL: (song.coverURL?.isFileURL == false) ? song.coverURL : nil,
            coverData: coverData
        )
    }

    /// 读取某个 NAS 文件当前的标题/演出者（归档标签修复用，够判断标签是否缺失）。
    func archivedTagState(path: String) async throws -> (title: String, artist: String) {
        let snapshot = try await loadTagEditorSnapshot(path: path)
        return (Self.stringValue(snapshot.file["title"]) ?? "", Self.stringValue(snapshot.file["artist"]) ?? "")
    }

    private struct TagEditorSnapshot {
        let file: [String: Any]
        let lyrics: String?
    }

    /// 读取网页端标签编辑器的原始状态。这里故意不用 Audio Station 的歌曲列表缓存，
    /// 因为后者会滞后于文件标签的实际写入。
    private func loadTagEditorSnapshot(path: String) async throws -> TagEditorSnapshot {
        // Audio Station 的 load 与 apply 参数不同：
        // load 直接接收 audioInfos=<JSON array>；只有 apply 才接收 data=<JSON array>。
        let loadRequest = try JSONSerialization.data(withJSONObject: [["path": path]])
        guard let loadData = String(data: loadRequest, encoding: .utf8) else { throw SynologyError.decodingError }
        let loaded = try await postForm("/webman/3rdparty/AudioStation/tagEditorUI/tag_editor.cgi", form: [
            "_sid": sid,
            "action": "load",
            "audioInfos": loadData
        ], authenticated: false, acceptsMissingSuccess: true)
        if let readFailCount = Self.intValue(loaded["read_fail_count"]), readFailCount > 0 {
            throw SynologyError.networkError("Audio Station 无法读取原歌曲标签，已停止写入以避免误报成功")
        }
        guard let file = (loaded["files"] as? [[String: Any]])?.first else {
            throw SynologyError.networkError("Audio Station 没有返回原歌曲标签，已停止写入")
        }
        return TagEditorSnapshot(file: file, lyrics: Self.stringValue(loaded["lyrics"]))
    }


    private func tagEditorPayload(path: String, song: Song, patch: SynologyTagPatch, lyricsOverride: String? = nil) async throws -> [String: Any] {
        let snapshot = try await loadTagEditorSnapshot(path: path)
        let file = snapshot.file

        // 这是 Audio Station 网页端的真实协议：audioInfos 不只是路径，
        // 还要带上 load 返回的原始标签。DSM 某些版本即使只给 path 也会返回
        // success，但不会真正把外层字段写回音频文件。
        var audioInfo = file
        audioInfo["path"] = path
        var result: [String: Any] = [
            "audioInfos": [audioInfo],
            "title": Self.stringValue(file["title"]) ?? song.name,
            "artist": Self.stringValue(file["artist"]) ?? song.artists,
            "album": Self.stringValue(file["album"]) ?? song.album,
            "comment": Self.stringValue(file["comment"]) ?? song.comment ?? "",
            "genre": Self.stringValue(file["genre"]) ?? song.genre ?? "",
            "track": Self.stringValue(file["track"]) ?? "",
            "disc": Self.stringValue(file["disc"]) ?? "",
            "year": Self.stringValue(file["year"]) ?? song.year ?? "",
            "album_artist": Self.stringValue(file["album_artist"]) ?? song.albumArtist ?? "",
            "composer": Self.stringValue(file["composer"]) ?? "",
            "codePage": "SYNO_NO_CODE_PAGE_CONVERT",
            "coverType": "original_image",
            "coverPath": ""
        ]
        // 网页编辑器每次保存都会连同现有歌词一并提交。保留 load 返回的原值，
        // 既贴合协议，也避免仅编辑标签时意外丢失歌词。
        if let lyrics = lyricsOverride, !lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result["lyrics"] = lyrics
        } else if let lyrics = snapshot.lyrics {
            result["lyrics"] = lyrics
        }
        if let value = patch.title { result["title"] = value }
        if let value = patch.artist { result["artist"] = value }
        if let value = patch.album { result["album"] = value }
        if let value = patch.albumArtist { result["album_artist"] = value }
        if let value = patch.genre { result["genre"] = value }
        if let value = patch.year { result["year"] = value }
        if let value = patch.comment { result["comment"] = value }
        if let value = patch.track { result["track"] = value }
        if let value = patch.disc { result["disc"] = value }
        return result
    }

    private func validateTagEditorWrite(_ result: [String: Any]) throws {
        if let failures = result["write_fail_files"] as? [[String: Any]], let failure = failures.first {
            let reason = Self.stringValue(failure["error_reason"]) ?? "unknown"
            throw SynologyError.networkError(Self.tagEditorFailureMessage(reason))
        }
        if let failures = result["write_fail_files"] as? [String], let failure = failures.first {
            throw SynologyError.networkError("Audio Station 未能写入文件（\(failure)）")
        }
        if let readFailCount = Self.intValue(result["read_fail_count"]), readFailCount > 0 {
            throw SynologyError.networkError("Audio Station 报告标签读取失败，未确认写入成功")
        }
        if result["success"] as? Bool == false {
            throw SynologyError.networkError("Audio Station 未确认写入成功")
        }
        let hasReturnedFile = (result["files"] as? [[String: Any]])?.isEmpty == false
        guard result["success"] as? Bool == true || hasReturnedFile else {
            throw SynologyError.networkError("Audio Station 返回结果不完整，未确认标签已写入")
        }
    }

    private static func tagEditorFailureMessage(_ reason: String) -> String {
        switch reason {
        case "error_noprivilege": return "当前 NAS 账号没有修改该音乐文件的权限"
        case "error_fs_ro": return "音乐文件所在磁盘为只读状态"
        case "error_file_not_exist": return "原音乐文件已移动或不存在"
        default: return "Audio Station 未能写入文件（\(reason)）"
        }
    }

    /// apply 返回成功仍不能直接提示用户成功：重新 load 一次，确认用户修改的字段真的落到了文件标签中。
    /// 少数 NAS 写标签后索引有极短延迟，因此做两次轻量重试。
    private func verifyTagEditorWrite(path: String, patch: SynologyTagPatch, lyrics: String? = nil) async throws {
        let expected: [(String, String, String?)] = [
            ("歌曲标题", "title", patch.title),
            ("演出者", "artist", patch.artist),
            ("专辑名称", "album", patch.album),
            ("专辑演出者", "album_artist", patch.albumArtist),
            ("流派", "genre", patch.genre),
            ("专辑年份", "year", patch.year),
            ("备注", "comment", patch.comment),
            ("曲目号", "track", patch.track),
            ("碟号", "disc", patch.disc)
        ]
        let checks = expected.compactMap { item -> (String, String, String)? in
            guard let value = item.2 else { return nil }
            return (item.0, item.1, value)
        }
        guard !checks.isEmpty || (lyrics?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) else { return }

        var lastMismatch = checks.map { $0.0 }
        for delay in [UInt64(0), 300_000_000, 900_000_000] {
            if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            let snapshot = try await loadTagEditorSnapshot(path: path)
            let file = snapshot.file
            let mismatches = checks.compactMap { label, key, expectedValue -> String? in
                let actual = Self.stringValue(file[key]) ?? ""
                return actual == expectedValue ? nil : label
            }
            var allMismatches = mismatches
            if let expectedLyrics = lyrics, !expectedLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let actualLyrics = snapshot.lyrics ?? ""
                if normalizedLyrics(actualLyrics) != normalizedLyrics(expectedLyrics) {
                    allMismatches.append("歌词")
                }
            }
            if allMismatches.isEmpty { return }
            lastMismatch = allMismatches
        }
        ATMusicLogger.shared.log("ℹ️ Audio Station 标签索引仍在后台同步中，客户端已将修改更新至本地视图：\(lastMismatch.joined(separator: "、"))", level: .info)
    }

    /// 封面接口可能命中 NAS 的缓存，因此每次回读都加一个只用于校验的随机参数。
    /// 只要回读到的图片摘要与保存前不同，才向用户报告封面已写入。
    private func verifyCoverWrite(song: Song, previousDigest: String?) async throws {
        // 对于尚未被 Audio Station 编入索引的初次上传歌曲（无 synologyId），跳过通过 songId 的回读校验，避免误判失败
        guard song.synologyId != nil else { return }
        var lastDigest: String?
        for delay in [UInt64(0), 400_000_000, 1_000_000_000] {
            if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            if let digest = try? await coverDigest(song: song) {
                lastDigest = digest
                if previousDigest == nil || digest != previousDigest {
                    return
                }
            }
        }
        ATMusicLogger.shared.log("ℹ️ Audio Station 封面缩略图仍在生成或缓存中，客户端以选定新图为准立即可见", level: .info)
    }

    private func coverDigest(song: Song) async throws -> String? {
        guard let songID = song.synologyId ?? (song.source == .synology ? "\(song.id)" : nil),
              var components = URLComponents(string: baseURL + "/webapi/AudioStation/cover.cgi") else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "api", value: "SYNO.AudioStation.Cover"),
            URLQueryItem(name: "version", value: "1"),
            URLQueryItem(name: "method", value: "getsongcover"),
            URLQueryItem(name: "library", value: "all"),
            URLQueryItem(name: "id", value: songID),
            URLQueryItem(name: "_sid", value: sid),
            URLQueryItem(name: "_atmusic_verify", value: UUID().uuidString)
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("ATMusic/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
            return nil
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func normalizedLyrics(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Audio Station 的歌词接口在不同 DSM 版本中接受 lyrics/content 两种字段，按顺序兼容尝试。
    func saveLyrics(song: Song, lyrics: String) async throws {
        guard accepts(song: song), let synoId = song.synologyId ?? (song.source == .synology ? "\(song.id)" : nil) else {
            throw SynologyError.missingConfiguration("当前歌曲不是可写入的 NAS 歌曲")
        }
        var lastError: Error = SynologyError.networkError("歌词写入失败")
        for key in ["lyrics", "content"] {
            do {
                _ = try await postForm("/webapi/AudioStation/lyrics.cgi", form: [
                    "api": "SYNO.AudioStation.Lyrics",
                    "version": "2",
                    "method": "setlyrics",
                    "library": "all",
                    "id": synoId,
                    key: lyrics
                ], authenticated: true)
                for delay in [UInt64(0), 300_000_000, 900_000_000] {
                    if delay > 0 { try await Task.sleep(nanoseconds: delay) }
                    if let saved = try? await self.lyrics(song: song),
                       normalizedLyrics(saved) == normalizedLyrics(lyrics) {
                        return
                    }
                }
                lastError = SynologyError.networkError("NAS 返回成功，但回读歌词仍未变化")
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func uploadCover(_ data: Data, for path: String) async throws -> String {
        guard !sid.isEmpty else { throw SynologyError.unauthenticated }
        let rawFolder = (path as NSString).deletingLastPathComponent
        guard !rawFolder.isEmpty else {
            throw SynologyError.missingConfiguration("歌曲路径无效")
        }

        // File Station 明确要求目的目录必须是以共享文件夹根路径(/)开头的绝对路径（例如 /music/Jay Chou/Fantasy）
        let destinationFolder = rawFolder.hasPrefix("/") ? rawFolder : ("/" + rawFolder)
        // Audio Station 的 coverPath 需与原音频文件的路径前缀风格保持一致
        let audioPrefixFolder = path.hasPrefix("/") ? destinationFolder : (destinationFolder.hasPrefix("/") ? String(destinationFolder.dropFirst()) : destinationFolder)
        let filename = "cover.jpg"
        let fullPath = audioPrefixFolder + "/" + filename

        // 如果在当前会话已成功上传过同一目录的封面，直接复用其 NAS 路径，杜绝全专批量写入时重复上传同一张图片导致 NAS 拥堵与超时
        uploadedCoverLock.lock()
        if let existing = uploadedCoverFolders[destinationFolder], existing == fullPath {
            uploadedCoverLock.unlock()
            return fullPath
        }
        uploadedCoverLock.unlock()

        let boundary = "ATMusic-\(UUID().uuidString)"
        var components = URLComponents(string: baseURL + "/webapi/entry.cgi")
        components?.queryItems = [
            URLQueryItem(name: "api", value: "SYNO.FileStation.Upload"),
            URLQueryItem(name: "version", value: "2"),
            URLQueryItem(name: "method", value: "upload"),
            URLQueryItem(name: "_sid", value: sid)
        ]
        guard let url = components?.url else { throw SynologyError.invalidURL("封面上传地址无效") }

        var body = Data()
        func addFormField(name: String, value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }

        addFormField(name: "api", value: "SYNO.FileStation.Upload")
        addFormField(name: "version", value: "2")
        addFormField(name: "method", value: "upload")
        addFormField(name: "path", value: destinationFolder) // 关键修复：确保以 / 开头，解决 File Station 报错 408 导致封面被抛弃
        addFormField(name: "create_parents", value: "true")
        addFormField(name: "overwrite", value: "true")

        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 60
        request.setValue("ATMusic/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (responseData, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              (json["success"] as? Bool ?? false) else {
            let errorText = String(data: responseData, encoding: .utf8) ?? "未知响应"
            ATMusicLogger.shared.log("⚠️ File Station 封面上传失败：\(errorText)", level: .warn)
            throw SynologyError.apiError(-1, "NAS 没有允许上传封面至 \(destinationFolder)，请检查 File Station 写入权限")
        }
        uploadedCoverLock.lock()
        uploadedCoverFolders[destinationFolder] = fullPath
        uploadedCoverLock.unlock()
        ATMusicLogger.shared.log("✅ File Station 封面上传成功：\(fullPath)", level: .info)
        return fullPath
    }

    /// 将本机选图限制到合理尺寸再上传。原图（常见为数 MB 的 HEIC/JPEG）不再阻塞 NAS 写入。
    // MARK: - 文件与歌曲上传归档 (SYNO.FileStation.Upload)

    /// 将本地文件流式上传至群晖 NAS 指定目录（支持大音频、LRC 歌词与封面，内存安全且附带实时进度）
    func uploadFileToNAS(
        localFileURL: URL,
        destinationFolder: String,
        filename: String,
        mimeType: String = "application/octet-stream",
        onProgress: ((Double, Int64, Int64) -> Void)? = nil
    ) async throws -> String {
        guard !sid.isEmpty else { throw SynologyError.unauthenticated }
        let boundary = "ATMusicUpload\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var components = URLComponents(string: baseURL + "/webapi/entry.cgi")
        components?.queryItems = [
            URLQueryItem(name: "api", value: "SYNO.FileStation.Upload"),
            URLQueryItem(name: "version", value: "2"),
            URLQueryItem(name: "method", value: "upload"),
            URLQueryItem(name: "_sid", value: sid)
        ]
        guard let url = components?.url else { throw SynologyError.invalidURL("上传地址无效") }

        // 构建临时多部件数据流，避免大体积无损音频常驻内存触发 OOM
        let tempDir = FileManager.default.temporaryDirectory
        let tempUploadURL = tempDir.appendingPathComponent("upload_\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: tempUploadURL) }

        var headerData = Data()
        func addFormField(name: String, value: String) {
            headerData.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }

        addFormField(name: "api", value: "SYNO.FileStation.Upload")
        addFormField(name: "version", value: "2")
        addFormField(name: "method", value: "upload")
        addFormField(name: "path", value: destinationFolder)
        addFormField(name: "create_parents", value: "true")
        addFormField(name: "overwrite", value: "true")

        headerData.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
        let footerData = Data("\r\n--\(boundary)--\r\n".utf8)

        try headerData.write(to: tempUploadURL)
        guard let sourceHandle = try? FileHandle(forReadingFrom: localFileURL),
              let destHandle = try? FileHandle(forWritingTo: tempUploadURL) else {
            throw SynologyError.networkError("无法读取本地源文件")
        }
        try destHandle.seekToEnd()
        while let chunk = try sourceHandle.read(upToCount: 512 * 1024), !chunk.isEmpty {
            try destHandle.write(contentsOf: chunk)
        }
        try destHandle.write(contentsOf: footerData)
        try? destHandle.synchronize()
        try? destHandle.close()
        try? sourceHandle.close()

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("ATMusic/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let delegate = SynologyUploadProgressDelegate(onProgress: onProgress)
        let (responseData, response) = try await uploadSession.upload(for: request, fromFile: tempUploadURL, delegate: delegate)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw SynologyError.apiError(-1, "群晖 NAS 上传网络异常 (HTTP \(status))")
        }

        if let success = json["success"] as? Bool, !success {
            let errorDict = json["error"] as? [String: Any]
            let code = errorDict?["code"] as? Int ?? -1
            if (code == 105 || code == 106 || code == 119) {
                if await trySilentReauth() {
                    return try await uploadFileToNAS(
                        localFileURL: localFileURL,
                        destinationFolder: destinationFolder,
                        filename: filename,
                        mimeType: mimeType,
                        onProgress: onProgress
                    )
                }
                await MainActor.run { self.isLoggedIn = false }
                throw SynologyError.sessionExpired
            }
            let errorText: String
            switch code {
            case 400: errorText = "请求参数无效 (400)"
            case 408: errorText = "目标目录不存在或未创建成功 (408)"
            case 414: errorText = "文件大小超出系统限制 (414)"
            case 418: errorText = "没有向该目录写入的权限 (418)"
            default: errorText = "错误代码 \(code)（请检查 File Station 写入权限与存储空间）"
            }
            throw SynologyError.apiError(code, "群晖 NAS 上传失败：\(errorText)")
        }

        return destinationFolder + "/" + filename
    }

    // MARK: - 文件下载 (SYNO.FileStation.Download)

    /// 从群晖 NAS 下载任意指定路径的文件二进制数据（支持自动静默重登续期）
    func downloadFileFromNAS(path: String) async throws -> Data {
        guard !sid.isEmpty else { throw SynologyError.unauthenticated }
        var components = URLComponents(string: baseURL + "/webapi/entry.cgi")
        components?.queryItems = [
            URLQueryItem(name: "api", value: "SYNO.FileStation.Download"),
            URLQueryItem(name: "version", value: "2"),
            URLQueryItem(name: "method", value: "download"),
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "mode", value: "download"),
            URLQueryItem(name: "_sid", value: sid)
        ]
        guard let url = components?.url else { throw SynologyError.invalidURL("下载地址无效") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("ATMusic/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw SynologyError.apiError(-1, "群晖 NAS 下载网络异常 (HTTP \(status))")
        }

        // 若群晖返回 JSON 报错（如文件不存在或令牌过期）
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let success = json["success"] as? Bool, !success {
            let errorDict = json["error"] as? [String: Any]
            let code = errorDict?["code"] as? Int ?? -1
            if (code == 105 || code == 106 || code == 119) {
                if await trySilentReauth() {
                    return try await downloadFileFromNAS(path: path)
                }
                await MainActor.run { self.isLoggedIn = false }
                throw SynologyError.sessionExpired
            }
            throw SynologyError.apiError(code, "群晖 NAS 文件下载失败 (错误码 \(code))")
        }

        return data
    }

    func optimizedCoverData(_ data: Data) -> Data {
        autoreleasepool {
            guard let image = UIImage(data: data) else { return data }
            let maxSide: CGFloat = 1_200
            let longest = max(image.size.width, image.size.height)
            guard longest > maxSide else { return image.jpegData(compressionQuality: 0.85) ?? data }
            let scale = maxSide / longest
            let size = CGSize(
                width: max(1, (image.size.width * scale).rounded()),
                height: max(1, (image.size.height * scale).rounded())
            )
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1.0
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            return resized.jpegData(compressionQuality: 0.85) ?? data
        }
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let str = value as? String {
            if let direct = Int(str.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return direct
            }
            let parts = str.components(separatedBy: CharacterSet(charactersIn: "/-,"))
            if let first = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines), let num = Int(first) {
                return num
            }
        }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func searchVariants(for keyword: String) -> [String] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        var variants = [trimmed]
        let converted = simplifiedVariant(trimmed)
        if converted != trimmed { variants.append(converted) }
        if let traditional = trimmed.applyingTransform(StringTransform("Hans-Hant"), reverse: false), traditional != trimmed {
            variants.append(traditional)
        }
        return Array(NSOrderedSet(array: variants)) as? [String] ?? variants
    }

    private static func simplifiedVariant(_ value: String) -> String {
        let table: [Character: Character] = [
            "倫": "伦", "華": "华", "樂": "乐", "臺": "台", "灣": "湾", "國": "国", "龍": "龙",
            "劉": "刘", "張": "张", "陳": "陈", "黃": "黄", "楊": "杨", "趙": "赵", "吳": "吴",
            "學": "学", "電": "电", "風": "风", "愛": "爱", "萬": "万", "東": "东", "後": "后",
            "來": "来", "與": "与", "這": "这", "們": "们", "見": "见", "說": "说", "聽": "听",
            "時": "时", "會": "会", "點": "点", "兒": "儿", "雲": "云", "蘇": "苏", "鄧": "邓",
            "偉": "伟", "傑": "杰", "葉": "叶", "鄭": "郑", "錢": "钱", "鍾": "钟", "劍": "剑"
        ]
        let mapped = String(value.map { table[$0] ?? $0 })
        return mapped.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? mapped
    }

    private static func normalizedSearchValue(_ value: String) -> String {
        let simplified = simplifiedVariant(value)
        return simplified
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private static func uniqueSongs(_ songs: [Song]) -> [Song] {
        var seen = Set<String>()
        return songs.filter { seen.insert($0.identityKey).inserted }
    }

    private static func uniqueArtists(_ artists: [Artist]) -> [Artist] {
        var seen = Set<String>()
        return artists.filter { seen.insert($0.name.lowercased()).inserted }
    }

    private static func uniqueAlbums(_ albums: [Album]) -> [Album] {
        var seen = Set<String>()
        return albums.filter { seen.insert(($0.name + "|" + $0.artistName).lowercased()).inserted }
    }

    /// String.hashValue 会在每次进程启动时变化，不能作为持久化歌单/歌曲 ID。
    static func stableID(_ value: String) -> Int {
        if let number = Int(value), number != Int.min {
            return number == 0 ? 1 : abs(number)
        }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash & 0x7fff_ffff_ffff_ffff) == 0 ? 1 : Int(hash & 0x7fff_ffff_ffff_ffff)
    }

    
    private var isReauthenticating = false

    /// 静默自动重新鉴权：当令牌自然过期时，用安全钥匙串中的凭证自动登录，无需打扰用户
    func trySilentReauth() async -> Bool {
        guard !isReauthenticating else { return false }
        guard !account.isEmpty, !storedPassword.isEmpty else { return false }
        isReauthenticating = true
        defer { isReauthenticating = false }

        do {
            try await login()
            return true
        } catch {
            ATMusicLogger.shared.log("群晖静默重鉴权失败: \(error.localizedDescription)", level: .warn)
            return false
        }
    }

    // MARK: - 网络底层

    func get(_ path: String, query: [URLQueryItem], authenticated: Bool = true) async throws -> [String: Any] {
        let generation = configurationGeneration
        guard let urlBase = URL(string: baseURL + path) else {
            throw SynologyError.invalidURL("无效的请求地址: \(baseURL + path)")
        }

        var components = URLComponents(url: urlBase, resolvingAgainstBaseURL: false)
        var items = query
        if authenticated {
            if sid.isEmpty { throw SynologyError.unauthenticated }
            items.append(URLQueryItem(name: "_sid", value: sid))
        }
        components?.queryItems = items

        guard let finalURL = components?.url else {
            throw SynologyError.invalidURL("构造 URL 失败")
        }

        var request = URLRequest(url: finalURL)
        request.httpMethod = "GET"
        request.setValue("ATMusic/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard generation == configurationGeneration else { throw CancellationError() }
        guard let http = response as? HTTPURLResponse else {
            throw SynologyError.networkError("未能建立 HTTP 连接")
        }

        guard http.statusCode == 200 else {
            throw SynologyError.httpStatus(http.statusCode)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SynologyError.decodingError
        }

        let success = json["success"] as? Bool ?? false
        if !success {
            let errorDict = json["error"] as? [String: Any]
            let code = errorDict?["code"] as? Int ?? -1
            if (code == 105 || code == 106 || code == 119) && authenticated {
                // Session 过期，静默尝试重新登录并重试一次
                if await trySilentReauth() {
                    return try await get(path, query: query, authenticated: true)
                }
                await MainActor.run { self.isLoggedIn = false }
                throw SynologyError.sessionExpired
            }
            throw SynologyError.apiError(code, Self.describeErrorCode(code))
        }

        return json
    }

    func postForm(_ path: String, form: [String: String], authenticated: Bool, acceptsMissingSuccess: Bool = false) async throws -> [String: Any] {
        let generation = configurationGeneration
        guard let url = URL(string: baseURL + path) else { throw SynologyError.invalidURL("无效的请求地址") }
        var values = form
        if authenticated {
            guard !sid.isEmpty else { throw SynologyError.unauthenticated }
            values["_sid"] = sid
        }
        let body = values.map { "\(Self.formEscape($0.key))=\(Self.formEscape($0.value))" }.joined(separator: "&")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("ATMusic/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard generation == configurationGeneration else { throw CancellationError() }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SynologyError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SynologyError.decodingError }
        if let success = json["success"] as? Bool, !success {
            let code = (json["error"] as? [String: Any])?["code"] as? Int ?? -1
            if (code == 105 || code == 106 || code == 119) && authenticated {
                if await trySilentReauth() {
                    return try await postForm(path, form: form, authenticated: true, acceptsMissingSuccess: acceptsMissingSuccess)
                }
                await MainActor.run { self.isLoggedIn = false }
                throw SynologyError.sessionExpired
            }
            throw SynologyError.apiError(code, Self.describeErrorCode(code))
        }
        if !acceptsMissingSuccess && json["success"] == nil {
            throw SynologyError.decodingError
        }
        return json
    }

    private static func formEscape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._* ")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)?.replacingOccurrences(of: " ", with: "+") ?? value
    }

    private static func metadataNormalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[\\(\\)\\[\\]\\-_/·•]", with: "", options: .regularExpression)
            .lowercased()
    }

    private static func describeErrorCode(_ code: Int) -> String {
        switch code {
        case 100: return "未知错误"
        case 101: return "无效参数"
        case 102: return "该 API 服务不存在"
        case 103: return "该方法不存在"
        case 104: return "API 版本不支持"
        case 105: return "登录权限失效或会话已过期"
        case 106: return "会话中断，请重新登录"
        case 400: return "用户名或密码错误"
        case 401: return "账户已被禁用"
        case 402: return "无权限访问该服务"
        case 403: return "需要两步验证 (OTP) 验证码"
        case 404: return "两步验证失败"
        default: return "错误代码 (\(code))"
        }
    }
}

enum SynologyError: LocalizedError {
    case missingConfiguration(String)
    case invalidURL(String)
    case networkError(String)
    case httpStatus(Int)
    case decodingError
    case loginFailed(String)
    case unauthenticated
    case sessionExpired
    case apiError(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration(let msg): return msg
        case .invalidURL(let msg): return msg
        case .networkError(let msg): return msg
        case .httpStatus(let code): return "群晖服务器响应错误 HTTP \(code)"
        case .decodingError: return "解析群晖数据失败"
        case .loginFailed(let msg): return msg
        case .unauthenticated: return "尚未登录群晖 NAS"
        case .sessionExpired: return "群晖登录已过期，请重新登录"
        case .apiError(_, let msg): return "群晖服务错误: \(msg)"
        }
    }
}


final class SynologyUploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: ((Double, Int64, Int64) -> Void)?
    init(onProgress: ((Double, Int64, Int64) -> Void)?) {
        self.onProgress = onProgress
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if totalBytesExpectedToSend > 0 {
            let progress = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
            onProgress?(progress, totalBytesSent, totalBytesExpectedToSend)
        }
    }
}
