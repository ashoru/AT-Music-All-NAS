import Foundation

// MARK: - NAS 音乐库索引控制

/// 索引状态快照（对外只暴露三件事：能不能扫、扫到哪了、出了什么问题）。
struct NASReindexSnapshot {
    enum Phase {
        case unknown        // 还没探测
        case unsupported    // 该 DSM 没有可用的索引接口
        case idle           // 接口可用，当前没在扫
        case scanning
        case finished
        case failed
    }

    var phase: Phase = .unknown
    var percent: Int?
    var detail: String = ""

    var isScanning: Bool { phase == .scanning }
    var canTrigger: Bool { phase == .idle || phase == .finished || phase == .failed }

    var title: String {
        switch phase {
        case .unknown: return "未检测"
        case .unsupported: return "该 DSM 不支持 App 内触发"
        case .idle: return "空闲"
        case .scanning: return percent.map { "正在扫描 \($0)%" } ?? "正在扫描"
        case .finished: return "上次扫描已完成"
        case .failed: return "扫描失败"
        }
    }
}

/// Audio Station 的「重新索引」并没有稳定公开的接口名：不同 DSM 版本可能叫
/// `SYNO.AudioStation.Reindex`，也可能只有媒体索引服务。这里的做法是
/// 先用 `SYNO.API.Info` 把服务器实际开放的能力列出来，命中才显示开关，
/// 不命中就明确降级为「刷新曲库缓存」，绝不给用户一个按了没反应的按钮。
@MainActor
final class NASIndexController: ObservableObject {
    static let shared = NASIndexController()

    static let lastFinishedKey = "atmusic.nas.index.lastFinishedAt"

    @Published private(set) var snapshot = NASReindexSnapshot()
    @Published private(set) var isBusy = false
    /// 探测到的可用接口名（例如 SYNO.AudioStation.Reindex），供日志与设置页展示。
    @Published private(set) var resolvedAPI: String?

    private var discovered: [String: [String: Any]] = [:]
    private var pollTask: Task<Void, Never>?
    private var didProbe = false

    private init() {
        if let saved = UserDefaults.standard.object(forKey: Self.lastFinishedKey) as? Date {
            snapshot.phase = .idle
            snapshot.detail = "上次完成：\(Self.formatter.string(from: saved))"
        }
    }

    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    var lastFinishedText: String? {
        guard let saved = UserDefaults.standard.object(forKey: Self.lastFinishedKey) as? Date else { return nil }
        return Self.formatter.string(from: saved)
    }

    // MARK: 探测

    func probeIfNeeded(force: Bool = false) async {
        if didProbe && !force { return }
        guard SynologyAPI.shared.isLoggedIn else {
            snapshot = NASReindexSnapshot(phase: .unknown, percent: nil, detail: "尚未连接 NAS")
            return
        }
        isBusy = true
        defer { isBusy = false }
        didProbe = true

        let catalog = await Self.apiCatalog()
        let candidates = Self.indexCandidates(in: catalog)
        discovered = candidates
        if let first = candidates.keys.sorted().first {
            resolvedAPI = first
            snapshot = NASReindexSnapshot(phase: .idle, percent: nil, detail: "可用接口：\(first)")
            ATMusicLogger.shared.log("🗂 NAS 索引接口可用：\(candidates.keys.sorted().joined(separator: ", "))", level: .info)
        } else {
            resolvedAPI = nil
            snapshot = NASReindexSnapshot(
                phase: .unsupported,
                percent: nil,
                detail: "该 DSM 未开放索引接口，可用「刷新曲库缓存」替代（Audio Station 也会按自己的周期扫描）"
            )
            ATMusicLogger.shared.log("🗂 NAS 未发现索引接口，已降级为本地缓存刷新", level: .warn)
        }
    }

    // MARK: 触发 / 停止 / 查状态

    func start() async {
        await probeIfNeeded()
        guard snapshot.phase != .unsupported else { return }
        guard let api = resolvedAPI, let info = discovered[api] else { return }
        isBusy = true
        do {
            try await Self.callIndexAPI(api: api, info: info, method: "start")
            snapshot = NASReindexSnapshot(phase: .scanning, percent: 0, detail: "已提交扫描任务")
            ATMusicLogger.shared.log("🗂 已触发 NAS 音乐库重新扫描（\(api)）", level: .info)
            startPolling()
        } catch {
            snapshot = NASReindexSnapshot(phase: .failed, percent: nil, detail: error.localizedDescription)
            ATMusicLogger.shared.log("⚠️ 触发 NAS 扫描失败：\(error.localizedDescription)", level: .error)
        }
        isBusy = false
    }

    func stop() async {
        pollTask?.cancel()
        pollTask = nil
        guard let api = resolvedAPI, let info = discovered[api] else { return }
        _ = try? await Self.callIndexAPI(api: api, info: info, method: "stop")
        snapshot = NASReindexSnapshot(phase: .idle, percent: nil, detail: "已手动停止扫描")
    }

