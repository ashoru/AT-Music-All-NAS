import SwiftUI

// MARK: - 播放器 UI 自由调整（x / y / 大小）

/// 可自由调整的播放器组件
enum PlayerLayoutPart: String, CaseIterable, Identifiable {
    case topBack = "返回"
    case topTitle = "顶部标题"
    case topFavorite = "收藏"
    case cover = "封面"
    case title = "歌名"
    case previewLyric = "预览歌词"
    case vinylAlbum = "黑胶播放器"
    /// 保留旧的整体黑胶歌词布局键，用于兼容已保存的用户设置。
    case vinylLyric = "黑胶歌词"
    case vinylLyricsHeader = "黑胶歌词顶部"
    case vinylLyricsText = "黑胶歌词文字"
    case progress = "进度条"
    case controls = "控制行"
    case loop = "循环按钮"
    case previous = "上一首"
    case playPause = "播放暂停"
    case next = "下一首"
    case queue = "播放列表"
    case lyric = "歌词"
    case grabber = "指示线"

    var id: String { rawValue }

    /// 黑胶歌词现在拆成顶部信息和歌词文字两个独立组件，旧整体项不再显示在编辑器中。
    static var editableCases: [PlayerLayoutPart] {
        allCases.filter {
            $0 != .vinylLyric
                && $0 != .vinylAlbum
                && $0 != .vinylLyricsHeader
                && $0 != .vinylLyricsText
        }
    }
}

/// Apple Music 播放页实时调试组件。
enum AppleMusicLayoutPart: String, CaseIterable, Identifiable {
    case top = "顶部指示线"
    case cover = "封面"
    case title = "歌名歌手"
    case previewLyric = "预览歌词"
    case progress = "进度条"
    case previous = "上一首"
    case play = "播放按钮"
    case next = "下一首"
    case volume = "音量条"
    case actions = "底部按钮"

    var id: String { rawValue }
}

/// 单个组件的自定义位置（相对默认位置的偏移）、缩放、旋转和透明度。
/// 新字段使用默认值解码，兼容旧版本已经保存的布局。
struct PlayerLayoutEntry: Codable, Equatable {
    var x: CGFloat = 0
    var y: CGFloat = 0
    /// 组件大小缩放（1 为原始大小）
    var scale: CGFloat = 1
    /// 组件旋转角度
    var rotation: CGFloat = 0
    /// 组件透明度（0...1）
    var opacity: CGFloat = 1

    init(x: CGFloat = 0, y: CGFloat = 0, scale: CGFloat = 1, rotation: CGFloat = 0, opacity: CGFloat = 1) {
        self.x = x
        self.y = y
        self.scale = scale
        self.rotation = rotation
        self.opacity = opacity
    }

    /// 兼容旧存档（老版本没有 scale 字段，缺省为 1）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decodeIfPresent(CGFloat.self, forKey: .x) ?? 0
        y = try c.decodeIfPresent(CGFloat.self, forKey: .y) ?? 0
        scale = try c.decodeIfPresent(CGFloat.self, forKey: .scale) ?? 1
        rotation = try c.decodeIfPresent(CGFloat.self, forKey: .rotation) ?? 0
        opacity = try c.decodeIfPresent(CGFloat.self, forKey: .opacity) ?? 1
    }
}

/// 播放器底部布局调整存储（UserDefaults JSON，持久化）
enum PlayerLayoutStore {
    static let modeKey = "atmusic.playerLayoutMode"
    /// 旧版本经典/唱片共用的数据键，仅用于首次迁移。
    private static let legacyDataKey = "atmusic.playerLayoutData"
    private static let classicDataKey = "atmusic.playerLayoutData.classic"
    private static let vinylDataKey = "atmusic.playerLayoutData.vinyl"
    private static let immersiveDataKey = "atmusic.playerLayoutData.immersive"
    private static var pendingSaves: [String: DispatchWorkItem] = [:]

    private static func storageKey(for style: ATMusicCoverPlayerStyle) -> String {
        switch style {
        case .vinyl: return vinylDataKey
        case .classic, .appleMusic: return classicDataKey
        case .immersive: return immersiveDataKey
        }
    }

