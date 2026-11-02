import Foundation

/// 要写进音频文件本体的标签集合。
///
/// 两处使用：
/// 1. 归档上传 NAS 前写进临时副本（`embed(tags:into:)`，产物是副本，原文件不动）；
/// 2. 本地曲库改元数据 / 封面 / 歌词后直接改写原文件（`writeInPlace(tags:fileURL:)`），
///    这样导出、分享、拷进别的播放器都带着新标签。
struct AudioTagSet {
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var genre: String?
    var year: String?
    var comment: String?
    var track: Int = 0
    var disc: Int = 0
    var coverData: Data?
    var trackTotal: Int = 0
    var discTotal: Int = 0
    var lyrics: String?

    /// 是否真的带了可写内容，用于跳过无意义的整文件重写。
    var hasAnyContent: Bool {
        if track > 0 || disc > 0 { return true }
        if let coverData, !coverData.isEmpty { return true }
        if let lyrics, !lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return [title, artist, album, albumArtist, genre, year, comment]
            .contains { ($0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
    }
}

/// 音频容器类型（按文件头魔数判断，不迷信扩展名）。
enum AudioTagContainer: String {
    case mp3
    case flac
    case mp4
    case wav
    case aiff
    case ogg
    case ape
    case dsf
    case unknown

    var displayName: String {
        switch self {
        case .mp3: return "MP3"
        case .flac: return "FLAC"
        case .mp4: return "M4A"
        case .wav: return "WAV"
        case .aiff: return "AIFF"
        case .ogg: return "OGG"
        case .ape: return "APE"
        case .dsf: return "DSD"
        case .unknown: return "未知容器"
        }
    }

    /// 支持原地写标签的容器。
    var supportsInPlaceTagWrite: Bool {
        switch self {
        case .mp3, .flac, .mp4, .wav, .aiff: return true
        case .ogg, .ape, .dsf, .unknown: return false
        }
    }
}

enum AudioTagWriteError: LocalizedError {
    case unsupportedContainer(String)
    case unreadable(String)
    case damaged(String)
    case insufficientSpace
    case noAudioFile

    var errorDescription: String? {
        switch self {
        case .unsupportedContainer(let name):
            return "\(name) 容器暂不支持内嵌标签写入（现支持 MP3 / FLAC / M4A / ALAC / WAV / AIFF）"
        case .unreadable(let reason):
            return "读写音频文件失败：\(reason)"
        case .damaged(let reason):
            return "音频文件结构异常：\(reason)"
        case .insufficientSpace:
            return "设备可用空间不足，无法写回音频文件"
        case .noAudioFile:
            return "找不到这首歌对应的本地音频文件"
        }
    }
}

struct AudioTagWriteReport {
    let container: String
    let byteCount: Int
    let hasCover: Bool
    let hasLyrics: Bool

    var summary: String {
        var parts: [String] = [container]
        if hasCover { parts.append("含封面") }
        if hasLyrics { parts.append("含歌词") }
        return parts.joined(separator: " · ")
    }
}

/// 把标签直接写进音频文件本体：
/// MP3 → ID3v2.3（+ ID3v1 尾标兜底老车机）、FLAC → Vorbis Comment + PICTURE、
/// M4A/MP4 → moov/udta/meta/ilst、WAV/AIFF → 内嵌 ID3 chunk。
///
/// 所有写入都是「整份重建 → 校验 → 原子替换」：中途失败原文件保持不动，
/// 不会出现写坏一半的音频。
enum AudioTagEmbedder {

    // MARK: - 容器嗅探

    static func container(of data: Data) -> AudioTagContainer {
        let bytes = [UInt8](data.prefix(32))
        func text(_ start: Int, _ length: Int) -> String {
            guard start >= 0, start + length <= bytes.count else { return "" }
            return String(decoding: bytes[start..<(start + length)], as: UTF8.self)
        }
        if text(0, 3) == "ID3" { return .mp3 }
        if text(0, 4) == "fLaC" { return .flac }
        if text(0, 4) == "OggS" { return .ogg }
        if text(0, 4) == "MAC " { return .ape }
        if text(0, 4) == "DSD " { return .dsf }
        if text(4, 4) == "ftyp" || text(4, 4) == "moov" || text(4, 4) == "wide" || text(0, 4) == "moov" { return .mp4 }
        if text(0, 4) == "RIFF" {
            if text(8, 4) == "WAVE" { return .wav }
            return .unknown
        }
        if text(0, 4) == "FORM" {
            let form = text(8, 4)
            if form == "AIFF" || form == "AIFC" { return .aiff }
            return .unknown
        }
        if bytes.count >= 2, bytes[0] == 0xFF, (bytes[1] & 0xE0) == 0xE0 { return .mp3 }
        return .unknown
    }

    static func container(for fileURL: URL) -> AudioTagContainer {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return .unknown }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 32)) ?? Data()
        return container(of: head)
    }

    private static func container(matchingExtension ext: String) -> AudioTagContainer {
        switch ext.lowercased() {
        case "mp3", "mp2", "mpga": return .mp3
        case "flac": return .flac
        case "m4a", "mp4", "alac", "m4b", "aac": return .mp4
        case "wav", "wave": return .wav
        case "aiff", "aif", "aifc": return .aiff
        case "ogg", "oga", "opus": return .ogg
        case "ape": return .ape
        case "dsf", "dff": return .dsf
        default: return .unknown
        }
    }

    static func supportsInPlaceWrite(fileURL: URL) -> Bool {
        let kind = container(for: fileURL)
        if kind == .unknown {
            return container(matchingExtension: fileURL.pathExtension).supportsInPlaceTagWrite
        }
        return kind.supportsInPlaceTagWrite
    }

    // MARK: - 原地写回

    @discardableResult
    static func writeInPlace(tags: AudioTagSet, fileURL: URL) throws -> AudioTagWriteReport {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        } catch {
            throw AudioTagWriteError.unreadable(error.localizedDescription)
        }
        guard data.count > 128 else { throw AudioTagWriteError.damaged("文件内容过小") }

        var kind = container(of: data)
        if kind == .unknown {
            kind = container(matchingExtension: fileURL.pathExtension)
        }
        guard kind.supportsInPlaceTagWrite else {
            throw AudioTagWriteError.unsupportedContainer(kind.displayName)
        }

        let rebuilt: Data
        switch kind {
        case .mp3:
            rebuilt = try ID3Writer.write(tags: tags, data: data)
        case .flac:
            rebuilt = try FLACWriter.write(tags: tags, data: data)
        case .mp4:
            rebuilt = try MP4TagWriter.write(tags: tags, data: data)
        case .wav:
            rebuilt = try RIFFTagWriter.write(tags: tags, data: data, isAIFF: false)
        case .aiff:
            rebuilt = try RIFFTagWriter.write(tags: tags, data: data, isAIFF: true)
        default:
            throw AudioTagWriteError.unsupportedContainer(kind.displayName)
        }
        guard rebuilt.count > 128 else { throw AudioTagWriteError.damaged("写入结果异常") }

        if let capacity = try? fileURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage,
           Int64(rebuilt.count) > capacity {
            throw AudioTagWriteError.insufficientSpace
        }

        do {
            try rebuilt.write(to: fileURL, options: .atomic)
        } catch {
            throw AudioTagWriteError.unreadable(error.localizedDescription)
        }
        return AudioTagWriteReport(
            container: kind.displayName,
            byteCount: rebuilt.count,
            hasCover: (tags.coverData?.isEmpty == false),
            hasLyrics: (tags.lyrics?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        )
    }

    // MARK: - 归档上传用：写到临时副本

    /// 上传 NAS 前调用：产物是临时目录里的副本，原文件不动；失败/格式不支持返回 nil。
    static func embed(tags: AudioTagSet, into sourceURL: URL) -> URL? {
        guard let data = try? Data(contentsOf: sourceURL, options: [.mappedIfSafe]), !data.isEmpty else { return nil }
        var kind = container(of: data)
        if kind == .unknown {
            kind = container(matchingExtension: sourceURL.pathExtension)
        }
        let rebuilt: Data?
        switch kind {
        case .mp3: rebuilt = try? ID3Writer.write(tags: tags, data: data)
        case .flac: rebuilt = try? FLACWriter.write(tags: tags, data: data)
        case .mp4: rebuilt = try? MP4TagWriter.write(tags: tags, data: data)
        case .wav: rebuilt = try? RIFFTagWriter.write(tags: tags, data: data, isAIFF: false)
        case .aiff: rebuilt = try? RIFFTagWriter.write(tags: tags, data: data, isAIFF: true)
        default: rebuilt = nil
        }
        guard let rebuilt else { return nil }
        var ext = sourceURL.pathExtension.lowercased()
        if ext.isEmpty || ext == "tmp" {
            switch kind {
            case .flac: ext = "flac"
            case .mp4: ext = "m4a"
            case .wav: ext = "wav"
            case .aiff: ext = "aiff"
            default: ext = "mp3"
            }
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("atm-archive-\(UUID().uuidString).\(ext)")
        do {
            try rebuilt.write(to: dest, options: .atomic)
            return dest
        } catch {
            return nil
        }
    }

    static func firstFourDigitYear(_ value: String) -> String? {
        var run = ""
        for ch in value {
            if ch.isNumber {
                run.append(ch)
                if run.count == 4 { return run }
            } else {
                run = ""
            }
        }
        return nil
    }

    static func isPNG(_ data: Data) -> Bool {
        guard data.count > 8 else { return false }
        return data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E && data[3] == 0x47
    }
}

