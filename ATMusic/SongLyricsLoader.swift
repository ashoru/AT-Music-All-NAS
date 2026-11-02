import Foundation

/// 统一歌词加载与缓存协调器：
/// 1. 优先读取磁盘与内存缓存；
/// 2. 分源读取本地 .lrc / NAS / 酷狗 / QQ / 网易云官方歌词；
/// 3. 当未匹配到歌词时，跨平台智能模糊匹配补全并写入离线缓存；
/// 4. 供播放器主页与播放器布局编辑器实时联动。
enum SongLyricsLoader {
    private static var inFlightTasks: [String: Task<[LyricLine], Never>] = [:]
    private static let taskLock = NSLock()

    static func loadLyrics(for song: Song) async -> [LyricLine] {
        let identity = song.identityKey

        // 1. 优先检查本地歌词磁盘缓存
        if let cached = await ATMusicCacheCoordinator.shared.cachedLyric(for: song), !cached.isEmpty {
            let parsed = LyricParser.parse(cached, translationRaw: await ATMusicCacheCoordinator.shared.cachedLyricTranslation(for: song))
            if !parsed.isEmpty { return parsed }
        }

        taskLock.lock()
        if let existing = inFlightTasks[identity] {
            taskLock.unlock()
            return await existing.value
        }
        let task = Task<[LyricLine], Never> {
            defer {
                taskLock.lock()
                inFlightTasks.removeValue(forKey: identity)
                taskLock.unlock()
            }
            return await fetchAndParseLyrics(for: song)
        }
        inFlightTasks[identity] = task
        taskLock.unlock()
        return await task.value
    }

    private static func fetchAndParseLyrics(for song: Song) async -> [LyricLine] {
        var rawLyrics: String?
        var translationRaw: String?

        // 2. 根据音源获取
        if song.source == .local, let relativePath = song.localRelativePath {
            let lrcPath = (relativePath as NSString).deletingPathExtension + ".lrc"
            if let lrcURL = try? ManagedAudioPath.resolve(lrcPath),
               let raw = try? String(contentsOf: lrcURL, encoding: .utf8) {
                rawLyrics = raw
            }
        } else if let localFile = LocalAudioFileManager.shared.file(forSongId: song.identityKey) {
            let lrcPath = (localFile.relativePath as NSString).deletingPathExtension + ".lrc"
            if let lrcURL = try? ManagedAudioPath.resolve(lrcPath),
               let raw = try? String(contentsOf: lrcURL, encoding: .utf8) {
                rawLyrics = raw
            }
        } else if song.source == .synology {
            if let raw = try? await SynologyAPI.shared.lyrics(song: song) {
                rawLyrics = raw
            }
            // Audio Station 只有内嵌歌词、没有翻译数据；有原文时也跨源配一份翻译挂上。
            if rawLyrics != nil {
                translationRaw = await matchedTranslation(for: song)
            }
        } else if song.source == .subsonic {
            if let raw = try? await SubsonicAPI.shared.lyrics(song: song) {
                rawLyrics = raw
            }
            if rawLyrics != nil {
                translationRaw = await matchedTranslation(for: song)
            }
        } else if song.source == .jellyfin {
            if let raw = try? await JellyfinAPI.shared.lyrics(song: song) {
                rawLyrics = raw
            }
            if rawLyrics != nil {
                translationRaw = await matchedTranslation(for: song)
            }
        } else if song.source == .webdav {
            if let raw = try? await WebDAVAPI.shared.lyrics(song: song) {
                rawLyrics = raw
            }
            if rawLyrics != nil {
                translationRaw = await matchedTranslation(for: song)
            }
        } else if song.source == .kugou, let hash = song.kugouHash {
            let raw = await KugouMusicAPI.shared.lyric(hash: hash, duration: song.duration)
            if !raw.isEmpty { rawLyrics = raw }
        } else if song.source == .qq, let mid = song.qqMid {
            let result = await QQMusicAPI.shared.lyricWithTranslation(songmid: mid, songID: song.id, name: song.name, singer: song.artists, album: song.album)
            rawLyrics = result.lrc
            translationRaw = result.trans
        } else if song.source == .netease {
            if let (lrc, tlyric) = try? await NetEaseAPI.shared.lyricWithTranslation(id: song.id) {
                rawLyrics = lrc
                translationRaw = tlyric
            }
        }

        if let rawLyrics, !rawLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsed = LyricParser.parse(rawLyrics, translationRaw: translationRaw)
            if !parsed.isEmpty {
                await ATMusicCacheCoordinator.shared.cacheLyric(for: song, content: rawLyrics)
                if let translationRaw {
                    await ATMusicCacheCoordinator.shared.cacheLyricTranslation(for: song, content: translationRaw)
                }
                return parsed
            }
        }

