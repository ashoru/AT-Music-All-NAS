import Foundation

final class SourceQoSRanking: @unchecked Sendable {
    static let shared = SourceQoSRanking()
    private var stats: [String: (success: Int, failure: Int, totalRTT: TimeInterval)] = [:]
    private let lock = NSLock()

    func record(sourceId: String, success: Bool, rtt: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        var s = stats[sourceId] ?? (0, 0, 0)
        if success {
            s.success += 1
            s.totalRTT += rtt
        } else {
            s.failure += 1
        }
        stats[sourceId] = s
    }

    func score(sourceId: String) -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard let s = stats[sourceId], (s.success + s.failure) > 0 else {
            return 100.0 // 默认新节点基础分
        }
        let rate = Double(s.success) / Double(s.success + s.failure)
        let avgRTT = s.success > 0 ? (s.totalRTT / Double(s.success)) : 4.0
        let rttScore = max(0, 100.0 - avgRTT * 20.0)
        return rate * 70.0 + rttScore * 0.3
    }
}

enum UnblockService {
    struct Resolved {
        let url: URL
        let source: String
        let quality: ThirdPartyAudioQuality
        let headers: [String: String]

        var sourceTitle: String { source }

        init(url: URL, source: String, quality: ThirdPartyAudioQuality = .kb320, headers: [String: String] = [:]) {
            self.url = url
            self.source = source
            self.quality = quality
            self.headers = headers
        }
    }

