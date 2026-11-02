import Foundation

/// 生产代码 `LyricTimingBaker` 的回归测试：歌词时间轴烘焙语义。
///
/// 运行：
/// ```sh
/// swiftc -O ATMusic/LyricTimingBaker.swift tests/LyricTimingBakerTests.swift -o /tmp/atmusic-lyric-baker-tests
/// /tmp/atmusic-lyric-baker-tests
/// ```
@main
enum LyricTimingBakerTests {
    static var failures = 0
    static var checks = 0

    static func check(_ condition: Bool, _ label: String) {
        checks += 1
        print((condition ? "✅ " : "❌ ") + label)
        if !condition { failures += 1 }
    }

    static func main() {
        let lrc = """
        [offset:-200]
        [ti:测试]
        [ar:AT Music]
        [00:01.00]第一行
        [00:02.50]第二行
        [00:03.00][00:09.75]重复行
        """

        let lead = LyricTimingBaker.bake(lrc, offset: 0.5)
        check(lead.contains("[00:00.30]第一行"), "提前 0.5s + 原有 offset:-0.2s → 01.00 变 00.30")
        check(lead.contains("[00:01.80]第二行"), "提前 0.5s + offset:-0.2s → 02.50 变 01.80")
        check(lead.contains("[00:02.30][00:09.05]重复行"), "同一行的多个时间戳整体平移")
        check(!lead.contains("[offset:"), "烘焙后移除 [offset:] 标签，避免播放时二次叠加")
        check(lead.contains("[ti:测试]") && lead.contains("[ar:AT Music]"), "元信息行原样保留")

        check(LyricTimingBaker.bake("[00:01.00]x", offset: -0.5).contains("[00:01.50]x"), "延后 0.5s → 01.00 变 01.50")
        check(LyricTimingBaker.bake("[00:00.20]x", offset: 0.5).contains("[00:00.00]x"), "前移越界夹到 00:00.00")
        check(LyricTimingBaker.bake("[00:01.234]x", offset: 0.1).contains("[00:01.134]x"), "毫秒位数按原文件保留（3 位）")
        check(LyricTimingBaker.bake("[00:01.20]x", offset: 0.1).contains("[00:01.10]x"), "两位小数保留两位")
        check(LyricTimingBaker.bake("[00:05]x", offset: 0.5).contains("[00:04]x"), "原本无小数的行不加小数")
        check(LyricTimingBaker.bake(lrc, offset: 0) == lrc, "偏移为 0 时原样返回（不误改文件）")
        check(LyricTimingBaker.bake("没有时间戳的纯文本", offset: 1.0) == "没有时间戳的纯文本", "无时间轴歌词不被改写")
        check(abs(LyricTimingBaker.declaredOffset(in: "[offset:+300]") - 0.3) < 0.0001, "解析 [offset:+300] → +0.3s")

        print("\n=== 歌词烘焙：\(checks) 项断言，\(failures == 0 ? "全部通过" : "\(failures) 项失败") ===")
        exit(failures == 0 ? 0 : 1)
    }
}
