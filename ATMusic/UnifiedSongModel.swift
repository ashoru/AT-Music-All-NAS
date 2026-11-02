import Foundation

// MARK: - 歌曲来源枚举扩充

/// 统一音乐来源类型（支持网易云、QQ音乐、酷狗音乐、群晖NAS、以及本地导入音频）
enum SongSourceType: String, Codable, CaseIterable, Hashable, Sendable {
    case netease
    case qq
    case kugou
    case synology
    case subsonic
    case jellyfin
    case webdav
    case local

    var displayName: String {
        switch self {
        case .netease: return "网易云音乐"
        case .qq: return "QQ音乐"
        case .kugou: return "酷狗音乐"
        case .synology: return "群晖 NAS"
        case .subsonic: return "Subsonic"
        case .jellyfin: return "Jellyfin"
        case .webdav: return "WebDAV"
        case .local: return "本地音乐"
        }
    }

    /// 与既有 SongSource 枚举的互转
    init(legacySource: SongSource) {
        switch legacySource {
        case .netease: self = .netease
        case .qq: self = .qq
        case .kugou: self = .kugou
        case .synology: self = .synology
        case .subsonic: self = .subsonic
        case .jellyfin: self = .jellyfin
        case .webdav: self = .webdav
        case .local: self = .local
        }
    }

    var legacySource: SongSource? {
        switch self {
        case .netease: return .netease
        case .qq: return .qq
        case .kugou: return .kugou
        case .synology: return .synology
        case .subsonic: return .subsonic
        case .jellyfin: return .jellyfin
        case .webdav: return .webdav
        case .local: return nil // 本地文件不是 NAS；由本地适配器处理。
        }
    }
}

// MARK: - 歌曲版本分类（防止现场版、翻唱、伴奏等不同版本被错误合并）

enum SongVersionKind: String, Codable, Hashable, Sendable {
    case studio       // 标准录音室版 / 原版
    case live         // 现场演出 / 演唱会版
    case instrumental // 伴奏 / 纯音乐 / Karaoke
    case remix        // 混音 / DJ / 变奏
    case cover        // 翻唱版
    case speedup      // 加速 / 减速 / 变调版
    case acoustic     // 不插电 / 木吉他版
    case other        // 其他特定标注版本

    var label: String {
        switch self {
        case .studio: return "原版"
        case .live: return "现场版"
        case .instrumental: return "伴奏"
        case .remix: return "Remix"
        case .cover: return "翻唱"
        case .speedup: return "调速版"
        case .acoustic: return "不插电"
        case .other: return "特殊版本"
        }
    }

    /// 根据歌名和歌手字符串自动识别版本类型
    static func detect(title: String, artist: String = "") -> SongVersionKind {
        let combined = SongIdentityNormalizer.toSimplified(title).lowercased()

        // 伴奏 / 纯音乐识别
        if combined.contains("伴奏") || combined.contains("instrumental")
            || combined.contains("karaoke") || combined.contains("inst.")
            || combined.contains("off vocal") || combined.contains("纯音乐") {
            return .instrumental
        }

        // 现场版 / 演唱会识别
        if combined.range(of: #"\blive\b"#, options: .regularExpression) != nil || combined.contains("现场")
            || combined.contains("演唱会") || combined.contains("音乐节")
            || combined.contains("unplugged live") {
            return .live
        }

        // 不插电
        if combined.contains("acoustic") || combined.contains("不插电") {
            return .acoustic
        }

        // 混音 / DJ
        if combined.contains("remix") || combined.contains("dj版")
            || combined.contains("club mix") || combined.contains("extended mix") {
            return .remix
        }

        // 调速版
        if combined.contains("sped up") || combined.contains("slowed")
            || combined.contains("加速版") || combined.contains("减速版")
            || combined.contains("nightcore") {
            return .speedup
        }

        // 翻唱
        if combined.range(of: #"\bcover\b"#, options: .regularExpression) != nil || combined.contains("翻唱") {
            return .cover
        }

        return .studio
    }
}

// MARK: - 来源记录（SongSourceRecord）：保留各平台/NAS/本地原始身份与上下文

struct SongSourceRecord: Identifiable, Codable, Hashable, Sendable {
    /// 来源全局唯一键（格式例如：`netease:12345`、`qq:001aBC`、`synology:srvHash:acc:syno123`、`local:fileHash`）
    let id: String
    /// 来源平台
    let sourceType: SongSourceType
    /// 平台上的原始 ID（如网易云数字ID、QQ songmid、群晖 ID、本地文件ID）
    let remoteId: String
    /// 针对群晖 NAS 的多服务器 / 账号隔离作用域标识（如 `host:port/account`），非 NAS 时为 nil
    let serverScope: String?

    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let coverURL: URL?
    let isVIP: Bool
    let fee: Int

