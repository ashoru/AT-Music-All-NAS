import Foundation
import AVFoundation
import UIKit

enum LibraryStorageError: LocalizedError {
    case invalidPath, unsupportedSchema, unavailable
    var errorDescription: String? {
        switch self {
        case .invalidPath: return "音频路径无效或已移出受管目录"
        case .unsupportedSchema: return "音乐库格式不受支持，原数据已保留"
        case .unavailable: return "音乐库未能安全读取，已停止写入以保护原数据"
        }
    }
}

/// 所有新数据放到 Application Support 独立文件，原 UserDefaults 数据不删除。
/// 原子替换前保存上一份；坏文件不按空库覆盖，错误交给调用方。
struct AtomicLibraryFile<Value: Codable> {
    struct Envelope: Codable {
        let schema: Int
        let value: Value
    }
    let url: URL
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UnifiedLibrary", isDirectory: true)
    }
    func read() throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
        guard envelope.schema == 2 else { throw LibraryStorageError.unsupportedSchema }
        return envelope.value
    }
    func write(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Envelope(schema: 2, value: value))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            // 校验旧文件，防止外部损坏后把坏内容盖到恢复副本。
            _ = try read()
            let previous = try Data(contentsOf: url)
            try previous.write(to: url.appendingPathExtension("previous"), options: .atomic)
        }
        try data.write(to: url, options: .atomic)
    }
}

enum AudioFileKind: String, Codable, Sendable {
    case userImported, userDownloaded, playbackCache
}

struct ManagedAudioFile: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let songId: String
    let relativePath: String
    let kind: AudioFileKind
    let originalFilename: String
    let fileSize: Int64
    let sha256Hash: String?
    let fileExtension: String
    let createdAt: Date
}

/// 只允许受管音频目录内的真实路径；拒绝 ..、绝对路径和越界符号链接。
enum ManagedAudioPath {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// 确保受管离线音频目录存在并排除在 iCloud 备份之外，防止音频文件占用用户云存储空间
    static func ensureExcludedFromBackup() {
        var root = documents.appendingPathComponent("ATMusicAudio", isDirectory: true)
        if !FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
    }
    static func resolve(_ relativePath: String, documents: URL = documents) throws -> URL {
        guard !relativePath.hasPrefix("/"), relativePath.hasPrefix("ATMusicAudio/"),
              !relativePath.split(separator: "/").contains("..") else { throw LibraryStorageError.invalidPath }
        let root = documents.appendingPathComponent("ATMusicAudio", isDirectory: true).standardizedFileURL
        let resolvedRoot = root.resolvingSymlinksInPath()
        // 不允许整个受管目录被替换成指向其他位置的链接。
        guard resolvedRoot.path == root.path else { throw LibraryStorageError.invalidPath }
        let file = documents.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(resolvedRoot.path + "/"), file.path != resolvedRoot.path else {
            throw LibraryStorageError.invalidPath
        }
        return file
    }

    /// 动态修复可能包含旧沙盒容器 UUID 的本地文件 URL，自动映射到当前运行沙盒 Documents 真实目录
    static func resolveFileURL(_ url: URL?) -> URL? {
        guard let url else { return nil }
        guard url.isFileURL else { return url }

        // 1. 若当前路径真实存在，直接返回
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }

        // 2. 检查是否包含 ATMusicAudio 受管目录
        let fullPath = url.path
        if let range = fullPath.range(of: "ATMusicAudio/") {
            let relativePath = String(fullPath[range.lowerBound...])
            if let resolved = try? ManagedAudioPath.resolve(relativePath),
               FileManager.default.fileExists(atPath: resolved.path) {
                return resolved
            }
        }

        // 3. 检查是否包含 /Documents/ 目录
        if let range = fullPath.range(of: "/Documents/") {
            let relativeDocPath = String(fullPath[range.upperBound...])
            let currentTarget = documents.appendingPathComponent(relativeDocPath)
            if FileManager.default.fileExists(atPath: currentTarget.path) {
                return currentTarget
            }
        }

