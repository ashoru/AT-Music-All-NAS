import Foundation

/// 音质等级（全面对标网易云音乐与 QQ 音乐专业音质体系）。
enum ATMusicAudioQuality: String, CaseIterable, Identifiable {
    case auto
    case standard
    case higher
    case exhigh
    case lossless
    case hires
    case master

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return atmusicLocalized("智能自适应", "Auto Adaptive")
        case .standard: return atmusicLocalized("标准音质", "Standard")
        case .higher: return atmusicLocalized("较高品质", "Higher")
        case .exhigh: return atmusicLocalized("极高品质", "Very High")
        case .lossless: return atmusicLocalized("无损音质", "Lossless")
        case .hires: return atmusicLocalized("超清母带", "Hi-Res Master")
        case .master: return atmusicLocalized("臻品母带", "Master Quality")
        }
    }

    /// 专业音质徽标缩写（对标网易/QQ 音乐）
    var badgeText: String {
        switch self {
        case .auto: return "AUTO"
        case .standard: return "SD"
        case .higher: return "HQ"
        case .exhigh: return "HQ+"
        case .lossless: return "SQ"
        case .hires: return "Hi-Res"
        case .master: return "MASTER"
        }
    }

    /// 码率与规格参数描述
    var subtitle: String {
        switch self {
        case .auto: return atmusicLocalized("自动匹配网络与设备最佳音质", "Match best network & device quality")
        case .standard: return "128kbps MP3 · 畅享省流"
        case .higher: return "192kbps AAC · 平衡流畅"
        case .exhigh: return "320kbps MP3 · 细节丰富"
        case .lossless: return "FLAC 16bit/44.1kHz · CD 级"
        case .hires: return "FLAC 24bit/96kHz · 超解析母带"
        case .master: return "24bit/192kHz · 顶级录音室母带"
        }
    }

    /// 网易云 songURL 的 level 参数
    var level: String {
        switch self {
        case .auto: return "hires"
        case .standard: return "standard"
        case .higher: return "higher"
        case .exhigh: return "exhigh"
        case .lossless: return "lossless"
        case .hires: return "hires"
        case .master: return "jymaster"
        }
    }

    /// 当前官方播放音质（默认 Hi-Res；不可用时由各平台接口自行降级）。
    static var current: ATMusicAudioQuality {
        let raw = UserDefaults.standard.string(forKey: "atmusic.audioQuality") ?? Self.hires.rawValue
        return ATMusicAudioQuality(rawValue: raw) ?? .hires
    }
}

/// 第三方音源音质。
enum ThirdPartyAudioQuality: String, CaseIterable, Identifiable, Sendable, Codable {
    case kb128 = "128k"
    case kb320 = "320k"
    case flac = "flac"
    case flac24bit = "flac24bit"
    case hires = "hires"
    case atmos = "atmos"
    case atmosPlus = "atmos_plus"
    case master = "master"

    static let storageKey = "atmusic.thirdPartyAudioQuality"
    static let downloadStorageKey = "atmusic.downloadAudioQuality"

    var id: String { rawValue }

    /// 兼容第三方脚本常见的音质别名（例如 24bit / lossless）。
    init?(sourceValue: String) {
        let normalized = sourceValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalized {
        case "128", "128k", "low", "standard": self = .kb128
        case "320", "320k", "high", "exhigh": self = .kb320
        case "flac", "lossless": self = .flac
        case "24bit", "flac24", "flac24bit", "hires24": self = .flac24bit
        case "hires", "highres", "high-resolution": self = .hires
        case "atmos", "dolby": self = .atmos
        case "atmosplus", "atmos_plus", "dolbyplus": self = .atmosPlus
        case "master", "masterquality": self = .master
        default: return nil
        }
    }

    var displayName: String {
        switch self {
        case .kb128: return atmusicLocalized("128k", "128k")
        case .kb320: return atmusicLocalized("320k", "320k")
        case .flac: return atmusicLocalized("无损 FLAC", "FLAC")
        case .flac24bit: return atmusicLocalized("FLAC 24 位", "FLAC 24-bit")
        case .hires: return atmusicLocalized("Hi-Res", "Hi-Res")
        case .atmos: return atmusicLocalized("Atmos", "Atmos")
        case .atmosPlus: return atmusicLocalized("Atmos+", "Atmos+")
        case .master: return atmusicLocalized("Master", "Master")
        }
    }

    /// 当前第三方音源优先音质。
    static var current: ThirdPartyAudioQuality {
        UserDefaults.standard.string(forKey: storageKey)
            .flatMap { ThirdPartyAudioQuality(sourceValue: $0) } ?? .kb320
    }