    /// 经典封面与唱片模式分别持久化，避免两个主题调整同名组件时互相覆盖。
    /// 第一次升级时会从旧的共用布局复制一份作为各自初始值。
    static func load(for style: ATMusicCoverPlayerStyle = .classic) -> [String: PlayerLayoutEntry] {
        let key = storageKey(for: style)
        let defaults = UserDefaults.standard
        let raw = defaults.string(forKey: key) ?? defaults.string(forKey: legacyDataKey)
        guard let raw,
              let data = raw.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: PlayerLayoutEntry].self, from: data) else {
            return [:]
        }

        var migrated = dict
        var needsSave = defaults.string(forKey: key) == nil

        // 唱片模式历史默认值迁移只作用于唱片自己的布局，不再污染经典封面。
        if style == .vinyl {
            if migrated[PlayerLayoutPart.vinylAlbum.rawValue] == PlayerLayoutEntry(x: 0, y: -8, scale: 1)
                || migrated[PlayerLayoutPart.vinylAlbum.rawValue] == PlayerLayoutEntry(x: 0, y: -56, scale: 1)
                || migrated[PlayerLayoutPart.vinylAlbum.rawValue] == PlayerLayoutEntry() {
                migrated[PlayerLayoutPart.vinylAlbum.rawValue] = PlayerLayoutEntry(x: 0, y: 20, scale: 1)
                needsSave = true
            }
            if migrated[PlayerLayoutPart.vinylLyric.rawValue] == PlayerLayoutEntry(x: 0, y: -10, scale: 1)
                || migrated[PlayerLayoutPart.vinylLyric.rawValue] == PlayerLayoutEntry(x: -2, y: -56, scale: 1) {
                migrated[PlayerLayoutPart.vinylLyric.rawValue] = PlayerLayoutEntry()
                needsSave = true
            }
            if migrated[PlayerLayoutPart.vinylLyricsHeader.rawValue] == nil,
               migrated[PlayerLayoutPart.vinylLyricsText.rawValue] == nil {
                let legacy = migrated[PlayerLayoutPart.vinylLyric.rawValue] ?? PlayerLayoutEntry()
                migrated[PlayerLayoutPart.vinylLyricsHeader.rawValue] = legacy
                migrated[PlayerLayoutPart.vinylLyricsText.rawValue] = legacy
                migrated.removeValue(forKey: PlayerLayoutPart.vinylLyric.rawValue)
                needsSave = true
            }
        }

        if needsSave {
            saveImmediately(migrated, for: style)
        }
        return migrated
    }

    static func save(_ dict: [String: PlayerLayoutEntry], for style: ATMusicCoverPlayerStyle = .classic) {
        let key = storageKey(for: style)
        pendingSaves[key]?.cancel()
        let snapshot = dict
        // 先把内存快照广播给正在显示的真实播放页，编辑器滑杆移动时立即刷新。
        NotificationCenter.default.post(
            name: .atmusicPlayerLayoutDidChange,
            object: nil,
            userInfo: ["style": style.rawValue, "data": snapshot]
        )
        let work = DispatchWorkItem {
            guard let data = try? JSONEncoder().encode(snapshot),
                  let raw = String(data: data, encoding: .utf8) else { return }
            UserDefaults.standard.set(raw, forKey: key)
        }
        pendingSaves[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    static func saveImmediately(_ dict: [String: PlayerLayoutEntry], for style: ATMusicCoverPlayerStyle = .classic) {
        let key = storageKey(for: style)
        pendingSaves[key]?.cancel()
        if let data = try? JSONEncoder().encode(dict),
           let raw = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(raw, forKey: key)
        }
        NotificationCenter.default.post(
            name: .atmusicPlayerLayoutDidChange,
            object: nil,
            userInfo: ["style": style.rawValue, "data": dict]
        )
    }

    static func reset(for style: ATMusicCoverPlayerStyle = .classic) {
        let key = storageKey(for: style)
        pendingSaves[key]?.cancel()
        UserDefaults.standard.removeObject(forKey: key)
        NotificationCenter.default.post(
            name: .atmusicPlayerLayoutDidChange,
            object: nil,
            userInfo: ["style": style.rawValue, "data": [String: PlayerLayoutEntry]()]
        )
    }

    /// 各播放器风格自己的参考基线。真实播放页与布局编辑器都只从这里取默认值。
    static func defaultEntry(for part: PlayerLayoutPart, style: ATMusicCoverPlayerStyle = .classic) -> PlayerLayoutEntry {
        if style == .immersive {
            return PlayerLayoutEntry(x: 0, y: 0, scale: 1)
        }
        if style == .vinyl {
            switch part {
            case .vinylAlbum:
                return PlayerLayoutEntry(x: 0, y: 20, scale: 1)
            case .title:
                return PlayerLayoutEntry(x: 0, y: 0, scale: 1)
            case .vinylLyric:
                return PlayerLayoutEntry()
            case .vinylLyricsHeader:
                return PlayerLayoutEntry(x: 0, y: 30, scale: 1)
            case .vinylLyricsText:
                return PlayerLayoutEntry(x: 0, y: -52, scale: 1)
            case .progress:
                return PlayerLayoutEntry(x: 0, y: -10, scale: 1)
            case .controls:
                return PlayerLayoutEntry(x: 0, y: 0, scale: 1.04)
            case .queue:
                return PlayerLayoutEntry(x: 0, y: 0, scale: 1)
            default:
                return PlayerLayoutEntry()
            }
        }

        // 经典封面参考基线：按参考图缩小圆形封面，标题/歌词紧跟主体，控制区留在底部。
        switch part {
        case .topBack, .topTitle, .topFavorite:
            return PlayerLayoutEntry(x: 0, y: 0, scale: 1)
        case .cover:
            return PlayerLayoutEntry(x: 0, y: 0, scale: 1)
        case .title:
            return PlayerLayoutEntry(x: 0, y: -4, scale: 1)
        case .previewLyric:
            return PlayerLayoutEntry(x: 0, y: -6, scale: 0.96)
        case .vinylAlbum, .vinylLyric, .vinylLyricsHeader, .vinylLyricsText:
            return PlayerLayoutEntry()
        case .progress:
            return PlayerLayoutEntry(x: 0, y: 10, scale: 1)
        case .controls:
            return PlayerLayoutEntry(x: 0, y: 8, scale: 1.02)
        case .loop:
            return PlayerLayoutEntry(x: -4, y: 0, scale: 1.04)
        case .playPause:
            return PlayerLayoutEntry(x: 0, y: 0, scale: 1)
        case .queue:
            return PlayerLayoutEntry(x: 4, y: 0, scale: 1.04)
        case .previous, .next:
            return PlayerLayoutEntry(x: 0, y: 0, scale: 1)
        case .grabber:
            return PlayerLayoutEntry(x: 0, y: 27, scale: 0.7)
        case .lyric:
            return PlayerLayoutEntry(x: 0, y: 0, scale: 1)
        }
    }
}

