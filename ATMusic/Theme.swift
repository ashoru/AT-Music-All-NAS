import SwiftUI
import UIKit
import CoreImage

// MARK: - 动态主题色（跟随系统外观或手动切换）

extension UIColor {
    static func atmusicDynamic(light: UIColor, dark: UIColor) -> UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        }
    }

    static let atmusicBackground = atmusicDynamic(
        light: UIColor(red: 0.949, green: 0.949, blue: 0.961, alpha: 1),  // #F2F2F7
        dark: UIColor(red: 0.039, green: 0.039, blue: 0.047, alpha: 1)    // #0A0A0C
    )
    static let atmusicCard = atmusicDynamic(
        light: UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1),
        dark: UIColor(red: 0.110, green: 0.110, blue: 0.118, alpha: 1)    // #1C1C1E
    )
    private static let atmusicDefaultLabel = atmusicDynamic(
        light: UIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1),
        dark: UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1)
    )
    static var atmusicLabel: UIColor {
        if let raw = UserDefaults.standard.string(forKey: "atmusic.labelColorHex"),
           let custom = UIColor(hex: raw) {
            return custom
        }
        return atmusicDefaultLabel
    }
    static let atmusicSecondary = atmusicDynamic(
        light: UIColor(red: 0.424, green: 0.424, blue: 0.439, alpha: 1),  // #6C6C70
        dark: UIColor(red: 0.596, green: 0.596, blue: 0.624, alpha: 1)    // #98989F
    )
    /// 全局着色（跟随配色主题：浅色用深色调保证对比度，深色用亮色调保证可读性）
    static var atmusicAmber: UIColor {
        if let custom = ThemeStore.shared.customAccentHex, let c = UIColor(hex: custom) {
            return atmusicDynamic(light: c.shaded(0.25), dark: c)
        }
        let accent = ThemeStore.shared.accent
        return atmusicDynamic(light: accent.tintLight, dark: accent.tintDark)
    }
    static let atmusicSage = atmusicDynamic(
        light: UIColor(red: 0.384, green: 0.482, blue: 0.310, alpha: 1),
        dark: UIColor(red: 0.560, green: 0.650, blue: 0.480, alpha: 1)
    )
    /// 液态玻璃基底填充：修复 `.glassEffect` 配 `Color.clear` 时玻璃无内容可采样、
    /// 渲染成灰糊块/模糊失效的问题（玻璃效果需要一个非透明基底色）。
    static let atmusicGlassFill = atmusicDynamic(
        light: UIColor(white: 0.96, alpha: 0.55),
        dark: UIColor(white: 0.07, alpha: 0.55)
    )
}

extension Color {
    static let atmusicBackground = Color(uiColor: .atmusicBackground)
    static let atmusicCard = Color(uiColor: .atmusicCard)
    static var atmusicLabel: Color { Color(uiColor: .atmusicLabel) }
    static let atmusicSecondary = Color(uiColor: .atmusicSecondary)

    /// 全局说明文字（注释）颜色：可在「我的 → 外观」中自定义；默认跟随次要文字色
    static var atmusicComment: Color {
        if let raw = UserDefaults.standard.string(forKey: "atmusic.commentColorHex"),
           let c = Color(hex: raw) { return c }
        return .atmusicSecondary
    }
    /// 全局着色：跟随当前配色主题即时变化（所有页面统一生效）
    static var atmusicAmber: Color { Color(uiColor: .atmusicAmber) }
    static let atmusicSage = Color(uiColor: .atmusicSage)
    static let atmusicGlassFill = Color(uiColor: .atmusicGlassFill)
    /// 当前配色主题的高亮色（播放器进度点 / 光斑 / 歌词高亮等）
    static var atmusicHighlight: Color {
        ThemeStore.shared.customAccent ?? AccentTheme.current.highlight
    }
}

// MARK: - 主题偏好

enum ATMusicThemeMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.stars.fill"
        }
    }
}

// MARK: - 壁纸外观目标