    /// 下载使用的独立音质设置，默认保持 320k 以兼容旧版本。
    static var downloadCurrent: ThirdPartyAudioQuality {
        UserDefaults.standard.string(forKey: downloadStorageKey)
            .flatMap { ThirdPartyAudioQuality(sourceValue: $0) } ?? .kb320
    }

    /// 按第三方接口的平台代码返回可用档位。
    static func supported(providerCode: String) -> [ThirdPartyAudioQuality] {
        switch providerCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "kw", "mg":
            return [.kb128, .kb320, .flac, .flac24bit, .hires]
        case "kg":
            return [.kb128, .kb320, .flac, .flac24bit, .hires, .atmos, .master]
        case "tx":
            return allCases
        case "wy":
            return [.kb128, .kb320, .flac, .flac24bit, .hires, .atmos, .master]
        case "git":
            return [.kb128, .kb320, .flac]
        default:
            return allCases
        }
    }

    static func supported(for source: SongSource) -> [ThirdPartyAudioQuality] {
        switch source {
        case .netease: return supported(providerCode: "wy")
        case .qq: return supported(providerCode: "tx")
        case .kugou: return supported(providerCode: "kg")
        case .synology, .subsonic, .jellyfin, .webdav: return [.flac, .kb320]
        case .local: return [.flac, .kb320, .kb128]
        }
    }

    /// 从高到低的降级链。
    var fallbackChain: [ThirdPartyAudioQuality] {
        switch self {
        case .kb128:
            return [.kb128]
        case .kb320:
            return [.kb320, .kb128]
        case .flac:
            return [.flac, .kb320, .kb128]
        case .flac24bit:
            return [.flac24bit, .flac, .kb320, .kb128]
        case .hires:
            return [.hires, .flac24bit, .flac, .kb320, .kb128]
        case .atmos:
            return [.atmos, .hires, .flac24bit, .flac, .kb320, .kb128]
        case .atmosPlus:
            return [.atmosPlus, .atmos, .hires, .flac24bit, .flac, .kb320, .kb128]
        case .master:
            return [.master, .atmosPlus, .atmos, .hires, .flac24bit, .flac, .kb320, .kb128]
        }
    }

    /// 网易云 player/url 的 level 参数。
    var neteaseLevel: String {
        switch self {
        case .kb128: return "standard"
        case .kb320: return "exhigh"
        case .flac: return "lossless"
        case .flac24bit, .hires, .atmos, .atmosPlus, .master: return "hires"
        }
    }

    /// QQ vkey 的 br 参数。
    var qqBR: String {
        switch self {
        case .kb128: return "M500"
        case .kb320: return "M800"
        case .flac, .flac24bit, .hires, .atmos, .atmosPlus, .master: return "F000"
        }
    }

    /// 酷狗官方接口所能理解的质量档位。
    var atmusicQuality: ATMusicAudioQuality {
        switch self {
        case .kb128: return .standard
        case .kb320: return .exhigh
        case .flac: return .lossless
        case .flac24bit, .hires, .atmos, .atmosPlus: return .hires
        case .master: return .master
        }
    }
}

/// 歌曲来源（网易云 / QQ音乐 / 酷狗音乐 / 群晖NAS）
enum SongSource: String, Codable, Sendable {
    case netease
    case qq
    case kugou
    case synology
    case subsonic
    case jellyfin
    case webdav
    case local

    /// 兼容旧版本地收藏：未知或已下线来源统一回退为网易云
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SongSource(rawValue: raw) ?? .netease
    }
}

/// NAS/自建音乐服务器通用搜索结果（Subsonic / Jellyfin / WebDAV 共用，避免每个后端各自重复定义）
struct NASSearchResult {
    let songs: [Song]
    let artists: [Artist]
    let albums: [Album]
}

