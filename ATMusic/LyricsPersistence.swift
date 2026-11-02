import Foundation

// MARK: - 歌词持久化（NAS / 本地统一入口）

/// 歌词写回的唯一入口。
///
/// 之前只把歌词写进音频文件标签（tag_editor），没有更新**同目录同名的 .lrc**，
/// 也没有覆盖本机的歌词缓存，于是出现「搜了新歌词、下次播放还是旧的」：
/// 库里往往存在归档时上传的 `<歌名>.lrc`，Audio Station / 其它播放器优先读它；
/// 而 App 自己又是先读本地缓存，两边都还留着旧内容。
///
/// 现在的做法是「一处调用，四处落地」：
/// 1. 音频文件内嵌歌词（Audio Station tag_editor，保留其它标签）；
/// 2. 同目录同名 `.lrc`（覆盖写，路径与音频同基名）；
/// 3. Audio Station 歌词库（`setlyrics`，不同 DSM 读取优先级不同，两手都写）；
/// 4. 本机歌词缓存（覆盖写），保证切歌再切回来立刻是新的。
enum LyricsPersistence {

    struct Report {
        let message: String
        let wroteFileTag: Bool
        let wroteSidecar: Bool
        let wroteLyricsAPI: Bool
        var isSuccess: Bool { wroteFileTag || wroteSidecar || wroteLyricsAPI }
    }

    // MARK: 保存

    @discardableResult
    static func save(song: Song, raw: String) async -> Report {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Report(message: "歌词内容为空，未写入", wroteFileTag: false, wroteSidecar: false, wroteLyricsAPI: false)
        }

        // 无论写 NAS 是否成功，本机缓存都先跟上，保证当场与切歌回来都看到新歌词。
        // 先删再写：旧歌词缓存里的翻译（.tlrc）是按时间戳挂的，换歌词后必须一起作废，
        // 否则会出现「新歌词 + 旧翻译」错配。
        await ATMusicCacheCoordinator.shared.removeCachedLyric(for: song)
        await ATMusicCacheCoordinator.shared.cacheLyric(for: song, content: raw)

