import Foundation

/// 生产代码 `AudioTagEmbedder` / `AudioTagContainerWriters` 的真机格式回归测试。
///
/// 用真实音频逐个容器写入标签，然后校验：
/// 1. 容器结构仍可被系统解析（afinfo）；
/// 2. 写入前后**完整解码的 PCM 逐字节一致**（MP4 额外校验 mdat 位流完全相同 + chunk 偏移同量平移）；
/// 3. 标签位真的长出了对应帧/键；
/// 4. 连续写两次不破坏文件（幂等）。
///
/// 运行：
/// ```sh
/// swiftc -O ATMusic/AudioTagEmbedder.swift ATMusic/AudioTagContainerWriters.swift \
///   tests/AudioTagWriterTests.swift -o /tmp/atmusic-tag-writer-tests && /tmp/atmusic-tag-writer-tests
/// ```
/// 需要 macOS 自带 `afconvert` / `afinfo`；无可用源素材时只跑结构性断言。
@main
enum AudioTagWriterTests {
    static var failures = 0
    static var checks = 0
    static let work = NSTemporaryDirectory() + "atmusic-tag-writer-tests"

    static func check(_ condition: Bool, _ label: String) {
        checks += 1
        print((condition ? "✅ " : "❌ ") + label)
        if !condition { failures += 1 }
    }

    @discardableResult
    static func shell(_ command: String) -> (code: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func bytes(_ path: String) -> [UInt8] { [UInt8]((try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()) }
    static func md5(_ path: String) -> String { shell("md5 -q '\(path)'").output.trimmingCharacters(in: .whitespacesAndNewlines) }

    static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count) where haystack[start] == needle[0] {
            var matched = true
            for offset in 1..<needle.count where haystack[start + offset] != needle[offset] {
                matched = false
                break
            }
            if matched { return true }
        }
        return false
    }

    static func decode(_ source: String, _ destination: String) -> Bool {
        shell("afconvert -f WAVE -d LEI16 '\(source)' '\(destination)' 2>/dev/null").code == 0
    }

    /// 取 WAV 的 PCM 负载，仅比对音频本体（忽略容器头差异）
    static func pcmPayload(_ path: String) -> [UInt8] {
        let data = bytes(path)
        var position = 12
        while position + 8 <= data.count {
            let id = String(decoding: data[position..<(position + 4)], as: UTF8.self)
            let size = Int(data[position + 4]) | Int(data[position + 5]) << 8
                | Int(data[position + 6]) << 16 | Int(data[position + 7]) << 24
            if id == "data" {
                let start = position + 8
                let end = min(data.count, start + max(0, size))
                return Array(data[start..<end])
            }
            position += 8 + size + (size % 2)
        }
        return data
    }

    struct MP4Atom { let type: String; let start: Int; let payloadStart: Int; let end: Int }

    static func mp4Atoms(_ bytes: [UInt8], _ range: Range<Int>) -> [MP4Atom] {
        var atoms: [MP4Atom] = []
        var position = range.lowerBound
        while position + 8 <= range.upperBound {
            let size = Int(bytes[position]) << 24 | Int(bytes[position + 1]) << 16
                | Int(bytes[position + 2]) << 8 | Int(bytes[position + 3])
            let type = String(decoding: bytes[(position + 4)..<(position + 8)], as: UTF8.self)
            guard size >= 8, position + size <= range.upperBound else { break }
            atoms.append(MP4Atom(type: type, start: position, payloadStart: position + 8, end: position + size))
            position += size
        }
        return atoms
    }

    static func mp4Find(_ bytes: [UInt8], _ range: Range<Int>, _ wanted: String) -> MP4Atom? {
        for atom in mp4Atoms(bytes, range) {
            if atom.type == wanted { return atom }
            if ["moov", "trak", "mdia", "minf", "stbl", "udta"].contains(atom.type),
               let found = mp4Find(bytes, atom.payloadStart..<atom.end, wanted) {
                return found
            }
        }
        return nil
    }

