import Foundation

// MARK: - 平台能力清单（PlatformCapabilities）

/// 平台功能与权限清单：明确各平台实际支持哪些能力，避免页面随意假设接口可用
struct PlatformCapabilities: Codable, Hashable, Sendable {
    /// 搜索能力
    let canSearchSongs: Bool
    let canSearchArtists: Bool
    let canSearchAlbums: Bool
    let canSearchPlaylists: Bool
    let supportsPaging: Bool

    /// 账号与用户能力
    let requiresAccount: Bool
    let canReadUserPlaylists: Bool
    let canWriteUserPlaylists: Bool

    /// 音质支持列表
    let supportedAudioQualities: [ThirdPartyAudioQuality]

    /// 媒体能力
    let supportsDownload: Bool
    let supportsLyrics: Bool
    let supportsComments: Bool

    /// 各平台标准能力预设
    static var netease: PlatformCapabilities {
        PlatformCapabilities(
            canSearchSongs: true,
            canSearchArtists: true,
            canSearchAlbums: true,
            canSearchPlaylists: true,
            supportsPaging: true,
            requiresAccount: false,
            canReadUserPlaylists: true,
            canWriteUserPlaylists: false,
            supportedAudioQualities: [.kb128, .kb320, .flac, .flac24bit, .hires, .atmos, .master],
            supportsDownload: true,
            supportsLyrics: true,
            supportsComments: true
        )
    }

    static var qq: PlatformCapabilities {
        PlatformCapabilities(
            canSearchSongs: true,
            canSearchArtists: true,
            canSearchAlbums: true,
            canSearchPlaylists: true,
            supportsPaging: true,
            requiresAccount: false,
            canReadUserPlaylists: true,
            canWriteUserPlaylists: false,
            supportedAudioQualities: [.kb128, .kb320, .flac, .flac24bit, .hires, .atmos, .master],
            supportsDownload: true,
            supportsLyrics: true,
            supportsComments: false
        )
    }

    static var kugou: PlatformCapabilities {
        PlatformCapabilities(
            canSearchSongs: true,
            canSearchArtists: false,
            canSearchAlbums: false,
            canSearchPlaylists: false,
            supportsPaging: true,
            requiresAccount: false,
            canReadUserPlaylists: true,
            canWriteUserPlaylists: false,
            supportedAudioQualities: [.kb128, .kb320, .flac, .flac24bit, .hires, .atmos, .master],
            supportsDownload: true,
            supportsLyrics: true,
            supportsComments: false
        )
    }


    static var synology: PlatformCapabilities {
        PlatformCapabilities(
            canSearchSongs: true,
            canSearchArtists: true,
            canSearchAlbums: true,
            canSearchPlaylists: true,
            supportsPaging: true,
            requiresAccount: true,
            canReadUserPlaylists: true,
            canWriteUserPlaylists: false,
            supportedAudioQualities: [.flac, .kb320],
            supportsDownload: true,
            supportsLyrics: true,
            supportsComments: false
        )
    }

    static var local: PlatformCapabilities {
        PlatformCapabilities(
            canSearchSongs: true,
            canSearchArtists: true,
            canSearchAlbums: true,
            canSearchPlaylists: true,
            supportsPaging: false,
            requiresAccount: false,
            canReadUserPlaylists: true,
            canWriteUserPlaylists: true,
            supportedAudioQualities: [.master, .hires, .flac24bit, .flac, .kb320, .kb128],
            supportsDownload: false, // 本地音频本已在设备内
            supportsLyrics: true,
            supportsComments: false
        )
    }
}

// MARK: - 统一平台适配器协议（MusicPlatformAdapter）

protocol MusicPlatformAdapter: Sendable {
    var platformType: SongSourceType { get }
    var displayName: String { get }
    var capabilities: PlatformCapabilities { get }

    /// 当前适配器是否已配置（如 NAS 是否配置了 host，各在线平台是否就绪）
    func isConfigured() -> Bool

    /// 当前适配器是否已登录账号
    func isLoggedIn() -> Bool

    /// 根据来源记录解析播放资源
    func resolvePlayableResource(for source: SongSourceRecord, quality: ThirdPartyAudioQuality) async throws -> PlayableResource?

    /// 获取歌词
    func fetchLyrics(for source: SongSourceRecord) async throws -> String?
}

// MARK: - 网易云适配器（NetEasePlatformAdapter）

final class NetEasePlatformAdapter: MusicPlatformAdapter {
    let platformType: SongSourceType = .netease
    let displayName: String = "网易云音乐"
    let capabilities: PlatformCapabilities = .netease

    func isConfigured() -> Bool { true }
    func isLoggedIn() -> Bool {
        UserDefaults.standard.data(forKey: "atmusic.user") != nil
    }

    func resolvePlayableResource(for source: SongSourceRecord, quality: ThirdPartyAudioQuality) async throws -> PlayableResource? {
        guard let songId = Int(source.remoteId) else { return nil }
        let level = quality.neteaseLevel
        let urls = try? await NetEaseAPI.shared.songURLs(ids: [songId], level: level)
        guard let urlString = urls?[songId], let url = URL(string: urlString) else {
            return nil
        }
        return PlayableResource(
            sourceRecordId: source.id,
            kind: .onlineStream(streamURL: url, isThirdParty: false),
            quality: quality,
            isOfflineAvailable: false
        )
    }

