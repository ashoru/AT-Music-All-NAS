import SwiftUI
import Foundation

// MARK: - 逐曲歌词时间轴偏移

/// 逐曲歌词偏移存储。
///
/// 布局编辑器里那根滑杆是「全局默认偏移」，适合整台设备统一口味；
/// 但不同专辑的压制时间轴本来就不一样，必须能逐曲微调，而且调完要能存下来。
/// 这里按 `identityKey` 记一份逐曲偏移，没设过的歌曲回落到全局默认值。
final class LyricOffsetStore: ObservableObject {
    static let shared = LyricOffsetStore()

    static let storageKey = "atmusic.lyricOffsets.v2"
    static let globalKey = "atmusic.lyricOffset"

    /// 偏移量上限：超过 12 秒基本不是同步问题而是拿错了歌词。
    static let limit: Double = 12
    static let coarseStep: Double = 0.5
    static let fineStep: Double = 0.1

    private let lock = NSLock()
    private var cache: [String: Double] = [:]

    /// 任何写入都会自增，视图 body 里读一下这个值即可获得刷新。
    @Published private(set) var revision: Int = 0

    private init() {
        reload()
    }

    private func reload() {
        lock.lock()
        defer { lock.unlock() }
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([String: Double].self, from: data) else {
            cache = [:]
            return
        }
        cache = decoded
    }

    /// 布局编辑器里的全局默认偏移。
    static var globalDefault: Double {
        UserDefaults.standard.double(forKey: globalKey)
    }

    func offset(for identityKey: String?) -> Double {
        guard let identityKey, !identityKey.isEmpty else { return Self.globalDefault }
        lock.lock()
        defer { lock.unlock() }
        return cache[identityKey] ?? Self.globalDefault
    }

    func hasCustomOffset(for identityKey: String?) -> Bool {
        guard let identityKey, !identityKey.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        return cache[identityKey] != nil
    }

    func set(_ value: Double, for identityKey: String?) {
        guard let identityKey, !identityKey.isEmpty else { return }
        let clamped = min(max(value, -Self.limit), Self.limit)
        lock.lock()
        cache[identityKey] = abs(clamped) < 0.001 ? nil : clamped
        if cache[identityKey] == nil { cache.removeValue(forKey: identityKey) }
        let snapshot = cache
        lock.unlock()
        persist(snapshot)
        bump()
    }

    @discardableResult
    func adjust(by delta: Double, for identityKey: String?) -> Double {
        let next = offset(for: identityKey) + delta
        set(next, for: identityKey)
        return offset(for: identityKey)
    }

    func reset(for identityKey: String?) {
        set(0, for: identityKey)
    }

    private func persist(_ snapshot: [String: Double]) {
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private func bump() {
        if Thread.isMainThread {
            revision &+= 1
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.revision &+= 1
            }
        }
    }

    /// 供 UI 直接展示："提前 0.5s" / "延后 0.2s" / "同步"
    static func text(for offset: Double) -> String {
        if abs(offset) < 0.001 { return "同步" }
        let value = String(format: "%.1f", abs(offset))
        return offset > 0 ? "提前 \(value)s" : "延后 \(value)s"
    }
}

// MARK: - 歌词时间轴烘焙与写回

/// 把「当前偏移」真正固化进歌词文本，再写回文件：
/// 这样换播放器、换设备、看内嵌歌词时都是校准好的时间轴，而不是只在本机生效。
enum LyricWriteback {

    struct Outcome {
        let message: String
        let bakedLyrics: String
        /// 是否真的落到了文件（本地音频 / NAS 文件），false 表示只更新了本地缓存。
        let wroteToFile: Bool
    }

    /// 烘焙算法本体在 `LyricTimingBaker`（Foundation-only，可独立单测）。
    static func bake(_ raw: String, offset: Double) -> String {
        LyricTimingBaker.bake(raw, offset: offset)
    }

    static func emptyPatch() -> SynologyTagPatch {
        SynologyTagPatch(title: nil, artist: nil, album: nil, albumArtist: nil,
                         genre: nil, year: nil, comment: nil)
    }

    /// 烘焙并写回：NAS 走 Audio Station 标签通道写进原文件，本地写 .lrc 旁挂并内嵌进音频。
    static func bakeAndSave(song: Song, raw: String, offset: Double) async -> Outcome {
        let baked = bake(raw, offset: offset)
        let offsetText = LyricOffsetStore.text(for: offset)

        if song.source == .synology {
            // 走统一写回：内嵌标签 + 同目录同名 .lrc + 歌词库 + 本机缓存，四层一起更新
            let report = await LyricsPersistence.save(song: song, raw: baked)
            let message = report.isSuccess
                ? "已按「\(offsetText)」校准并写回 NAS（\(report.message)）"
                : "写回 NAS 失败：\(report.message)"
            return Outcome(message: message, bakedLyrics: baked, wroteToFile: report.isSuccess)
        }

        // 在线流媒体歌曲还没离线：没有本地音频可写，就把烘焙结果落进歌词缓存，
        // 播放页立即按新时间轴走；离线后再点一次即可写进文件本体。
        guard LocalTagWriteback.audioFileURL(for: song) != nil else {
            await ATMusicCacheCoordinator.shared.cacheLyric(for: song, content: baked)
            return Outcome(
                message: "这首歌还没离线到本机，已把校准结果存进歌词缓存（离线后再保存一次即可写回文件）",
                bakedLyrics: baked,
                wroteToFile: true
            )
        }

        let sidecarWritten = LocalTagWriteback.writeSidecarLyrics(baked, for: song)
        let embedResult = await LocalTagWriteback.writeLyricsAsync(song: song, lyrics: baked)
        await ATMusicCacheCoordinator.shared.cacheLyric(for: song, content: baked)

        switch embedResult {
        case .success(let report):
            return Outcome(message: "已按「\(offsetText)」校准并写入文件（\(report.container)）", bakedLyrics: baked, wroteToFile: true)
        case .failure(let error):
            if sidecarWritten {
                return Outcome(message: "已保存 .lrc，内嵌失败：\(error.localizedDescription)", bakedLyrics: baked, wroteToFile: false)
            }
            return Outcome(message: "保存失败：\(error.localizedDescription)", bakedLyrics: baked, wroteToFile: false)
        }
    }
}