        if song.source == .synology {
            return await saveToNAS(song: song, raw: raw)
        }
        // 在线流媒体且没离线：没有本地文件可写，更新缓存即可（离线后可用「歌词同步校准」再写回文件）
        if LocalTagWriteback.audioFileURL(for: song) == nil {
            return Report(
                message: "歌词已更新（本机缓存；这首歌还没离线，暂无可写入的音频文件）",
                wroteFileTag: false,
                wroteSidecar: false,
                wroteLyricsAPI: false
            )
        }
        return await saveToLocal(song: song, raw: raw)
    }

    private static func saveToNAS(song: Song, raw: String) async -> Report {
        var wroteTag = false
        var wroteSidecar = false
        var wroteAPI = false
        var failures: [String] = []

        // 1. 内嵌进音频文件标签
        do {
            try await SynologyAPI.shared.applyMetadata(
                song: song,
                patch: LyricWriteback.emptyPatch(),
                lyrics: raw
            )
            wroteTag = true
        } catch {
            failures.append("内嵌标签：\(error.localizedDescription)")
        }

        // 2. 同目录同名 .lrc（库里通常有归档时生成的这一份，必须一起更新）
        do {
            try await SynologyAPI.shared.uploadLyricsSidecar(song: song, lyrics: raw)
            wroteSidecar = true
        } catch {
            failures.append("同名 .lrc：\(error.localizedDescription)")
        }

        // 3. Audio Station 歌词库
        do {
            try await SynologyAPI.shared.saveLyrics(song: song, lyrics: raw)
            wroteAPI = true
        } catch {
            failures.append("歌词接口：\(error.localizedDescription)")
        }

        // 4. 回读校验：读回来的还是旧内容时，至少让用户知道该刷新的层级没刷到
        var verificationNote = ""
        if let fetched = try? await SynologyAPI.shared.lyrics(song: song),
           !normalized(fetched).isEmpty,
           normalized(fetched) != normalized(raw) {
            verificationNote = "（回读到的仍是旧歌词，可能被服务端缓存，稍后会自动刷新）"
            ATMusicLogger.shared.log(
                "⚠️ 歌词回读与写入不一致：\(song.name) 写入 \(normalized(raw).count) 字 / 回读 \(normalized(fetched).count) 字",
                level: .warn
            )
        }

        let report = Report(
            message: reportMessage(prefix: "歌词已保存到 NAS", tag: wroteTag, sidecar: wroteSidecar, api: wroteAPI, failures: failures) + verificationNote,
            wroteFileTag: wroteTag,
            wroteSidecar: wroteSidecar,
            wroteLyricsAPI: wroteAPI
        )
        ATMusicLogger.shared.log(
            "🎤 歌词写回 \(song.name)：内嵌=\(wroteTag) lrc=\(wroteSidecar) 接口=\(wroteAPI)"
                + (failures.isEmpty ? "" : " 失败项：\(failures.joined(separator: "；"))"),
            level: report.isSuccess ? .info : .error
        )
        return report
    }

    private static func saveToLocal(song: Song, raw: String) async -> Report {
        var wroteSidecar = false
        var wroteTag = false
        var failures: [String] = []

        if LocalTagWriteback.writeSidecarLyrics(raw, for: song) {
            wroteSidecar = true
        } else {
            failures.append("本地 .lrc 写入失败")
        }
        switch await LocalTagWriteback.writeLyricsAsync(song: song, lyrics: raw) {
        case .success:
            wroteTag = true
        case .failure(let error):
            failures.append("内嵌歌词：\(error.localizedDescription)")
        }
        return Report(
            message: reportMessage(prefix: "歌词已保存", tag: wroteTag, sidecar: wroteSidecar, api: false, failures: failures),
            wroteFileTag: wroteTag,
            wroteSidecar: wroteSidecar,
            wroteLyricsAPI: false
        )
    }

    // MARK: 清除

    @discardableResult
    static func clear(song: Song) async -> String {
        await ATMusicCacheCoordinator.shared.removeCachedLyric(for: song)
        if song.source == .synology {
            var failures: [String] = []
            do {
                try await SynologyAPI.shared.applyMetadata(
                    song: song,
                    patch: LyricWriteback.emptyPatch(),
                    lyrics: ""
                )
            } catch {
                failures.append("内嵌标签：\(error.localizedDescription)")
            }
            do {
                try await SynologyAPI.shared.deleteLyricsSidecar(song: song)
            } catch {
                failures.append("同名 .lrc：\(error.localizedDescription)")
            }
            do {
                try await SynologyAPI.shared.saveLyrics(song: song, lyrics: "")
            } catch {
                // DSM 不接受清空歌词时忽略，文件侧已清
            }
            ATMusicLogger.shared.log("🎤 清除 NAS 歌词：\(song.name)" + (failures.isEmpty ? "" : " 失败项：\(failures.joined(separator: "；"))"), level: failures.isEmpty ? .info : .warn)
            return failures.isEmpty ? "已清除 NAS 歌词" : "部分清除失败：\(failures.joined(separator: "；"))"
        }
        if let sidecar = LocalTagWriteback.sidecarLyricURL(for: song) {
            try? FileManager.default.removeItem(at: sidecar)
        }
        return "已清除本地歌词"
    }

    // MARK: 工具

    private static func reportMessage(prefix: String, tag: Bool, sidecar: Bool, api: Bool, failures: [String]) -> String {
        var parts: [String] = []
        if tag { parts.append("文件内嵌") }
        if sidecar { parts.append("同名 .lrc") }
        if api { parts.append("歌词库") }
        if parts.isEmpty {
            return prefix + "失败：" + failures.joined(separator: "；")
        }
        let base = prefix + "（" + parts.joined(separator: " + ") + "）"
        return failures.isEmpty ? base : base + "，部分失败：" + failures.joined(separator: "；")
    }

    private static func normalized(_ value: String) -> String {
        value.replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

// MARK: - NAS 歌词旁挂文件

extension SynologyAPI {

    /// 音频同目录、同基名的 `.lrc`（Audio Station 与常见播放器都认这个）。
    static func lyricsSidecarPath(for song: Song) -> String? {
        guard let path = song.synologyPath, !path.isEmpty else { return nil }
        let folder = (path as NSString).deletingLastPathComponent
        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        guard !base.isEmpty else { return nil }
        let joined = folder.isEmpty ? base : folder + "/" + base
        return joined + ".lrc"
    }

    func uploadLyricsSidecar(song: Song, lyrics: String) async throws {
        guard let path = song.synologyPath, !path.isEmpty else {
            throw SynologyError.missingConfiguration("当前 NAS 歌曲没有原文件路径，无法写入同名 .lrc")
        }
        let folder = (path as NSString).deletingLastPathComponent
        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        guard !base.isEmpty else {
            throw SynologyError.missingConfiguration("无法从原文件路径推导 .lrc 名称")
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("atm-lyrics-\(UUID().uuidString).lrc")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try lyrics.data(using: .utf8)?.write(to: tempURL, options: .atomic)
        _ = try await uploadFileToNAS(
            localFileURL: tempURL,
            destinationFolder: folder,
            filename: base + ".lrc",
            mimeType: "text/plain"
        )
    }

    func deleteLyricsSidecar(song: Song) async throws {
        guard let path = Self.lyricsSidecarPath(for: song) else {
            throw SynologyError.missingConfiguration("无法定位同名 .lrc")
        }
        try await deleteNASFile(path: path)
    }

    /// File Station 删除单个文件（歌词旁挂清理用）。
    func deleteNASFile(path: String) async throws {
        _ = try await postForm(
            "/webapi/entry.cgi",
            form: [
                "api": "SYNO.FileStation.Delete",
                "version": "2",
                "method": "delete",
                "path": "[\(jsonQuoted(path))]",
                "recursive": "false"
            ],
            authenticated: true,
            acceptsMissingSuccess: true
        )
    }

    private func jsonQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