/// Apple Music 播放页布局存储。
final class AppleMusicLayoutStore: ObservableObject {
    static let shared = AppleMusicLayoutStore()

    private static let dataKey = "atmusic.appleMusic.layoutData"
    private let defaults = UserDefaults.standard

    @Published var entries: [String: PlayerLayoutEntry] {
            didSet { scheduleSave() }
    }

    private init() {
        if let raw = defaults.string(forKey: Self.dataKey),
           let data = raw.data(using: .utf8),
           let stored = try? JSONDecoder().decode([String: PlayerLayoutEntry].self, from: data) {
            var normalized = stored
            if normalized[AppleMusicLayoutPart.top.rawValue] == PlayerLayoutEntry() {
                normalized[AppleMusicLayoutPart.top.rawValue] = Self.defaultEntry(for: .top)
            }
            entries = normalized
            if normalized != stored {
                save(normalized)
            }
        } else {
            entries = Self.migrateLegacyEntries(from: defaults)
        }
    }

    func entry(for part: AppleMusicLayoutPart) -> PlayerLayoutEntry {
        entries[part.rawValue] ?? Self.defaultEntry(for: part)
    }

    func set(_ entry: PlayerLayoutEntry, for part: AppleMusicLayoutPart) {
        entries[part.rawValue] = entry
    }

    func reset(_ part: AppleMusicLayoutPart) {
        entries[part.rawValue] = nil
    }

    func resetAll() {
        entries = [:]
    }

    private var pendingSave: DispatchWorkItem?