        return url
    }

    /// 针对歌曲封面多层级解析：本地已持久化封面优先，沙盒相对路径解析，内嵌封面兜底
    static func resolveCoverURL(candidate: URL?, localRelativePath: String?) -> URL? {
        // 1. 如果有 localRelativePath，优先计算对应的本地 Artwork 路径
        if let localRelativePath, !localRelativePath.isEmpty {
            let recordId = ((localRelativePath as NSString).lastPathComponent as NSString).deletingPathExtension
            let artworkRelative = "ATMusicAudio/Artwork/\(recordId).jpg"
            if let artworkURL = try? ManagedAudioPath.resolve(artworkRelative),
               FileManager.default.fileExists(atPath: artworkURL.path) {
                return artworkURL
            }
        }

        // 2. 如果 candidate 是本地文件，尝试修复沙盒路径
        if let candidate {
            if candidate.isFileURL {
                if let resolved = resolveFileURL(candidate), FileManager.default.fileExists(atPath: resolved.path) {
                    return resolved
                }
            } else {
                // 网络直链直接返回
                return candidate
            }
        }

        return candidate
    }
}


// MARK: - 音频格式检测器（基于文件头 Magic Bytes 权威推断）

enum AudioFormatDetector {
    static func detectExtension(fileURL: URL, fallback: String = "mp3") -> String {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return fallback }
        defer { try? handle.close() }
        let header = (try? handle.read(upToCount: 32)) ?? Data()
        return detectExtension(fromHeaderData: header, fallback: fallback)
    }

    static func detectExtension(fromHeaderData header: Data, fallback: String = "mp3") -> String {
        guard header.count >= 4 else { return fallback }

        // FLAC: 0x66 0x4C 0x61 0x43 ("fLaC")
        if header.starts(with: [0x66, 0x4C, 0x61, 0x43]) {
            return "flac"
        }

        // MP3 with ID3: 0x49 0x44 0x33 ("ID3")
        if header.starts(with: [0x49, 0x44, 0x33]) {
            return "mp3"
        }

        // MP3 MPEG sync frame: 11 bits set to 1 (0xFF, high 3 bits of byte 1 are 1)
        if header[0] == 0xFF && (header[1] & 0xE0) == 0xE0 {
            return "mp3"
        }

        // WAV: "RIFF" .... "WAVE"
        if header.starts(with: [0x52, 0x49, 0x46, 0x46]) && header.count >= 12 {
            if header[8] == 0x57 && header[9] == 0x41 && header[10] == 0x56 && header[11] == 0x45 {
                return "wav"
            }
        }

        // M4A / AAC / MP4: bytes 4..7 == "ftyp" (0x66 0x74 0x79 0x70)
        if header.count >= 8 && header[4] == 0x66 && header[5] == 0x74 && header[6] == 0x79 && header[7] == 0x70 {
            return "m4a"
        }

        // OGG: "OggS" (0x4F 0x67 0x67 0x53)
        if header.starts(with: [0x4F, 0x67, 0x67, 0x53]) {
            return "ogg"
        }

        // APE: "MAC " (0x4D 0x41 0x43 0x20)
        if header.starts(with: [0x4D, 0x41, 0x43, 0x20]) {
            return "ape"
        }

        // DSD / DSF: "DSD " (0x44 0x53 0x44 0x20)
        if header.starts(with: [0x44, 0x53, 0x44, 0x20]) {
            return "dsf"
        }

        // AIFF: "FORM" .... "AIFF" / "AIFC"
        if header.starts(with: [0x46, 0x4F, 0x52, 0x4D]) && header.count >= 12 {
            if header[8] == 0x41 && header[9] == 0x49 && header[10] == 0x46 && (header[11] == 0x46 || header[11] == 0x43) {
                return "aiff"
            }
        }

        return fallback
    }

    static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "flac": return "audio/flac"
        case "mp3", "mp2", "mpga": return "audio/mpeg"
        case "m4a", "aac", "mp4", "alac", "m4b": return "audio/mp4"
        case "wav", "wave": return "audio/wav"
        case "aiff", "aif", "aifc": return "audio/aiff"
        case "ogg", "oga": return "audio/ogg"
        case "opus": return "audio/opus"
        case "ape": return "audio/x-ape"
        case "dsf", "dff": return "audio/x-dsf"
        default: return "application/octet-stream"
        }
    }
}