struct Song: Identifiable, Hashable, Codable {
    let id: Int
    let name: String
    let artists: String
    let album: String
    private let _coverURL: URL?
    var coverURL: URL? {
        ManagedAudioPath.resolveCoverURL(candidate: _coverURL, localRelativePath: localRelativePath)
    }
    var rawCoverURL: URL? { _coverURL }
    let duration: TimeInterval
    /// 歌曲来源（网易云 / QQ音乐 / 酷狗 / 群晖）
    let source: SongSource
    /// QQ 音乐 songmid（source == .qq 时用于获取播放地址与歌词）
    let qqMid: String?
    /// QQ 音乐音频文件 media_mid；部分歌曲与 songmid 不同，取 vkey 时必须优先使用
    let qqMediaMid: String?
    /// 酷狗音乐文件 hash 与专辑音频 id（source == .kugou 时用于获取播放地址与歌词）
    let kugouHash: String?
    let kugouAlbumAudioId: String?
    let kugouAlbumId: String?
    let kugouQualityHashes: [String: String]?
    /// 群晖 NAS 歌曲 ID
    let synologyId: String?
    /// 服务器协议、地址、端口与账号共同确定的作用域；旧数据缺失时不能猜测来源。
    let synologyServerScope: String?
    /// NAS 原文件的完整路径，仅用于用户确认后写回标签/封面/歌词。
    let synologyPath: String?
    /// Subsonic/OpenSubsonic 歌曲 ID
    let subsonicId: String?
    /// Subsonic 服务器地址 + 账号共同确定的作用域
    let subsonicServerScope: String?
    /// Jellyfin 媒体项 ID（GUID）
    let jellyfinId: String?
    /// Jellyfin 服务器地址 + 账号共同确定的作用域
    let jellyfinServerScope: String?
    /// WebDAV 服务器上的完整文件路径
    let webdavPath: String?
    /// WebDAV 服务器地址 + 账号共同确定的作用域
    let webdavServerScope: String?
    /// 用户导入音频在 ATMusicAudio 目录下的相对路径。
    let localRelativePath: String?
    /// 本地/NAS 歌曲可选的扩展标签。旧版本记录没有这些字段时保持 nil。
    let albumArtist: String?
    let genre: String?
    let year: String?
    let comment: String?
    /// CD 盘号（多 CD 专辑支持，默认为 1）
    let discNumber: Int
    /// 专辑音轨序号（从 1 开始，无音轨则为 0）
    let trackNumber: Int
    /// 付费/VIP 标记（网易云：0 免费、1 VIP、4 付费单曲；QQ：0 免费、非 0 付费）
    let fee: Int

