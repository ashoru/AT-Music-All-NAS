import Foundation
import UIKit

/// 闪退检测与崩溃日志：捕获未捕获异常 / 崩溃信号，并在下次启动时检测上次是否异常退出。
/// 崩溃信息写入 Documents/ATMusicLogs/crash-日期.log，同时写入 App 内日志，便于反馈排查。
final class CrashReporter {
    static let shared = CrashReporter()

    /// 启动是否仍在进行（正常完成前为 true；若上次退出时仍为 true，说明可能闪退）
    private static let launchKey = "atmusic.launchInProgress"

    private init() {
        // 检测上次启动是否正常完成
        let wasInProgress = UserDefaults.standard.bool(forKey: Self.launchKey)
        if wasInProgress {
            ATMusicLogger.shared.log("⚠ 检测到上次运行异常退出（疑似闪退）。崩溃详情见 crash-*.log，可导出反馈排查", level: .error)
        }
        UserDefaults.standard.set(true, forKey: Self.launchKey)

        // 未捕获异常（NSException）
        NSSetUncaughtExceptionHandler { exception in
            let detail = """
            [未捕获异常] \(exception.name.rawValue)
            reason: \(exception.reason ?? "无")
            stack:
            \(exception.callStackSymbols.joined(separator: "\n"))
            """
            CrashReporter.writeCrash(detail)
        }

        // 崩溃信号：先预备好信号专用日志路径（handler 内只能用 async-signal-safe 的 POSIX write）
        Self.prepareSignalCrashFile()

        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE] {
            signal(sig, Self.signalHandler)
        }
    }

    /// 启动正常完成后调用，标记本次启动成功（避免下次误报闪退）
    func markLaunchCompleted() {
        UserDefaults.standard.set(false, forKey: Self.launchKey)
    }

    /// 信号崩溃专用日志路径（启动时预先算好；handler 内禁止调用 Foundation/String/DateFormatter，
    /// 这些都不是 async-signal-safe 的，可能在处理崩溃时二次死锁）
    private static var signalCrashPath: [CChar] = []

    private static func prepareSignalCrashFile() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ATMusicLogs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        signalCrashPath = Array(dir.appendingPathComponent("crash-signal.log").path.utf8CString)
    }

    /// 崩溃信号处理：只用 POSIX open/write/close 落一行信号编号，随后恢复默认并重新抛出，保持系统崩溃行为。
    /// 详细崩溃日志由系统崩溃报告与下次启动的异常退出检测兜底。
    private static let signalHandler: @convention(c) (Int32) -> Void = { sig in
        if !CrashReporter.signalCrashPath.isEmpty {
            let fd = open(CrashReporter.signalCrashPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
            if fd >= 0 {
                var msg: [UInt8] = [99, 114, 97, 115, 104, 32, 115, 105, 103, 110, 97, 108, 61] // "crash signal="
                var digits: [UInt8] = []
                var value = sig
                if value == 0 { digits.append(48) }
                while value > 0 {
                    digits.append(UInt8(48 + value % 10))
                    value /= 10
                }
                msg.append(contentsOf: digits.reversed())
                msg.append(10) // "\n"
                msg.withUnsafeBufferPointer { buf in
                    _ = write(fd, buf.baseAddress, buf.count)
                }
                close(fd)
            }
        }
        signal(sig, SIG_DFL)
        raise(sig)
    }

    /// 崩溃 / 异常内容写入崩溃日志文件（尽量简单，避免依赖过多）
    static func writeCrash(_ text: String) {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ATMusicLogs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let stamp = formatter.string(from: Date())

        let file = dir.appendingPathComponent("crash-\(stamp.replacingOccurrences(of: ":", with: "-")).log")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let device = UIDevice.current.model
        let os = UIDevice.current.systemName + " " + UIDevice.current.systemVersion
        let content = """
        AT Music 崩溃日志
        时间：\(stamp)
        版本：\(version) (build \(build))
        设备：\(device)
        系统：\(os)
        -------------------------
        \(text)
        """
        try? content.data(using: .utf8)?.write(to: file, options: .atomic)

        // 同时写入 App 内日志，便于直接查看与反馈排查
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let firstLine = lines.first ?? text
        let reasonLine = lines.first(where: { $0.hasPrefix("reason:") })
        let summary = [firstLine, reasonLine].compactMap { $0 }.joined(separator: " | ")
        ATMusicLogger.shared.log("检测到崩溃/异常：\(summary)", level: .error)
        for line in lines.dropFirst().prefix(15) {
            ATMusicLogger.shared.log(line, level: .error)
        }
    }
}