    /// 严格识别防盗链音频、严重截断测试音、错误重定向或已失效的黑名单 URL
    static func isCorruptOrAntiLeechURL(_ url: URL) -> Bool {
        let raw = url.absoluteString.lowercased()
        // 1. 酷我官方防盗链 11 秒提示音频（M5000004Gmy54cGDqK.mp3）及特征
        if raw.contains("m5000004gmy54cgdqk") { return true }
        if raw.contains("bitrate$1") || raw.contains("bitrate=1") { return true }
        if raw.contains("30106/trackmedia") || raw.contains("/30106/") { return true }
        // 2. 通用防盗链 / 未授权音频标识
        if raw.contains("antifake") || raw.contains("anti-leech") || raw.contains("anti_leech") { return true }
        if raw.contains("error.php") || raw.contains("error_url") || raw.contains("music.163.com/404") { return true }
        if raw.contains("2026-06-17-195722_104595") { return true }
        return false
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 4.5
        config.timeoutIntervalForResource = 8.0
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// 入口：并发尝试用户导入且可用于当前平台的音源，返回第一个可用地址。
    static func resolve(
        name: String,
        artists: String,
        neteaseID: Int,
        songSource: SongSource = .netease,
        qqMid: String? = nil,
        qqMediaMid: String? = nil,
        kugouID: String? = nil,
        quality: ThirdPartyAudioQuality = .current,
        strict: Bool = false,
        excludedHosts: Set<String> = []
    ) async -> Resolved? {
        guard UnblockSourceStore.shared.isEffectivelyEnabled else {
            return nil
        }
        let hasSongIdentity = !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !artists.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasSongIdentity else { return nil }
        let sources = UnblockSourceStore.shared.sources
            .filter { source in
                guard source.enabled else { return false }
                return isScriptSource(source)
                    || canUse(source: source, songSource: songSource, neteaseID: neteaseID, qqMid: qqMid, kugouID: kugouID)
            }
        if sources.isEmpty {
            ATMusicLogger.shared.log(
                "没有启用的自定义音源，直接调用原生车机专线保底：\(name)",
                level: .debug
            )
            return await nativeFastResolve(name: name, artists: artists, preferredQuality: quality)
        }

        return await resolveSources(
            sources,
            name: name,
            artists: artists,
            neteaseID: neteaseID,
            songSource: songSource,
            qqMid: qqMid,
            qqMediaMid: qqMediaMid,
            kugouID: kugouID,
            quality: quality,
            excludedHosts: excludedHosts
        )
    }

    private static func resolveSources(
        _ sources: [ThirdPartySource],
        name: String,
        artists: String,
        neteaseID: Int,
        songSource: SongSource,
        qqMid: String?,
        qqMediaMid: String?,
        kugouID: String?,
        quality: ThirdPartyAudioQuality,
        excludedHosts: Set<String>
    ) async -> Resolved? {
        guard !sources.isEmpty else { return nil }

        // 相同配置只保留每个请求指纹的第一个，避免重复请求同一个服务。
        var seen = Set<String>()
        let uniqueSources = sources.filter { seen.insert(requestFingerprint(for: $0)).inserted }
        let rankedSources = uniqueSources.sorted { s1, s2 in
            SourceQoSRanking.shared.score(sourceId: s1.id) > SourceQoSRanking.shared.score(sourceId: s2.id)
        }

        // 慢源/失效源不要拖住播放：全部候选一起请求，最快命中的播放地址直接返回。
        return await withTaskGroup(of: Resolved?.self) { group in
            // 原生车机极速专线并发竞速 (跨源秒级直出全曲)
            if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                group.addTask {
                    await nativeFastResolve(name: name, artists: artists, preferredQuality: quality)
                }
            }
            for source in rankedSources {
                group.addTask {
                    let startTime = Date()
                    let result: Resolved?
                    if isScriptSource(source) {
                        result = await scriptSourceRequest(
                            source: source,
                            name: name,
                            artists: artists,
                            neteaseID: neteaseID,
                            songSource: songSource,
                            qqMid: qqMid,
                            qqMediaMid: qqMediaMid,
                            kugouID: kugouID,
                            preferredQuality: quality,
                            excludedHosts: excludedHosts
                        )
                    } else {
                        result = await presetSourceRequest(
                            source: source,
                            name: name,
                            artists: artists,
                            neteaseID: neteaseID,
                            songSource: songSource,
                            qqMid: qqMid,
                            qqMediaMid: qqMediaMid,
                            kugouID: kugouID,
                            preferredQuality: quality,
                            excludedHosts: excludedHosts
                        )
                    }
                    let elapsed = Date().timeIntervalSince(startTime)
                    SourceQoSRanking.shared.record(sourceId: source.id, success: result != nil, rtt: elapsed)
                    return result
                }
            }
            for await result in group {
                if let result, !isCorruptOrAntiLeechURL(result.url) {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
    }

    private static func canUse(source: ThirdPartySource, songSource: SongSource, neteaseID: Int, qqMid: String?, kugouID: String?) -> Bool {
        let expectedProvider = providerCode(for: songSource)
        if let provider = source.headers["source"], !provider.isEmpty, provider != expectedProvider {
            return false
        }
        if songSource == .qq {
            return qqMid?.isEmpty == false
        }
        if songSource == .kugou {
            return kugouID?.isEmpty == false
        }
        return neteaseID > 0
    }

    private static func isScriptSource(_ source: ThirdPartySource) -> Bool {
        let kind = source.kind.lowercased()
        return kind.contains("script") || source.script?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private static func presetSourceRequest(
        source: ThirdPartySource,
        name: String,
        artists: String,
        neteaseID: Int,
        songSource: SongSource,
        qqMid: String?,
        qqMediaMid: String?,
        kugouID: String?,
        preferredQuality: ThirdPartyAudioQuality,
        excludedHosts: Set<String>
    ) async -> Resolved? {
        guard !source.template.isEmpty else { return nil }
        let expectedProvider = providerCode(for: songSource)
        if let provider = source.headers["source"], !provider.isEmpty, provider != expectedProvider {
            return nil
        }
        let songIDs: [String]
        switch songSource {
        case .netease where neteaseID > 0:
            songIDs = [String(neteaseID)]
        case .qq:
            guard let qqMid, !qqMid.isEmpty else { return nil }
            songIDs = qqIDCandidates(songID: neteaseID, songMid: qqMid, mediaMid: qqMediaMid)
        case .kugou:
            guard let kugouID, !kugouID.isEmpty else { return nil }
            songIDs = [kugouID]
        default:
            return nil
        }
        let apiKeys = orderedAPIKeys(for: source)
        let apiKeyPlaceholders = ["{apiKey}", "{apikey}", "{key}"]
        let requiresAPIKey = apiKeyPlaceholders.contains { source.template.contains($0) }
        if requiresAPIKey && apiKeys.isEmpty {
            ATMusicLogger.shared.log(
                "自定义音源缺少请求密钥：\(source.name)，已跳过请求",
                level: .debug
            )
            return nil
        }
        for (idIndex, songID) in songIDs.enumerated() {
            var baseURLString = source.template
            let idValues: [String: String] = [
                "{id}": songID,
                "{songId}": songID,
                "{songid}": songID,
                "{songID}": songID,
                "{songmid}": qqMid ?? songID,
                "{mid}": qqMid ?? songID,
                "{hash}": kugouID ?? songID
            ]
            for (placeholder, value) in idValues {
                baseURLString = baseURLString.replacingOccurrences(of: placeholder, with: value)
            }
            baseURLString = baseURLString.replacingOccurrences(of: "{source}", with: expectedProvider)
            baseURLString = baseURLString.replacingOccurrences(of: "{name}", with: urlEncoded(name))
            let keyword = ([name, artists].filter { !$0.isEmpty }).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            baseURLString = baseURLString.replacingOccurrences(of: "{keyword}", with: urlEncoded(keyword))
            baseURLString = baseURLString.replacingOccurrences(of: "{artist}", with: urlEncoded(artists))
            for (qualityIndex, quality) in qualityCandidates(for: source, songSource: songSource, preferredQuality: preferredQuality).enumerated() {
                if qualityIndex > 0 {
                    ATMusicLogger.shared.log("第三方音源自动降级：\(source.name) 音质=\(quality)", level: .debug)
                }
                let urlString = replacingQualityPlaceholders(in: baseURLString, with: quality)
                let idLabel = songSource == .qq && songIDs.count > 1 ? " ID=\(idIndex + 1)/\(songIDs.count)" : ""
                if !apiKeys.isEmpty {
                    for (originalIndex, apiKey) in apiKeys {
                        let keyedURLString = apiKeyPlaceholders.reduce(urlString) { result, placeholder in
                            result.replacingOccurrences(of: placeholder, with: urlEncoded(apiKey))
                        }
                        guard let url = URL(string: keyedURLString) else { continue }
                        if let resolved = await presetSourceRequestOnce(
                            source: source,
                            url: url,
                            apiKey: apiKey,
                            keyIndex: originalIndex + 1,
                            keyTotal: apiKeys.count,
                            quality: quality,
                            idLabel: idLabel,
                            excludedHosts: excludedHosts
                        ) {
                            rememberWorkingKey(originalIndex, for: source)
                            return resolved
                        }
                    }
                } else if !requiresAPIKey,
                          let url = URL(string: urlString),
                          let resolved = await presetSourceRequestOnce(
                    source: source,
                    url: url,
                    apiKey: nil,
                    keyIndex: 0,
                    keyTotal: 0,
                    quality: quality,
                    idLabel: idLabel,
                    excludedHosts: excludedHosts
                ) {
                    return resolved
                }
            }
        }

        if !apiKeys.isEmpty {
            ATMusicLogger.shared.log("第三方音源全部密钥未命中：\(source.name) 共 \(apiKeys.count) 个", level: .debug)
        }
        return nil
    }

    private static func scriptSourceRequest(
        source: ThirdPartySource,
        name: String,
        artists: String,
        neteaseID: Int,
        songSource: SongSource,
        qqMid: String?,
        qqMediaMid: String?,
        kugouID: String?,
        preferredQuality: ThirdPartyAudioQuality,
        excludedHosts: Set<String>
    ) async -> Resolved? {
        guard let script = source.script?.trimmingCharacters(in: .whitespacesAndNewlines), !script.isEmpty else { return nil }
        let songIDs: [String]
        switch songSource {
        case .netease where neteaseID > 0:
            songIDs = [String(neteaseID)]
        case .qq:
            guard let qqMid, !qqMid.isEmpty else { return nil }
            var candidates: [String] = [qqMid]
            if let qqMediaMid, !qqMediaMid.isEmpty {
                candidates.append(qqMediaMid)
            }
            if neteaseID > 0 {
                candidates.append(String(neteaseID))
            }
            var seen = Set<String>()
            songIDs = candidates.filter { seen.insert($0).inserted }
        case .kugou:
            guard let kugouID, !kugouID.isEmpty else { return nil }
            songIDs = [kugouID]
        default:
            return nil
        }

        let qualities = qualityCandidates(for: source, songSource: songSource, preferredQuality: preferredQuality)
        for songID in songIDs {
            for (qualityIndex, quality) in qualities.enumerated() {
                if qualityIndex > 0 {
                    ATMusicLogger.shared.log("脚本音源自动降级：\(source.name) 音质=\(quality)", level: .debug)
                }
                if let resolved = await LXScriptSourceRunner.shared.resolve(
                    source: source,
                    script: script,
                    songSource: songSource,
                    songID: songID,
                    qqMid: qqMid,
                    qqMediaMid: qqMediaMid,
                    kugouID: kugouID,
                    name: name,
                    artists: artists,
                    quality: quality,
                    excludedHosts: excludedHosts
                ), !isCorruptOrAntiLeechURL(resolved.url) {
                    ATMusicLogger.shared.log("脚本音源命中：\(source.name) 音质=\(quality)", level: .info)
                    return resolved
                }
            }
        }
        return nil
    }

    private static func presetSourceRequestOnce(
        source: ThirdPartySource,
        url: URL,
        apiKey: String?,
        keyIndex: Int,
        keyTotal: Int,
        quality: String,
        idLabel: String = "",
        excludedHosts: Set<String>
    ) async -> Resolved? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 7
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ATMusic-UserSource/1.0", forHTTPHeaderField: "User-Agent")
        if let apiKey, !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        }
        let keyLabel = idLabel + (keyTotal > 1 ? " 密钥=\(keyIndex)/\(keyTotal)" : "") + " 音质=\(quality)"
        let metadataKeys: Set<String> = [
            "source", "quality", "qualities", "qualityOptions", "qualitys",
            "br", "level", "apiKey", "apiKeys", "apiKeyQuery"
        ]
        for (key, value) in source.headers where !metadataKeys.contains(key) {
            let resolvedValue = value
                .replacingOccurrences(of: "{quality}", with: quality)
                .replacingOccurrences(of: "{source}", with: source.headers["source"] ?? "")
            request.setValue(resolvedValue, forHTTPHeaderField: key)
        }
        request.setValue(quality, forHTTPHeaderField: "quality")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            ATMusicLogger.shared.log("第三方音源请求失败：\(source.name)\(keyLabel) \(error.localizedDescription)", level: .debug)
            return nil
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            ATMusicLogger.shared.log("第三方音源 HTTP 失败：\(source.name)\(keyLabel) 状态=\(status)", level: .debug)
            return nil
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            ATMusicLogger.shared.log("第三方音源响应格式错误：\(source.name)\(keyLabel)", level: .debug)
            return nil
        }
        if let code = responseCode(from: obj), code != 0 && code != 200 {
            let message = obj["message"] as? String ?? obj["msg"] as? String ?? "code=\(code)"
            ATMusicLogger.shared.log("第三方音源返回失败：\(source.name)\(keyLabel) \(message)", level: .debug)
            return nil
        }
        guard let value = valueAtAnyPath(obj, source.urlPath),
              let resolvedURL = value as? String, !resolvedURL.isEmpty,
              let rawPlayURL = URL(string: resolvedURL),
              !isCorruptOrAntiLeechURL(rawPlayURL),
              let playURL = playablePlaybackURL(from: rawPlayURL, source: source, keyLabel: keyLabel, excludedHosts: excludedHosts),
              !isCorruptOrAntiLeechURL(playURL) else {
            ATMusicLogger.shared.log("第三方音源响应中没有有效播放地址：\(source.name)\(keyLabel)", level: .debug)
            return nil
        }
        if rawPlayURL != playURL {
            ATMusicLogger.shared.log(
                "第三方音源切换 QQ CDN 节点：\(rawPlayURL.host ?? "?") -> \(playURL.host ?? "?")",
                level: .debug
            )
        }
        if let host = playURL.host?.lowercased(), excludedHosts.contains(host) {
            ATMusicLogger.shared.log(
                "第三方音源跳过已失败节点：\(source.name)\(keyLabel) 域名=\(host)",
                level: .debug
            )
            return nil
        }
        ATMusicLogger.shared.log("第三方音源命中：\(source.name)\(keyLabel)", level: .info)
        return Resolved(
            url: playURL,
            source: source.name,
            quality: ThirdPartyAudioQuality(sourceValue: quality) ?? .kb320,
            headers: source.headers
        )
    }

    /// 部分第三方接口会固定返回不稳定的 QQ CDN 节点。
    /// 不在这里做 Range 探测：部分 QQ CDN 会拒绝探测请求，但 AVPlayer
    /// 带完整请求头后仍可正常播放。实际失败由 AVPlayer 反馈，再换下一个节点。
    private static func playablePlaybackURL(from rawURL: URL, source: ThirdPartySource, keyLabel: String, excludedHosts: Set<String>) -> URL? {
        guard !isCorruptOrAntiLeechURL(rawURL) else {
            ATMusicLogger.shared.log("第三方音源跳过防盗链地址：\(source.name)\(keyLabel) \(safeURLSummary(rawURL))", level: .debug)
            return nil
        }
        let candidates = qqPlaybackURLCandidates(for: rawURL)
        for candidate in candidates {
            guard !isCorruptOrAntiLeechURL(candidate) else { continue }
            guard let host = candidate.host?.lowercased() else { continue }
            if excludedHosts.contains(host) {
                ATMusicLogger.shared.log(
                    "第三方音源跳过已失败节点：\(source.name)\(keyLabel) 域名=\(host)",
                    level: .debug
                )
                continue
            }
            if rawURL != candidate {
                ATMusicLogger.shared.log(
                    "第三方音源准备 QQ CDN 备用节点：\(rawURL.host ?? "?") -> \(host)",
                    level: .debug
                )
            }
            ATMusicLogger.shared.log("第三方音源选择播放地址：\(source.name)\(keyLabel) \(safeURLSummary(candidate))", level: .debug)
            return candidate
        }
        return nil
    }

    private static func qqPlaybackURLCandidates(for url: URL) -> [URL] {
        guard let host = url.host?.lowercased(), isQQPlaybackHost(host) else {
            return [url]
        }
        let hosts = [
            host,
            "isure6.ptqqmusic.gitv.tv",
            "isure.stream.qqmusic.qq.com",
            "dl.stream.qqmusic.qq.com",
            "ws.stream.qqmusic.qq.com",
            "streamoc.music.tc.qq.com"
        ]
        var seen = Set<String>()
        return hosts.compactMap { replacement in
            guard seen.insert(replacement).inserted else { return nil }
            return replacingHost(of: url, with: replacement)
        }
    }

    private static func replacingHost(of url: URL, with replacementHost: String) -> URL? {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.host = replacementHost
        return components?.url ?? url
    }

    private static func isQQPlaybackHost(_ host: String) -> Bool {
        host.contains("qq.com") || host.contains("qqmusic") || host.contains("ptqqmusic") || host.contains("gitv.tv")
    }

    private static func replacingQualityPlaceholders(in template: String, with quality: String) -> String {
        ["{quality}", "{br}", "{level}"].reduce(template) { result, placeholder in
            result.replacingOccurrences(of: placeholder, with: quality)
        }
    }

    private static func qualityCandidates(for source: ThirdPartySource, songSource: SongSource, preferredQuality: ThirdPartyAudioQuality) -> [String] {
        let provider = providerCode(for: songSource)
        let supported = Set(UnblockSourceStore.supportedQualities(for: source, providerCode: provider))
        let platformSupported = Set(ThirdPartyAudioQuality.supported(providerCode: provider))
        let sourceDefault = ThirdPartyAudioQuality(sourceValue: source.quality)
        let platformDefault: ThirdPartyAudioQuality = {
            switch songSource {
            case .netease, .qq, .kugou, .synology, .subsonic, .jellyfin, .webdav, .local:
                return .kb320
            }
        }()

        var ordered: [ThirdPartyAudioQuality] = []
        ordered.append(contentsOf: preferredQuality.fallbackChain)
        if let sourceDefault, sourceDefault != preferredQuality {
            ordered.append(contentsOf: sourceDefault.fallbackChain)
        }
        if platformDefault != preferredQuality && platformDefault != sourceDefault {
            ordered.append(contentsOf: platformDefault.fallbackChain)
        }

        let filtered = ordered.filter {
            platformSupported.contains($0) && (supported.isEmpty || supported.contains($0))
        }
        var seen = Set<String>()
        let result = filtered.compactMap { quality -> String? in
            let trimmed = quality.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || !seen.insert(trimmed).inserted ? nil : trimmed
        }
        if !result.isEmpty { return result }

        // 若源只声明了非标准档位，至少尝试它声明过的档位，不能越过能力表强行请求未知音质。
        if !supported.isEmpty {
            return UnblockSourceStore
                .supportedQualities(for: source, providerCode: provider)
                .map(\.rawValue)
        }

        var fallbackSeen = Set<String>()
        return ordered.compactMap { quality -> String? in
            let trimmed = quality.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || !fallbackSeen.insert(trimmed).inserted ? nil : trimmed
        }
    }

    private static func qqIDCandidates(songID: Int, songMid: String, mediaMid: String?) -> [String] {
        var seen = Set<String>()
        let numericID = songID > 0 ? String(songID) : nil
        return [numericID, mediaMid, songMid].compactMap { raw in
            guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty,
                  seen.insert(value).inserted else { return nil }
            return value
        }
    }

    private static func safeURLSummary(_ url: URL) -> String {
        let host = url.host ?? "?"
        let path = url.path.isEmpty ? "/" : url.path
        let shortPath = path.count > 72 ? String(path.prefix(72)) + "..." : path
        return "\(host)\(shortPath)"
    }

    private static func requestFingerprint(for source: ThirdPartySource) -> String {
        let headers = source.headers
            .filter { $0.key != "source" }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
        let scriptFingerprint = source.script?.hashValue.description ?? ""
        return "\(source.template)|\(source.urlPath)|\(headers)|\(source.quality)|\(scriptFingerprint)"
    }

    private static func sourceAPIKeys(for source: ThirdPartySource) -> [String] {
        var keys: [String] = []
        if let raw = source.headers["apiKeys"], !raw.isEmpty {
            keys.append(contentsOf: raw
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty })
        }
        if let raw = source.headers["apiKey"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            keys.append(raw)
        }
        var seen = Set<String>()
        return keys.filter { seen.insert($0).inserted }
    }