    var formattedDuration: String {
        let total = max(0, Int(duration))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// 跨平台唯一标识（避免网易云与 QQ 音乐歌曲 id 撞车）
    var identityKey: String {
        switch source {
        case .qq: return "qq-\(id)"
        case .kugou: return "kugou-\(id)"
        case .netease: return "netease-\(id)"
        case .synology:
            return "synology-\(synologyServerScope.map { $0 + ":" } ?? "")\(synologyId ?? "\(id)")"
        case .subsonic:
            return "subsonic-\(subsonicServerScope.map { $0 + ":" } ?? "")\(subsonicId ?? "\(id)")"
        case .jellyfin:
            return "jellyfin-\(jellyfinServerScope.map { $0 + ":" } ?? "")\(jellyfinId ?? "\(id)")"
        case .webdav:
            return "webdav-\(webdavServerScope.map { $0 + ":" } ?? "")\(webdavPath ?? "\(id)")"
        case .local:
            return "local-\(localRelativePath ?? "\(id)")"
        }
    }

    /// 是否为 VIP / 付费歌曲（用于列表与播放器角标）
    /// 网易云 fee：0 免费、1 VIP、4 付费单曲；8 为翻唱/免费资源，不视为 VIP
    /// QQ payplay：0 免费，非 0 需要会员/付费
    var isVIP: Bool {
        switch source {
        case .netease:
            return fee == 1 || fee == 4
        case .qq:
            return fee != 0
        case .kugou:
            return fee != 0
        case .synology, .subsonic, .jellyfin, .webdav, .local:
            return false
        }
    }

    init(id: Int, name: String, artists: String, album: String, coverURL: URL?, duration: TimeInterval, source: SongSource = .netease, qqMid: String? = nil, qqMediaMid: String? = nil, kugouHash: String? = nil, kugouAlbumAudioId: String? = nil, kugouAlbumId: String? = nil, kugouQualityHashes: [String: String]? = nil, synologyId: String? = nil, synologyServerScope: String? = nil, synologyPath: String? = nil, subsonicId: String? = nil, subsonicServerScope: String? = nil, jellyfinId: String? = nil, jellyfinServerScope: String? = nil, webdavPath: String? = nil, webdavServerScope: String? = nil, localRelativePath: String? = nil, albumArtist: String? = nil, genre: String? = nil, year: String? = nil, comment: String? = nil, discNumber: Int = 1, trackNumber: Int = 0, fee: Int = 0) {
        self.id = id
        self.name = name
        self.artists = artists
        self.album = album
        self._coverURL = coverURL
        self.duration = duration
        self.source = source
        self.qqMid = qqMid
        self.qqMediaMid = qqMediaMid
        self.kugouHash = kugouHash
        self.kugouAlbumAudioId = kugouAlbumAudioId
        self.kugouAlbumId = kugouAlbumId
        self.kugouQualityHashes = kugouQualityHashes
        self.synologyId = synologyId
        self.synologyServerScope = synologyServerScope
        self.synologyPath = synologyPath
        self.subsonicId = subsonicId
        self.subsonicServerScope = subsonicServerScope
        self.jellyfinId = jellyfinId
        self.jellyfinServerScope = jellyfinServerScope
        self.webdavPath = webdavPath
        self.webdavServerScope = webdavServerScope
        self.localRelativePath = localRelativePath
        self.albumArtist = albumArtist
        self.genre = genre
        self.year = year
        self.comment = comment
        self.discNumber = discNumber
        self.trackNumber = trackNumber
        self.fee = fee
    }

    func withLocalRelativePath(_ path: String?) -> Song {
        Song(
            id: id,
            name: name,
            artists: artists,
            album: album,
            coverURL: coverURL,
            duration: duration,
            source: source,
            qqMid: qqMid,
            qqMediaMid: qqMediaMid,
            kugouHash: kugouHash,
            kugouAlbumAudioId: kugouAlbumAudioId,
            kugouAlbumId: kugouAlbumId,
            kugouQualityHashes: kugouQualityHashes,
            synologyId: synologyId,
            synologyServerScope: synologyServerScope,
            synologyPath: synologyPath,
            subsonicId: subsonicId,
            subsonicServerScope: subsonicServerScope,
            jellyfinId: jellyfinId,
            jellyfinServerScope: jellyfinServerScope,
            webdavPath: webdavPath,
            webdavServerScope: webdavServerScope,
            localRelativePath: path,
            albumArtist: albumArtist,
            genre: genre,
            year: year,
            comment: comment,
            discNumber: discNumber,
            trackNumber: trackNumber,
            fee: fee
        )
    }

    init?(json: [String: Any]) {
        guard let id = json["id"] as? Int else { return nil }
        self.id = id
        name = json["name"] as? String ?? ""
        let artistsArray = json["artists"] as? [[String: Any]] ?? (json["ar"] as? [[String: Any]]) ?? []
        artists = artistsArray.compactMap { $0["name"] as? String }.joined(separator: " / ")
        if let albumDict = json["album"] as? [String: Any] {
            album = albumDict["name"] as? String ?? ""
            let pic = albumDict["picUrl"] as? String ?? (albumDict["blurPicUrl"] as? String ?? "")
            _coverURL = pic.isEmpty ? nil : URL(string: pic)
        } else if let al = json["al"] as? [String: Any] {
            album = al["name"] as? String ?? ""
            let pic = al["picUrl"] as? String ?? ""
            _coverURL = pic.isEmpty ? nil : URL(string: pic)
        } else {
            album = ""
            _coverURL = nil
        }
        let ms = json["duration"] as? Int ?? (json["dt"] as? Int) ?? 0
        duration = Double(ms) / 1000.0
        source = .netease
        qqMid = nil
        qqMediaMid = nil
        kugouHash = nil
        kugouAlbumAudioId = nil
        kugouAlbumId = nil
        kugouQualityHashes = nil
        synologyId = nil
        synologyServerScope = nil
        synologyPath = nil
        subsonicId = nil
        subsonicServerScope = nil
        jellyfinId = nil
        jellyfinServerScope = nil
        webdavPath = nil
        webdavServerScope = nil
        localRelativePath = nil
        albumArtist = nil
        genre = nil
        year = nil
        comment = nil
        if let cdStr = json["cd"] as? String {
            discNumber = Int(cdStr) ?? 1
        } else if let cdVal = json["cd"] as? Int {
            discNumber = cdVal
        } else if let discVal = json["disc"] as? Int {
            discNumber = discVal
        } else if let discStr = json["disc"] as? String {
            discNumber = Int(discStr) ?? 1
        } else if let discNoVal = json["discNo"] as? Int ?? json["disc_no"] as? Int {
            discNumber = discNoVal
        } else {
            discNumber = 1
        }
        trackNumber = json["no"] as? Int ?? (json["track"] as? Int ?? (json["trackNo"] as? Int ?? (json["trackNumber"] as? Int ?? (json["track_number"] as? Int ?? 0))))
        fee = json["fee"] as? Int ?? 0
    }

    private enum CodingKeys: String, CodingKey { case id, name, artists, album, coverURL, duration, source, qqMid, qqMediaMid, kugouHash, kugouAlbumAudioId, kugouAlbumId, kugouQualityHashes, synologyId, synologyServerScope, synologyPath, subsonicId, subsonicServerScope, jellyfinId, jellyfinServerScope, webdavPath, webdavServerScope, localRelativePath, albumArtist, genre, year, comment, discNumber, trackNumber, fee }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        artists = try c.decodeIfPresent(String.self, forKey: .artists) ?? ""
        album = try c.decodeIfPresent(String.self, forKey: .album) ?? ""
        _coverURL = try c.decodeIfPresent(URL.self, forKey: .coverURL)
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        source = try c.decodeIfPresent(SongSource.self, forKey: .source) ?? .netease
        qqMid = try c.decodeIfPresent(String.self, forKey: .qqMid)
        qqMediaMid = try c.decodeIfPresent(String.self, forKey: .qqMediaMid)
        kugouHash = try c.decodeIfPresent(String.self, forKey: .kugouHash)
        kugouAlbumAudioId = try c.decodeIfPresent(String.self, forKey: .kugouAlbumAudioId)
        kugouAlbumId = try c.decodeIfPresent(String.self, forKey: .kugouAlbumId)
        kugouQualityHashes = try c.decodeIfPresent([String: String].self, forKey: .kugouQualityHashes)
        synologyId = try c.decodeIfPresent(String.self, forKey: .synologyId)
        synologyServerScope = try c.decodeIfPresent(String.self, forKey: .synologyServerScope)
        synologyPath = try c.decodeIfPresent(String.self, forKey: .synologyPath)
        subsonicId = try c.decodeIfPresent(String.self, forKey: .subsonicId)
        subsonicServerScope = try c.decodeIfPresent(String.self, forKey: .subsonicServerScope)
        jellyfinId = try c.decodeIfPresent(String.self, forKey: .jellyfinId)
        jellyfinServerScope = try c.decodeIfPresent(String.self, forKey: .jellyfinServerScope)
        webdavPath = try c.decodeIfPresent(String.self, forKey: .webdavPath)
        webdavServerScope = try c.decodeIfPresent(String.self, forKey: .webdavServerScope)
        localRelativePath = try c.decodeIfPresent(String.self, forKey: .localRelativePath)
        albumArtist = try c.decodeIfPresent(String.self, forKey: .albumArtist)
        genre = try c.decodeIfPresent(String.self, forKey: .genre)
        year = try c.decodeIfPresent(String.self, forKey: .year)
        comment = try c.decodeIfPresent(String.self, forKey: .comment)
        discNumber = try c.decodeIfPresent(Int.self, forKey: .discNumber) ?? 1
        trackNumber = try c.decodeIfPresent(Int.self, forKey: .trackNumber) ?? 0
        fee = try c.decodeIfPresent(Int.self, forKey: .fee) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(artists, forKey: .artists)
        try c.encode(album, forKey: .album)
        try c.encodeIfPresent(_coverURL ?? coverURL, forKey: .coverURL)
        try c.encode(duration, forKey: .duration)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(qqMid, forKey: .qqMid)
        try c.encodeIfPresent(qqMediaMid, forKey: .qqMediaMid)
        try c.encodeIfPresent(kugouHash, forKey: .kugouHash)
        try c.encodeIfPresent(kugouAlbumAudioId, forKey: .kugouAlbumAudioId)
        try c.encodeIfPresent(kugouAlbumId, forKey: .kugouAlbumId)
        try c.encodeIfPresent(kugouQualityHashes, forKey: .kugouQualityHashes)
        try c.encodeIfPresent(synologyId, forKey: .synologyId)
        try c.encodeIfPresent(synologyServerScope, forKey: .synologyServerScope)
        try c.encodeIfPresent(synologyPath, forKey: .synologyPath)
        try c.encodeIfPresent(subsonicId, forKey: .subsonicId)
        try c.encodeIfPresent(subsonicServerScope, forKey: .subsonicServerScope)
        try c.encodeIfPresent(jellyfinId, forKey: .jellyfinId)
        try c.encodeIfPresent(jellyfinServerScope, forKey: .jellyfinServerScope)
        try c.encodeIfPresent(webdavPath, forKey: .webdavPath)
        try c.encodeIfPresent(webdavServerScope, forKey: .webdavServerScope)
        try c.encodeIfPresent(localRelativePath, forKey: .localRelativePath)
        try c.encodeIfPresent(albumArtist, forKey: .albumArtist)
        try c.encodeIfPresent(genre, forKey: .genre)
        try c.encodeIfPresent(year, forKey: .year)
        try c.encodeIfPresent(comment, forKey: .comment)
        try c.encode(discNumber, forKey: .discNumber)
        try c.encode(trackNumber, forKey: .trackNumber)
        try c.encode(fee, forKey: .fee)
    }
}