    /// 各平台专属的附加信息（如 QQ 的 songmid/mediaMid、酷狗的 hash/albumAudioId、本地文件的相对路径等）
    var extraAttributes: [String: String]

    init(
        id: String,
        sourceType: SongSourceType,
        remoteId: String,
        serverScope: String? = nil,
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        coverURL: URL? = nil,
        isVIP: Bool = false,
        fee: Int = 0,
        extraAttributes: [String: String] = [:]
    ) {
        self.id = id
        self.sourceType = sourceType
        self.remoteId = remoteId
        self.serverScope = serverScope
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.coverURL = coverURL
        self.isVIP = isVIP
        self.fee = fee
        self.extraAttributes = extraAttributes
    }

    /// 从现有旧版 `Song` 生成来源记录，并绑定指定的群晖服务器作用域（如有）
    init(legacySong: Song, serverScope: String? = nil) {
        let st = SongSourceType(legacySource: legacySong.source)
        self.sourceType = st
        self.title = legacySong.name
        self.artist = legacySong.artists
        self.album = legacySong.album
        self.duration = legacySong.duration
        self.coverURL = legacySong.coverURL
        self.isVIP = legacySong.isVIP
        self.fee = legacySong.fee

        var extras: [String: String] = ["legacyNumericId": String(legacySong.id)]
        if let hashes = legacySong.kugouQualityHashes,
           let data = try? JSONEncoder().encode(hashes) {
            extras["kugouQualityHashes"] = String(data: data, encoding: .utf8)
        }
        if let mid = legacySong.qqMid { extras["qqMid"] = mid }
        if let mmid = legacySong.qqMediaMid { extras["qqMediaMid"] = mmid }
        if let hash = legacySong.kugouHash { extras["kugouHash"] = hash }
        if let aaid = legacySong.kugouAlbumAudioId { extras["kugouAlbumAudioId"] = aaid }
        if let aid = legacySong.kugouAlbumId { extras["kugouAlbumId"] = aid }
        if let sid = legacySong.synologyId { extras["synologyId"] = sid }
        if let sid = legacySong.subsonicId { extras["subsonicId"] = sid }
        if let jid = legacySong.jellyfinId { extras["jellyfinId"] = jid }
        if let wpath = legacySong.webdavPath { extras["webdavPath"] = wpath }

        switch st {
        case .netease:
            self.remoteId = "\(legacySong.id)"
            self.serverScope = nil
            self.id = "netease:\(legacySong.id)"
        case .qq:
            self.remoteId = legacySong.qqMid ?? "\(legacySong.id)"
            self.serverScope = nil
            self.id = "qq:\(self.remoteId)"
        case .kugou:
            self.remoteId = legacySong.kugouHash ?? legacySong.kugouAlbumAudioId ?? "\(legacySong.id)"
            self.serverScope = nil
            self.id = "kugou:\(self.remoteId)"
        case .synology:
            let serverScope = legacySong.synologyServerScope ?? serverScope
            let synoId = legacySong.synologyId ?? "\(legacySong.id)"
            self.remoteId = synoId
            self.serverScope = serverScope
            if let scope = serverScope, !scope.isEmpty {
                self.id = "synology:\(scope):\(synoId)"
            } else {
                self.id = "synology:\(synoId)"
            }
        case .subsonic:
            let serverScope = legacySong.subsonicServerScope ?? serverScope
            let subId = legacySong.subsonicId ?? "\(legacySong.id)"
            self.remoteId = subId
            self.serverScope = serverScope
            if let scope = serverScope, !scope.isEmpty {
                self.id = "subsonic:\(scope):\(subId)"
            } else {
                self.id = "subsonic:\(subId)"
            }
        case .jellyfin:
            let serverScope = legacySong.jellyfinServerScope ?? serverScope
            let jfId = legacySong.jellyfinId ?? "\(legacySong.id)"
            self.remoteId = jfId
            self.serverScope = serverScope
            if let scope = serverScope, !scope.isEmpty {
                self.id = "jellyfin:\(scope):\(jfId)"
            } else {
                self.id = "jellyfin:\(jfId)"
            }
        case .webdav:
            let serverScope = legacySong.webdavServerScope ?? serverScope
            let path = legacySong.webdavPath ?? "\(legacySong.id)"
            self.remoteId = path
            self.serverScope = serverScope
            if let scope = serverScope, !scope.isEmpty {
                self.id = "webdav:\(scope):\(path)"
            } else {
                self.id = "webdav:\(path)"
            }
        case .local:
            self.remoteId = "\(legacySong.id)"
            self.serverScope = nil
            self.id = "local:\(legacySong.id)"
        }
        self.extraAttributes = extras
    }
}

// MARK: - 可播放资源（PlayableResource）：执行播放时动态决定的真实可用资源

enum PlayableResourceKind: Codable, Hashable, Sendable {
    case localFile(relativePath: String, isUserImported: Bool)
    case nasStream(streamURL: URL, serverScope: String)
    case onlineStream(streamURL: URL, isThirdParty: Bool)
}

struct PlayableResource: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let sourceRecordId: String
    let kind: PlayableResourceKind
    /// 请求音质不等于服务器实际音质；未验证时 actualQuality 必须为 nil。
    let quality: ThirdPartyAudioQuality
    let actualQuality: ThirdPartyAudioQuality?
    let isOfflineAvailable: Bool
    let expirationDate: Date?
    let headers: [String: String]