    private static func orderedAPIKeys(for source: ThirdPartySource) -> [(Int, String)] {
        let keys = sourceAPIKeys(for: source)
        var seen = Set<String>()
        let unique = keys.enumerated().compactMap { index, key -> (Int, String)? in
            seen.insert(key).inserted ? (index, key) : nil
        }
        let preferred = UserDefaults.standard.integer(forKey: preferredKeyIndexDefaultsKey(for: source))
        guard let hit = unique.firstIndex(where: { $0.0 == preferred }), hit > 0 else {
            return unique
        }
        var reordered = unique
        let item = reordered.remove(at: hit)
        reordered.insert(item, at: 0)
        return reordered
    }

    private static func rememberWorkingKey(_ index: Int, for source: ThirdPartySource) {
        UserDefaults.standard.set(index, forKey: preferredKeyIndexDefaultsKey(for: source))
    }

    private static func preferredKeyIndexDefaultsKey(for source: ThirdPartySource) -> String {
        "atmusic.unblock.preferredKeyIndex.\(source.id)"
    }

    private static func responseCode(from object: [String: Any]) -> Int? {
        if let code = object["code"] as? Int {
            return code
        }
        if let code = object["code"] as? NSNumber {
            return code.intValue
        }
        if let code = object["code"] as? String {
            return Int(code)
        }
        return nil
    }