extension Song {
    /// Compatibility names used by the iPad and watch companion views.
    var title: String { name }
    var artist: String { artists }
}

/// 歌手搜索结果（网易云 / QQ音乐通用）
struct Artist: Identifiable, Hashable {
    let id: String
    let name: String
    let coverURL: URL?
    let source: SongSource

    /// 平台内 ID 不能直接作为聚合列表身份：不同平台可能返回相同数字 ID，
    /// 某些接口还会返回空 ID。把来源和内容兜底一并纳入，保证 SwiftUI 不会
    /// 将两个平台的歌手误复用为同一个视图。
    var identityKey: String {
        let remoteID = id.isEmpty
            ? name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            : id
        return "\(source.rawValue)|\(remoteID)"
    }
}

/// 专辑搜索结果（网易云 / QQ音乐通用）
struct Album: Identifiable, Hashable {
    let id: String
    let name: String
    let artistName: String
    let coverURL: URL?
    let source: SongSource
    var trackCount: Int?

    /// 聚合列表使用跨平台稳定身份，避免专辑卡片在多音源回包时跳动或消失。
    var identityKey: String {
        let fallback = "\(name)|\(artistName)"
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let remoteID = id.isEmpty ? fallback : id
        return "\(source.rawValue)|\(remoteID)"
    }
}