        // 3. 跨源自动匹配（候选源的翻译一并带回，不再丢弃）
        if let matched = await autoMatchedLyrics(for: song) {
            let parsed = LyricParser.parse(matched.lrc, translationRaw: matched.trans)
            if !parsed.isEmpty {
                await ATMusicCacheCoordinator.shared.cacheLyric(for: song, content: matched.lrc)
                if let trans = matched.trans {
                    await ATMusicCacheCoordinator.shared.cacheLyricTranslation(for: song, content: trans)
                }
                return parsed
            }
        }

        return []
    }

    private static func autoMatchedLyrics(for song: Song) async -> (lrc: String, trans: String?)? {
        let candidates = await lyricCandidates(for: song)

        for candidate in candidates.sorted(by: { lyricMatchScore($0, to: song) > lyricMatchScore($1, to: song) }).prefix(8) {
            if let pair = await fetchLyrics(for: candidate),
               let lrc = pair.lrc,
               !lrc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (lrc, pair.trans)
            }
        }
        return nil
    }

    /// 只找翻译：给已有原文歌词的歌曲（NAS 内嵌歌词）跨源配翻译。
    /// 挂错翻译比没有翻译更糟，只接受高置信匹配（歌名精确一致且歌手至少部分对齐）。
    private static func matchedTranslation(for song: Song) async -> String? {
        let candidates = await lyricCandidates(for: song)
        for candidate in candidates.sorted(by: { lyricMatchScore($0, to: song) > lyricMatchScore($1, to: song) }).prefix(8) {
            guard lyricMatchScore(candidate, to: song) >= 120 else { continue }
            if let pair = await fetchLyrics(for: candidate),
               pair.lrc != nil,
               let trans = pair.trans,
               !trans.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return trans
            }
        }
        return nil
    }

    // MARK: - 仅在线匹配（批量写回流水线复用）

    struct OnlineMatch {
        let lrc: String
        let provider: String
        let score: Int
    }

    /// 只从在线平台匹配带时间轴的歌词，**不读本地缓存**——
    /// 批量写回要的是「这首歌能拿到的最好歌词」，而不是「本机已有的那份」。
    /// 打分阈值默认 110：歌名必须基本对齐，避免把同名不同曲的歌词写到别人歌上。
    static func matchOnlineLyrics(for song: Song, minimumScore: Int = 110) async -> OnlineMatch? {
        let candidates = await lyricCandidates(for: song)
        let ranked = candidates
            .map { (song: $0, score: lyricMatchScore($0, to: song)) }
            .filter { $0.score >= minimumScore }
            .sorted { $0.score > $1.score }
        for entry in ranked.prefix(6) {
            guard let pair = await fetchLyrics(for: entry.song),
                  let lrc = pair.lrc,
                  lrc.contains("[") else { continue }  // 必须有时间轴，纯文本歌词没法滚
            return OnlineMatch(lrc: lrc, provider: providerName(for: entry.song.source), score: entry.score)
        }
        return nil
    }

    /// 列出多个候选歌词（供批量写回里手动挑选），按置信度从高到低。
    /// 与 `matchOnlineLyrics` 的区别：这里不只看第一条，而是把可用候选都带回来。
    static func onlineLyricCandidates(for song: Song, minimumScore: Int = 90, limit: Int = 4) async -> [OnlineMatch] {
        let candidates = await lyricCandidates(for: song)
        let ranked = candidates
            .map { (song: $0, score: lyricMatchScore($0, to: song)) }
            .filter { $0.score >= minimumScore }
            .sorted { $0.score > $1.score }

        var matches: [OnlineMatch] = []
        var seenTexts = Set<String>()
        for entry in ranked.prefix(8) {
            if matches.count >= limit { break }
            guard let pair = await fetchLyrics(for: entry.song),
                  let lrc = pair.lrc,
                  lrc.contains("[") else { continue }
            let fingerprint = lrc.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)
            guard seenTexts.insert(String(fingerprint)).inserted else { continue }
            matches.append(OnlineMatch(lrc: lrc, provider: providerName(for: entry.song.source), score: entry.score))
        }
        return matches
    }

    static func providerName(for source: SongSource) -> String {
        switch source {
        case .netease: return "网易云音乐"
        case .qq: return "QQ音乐"
        case .kugou: return "酷狗音乐"
        case .synology: return "群晖 NAS"
        case .subsonic: return "Subsonic"
        case .jellyfin: return "Jellyfin"
        case .webdav: return "WebDAV"
        case .local: return "本地"
        }
    }

    private static func lyricCandidates(for song: Song) async -> [Song] {
        let candidates: [Song]
        if song.source == .synology {
            let matches = await SynologyAPI.shared.metadataCandidates(for: song)
            candidates = matches.map(\.song)
        } else if song.source == .netease {
            candidates = (try? await NetEaseAPI.shared.search(keyword: "\(song.name) \(song.artists)", limit: 12)) ?? []
        } else if song.source == .qq {
            candidates = (try? await QQMusicAPI.shared.searchSongs(keyword: "\(song.name) \(song.artists)", limit: 12)) ?? []
        } else if song.source == .kugou {
            candidates = (try? await KugouMusicAPI.shared.searchSongs(keyword: "\(song.name) \(song.artists)", limit: 12)) ?? []
        } else {
            async let netease = (try? await NetEaseAPI.shared.search(keyword: "\(song.name) \(song.artists)", limit: 8)) ?? []
            async let qq = (try? await QQMusicAPI.shared.searchSongs(keyword: "\(song.name) \(song.artists)", limit: 8)) ?? []
            async let kugou = (try? await KugouMusicAPI.shared.searchSongs(keyword: "\(song.name) \(song.artists)", limit: 8)) ?? []
            let all = await (netease, qq, kugou)
            candidates = all.0 + all.1 + all.2
        }
        return candidates
    }

    private static func fetchLyrics(for song: Song) async -> (lrc: String?, trans: String?)? {
        switch song.source {
        case .netease:
            guard let result = try? await NetEaseAPI.shared.lyricWithTranslation(id: song.id) else { return nil }
            return (result.lrc, result.tlyric)
        case .qq:
            guard let mid = song.qqMid else { return nil }
            let result = await QQMusicAPI.shared.lyricWithTranslation(songmid: mid, songID: song.id, name: song.name, singer: song.artists, album: song.album)
            return (result.lrc, result.trans)
        case .kugou:
            guard let hash = song.kugouHash else { return nil }
            let raw = await KugouMusicAPI.shared.lyric(hash: hash, duration: song.duration)
            return (raw.isEmpty ? nil : raw, nil)
        case .synology, .subsonic, .jellyfin, .webdav, .local:
            return nil
        }
    }

    private static func lyricMatchScore(_ candidate: Song, to target: Song) -> Int {
        func normalize(_ value: String) -> String {
            value.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let targetName = normalize(target.name)
        let candidateName = normalize(candidate.name)
        var score = 0
        if candidateName == targetName { score += 100 } else if candidateName.contains(targetName) || targetName.contains(candidateName) { score += 60 }
        let targetArtists = normalize(target.artists)
        let candidateArtists = normalize(candidate.artists)
        if !targetArtists.isEmpty, candidateArtists == targetArtists { score += 45 } else if !targetArtists.isEmpty && (candidateArtists.contains(targetArtists) || targetArtists.contains(candidateArtists)) { score += 25 }
        let targetAlbum = normalize(target.album)
        let candidateAlbum = normalize(candidate.album)
        if !targetAlbum.isEmpty, candidateAlbum == targetAlbum { score += 20 } else if !targetAlbum.isEmpty && candidateAlbum.contains(targetAlbum) { score += 8 }
        if target.duration > 0, candidate.duration > 0, abs(target.duration - candidate.duration) < 3 { score += 12 }
        return score
    }

    /// 获取原始歌词纯文本（用于保存本地 .lrc 或上传到群晖 NAS 同步）
    static func rawLyricString(for song: Song) async -> String? {
        if song.source == .local, let relativePath = song.localRelativePath {
            let lrcPath = (relativePath as NSString).deletingPathExtension + ".lrc"
            if let lrcURL = try? ManagedAudioPath.resolve(lrcPath),
               let raw = try? String(contentsOf: lrcURL, encoding: .utf8) {
                return raw
            }
        }
        if let localFile = LocalAudioFileManager.shared.file(forSongId: song.identityKey) {
            let lrcPath = (localFile.relativePath as NSString).deletingPathExtension + ".lrc"
            if let lrcURL = try? ManagedAudioPath.resolve(lrcPath),
               let raw = try? String(contentsOf: lrcURL, encoding: .utf8) {
                return raw
            }
        }
        if song.source == .synology {
            if let raw = try? await SynologyAPI.shared.lyrics(song: song) {
                return raw
            }
        } else if song.source == .subsonic {
            if let raw = try? await SubsonicAPI.shared.lyrics(song: song) {
                return raw
            }
        } else if song.source == .jellyfin {
            if let raw = try? await JellyfinAPI.shared.lyrics(song: song) {
                return raw
            }
        } else if song.source == .webdav {
            if let raw = try? await WebDAVAPI.shared.lyrics(song: song) {
                return raw
            }
        } else if song.source == .kugou, let hash = song.kugouHash {
            let raw = await KugouMusicAPI.shared.lyric(hash: hash, duration: song.duration)
            if !raw.isEmpty { return raw }
        } else if song.source == .qq, let mid = song.qqMid {
            if let raw = try? await QQMusicAPI.shared.lyric(songmid: mid) {
                return raw
            }
        } else if song.source == .netease {
            if let (lrc, _) = try? await NetEaseAPI.shared.lyricWithTranslation(id: song.id) {
                return lrc
            }
        }
        return await autoMatchedLyrics(for: song)?.lrc
    }

}