    private func scheduleSave() {
        pendingSave?.cancel()
        let snapshot = entries
        let work = DispatchWorkItem { [weak self] in
            self?.save(snapshot)
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func save(_ snapshot: [String: PlayerLayoutEntry]) {
        guard let data = try? JSONEncoder().encode(snapshot),
              let raw = String(data: data, encoding: .utf8) else {
            return
        }
        defaults.set(raw, forKey: Self.dataKey)
    }

    static func defaultEntry(for part: AppleMusicLayoutPart) -> PlayerLayoutEntry {
        switch part {
        case .top:
            return PlayerLayoutEntry(y: -63)
        case .cover:
            return PlayerLayoutEntry(x: 0, y: 0, scale: 1)
        case .title:
            return PlayerLayoutEntry(x: 0, y: -2, scale: 1)
        case .previewLyric:
            return PlayerLayoutEntry(x: 0, y: -4, scale: 0.98)
        case .progress:
            return PlayerLayoutEntry(x: 0, y: 0, scale: 1)
        case .previous, .play, .next:
            return PlayerLayoutEntry(x: 0, y: 0, scale: 1)
        case .volume:
            return PlayerLayoutEntry(x: 0, y: 0, scale: 1)
        case .actions:
            return PlayerLayoutEntry(x: 0, y: 0, scale: 1)
        }
    }

    private static func migrateLegacyEntries(from defaults: UserDefaults) -> [String: PlayerLayoutEntry] {
        var migrated: [String: PlayerLayoutEntry] = [:]

        func legacyDouble(_ key: String, defaultValue: Double) -> CGFloat {
            guard defaults.object(forKey: key) != nil else { return CGFloat(defaultValue) }
            return CGFloat(defaults.double(forKey: key))
        }

        migrated[AppleMusicLayoutPart.top.rawValue] = PlayerLayoutEntry(
            y: legacyDouble("atmusic.appleMusic.topY", defaultValue: -63)
        )
        migrated[AppleMusicLayoutPart.cover.rawValue] = PlayerLayoutEntry(
            scale: legacyDouble("atmusic.appleMusic.coverScale", defaultValue: 1)
        )
        migrated[AppleMusicLayoutPart.title.rawValue] = PlayerLayoutEntry(
            y: legacyDouble("atmusic.appleMusic.titleY", defaultValue: 0)
        )
        migrated[AppleMusicLayoutPart.previewLyric.rawValue] = PlayerLayoutEntry(
            y: legacyDouble("atmusic.appleMusic.lyricY", defaultValue: 0)
        )
        let legacyControls = PlayerLayoutEntry(
            y: legacyDouble("atmusic.appleMusic.controlsY", defaultValue: 0)
        )
        migrated[AppleMusicLayoutPart.previous.rawValue] = legacyControls
        migrated[AppleMusicLayoutPart.play.rawValue] = legacyControls
        migrated[AppleMusicLayoutPart.next.rawValue] = legacyControls
        migrated[AppleMusicLayoutPart.actions.rawValue] = PlayerLayoutEntry(
            y: legacyDouble("atmusic.appleMusic.actionsY", defaultValue: 0)
        )
        return migrated
    }
}

/// 仅负责应用 Apple Music 组件的实时位置和大小。
struct AppleMusicLayoutTransform: ViewModifier {
    let entry: PlayerLayoutEntry

    func body(content: Content) -> some View {
        content
            .scaleEffect(entry.scale)
            .rotationEffect(.degrees(Double(entry.rotation)))
            .offset(x: entry.x, y: entry.y)
            .opacity(Double(min(max(entry.opacity, 0), 1)))
    }
}

/// 让组件可自由拖动并应用自定义位置与大小（x / y 偏移 + scale 缩放）
struct Layoutable: ViewModifier {
    let part: PlayerLayoutPart
    /// 编辑模式开关：开启时可拖动，未开启时完全无影响
    let enabled: Bool
    /// 布局数据（双向绑定，实时保存）
    @Binding var data: [String: PlayerLayoutEntry]
    var style: ATMusicCoverPlayerStyle = .classic

    func body(content: Content) -> some View {
        let entry = data[part.rawValue] ?? PlayerLayoutStore.defaultEntry(for: part, style: style)
        content
            .scaleEffect(entry.scale)
            .rotationEffect(.degrees(Double(entry.rotation)))
            .offset(x: entry.x, y: entry.y)
            .opacity(Double(min(max(entry.opacity, 0), 1)))
            .gesture(
                enabled
                    ? DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            var e = data[part.rawValue] ?? PlayerLayoutStore.defaultEntry(for: part, style: style)
                            e.x = value.translation.width
                            e.y = value.translation.height
                            data[part.rawValue] = e
                        }
                    : nil
            )
    }
}