// MARK: - MP3：ID3v2.3 + ID3v1

enum ID3Writer {
    /// 每次都由我们重新生成的帧（旧值丢弃）。
    private static let alwaysManagedFrames: Set<String> = [
        "TIT2", "TPE1", "TPE2", "TALB", "TCON", "TYER", "TDRC", "TRCK", "TPOS"
    ]

    /// 条件管理的帧：只有当新值确实存在时才覆盖，避免把源文件里的原注释/内嵌歌词白白删掉。
    private static func managedFrames(for tags: AudioTagSet) -> Set<String> {
        var ids = alwaysManagedFrames
        if tags.comment != nil { ids.insert("COMM") }
        if tags.lyrics != nil { ids.insert("USLT") }
        if tags.coverData != nil { ids.insert("APIC") }
        return ids
    }

    static func write(tags: AudioTagSet, data: Data) throws -> Data {
        let bytes = [UInt8](data)
        var audioStart = 0
        var preserved: [(id: String, body: Data)] = []

        if bytes.count >= 10, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 {
            let major = bytes[3]
            let flags = bytes[5]
            let unsynchronised = (flags & 0x80) != 0
            var tagSize = 0
            for i in 6..<10 { tagSize = (tagSize << 7) | Int(bytes[i] & 0x7F) }
            audioStart = 10 + tagSize + ((flags & 0x10) != 0 ? 10 : 0)
            if !unsynchronised, major == 3 || major == 4 {
                let managed = managedFrames(for: tags)
                var pos = 10
                let tagEnd = min(10 + tagSize, bytes.count)
                while pos + 10 <= tagEnd {
                    let fid = String(decoding: bytes[pos..<(pos + 4)], as: UTF8.self)
                    guard fid.count == 4, fid.allSatisfy({ $0.isLetter || $0.isNumber }) else { break }
                    let frameSize: Int
                    if major == 4 {
                        var value = 0
                        for i in 0..<4 { value = (value << 7) | Int(bytes[pos + 4 + i] & 0x7F) }
                        frameSize = value
                    } else {
                        frameSize = Int(bytes[pos + 4]) << 24 | Int(bytes[pos + 5]) << 16
                            | Int(bytes[pos + 6]) << 8 | Int(bytes[pos + 7])
                    }
                    guard frameSize > 0, pos + 10 + frameSize <= bytes.count else { break }
                    if !managed.contains(fid) {
                        preserved.append((fid, Data(bytes[(pos + 10)..<(pos + 10 + frameSize)])))
                    }
                    pos += 10 + frameSize
                }
            }
        }
        guard audioStart < bytes.count else { throw AudioTagWriteError.damaged("ID3 标签长度超出文件") }

        // 尾部 ID3v1：保留原流派字节后重写，方便老设备/车机也能读到新标题。
        var payload = Array(bytes[audioStart...])
        var genreByte: UInt8 = 0xFF
        if payload.count >= 128,
           payload[payload.count - 128] == 0x54,
           payload[payload.count - 127] == 0x41,
           payload[payload.count - 126] == 0x47 {
            genreByte = payload[payload.count - 1]
            payload.removeLast(128)
        }
        guard !payload.isEmpty else { throw AudioTagWriteError.damaged("音频数据为空") }

        var out = [UInt8](tagBytes(tags: tags, preservedFrames: preserved))
        out.append(contentsOf: payload)
        out.append(contentsOf: id3v1Block(tags: tags, genreByte: genreByte))
        return Data(out)
    }