struct Playlist: Identifiable, Hashable, Codable {
    let id: Int
    let name: String
    var coverURL: URL?
    let trackCount: Int
    var creatorName: String
    let specialType: Int
    /// 歌单来源（网易云 / QQ音乐），非网易云歌单用对应接口加载
    let source: SongSource
    /// 群晖 Audio Station 的原始歌单 ID。它可能是字符串路径，不能用 Swift 的 hashValue 代替。
    let synologyPlaylistId: String?
    /// Subsonic/OpenSubsonic 歌单 ID
    var subsonicPlaylistId: String? = nil
    /// Jellyfin 歌单 ID（GUID）
    var jellyfinPlaylistId: String? = nil
    /// WebDAV 服务器上承载歌单的 .m3u 文件路径
    var webdavPlaylistPath: String? = nil
    /// 平台返回的热度值（播放量/收藏量等），用于聚合歌单搜索的次级排序。
    var popularity: Int? = nil
    /// 搜索/详情接口返回的歌单简介；缺失时保持 nil，兼容历史本地缓存。
    var descriptionText: String? = nil

    /// 聚合列表必须把平台纳入身份。不同平台的纯数字歌单 ID 经常重复，
    /// 直接使用 `id` 会让 SwiftUI 错误复用视图并产生闪烁。
    var identityKey: String {
        let remoteID = synologyPlaylistId ?? subsonicPlaylistId ?? jellyfinPlaylistId ?? webdavPlaylistPath ?? String(id)
        return "\(source.rawValue)|\(remoteID)"
    }

    init(id: Int, name: String, coverURL: URL?, trackCount: Int = 0, source: SongSource = .netease, synologyPlaylistId: String? = nil, subsonicPlaylistId: String? = nil, jellyfinPlaylistId: String? = nil, webdavPlaylistPath: String? = nil) {
        self.id = id
        self.name = name
        self.coverURL = coverURL
        self.trackCount = trackCount
        self.creatorName = ""
        self.specialType = 0
        self.source = source
        self.synologyPlaylistId = synologyPlaylistId
        self.subsonicPlaylistId = subsonicPlaylistId
        self.jellyfinPlaylistId = jellyfinPlaylistId
        self.webdavPlaylistPath = webdavPlaylistPath
    }

    init?(json: [String: Any]) {
        guard let id = json["id"] as? Int else { return nil }
        self.id = id
        name = json["name"] as? String ?? ""
        trackCount = json["trackCount"] as? Int ?? 0
        let pic = json["coverImgUrl"] as? String ?? json["picUrl"] as? String ?? ""
        coverURL = pic.isEmpty ? nil : URL(string: pic)
        creatorName = (json["creator"] as? [String: Any])?["nickname"] as? String ?? ""
        specialType = json["specialType"] as? Int ?? 0
        source = .netease
        synologyPlaylistId = nil
        descriptionText = (json["description"] as? String)
            ?? (json["copywriter"] as? String)
    }

    init?(personalizedJSON json: [String: Any]) {
        guard let id = json["id"] as? Int else { return nil }
        self.id = id
        name = json["name"] as? String ?? ""
        trackCount = 0
        let pic = json["picUrl"] as? String ?? ""
        coverURL = pic.isEmpty ? nil : URL(string: pic)
        creatorName = ""
        specialType = json["specialType"] as? Int ?? 0
        source = .netease
        synologyPlaylistId = nil
    }

