import Foundation

enum ATMusicLogSanitizer {
    private static let rules: [(NSRegularExpression, String)] = {
        let keys = #"password|passwd|pwd|_sid|sid|vkey|token|access_token|refresh_token|auth_token|accesstoken|cookie|set-cookie|authorization|music_u|secret|api_key|apikey"#
        let patterns: [(String, String)] = [
            (#"(?i)(["'](?:"# + keys + #")["']\s*:\s*)"(?:\\.|[^"\\])*""#, "$1\"***\""),
            (#"(?i)(["'](?:"# + keys + #")["']\s*:\s*)'(?:\\.|[^'\\])*'"#, "$1'***'"),
            (#"(?im)\b(authorization|cookie|set-cookie)\s*[:=]\s*[^\r\n]+"#, "$1: ***"),
            (#"(?i)\b("# + keys + #")\s*(?:=|:|%3d|%3a)\s*[^\s&,;]+"#, "$1=***")
        ]
        return patterns.compactMap { pattern, replacement in
            (try? NSRegularExpression(pattern: pattern)).map { ($0, replacement) }
        }
    }()
    static func sanitize(_ text: String) -> String {
        rules.reduce(text) { value, rule in
            rule.0.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: rule.1)
        }
    }
}