    /// 只生成 ID3v2.3 标签块（WAV / AIFF 内嵌 ID3 chunk 复用）。
    static func tagBytes(tags: AudioTagSet, preservedFrames: [(id: String, body: Data)] = []) -> Data {
        var frames: [UInt8] = []

        func appendFrame(id: String, body: [UInt8]) {
            guard let idBytes = id.data(using: .ascii), idBytes.count == 4,
                  body.count < Int(UInt32.max) else { return }
            frames.append(contentsOf: idBytes)
            let size = UInt32(body.count).bigEndian
            frames.append(contentsOf: withUnsafeBytes(of: size) { Array($0) })
            frames.append(contentsOf: [0x00, 0x00])
            frames.append(contentsOf: body)
        }
        func textBody(_ value: String) -> [UInt8] {
            var body: [UInt8] = [0x01, 0xFF, 0xFE]  // UTF-16 with BOM
            body.append(contentsOf: value.data(using: .utf16LittleEndian) ?? Data())
            return body
        }
        func textFrame(_ id: String, _ value: String?) {
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            appendFrame(id: id, body: textBody(value))
        }

        textFrame("TIT2", tags.title)
        textFrame("TPE1", tags.artist)
        textFrame("TALB", tags.album)
        textFrame("TPE2", tags.albumArtist)
        textFrame("TCON", tags.genre)
        if let year = tags.year, let fourDigit = AudioTagEmbedder.firstFourDigitYear(year) {
            textFrame("TYER", fourDigit)
        }
        if tags.track > 0 {
            textFrame("TRCK", tags.trackTotal > 0 ? "\(tags.track)/\(tags.trackTotal)" : "\(tags.track)")
        }
        if tags.disc > 0 {
            textFrame("TPOS", tags.discTotal > 0 ? "\(tags.disc)/\(tags.discTotal)" : "\(tags.disc)")
        }
        if let comment = tags.comment, !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // COMM：编码 + 语言 eng + 描述符(UTF-16 空串) + 正文
            var body: [UInt8] = [0x01]
            body.append(contentsOf: Array("eng".utf8))
            body.append(contentsOf: [0xFF, 0xFE, 0x00, 0x00])
            body.append(contentsOf: [0xFF, 0xFE])
            body.append(contentsOf: comment.data(using: .utf16LittleEndian) ?? Data())
            appendFrame(id: "COMM", body: body)
        }
        if let lyrics = tags.lyrics, !lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // USLT：与 COMM 同构，正文是整段 LRC
            var body: [UInt8] = [0x01]
            body.append(contentsOf: Array("eng".utf8))
            body.append(contentsOf: [0xFF, 0xFE, 0x00, 0x00])
            body.append(contentsOf: [0xFF, 0xFE])
            body.append(contentsOf: lyrics.data(using: .utf16LittleEndian) ?? Data())
            appendFrame(id: "USLT", body: body)
        }
        if let cover = tags.coverData, !cover.isEmpty {
            // APIC：编码 0 + mime + 0 + 图片类型 3(封面) + 描述 0 + 二进制
            var body: [UInt8] = [0x00]
            body.append(contentsOf: Array((AudioTagEmbedder.isPNG(cover) ? "image/png" : "image/jpeg").utf8))
            body.append(contentsOf: [0x00, 0x03, 0x00])
            body.append(contentsOf: cover)
            appendFrame(id: "APIC", body: body)
        }
        for old in preservedFrames {
            appendFrame(id: old.id, body: [UInt8](old.body))
        }
        frames.append(contentsOf: [UInt8](repeating: 0, count: 2048))  // padding，方便下次原地再写

        var out: [UInt8] = Array("ID3".utf8)
        out.append(contentsOf: [0x03, 0x00, 0x00])
        var remaining = frames.count
        var syncsafe = [UInt8](repeating: 0, count: 4)
        for i in stride(from: 3, through: 0, by: -1) {
            syncsafe[i] = UInt8(remaining & 0x7F)
            remaining >>= 7
        }
        out.append(contentsOf: syncsafe)
        out.append(contentsOf: frames)
        return Data(out)
    }

    private static func id3v1Block(tags: AudioTagSet, genreByte: UInt8) -> [UInt8] {
        func field(_ value: String?, _ length: Int) -> [UInt8] {
            var data = (value ?? "").data(using: .isoLatin1) ?? Data()
            if data.count > length { data = Data(data.prefix(length)) }
            if data.count < length { data.append(Data(repeating: 0, count: length - data.count)) }
            return [UInt8](data)
        }
        var out: [UInt8] = Array("TAG".utf8)
        out.append(contentsOf: field(tags.title, 30))
        out.append(contentsOf: field(tags.artist, 30))
        out.append(contentsOf: field(tags.album, 30))
        out.append(contentsOf: field(tags.year.flatMap { AudioTagEmbedder.firstFourDigitYear($0) }, 4))
        if tags.track > 0, tags.track < 256 {
            out.append(contentsOf: field(tags.comment, 28))
            out.append(0x00)
            out.append(UInt8(tags.track))
        } else {
            out.append(contentsOf: field(tags.comment, 30))
        }
        out.append(genreByte)
        return out
    }
}

