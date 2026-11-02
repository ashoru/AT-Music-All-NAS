import Foundation
import SwiftUI

// MARK: - 日志级别

enum ATMusicLogLevel: String, CaseIterable {
    case debug = "DEBUG"
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"

    var tint: Color {
        switch self {
        case .debug: return .secondary
        case .info: return .blue
        case .warn: return .orange
        case .error: return .red
        }
    }
}

// MARK: - 单条日志

struct ATMusicLogEntry: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let level: ATMusicLogLevel
    let message: String
}

// MARK: - 全局日志中心

/// 全局日志中心：内存环形缓存（供 App 内查看）+ 文件持久化（Documents/ATMusicLogs/atmusic-日期.log，可导出分享）。
/// 任意线程可调用 log()，自动执行敏感凭据脱敏，界面更新自动切回主线程。
final class ATMusicLogger: ObservableObject {
    static let shared = ATMusicLogger()

    @Published private(set) var entries: [ATMusicLogEntry] = []

    private let maxEntries = 5000
    private let maxLogFileBytes = 10 * 1024 * 1024
    /// 日志保留上限：只保留最近 72 小时
    private let maxLogAge: TimeInterval = 72 * 3600
    private let lock = NSLock()
    private var recentEntries: [ATMusicLogEntry] = []
    private var lastPruneDate = Date.distantPast

    private static let lineFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
    private static let fileStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        return f
    }()

    private init() {
        log("AT Music 启动（版本 \(Self.appVersion)）", level: .info)
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    static func dateString(_ date: Date) -> String {
        lineFormatter.string(from: date)
    }

    /// 记录一条日志（任意线程可调用，自动执行敏感机密信息脱敏）
    func log(_ message: String, level: ATMusicLogLevel = .debug) {
        let cleanMessage = ATMusicLogSanitizer.sanitize(message)
        let entry = ATMusicLogEntry(date: Date(), level: level, message: cleanMessage)
        lock.lock()
        recentEntries.append(entry)
        if recentEntries.count > maxEntries {
            recentEntries.removeFirst(recentEntries.count - maxEntries)
        }
        // 只保留最近 12 小时（按时间正序追加，直接从头部剔除过期条目）
        let cutoff = Date().addingTimeInterval(-maxLogAge)
        while let first = recentEntries.first, first.date < cutoff {
            recentEntries.removeFirst()
        }
        let snapshot = recentEntries
        let shouldPrune = Date().timeIntervalSince(lastPruneDate) > 60
        if shouldPrune { lastPruneDate = Date() }
        lock.unlock()
        if shouldPrune { pruneOldLogFiles() }
        DispatchQueue.main.async { [weak self] in
            self?.entries = snapshot
        }
        write(entry.line)
    }

    /// 全部日志文本（按时间正序）
    var fullText: String {
        lock.lock()
        let snapshot = recentEntries
        lock.unlock()
        return snapshot.map(\.line).joined(separator: "\n")
    }

    /// 清空内存日志与日志文件
    func clear() {
        lock.lock()
        recentEntries = []
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.entries = []
        }
        try? FileManager.default.removeItem(at: logDirectory)
        log("日志已清空", level: .info)
    }

    // MARK: - 12 小时上限裁剪

    /// 删除超 12 小时的旧日志文件，并裁掉保留文件里超 12 小时的行（最多 60 秒执行一次）
    private func pruneOldLogFiles() {
        let cutoff = Date().addingTimeInterval(-maxLogAge)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: nil) else { return }
        let keepSinceDay = Calendar.current.startOfDay(for: cutoff)
        for url in files {
            let name = url.lastPathComponent
            guard name.hasPrefix("atmusic-"), name.hasSuffix(".log") else { continue }
            // 文件名 atmusic-YYYYMMDD.log / atmusic-YYYYMMDD.1.log，解析日期
            let stamp = name.dropFirst("atmusic-".count).prefix(8)
            if let day = Self.fileStampFormatter.date(from: String(stamp)) {
                if day < keepSinceDay {
                    try? fm.removeItem(at: url)
                    continue
                }
            }
            trimLines(olderThan: cutoff, in: url)
        }
    }

    /// 裁掉单个日志文件里早于 cutoff 的行（行首时间戳 [yyyy-MM-dd HH:mm:ss.SSS]）
    private func trimLines(olderThan cutoff: Date, in url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var firstKeep = lines.count
        for (i, line) in lines.enumerated() {
            // 行首 "[yyyy-MM-dd HH:mm:ss.SSS]"，取日期部分比较
            guard line.count > 21, line.first == "[" else { continue }
            let stamp = String(line.dropFirst().prefix(19)) // yyyy-MM-dd HH:mm:ss
            var comps = DateComponents()
            let parts = stamp.split(separator: " ")
            guard parts.count == 2 else { continue }
            let d = parts[0].split(separator: "-").compactMap { Int($0) }
            let t = parts[1].split(separator: ":").compactMap { Int($0) }
            guard d.count == 3, t.count == 3 else { continue }
            comps.year = d[0]; comps.month = d[1]; comps.day = d[2]
            comps.hour = t[0]; comps.minute = t[1]; comps.second = t[2]
            if let date = Calendar.current.date(from: comps), date >= cutoff {
                firstKeep = i
                break
            }
        }
        guard firstKeep > 0, firstKeep < lines.count else { return }
        let kept = lines[firstKeep...].joined(separator: "\n")
        try? kept.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - 文件持久化

    private var logDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ATMusicLogs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var currentFileURL: URL {
        logDirectory.appendingPathComponent("atmusic-\(Self.fileStampFormatter.string(from: Date())).log")
    }

    /// 导出日志文件（不存在则先生成一份完整日志）
    func exportLogURL() -> URL {
        let url = currentFileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? fullText.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    private func write(_ line: String) {
        let url = currentFileURL
        // 单日日志过大时轮转到 .1，避免无限膨胀
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        if fileSize > maxLogFileBytes {
            let rotated = url.deletingPathExtension().appendingPathExtension("1.log")
            try? FileManager.default.removeItem(at: rotated)
            try? FileManager.default.moveItem(at: url, to: rotated)
        }
        let payload = (line + "\n").data(using: .utf8) ?? Data()
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(payload)
        } else {
            try? payload.write(to: url, options: .atomic)
        }
    }
}

extension ATMusicLogEntry {
    var line: String {
        "[\(ATMusicLogger.dateString(date))] [\(level.rawValue)] \(message)"
    }
}