enum ATMusicWallpaperAppearance: String, CaseIterable, Identifiable {
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return atmusicLocalized("浅色模式", "Light Mode")
        case .dark: return atmusicLocalized("深色模式", "Dark Mode")
        }
    }

    var colorScheme: ColorScheme {
        switch self {
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - 配色主题（多套配色，可在「我的 → 外观」中切换；全局统一生效）

enum ATMusicAccent: String, CaseIterable, Identifiable {
    // 默认预设使用 AT Music 品牌红；保留原枚举值以便同一版本内部配置稳定。
    case amber = "科技红"
    case mint = "青碧湖绿"
    case pink = "樱粉"
    case sky = "星蓝"
    case violet = "罗兰紫"
    case cyber = "赛博青"
    case peach = "蜜桃粉"
    case gold = "鎏金黑"
    case emerald = "翡翠绿"

    var id: String { rawValue }

    /// 渐变强调色（播放键 / 进度条 / 玻璃光晕）
    var gradientColors: [Color] {
        switch self {
        case .amber:
            return [Color(red: 1.00, green: 0.12, blue: 0.16), Color(red: 0.72, green: 0.01, blue: 0.06)]
        case .mint:
            return [Color(red: 0.42, green: 0.78, blue: 0.62), Color(red: 0.16, green: 0.55, blue: 0.42)]
        case .pink:
            return [Color(red: 0.96, green: 0.56, blue: 0.70), Color(red: 0.82, green: 0.37, blue: 0.56)]
        case .sky:
            return [Color(red: 0.39, green: 0.71, blue: 0.96), Color(red: 0.23, green: 0.48, blue: 0.84)]
        case .violet:
            return [Color(red: 0.70, green: 0.62, blue: 0.86), Color(red: 0.49, green: 0.34, blue: 0.76)]
        case .cyber:
            return [Color(red: 0.25, green: 0.90, blue: 0.85), Color(red: 0.05, green: 0.55, blue: 0.65)]
        case .peach:
            return [Color(red: 1.00, green: 0.62, blue: 0.52), Color(red: 0.95, green: 0.38, blue: 0.55)]
        case .gold:
            return [Color(red: 0.92, green: 0.75, blue: 0.35), Color(red: 0.45, green: 0.33, blue: 0.10)]
        case .emerald:
            return [Color(red: 0.30, green: 0.85, blue: 0.55), Color(red: 0.05, green: 0.50, blue: 0.35)]
        }
    }

    /// 高亮色（渐变首色，用于光斑 / 进度点 / 歌词高亮）
    var highlight: Color {
        gradientColors[0]
    }

    /// 常规着色（图标 / 文字）浅色模式版本：深色调保证浅色背景对比度
    var tintLight: UIColor {
        switch self {
        case .amber: return UIColor(red: 0.80, green: 0.03, blue: 0.07, alpha: 1)   // 科技红
        case .mint: return UIColor(red: 0.15, green: 0.53, blue: 0.39, alpha: 1)    // 深湖绿
        case .pink: return UIColor(red: 0.78, green: 0.33, blue: 0.53, alpha: 1)    // 深樱粉
        case .sky: return UIColor(red: 0.20, green: 0.48, blue: 0.84, alpha: 1)     // 深星蓝
        case .violet: return UIColor(red: 0.46, green: 0.34, blue: 0.77, alpha: 1)  // 深罗兰
        case .cyber: return UIColor(red: 0.05, green: 0.48, blue: 0.55, alpha: 1)     // 深赛博青
        case .peach: return UIColor(red: 0.82, green: 0.32, blue: 0.45, alpha: 1)     // 深蜜桃
        case .gold: return UIColor(red: 0.55, green: 0.40, blue: 0.08, alpha: 1)      // 深鎏金
        case .emerald: return UIColor(red: 0.08, green: 0.45, blue: 0.30, alpha: 1)   // 深翡翠
        }
    }

    /// 常规着色（图标 / 文字）深色模式版本：亮色调保证深色背景对比度
    var tintDark: UIColor {
        switch self {
        case .amber: return UIColor(red: 1.00, green: 0.12, blue: 0.16, alpha: 1)
        case .mint: return UIColor(red: 0.45, green: 0.80, blue: 0.64, alpha: 1)
        case .pink: return UIColor(red: 0.97, green: 0.60, blue: 0.74, alpha: 1)
        case .sky: return UIColor(red: 0.45, green: 0.72, blue: 0.98, alpha: 1)
        case .violet: return UIColor(red: 0.71, green: 0.62, blue: 0.92, alpha: 1)
        case .cyber: return UIColor(red: 0.35, green: 0.95, blue: 0.88, alpha: 1)
        case .peach: return UIColor(red: 1.00, green: 0.68, blue: 0.58, alpha: 1)
        case .gold: return UIColor(red: 0.94, green: 0.80, blue: 0.45, alpha: 1)
        case .emerald: return UIColor(red: 0.42, green: 0.92, blue: 0.62, alpha: 1)
        }
    }
}

// MARK: - 全局 UI 风格

enum ATMusicUIStyle: String, CaseIterable {
    case liquid = "liquid"
    case clear = "clear"
    case compact = "compact"
    case nativeClean = "nativeClean"

    var title: String {
        switch self {
        case .liquid: return "默认液态"
        case .clear: return "磨砂玻璃"
        case .compact: return "紧凑淡雅"
        case .nativeClean: return "Apple 简洁"
        }
    }
}

// MARK: - 播放器按钮样式

enum ATMusicPlayerButtonStyle: String, CaseIterable, Identifiable {
    case glass
    case appleMusic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .glass: return "经典圆形"
        case .appleMusic: return "Apple Music"
        }
    }

    var previewIcon: String {
        switch self {
        case .glass: return "circle"
        case .appleMusic: return "circle.grid.cross"
        }
    }

    var subtitle: String {
        switch self {
        case .glass: return "保留原来的圆形玻璃按钮"
        case .appleMusic: return "深色圆形底座，图标更大更集中"
        }
    }

    /// 各播放器样式独立的按钮风格存储 key（Apple Music 风格天生无圆圈，不需要）
    static func storageKey(for playerStyle: ATMusicCoverPlayerStyle) -> String {
        "atmusic.playerButtonStyle.\(playerStyle.rawValue)"
    }

    /// 读取某播放器样式的按钮风格
    static func current(for playerStyle: ATMusicCoverPlayerStyle) -> ATMusicPlayerButtonStyle {
        let raw = UserDefaults.standard.string(forKey: storageKey(for: playerStyle))
        return ATMusicPlayerButtonStyle(rawValue: raw ?? "") ?? .appleMusic
    }
}

