import Foundation
import AVFoundation
import UIKit

/// 歌单播放来源策略。歌单仍保存原始歌曲；策略只影响播放时选择哪个已存在来源。
enum PlaylistSourceStrategy: String, CaseIterable, Codable, Identifiable {
    case automatic
    case preferNetEase
    case preferQQ
    case preferKugou
    case preferSynology

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "自动（按歌单记录）"
        case .preferNetEase: return "优先网易云音乐"
        case .preferQQ: return "优先 QQ 音乐"
        case .preferKugou: return "优先酷狗音乐"
        case .preferSynology: return "优先群晖 NAS"
        }
    }
    var preferredSource: SongSource? {
        switch self {
        case .automatic: return nil
        case .preferNetEase: return .netease
        case .preferQQ: return .qq
        case .preferKugou: return .kugou
        case .preferSynology: return .synology
        }
    }
}

/// 本地歌单（保存在设备本机，不依赖任何平台账号）。可混合保存多个平台歌曲。
struct LocalPlaylist: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var songs: [Song] = []
    var createdAt = Date()
    var sourceStrategy: PlaylistSourceStrategy = .automatic
    /// 用户自选封面；为空时界面取首歌封面。
    var coverURL: URL? = nil
    /// 用户自填简介；为空时不展示。
    var descriptionText: String? = nil

    enum CodingKeys: String, CodingKey { case id, name, songs, createdAt, sourceStrategy, coverURL, descriptionText }

    init(id: UUID = UUID(), name: String, songs: [Song] = [], createdAt: Date = Date(), sourceStrategy: PlaylistSourceStrategy = .automatic, coverURL: URL? = nil, descriptionText: String? = nil) {
        self.id = id
        self.name = name
        self.songs = songs
        self.createdAt = createdAt
        self.sourceStrategy = sourceStrategy
        self.coverURL = coverURL
        self.descriptionText = descriptionText
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "未命名歌单"
        songs = try c.decodeIfPresent([Song].self, forKey: .songs) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        sourceStrategy = try c.decodeIfPresent(PlaylistSourceStrategy.self, forKey: .sourceStrategy) ?? .automatic
        coverURL = try c.decodeIfPresent(URL.self, forKey: .coverURL)
        descriptionText = try c.decodeIfPresent(String.self, forKey: .descriptionText)
    }
}

/// 本地音乐库：本地歌单的创建 / 删除 / 收藏歌曲，UserDefaults JSON 持久化（覆盖安装不丢失）
final class LocalLibraryStore: ObservableObject {
    static let shared = LocalLibraryStore()

    @Published var playlists: [LocalPlaylist] {
        didSet { save() }
    }
    @Published var importedSongs: [Song] {
        didSet {
            rebuildImportedSongsIndex()
            saveImportedSongs()
        }
    }
    private var importedSongsIndex: [String: Song] = [:]
    private func rebuildImportedSongsIndex() {
        var map: [String: Song] = [:]
        for s in importedSongs {
            map[s.identityKey] = s
        }
        importedSongsIndex = map
    }

    private let defaults = UserDefaults.standard
    private let key = "atmusic.localLibrary.playlists"
    /// 阶段 5：本地歌单的独立文件存储（原子写 + 上一份备份），不再全量塞 UserDefaults。
    private let playlistFile = AtomicLibraryFile<[LocalPlaylist]>(url: AtomicLibraryFile<[LocalPlaylist]>.defaultDirectory.appendingPathComponent("local-playlists.json"))
    private let importedSongsKey = "atmusic.localLibrary.importedSongs.v1"

    private init() {
        // 优先读文件；文件损坏或不存在时回退旧键并顺手迁回文件，绝不丢歌单。
        if let list = try? playlistFile.read() {
            playlists = list
            UnifiedSongStore.synchronizeLegacy(list)
        } else if let data = defaults.data(forKey: key),
           let list = try? JSONDecoder().decode([LocalPlaylist].self, from: data) {
            playlists = list
            UnifiedSongStore.synchronizeLegacy(list)
            try? playlistFile.write(list)
        } else {
            playlists = []
        }
        if let data = defaults.data(forKey: importedSongsKey),
           let songs = try? JSONDecoder().decode([Song].self, from: data) {
            importedSongs = songs.filter { $0.source == .local }
        } else {
            importedSongs = []
        }
        rebuildImportedSongsIndex()
        repairLocalArtworksIfNeeded()
        cleanDuplicateImportedSongsAndPlaylists()
    }

