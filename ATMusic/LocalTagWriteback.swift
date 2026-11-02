import Foundation
import UIKit

/// 本地歌曲的「物理标签」写回服务。
///
/// 本地曲库（导入 + 离线下载）此前改元数据只更新 JSON 索引与 `ATMusicAudio/Artwork/` 下的独立封面，
/// 音频文件本体一直是原样：换到别的播放器、AirDrop 出去、或者插到车机上，看到的还是老标签。
/// 这里统一负责把歌名/歌手/专辑/专辑歌手/流派/年份/曲目号/碟号/备注/封面/歌词写进文件本体，
/// 所有失败都只记录日志、不影响资料库本身的保存。
enum LocalTagWriteback {

    // MARK: - 路径解析

    /// 解析出这首歌对应的受管音频文件（本地导入与离线下载共用同一套路径解析）。
    static func audioFileURL(for song: Song) -> URL? {
        if let relative = song.localRelativePath,
           let url = try? ManagedAudioPath.resolve(relative),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        // 离线下载的歌曲走受管文件登记表（内部带锁，可从后台线程安全读取）。
        if let file = LocalAudioFileManager.shared.file(forSongId: song.identityKey),
           let url = try? LocalAudioFileManager.shared.url(for: file),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        // .tmp 落地名的历史遗留记录：补试常见音频扩展名。
        if let relative = song.localRelativePath, relative.hasSuffix(".tmp") {
            let base = (relative as NSString).deletingPathExtension
            for ext in ["flac", "mp3", "m4a", "wav", "aiff"] {
                if let url = try? ManagedAudioPath.resolve(base + "." + ext),
                   FileManager.default.fileExists(atPath: url.path) {
                    return url
                }
            }
        }
        return nil
    }

    /// 与音频同名的 .lrc 旁挂文件路径（歌词烘焙后写这里）。
    static func sidecarLyricURL(for song: Song) -> URL? {
        guard let audioURL = audioFileURL(for: song) else { return nil }
        return audioURL.deletingPathExtension().appendingPathExtension("lrc")
    }

    static func currentSidecarLyrics(for song: Song) -> String? {
        guard let url = sidecarLyricURL(for: song),
              let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : raw
    }

    // MARK: - 封面准备

    /// 内嵌封面统一压到长边 1200px、JPEG 0.86：视觉无损，又能把文件增量压在几百 KB 内。
    static func optimizedCover(_ image: UIImage, maxEdge: CGFloat = 1200) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxEdge / max(size.width, size.height))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let redrawn = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return redrawn.jpegData(compressionQuality: 0.86)
    }

    /// 决定这次要写进文件的封面：优先用户这次新选的图，其次回落已持久化的封面文件。
    static func coverData(for song: Song, newImage: UIImage? = nil, explicitData: Data? = nil) -> Data? {
        if let explicitData, !explicitData.isEmpty {
            if let image = UIImage(data: explicitData), let optimized = optimizedCover(image) {
                return optimized
            }
            return explicitData
        }
        if let newImage, let optimized = optimizedCover(newImage) {
            return optimized
        }
        guard let coverURL = song.coverURL else { return nil }
        let resolved = ManagedAudioPath.resolveFileURL(coverURL) ?? coverURL
        guard resolved.isFileURL,
              let data = try? Data(contentsOf: resolved),
              !data.isEmpty else { return nil }
        if let image = UIImage(data: data), let optimized = optimizedCover(image) {
            return optimized
        }
        return data
    }

    // MARK: - 写入

    /// 用当前 Song 的完整信息重写文件标签（封面与歌词可选）。
    @discardableResult
    static func write(song: Song, coverData: Data?, lyrics: String?) throws -> AudioTagWriteReport {
        guard let url = audioFileURL(for: song) else { throw AudioTagWriteError.noAudioFile }
        var tags = AudioTagSet(
            title: song.name,
            artist: song.artists,
            album: song.album,
            albumArtist: song.albumArtist?.isEmpty == false ? song.albumArtist : song.artists,
            genre: song.genre,
            year: song.year,
            comment: song.comment,
            track: song.trackNumber,
            disc: song.discNumber,
            coverData: coverData
        )
        tags.lyrics = lyrics ?? currentSidecarLyrics(for: song)
        return try AudioTagEmbedder.writeInPlace(tags: tags, fileURL: url)
    }

    /// 后台线程执行，避免整文件重写卡住主线程。
    static func writeAsync(song: Song, coverData: Data?, lyrics: String? = nil) async -> Result<AudioTagWriteReport, Error> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let report = try write(song: song, coverData: coverData, lyrics: lyrics)
                    continuation.resume(returning: .success(report))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }
    }

    /// 只把歌词写进文件本体（时间轴烘焙后用）。
    static func writeLyricsAsync(song: Song, lyrics: String) async -> Result<AudioTagWriteReport, Error> {
        let cover = coverData(for: song)
        return await writeAsync(song: song, coverData: cover, lyrics: lyrics)
    }

    // MARK: - 歌词旁挂文件

    @discardableResult
    static func writeSidecarLyrics(_ raw: String, for song: Song) -> Bool {
        guard let url = sidecarLyricURL(for: song) else { return false }
        do {
            try raw.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            ATMusicLogger.shared.log("⚠️ 歌词旁挂文件写入失败：\(song.name) - \(error.localizedDescription)", level: .warn)
            return false
        }
    }
}