// MARK: - 播放器浮尘样式

enum ATMusicPlayerDustMode: String, CaseIterable, Identifiable {
    case off
    case snow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "关闭"
        case .snow: return "动态浮尘"
        }
    }

    var icon: String {
        switch self {
        case .off: return "circle.slash"
        case .snow: return "sparkles"
        }
    }
}

// MARK: - 播放器封面页样式

enum ATMusicCoverPlayerStyle: String, CaseIterable, Identifiable {
    case classic
    case appleMusic
    case vinyl
    case immersive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: return "经典封面"
        case .appleMusic: return "Apple Music"
        case .vinyl: return atmusicLocalized("唱片模式", "Record Mode")
        case .immersive: return "沉浸式专辑"
        }
    }

    var subtitle: String {
        switch self {
        case .classic: return "封面、歌名和预览歌词分层显示"
        case .appleMusic: return "大封面、细进度条和简洁播放控制"
        case .vinyl: return atmusicLocalized("参考唱片界面、歌词、队列和播放控制", "Record-style lyrics, queue, and playback controls")
        case .immersive: return "全宽 1:1 封面铺满全屏，极简无边框设计"
        }
    }

    var icon: String {
        switch self {
        case .classic: return "square.stack"
        case .appleMusic: return "music.note.list"
        case .vinyl: return "opticaldisc"
        case .immersive: return "rectangle.expand.vertical"
        }
    }
}

// MARK: - 全局主题（ObservableObject：一处修改，全 App 即时联动）