    init(
        id: String = UUID().uuidString,
        sourceRecordId: String,
        kind: PlayableResourceKind,
        quality: ThirdPartyAudioQuality,
        isOfflineAvailable: Bool,
        actualQuality: ThirdPartyAudioQuality? = nil,
        expirationDate: Date? = nil,
        headers: [String: String] = [:]
    ) {
        self.id = id
        self.sourceRecordId = sourceRecordId
        self.kind = kind
        self.quality = quality
        self.actualQuality = actualQuality
        self.isOfflineAvailable = isOfflineAvailable
        self.expirationDate = expirationDate
        self.headers = headers
    }
}

// MARK: - 统一歌曲模型（UnifiedSong）：规范化身份 + 多来源关联 + 版本保护

struct UnifiedSong: Identifiable, Codable, Hashable, Sendable {
    /// 全局稳定 Canonical ID
    let id: String
    /// 规范化歌名
    let title: String
    /// 规范化主要歌手
    let artist: String
    /// 规范化专辑
    let album: String
    /// 版本类型（录音室原版、现场版、伴奏、翻唱等）
    let versionKind: SongVersionKind
    /// 参考时长
    let duration: TimeInterval
    /// 关联的所有来源记录（可对应不同平台或 NAS/本地副本）
    var sources: [SongSourceRecord]
    /// 用户手动指定的固定播放来源（若设置则不自动切换其他平台）
    var preferredSourceType: SongSourceType?
    /// 首选封面
    var coverURL: URL?

    init(
        id: String? = nil,
        title: String,
        artist: String,
        album: String,
        versionKind: SongVersionKind? = nil,
        duration: TimeInterval,
        sources: [SongSourceRecord] = [],
        preferredSourceType: SongSourceType? = nil,
        coverURL: URL? = nil
    ) {
        let vk = versionKind ?? SongVersionKind.detect(title: title, artist: artist)
        self.title = title
        self.artist = artist
        self.album = album
        self.versionKind = vk
        self.duration = duration
        self.sources = sources
        self.preferredSourceType = preferredSourceType
        self.coverURL = coverURL ?? sources.compactMap(\.coverURL).first

        if let id, !id.isEmpty {
            self.id = id
        } else {
            // 身份来自原始来源，不以模糊的歌名/歌手猜测录音身份。
            // 无来源的草稿各自拥有独立 ID；后续人工确认合并才关联多个来源。
            self.id = sources.first.map { "usong:" + $0.id } ?? "usong:" + UUID().uuidString
        }
    }

    /// 从现有旧版 `Song` 生成 `UnifiedSong`
    init(legacySong: Song, serverScope: String? = nil) {
        let record = SongSourceRecord(legacySong: legacySong, serverScope: serverScope)
        let vk = SongVersionKind.detect(title: legacySong.name, artist: legacySong.artists)
        self.init(
            id: nil,
            title: legacySong.name,
            artist: legacySong.artists,
            album: legacySong.album,
            versionKind: vk,
            duration: legacySong.duration,
            sources: [record],
            preferredSourceType: record.sourceType,
            coverURL: legacySong.coverURL
        )
    }