    var isNetEaseLikedPlaylist: Bool {
        source == .netease && (specialType == 5 || name == "我喜欢的音乐" || name.localizedCaseInsensitiveContains("liked songs"))
    }
}

struct TopList: Identifiable, Hashable, Codable {
    let id: Int
    let name: String
    let coverURL: URL?
    let updateFrequency: String

    init?(json: [String: Any]) {
        guard let id = json["id"] as? Int else { return nil }
        self.id = id
        name = json["name"] as? String ?? ""
        let pic = json["coverImgUrl"] as? String ?? ""
        coverURL = pic.isEmpty ? nil : URL(string: pic)
        updateFrequency = json["updateFrequency"] as? String ?? ""
    }
}

/// QQ 峰尖榜总览项
struct QQTopInfo: Identifiable, Hashable, Codable {
    let id: Int
    let name: String
    let subTitle: String
    let topSongNames: [String]
    let coverURL: URL?
}

/// 酷狗官方排行榜总览项
struct KugouTopInfo: Identifiable, Hashable, Codable {
    let id: Int
    let name: String
    let updateFrequency: String
    let coverURL: URL?
}

struct LyricLine: Identifiable, Hashable {
    let id: UUID
    let time: Double
    let text: String
    /// 歌词翻译（网易云 tlyric，可空）
    var translation: String?

    init(time: Double, text: String, translation: String? = nil) {
        self.id = UUID()
        self.time = time
        self.text = text
        self.translation = translation
    }
}

enum LyricParser {
    /// 解析歌词；可选传入翻译歌词（网易云 tlyric），按时间戳合并到对应行
    static func parse(_ raw: String, translationRaw: String? = nil) -> [LyricLine] {
        var lines = parseCore(raw, offset: declaredOffsetSeconds(in: raw))
        if let translationRaw, !translationRaw.isEmpty {
            let trans = parseCore(translationRaw, offset: declaredOffsetSeconds(in: translationRaw))
            var byTime: [Double: String] = [:]
            for t in trans where !t.text.isEmpty {
                byTime[t.time] = t.text
            }
            for i in lines.indices {
                if let tr = byTime[lines[i].time], !tr.isEmpty {
                    lines[i].translation = tr
                    continue
                }
                // 跨源翻译（如 NAS 歌曲挂网易/QQ 的翻译）与原文时间戳常有零点几秒偏差，
                // 精确同刻对不上时就近挂到容差内最近的翻译行，避免整份翻译失效。
                var bestDelta = 0.6
                var bestText: String? = nil
                for t in trans where !t.text.isEmpty {
                    let delta = abs(t.time - lines[i].time)
                    if delta <= bestDelta {
                        bestDelta = delta
                        bestText = t.text
                    }
                }
                if let bestText {
                    lines[i].translation = bestText
                }
            }
        }
        return lines
    }

    private static func parseCore(_ raw: String, offset: Double) -> [LyricLine] {
        var lines: [LyricLine] = []
        for line in raw.components(separatedBy: .newlines) {
            parseTimes(in: line).forEach { time in
                let text = line.replacingOccurrences(of: #"\[\d{2}:\d{2}(\.\d{1,3})?\]"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                lines.append(LyricLine(time: max(0, time + offset), text: text))
            }
        }
        return lines.sorted { $0.time < $1.time }
    }

    private static func declaredOffsetSeconds(in raw: String) -> Double {
        let pattern = #"\[offset:([+-]?\d+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let range = Range(match.range(at: 1), in: raw),
              let milliseconds = Double(raw[range]) else {
            return 0
        }
        return milliseconds / 1000.0
    }

    private static func parseTimes(in line: String) -> [Double] {
        var times: [Double] = []
        let pattern = #"\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]"#
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(line.startIndex..., in: line)
        regex?.enumerateMatches(in: line, options: [], range: range) { match, _, _ in
            guard let match else { return }
            guard let minuteRange = Range(match.range(at: 1), in: line),
                  let secondRange = Range(match.range(at: 2), in: line) else { return }
            let minutes = Double(line[minuteRange]) ?? 0
            let seconds = Double(line[secondRange]) ?? 0
            var fraction = 0.0
            if match.numberOfRanges > 3, let fracRange = Range(match.range(at: 3), in: line) {
                let raw = String(line[fracRange])
                fraction = (Double(raw) ?? 0) / pow(10, Double(max(raw.count, 1)))
            }
            times.append(minutes * 60 + seconds + fraction)
        }
        return times
    }
}

enum LyricTiming {
    static let userOffsetKey = "atmusic.lyricOffset"