    static func stcoOffsets(_ bytes: [UInt8]) -> [Int] {
        guard let stco = mp4Find(bytes, 0..<bytes.count, "stco") else { return [] }
        let body = stco.payloadStart
        guard body + 8 <= bytes.count else { return [] }
        let count = Int(bytes[body + 4]) << 24 | Int(bytes[body + 5]) << 16
            | Int(bytes[body + 6]) << 8 | Int(bytes[body + 7])
        return (0..<count).compactMap { index in
            let offset = body + 8 + index * 4
            guard offset + 4 <= bytes.count else { return nil }
            return Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
        }
    }

    static func makeTags(cover: Data?) -> AudioTagSet {
        var tags = AudioTagSet(
            title: "Tester 歌曲",
            artist: "AT 测试",
            album: "标签验证盘",
            albumArtist: "AT 测试",
            genre: "Electronic",
            year: "2026",
            comment: "AT Music 写回测试",
            track: 7,
            disc: 2,
            coverData: cover
        )
        tags.trackTotal = 12
        tags.discTotal = 2
        tags.lyrics = "[00:00.50]第一行歌词\n[00:02.00]第二行歌词"
        return tags
    }

    static func main() {
        try? FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)

        // 封面：用仓库里的 AppIcon（真 JPEG/PNG 都走一遍 isPNG 分支）
        let iconPNG = "ATMusic/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
        let iconJPEG = work + "/cover.jpg"
        _ = shell("sips -s format jpeg '\(iconPNG)' --out '\(iconJPEG)' >/dev/null 2>&1")
        let cover = (try? Data(contentsOf: URL(fileURLWithPath: iconJPEG)))
        check(cover != nil, "封面素材可用（\(cover?.count ?? 0) B）")
        let tags = makeTags(cover: cover)

        // 源素材：系统自带的 mp3，转出 FLAC / WAV / AIFF / M4A
        let systemMP3 = "/System/Library/PrivateFrameworks/PersonalAudio.framework/Versions/A/Resources/Enrollment_1.mp3"
        let sourceMP3 = work + "/source.mp3"
        _ = shell("cp '\(systemMP3)' '\(sourceMP3)' 2>/dev/null")
        let hasSource = FileManager.default.fileExists(atPath: sourceMP3)
        print(hasSource ? "ℹ️  使用系统样例音频作为源素材" : "ℹ️  无可用源素材，仅跑结构性断言")
        if hasSource {
            _ = shell("afconvert -f m4af -d aac '\(sourceMP3)' '\(work)/source.m4a' 2>/dev/null")
            _ = shell("afconvert -f WAVE -d LEI16 '\(sourceMP3)' '\(work)/source.wav' 2>/dev/null")
            _ = shell("afconvert -f AIFF -d BEI16 '\(sourceMP3)' '\(work)/source.aiff' 2>/dev/null")
            _ = shell("afconvert -f flac -d flac '\(sourceMP3)' '\(work)/source.flac' 2>/dev/null")
        }

        let cases: [(String, AudioTagContainer, [String])] = [
            ("source.mp3", .mp3, ["TIT2", "Tester 歌曲", "APIC", "USLT", "TPOS"]),
            ("source.flac", .flac, ["TITLE=Tester 歌曲", "TRACKNUMBER=7", "DISCNUMBER=2", "LYRICS=[00:00.50]"]),
            ("source.m4a", .mp4, ["Tester 歌曲", "AT 测试", "covr"]),
            ("source.wav", .wav, ["id3 ", "TIT2"]),
            ("source.aiff", .aiff, ["ID3 ", "TIT2"])
        ]