final class LocalAudioFileManager: @unchecked Sendable {
    static let shared = LocalAudioFileManager()
    private let documents: URL
    private let file: AtomicLibraryFile<[String: ManagedAudioFile]>
    private let lock = NSLock()
    private var fileIndex: [String: ManagedAudioFile] = [:]
    private var loadFailed = false

    init(documents: URL = ManagedAudioPath.documents,
         directory: URL = AtomicLibraryFile<[String: ManagedAudioFile]>.defaultDirectory,
         defaults: UserDefaults = .standard) {
        self.documents = documents.standardizedFileURL.resolvingSymlinksInPath()
        file = AtomicLibraryFile(url: directory.appendingPathComponent("audio-files-v2.json"))
        do {
            if let saved = try file.read() { fileIndex = saved }
            else if let legacy = defaults.data(forKey: "atmusic.managed.audio.files.v1") {
                fileIndex = try JSONDecoder().decode([String: ManagedAudioFile].self, from: legacy)
                try file.write(fileIndex)
            }
        } catch { loadFailed = true }
        ManagedAudioPath.ensureExcludedFromBackup()
        repairTmpFilesIfNeeded()
    }

    func registerFile(sourceTempURL: URL, songId: String, originalFilename: String,
                      kind: AudioFileKind, sha256: String? = nil, explicitExtension: String? = nil) throws -> ManagedAudioFile {
        lock.lock()
        defer { lock.unlock() }
        guard !loadFailed else { throw LibraryStorageError.unavailable }
        var ext = explicitExtension?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if ext.isEmpty || ext == "tmp" {
            let tempExt = sourceTempURL.pathExtension.lowercased()
            if !tempExt.isEmpty && tempExt != "tmp" {
                ext = tempExt
            } else {
                let origExt = (originalFilename as NSString).pathExtension.lowercased()
                if !origExt.isEmpty && origExt != "tmp" {
                    ext = origExt
                } else {
                    ext = AudioFormatDetector.detectExtension(fileURL: sourceTempURL, fallback: "mp3")
                }
            }
        }
        let uniqueID = "aud_" + UUID().uuidString
        let relative = "ATMusicAudio/" + uniqueID + "." + ext
        let target = try ManagedAudioPath.resolve(relative, documents: documents)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        // copyItem 不覆盖目标；源文件永远不移动或删除。
        try FileManager.default.copyItem(at: sourceTempURL, to: target)
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: target.path)
            let record = ManagedAudioFile(id: uniqueID, songId: songId, relativePath: relative, kind: kind,
                originalFilename: originalFilename, fileSize: (attrs[.size] as? NSNumber)?.int64Value ?? 0,
                sha256Hash: sha256, fileExtension: ext, createdAt: Date())
            var next = fileIndex
            next[record.id] = record
            try file.write(next)
            fileIndex = next
            return record
        } catch {
            // 仅回收本次新复制、尚未登记的副本。
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }

    private func exists(_ item: ManagedAudioFile) -> Bool {
        guard let url = try? ManagedAudioPath.resolve(item.relativePath, documents: documents) else { return false }
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && !directory.boolValue
    }
    func url(for item: ManagedAudioFile) throws -> URL {
        try ManagedAudioPath.resolve(item.relativePath, documents: documents)
    }
    func file(forSongId songId: String) -> ManagedAudioFile? {
        lock.lock()
        defer { lock.unlock() }
        return fileIndex.values.filter { $0.songId == songId && exists($0) }
            .sorted { $0.createdAt < $1.createdAt }.first
    }
    func findDuplicate(sha256: String) -> ManagedAudioFile? {
        guard !sha256.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return fileIndex.values.first { $0.sha256Hash == sha256 && exists($0) }
    }

    func allFiles() -> [ManagedAudioFile] {
        lock.lock()
        defer { lock.unlock() }
        return fileIndex.values.filter { exists($0) }.sorted { $0.createdAt < $1.createdAt }
    }

    func file(relativePath: String) -> ManagedAudioFile? {
        lock.lock()
        defer { lock.unlock() }
        return fileIndex.values.first { $0.relativePath == relativePath && exists($0) }
    }

    /// 将与音频配套的歌词或封面保存到受管目录，路径同样经过越界校验。
    func copySupportFile(sourceURL: URL, relativePath: String) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        guard !loadFailed else { throw LibraryStorageError.unavailable }
        let target = try ManagedAudioPath.resolve(relativePath, documents: documents)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.copyItem(at: sourceURL, to: target)
        return target
    }

    /// 用户主动删除时先可恢复地移到隔离目录，索引提交失败则移回。
    private func removeLocked(_ item: ManagedAudioFile) throws {
        guard !loadFailed else { throw LibraryStorageError.unavailable }
        let source = try ManagedAudioPath.resolve(item.relativePath, documents: documents)
        let trash = try ManagedAudioPath.resolve("ATMusicAudio/RecentlyRemoved/" + UUID().uuidString, documents: documents)
        let exists = FileManager.default.fileExists(atPath: source.path)
        if exists {
            try FileManager.default.createDirectory(at: trash.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: source, to: trash)
        }
        var next = fileIndex
        next.removeValue(forKey: item.id)
        do { try file.write(next) }
        catch {
            if exists { try? FileManager.default.moveItem(at: trash, to: source) }
            throw error
        }
        fileIndex = next
        // 已从受管列表移除；缓存可直接清除，用户音频保留隔离副本以备恢复。
        if exists && item.kind == .playbackCache { try? FileManager.default.removeItem(at: trash) }
    }

    /// 自动巡检并修复沙盒中历史遗留的 .tmp 文件，推断真实音频格式并改名，无缝恢复 0ms 离线秒播
    func repairTmpFilesIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !loadFailed else { return }

        var changed = false
        var updatedIndex = fileIndex

        for (id, record) in fileIndex {
            let isTmp = record.fileExtension.lowercased() == "tmp" || record.relativePath.hasSuffix(".tmp")
            guard isTmp else { continue }
            guard let oldURL = try? ManagedAudioPath.resolve(record.relativePath, documents: documents),
                  FileManager.default.fileExists(atPath: oldURL.path) else { continue }

            let realExt = AudioFormatDetector.detectExtension(fileURL: oldURL, fallback: "mp3")
            let newRelative = "ATMusicAudio/\(record.id).\(realExt)"
            guard let newURL = try? ManagedAudioPath.resolve(newRelative, documents: documents) else { continue }

            do {
                if FileManager.default.fileExists(atPath: newURL.path) {
                    try? FileManager.default.removeItem(at: newURL)
                }
                try FileManager.default.moveItem(at: oldURL, to: newURL)

                // 迁移伴生歌词
                let oldLrcPath1 = (record.relativePath as NSString).deletingPathExtension + ".lrc"
                let oldLrcPath2 = record.relativePath + ".lrc"
                let newLrcPath = "ATMusicAudio/\(record.id).lrc"
                for oldPath in [oldLrcPath1, oldLrcPath2] {
                    if let oldLrcURL = try? ManagedAudioPath.resolve(oldPath, documents: documents),
                       FileManager.default.fileExists(atPath: oldLrcURL.path),
                       let newLrcURL = try? ManagedAudioPath.resolve(newLrcPath, documents: documents) {
                        if !FileManager.default.fileExists(atPath: newLrcURL.path) {
                            try? FileManager.default.moveItem(at: oldLrcURL, to: newLrcURL)
                        }
                    }
                }

                let newRecord = ManagedAudioFile(
                    id: record.id,
                    songId: record.songId,
                    relativePath: newRelative,
                    kind: record.kind,
                    originalFilename: record.originalFilename,
                    fileSize: record.fileSize,
                    sha256Hash: record.sha256Hash,
                    fileExtension: realExt,
                    createdAt: record.createdAt
                )
                updatedIndex[id] = newRecord
                changed = true
                ATMusicLogger.shared.log("🛠️ 成功自愈修复历史离线音频文件：\(record.originalFilename) [tmp -> \(realExt)]", level: .info)
            } catch {
                ATMusicLogger.shared.log("自愈修复音频文件失败：\(record.originalFilename) 错误：\(error.localizedDescription)", level: .warn)
            }
        }

        // 扫描 ATMusicAudio 目录内可能存在的未建索引 tmp 文件
        let audioDir = documents.appendingPathComponent("ATMusicAudio", isDirectory: true)
        if let files = try? FileManager.default.contentsOfDirectory(atPath: audioDir.path) {
            for f in files where f.hasSuffix(".tmp") && f.hasPrefix("aud_") {
                let fileURL = audioDir.appendingPathComponent(f)
                let realExt = AudioFormatDetector.detectExtension(fileURL: fileURL, fallback: "mp3")
                let newName = (f as NSString).deletingPathExtension + "." + realExt
                let newURL = audioDir.appendingPathComponent(newName)
                if !FileManager.default.fileExists(atPath: newURL.path) {
                    try? FileManager.default.moveItem(at: fileURL, to: newURL)
                    ATMusicLogger.shared.log("🛠️ 修复目录内游离 tmp 文件：\(f) -> \(newName)", level: .info)
                }
            }
        }

        if changed {
            try? file.write(updatedIndex)
            fileIndex = updatedIndex

            Task { @MainActor in
                LocalLibraryStore.shared.repairTmpSongPaths()
            }
        }
    }

    func deleteFile(id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if let item = fileIndex[id] { try removeLocked(item) }
    }

    private func deleteDiskFiles(forBaseName baseName: String, relativePath: String) {
        var pathsToDelete: [String] = [relativePath]
        if !baseName.isEmpty {
            for ext in ["flac", "mp3", "m4a", "wav", "ogg", "tmp", "bin"] {
                pathsToDelete.append("ATMusicAudio/\(baseName).\(ext)")
                pathsToDelete.append("ATMusicAudio/\(baseName).\(ext).lrc")
            }
            pathsToDelete.append("ATMusicAudio/Artwork/\(baseName).jpg")
            pathsToDelete.append("ATMusicAudio/\(baseName).lrc")
            pathsToDelete.append((relativePath as NSString).deletingPathExtension + ".lrc")
            pathsToDelete.append("Trash/\(baseName).bin")
            pathsToDelete.append("ATMusicAudio/RecentlyRemoved/\(baseName)")
        }
        for p in pathsToDelete {
            if let url = try? ManagedAudioPath.resolve(p, documents: documents) {
                if FileManager.default.fileExists(atPath: url.path) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    /// 删除用户导入或下载的音频副本及其所有伴生封面、歌词文件与磁盘变体
    func deleteFileAndSupport(relativePath: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let baseName = ((relativePath as NSString).lastPathComponent as NSString).deletingPathExtension
        let matchingItems = fileIndex.values.filter {
            $0.relativePath == relativePath ||
            (!baseName.isEmpty && ((($0.relativePath as NSString).lastPathComponent as NSString).deletingPathExtension == baseName || $0.id == baseName))
        }
        for item in matchingItems {
            try? removeLocked(item)
        }
        deleteDiskFiles(forBaseName: baseName, relativePath: relativePath)
    }

    /// 根据 songId（如 qq-109295782 或 local-...）删除该曲目在受管索引和磁盘上的所有副本
    func deleteFiles(forSongId songId: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let matches = fileIndex.values.filter { $0.songId == songId }
        for item in matches {
            try? removeLocked(item)
            let base = ((item.relativePath as NSString).lastPathComponent as NSString).deletingPathExtension
            deleteDiskFiles(forBaseName: base, relativePath: item.relativePath)
        }
    }

    /// 根据歌名与歌手归一化搜索并彻底清理历史遗留副本
    func deleteFiles(matchingTitle title: String, artist: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let normTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normTitle.isEmpty else { return }
        let matches = fileIndex.values.filter {
            let orig = $0.originalFilename.lowercased()
            return orig.contains(normTitle)
        }
        for item in matches {
            try? removeLocked(item)
            let base = ((item.relativePath as NSString).lastPathComponent as NSString).deletingPathExtension
            deleteDiskFiles(forBaseName: base, relativePath: item.relativePath)
        }
    }

    /// 查询指定 songId 的所有已登记音频实体
    func allFiles(forSongId songId: String) -> [ManagedAudioFile] {
        lock.lock()
        defer { lock.unlock() }
        return fileIndex.values.filter { $0.songId == songId && exists($0) }
    }
    func clearPlaybackCacheOnly() throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        let items = fileIndex.values.filter { $0.kind == .playbackCache }
        for item in items { try removeLocked(item) }
        return items.count
    }
}

enum DownloadTaskStatus: String, Codable, Sendable {
    case pending, downloading, paused, completed, failed
}
struct DownloadTaskRecord: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let songId: String
    let songTitle: String
    let artist: String
    let coverURL: URL?
    let requestedQuality: ThirdPartyAudioQuality
    var actualQuality: ThirdPartyAudioQuality?
    var status: DownloadTaskStatus
    var progress: Double
    var totalBytes: Int64
    var downloadedBytes: Int64
    var errorDescription: String?
    var localAudioFileId: String?
    let createdAt: Date
    var updatedAt: Date
}

