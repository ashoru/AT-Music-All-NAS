import Foundation

/// 歌词时间轴烘焙的**纯算法**（Foundation-only，便于用 swiftc 直接跑断言测试）。
///
/// 语义与播放侧一致：偏移为正 = 歌词提前（`effectiveProgress = progress + offset`），
/// 因此烘焙时行时间整体前移 offset，之后按 0 偏移播放即对齐。
/// 歌词自带 `[offset:±ms]` 标签时，先把它算进绝对值、再删掉这条标签，
/// 避免「烘焙一次、播放时再叠加一次」的双重偏移。
enum LyricTimingBaker {
    private static let timeTagPattern = "\\[(\\d{1,3}):(\\d{1,2})(?:[.:](\\d{1,3}))?\\]"
    private static let timeTagRegex = try? NSRegularExpression(pattern: timeTagPattern, options: [])
    private static let declaredOffsetPattern = #"\[offset:([+-]?\d+)\]"#
    private static let declaredOffsetRegex = try? NSRegularExpression(pattern: declaredOffsetPattern, options: [])

    /// 歌词自带 `[offset:±ms]` 时，播放解析会把它叠进时间轴；
    /// 烘焙时必须把它算进绝对值并删掉这条标签，否则会出现「烘焙一次再叠加一次」的双重偏移。
    static func declaredOffset(in raw: String) -> Double {
        guard let regex = declaredOffsetRegex,
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let range = Range(match.range(at: 1), in: raw),
              let milliseconds = Double(raw[range]) else { return 0 }
        return milliseconds / 1000.0
    }

    private static func strippingDeclaredOffset(_ raw: String) -> String {
        guard let regex = declaredOffsetRegex else { return raw }
        let range = NSRange(raw.startIndex..., in: raw)
        return regex.stringByReplacingMatches(in: raw, options: [], range: range, withTemplate: "")
    }

    /// 把偏移烘焙进 LRC：偏移为正（歌词提前）时，行时间整体前移，之后按 0 偏移播放即对齐。
    static func bake(_ raw: String, offset: Double) -> String {
        guard abs(offset) > 0.0001, let regex = timeTagRegex else { return raw }
        let carried = declaredOffset(in: raw)
        let cleaned = strippingDeclaredOffset(raw)
        let lines = cleaned.components(separatedBy: .newlines)
        let baked = lines.map { rewrite(line: $0, offset: offset - carried, regex: regex) }
        return baked.joined(separator: "\n")
    }

    private static func rewrite(line: String, offset: Double, regex: NSRegularExpression) -> String {
        let ns = line as NSString
        let matches = regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return line }
        var output = ""
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                output += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            }
            let minutes = Double(ns.substring(with: match.range(at: 1))) ?? 0
            let seconds = Double(ns.substring(with: match.range(at: 2))) ?? 0
            var fraction = 0.0
            var fractionDigits = 0
            if match.range(at: 3).location != NSNotFound {
                let rawFraction = ns.substring(with: match.range(at: 3))
                fractionDigits = rawFraction.count
                fraction = (Double(rawFraction) ?? 0) / pow(10, Double(max(1, rawFraction.count)))
            }
            let time = max(0, minutes * 60 + seconds + fraction - offset)
            output += "[\(formatTime(time, fractionDigits: fractionDigits))]"
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            output += ns.substring(from: cursor)
        }
        return output
    }

    private static func formatTime(_ time: Double, fractionDigits: Int) -> String {
        let clamped = max(0, time)
        let totalSeconds = Int(clamped)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        guard fractionDigits > 0 else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
        let digits = max(1, min(3, fractionDigits))
        let scale = Int(pow(10.0, Double(digits)))
        var fraction = Int(((clamped - Double(totalSeconds)) * Double(scale)).rounded())
        if fraction >= scale { fraction = scale - 1 }
        return String(format: "%02d:%02d.%0*d", minutes, seconds, digits, fraction)
    }

}
