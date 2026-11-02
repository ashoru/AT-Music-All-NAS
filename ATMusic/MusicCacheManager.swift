import Foundation
import Combine
import AVFoundation

/// AT Music 连续播放磁盘缓存。
/// 只缓存为了播放加速而下载的音频；不进入“本地音乐”，也不会当作用户下载文件长期保存。
@MainActor
final class MusicCacheManager: ObservableObject {
    static let shared = MusicCacheManager()

    static let prefetchEnabledKey = "atmusic.playbackCache.prefetchNext"
    static let limitMBKey = "atmusic.playbackCache.limitMB"
    static let defaultLimitMB = 2048
    static let limitOptionsMB = [500, 1024, 2048, 5120, 10240, 20480]

    private static let minimumFreeDiskBytes: Int64 = 2 * 1024 * 1024 * 1024

    @Published private(set) var usageBytes: Int64 = 0
    @Published private(set) var cachedSongCount: Int = 0

    private struct Entry: Codable {
        let key: String
        let songIdentityKey: String
        let requestedQuality: String
        let actualQuality: String
        let filename: String
        let fileSize: Int64
        let createdAt: Date
        var lastAccessAt: Date
    }

    private let fm = FileManager.default
    private let defaults = UserDefaults.standard
    private let directory: URL
    private let indexURL: URL
    private var entries: [String: Entry] = [:]

    private var prefetchTask: Task<Void, Never>?
    private var prefetchKey: String?
    private var currentPlaybackKey: String?
    private var clearCurrentWhenSafe = false

    private init() {
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("ATMusicPlaybackCache", isDirectory: true)
        indexURL = directory.appendingPathComponent("index-v1.json")
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        loadIndex()
        reconcileIndex()
        refreshPublishedUsage()

        // build 109 一次性清理：此前第三方脚本解析并发串线可能把 A 歌音频存进 B 歌的缓存条目，
        // 这类错歌文件时长完整、常规验货发现不了，整体清一次防残留。
        let purgedBuildKey = "atm_playback_cache_purged_build"
        if defaults.integer(forKey: purgedBuildKey) < 109 {
            let cachedFiles = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            var removedCount = 0
            for file in cachedFiles where file.lastPathComponent != indexURL.lastPathComponent {
                if (try? fm.removeItem(at: file)) != nil { removedCount += 1 }
            }
            entries.removeAll()
            persistIndex()
            refreshPublishedUsage()
            defaults.set(109, forKey: purgedBuildKey)
            if removedCount > 0 {
                ATMusicLogger.shared.log("🧹 build 109 一次性清理播放缓存文件 \(removedCount) 个（防解析串线错歌文件残留）", level: .info)
            }
        }

        if defaults.object(forKey: Self.prefetchEnabledKey) == nil {
            defaults.set(true, forKey: Self.prefetchEnabledKey)
        }
        if defaults.object(forKey: Self.limitMBKey) == nil {
            defaults.set(Self.defaultLimitMB, forKey: Self.limitMBKey)
        }
        trimToLimit(requiredBytes: 0, protecting: [])
    }

    var isPrefetchEnabled: Bool {
        if defaults.object(forKey: Self.prefetchEnabledKey) == nil { return true }
        return defaults.bool(forKey: Self.prefetchEnabledKey)
    }

    var limitMB: Int {
        let saved = defaults.integer(forKey: Self.limitMBKey)
        return saved > 0 ? saved : Self.defaultLimitMB
    }

    private var limitBytes: Int64 {
        Int64(limitMB) * 1_048_576
    }

