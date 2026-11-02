import Foundation

// MARK: - NAS 封面物理写入

enum SynologyCoverWriteError: LocalizedError {
    case unsupportedContainer(String)
    case missingPath
    case tooLarge(Int64)

    var errorDescription: String? {
        switch self {
        case .unsupportedContainer(let ext):
            return "\(ext.uppercased()) 容器暂不支持内嵌封面"
        case .missingPath:
            return "缺少原文件路径，无法写回封面"
        case .tooLarge(let bytes):
            return "文件过大（\(bytes / 1_048_576) MB），已跳过内嵌以免传输失败"
        }
    }
}

/// 把封面真正写进**NAS 上的音频文件本体**。
///
/// Audio Station 的标签通道能改文字标签，但封面很容易只落到「文件夹图片」这一层，
/// 于是别的播放器/拷出来的文件里还是没有封面。这里的做法最实在也最难出错：
/// 下载原文件 → 用本地已验证的容器写入器内嵌封面（保留原有其它标签与歌词）→ 覆盖回传。
extension SynologyAPI {

    /// 内嵌封面的单文件上限：再大就不折腾了，交给文件夹 cover.jpg 兜底。
    static let coverEmbedSizeLimit: Int64 = 300 * 1_048_576

    /// 内嵌封面，返回写入报告摘要。
    @discardableResult
    func embedCoverIntoNASFile(song: Song, coverData: Data) async throws -> AudioTagWriteReport {
        guard let path = song.synologyPath, !path.isEmpty else {
            throw SynologyCoverWriteError.missingPath
        }
        let ext = (path as NSString).pathExtension.lowercased()
        let writable: Set<String> = ["mp3", "mp2", "mpga", "flac", "m4a", "mp4", "alac", "m4b", "wav", "wave", "aiff", "aif", "aifc"]
        guard writable.contains(ext) else {
            throw SynologyCoverWriteError.unsupportedContainer(ext)
        }

        // 1. 下载
        let downloaded = try await downloadFileFromNAS(path: path)
        let bytes = Int64(downloaded.count)
        guard bytes > 0 else { throw SynologyError.networkError("下载到的文件为空") }
        guard bytes <= Self.coverEmbedSizeLimit else {
            throw SynologyCoverWriteError.tooLarge(bytes)
        }

        // 2. 本地内嵌（只带封面 + 基础标签，未提供的字段一律保持文件原样）
        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent("atm-cover-\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try downloaded.write(to: tempURL, options: .atomic)

        var tags = AudioTagSet(coverData: coverData)
        if !song.name.isEmpty && song.name != "未知歌曲" { tags.title = song.name }
        if !song.artists.isEmpty && song.artists != "未知艺术家" { tags.artist = song.artists }
        if !song.album.isEmpty && song.album != "群晖 NAS" { tags.album = song.album }
        if let aa = song.albumArtist, !aa.isEmpty { tags.albumArtist = aa }
        if let g = song.genre, !g.isEmpty { tags.genre = g }
        if let y = song.year, !y.isEmpty { tags.year = y }
        if let c = song.comment, !c.isEmpty { tags.comment = c }
        if song.trackNumber > 0 { tags.track = song.trackNumber }
        if song.discNumber > 0 { tags.disc = song.discNumber }
        tags.lyrics = nil  // 保留原有歌词不动
        let report = try AudioTagEmbedder.writeInPlace(tags: tags, fileURL: tempURL)

        // 3. 覆盖回传
        let folder = (path as NSString).deletingLastPathComponent
        let filename = (path as NSString).lastPathComponent
        _ = try await uploadFileToNAS(
            localFileURL: tempURL,
            destinationFolder: folder,
            filename: filename,
            mimeType: AudioFormatDetector.mimeType(forExtension: ext)
        )
        return report
    }

    /// 在专辑目录写一份 cover.jpg（给按文件夹取封面的播放器兜底）。
    /// 同一目录在一次流程里只上传一次，由调用方去重。
    func writeFolderCover(folderPath: String, coverData: Data) async throws {
        let folder = folderPath.hasPrefix("/") ? folderPath : "/" + folderPath
        let optimized = optimizedCoverData(coverData)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("atm-folder-cover-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try optimized.write(to: tempURL, options: .atomic)
        _ = try await uploadFileToNAS(
            localFileURL: tempURL,
            destinationFolder: folder,
            filename: "cover.jpg",
            mimeType: "image/jpeg"
        )
    }

    /// 歌曲所在目录（NAS 绝对路径风格）
    static func folderPath(of song: Song) -> String? {
        guard let path = song.synologyPath, !path.isEmpty else { return nil }
        let folder = (path as NSString).deletingLastPathComponent
        return folder.isEmpty ? nil : folder
    }
}