    func fetchLyrics(for source: SongSourceRecord) async throws -> String? {
        guard let songId = Int(source.remoteId) else { return nil }
        return try? await NetEaseAPI.shared.lyric(id: songId)
    }
}

// MARK: - QQ 音乐适配器（QQMusicPlatformAdapter）

final class QQMusicPlatformAdapter: MusicPlatformAdapter {
    let platformType: SongSourceType = .qq
    let displayName: String = "QQ音乐"
    let capabilities: PlatformCapabilities = .qq

    func isConfigured() -> Bool { true }
    func isLoggedIn() -> Bool {
        QQMusicAuth.shared.isLoggedIn
    }

    func resolvePlayableResource(for source: SongSourceRecord, quality: ThirdPartyAudioQuality) async throws -> PlayableResource? {
        let mid = source.extraAttributes["qqMid"] ?? source.remoteId
        let mediaMid = source.extraAttributes["qqMediaMid"]
        let result = try? await QQMusicAPI.shared.songURLResult(
            songmid: mid,
            mediaMid: mediaMid,
            quality: quality.atmusicQuality
        )
        guard let res = result, let url = URL(string: res.url) else { return nil }
        return PlayableResource(
            sourceRecordId: source.id,
            kind: .onlineStream(streamURL: url, isThirdParty: false),
            quality: quality,
            isOfflineAvailable: false,
            headers: ["Referer": "https://y.qq.com/"]
        )
    }

    func fetchLyrics(for source: SongSourceRecord) async throws -> String? {
        let mid = source.extraAttributes["qqMid"] ?? source.remoteId
        return try? await QQMusicAPI.shared.lyric(songmid: mid)
    }
}

// MARK: - 酷狗音乐适配器（KugouPlatformAdapter）

final class KugouPlatformAdapter: MusicPlatformAdapter {
    let platformType: SongSourceType = .kugou
    let displayName: String = "酷狗音乐"
    let capabilities: PlatformCapabilities = .kugou

    func isConfigured() -> Bool { true }
    func isLoggedIn() -> Bool {
        KugouMusicAuth.shared.isLoggedIn
    }

    func resolvePlayableResource(for source: SongSourceRecord, quality: ThirdPartyAudioQuality) async throws -> PlayableResource? {
        // 构造桥接旧版 Song 传参
        let legacy = Song(
            id: UnifiedSong.stableNumericHash(source.id),
            name: source.title,
            artists: source.artist,
            album: source.album,
            coverURL: source.coverURL,
            duration: source.duration,
            source: .kugou,
            kugouHash: source.extraAttributes["kugouHash"] ?? source.remoteId,
            kugouAlbumAudioId: source.extraAttributes["kugouAlbumAudioId"],
            kugouAlbumId: source.extraAttributes["kugouAlbumId"],
            kugouQualityHashes: source.extraAttributes["kugouQualityHashes"].flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
        )
        guard let urlString = try? await KugouMusicAPI.shared.songURL(song: legacy, quality: quality.atmusicQuality),
              let url = URL(string: urlString) else { return nil }
        return PlayableResource(
            sourceRecordId: source.id,
            kind: .onlineStream(streamURL: url, isThirdParty: false),
            quality: quality,
            isOfflineAvailable: false,
            headers: ["Referer": "https://www.kugou.com/"]
        )
    }

    func fetchLyrics(for source: SongSourceRecord) async throws -> String? {
        guard let hash = source.extraAttributes["kugouHash"] ?? (source.remoteId.isEmpty ? nil : source.remoteId) else {
            return nil
        }
        let lrc = await KugouMusicAPI.shared.lyric(hash: hash, duration: source.duration)
        return lrc.isEmpty ? nil : lrc
    }
}

// MARK: - 群晖 NAS 适配器（SynologyPlatformAdapter，支持多服务器与账号隔离）

final class SynologyPlatformAdapter: MusicPlatformAdapter {
    let platformType: SongSourceType = .synology
    let displayName: String = "群晖 NAS"
    let capabilities: PlatformCapabilities = .synology

    func isConfigured() -> Bool {
        !SynologyAPI.shared.host.isEmpty
    }

    func isLoggedIn() -> Bool {
        SynologyAPI.shared.isLoggedIn
    }

    /// 当前 NAS 连接的作用域（host:port/account）
    var currentServerScope: String {
        SynologyAPI.shared.currentServerScope
    }

    func resolvePlayableResource(for source: SongSourceRecord, quality: ThirdPartyAudioQuality) async throws -> PlayableResource? {
        guard isConfigured(), isLoggedIn() else { return nil }
        let unified = UnifiedSong(title: source.title, artist: source.artist, album: source.album,
                                  duration: source.duration, sources: [source])
        guard let song = unified.toLegacySong(), let value = SynologyAPI.shared.songURL(song: song),
              let url = URL(string: value) else { return nil }

        return PlayableResource(
            sourceRecordId: source.id,
            kind: .nasStream(streamURL: url, serverScope: currentServerScope),
            quality: quality,
            isOfflineAvailable: false
        )
    }