// MARK: - FLAC：Vorbis Comment + PICTURE

enum FLACWriter {
    private static let alwaysManagedKeys: Set<String> = [
        "TITLE", "ARTIST", "ALBUM", "ALBUMARTIST", "GENRE", "DATE",
        "TRACKNUMBER", "DISCNUMBER", "TRACKTOTAL", "DISCTOTAL", "TOTALTRACKS", "TOTALDISCS"
    ]

    private static func managedKeys(for tags: AudioTagSet) -> Set<String> {
        var keys = alwaysManagedKeys
        if tags.comment != nil { keys.insert("COMMENT") }
        if tags.lyrics != nil { keys.insert("LYRICS") }
        return keys
    }

    static func write(tags: AudioTagSet, data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 8, bytes[0] == 0x66, bytes[1] == 0x4C, bytes[2] == 0x61, bytes[3] == 0x43 else {
            throw AudioTagWriteError.damaged("不是有效的 FLAC 文件")
        }

        struct Block {
            let type: UInt8
            let payload: [UInt8]
        }
        var blocks: [Block] = []
        var pos = 4
        var audioStart: Int?
        while pos + 4 <= bytes.count {
            let head = bytes[pos]
            let isLast = (head & 0x80) != 0
            let type = head & 0x7F
            let length = Int(bytes[pos + 1]) << 16 | Int(bytes[pos + 2]) << 8 | Int(bytes[pos + 3])
            guard pos + 4 + length <= bytes.count else {
                throw AudioTagWriteError.damaged("FLAC 元数据块长度越界")
            }
            blocks.append(Block(type: type, payload: Array(bytes[(pos + 4)..<(pos + 4 + length)])))
            pos += 4 + length
            if isLast {
                audioStart = pos
                break
            }
        }
        guard let audioStart, let streamInfo = blocks.first, streamInfo.type == 0 else {
            throw AudioTagWriteError.damaged("FLAC STREAMINFO 缺失")
        }
        guard audioStart < bytes.count else { throw AudioTagWriteError.damaged("FLAC 音频数据为空") }

        let managed = managedKeys(for: tags)
        var vendor = "AT Music"
        var keptEntries: [String] = []
        var oldPicture: [UInt8]?
        for block in blocks where block.type == 4 {
            let payload = block.payload
            guard payload.count >= 8 else { continue }
            func le32(_ offset: Int) -> Int {
                Int(payload[offset]) | Int(payload[offset + 1]) << 8
                    | Int(payload[offset + 2]) << 16 | Int(payload[offset + 3]) << 24
            }
            let vendorLength = le32(0)
            guard vendorLength >= 0, 4 + vendorLength + 4 <= payload.count else { continue }
            if vendorLength > 0,
               let value = String(bytes: payload[4..<(4 + vendorLength)], encoding: .utf8),
               !value.isEmpty {
                vendor = value
            }
            var offset = 4 + vendorLength
            let count = le32(offset)
            offset += 4
            guard count > 0, count < 100_000 else { continue }
            for _ in 0..<count {
                guard offset + 4 <= payload.count else { break }
                let length = le32(offset)
                offset += 4
                guard length >= 0, offset + length <= payload.count else { break }
                if let entry = String(bytes: payload[offset..<(offset + length)], encoding: .utf8) {
                    let key = entry.split(separator: "=", maxSplits: 1).first.map { $0.uppercased() } ?? ""
                    if !managed.contains(key) { keptEntries.append(entry) }
                }
                offset += length
            }
        }
        for block in blocks where block.type == 6 { oldPicture = block.payload }

        var entries = keptEntries
        func add(_ key: String, _ value: String?) {
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            entries.append("\(key)=\(value)")
        }
        add("TITLE", tags.title)
        add("ARTIST", tags.artist)
        add("ALBUM", tags.album)
        add("ALBUMARTIST", tags.albumArtist)
        add("GENRE", tags.genre)
        add("DATE", tags.year)
        if tags.track > 0 { add("TRACKNUMBER", String(tags.track)) }
        if tags.trackTotal > 0 { add("TRACKTOTAL", String(tags.trackTotal)) }
        if tags.disc > 0 { add("DISCNUMBER", String(tags.disc)) }
        if tags.discTotal > 0 { add("DISCTOTAL", String(tags.discTotal)) }
        add("COMMENT", tags.comment)
        add("LYRICS", tags.lyrics)

        var commentPayload: [UInt8] = []
        func appendLE32(_ value: Int) {
            commentPayload.append(contentsOf: [
                UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
                UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)
            ])
        }
        let vendorData = [UInt8](vendor.data(using: .utf8) ?? Data())
        appendLE32(vendorData.count)
        commentPayload.append(contentsOf: vendorData)
        appendLE32(entries.count)
        for entry in entries {
            let entryData = [UInt8](entry.data(using: .utf8) ?? Data())
            appendLE32(entryData.count)
            commentPayload.append(contentsOf: entryData)
        }