/// 这里只持久化任务模型。真正的后台下载、续传及下载中心属于第六阶段。
final class DownloadTaskStore: @unchecked Sendable {
    private let lock = NSLock()
    private let file: AtomicLibraryFile<[String: DownloadTaskRecord]>
    private var records: [String: DownloadTaskRecord]
    init(directory: URL = AtomicLibraryFile<[String: DownloadTaskRecord]>.defaultDirectory) throws {
        file = AtomicLibraryFile(url: directory.appendingPathComponent("download-tasks-v2.json"))
        records = try file.read() ?? [:]
        var changed = false
        for id in Array(records.keys) where records[id]?.status == .downloading {
            records[id]?.status = .paused
            records[id]?.errorDescription = "应用已重新启动，等待恢复"
            records[id]?.updatedAt = Date()
            changed = true
        }
        if changed { try file.write(records) }
    }
    func upsert(_ task: DownloadTaskRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        var next = records
        next[task.id] = task
        try file.write(next)
        records = next
    }
    var allTasks: [DownloadTaskRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records.values.sorted { $0.createdAt < $1.createdAt }
    }
}

final class UnifiedSongStore: @unchecked Sendable {
    static let shared = UnifiedSongStore()
    private static let migrationQueue = DispatchQueue(label: "atmusic.unified.migration", qos: .utility)
    private let file: AtomicLibraryFile<[String: UnifiedSong]>
    private let lock = NSLock()
    private var songsByID: [String: UnifiedSong] = [:]
    /// 可重建来源索引，与音频文件/任务索引分离，不进行全库模糊扫描。
    private var sourceIndex: [String: String] = [:]
    private var loadFailed = false
    private(set) var persistenceWrites = 0