    func fetchLyrics(for source: SongSourceRecord) async throws -> String? {
        let legacy = Song(
            id: UnifiedSong.stableNumericHash(source.id),
            name: source.title,
            artists: source.artist,
            album: source.album,
            coverURL: source.coverURL,
            duration: source.duration,
            source: .synology,
            synologyId: source.extraAttributes["synologyId"] ?? source.remoteId,
            synologyServerScope: source.serverScope
        )
        return try? await SynologyAPI.shared.lyrics(song: legacy)
    }
}

// MARK: - 本地音乐适配器（LocalPlatformAdapter）

final class LocalPlatformAdapter: MusicPlatformAdapter {
    let platformType: SongSourceType = .local
    let displayName: String = "本地音乐"
    let capabilities: PlatformCapabilities = .local

    func isConfigured() -> Bool { true }
    func isLoggedIn() -> Bool { true }

    func resolvePlayableResource(for source: SongSourceRecord, quality: ThirdPartyAudioQuality) async throws -> PlayableResource? {
        guard let relPath = source.extraAttributes["relativePath"] else { return nil }
        let fileURL = try ManagedAudioPath.resolve(relPath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        return PlayableResource(
            sourceRecordId: source.id,
            kind: .localFile(relativePath: relPath, isUserImported: true),
            quality: quality,
            isOfflineAvailable: true
        )
    }

    func fetchLyrics(for source: SongSourceRecord) async throws -> String? {
        // 查找同名 .lrc 文件
        guard let relPath = source.extraAttributes["relativePath"] else { return nil }
        let lrcPath = (relPath as NSString).deletingPathExtension + ".lrc"
        let lrcURL = try ManagedAudioPath.resolve(lrcPath)
        guard FileManager.default.fileExists(atPath: lrcURL.path) else { return nil }
        return try? String(contentsOf: lrcURL, encoding: .utf8)
    }
}

// MARK: - 平台适配器统一注册表与调度中心（PlatformRegistry）

final class PlatformRegistry: @unchecked Sendable {
    static let shared = PlatformRegistry()

    private var adapters: [SongSourceType: MusicPlatformAdapter] = [:]
    private let lock = NSLock()

    init(registerDefaults: Bool = true) {
        guard registerDefaults else { return }
        register(NetEasePlatformAdapter())
        register(QQMusicPlatformAdapter())
        register(KugouPlatformAdapter())
        register(SynologyPlatformAdapter())
        register(LocalPlatformAdapter())
    }

    func register(_ adapter: MusicPlatformAdapter) {
        lock.lock()
        defer { lock.unlock() }
        adapters[adapter.platformType] = adapter
    }

    func adapter(for type: SongSourceType) -> MusicPlatformAdapter? {
        lock.lock()
        defer { lock.unlock() }
        return adapters[type]
    }

    /// 查询平台能力
    func capabilities(for type: SongSourceType) -> PlatformCapabilities {
        adapter(for: type)?.capabilities ?? .netease
    }

    /// 安全解析播放资源（故障隔离：单个适配器抛出异常或超时不影响其他调用）
    func safeResolveResource(
        for source: SongSourceRecord,
        quality: ThirdPartyAudioQuality,
        timeout: TimeInterval = 15
    ) async -> PlayableResource? {
        guard let adp = adapter(for: source.sourceType) else {
            return nil
        }
        let race = ResourceResolutionRace()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                race.begin(continuation)
                let worker = Task {
                    let result = try? await adp.resolvePlayableResource(for: source, quality: quality)
                    race.finish(result)
                }
                let timer = Task {
                    let seconds = timeout.isFinite ? min(max(timeout, 0.001), 60) : 15
                    do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
                    catch { return }
                    race.finish(nil)
                }
                race.attach([worker, timer])
            }
        }, onCancel: { race.finish(nil) })
    }
}

/// 超时只结束本次调用，不等待不合作的适配器；迟到结果不能覆盖已完成的结果。
private final class ResourceResolutionRace: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var continuation: CheckedContinuation<PlayableResource?, Never>?
    private var tasks: [Task<Void, Never>] = []
    func begin(_ value: CheckedContinuation<PlayableResource?, Never>) {
        lock.lock()
        let alreadyFinished = finished
        if !alreadyFinished { continuation = value }
        lock.unlock()
        if alreadyFinished { value.resume(returning: nil) }
    }
    func attach(_ values: [Task<Void, Never>]) {
        lock.lock()
        let alreadyFinished = finished
        if !alreadyFinished { tasks = values }
        lock.unlock()
        if alreadyFinished { values.forEach { $0.cancel() } }
    }
    func finish(_ result: PlayableResource?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let completion = continuation
        let running = tasks
        continuation = nil
        tasks = []
        lock.unlock()
        running.forEach { $0.cancel() }
        completion?.resume(returning: result)
    }
}