    func setPrefetchEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.prefetchEnabledKey)
        if !enabled {
            cancelPrefetch()
        }
    }

    func setLimitMB(_ value: Int) {
        let normalized = Self.limitOptionsMB.contains(value) ? value : Self.defaultLimitMB
        defaults.set(normalized, forKey: Self.limitMBKey)
        trimToLimit(requiredBytes: 0, protecting: protectedKeys())
        refreshPublishedUsage()
    }

    func markCurrentPlayback(song: Song, quality: ThirdPartyAudioQuality) {
        let newKey = cacheKey(song: song, quality: quality)

        if clearCurrentWhenSafe, let oldKey = currentPlaybackKey, oldKey != newKey {
            removeEntry(forKey: oldKey)
            clearCurrentWhenSafe = false
        }

        currentPlaybackKey = newKey
        if var entry = entries[newKey] {
            entry.lastAccessAt = Date()
            entries[newKey] = entry
            persistIndex()
        }
        refreshPublishedUsage()
    }

    func cachedURL(for song: Song, quality: ThirdPartyAudioQuality) -> URL? {
        let key = cacheKey(song: song, quality: quality)
        guard var entry = entries[key] else { return nil }
        let url = directory.appendingPathComponent(entry.filename)
        guard fm.fileExists(atPath: url.path) else {
            entries.removeValue(forKey: key)
            persistIndex()
            refreshPublishedUsage()
            return nil
        }
        if song.duration >= 45 && entry.fileSize < 250_000 {
            try? fm.removeItem(at: url)
            entries.removeValue(forKey: key)
            persistIndex()
            refreshPublishedUsage()
            ATMusicLogger.shared.log("🚫 发现并清除损坏/防盗链缓存文件：\(song.name) 大小=\(entry.fileSize) 时长=\(song.duration)s", level: .warn)
            return nil
        }
        if Self.isSuspiciouslyTruncated(fileURL: url, nominalDuration: Double(song.duration)) {
            try? fm.removeItem(at: url)
            entries.removeValue(forKey: key)
            persistIndex()
            refreshPublishedUsage()
            ATMusicLogger.shared.log("🚫 发现并清除时长异常的缓存文件：\(song.name) 标称=\(song.duration)s", level: .warn)
            return nil
        }
        entry.lastAccessAt = Date()
        entries[key] = entry
        persistIndex()
        refreshPublishedUsage()
        return url
    }

    func remove(song: Song) {
        for quality in ThirdPartyAudioQuality.allCases {
            let key = cacheKey(song: song, quality: quality)
            removeEntry(forKey: key)
        }
        persistIndex()
        refreshPublishedUsage()
    }

    func cancelPrefetch() {
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchKey = nil
    }

    func removeCachedFile(for song: Song, quality: ThirdPartyAudioQuality) {
        let key = cacheKey(song: song, quality: quality)
        removeEntry(forKey: key)
        if currentPlaybackKey == key {
            currentPlaybackKey = nil
        }
        persistIndex()
        refreshPublishedUsage()
    }

    /// 当前歌曲稳定播放后调用。一次只缓存“真实播放队列中的下一首”。
    func requestPrefetch(song: Song?, quality: ThirdPartyAudioQuality) {
        guard isPrefetchEnabled,
              let song,
              song.source != .local,
              song.source != .synology else {
            cancelPrefetch()
            return
        }

        let key = cacheKey(song: song, quality: quality)
        if cachedURL(for: song, quality: quality) != nil {
            cancelPrefetch()
            return
        }
        if prefetchKey == key, prefetchTask != nil {
            return
        }

        cancelPrefetch()
        prefetchKey = key

        prefetchTask = Task { [weak self] in
            guard let self else { return }

            if self.freeDiskBytes() <= Self.minimumFreeDiskBytes {
                self.trimForLowDisk()
                guard self.freeDiskBytes() > Self.minimumFreeDiskBytes else {
                    self.finishPrefetch(key: key)
                    ATMusicLogger.shared.log("跳过下一首缓存：设备剩余空间不足 2 GB", level: .debug)
                    return
                }
            }

            let result = await DownloadManager.shared.downloadForPlaybackCache(song: song, quality: quality)
            guard !Task.isCancelled else {
                if case let .success(download) = result {
                    try? self.fm.removeItem(at: download.url)
                }
                return
            }

            switch result {
            case let .success(download):
                let stored = self.storeDownloadedFile(
                    download,
                    song: song,
                    requestedQuality: quality,
                    key: key
                )
                ATMusicLogger.shared.log(
                    stored
                        ? "下一首缓存完成：\(song.name)｜请求=\(quality.rawValue)｜实际=\(download.actualQuality.rawValue)"
                        : "下一首缓存未写入：\(song.name)",
                    level: stored ? .info : .debug
                )
            case let .failure(error):
                if !(error is CancellationError) {
                    ATMusicLogger.shared.log(
                        "下一首缓存失败：\(song.name) - \(error.localizedDescription)",
                        level: .debug
                    )
                }
            }
            self.finishPrefetch(key: key)
        }
    }

    /// 用户主动清理。正在播放的缓存文件暂时保留，切歌后自动删除，避免清理动作打断当前播放。
    @discardableResult
    func clearPlaybackCache() -> Int {
        cancelPrefetch()
        var removed = 0
        let protected = currentPlaybackKey
        for key in Array(entries.keys) {
            if key == protected {
                clearCurrentWhenSafe = true
                continue
            }
            removeEntry(forKey: key)
            removed += 1
        }
        persistIndex()
        refreshPublishedUsage()
        return removed
    }

    private func finishPrefetch(key: String) {
        guard prefetchKey == key else { return }
        prefetchTask = nil
        prefetchKey = nil
    }

    private func storeDownloadedFile(
        _ download: DownloadResult,
        song: Song,
        requestedQuality: ThirdPartyAudioQuality,
        key: String
    ) -> Bool {
        defer {
            if fm.fileExists(atPath: download.url.path) {
                try? fm.removeItem(at: download.url)
            }
        }

        guard let attrs = try? fm.attributesOfItem(atPath: download.url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              size > 0,
              size <= limitBytes else {
            return false
        }

        if song.duration >= 45 && size < 250_000 {
            ATMusicLogger.shared.log("🚫 拒绝写入异常截断/防盗链音频缓存：\(song.name) 大小=\(size) 歌曲时长=\(song.duration)s", level: .warn)
            return false
        }

        if Self.isSuspiciouslyTruncated(fileURL: download.url, nominalDuration: Double(song.duration)) {
            ATMusicLogger.shared.log("🚫 拒绝写入时长异常的音频缓存：\(song.name) 标称=\(song.duration)s", level: .warn)
            return false
        }

        trimToLimit(requiredBytes: size, protecting: protectedKeys().union([key]))
        let retainedBytes = entries.values.reduce(Int64(0)) { $0 + $1.fileSize }
        guard retainedBytes + size <= limitBytes else {
            ATMusicLogger.shared.log(
                "跳过下一首缓存：当前保护中的缓存与新文件合计超过缓存上限",
                level: .debug
            )
            return false
        }
        guard freeDiskBytes() > Self.minimumFreeDiskBytes else {
            trimForLowDisk()
            guard freeDiskBytes() > Self.minimumFreeDiskBytes else { return false }
            return false
        }

        let ext = download.url.pathExtension.isEmpty
            ? download.actualQuality.defaultFileExtension
            : download.url.pathExtension.lowercased()
        let filename = ext.isEmpty ? key : "\(key).\(ext)"
        let target = directory.appendingPathComponent(filename)

        if let old = entries[key] {
            try? fm.removeItem(at: directory.appendingPathComponent(old.filename))
            entries.removeValue(forKey: key)
        }
        try? fm.removeItem(at: target)

        do {
            try fm.moveItem(at: download.url, to: target)
            entries[key] = Entry(
                key: key,
                songIdentityKey: song.identityKey,
                requestedQuality: requestedQuality.rawValue,
                actualQuality: download.actualQuality.rawValue,
                filename: filename,
                fileSize: size,
                createdAt: Date(),
                lastAccessAt: Date()
            )
            persistIndex()
            refreshPublishedUsage()
            trimToLimit(requiredBytes: 0, protecting: protectedKeys())
            return true
        } catch {
            ATMusicLogger.shared.log(
                "缓存文件落盘失败：\(song.name) - \(error.localizedDescription)",
                level: .debug
            )
            return false
        }
    }

    private func protectedKeys() -> Set<String> {
        Set([currentPlaybackKey, prefetchKey].compactMap { $0 })
    }

    private func trimForLowDisk() {
        let target = min(limitBytes * 7 / 10, max(0, usageBytes / 2))
        trim(to: target, protecting: protectedKeys())
    }

    private func trimToLimit(requiredBytes: Int64, protecting: Set<String>) {
        let target = max(0, limitBytes - requiredBytes)
        trim(to: target, protecting: protecting)
    }

    private func trim(to targetBytes: Int64, protecting: Set<String>) {
        var total = entries.values.reduce(Int64(0)) { $0 + $1.fileSize }
        guard total > targetBytes else { return }

        let candidates = entries.values
            .filter { !protecting.contains($0.key) }
            .sorted {
                if $0.lastAccessAt == $1.lastAccessAt {
                    return $0.createdAt < $1.createdAt
                }
                return $0.lastAccessAt < $1.lastAccessAt
            }

        for entry in candidates where total > targetBytes {
            try? fm.removeItem(at: directory.appendingPathComponent(entry.filename))
            entries.removeValue(forKey: entry.key)
            total -= entry.fileSize
        }
        persistIndex()
        refreshPublishedUsage()
    }

    private func removeEntry(forKey key: String) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        try? fm.removeItem(at: directory.appendingPathComponent(entry.filename))
    }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            entries = [:]
            return
        }
        entries = decoded
    }

    private func reconcileIndex() {
        var changed = false
        for (key, entry) in Array(entries) {
            if !fm.fileExists(atPath: directory.appendingPathComponent(entry.filename).path) {
                entries.removeValue(forKey: key)
                changed = true
            }
        }
        if changed { persistIndex() }
    }

    private func persistIndex() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private func refreshPublishedUsage() {
        usageBytes = entries.values.reduce(Int64(0)) { $0 + $1.fileSize }
        cachedSongCount = entries.count
    }

    private func freeDiskBytes() -> Int64 {
        if let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let value = values.volumeAvailableCapacityForImportantUsage {
            return Int64(value)
        }
        let attrs = try? fm.attributesOfFileSystem(forPath: directory.path)
        return (attrs?[.systemFreeSize] as? NSNumber)?.int64Value ?? Int64.max
    }

    /// 时长验货：标称 ≥45s 的歌曲，本地文件真实时长 <20s 且不足标称一半 → 防盗链/残缺文件。
    /// 只在有确凿证据时判定（文件打不开/时长读不到一律放行，交给播放与自愈路径处理）。
    nonisolated static func isSuspiciouslyTruncated(fileURL: URL, nominalDuration: Double) -> Bool {
        guard nominalDuration >= 45,
              let audioFile = try? AVAudioFile(forReading: fileURL),
              audioFile.fileFormat.sampleRate > 0 else { return false }
        let seconds = Double(audioFile.length) / audioFile.fileFormat.sampleRate
        guard seconds.isFinite, seconds > 0 else { return false }
        return seconds < 20 && seconds < nominalDuration * 0.5
    }

    private func cacheKey(song: Song, quality: ThirdPartyAudioQuality) -> String {
        stableHash("\(song.identityKey)|\(song.source.rawValue)|\(quality.rawValue)")
    }

    /// Swift 的 hashValue 每次进程启动都会随机化，缓存文件名必须使用稳定散列。
    private func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(format: "%016llx", hash)
    }
}