final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    /// 当前配色主题（@Published：切换后所有观察视图立即重绘）
    @Published var accent: ATMusicAccent
    /// 自定义全局强调色（色盘任选，nil 表示使用预设主题）
    @Published var customAccentHex: String?
    /// 自定义背景色（浅色/深色分别保存，未设置的一侧回退到另一侧）
    @Published private(set) var backgroundHexLight: String = ""
    @Published private(set) var backgroundHexDark: String = ""
    /// 自定义背景是否同步到搜索 / 音乐库 / 我的等全部页面
    @Published var backgroundSyncAll = true
    /// 当前使用的背景图片文件路径（兼容旧调用；按当前系统外观返回有效路径）
    var backgroundImagePath: String {
        backgroundImagePath(for: Self.currentColorScheme)
    }
    /// 浅色/深色分别使用的壁纸路径；未设置的一侧自动使用另一侧。
    @Published private(set) var backgroundImagePathLight: String = ""
    @Published private(set) var backgroundImagePathDark: String = ""
    /// 壁纸库：所有已上传壁纸的文件路径
    @Published var wallpaperPaths: [String] = []
    /// 全局 UI 风格：影响玻璃容器、卡片透明度与边框质感
    @Published var uiStyle: ATMusicUIStyle = .liquid

    private let customAccentKey = "atmusic.accent.custom"
    private let backgroundKey = "atmusic.background.custom"
    private let backgroundLightKey = "atmusic.background.custom.light"
    private let backgroundDarkKey = "atmusic.background.custom.dark"
    private let syncAllKey = "atmusic.background.syncAll"
    private let backgroundImageKey = "atmusic.background.image"
    private let backgroundImageLightKey = "atmusic.background.image.light"
    private let backgroundImageDarkKey = "atmusic.background.image.dark"
    private let wallpaperListKey = "atmusic.wallpapers.list"
    private let wallpaperDataKey = "atmusic.wallpapers.data"
    private let deletedKey = "atmusic.wallpapers.deleted"
    private let uiStyleKey = "atmusic.uiStyle"
    private var wallpapersRestored = false

    private init() {
        accent = ATMusicAccent(rawValue: UserDefaults.standard.string(forKey: AccentTheme.key) ?? "") ?? .amber
        let savedAccent = UserDefaults.standard.string(forKey: customAccentKey)
        customAccentHex = (savedAccent?.isEmpty ?? true) ? nil : savedAccent
        let legacyBackground = UserDefaults.standard.string(forKey: backgroundKey) ?? ""
        let hasSplitBackground = UserDefaults.standard.object(forKey: backgroundLightKey) != nil
            || UserDefaults.standard.object(forKey: backgroundDarkKey) != nil
        if hasSplitBackground {
            backgroundHexLight = UserDefaults.standard.string(forKey: backgroundLightKey) ?? ""
            backgroundHexDark = UserDefaults.standard.string(forKey: backgroundDarkKey) ?? ""
        } else {
            // 旧版本只有一套背景，迁移成两套，避免升级后背景突然消失。
            backgroundHexLight = legacyBackground
            backgroundHexDark = legacyBackground
            UserDefaults.standard.set(legacyBackground, forKey: backgroundLightKey)
            UserDefaults.standard.set(legacyBackground, forKey: backgroundDarkKey)
        }
        backgroundSyncAll = UserDefaults.standard.object(forKey: syncAllKey) as? Bool ?? true
        let legacyImage = UserDefaults.standard.string(forKey: backgroundImageKey) ?? ""
        let hasSplitImage = UserDefaults.standard.object(forKey: backgroundImageLightKey) != nil
            || UserDefaults.standard.object(forKey: backgroundImageDarkKey) != nil
        if hasSplitImage {
            backgroundImagePathLight = UserDefaults.standard.string(forKey: backgroundImageLightKey) ?? ""
            backgroundImagePathDark = UserDefaults.standard.string(forKey: backgroundImageDarkKey) ?? ""
        } else {
            // 旧版本只有一套壁纸，默认同时用于浅色和深色模式。
            backgroundImagePathLight = legacyImage
            backgroundImagePathDark = legacyImage
            UserDefaults.standard.set(legacyImage, forKey: backgroundImageLightKey)
            UserDefaults.standard.set(legacyImage, forKey: backgroundImageDarkKey)
        }
        wallpaperPaths = UserDefaults.standard.stringArray(forKey: wallpaperListKey) ?? []
        let savedUIStyle = UserDefaults.standard.string(forKey: uiStyleKey) ?? ""
        if savedUIStyle.isEmpty {
            UserDefaults.standard.set(ATMusicUIStyle.nativeClean.rawValue, forKey: uiStyleKey)
            UserDefaults.standard.set(true, forKey: "atmusic.hideLiquidGlass")
            uiStyle = .nativeClean
        } else {
            uiStyle = savedUIStyle == "outline" ? .clear : (ATMusicUIStyle(rawValue: savedUIStyle) ?? .liquid)
        }
    }

    /// 在首帧之后恢复壁纸，避免覆盖安装后同步读写大图备份阻塞应用启动。
    func restoreWallpapersIfNeeded() {
        guard !wallpapersRestored else { return }
        wallpapersRestored = true
        restoreWallpapers()
    }

    /// 壁纸自动恢复：
    /// 1. 列表中文件仍在→直接保留；文件丢失但有 base64 备份→重建文件。
    /// 2. 扫描壁纸目录，把残留的 jpg 重新登记。
    /// 3. 当前背景图丢失时优先从备份重建，失败则回退到壁纸库第一张。
    /// 注：已彻底移除旧版“重置即删除背景图”的逻辑（它会导致更新后壁纸消失）。
    private func restoreWallpapers() {
        let dir = Self.wallpaperDirectory()
        var backup = UserDefaults.standard.dictionary(forKey: wallpaperDataKey) as? [String: String] ?? [:]
        let deleted = deletedWallpaperPaths()
        var restored: [String] = []
        for path in wallpaperPaths {
            if deleted.contains(path) { continue }
            if FileManager.default.fileExists(atPath: path) {
                restored.append(path)
                continue
            }
            // 覆盖安装后沙盒容器路径会变：备份重建必须写到当前沙盒的有效路径
            guard let b64 = Self.wallpaperBackupValue(for: path, in: backup),
                  let data = Data(base64Encoded: b64) else { continue }
            let fileName = URL(fileURLWithPath: path).lastPathComponent
            let newPath = Self.wallpaperDirectory().appendingPathComponent(fileName).path
            if (try? data.write(to: URL(fileURLWithPath: newPath), options: .atomic)) != nil {
                restored.append(newPath)
                backup[newPath] = b64
            }
        }
        if let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for name in names where name.hasSuffix(".jpg") {
                let full = dir.appendingPathComponent(name).path
                if deleted.contains(full) { continue }
                if !restored.contains(full) { restored.append(full) }
            }
        }
        wallpaperPaths = restored
        saveWallpaperList()
        backgroundImagePathLight = restoreWallpaperPath(backgroundImagePathLight, backup: &backup, deleted: deleted)
        backgroundImagePathDark = restoreWallpaperPath(backgroundImagePathDark, backup: &backup, deleted: deleted)
        persistSplitBackgroundImages()
        for path in [backgroundImagePathLight, backgroundImagePathDark] where !path.isEmpty {
            if !wallpaperPaths.contains(path), FileManager.default.fileExists(atPath: path), !deleted.contains(path) {
                wallpaperPaths.insert(path, at: 0)
            }
        }
        saveWallpaperList()
        UserDefaults.standard.set(backup, forKey: wallpaperDataKey)
        invalidateBackgroundCache()
    }

    /// 配置备份恢复后调用：按 UserDefaults 中的壁纸列表与 base64 备份重建壁纸文件
    func reloadWallpapersFromBackup() {
        wallpapersRestored = true
        restoreWallpapers()
    }

    /// 导出配置备份前调用：把当前壁纸文件内容补进 UserDefaults，避免只备份到旧沙盒路径。
    func refreshWallpaperBackupForExport() {
        var backup = UserDefaults.standard.dictionary(forKey: wallpaperDataKey) as? [String: String] ?? [:]
        let candidates = ([backgroundImagePathLight, backgroundImagePathDark] + wallpaperPaths).filter { !$0.isEmpty }
        for path in candidates {
            guard FileManager.default.fileExists(atPath: path),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { continue }
            backup[path] = data.base64EncodedString()
        }
        UserDefaults.standard.set(backup, forKey: wallpaperDataKey)
    }

    func setUIStyle(_ style: ATMusicUIStyle) {
        uiStyle = style
        UserDefaults.standard.set(style.rawValue, forKey: uiStyleKey)
        // Retired compatibility key for older backups/builds. Modern rendering reads uiStyle only.
        UserDefaults.standard.set(style != .liquid, forKey: "atmusic.hideLiquidGlass")
        objectWillChange.send()
    }

    func set(_ newAccent: ATMusicAccent) {
        guard accent != newAccent else { return }
        accent = newAccent
        UserDefaults.standard.set(newAccent.rawValue, forKey: AccentTheme.key)
    }

    /// 自定义强调色（色盘选色）
    func setCustomAccent(_ hex: String?) {
        let normalized = hex?.isEmpty == true ? nil : hex
        customAccentHex = normalized
        UserDefaults.standard.set(normalized ?? "", forKey: customAccentKey)
    }

    func clearCustomAccent() {
        setCustomAccent(nil)
    }

    /// 自定义背景色（兼容旧调用：写入当前系统外观）
    func setBackground(_ hex: String) {
        setBackground(hex, for: Self.currentColorScheme)
    }

    /// 为指定外观设置背景色；另一侧为空时会自动回退到这一侧。
    func setBackground(_ hex: String, for colorScheme: ColorScheme) {
        if colorScheme == .dark {
            backgroundHexDark = hex
            UserDefaults.standard.set(hex, forKey: backgroundDarkKey)
        } else {
            backgroundHexLight = hex
            UserDefaults.standard.set(hex, forKey: backgroundLightKey)
        }
        UserDefaults.standard.set(hex, forKey: backgroundKey)
    }

    func setBackgroundSyncAll(_ on: Bool) {
        backgroundSyncAll = on
        UserDefaults.standard.set(on, forKey: syncAllKey)
    }

    /// 配置备份恢复后重新读取浅色/深色背景设置。
    func reloadBackgroundSettings() {
        let defaults = UserDefaults.standard
        let legacyBackground = defaults.string(forKey: backgroundKey) ?? ""
        let hasSplitBackground = defaults.object(forKey: backgroundLightKey) != nil
            || defaults.object(forKey: backgroundDarkKey) != nil
        if hasSplitBackground {
            backgroundHexLight = defaults.string(forKey: backgroundLightKey) ?? ""
            backgroundHexDark = defaults.string(forKey: backgroundDarkKey) ?? ""
        } else {
            backgroundHexLight = legacyBackground
            backgroundHexDark = legacyBackground
        }

        let legacyImage = defaults.string(forKey: backgroundImageKey) ?? ""
        let hasSplitImage = defaults.object(forKey: backgroundImageLightKey) != nil
            || defaults.object(forKey: backgroundImageDarkKey) != nil
        if hasSplitImage {
            backgroundImagePathLight = defaults.string(forKey: backgroundImageLightKey) ?? ""
            backgroundImagePathDark = defaults.string(forKey: backgroundImageDarkKey) ?? ""
        } else {
            backgroundImagePathLight = legacyImage
            backgroundImagePathDark = legacyImage
        }
        invalidateBackgroundCache()
    }

    /// 自定义强调色 Color
    var customAccent: Color? {
        guard let customAccentHex else { return nil }
        return Color(hex: customAccentHex)
    }

    /// 自定义背景色 Color
    var customBackground: Color? {
        customBackground(for: Self.currentColorScheme)
    }

    /// 指定外观下的有效背景色，未设置时回退到另一侧。
    func customBackground(for colorScheme: ColorScheme) -> Color? {
        let hex = effectiveBackgroundHex(for: colorScheme)
        guard !hex.isEmpty else { return nil }
        return Color(hex: hex)
    }

    /// 上传的背景图片（按路径加载，解码结果缓存，避免大图每次重复解码导致卡顿/布局抖动）
    private var cachedBackgroundImage: UIImage?
    private var cachedBackgroundImagePath: String?
    var customBackgroundImage: UIImage? {
        customBackgroundImage(for: Self.currentColorScheme)
    }

    /// 指定外观下的有效壁纸，未设置时回退到另一侧。
    func customBackgroundImage(for colorScheme: ColorScheme) -> UIImage? {
        let path = backgroundImagePath(for: colorScheme)
        guard !path.isEmpty else { return nil }
        if let cached = cachedBackgroundImage, cachedBackgroundImagePath == path { return cached }
        let image = ATMusicImageFileCache.image(at: path)
        cachedBackgroundImage = image
        cachedBackgroundImagePath = path
        return image
    }

    private func invalidateBackgroundCache() {
        cachedBackgroundImage = nil
        cachedBackgroundImagePath = nil
    }

    /// 上传新壁纸：归一化后保存到壁纸库，并直接设为当前背景（覆盖保存当前壁纸）
    func addWallpaper(_ data: Data) {
        addWallpaper(data, for: Self.currentColorScheme)
    }

    /// 上传新壁纸并应用到指定外观。
    func addWallpaper(_ data: Data, for colorScheme: ColorScheme) {
        let normalized = Self.normalizedWallpaperJPEG(from: data)
        let imageData: Data
        if let normalized, !normalized.isEmpty {
            imageData = normalized
        } else if !data.isEmpty {
            // 归一化失败（如超内存的极端大图）：兜底保存原图，保证上传必生效
            imageData = data
        } else {
            return
        }
        let url = Self.wallpaperDirectory()
            .appendingPathComponent("wallpaper-\(Int(Date().timeIntervalSince1970))-\(Int.random(in: 100...999)).jpg")
        do {
            try imageData.write(to: url, options: .atomic)
            wallpaperPaths.append(url.path)
            saveWallpaperList()
            setBackgroundImagePath(url.path, for: colorScheme)
            saveWallpaperBackup(url.path, data: imageData)
            invalidateBackgroundCache()
            ATMusicImageFileCache.remove(url.path)
        } catch {
            // 保存失败：静默保留当前壁纸
        }
    }

    /// 从壁纸库选择壁纸应用为当前背景（无需再去相册）
    func applyWallpaper(at path: String) {
        applyWallpaper(at: path, for: Self.currentColorScheme)
    }

    /// 从壁纸库选择壁纸应用到指定外观。
    func applyWallpaper(at path: String, for colorScheme: ColorScheme) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        setBackgroundImagePath(path, for: colorScheme)
        invalidateBackgroundCache()
    }

    /// 删除壁纸库中的某张壁纸；若正在使用则自动切换到上一张/清空
    func deleteWallpaper(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
        ATMusicImageFileCache.remove(path)
        wallpaperPaths.removeAll { $0 == path }
        removeWallpaperBackup(path)
        saveDeletedWallpaper(path)
        saveWallpaperList()
        if backgroundImagePathLight == path { setBackgroundImagePath(wallpaperPaths.first ?? "", for: .light) }
        if backgroundImagePathDark == path { setBackgroundImagePath(wallpaperPaths.first ?? "", for: .dark) }
        invalidateBackgroundCache()
    }

    /// 清除当前背景（保留壁纸库，可随时重新选择）
    func clearBackgroundImage() {
        clearBackgroundImage(for: Self.currentColorScheme)
    }

    /// 清除指定外观的壁纸；若另一侧有壁纸，该外观会自动回退到另一侧。
    func clearBackgroundImage(for colorScheme: ColorScheme) {
        setBackgroundImagePath("", for: colorScheme)
        invalidateBackgroundCache()
    }

    /// 重置设置时清空整套壁纸库与当前背景。
    func clearAllWallpapers() {
        for path in wallpaperPaths {
            try? FileManager.default.removeItem(atPath: path)
            ATMusicImageFileCache.remove(path)
        }
        for path in Set([backgroundImagePathLight, backgroundImagePathDark].filter { !$0.isEmpty }) {
            try? FileManager.default.removeItem(atPath: path)
            ATMusicImageFileCache.remove(path)
        }
        wallpaperPaths = []
        backgroundImagePathLight = ""
        backgroundImagePathDark = ""
        backgroundHexLight = ""
        backgroundHexDark = ""
        UserDefaults.standard.removeObject(forKey: wallpaperListKey)
        UserDefaults.standard.removeObject(forKey: wallpaperDataKey)
        UserDefaults.standard.removeObject(forKey: deletedKey)
        UserDefaults.standard.set("", forKey: backgroundImageKey)
        UserDefaults.standard.set("", forKey: backgroundImageLightKey)
        UserDefaults.standard.set("", forKey: backgroundImageDarkKey)
        UserDefaults.standard.set("", forKey: backgroundKey)
        UserDefaults.standard.set("", forKey: backgroundLightKey)
        UserDefaults.standard.set("", forKey: backgroundDarkKey)
        invalidateBackgroundCache()
        ATMusicImageFileCache.removeAll()
    }

    private func effectiveBackgroundHex(for colorScheme: ColorScheme) -> String {
        let primary = colorScheme == .dark ? backgroundHexDark : backgroundHexLight
        if !primary.isEmpty { return primary }
        return colorScheme == .dark ? backgroundHexLight : backgroundHexDark
    }

    func backgroundImagePath(for colorScheme: ColorScheme) -> String {
        let primary = colorScheme == .dark ? backgroundImagePathDark : backgroundImagePathLight
        if !primary.isEmpty { return primary }
        return colorScheme == .dark ? backgroundImagePathLight : backgroundImagePathDark
    }

    private func setBackgroundImagePath(_ path: String, for colorScheme: ColorScheme) {
        if colorScheme == .dark {
            backgroundImagePathDark = path
            UserDefaults.standard.set(path, forKey: backgroundImageDarkKey)
        } else {
            backgroundImagePathLight = path
            UserDefaults.standard.set(path, forKey: backgroundImageLightKey)
        }
        UserDefaults.standard.set(path, forKey: backgroundImageKey)
    }

    private func persistSplitBackgroundImages() {
        UserDefaults.standard.set(backgroundImagePathLight, forKey: backgroundImageLightKey)
        UserDefaults.standard.set(backgroundImagePathDark, forKey: backgroundImageDarkKey)
        UserDefaults.standard.set(backgroundImagePath, forKey: backgroundImageKey)
    }

    private func restoreWallpaperPath(
        _ path: String,
        backup: inout [String: String],
        deleted: Set<String>
    ) -> String {
        guard !path.isEmpty, !deleted.contains(path) else { return "" }
        var resolved = path
        if !FileManager.default.fileExists(atPath: resolved),
           let b64 = Self.wallpaperBackupValue(for: resolved, in: backup),
           let data = Data(base64Encoded: b64) {
            let fileName = URL(fileURLWithPath: resolved).lastPathComponent
            let newPath = Self.wallpaperDirectory().appendingPathComponent(fileName).path
            if (try? data.write(to: URL(fileURLWithPath: newPath), options: .atomic)) != nil {
                resolved = newPath
                backup[newPath] = b64
            }
        }
        if !FileManager.default.fileExists(atPath: resolved) {
            return wallpaperPaths.first ?? ""
        }
        return resolved
    }

    private static var currentColorScheme: ColorScheme {
        let mode = UserDefaults.standard.string(forKey: "atmusic.themeMode") ?? ATMusicThemeMode.system.rawValue
        if mode == ATMusicThemeMode.dark.rawValue { return .dark }
        if mode == ATMusicThemeMode.light.rawValue { return .light }
        return UITraitCollection.current.userInterfaceStyle == .dark ? .dark : .light
    }

    private static func wallpaperDirectory() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ATMusicWallpapers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func saveWallpaperList() {
        UserDefaults.standard.set(wallpaperPaths, forKey: wallpaperListKey)
    }

    /// base64 备份（UserDefaults 持久化）：覆盖安装导致文件丢失时可自动重建
    private func saveWallpaperBackup(_ path: String, data: Data) {
        var backup = UserDefaults.standard.dictionary(forKey: wallpaperDataKey) as? [String: String] ?? [:]
        backup[path] = data.base64EncodedString()
        UserDefaults.standard.set(backup, forKey: wallpaperDataKey)
    }

    private func removeWallpaperBackup(_ path: String) {
        var backup = UserDefaults.standard.dictionary(forKey: wallpaperDataKey) as? [String: String] ?? [:]
        backup.removeValue(forKey: path)
        UserDefaults.standard.set(backup, forKey: wallpaperDataKey)
    }

    /// 删除标记：删除过的壁纸不会被目录扫描/备份重新拉回（保证删除是永久的）
    private func saveDeletedWallpaper(_ path: String) {
        var set = UserDefaults.standard.stringArray(forKey: deletedKey) ?? []
        if !set.contains(path) { set.append(path) }
        UserDefaults.standard.set(set, forKey: deletedKey)
    }

    private func deletedWallpaperPaths() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: deletedKey) ?? [])
    }

    private static func wallpaperBackupValue(for path: String, in backup: [String: String]) -> String? {
        if let exact = backup[path] { return exact }
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        return backup.first { URL(fileURLWithPath: $0.key).lastPathComponent == fileName }?.value
    }
    /// 归一化背景图：长边统一到 1600px；原图过小时放大到该尺寸并轻度高斯模糊柔化，
    /// 铺满屏幕时既不会像素化，也不会因小图拉伸引发布局/视觉问题
    private static func normalizedWallpaperJPEG(from data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let w = image.size.width
        let h = image.size.height
        guard w > 0, h > 0 else { return nil }
        let target: CGFloat = 1600
        let longest = max(w, h)
        let wasSmall = longest < target
        let scale = target / longest
        let size = CGSize(width: w * scale, height: h * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1 // 固定输出真实像素：长边 1600px，避免高分屏生成 4800px 巨图导致内存/解码异常
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        var result = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        if wasSmall,
           let ci = CIImage(image: result)?.clampedToExtent(),
           let filter = CIFilter(name: "CIGaussianBlur") {
            filter.setValue(ci, forKey: kCIInputImageKey)
            filter.setValue(4, forKey: kCIInputRadiusKey)
            if let output = filter.outputImage?.cropped(to: ci.extent),
               let cg = CIContext().createCGImage(output, from: output.extent) {
                result = UIImage(cgImage: cg)
            }
        }
        return result.jpegData(compressionQuality: 0.8)
    }
}