    func refreshStatusOnce() async {
        guard let api = resolvedAPI, let info = discovered[api] else { return }
        await poll(api: api, info: info)
    }

    private func startPolling() {
        pollTask?.cancel()
        guard let api = resolvedAPI, let info = discovered[api] else { return }
        pollTask = Task { [weak self] in
            for _ in 0..<240 {
                if Task.isCancelled { return }
                await self?.poll(api: api, info: info)
                let phase = await self?.snapshot.phase
                if phase == .finished || phase == .failed || phase == .idle { return }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func poll(api: String, info: [String: Any]) async {
        guard let json = try? await Self.callIndexAPI(api: api, info: info, method: "status") else { return }
        let data = json["data"] as? [String: Any] ?? json
        let percent = Self.intValue(data["progress"])
            ?? Self.intValue(data["percent"])
            ?? Self.intValue(data["percentage"])
        let finished = (data["finished"] as? Bool)
            ?? (data["done"] as? Bool)
            ?? (data["is_finishing"] as? Bool)
            ?? false
        let running = (data["running"] as? Bool)
            ?? (data["is_scanning"] as? Bool)
            ?? (data["scanning"] as? Bool)
            ?? !finished

        if finished || (!running && (percent ?? 0) >= 100) {
            snapshot = NASReindexSnapshot(phase: .finished, percent: 100, detail: "扫描完成")
            UserDefaults.standard.set(Date(), forKey: Self.lastFinishedKey)
            SynologyAPI.shared.clearLibraryCache()
            SynologyAPI.shared.invalidateAllFolderCaches()
            SynologyAPI.shared.bumpLibraryIndexRevision()
            ATMusicLogger.shared.log("🗂 NAS 音乐库扫描完成，已刷新本地索引", level: .info)
            return
        }
        snapshot = NASReindexSnapshot(
            phase: running ? .scanning : .idle,
            percent: percent,
            detail: running ? "Audio Station 正在扫描新增/改动的文件" : "等待扫描任务"
        )
    }

    /// 接口不可用时的降级动作：只刷新 App 侧缓存，并说明 NAS 端会自己扫描。
    func refreshLocalLibraryCache() {
        SynologyAPI.shared.clearLibraryCache()
        SynologyAPI.shared.invalidateAllFolderCaches()
        SynologyAPI.shared.bumpLibraryIndexRevision()
        snapshot = NASReindexSnapshot(
            phase: snapshot.phase == .unknown ? .unsupported : snapshot.phase,
            percent: snapshot.percent,
            detail: "已刷新 App 曲库缓存（NAS 端索引仍需 Audio Station 自行完成）"
        )
        ATMusicLogger.shared.log("🗂 已手动刷新 NAS 曲库本地缓存", level: .info)
    }

    // MARK: 底层

    private static func callIndexAPI(api: String, info: [String: Any], method: String) async throws -> [String: Any] {
        let path = (info["path"] as? String).map { $0.hasPrefix("/") ? $0 : "/webapi/" + $0 } ?? "/webapi/entry.cgi"
        let version = String(intValue(info["maxVersion"]) ?? intValue(info["minVersion"]) ?? 1)
        var form: [String: String] = [
            "api": api,
            "version": version,
            "method": method
        ]
        if api.contains("AudioStation") {
            form["library"] = "all"
        }
        return try await SynologyAPI.shared.postForm(path, form: form, authenticated: true, acceptsMissingSuccess: true)
    }

    private static func apiCatalog() async -> [String: [String: Any]] {
        do {
            let json = try await SynologyAPI.shared.get(
                "/webapi/query.cgi",
                query: [
                    URLQueryItem(name: "api", value: "SYNO.API.Info"),
                    URLQueryItem(name: "version", value: "1"),
                    URLQueryItem(name: "method", value: "query"),
                    URLQueryItem(name: "query", value: "all")
                ],
                authenticated: false
            )
            let data = json["data"] as? [String: Any] ?? [:]
            var result: [String: [String: Any]] = [:]
            for (key, value) in data {
                if let dict = value as? [String: Any] { result[key] = dict }
            }
            return result
        } catch {
            ATMusicLogger.shared.log("⚠️ 读取 NAS 能力清单失败：\(error.localizedDescription)", level: .warn)
            return [:]
        }
    }

    /// 只挑「索引/重新扫描」类接口，避免抓到 SYNO.AudioStation.Song 这类普通查询接口。
    private static func indexCandidates(in catalog: [String: [String: Any]]) -> [String: [String: Any]] {
        let wanted: Set<String> = [
            "SYNO.AudioStation.Reindex",
            "SYNO.AudioStation.Index",
            "SYNO.AudioStation.Rescan",
            "SYNO.MediaIndexing"
        ]
        var result: [String: [String: Any]] = [:]
        for (key, value) in catalog {
            if wanted.contains(key) {
                result[key] = value
            } else if key.lowercased().contains("reindex") {
                result[key] = value
            }
        }
        return result
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let value = any as? Int { return value }
        if let value = any as? Double { return Int(value) }
        if let value = any as? String { return Int(value) }
        return nil
    }
}
