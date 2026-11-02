import Foundation

// MARK: - M4A / MP4：moov → udta → meta → ilst

/// MP4 家族（m4a / mp4 / alac）标签写入。
///
/// 难点不在写标签，而在「改了 moov 大小之后别把音频流写坏」：
/// ilst 记录的是 chunk 的**绝对文件偏移**（stco / co64），一旦 moov 变长、
/// 而 moov 又排在 mdat 之前，mdat 整体后移，所有偏移都要同步平移 delta，
/// 否则播放器会把采样位置读偏、出现错音或整首无声。
enum MP4TagWriter {
    private struct Atom {
        let type: String
        let start: Int
        let bodyStart: Int
        let end: Int
    }

    /// 动态确定本次需要覆盖接管的 ilst 子项；未在 tags 中修改或未提供的子项（如未改封面、未改歌词等）原样保留。
    private static func managedIlstTypes(for tags: AudioTagSet) -> Set<String> {
        var types: Set<String> = []
        if tags.title != nil { types.insert("©nam") }
        if tags.artist != nil { types.insert("©ART") }
        if tags.albumArtist != nil { types.insert("aART") }
        if tags.album != nil { types.insert("©alb") }
        if tags.genre != nil { types.insert("©gen") }
        if tags.year != nil { types.insert("©day") }
        if tags.comment != nil { types.insert("©cmt") }
        if tags.lyrics != nil { types.insert("©lyr") }
        if tags.track > 0 { types.insert("trkn") }
        if tags.disc > 0 { types.insert("disk") }
        if tags.coverData != nil { types.insert("covr") }
        return types
    }

    private static let versionFlags: [UInt8] = [0x00, 0x00, 0x00, 0x00]