        var picturePayload: [UInt8]?
        if let cover = tags.coverData, !cover.isEmpty {
            var payload: [UInt8] = []
            func appendBE32(_ value: Int) {
                payload.append(contentsOf: [
                    UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                    UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)
                ])
            }
            appendBE32(3)  // 封面（front cover）
            let mime = [UInt8]((AudioTagEmbedder.isPNG(cover) ? "image/png" : "image/jpeg").utf8)
            appendBE32(mime.count)
            payload.append(contentsOf: mime)
            appendBE32(0)  // 描述
            appendBE32(0); appendBE32(0); appendBE32(0); appendBE32(0)  // 宽高色深索引
            appendBE32(cover.count)
            payload.append(contentsOf: cover)
            picturePayload = payload
        }

        var outBlocks: [Block] = [Block(type: 0, payload: streamInfo.payload)]
        for block in blocks.dropFirst() where block.type != 4 && block.type != 6 && block.type != 7 {
            outBlocks.append(Block(type: block.type, payload: block.payload))
        }
        outBlocks.append(Block(type: 4, payload: commentPayload))
        if let picturePayload {
            outBlocks.append(Block(type: 6, payload: picturePayload))
        } else if let oldPicture {
            outBlocks.append(Block(type: 6, payload: oldPicture))
        }
        outBlocks.append(Block(type: 7, payload: [UInt8](repeating: 0, count: 8192)))  // padding

        var out: [UInt8] = Array("fLaC".utf8)
        for (index, block) in outBlocks.enumerated() {
            let isLast = index == outBlocks.count - 1
            out.append(isLast ? (0x80 | block.type) : block.type)
            let length = block.payload.count
            out.append(contentsOf: [
                UInt8((length >> 16) & 0xFF), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)
            ])
            out.append(contentsOf: block.payload)
        }
        out.append(contentsOf: bytes[audioStart...])
        return Data(out)
    }
}