    init(directory: URL = AtomicLibraryFile<[String: UnifiedSong]>.defaultDirectory,
         defaults: UserDefaults = .standard) {
        file = AtomicLibraryFile(url: directory.appendingPathComponent("songs-v2.json"))
        do {
            if let saved = try file.read() { songsByID = saved }
            else if let old = defaults.data(forKey: "atmusic.unified.songs.v1") {
                // v1 曾按歌名误合并：逐来源展开，保留能恢复的全部元数据；旧数据原封不动留存。
                let legacy = try JSONDecoder().decode([String: UnifiedSong].self, from: old)
                for song in legacy.values {
                    if song.sources.isEmpty { songsByID[song.id] = song }
                    for source in song.sources {
                        let restored = UnifiedSong(title: source.title, artist: source.artist, album: source.album,
                            duration: source.duration, sources: [source], preferredSourceType: source.sourceType)
                        songsByID[restored.id] = restored
                    }
                }
                try file.write(songsByID)
            }
            rebuildIndex()
        } catch { loadFailed = true }
    }
    private func rebuildIndex() {
        sourceIndex = [:]
        for song in songsByID.values {
            for source in song.sources { sourceIndex[source.id] = song.id }
        }
    }
    @discardableResult
    func registerOrMerge(song: UnifiedSong) throws -> UnifiedSong {
        try registerBatch([song])[0]
    }