    /// 导出为旧版 `Song` 以便无缝复用现有播放与 UI 组件
    func toLegacySong(preferredSource: SongSourceType? = nil) -> Song? {
        let targetType = preferredSource ?? self.preferredSourceType
        let selectedRecord: SongSourceRecord
        if let targetType, let matched = sources.first(where: { $0.sourceType == targetType }) {
            selectedRecord = matched
        } else {
            selectedRecord = sources.first ?? SongSourceRecord(
                id: "local:\(id)",
                sourceType: .local,
                remoteId: id,
                title: title,
                artist: artist,
                album: album,
                duration: duration,
                coverURL: coverURL
            )
        }

        guard let legacySource = selectedRecord.sourceType.legacySource else { return nil }
        let numericId: Int
        if let parsedInt = Int(selectedRecord.extraAttributes["legacyNumericId"] ?? selectedRecord.remoteId) {
            numericId = parsedInt
        } else {
            numericId = Self.stableNumericHash(selectedRecord.id)
        }

        return Song(
            id: numericId,
            name: selectedRecord.title,
            artists: selectedRecord.artist,
            album: selectedRecord.album,
            coverURL: selectedRecord.coverURL,
            duration: selectedRecord.duration,
            source: legacySource,
            qqMid: selectedRecord.extraAttributes["qqMid"],
            qqMediaMid: selectedRecord.extraAttributes["qqMediaMid"],
            kugouHash: selectedRecord.extraAttributes["kugouHash"],
            kugouAlbumAudioId: selectedRecord.extraAttributes["kugouAlbumAudioId"],
            kugouAlbumId: selectedRecord.extraAttributes["kugouAlbumId"],
            kugouQualityHashes: selectedRecord.extraAttributes["kugouQualityHashes"].flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) },
            synologyId: selectedRecord.extraAttributes["synologyId"] ?? (selectedRecord.sourceType == .synology ? selectedRecord.remoteId : nil),
            synologyServerScope: selectedRecord.sourceType == .synology ? selectedRecord.serverScope : nil,
            subsonicId: selectedRecord.extraAttributes["subsonicId"] ?? (selectedRecord.sourceType == .subsonic ? selectedRecord.remoteId : nil),
            subsonicServerScope: selectedRecord.sourceType == .subsonic ? selectedRecord.serverScope : nil,
            jellyfinId: selectedRecord.extraAttributes["jellyfinId"] ?? (selectedRecord.sourceType == .jellyfin ? selectedRecord.remoteId : nil),
            jellyfinServerScope: selectedRecord.sourceType == .jellyfin ? selectedRecord.serverScope : nil,
            webdavPath: selectedRecord.extraAttributes["webdavPath"] ?? (selectedRecord.sourceType == .webdav ? selectedRecord.remoteId : nil),
            webdavServerScope: selectedRecord.sourceType == .webdav ? selectedRecord.serverScope : nil,
            fee: selectedRecord.fee
        )
    }

    // MARK: - 多来源安全合并与防误判规则

    /// 判断另一个 UnifiedSong 是否为同一录音版本，决定能否安全合并来源
    /// 核心安全原则：
    /// 1. versionKind 必须完全一致（现场版不能并入原版、伴奏不能并入原曲、翻唱不能并入原唱）
    /// 2. 歌手经过规范化和别名映射后必须兼容
    /// 3. 时长差异必须在安全容差（15秒）之内（排除截断或完整不同录音）
    func canSafelyMerge(with other: UnifiedSong) -> Bool {
        // 规则 1：版本类型必须一致
        guard self.versionKind == other.versionKind else { return false }

        // 规则 2：歌名核心特征匹配
        let normA = SongIdentityNormalizer.exactMetadata(self.title)
        let normB = SongIdentityNormalizer.exactMetadata(other.title)
        guard !normA.isEmpty, normA == normB else {
            return false
        }

        // 规则 3：歌手匹配（支持简繁和中英文别名对照）
        guard SongIdentityNormalizer.isArtistCompatible(artistA: self.artist, artistB: other.artist) else {
            return false
        }

        // 规则 4：时长接近（若两边均有时长数据，相差不得超过 15 秒）
        let albumKey = SongIdentityNormalizer.exactMetadata(album)
        return !albumKey.isEmpty && albumKey == SongIdentityNormalizer.exactMetadata(other.album)
            && duration.isFinite && other.duration.isFinite && duration > 0 && other.duration > 0
            && abs(duration - other.duration) <= 2
    }

    /// 将新的来源合并进当前歌曲（若已存在同平台同 remoteId 的来源则更新元数据，否则追加）
    mutating func addOrUpdateSource(_ newSource: SongSourceRecord) {
        if let index = sources.firstIndex(where: { $0.id == newSource.id }) {
            sources[index] = newSource
        } else {
            sources.append(newSource)
        }
        if coverURL == nil, let newCover = newSource.coverURL {
            coverURL = newCover
        }
    }

    // MARK: - 辅助计算

    private static func makeCanonicalID(title: String, artist: String, version: SongVersionKind) -> String {
        let normTitle = SongIdentityNormalizer.normalizeTitle(title)
        let normArtist = SongIdentityNormalizer.primaryArtist(artist)
        let raw = "\(normTitle)|\(normArtist)|\(version.rawValue)"
        let hash = stableNumericHash(raw)
        return "usong_\(abs(hash))"
    }

    static func stableNumericHash(_ string: String) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let positive = Int(hash & 0x7fff_ffff_ffff_ffff)
        return positive == 0 ? 1 : positive
    }
}