    private static func providerCode(for source: SongSource) -> String {
        switch source {
        case .netease: return "wy"
        case .qq: return "tx"
        case .kugou: return "kg"
        case .local: return "local"
        case .synology: return "syno"
        case .subsonic: return "subsonic"
        case .jellyfin: return "jellyfin"
        case .webdav: return "webdav"
        }
    }

    /// 多个点分路径取值：data.music|data.url|url。
    private static func valueAtAnyPath(_ obj: Any, _ paths: String) -> Any? {
        for path in paths.split(separator: "|") {
            if let value = valueAtPath(obj, String(path)) {
                return value
            }
        }
        return nil
    }

    /// 点分路径取值：url / data.url / data.audioUrl ...
    private static func valueAtPath(_ obj: Any, _ path: String) -> Any? {
        var current: Any = obj
        for key in path.split(separator: ".") {
            if let dict = current as? [String: Any], let next = dict[String(key)] {
                current = next
            } else if let dict = current as? NSDictionary, let next = dict[String(key)] {
                current = next
            } else {
                return nil
            }
        }
        return current
    }

    private static func urlEncoded(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? string
    }

    /// 原生车机专线极速直出全曲：绕过 JS 虚拟机开销，直接基于 URLSession 竞速解析
    static func nativeFastResolve(
        name: String,
        artists: String,
        preferredQuality: ThirdPartyAudioQuality = .kb320
    ) async -> Resolved? {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return nil }
        let kw = ([artists, cleanName].filter { !$0.isEmpty }).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let encoded = kw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchURL = URL(string: "http://search.kuwo.cn/r.s?client=kt&all=\(encoded)&pn=0&rn=5&ver=kwplayer_ar_9.2.1&vipver=1&ft=music&cluster=0&strategy=2012&encoding=utf8&rformat=json") else {
            return nil
        }