    /// 不靠标题自动合并跨来源。阶段三可将候选交由用户确认。
    /// 相同来源只更新原始记录；显式 ID 碰撞且来源不同则保留两条。
    @discardableResult
    func registerBatch(_ songs: [UnifiedSong]) throws -> [UnifiedSong] {
        lock.lock()
        defer { lock.unlock() }
        guard !loadFailed else { throw LibraryStorageError.unavailable }
        var next = songsByID
        var index = sourceIndex
        var result: [UnifiedSong] = []
        for song in songs {
            let known = song.sources.compactMap { index[$0.id] }.first
            if let known, var existing = next[known] {
                // 只接受全部来源都属于同一条记录，禁止跨记录隐式合并。
                guard song.sources.allSatisfy({ index[$0.id] == known || index[$0.id] == nil }) else {
                    throw LibraryStorageError.unavailable
                }
                for source in song.sources { existing.addOrUpdateSource(source); index[source.id] = known }
                next[known] = existing
                result.append(existing)
            } else {
                let unique: UnifiedSong
                if let existing = next[song.id], existing != song {
                    unique = UnifiedSong(title: song.title, artist: song.artist, album: song.album,
                        versionKind: song.versionKind, duration: song.duration, sources: song.sources,
                        preferredSourceType: song.preferredSourceType, coverURL: song.coverURL)
                    guard next[unique.id] == nil else { throw LibraryStorageError.unavailable }
                } else { unique = song }
                next[unique.id] = unique
                for source in unique.sources { index[source.id] = unique.id }
                result.append(unique)
            }
        }
        if next != songsByID {
            try file.write(next)
            songsByID = next
            sourceIndex = index
            persistenceWrites += 1
        }
        return result
    }
    @discardableResult
    func importLegacySong(_ song: Song, serverScope: String? = nil) throws -> UnifiedSong {
        try registerOrMerge(song: UnifiedSong(legacySong: song, serverScope: serverScope))
    }
    func song(byId id: String) -> UnifiedSong? {
        lock.lock()
        defer { lock.unlock() }
        return songsByID[id]
    }
    var allSongs: [UnifiedSong] {
        lock.lock()
        defer { lock.unlock() }
        return songsByID.values.sorted { $0.id < $1.id }
    }