    static func effectiveProgress(_ progress: Double, userOffset: Double? = nil) -> Double {
        let offset = userOffset ?? UserDefaults.standard.double(forKey: userOffsetKey)
        return max(0, progress + offset)
    }

    static func seekTime(for line: LyricLine, userOffset: Double? = nil) -> Double {
        let offset = userOffset ?? UserDefaults.standard.double(forKey: userOffsetKey)
        return max(0, line.time - offset)
    }
}

struct NetEaseUser: Identifiable, Hashable, Codable {
    let uid: Int
    let nickname: String
    let avatarURL: URL?
    /// 网易云会员类型：0 无会员；非 0 有 VIP；>= 11 为黑胶 SVIP（接口字段 profile.vipType）
    let vipType: Int

    var id: Int { uid }

    /// VIP 标识：nil 表示无会员
    var vipBadge: String? {
        if vipType >= 11 { return "SVIP" }
        if vipType > 0 { return "VIP" }
        return nil
    }

    init?(json: [String: Any]) {
        guard let id = json["userId"] as? Int ?? (json["id"] as? Int) else { return nil }
        uid = id
        nickname = json["nickname"] as? String ?? ""
        let pic = json["avatarUrl"] as? String ?? ""
        avatarURL = pic.isEmpty ? nil : URL(string: pic)
        vipType = json["vipType"] as? Int ?? 0
    }

    enum CodingKeys: String, CodingKey { case uid, nickname, avatarURL, vipType }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uid = try c.decode(Int.self, forKey: .uid)
        nickname = try c.decode(String.self, forKey: .nickname)
        avatarURL = try c.decodeIfPresent(URL.self, forKey: .avatarURL)
        vipType = try c.decodeIfPresent(Int.self, forKey: .vipType) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(uid, forKey: .uid)
        try c.encode(nickname, forKey: .nickname)
        try c.encodeIfPresent(avatarURL, forKey: .avatarURL)
        try c.encode(vipType, forKey: .vipType)
    }
}
/// 听歌排行条目（网易云听歌记录）
struct PlayRecordItem: Identifiable, Hashable {
    let song: Song
    let playCount: Int
    var id: Int { song.id }
}

/// 听歌排行结果（列表 + 真实总数，避免被接口单次上限截断）
struct PlayRecordResult {
    let items: [PlayRecordItem]
    let totalCount: Int
}

// MARK: - 歌曲评论

struct SongComment: Identifiable, Hashable {
    let id: Int
    let content: String
    let nickname: String
    let avatarURL: URL?
    let time: Date
    let likedCount: Int
    let isHot: Bool

    init(id: Int, content: String, nickname: String, avatarURL: URL?, time: Date, likedCount: Int, isHot: Bool = false) {
        self.id = id
        self.content = content
        self.nickname = nickname
        self.avatarURL = avatarURL
        self.time = time
        self.likedCount = likedCount
        self.isHot = isHot
    }

    init?(json: [String: Any], isHot: Bool = false) {
        guard let id = json["commentId"] as? Int else { return nil }
        self.id = id
        content = json["content"] as? String ?? ""
        let user = json["user"] as? [String: Any]
        nickname = user?["nickname"] as? String ?? ""
        let avatar = user?["avatarUrl"] as? String ?? ""
        avatarURL = avatar.isEmpty ? nil : URL(string: avatar)
        let ms = json["time"] as? Int ?? 0
        time = Date(timeIntervalSince1970: Double(ms) / 1000.0)
        likedCount = json["likedCount"] as? Int ?? 0
        self.isHot = isHot
    }
}

// MARK: - 搜索提供方

enum SearchProvider: String, CaseIterable, Identifiable, Hashable, Sendable {
    case netease = "网易云音乐"
    case qq = "QQ音乐"
    case kugou = "酷狗音乐"
    case synology = "群晖 NAS"
    case subsonic = "Subsonic"
    case jellyfin = "Jellyfin"
    case webdav = "WebDAV"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .netease: return "cloud.fill"
        case .qq: return "play.rectangle.fill"
        case .kugou: return "music.note"
        case .synology: return "externaldrive.fill"
        case .subsonic: return "server.rack"
        case .jellyfin: return "play.tv.fill"
        case .webdav: return "folder.fill.badge.gearshape"
        }
    }

    var brandImageName: String? {
        switch self {
        case .netease: return "BrandNetease"
        case .qq: return "BrandQQ"
        case .kugou: return "BrandKugou"
        case .synology, .subsonic, .jellyfin, .webdav: return nil
        }
    }
}