    static func write(tags: AudioTagSet, data: Data) throws -> Data {
        let bytes = [UInt8](data)
        let top = try parseAtoms(bytes, in: 0..<bytes.count)
        guard let moov = top.first(where: { $0.type == "moov" }) else {
            throw AudioTagWriteError.damaged("MP4 缺少 moov 原子")
        }
        let mdat = top.first(where: { $0.type == "mdat" })
        let moovChildren = try parseAtoms(bytes, in: moov.bodyStart..<moov.end)

        var newChildren: [[UInt8]] = []
        var rebuilt = false
        for child in moovChildren {
            switch child.type {
            case "udta":
                newChildren.append(try rebuildUdta(bytes: bytes, udta: child, tags: tags))
                rebuilt = true
            case "meta":
                newChildren.append(try rebuildMeta(bytes: bytes, meta: child, tags: tags))
                rebuilt = true
            default:
                newChildren.append(Array(bytes[child.start..<child.end]))
            }
        }
        if !rebuilt {
            newChildren.append(atom("udta", metaAtom(versionFlags: versionFlags,
                                                     handler: handlerAtom,
                                                     ilst: buildIlst(tags: tags, keeping: []))))
        }

        var newMoov = atom("moov", newChildren.flatMap { $0 })
        let delta = newMoov.count - (moov.end - moov.start)
        if delta != 0, let mdat, mdat.start > moov.start {
            try shiftChunkOffsets(&newMoov, delta: delta)
        }

        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + max(0, delta))
        out.append(contentsOf: bytes[0..<moov.start])
        out.append(contentsOf: newMoov)
        out.append(contentsOf: bytes[moov.end..<bytes.count])
        return Data(out)
    }

    // MARK: 组装

    private static func rebuildUdta(bytes: [UInt8], udta: Atom, tags: AudioTagSet) throws -> [UInt8] {
        let children = try parseAtoms(bytes, in: udta.bodyStart..<udta.end)
        var parts: [[UInt8]] = []
        var metaRebuilt = false
        for child in children {
            if child.type == "meta" {
                parts.append(try rebuildMeta(bytes: bytes, meta: child, tags: tags))
                metaRebuilt = true
            } else {
                parts.append(Array(bytes[child.start..<child.end]))
            }
        }
        if !metaRebuilt {
            parts.append(metaAtom(versionFlags: versionFlags,
                                  handler: handlerAtom,
                                  ilst: buildIlst(tags: tags, keeping: [])))
        }
        return atom("udta", parts.flatMap { $0 })
    }

    private static func detectMetaHeader(bytes: [UInt8], meta: Atom) -> (flags: [UInt8], childrenStart: Int) {
        // 尝试 1：QuickTime / iTunes 风格（标准 Box，0 字节 flags，子原子直接从 meta.bodyStart 开始）
        if let directAtoms = try? parseAtoms(bytes, in: meta.bodyStart..<meta.end),
           directAtoms.contains(where: { $0.type == "hdlr" || $0.type == "ilst" || $0.type == "keys" }) {
            return ([], meta.bodyStart)
        }

        // 尝试 2：ISO MP4 FullBox 风格（有 4 字节的 version/flags，子原子从 meta.bodyStart + 4 开始）
        if meta.bodyStart + 4 <= meta.end,
           let fullBoxAtoms = try? parseAtoms(bytes, in: (meta.bodyStart + 4)..<meta.end),
           fullBoxAtoms.contains(where: { $0.type == "hdlr" || $0.type == "ilst" || $0.type == "keys" }) {
            let flags = Array(bytes[meta.bodyStart..<(meta.bodyStart + 4)])
            return (flags, meta.bodyStart + 4)
        }

        // 兜底 1：直接从 bodyStart 解析有效原子无报错
        if let directAtoms = try? parseAtoms(bytes, in: meta.bodyStart..<meta.end), !directAtoms.isEmpty {
            return ([], meta.bodyStart)
        }

        // 兜底 2：4 字节 flags
        if meta.bodyStart + 4 <= meta.end {
            let flags = Array(bytes[meta.bodyStart..<(meta.bodyStart + 4)])
            return (flags, meta.bodyStart + 4)
        }

        return ([], meta.bodyStart)
    }

    private static func rebuildMeta(bytes: [UInt8], meta: Atom, tags: AudioTagSet) throws -> [UInt8] {
        guard meta.bodyStart <= meta.end else { throw AudioTagWriteError.damaged("meta 原子过短") }
        let (flags, childrenStart) = detectMetaHeader(bytes: bytes, meta: meta)
        let children = try parseAtoms(bytes, in: childrenStart..<meta.end)

        let managed = managedIlstTypes(for: tags)
        var handlerAtomBytes: [UInt8]? = nil
        var otherChildren: [[UInt8]] = []
        var keptIlstChildren: [[UInt8]] = []

        for child in children {
            switch child.type {
            case "ilst":
                let ilstChildren = try parseAtoms(bytes, in: child.bodyStart..<child.end)
                keptIlstChildren = ilstChildren
                    .filter { !managed.contains($0.type) }
                    .map { Array(bytes[$0.start..<$0.end]) }
            case "hdlr":
                handlerAtomBytes = Array(bytes[child.start..<child.end])
            default:
                otherChildren.append(Array(bytes[child.start..<child.end]))
            }
        }

        var parts: [[UInt8]] = []
        if let handlerAtomBytes {
            parts.append(handlerAtomBytes)
        } else {
            parts.append(handlerAtom)
        }
        parts.append(contentsOf: otherChildren)
        parts.append(buildIlst(tags: tags, keeping: keptIlstChildren))
        return atom("meta", flags + parts.flatMap { $0 })
    }

    private static func metaAtom(versionFlags: [UInt8], handler: [UInt8], ilst: [UInt8]) -> [UInt8] {
        atom("meta", versionFlags + handler + ilst)
    }

    private static func buildIlst(tags: AudioTagSet, keeping kept: [[UInt8]]) -> [UInt8] {
        var children: [UInt8] = []

        func text(_ name: String, _ value: String?) {
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            children += atom(name, dataAtom(typeIndicator: 1, payload: Array(value.utf8)))
        }

        if tags.title != nil { text("©nam", tags.title) }
        if tags.artist != nil { text("©ART", tags.artist) }
        if tags.albumArtist != nil { text("aART", tags.albumArtist) }
        if tags.album != nil { text("©alb", tags.album) }
        if tags.genre != nil { text("©gen", tags.genre) }
        if tags.year != nil { text("©day", tags.year) }
        if tags.comment != nil { text("©cmt", tags.comment) }
        if tags.lyrics != nil { text("©lyr", tags.lyrics) }

        if tags.track > 0 {
            let total = max(0, min(Int(UInt16.max), tags.trackTotal))
            let track = max(0, min(Int(UInt16.max), tags.track))
            var payload: [UInt8] = [0x00, 0x00]
            payload.append(contentsOf: [UInt8((track >> 8) & 0xFF), UInt8(track & 0xFF)])
            payload.append(contentsOf: [UInt8((total >> 8) & 0xFF), UInt8(total & 0xFF)])
            payload.append(contentsOf: [0x00, 0x00])
            children += atom("trkn", dataAtom(typeIndicator: 0, payload: payload))
        }
        if tags.disc > 0 {
            let total = max(0, min(Int(UInt16.max), tags.discTotal))
            let disc = max(0, min(Int(UInt16.max), tags.disc))
            var payload: [UInt8] = [0x00, 0x00]
            payload.append(contentsOf: [UInt8((disc >> 8) & 0xFF), UInt8(disc & 0xFF)])
            payload.append(contentsOf: [UInt8((total >> 8) & 0xFF), UInt8(total & 0xFF)])
            children += atom("disk", dataAtom(typeIndicator: 0, payload: payload))
        }
        if let cover = tags.coverData, !cover.isEmpty {
            children += atom("covr", dataAtom(typeIndicator: AudioTagEmbedder.isPNG(cover) ? 14 : 13,
                                              payload: [UInt8](cover)))
        }
        for extra in kept {
            children += extra
        }
        return atom("ilst", children)
    }

    private static func dataAtom(typeIndicator: UInt32, payload: [UInt8]) -> [UInt8] {
        var body: [UInt8] = [
            UInt8((typeIndicator >> 24) & 0xFF), UInt8((typeIndicator >> 16) & 0xFF),
            UInt8((typeIndicator >> 8) & 0xFF), UInt8(typeIndicator & 0xFF),
            0x00, 0x00, 0x00, 0x00  // locale
        ]
        body.append(contentsOf: payload)
        return atom("data", body)
    }

    private static var handlerAtom: [UInt8] {
        var body = versionFlags
        body += [0x00, 0x00, 0x00, 0x00]              // pre_defined
        body += Array("mdir".utf8)                     // handler_type
        body += [UInt8](repeating: 0x00, count: 12)    // reserved
        body += [0x00]                                 // name（空串）
        return atom("hdlr", body)
    }

    // MARK: 原子工具

    private static func atom(_ type: String, _ body: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        let total = body.count + 8
        out += [UInt8((total >> 24) & 0xFF), UInt8((total >> 16) & 0xFF),
                UInt8((total >> 8) & 0xFF), UInt8(total & 0xFF)]
        out += typeBytes(type)
        out += body
        return out
    }

    private static func typeBytes(_ type: String) -> [UInt8] {
        var out: [UInt8] = []
        for scalar in type.unicodeScalars {
            if out.count == 4 { break }
            if scalar.value == 0xA9 {
                out.append(0xA9)  // ©
            } else if scalar.value < 0x80 {
                out.append(UInt8(scalar.value))
            } else {
                out.append(0x3F)  // '?'
            }
        }
        while out.count < 4 { out.append(0x20) }
        return Array(out.prefix(4))
    }

    private static func displayType(_ bytes: [UInt8], _ offset: Int) -> String {
        var scalars: [Unicode.Scalar] = []
        for i in 0..<4 {
            let byte = bytes[offset + i]
            if byte == 0xA9 {
                scalars.append(Unicode.Scalar(UInt8(0xA9)))
            } else if byte >= 0x20, byte < 0x7F {
                scalars.append(Unicode.Scalar(byte))
            } else {
                scalars.append(Unicode.Scalar(UInt8(0x2E)))
            }
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func parseAtoms(_ bytes: [UInt8], in range: Range<Int>) throws -> [Atom] {
        var atoms: [Atom] = []
        var pos = range.lowerBound
        while pos + 8 <= range.upperBound {
            let size = Int(bytes[pos]) << 24 | Int(bytes[pos + 1]) << 16
                | Int(bytes[pos + 2]) << 8 | Int(bytes[pos + 3])
            let type = displayType(bytes, pos + 4)
            var bodyStart = pos + 8
            var end: Int
            if size == 1 {
                guard pos + 16 <= range.upperBound else {
                    throw AudioTagWriteError.damaged("原子 \(type) 64 位长度越界")
                }
                var large = 0
                for i in (pos + 8)..<(pos + 16) { large = (large << 8) | Int(bytes[i]) }
                guard large >= 16, large < (1 << 48) else {
                    throw AudioTagWriteError.damaged("原子 \(type) 64 位长度异常")
                }
                bodyStart = pos + 16
                end = pos + large
            } else if size == 0 {
                if pos == 0 || range.upperBound == bytes.count {
                    end = range.upperBound
                } else {
                    let remaining = bytes[pos..<range.upperBound]
                    if remaining.allSatisfy({ $0 == 0 }) {
                        break
                    }
                    end = range.upperBound
                }
            } else {
                end = pos + size
            }
            guard end >= bodyStart, end <= range.upperBound else {
                throw AudioTagWriteError.damaged("原子 \(type) 长度越界")
            }
            atoms.append(Atom(type: type, start: pos, bodyStart: bodyStart, end: end))
            if end == pos { break }
            pos = end
        }
        return atoms
    }

    /// moov 变长后，把它内部所有 chunk 偏移表整体平移。
    private static func shiftChunkOffsets(_ moov: inout [UInt8], delta: Int) throws {
        let root = try parseAtoms(moov, in: 0..<moov.count)
        guard let moovAtom = root.first(where: { $0.type == "moov" }) else { return }
        var targets: [(bodyStart: Int, is64: Bool)] = []
        let containers: Set<String> = ["trak", "mdia", "minf", "stbl", "edts", "udta"]

        func walk(_ range: Range<Int>) {
            guard let children = try? parseAtoms(moov, in: range) else { return }
            for child in children {
                if child.type == "stco" {
                    targets.append((child.bodyStart, false))
                } else if child.type == "co64" {
                    targets.append((child.bodyStart, true))
                } else if containers.contains(child.type) {
                    walk(child.bodyStart..<child.end)
                }
            }
        }
        walk(moovAtom.bodyStart..<moovAtom.end)

        for target in targets {
            let countPos = target.bodyStart + 4
            guard countPos + 4 <= moov.count else { continue }
            let count = Int(moov[countPos]) << 24 | Int(moov[countPos + 1]) << 16
                | Int(moov[countPos + 2]) << 8 | Int(moov[countPos + 3])
            guard count > 0, count < 50_000_000 else { continue }
            var pos = countPos + 4
            let width = target.is64 ? 8 : 4
            for _ in 0..<count {
                guard pos + width <= moov.count else { break }
                var value = 0
                for i in 0..<width { value = (value << 8) | Int(moov[pos + i]) }
                let shifted = value + delta
                guard shifted >= 0, shifted <= Int(UInt32.max) || target.is64 else {
                    throw AudioTagWriteError.damaged("chunk 偏移超出 32 位可表示范围")
                }
                for i in 0..<width {
                    moov[pos + i] = UInt8((shifted >> ((width - 1 - i) * 8)) & 0xFF)
                }
                pos += width
            }
        }
    }
}

// MARK: - WAV / AIFF：内嵌 ID3 chunk

enum RIFFTagWriter {
    static func write(tags: AudioTagSet, data: Data, isAIFF: Bool) throws -> Data {
        let bytes = [UInt8](data)
        let name = isAIFF ? "AIFF" : "WAV"
        guard bytes.count >= 12 else { throw AudioTagWriteError.damaged("\(name) 容器头不完整") }
        guard readSize(bytes, at: 0, bigEndian: isAIFF) > 0 else {
            throw AudioTagWriteError.damaged("\(name) 容器长度异常")
        }

        let id3Payload = [UInt8](ID3Writer.tagBytes(tags: tags))
        let skipChunks: Set<String> = isAIFF ? ["ID3 ", "id3 "] : ["id3 ", "ID3 "]

        var out: [UInt8] = Array(bytes[0..<12])
        var pos = 12
        while pos + 8 <= bytes.count {
            let id = String(decoding: bytes[pos..<(pos + 4)], as: UTF8.self)
            var payloadSize = readSize(bytes, at: pos + 4, bigEndian: isAIFF)
            let available = bytes.count - (pos + 8)
            if payloadSize < 0 || payloadSize > available { payloadSize = available }
            let end = pos + 8 + payloadSize
            if !skipChunks.contains(id) {
                out.append(contentsOf: bytes[pos..<end])
            }
            pos = end + (payloadSize % 2)
        }

        out.append(contentsOf: Array((isAIFF ? "ID3 " : "id3 ").utf8))
        out.append(contentsOf: encodeSize(id3Payload.count, bigEndian: isAIFF))
        out.append(contentsOf: id3Payload)
        if id3Payload.count % 2 == 1 { out.append(0x00) }

        let total = encodeSize(out.count - 8, bigEndian: isAIFF)
        out[4] = total[0]
        out[5] = total[1]
        out[6] = total[2]
        out[7] = total[3]
        return Data(out)
    }

    private static func readSize(_ bytes: [UInt8], at offset: Int, bigEndian: Bool) -> Int {
        guard offset + 4 <= bytes.count else { return -1 }
        if bigEndian {
            return Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
        }
        return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
            | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
    }

    private static func encodeSize(_ value: Int, bigEndian: Bool) -> [UInt8] {
        let clamped = max(0, min(value, Int(UInt32.max)))
        let big: [UInt8] = [
            UInt8((clamped >> 24) & 0xFF), UInt8((clamped >> 16) & 0xFF),
            UInt8((clamped >> 8) & 0xFF), UInt8(clamped & 0xFF)
        ]
        return bigEndian ? big : Array(big.reversed())
    }
}