        for (name, expected, probes) in cases {
            let path = work + "/" + name
            guard FileManager.default.fileExists(atPath: path) else {
                print("ℹ️  \(name) 不存在，跳过（本机未生成该格式）")
                continue
            }
            let original = bytes(path)
            check(AudioTagEmbedder.container(of: Data(original)) == expected, "\(name)：容器嗅探 → \(expected.displayName)")
            let referenceWAV = "\(path).before.wav"
            let decodedBefore = decode(path, referenceWAV)
            let m4aPayloadBefore = expected == .mp4 ? mp4Payload(path) : []
            let stcoBefore = expected == .mp4 ? stcoOffsets(original) : []
            let moovBefore = expected == .mp4 ? (mp4Find(original, 0..<original.count, "moov")?.end ?? 0)
                - (mp4Find(original, 0..<original.count, "moov")?.start ?? 0) : 0

            do {
                let report = try AudioTagEmbedder.writeInPlace(tags: tags, fileURL: URL(fileURLWithPath: path))
                check(report.container == expected.displayName, "\(name)：写入报告 \(report.container) · \(report.byteCount) B")
            } catch {
                check(false, "\(name)：写入抛错 \(error.localizedDescription)")
                continue
            }

            check(shell("afinfo '\(path)' >/dev/null 2>&1").code == 0, "\(name)：写标签后结构仍可解析")
            if decodedBefore {
                let taggedWAV = "\(path).after.wav"
                check(decode(path, taggedWAV), "\(name)：写标签后仍可完整解码")
                if expected != .mp4 {
                    check(pcmPayload(referenceWAV) == pcmPayload(taggedWAV), "\(name)：解码 PCM 与写标签前完全一致")
                }
            }

            let tagged = bytes(path)
            for probe in probes {
                let utf16 = [UInt8](probe.data(using: .utf16LittleEndian) ?? Data())
                check(contains(tagged, utf16) || contains(tagged, [UInt8](probe.utf8)), "\(name)：标签含「\(probe)」")
            }

            if expected == .mp4 {
                check(mp4Payload(path) == m4aPayloadBefore, "\(name)：mdat 音频位流与原文件完全相同")
                let stcoAfter = stcoOffsets(tagged)
                let moovAfter = (mp4Find(tagged, 0..<tagged.count, "moov")?.end ?? 0)
                    - (mp4Find(tagged, 0..<tagged.count, "moov")?.start ?? 0)
                let delta = moovAfter - moovBefore
                check(!stcoAfter.isEmpty, "\(name)：读得到 stco chunk 偏移表（\(stcoAfter.count) 项）")
                check(stcoAfter.count == stcoBefore.count, "\(name)：chunk 数量不变")
                check(zip(stcoBefore, stcoAfter).allSatisfy { $1 - $0 == delta },
                      "\(name)：全部 chunk 偏移随 moov 增长同量平移（Δ=\(delta)）")
                let mdat = mp4Find(tagged, 0..<tagged.count, "mdat")
                check(stcoAfter.first == mdat?.payloadStart, "\(name)：首块偏移精确落在 mdat 负载起点")
            }

            _ = try? AudioTagEmbedder.writeInPlace(tags: tags, fileURL: URL(fileURLWithPath: path))
            check(shell("afinfo '\(path)' >/dev/null 2>&1").code == 0, "\(name)：连续写两次仍可解析")
        }

        // 不支持的容器必须明确拒绝，而不是写坏文件
        let unsupported = work + "/fake.ape"
        var fake = Array("MAC ".utf8)
        fake.append(contentsOf: [UInt8](repeating: 0, count: 512))
        try? Data(fake).write(to: URL(fileURLWithPath: unsupported))
        do {
            _ = try AudioTagEmbedder.writeInPlace(tags: tags, fileURL: URL(fileURLWithPath: unsupported))
            check(false, "APE：应拒绝写入")
        } catch {
            check(true, "APE：明确拒绝写入（\(error.localizedDescription)）")
        }
        check(bytes(unsupported).count == fake.count, "APE：拒绝时未改动原文件")

        print("\n=== 标签写入：\(checks) 项断言，\(failures == 0 ? "全部通过" : "\(failures) 项失败") ===")
        exit(failures == 0 ? 0 : 1)
    }

    /// mdat 的负载（就是压缩音频位流本体）
    static func mp4Payload(_ path: String) -> [UInt8] {
        let data = bytes(path)
        guard let mdat = mp4Find(data, 0..<data.count, "mdat") else { return [] }
        return Array(data[mdat.payloadStart..<mdat.end])
    }
}