// MARK: - 歌曲身份与别名规范化引擎

enum SongIdentityNormalizer {
    static func exactMetadata(_ value: String) -> String {
        toSimplified(value).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 不拆开 AC/DC，也不丢弃合作歌手；别名只允许整个名字精确命中。
    static func artistIdentity(_ value: String) -> String {
        let key = exactMetadata(value)
        return artistAliasMap[key] ?? key
    }
    /// 常见中英文艺名与别名映射表
    private static let artistAliasMap: [String: String] = [
        "jay chou": "周杰伦",
        "eason chan": "陈奕迅",
        "jj lin": "林俊杰",
        "faye wong": "王菲",
        "david tao": "陶喆",
        "leehom wang": "王力宏",
        "stefanie sun": "孙燕姿",
        "jolin tsai": "蔡依林",
        "g.e.m.": "邓紫棋",
        "gem": "邓紫棋",
        "mayday": "五月天",
        "sodagreen": "苏打绿"
    ]

    /// 简繁体转换对照表
    private static let simplifiedMap: [Character: Character] = [
        "倫": "伦", "華": "华", "樂": "乐", "臺": "台", "灣": "湾", "國": "国", "龍": "龙",
        "劉": "刘", "張": "张", "陳": "陈", "黃": "黄", "楊": "杨", "趙": "赵", "吳": "吴",
        "學": "学", "電": "电", "風": "风", "愛": "爱", "萬": "万", "東": "东", "後": "后",
        "來": "来", "與": "与", "這": "这", "們": "们", "見": "见", "說": "说", "聽": "听",
        "時": "时", "會": "会", "點": "点", "兒": "儿", "雲": "云", "蘇": "苏", "鄧": "邓",
        "偉": "伟", "傑": "杰", "葉": "叶", "鄭": "郑", "錢": "钱", "鍾": "钟", "劍": "剑"
    ]

    static func toSimplified(_ text: String) -> String {
        let mapped = String(text.map { simplifiedMap[$0] ?? $0 })
        return mapped.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? mapped
    }

    /// 规范化歌名：去除版本括号、前后空格、统一小写与简繁体
    static func normalizeTitle(_ rawTitle: String) -> String {
        var clean = toSimplified(rawTitle).lowercased()
        // 去除常见的版本后缀标记以提取主体歌名
        let patterns = [
            #"\s*[\(\[（【].*?(live|现场|演唱会|伴奏|remix|翻唱|cover|instrumental|sped up).*?[\)\]）】]"#,
            #"\s*-\s*(live|伴奏|remix|翻唱版|现场版).*"#
        ]
        for pat in patterns {
            clean = clean.replacingOccurrences(of: pat, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return clean.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 提取主创歌手名并规范化
    static func primaryArtist(_ artist: String) -> String {
        let simplified = toSimplified(artist).lowercased()
        let separators = CharacterSet(charactersIn: "/,&、+")
        let parts = simplified.components(separatedBy: separators)
        let first = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? simplified
        return artistAliasMap[first] ?? first
    }

    /// 判断两组歌手是否具有兼容对应关系（支持多歌手拆解及英文艺名别名对照）
    static func isArtistCompatible(artistA: String, artistB: String) -> Bool {
        let a = artistIdentity(artistA)
        return !a.isEmpty && a == artistIdentity(artistB)
    }
}

/// 长度前缀防止地址/账号分隔符碰撞；协议也是身份的一部分。
enum NASSourceScope {
    static func make(host: String, port: Int, https: Bool, account: String) -> String {
        let raw = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = URLComponents(string: raw.contains("://") ? raw : "http://" + raw)
        let hostname = (components?.host ?? raw).lowercased()
        let user = account.trimmingCharacters(in: .whitespacesAndNewlines)
        return "nas2|\(https ? "https" : "http")|\(hostname.utf8.count):\(hostname)|\(port)|\(user.utf8.count):\(user)"
    }
}