    /// 返回与指定歌曲严格匹配的备用来源；只读查询，不改变统一库。
    func alternateSongs(for legacy: Song, preferredSource: SongSource? = nil) -> [Song] {
        let target = UnifiedSong(legacySong: legacy)
        lock.lock()
        let candidates = songsByID.values
            .filter { $0.canSafelyMerge(with: target) }
            .sorted { lhs, rhs in
                guard let preferredSource else { return lhs.id < rhs.id }
                let left = lhs.sources.contains { $0.sourceType == SongSourceType(legacySource: preferredSource) }
                let right = rhs.sources.contains { $0.sourceType == SongSourceType(legacySource: preferredSource) }
                return left && !right
            }
        lock.unlock()
        var result: [Song] = []
        for candidate in candidates {
            if let preferredSource {
                let type = SongSourceType(legacySource: preferredSource)
                if candidate.sources.contains(where: { $0.sourceType == type }),
                   let song = candidate.toLegacySong(preferredSource: type) {
                    result.append(song)
                }
            } else if let song = candidate.toLegacySong() {
                result.append(song)
            }
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0.identityKey).inserted }
    }
    @discardableResult
    func migrateLegacyPlaylistsIfNeeded(playlists: [LocalPlaylist]) throws -> [LocalPlaylist] {
        _ = try registerBatch(playlists.flatMap(\.songs).map { UnifiedSong(legacySong: $0) })
        return playlists
    }
    static func synchronizeLegacy(_ playlists: [LocalPlaylist]) {
        migrationQueue.async {
            do {
                _ = try shared.migrateLegacyPlaylistsIfNeeded(playlists: playlists)
            } catch {
                ATMusicLogger.shared.log("统一音乐库同步失败，原歌单已保留：\(error.localizedDescription)", level: .warn)
            }
        }
    }
}