        var searchReq = URLRequest(url: searchURL)
        searchReq.timeoutInterval = 2.5
        searchReq.setValue("okhttp/3.10.0", forHTTPHeaderField: "User-Agent")

        guard let (data, _) = try? await session.data(for: searchReq),
              let rawStr = String(data: data, encoding: .utf8) else {
            return nil
        }

        let jsonStr = rawStr.replacingOccurrences(of: "'", with: "\"")
        guard let jsonData = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let abslist = json["abslist"] as? [[String: Any]],
              !abslist.isEmpty else {
            return nil
        }

        let brCandidates: [(br: String, quality: ThirdPartyAudioQuality)]
        switch preferredQuality {
        case .kb128:
            brCandidates = [("128kmp3", .kb128)]
        case .flac, .flac24bit, .hires, .atmos, .atmosPlus, .master:
            brCandidates = [("2000kflac", preferredQuality), ("320kmp3", .kb320), ("128kmp3", .kb128)]
        default:
            brCandidates = [("320kmp3", .kb320), ("128kmp3", .kb128)]
        }

        for item in abslist.prefix(4) {
            let rawRid = (item["DC_TARGETID"] as? String) ?? (item["MUSICRID"] as? String)?.replacingOccurrences(of: "MUSIC_", with: "") ?? ""
            guard !rawRid.isEmpty else { continue }

            for (br, actualQuality) in brCandidates {
                // 渠道 1: 车机专线 convert_url2 (严格防盗链排查)
                if let url1 = URL(string: "http://anymatch.kuwo.cn/mobi.s?f=web&rid=\(rawRid)&br=\(br)&source=kwplayercar_ar_6.0.0.9_B_jiakong_vh.apk&type=convert_url2") {
                    var req1 = URLRequest(url: url1)
                    req1.timeoutInterval = 2.0
                    req1.setValue("okhttp/3.10.0", forHTTPHeaderField: "User-Agent")
                    if let (data1, _) = try? await session.data(for: req1),
                       let text1 = String(data: data1, encoding: .utf8) {
                        let isAntiLeech = text1.contains("bitrate=1")
                            || text1.contains("type=1")
                            || text1.contains("M5000004Gmy54cGDqK")
                            || text1.contains("bitrate$1")
                            || text1.contains("30106")
                        if !isAntiLeech, let match = text1.range(of: "url=") {
                            let rest = text1[match.upperBound...]
                            let line = rest.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            if (line.hasPrefix("http://") || line.hasPrefix("https://")) && !line.contains("404") && !line.contains("error.php"),
                               let finalURL = URL(string: line),
                               !isCorruptOrAntiLeechURL(finalURL) {
                                ATMusicLogger.shared.log("⚡️ 原生车机专线命中：\(cleanName) -> \(finalURL.host ?? "?") [\(br)]", level: .info)
                                return Resolved(
                                    url: finalURL,
                                    source: "车机极速专线",
                                    quality: actualQuality,
                                    headers: [
                                        "User-Agent": "okhttp/3.10.0",
                                        "Referer": "http://kuwo.cn/"
                                    ]
                                )
                            }
                        }
                    }
                }

                // 渠道 2: 车机签名通道 convert_url_with_sign (严格时长与类型排查)
                guard let playURL = URL(string: "https://mobi.kuwo.cn/mobi.s?f=web&rid=\(rawRid)&br=\(br)&source=jiakong&type=convert_url_with_sign&surl=1") else {
                    continue
                }

                var playReq = URLRequest(url: playURL)
                playReq.timeoutInterval = 2.0
                playReq.setValue("okhttp/3.10.0", forHTTPHeaderField: "User-Agent")

                guard let (playData, _) = try? await session.data(for: playReq),
                      let playJson = try? JSONSerialization.jsonObject(with: playData) as? [String: Any],
                      let dataDict = playJson["data"] as? [String: Any] else {
                    continue
                }

                let bitrate = (dataDict["bitrate"] as? NSNumber)?.intValue ?? (dataDict["bitrate"] as? Int) ?? 0
                let type = (dataDict["type"] as? NSNumber)?.intValue ?? (dataDict["type"] as? Int) ?? 0
                let duration = (dataDict["duration"] as? NSNumber)?.intValue ?? (dataDict["duration"] as? Int) ?? 0
                let p2p = (dataDict["p2p_audiosourceid"] as? String) ?? ""

                if bitrate <= 1 || type == 1 || (duration > 0 && duration <= 25) || p2p.contains("M5000004Gmy54cGDqK") || p2p.contains("30106") {
                    continue
                }

                guard let finalUrlStr = (dataDict["surl"] as? String) ?? (dataDict["url"] as? String),
                      let finalURL = URL(string: finalUrlStr),
                      (finalUrlStr.hasPrefix("http://") || finalUrlStr.hasPrefix("https://")),
                      !finalUrlStr.contains("404"),
                      !finalUrlStr.contains("error.php"),
                      !isCorruptOrAntiLeechURL(finalURL) else {
                    continue
                }

                ATMusicLogger.shared.log("⚡️ 原生车机签名专线命中：\(cleanName) -> \(finalURL.host ?? "?") [\(br)]", level: .info)
                return Resolved(
                    url: finalURL,
                    source: "车机极速专线",
                    quality: actualQuality,
                    headers: [
                        "User-Agent": "okhttp/3.10.0",
                        "Referer": "http://kuwo.cn/"
                    ]
                )
            }
        }
        return nil
    }
}