    @discardableResult
    func createPlaylist(name: String) -> LocalPlaylist {
        let playlist = LocalPlaylist(name: name)
        playlists.append(playlist)
        return playlist
    }

    func deletePlaylist(id: UUID) {
        playlists.removeAll { $0.id == id }
    }

    func renamePlaylist(id: UUID, name: String) {
        guard let idx = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[idx].name = name
    }

    /// 调整本地歌单顺序，顺序会随歌单一起持久化。
    func movePlaylist(id: UUID, offset: Int) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + offset
        guard playlists.indices.contains(destination) else { return }
        var reordered = playlists
        reordered.swapAt(index, destination)
        playlists = reordered
    }

    /// 使用 List 的拖动结果更新顺序，显式重新赋值确保 @Published 与持久化都能触发。
    func movePlaylists(from offsets: IndexSet, to destination: Int) {
        var reordered = playlists
        reordered.move(fromOffsets: offsets, toOffset: destination)
        playlists = reordered
    }

    /// 添加歌曲到本地歌单（按 identityKey 去重）
    func addSong(_ song: Song, to id: UUID) {
        guard let idx = playlists.firstIndex(where: { $0.id == id }) else { return }
        guard !playlists[idx].songs.contains(where: { $0.identityKey == song.identityKey }) else { return }
        playlists[idx].songs.append(song)
    }

    @discardableResult
    func addSongs(_ songs: [Song], to id: UUID) -> Int {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return 0 }
        var seen = Set(playlists[index].songs.map(\.identityKey))
        let added = songs.filter { seen.insert($0.identityKey).inserted }
        if !added.isEmpty { playlists[index].songs.append(contentsOf: added) }
        return added.count
    }

    /// 设置混合歌单的播放来源偏好；不会删除或替换歌单中的原始来源记录。
    func setSourceStrategy(_ strategy: PlaylistSourceStrategy, for id: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].sourceStrategy = strategy
    }

    /// 根据歌单策略解析播放快照。没有严格匹配的替代来源时保留原歌曲，避免歌单消失。
    func playbackSongs(for id: UUID) -> [Song] {
        guard let playlist = playlists.first(where: { $0.id == id }) else { return [] }
        guard let preferred = playlist.sourceStrategy.preferredSource else { return playlist.songs }
        return playlist.songs.map { song in
            UnifiedSongStore.shared.alternateSongs(for: song, preferredSource: preferred).first ?? song
        }
    }

    func containsSong(_ song: Song?) -> Bool {
        guard let song else { return false }
        return playlists.contains { $0.songs.contains { $0.identityKey == song.identityKey } }
    }

    @discardableResult
    func addToDefaultFavorites(_ song: Song, name: String = "我的收藏歌单") -> String {
        let playlist = playlists.first(where: { $0.name == name }) ?? createPlaylist(name: name)
        let before = playlists.first(where: { $0.id == playlist.id })?.songs.count ?? 0
        addSong(song, to: playlist.id)
        let after = playlists.first(where: { $0.id == playlist.id })?.songs.count ?? before
        return after > before ? "已加入「\(playlist.name)」" : "已在「\(playlist.name)」中"
    }

    @discardableResult
    func syncSongs(_ songs: [Song], intoPlaylistNamed name: String = "三平台喜欢") -> Int {
        let target: LocalPlaylist
        if let existing = playlists.first(where: { $0.name == name }) {
            target = existing
        } else {
            target = createPlaylist(name: name)
        }
        return addSongs(songs, to: target.id)
    }

    static func normalizeSongText(_ text: String) -> String {
        text.lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: "（", with: "")
            .replacingOccurrences(of: "）", with: "")
            .replacingOccurrences(of: "&", with: "")
    }

    /// 跨平台曲目智能全维比对：兼容在线平台 ID、本地相对路径、扩展名自愈变更与归一化标题歌手
    static func isMatchingSong(_ a: Song, _ b: Song) -> Bool {
        if a.identityKey == b.identityKey { return true }

        if let relA = a.localRelativePath, let relB = b.localRelativePath {
            if relA == relB { return true }
            let baseA = ((relA as NSString).lastPathComponent as NSString).deletingPathExtension
            let baseB = ((relB as NSString).lastPathComponent as NSString).deletingPathExtension
            if !baseA.isEmpty && baseA == baseB { return true }
        }

        if let relA = a.localRelativePath {
            let baseA = ((relA as NSString).lastPathComponent as NSString).deletingPathExtension
            if !baseA.isEmpty && (b.identityKey.contains(baseA) || baseA.contains(b.identityKey) || baseA.contains("\(b.id)")) { return true }
        }
        if let relB = b.localRelativePath {
            let baseB = ((relB as NSString).lastPathComponent as NSString).deletingPathExtension
            if !baseB.isEmpty && (a.identityKey.contains(baseB) || baseB.contains(a.identityKey) || baseB.contains("\(a.id)")) { return true }
        }

        if a.id == b.id && a.id != 0 {
            if a.source == b.source { return true }
            if a.source == .local || b.source == .local { return true }
        }

        let normNameA = normalizeSongText(a.name)
        let normNameB = normalizeSongText(b.name)
        if !normNameA.isEmpty && normNameA == normNameB {
            if a.id == b.id && a.id != 0 { return true }
            let normArtA = normalizeSongText(a.artists)
            let normArtB = normalizeSongText(b.artists)
            if !normArtA.isEmpty && !normArtB.isEmpty {
                if normArtA == normArtB || normArtA.contains(normArtB) || normArtB.contains(normArtA) {
                    return true
                }
            }
        }
        return false
    }

    func localSongs(matching song: Song) -> [Song] {
        importedSongs.filter { Self.isMatchingSong($0, song) }
    }

    func removeSong(playlistID: UUID, song: Song) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        let before = playlists[idx].songs.count
        playlists[idx].songs.removeAll { Self.isMatchingSong($0, song) }
        if playlists[idx].songs.count != before {
            save()
        }
    }

    func removeSong(playlistID: UUID, songIdentity: String) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        let targetSong = playlists[idx].songs.first(where: { $0.identityKey == songIdentity })
        let before = playlists[idx].songs.count
        playlists[idx].songs.removeAll { song in
            if song.identityKey == songIdentity { return true }
            if let targetSong, Self.isMatchingSong(song, targetSong) { return true }
            if let rel = song.localRelativePath {
                let base = ((rel as NSString).lastPathComponent as NSString).deletingPathExtension
                if !base.isEmpty && (songIdentity.contains(base) || base.contains(songIdentity)) { return true }
            }
            return false
        }
        if playlists[idx].songs.count != before {
            save()
        }
    }

    @discardableResult
    func removeSongFromAllPlaylists(_ song: Song) -> Int {
        var removed = 0
        var updated = playlists
        var changed = false
        for index in updated.indices {
            let before = updated[index].songs.count
            updated[index].songs.removeAll { Self.isMatchingSong($0, song) }
            let diff = before - updated[index].songs.count
            if diff > 0 {
                removed += diff
                changed = true
            }
        }
        if changed {
            playlists = updated
            save()
        }
        return removed
    }

    /// 编辑态拖动重排（仅搜索为空时调用，见详情页）。
    func reorderSongs(playlistID: UUID, from offsets: IndexSet, to destination: Int) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[idx].songs.move(fromOffsets: offsets, toOffset: destination)
    }

    /// 批量删歌（跨平台匹配，见 isMatchingSong）。
    func removeSongs(playlistID: UUID, songs: [Song]) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        let before = playlists[idx].songs.count
        playlists[idx].songs.removeAll { song in songs.contains { Self.isMatchingSong($0, song) } }
        if playlists[idx].songs.count != before { save() }
    }

    func setCoverURL(_ url: URL?, for playlistID: UUID) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[idx].coverURL = url
    }

    func setDescription(_ text: String?, for playlistID: UUID) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        playlists[idx].descriptionText = (trimmed?.isEmpty == true) ? nil : trimmed
    }

    /// 一键去重：按 identityKey 保留首次出现，返回删掉的条数。
    @discardableResult
    func deduplicatePlaylist(id: UUID) -> Int {
        guard let idx = playlists.firstIndex(where: { $0.id == id }) else { return 0 }
        var seen = Set<String>()
        let unique = playlists[idx].songs.filter { seen.insert($0.identityKey).inserted }
        let removed = playlists[idx].songs.count - unique.count
        if removed > 0 {
            playlists[idx].songs = unique
            save()
        }
        return removed
    }

    /// 清理本地失效条目：本地文件已不存在的歌曲（平台歌曲不受影响）。
    @discardableResult
    func removeDeadLocalSongs(id: UUID) -> Int {
        guard let idx = playlists.firstIndex(where: { $0.id == id }) else { return 0 }
        let before = playlists[idx].songs.count
        playlists[idx].songs.removeAll { song in
            guard let rel = song.localRelativePath else { return false }
            guard let url = try? ManagedAudioPath.resolve(rel) else { return true }
            return !FileManager.default.fileExists(atPath: url.path)
        }
        let removed = before - playlists[idx].songs.count
        if removed > 0 { save() }
        return removed
    }

    func addImportedSongs(_ songs: [Song]) {
        for song in songs {
            addOrUpdateImportedSong(song)
        }
    }

    func localSong(for identityKey: String) -> Song? {
        if let exact = importedSongsIndex[identityKey] ?? importedSongs.first(where: { $0.identityKey == identityKey }) {
            return exact
        }
        return importedSongs.first { song in
            if let rel = song.localRelativePath {
                let base = ((rel as NSString).lastPathComponent as NSString).deletingPathExtension
                if !base.isEmpty && identityKey.contains(base) { return true }
            }
            return false
        }
    }

    /// 下载或导入本地歌曲时无重复入库：若已存在同名同歌手或同实体曲目，自动就地更新并回收旧文件
    func addOrUpdateImportedSong(_ song: Song) {
        guard song.source == .local else { return }
        if let index = importedSongs.firstIndex(where: { Self.isMatchingSong($0, song) }) {
            let oldRel = importedSongs[index].localRelativePath
            if let oldRel, oldRel != song.localRelativePath {
                try? LocalAudioFileManager.shared.deleteFileAndSupport(relativePath: oldRel)
            }
            importedSongs[index] = song
        } else {
            importedSongs.append(song)
        }

        var updatedPlaylists = playlists
        var playlistChanged = false
        for pIdx in updatedPlaylists.indices {
            for sIdx in updatedPlaylists[pIdx].songs.indices where Self.isMatchingSong(updatedPlaylists[pIdx].songs[sIdx], song) {
                updatedPlaylists[pIdx].songs[sIdx] = song
                playlistChanged = true
            }
        }
        if playlistChanged {
            playlists = updatedPlaylists
            save()
        }
        saveImportedSongs()
    }

    @discardableResult
    func addSongToNamedPlaylist(_ song: Song, name: String = "已下载歌曲") -> Bool {
        addOrUpdateSongInNamedPlaylist(song, name: name)
    }

    @discardableResult
    func addOrUpdateSongInNamedPlaylist(_ song: Song, name: String = "已下载歌曲") -> Bool {
        let target: LocalPlaylist
        if let existing = playlists.first(where: { $0.name == name }) {
            target = existing
        } else {
            target = createPlaylist(name: name)
        }
        guard let idx = playlists.firstIndex(where: { $0.id == target.id }) else { return false }
        if let existingSongIdx = playlists[idx].songs.firstIndex(where: { Self.isMatchingSong($0, song) }) {
            playlists[idx].songs[existingSongIdx] = song
            save()
            return true
        } else {
            playlists[idx].songs.append(song)
            save()
            return true
        }
    }

    @discardableResult
    func updateImportedSong(_ song: Song) -> Bool {
        guard song.source == .local,
              let index = importedSongs.firstIndex(where: { Self.isMatchingSong($0, song) }) else {
            return false
        }

        importedSongs[index] = song

        var updatedPlaylists = playlists
        var playlistChanged = false
        for playlistIndex in updatedPlaylists.indices {
            for songIndex in updatedPlaylists[playlistIndex].songs.indices
            where Self.isMatchingSong(updatedPlaylists[playlistIndex].songs[songIndex], song) {
                updatedPlaylists[playlistIndex].songs[songIndex] = song
                playlistChanged = true
            }
        }
        if playlistChanged {
            playlists = updatedPlaylists
        }

        saveImportedSongs()
        if playlistChanged { save() }

        return true
    }

    /// 批量更新本地离线歌曲元数据（单次重构索引并落盘，杜绝循环更新时的重复磁盘 I/O）
    @discardableResult
    func updateImportedSongs(_ songs: [Song]) -> Int {
        guard !songs.isEmpty else { return 0 }
        var updatedCount = 0
        var newImported = importedSongs
        for song in songs {
            if let idx = newImported.firstIndex(where: { Self.isMatchingSong($0, song) }) {
                newImported[idx] = song
                updatedCount += 1
            }
        }
        guard updatedCount > 0 else { return 0 }
        importedSongs = newImported

        var updatedPlaylists = playlists
        var playlistChanged = false
        for playlistIndex in updatedPlaylists.indices {
            for songIndex in updatedPlaylists[playlistIndex].songs.indices {
                let curr = updatedPlaylists[playlistIndex].songs[songIndex]
                if let matched = songs.first(where: { Self.isMatchingSong($0, curr) }) {
                    updatedPlaylists[playlistIndex].songs[songIndex] = matched
                    playlistChanged = true
                }
            }
        }
        if playlistChanged {
            playlists = updatedPlaylists
            save()
        }
        return updatedCount
    }

    @discardableResult
    func removeAllMatchingImportedSongs(matching song: Song) -> Int {
        let before = importedSongs.count
        let matches = importedSongs.filter { Self.isMatchingSong($0, song) }
        for match in matches {
            if let rel = match.localRelativePath {
                try? LocalAudioFileManager.shared.deleteFileAndSupport(relativePath: rel)
            }
        }
        importedSongs.removeAll { Self.isMatchingSong($0, song) }
        let diff = before - importedSongs.count
        if diff > 0 {
            saveImportedSongs()
        }
        return diff
    }

    @discardableResult
    func removeImportedSong(_ song: Song) -> Bool {
        if let relativePath = song.localRelativePath {
            try? LocalAudioFileManager.shared.deleteFileAndSupport(relativePath: relativePath)
        }
        _ = removeAllMatchingImportedSongs(matching: song)
        _ = removeSongFromAllPlaylists(song)
        saveImportedSongs()
        save()
        return true
    }

    @discardableResult
    func removeImportedSongs(_ songs: [Song]) -> Int {
        var count = 0
        for song in songs {
            if removeImportedSong(song) {
                count += 1
            }
        }
        return count
    }

    /// 清理离线库中的冗余重复条目与死链，确保一个音频实体仅保留一份唯一记录
    func cleanDuplicateImportedSongsAndPlaylists() {
        var uniqueSongs: [Song] = []
        var seenKeys = Set<String>()
        var seenNormalized = Set<String>()
        var dirty = false

        for song in importedSongs {
            let normKey = "\(Self.normalizeSongText(song.name))|\(Self.normalizeSongText(song.artists))"
            if seenKeys.contains(song.identityKey) || seenNormalized.contains(normKey) {
                if let rel = song.localRelativePath {
                    try? LocalAudioFileManager.shared.deleteFileAndSupport(relativePath: rel)
                }
                dirty = true
            } else {
                if let rel = song.localRelativePath,
                   let url = try? ManagedAudioPath.resolve(rel),
                   FileManager.default.fileExists(atPath: url.path) {
                    seenKeys.insert(song.identityKey)
                    seenNormalized.insert(normKey)
                    uniqueSongs.append(song)
                } else if let rel = song.localRelativePath, rel.hasSuffix(".tmp") {
                    let base = (rel as NSString).deletingPathExtension
                    var found = false
                    for ext in ["flac", "mp3", "m4a", "wav", "ogg"] {
                        let cand = base + "." + ext
                        if let candURL = try? ManagedAudioPath.resolve(cand), FileManager.default.fileExists(atPath: candURL.path) {
                            let fixed = song.withLocalRelativePath(cand)
                            seenKeys.insert(fixed.identityKey)
                            seenNormalized.insert(normKey)
                            uniqueSongs.append(fixed)
                            found = true
                            dirty = true
                            break
                        }
                    }
                    if !found {
                        dirty = true
                    }
                } else {
                    dirty = true
                }
            }
        }

        if dirty {
            importedSongs = uniqueSongs
            saveImportedSongs()
            ATMusicLogger.shared.log("🧹 已清理离线库中的冗余重复曲目与死链，当前有效离线曲目 \(uniqueSongs.count) 首", level: .info)
        }

        var playlistsChanged = false
        var nextPlaylists = playlists
        for pIdx in nextPlaylists.indices {
            var pSeen = Set<String>()
            var pSeenNormalized = Set<String>()
            var pUnique: [Song] = []
            let isDownloadedList = nextPlaylists[pIdx].name == "已下载歌曲"
            for s in nextPlaylists[pIdx].songs {
                let key = s.identityKey
                let normKey = "\(Self.normalizeSongText(s.name))|\(Self.normalizeSongText(s.artists))"
                if isDownloadedList {
                    if pSeen.contains(key) || pSeenNormalized.contains(normKey) {
                        playlistsChanged = true
                        continue
                    }
                    if let rel = s.localRelativePath,
                       let url = try? ManagedAudioPath.resolve(rel),
                       FileManager.default.fileExists(atPath: url.path) {
                        pSeen.insert(key)
                        pSeenNormalized.insert(normKey)
                        pUnique.append(s)
                    } else {
                        playlistsChanged = true
                    }
                } else {
                    if !pSeen.contains(key) {
                        pSeen.insert(key)
                        pUnique.append(s)
                    } else {
                        playlistsChanged = true
                    }
                }
            }
            if nextPlaylists[pIdx].songs.count != pUnique.count {
                nextPlaylists[pIdx].songs = pUnique
                playlistsChanged = true
            }
        }
        if playlistsChanged {
            playlists = nextPlaylists
            save()
        }
    }

    /// 自愈修复本地离线歌曲路径中的 .tmp 扩展名，并同步校准歌单与执行智能去重
    func repairTmpSongPaths() {
        var updated = false
        var nextSongs = importedSongs
        for i in 0..<nextSongs.count {
            if let rel = nextSongs[i].localRelativePath, rel.hasSuffix(".tmp") {
                if let file = LocalAudioFileManager.shared.file(forSongId: nextSongs[i].identityKey) {
                    nextSongs[i] = nextSongs[i].withLocalRelativePath(file.relativePath)
                    updated = true
                } else {
                    let base = (rel as NSString).deletingPathExtension
                    for ext in ["flac", "mp3", "m4a", "wav", "ogg"] {
                        let candidate = base + "." + ext
                        if let url = try? ManagedAudioPath.resolve(candidate), FileManager.default.fileExists(atPath: url.path) {
                            nextSongs[i] = nextSongs[i].withLocalRelativePath(candidate)
                            updated = true
                            break
                        }
                    }
                }
            }
        }
        if updated {
            importedSongs = nextSongs
            saveImportedSongs()
            ATMusicLogger.shared.log("🛠️ 本地离线库歌曲路径已自愈校准完成", level: .info)
        }

        var playlistsChanged = false
        var nextPlaylists = playlists
        for pIdx in nextPlaylists.indices {
            for sIdx in nextPlaylists[pIdx].songs.indices {
                if let rel = nextPlaylists[pIdx].songs[sIdx].localRelativePath, rel.hasSuffix(".tmp") {
                    let base = (rel as NSString).deletingPathExtension
                    for ext in ["flac", "mp3", "m4a", "wav", "ogg"] {
                        let candidate = base + "." + ext
                        if let url = try? ManagedAudioPath.resolve(candidate), FileManager.default.fileExists(atPath: url.path) {
                            nextPlaylists[pIdx].songs[sIdx] = nextPlaylists[pIdx].songs[sIdx].withLocalRelativePath(candidate)
                            playlistsChanged = true
                            break
                        }
                    }
                }
            }
        }
        if playlistsChanged {
            playlists = nextPlaylists
            save()
            ATMusicLogger.shared.log("🛠️ 本地歌单中的离线歌曲路径已同步自愈校准", level: .info)
        }

        cleanDuplicateImportedSongsAndPlaylists()
    }

    private func save() {
        do {
            try playlistFile.write(playlists)
        } catch {
            // 文件写坏也不丢数据：回退旧键，下次启动仍能读回。
            if let data = try? JSONEncoder().encode(playlists) {
                defaults.set(data, forKey: key)
            }
            ATMusicLogger.shared.log("本地歌单文件写入失败，已回退到旧存储：\(error.localizedDescription)", level: .error)
        }
        UnifiedSongStore.synchronizeLegacy(playlists)
    }

    private func saveImportedSongs() {
        if let data = try? JSONEncoder().encode(importedSongs) {
            defaults.set(data, forKey: importedSongsKey)
        }
    }

    /// 跨设备云端同步：双向合并本地自建歌单（同名或同 ID 则合并曲目，全新歌单则直接追加）
    func mergePlaylists(_ remotePlaylists: [LocalPlaylist]) {
        var updated = playlists
        for remote in remotePlaylists {
            if let index = updated.firstIndex(where: { $0.id == remote.id || $0.name == remote.name }) {
                var existingKeys = Set(updated[index].songs.map { $0.identityKey })
                for s in remote.songs {
                    if !existingKeys.contains(s.identityKey) {
                        updated[index].songs.append(s)
                        existingKeys.insert(s.identityKey)
                    }
                }
            } else {
                updated.append(remote)
            }
        }
        playlists = updated
        save()
    }

    // MARK: - 历史离线歌曲封面自愈与补齐

    func repairLocalArtworksIfNeeded() {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let songs = await MainActor.run { self.importedSongs }
            var didUpdate = false
            var updatedSongs = songs

            for index in updatedSongs.indices {
                let song = updatedSongs[index]
                guard song.source == .local, let relPath = song.localRelativePath else { continue }
                let recId = ((relPath as NSString).lastPathComponent as NSString).deletingPathExtension
                let artworkRelative = "ATMusicAudio/Artwork/\(recId).jpg"

                // 如果本地 Artwork 文件已存在，跳过
                if let artURL = try? ManagedAudioPath.resolve(artworkRelative),
                   FileManager.default.fileExists(atPath: artURL.path) {
                    continue
                }

                var resolvedData: Data? = nil

                // 1. 从本地音频文件提取内嵌封面
                if let audioURL = try? ManagedAudioPath.resolve(relPath),
                   FileManager.default.fileExists(atPath: audioURL.path) {
                    let asset = AVURLAsset(url: audioURL)
                    if let artworkData = asset.commonMetadata.first(where: { $0.commonKey == .commonKeyArtwork })?.dataValue, !artworkData.isEmpty {
                        resolvedData = artworkData
                    }
                }

                // 2. 从原封面直链尝试拉取
                if resolvedData == nil, let coverURL = song.rawCoverURL, !coverURL.isFileURL {
                    var req = URLRequest(url: coverURL)
                    req.timeoutInterval = 10
                    req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
                    if let (data, resp) = try? await URLSession.shared.data(for: req),
                       let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty {
                        resolvedData = data
                    }
                }

                // 3. 落盘并更新歌曲
                if let resolvedData, !resolvedData.isEmpty {
                    if let localCoverURL = try? LocalAudioFileManager.shared.writeSupportData(resolvedData, relativePath: artworkRelative) {
                        if let img = UIImage(data: resolvedData) {
                            ATMusicRemoteCoverCache.store(img, for: localCoverURL)
                        }
                        let newSong = Song(
                            id: song.id,
                            name: song.name,
                            artists: song.artists,
                            album: song.album,
                            coverURL: localCoverURL,
                            duration: song.duration,
                            source: .local,
                            localRelativePath: song.localRelativePath,
                            albumArtist: song.albumArtist,
                            genre: song.genre,
                            year: song.year,
                            comment: song.comment,
                            discNumber: song.discNumber,
                            trackNumber: song.trackNumber,
                            fee: song.fee
                        )
                        updatedSongs[index] = newSong
                        didUpdate = true
                    }
                }
            }

            if didUpdate {
                await MainActor.run {
                    self.importedSongs = updatedSongs
                    self.saveImportedSongs()
                    ATMusicLogger.shared.log("🖼️ 已自动修复并补齐历史离线歌曲封面缓存", level: .info)
                }
            }
        }
    }
}