/// 当前配色读取 / 写入（持久化到 UserDefaults，统一走 ThemeStore）
enum AccentTheme {
    static let key = "atmusic.accent"

    static var current: ATMusicAccent {
        ThemeStore.shared.accent
    }

    static func set(_ accent: ATMusicAccent) {
        ThemeStore.shared.set(accent)
    }
}

// MARK: - 背景氛围渐变（让液态玻璃始终有内容可采样）

extension LinearGradient {
    /// 暖调咖啡色系背景
    static let atmusicBackdrop = LinearGradient(
        colors: [
            Color(uiColor: .atmusicBackground),
            Color(uiColor: .atmusicBackground).opacity(0.72),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    /// 强调色渐变（跟随配色主题）
    static var atmusicAccent: LinearGradient {
        LinearGradient(
            colors: AccentTheme.current.gradientColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - 浅色立体阴影（卡片分层质感）

struct ATMusicCardShadowModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var radius: CGFloat
    var y: CGFloat

    func body(content: Content) -> some View {
        content.shadow(
            color: colorScheme == .dark ? .black.opacity(0.35) : .black.opacity(0.08),
            radius: radius,
            y: y
        )
    }
}

extension View {
    /// 卡片阴影：浅色模式柔和阴影提升层次，深色模式轻微阴影保持立体
    func atmusicCardShadow(radius: CGFloat = 9, y: CGFloat = 3) -> some View {
        modifier(ATMusicCardShadowModifier(radius: radius, y: y))
    }
}

// MARK: - 主题模式 ↔ 系统外观

extension ATMusicThemeMode {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
// MARK: - 颜色工具（hex 解析 / 明暗调整，供色盘自定义使用）

extension UIColor {
    convenience init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6 || value.count == 8, let raw = UInt64(value, radix: 16) else { return nil }
        let r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat
        if value.count == 8 {
            a = CGFloat((raw >> 24) & 0xFF) / 255
            r = CGFloat((raw >> 16) & 0xFF) / 255
            g = CGFloat((raw >> 8) & 0xFF) / 255
            b = CGFloat(raw & 0xFF) / 255
        } else {
            a = 1
            r = CGFloat((raw >> 16) & 0xFF) / 255
            g = CGFloat((raw >> 8) & 0xFF) / 255
            b = CGFloat(raw & 0xFF) / 255
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(
            format: "#%02X%02X%02X",
            Int(r * 255), Int(g * 255), Int(b * 255)
        )
    }

    func shaded(_ amount: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        let k = max(0, 1 - amount)
        return UIColor(red: r * k, green: g * k, blue: b * k, alpha: a)
    }
}

extension Color {
    init?(hex: String) {
        guard let ui = UIColor(hex: hex) else { return nil }
        self.init(uiColor: ui)
    }

    var hexString: String {
        UIColor(self).hexString
    }
}
