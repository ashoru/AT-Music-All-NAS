import SwiftUI
import UIKit


struct PlayerView: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var clock: PlaybackClock
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var favorites: FavoritesStore
    @ObservedObject private var localLibrary = LocalLibraryStore.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Binding var isPresented: Bool
    private let previewShowLyrics: Bool?

    init(isPresented: Binding<Bool>, previewShowLyrics: Bool? = nil) {
        _isPresented = isPresented
        self.previewShowLyrics = previewShowLyrics
    }

    @State private var lyrics: [LyricLine] = []
    @State private var showLyrics = false
    @AppStorage("atmusic.player.lastLyricsPage") private var lastLyricsPage = false
    @State private var showQueue = false
    @State private var showSleepTimer = false
    @State private var showComments = false
    @State private var showDownloadPicker = false
    @State private var showDownloadedActionDialog = false
    @State private var showSynologyMetadataEditor = false
    @State private var showLocalMetadataEditor = false
    @State private var showLyricSearch = false
    @State private var showLyricsSync = false
    @State private var selectedAlbum: Album?
    @State private var showSignalPath = false
    @State private var showNativeMoreActions = false
    @State private var showMoreSettingsHint = false
    @AppStorage("atmusic.playerMoreSettingsHintSeen") private var playerMoreSettingsHintSeen = false
    /// 与设置页「关闭液态效果」共用，避免播放器按钮仍单独保留 iOS 26 液态玻璃。
    @AppStorage("atmusic.uiStyle") private var uiStyleRaw = ATMusicUIStyle.liquid.rawValue
    private var uiStyle: ATMusicUIStyle {
        uiStyleRaw == "outline" ? .clear : (ATMusicUIStyle(rawValue: uiStyleRaw) ?? .liquid)
    }
    private var isLiquid: Bool {
        uiStyle == .liquid
    }
    private let downloadFeatureUnlocked = true
    /// 下载完成后直接弹原生分享（用户自行选择保存或转发）
    @State private var shareFile: ShareFileItem?
    @State private var sharedFileURL: URL?
    @State private var showAddToLocalPlaylist = false
    @State private var showPlayerSettings = false
    @State private var showArtistHome = false
    @State private var pickedArtistName = ""
    @State private var showArtistPicker = false
    @State private var vinylScrollTarget: Int?
    @State private var vinylIsUserScrolling = false
    @State private var vinylLyricsResumeTask: Task<Void, Never>?
    /// 当前高亮歌词行索引（事件驱动缓存：只在换行时更新，阻断逐行 ForEach 重复二分查找）
    @State private var activeVinylLyricIndex: Int? = nil
    @AppStorage("atmusic.hideDynamicEffects") private var lowPowerVisualMode = false
    @AppStorage("atmusic.djVisual") private var djVisualEnabled = false
    @AppStorage("atmusic.djVisualIntensity") private var djVisualIntensity = 0.8
    @State private var dominantColor: RGBColor?
    @Namespace private var coverNS
    @AppStorage("atmusic.lyricFontSize") private var lyricFontSize = 17
    @AppStorage("atmusic.lyricColor") private var lyricColorRaw = "accent"
    @AppStorage("atmusic.lyricDimColor") private var lyricDimColorRaw = "dim"
    @AppStorage("atmusic.lyricGlow") private var lyricGlowLevel = 1
    @AppStorage("atmusic.lyricGradStart") private var lyricGradStartRaw = ""
    @AppStorage("atmusic.lyricGradEnd") private var lyricGradEndRaw = ""
    /// 渐变模式：0=跟随封面自动取色（默认），1=始终保持用户自定义渐变
    @AppStorage("atmusic.lyricGradMode") private var lyricGradMode = 0
    /// 歌词行距（14~40，默认 24）
    @AppStorage("atmusic.lyricSpacing") private var lyricLineSpacing = 24
    /// 播放器氛围：背景流动开关 / 速度 / 呼吸光晕强度
    @AppStorage("atmusic.playerBreath") private var playerBreath = 0.6
    @AppStorage("atmusic.playerDustMode") private var playerDustModeRaw = ATMusicPlayerDustMode.off.rawValue
    @AppStorage("atmusic.playerDustDensity") private var playerDustDensity = 1.0
    @AppStorage("atmusic.playerDustSize") private var playerDustSize = 1.0
    /// 播放控件颜色是否跟随封面主色；关闭后使用全局主题色
    @AppStorage("atmusic.playerControlsUseCoverColor") private var controlsUseCoverColor = true
    @AppStorage("atmusic.playerMainIconColorHex") private var playerMainIconColorHex = ""
    @AppStorage("atmusic.playerSecondaryIconColorHex") private var playerSecondaryIconColorHex = ""
    @AppStorage("atmusic.playerPrimaryButtonColorHex") private var playerPrimaryButtonColorHex = ""
    /// 播放器顶部与底部控制按钮样式：按播放器样式独立设置（经典/唱片各记各的）
    @AppStorage("atmusic.playerButtonStyle.classic") private var classicButtonStyleRaw = ATMusicPlayerButtonStyle.appleMusic.rawValue
    @AppStorage("atmusic.playerButtonStyle.vinyl") private var vinylButtonStyleRaw = ATMusicPlayerButtonStyle.appleMusic.rawValue
    @AppStorage("atmusic.lyricTranslation") private var lyricTranslation = true
    /// 进度条样式：0 流光 / 1 辉光 / 2 极光 / 3 波浪
    @AppStorage("atmusic.progressBarStyle") private var progressBarStyle = 0
    /// 进度条单独强调色；空值时跟随播放控件颜色
    @AppStorage("atmusic.progressAccentHex") private var progressAccentHex = ""
    /// 播放器布局自由调整：开关 + 各组件 x/y/z 数据 + 当前选中组件
    @AppStorage("atmusic.playerLayoutMode") private var layoutMode = false
    @AppStorage("atmusic.playerLayoutSelectedPart") private var layoutPartRaw = PlayerLayoutPart.progress.rawValue
    @State private var layoutData: [String: PlayerLayoutEntry] = PlayerLayoutStore.load()
    @State private var layoutPart: PlayerLayoutPart = .progress
    @ObservedObject private var appleLayout = AppleMusicLayoutStore.shared
    @State private var appleLayoutPart: AppleMusicLayoutPart = .cover
    /// 歌词布局：对齐样式 / 水平偏移 / 垂直重心（底部更多或顶部更多歌词）
    @AppStorage("atmusic.lyricAlignRaw") private var lyricAlignRaw = "center"
    @AppStorage("atmusic.lyricOffsetX") private var lyricOffsetX = 0.0
    @AppStorage("atmusic.lyricAnchorY") private var lyricAnchorY = 0.0
    /// 歌词大小缩放（布局调整弹窗「大小」滑杆）
    @AppStorage("atmusic.lyricScale") private var lyricScale = 1.0
    /// 底部指示线开关（上滑呼出评论区）
    @AppStorage("atmusic.deckGrabberEnabled") private var deckGrabberEnabled = true
    /// 圆形封面模式（播放器大封面 / 歌词页左上角小封面）
    @AppStorage("atmusic.circularCover") private var circularCover = true
    /// 圆形封面自动旋转
    @AppStorage("atmusic.circularCoverSpin") private var circularCoverSpin = true
    /// 歌词自定义发光颜色（留空跟随当前行颜色 / 封面取色）
    @AppStorage("atmusic.lyricGlowColorRaw") private var lyricGlowColorRaw = ""
    /// 侧边滑动切歌（抖音式刷视频交互，默认开启）
    @AppStorage("atmusic.swipeSwitchSong") private var swipeSwitchSong = true
    /// 歌词模糊控制：起始距离（距当前行几行开始模糊）+ 模糊强度（0 = 关闭）
    @AppStorage("atmusic.lyricBlurStart") private var lyricBlurStart = 1
    @AppStorage("atmusic.lyricBlurAmount") private var lyricBlurAmount = 1.1
    /// 歌词 3D 倾斜角度（0 = 关闭；顶部向后倒，立体透视感）
    @AppStorage("atmusic.lyricTilt") private var lyricTilt = 0
    /// 歌词左右倾斜角度（0 = 关闭；负值向左、正值向右，立体透视感）
    @AppStorage("atmusic.lyricTiltY") private var lyricTiltY = 0
    /// 歌词进度偏移（秒）：歌词与音频不同步时手动校正，正数提前、负数延后
    /// - 这里是「全局默认值」，逐曲校准值记在 LyricOffsetStore 里，优先于它生效。
    @AppStorage("atmusic.lyricOffset") private var lyricOffset = 0.0
    @ObservedObject private var lyricOffsets = LyricOffsetStore.shared

    /// 当前歌曲实际生效的歌词偏移（逐曲校准 > 全局默认）。
    private var activeLyricOffset: Double {
        _ = lyricOffsets.revision
        return lyricOffsets.offset(for: song?.identityKey)
    }
    /// 歌词界面自定义背景
    @AppStorage("atmusic.lyricBackground.image") private var lyricBackgroundImagePath = ""
    @AppStorage("atmusic.lyricBackground.blur") private var lyricBackgroundBlur = 12.0
    @AppStorage("atmusic.lyricBackground.syncCover") private var lyricBackgroundSyncCover = false
    @AppStorage("atmusic.albumTitleColorHex") private var albumTitleColorHex = ""
    @AppStorage("atmusic.albumArtistColorHex") private var albumArtistColorHex = ""
    @AppStorage("atmusic.albumPreviewLyricColorHex") private var albumPreviewLyricColorHex = ""
    @AppStorage("atmusic.albumPreviewDimColorHex") private var albumPreviewDimColorHex = ""
    @AppStorage("atmusic.albumTextGradient") private var albumTextGradient = false
    @AppStorage("atmusic.albumTextGlow") private var albumTextGlow = false
    @AppStorage("atmusic.albumTextGlowIntensity") private var albumTextGlowIntensity = 1.0
    @AppStorage("atmusic.coverPlayerStyle") private var coverPlayerStyleRaw = ATMusicCoverPlayerStyle.appleMusic.rawValue
    @AppStorage("atmusic.appleMusic.showVolume") private var appleShowVolume = false
    @AppStorage("atmusic.appleMusic.primaryHex") private var applePrimaryHex = ""
    @AppStorage("atmusic.appleMusic.secondaryHex") private var appleSecondaryHex = ""
    @AppStorage("atmusic.appleMusic.accentHex") private var appleAccentHex = ""
    @AppStorage("atmusic.appleMusic.volumeHex") private var appleVolumeHex = ""
    @AppStorage("atmusic.appleMusic.syncWallpaper") private var appleSyncWallpaper = false
    @AppStorage("atmusic.appleMusic.wallpaperBlur") private var appleWallpaperBlur = 14.0
    @AppStorage("atmusic.showSongVIPBadge") private var showSongVIPBadge = true
    @AppStorage("atmusic.appleMusic.showLyricPreview") private var appleShowLyricPreview = true
    /// 侧边滑动手势当前位移（刷视频式切歌过渡）
    @State private var swipeOffset: CGFloat = 0
    @State private var coverDrag: CGSize = .zero

    private var song: Song? { player.currentSong }
    private let rateOptions: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    private var downloadQualityOptions: [DownloadQuality] {
        guard let song else { return DownloadQuality.allCases }
        return DownloadQuality.supported(for: song.source)
    }

    /// 封面主色联动调色板：背景渐变 / 进度条 / 播放暂停键 / 功能按钮 / 歌词高亮等全部跟随封面主色。
    /// 安全机制：只在切歌（.task(id: song?.identityKey)）时一次性提取并更新，绝不随封面加载过程高频重算 @State，
    /// 避免整页反复重绘导致的布局错乱与发烫。深浅模式切换时及时重算配色。
    /// 自定义歌词发光颜色
    private var lyricGlowColor: Color? {
        if lyricGlowColorRaw.hasPrefix("#"), let c = Color(hex: lyricGlowColorRaw) { return c }
        return nil
    }

    /// 歌词对齐样式（居中 / 全部居左）
    private var lyricAlign: HorizontalAlignment {
        lyricAlignRaw == "left" ? .leading : .center
    }

    /// 自动播放时当前高亮歌词始终锁在歌词视口正中。
    /// `lyricAnchorY` 只用于移动整块歌词区域，不再改变滚动焦点，避免播放过程中高亮行逐渐下漂。
    private var lyricAnchor: UnitPoint { .center }

    private var palette: CoverPalette {
        if let dominantColor {
            return CoverPalette.make(dominant: dominantColor, colorScheme: colorScheme)
        }
        return CoverPalette.fallback(colorScheme: colorScheme)
    }

    private var controlAccent: Color {
        if playerPrimaryButtonColorHex.hasPrefix("#"), let color = Color(hex: playerPrimaryButtonColorHex) {
            return color
        }
        return controlsUseCoverColor ? palette.accent : Color.atmusicAmber
    }

    private var controlAccentSoft: Color {
        return controlsUseCoverColor ? palette.accentSoft : Color.atmusicAmber.opacity(0.28)
    }

    private var playerButtonStyle: ATMusicPlayerButtonStyle {
        let raw: String
        switch coverPlayerStyle {
        case .vinyl: raw = vinylButtonStyleRaw
        case .classic: raw = classicButtonStyleRaw
        default: raw = classicButtonStyleRaw
        }
        return ATMusicPlayerButtonStyle(rawValue: raw) ?? .appleMusic
    }

    private var coverPlayerStyle: ATMusicCoverPlayerStyle {
        return ATMusicCoverPlayerStyle(rawValue: coverPlayerStyleRaw) ?? .appleMusic
    }

    private var legacyLayoutStyle: ATMusicCoverPlayerStyle {
        coverPlayerStyle == .vinyl ? .vinyl : (coverPlayerStyle == .immersive ? .immersive : .classic)
    }

    private func vinylLayoutEntry(_ part: PlayerLayoutPart) -> PlayerLayoutEntry {
        layoutData[part.rawValue] ?? PlayerLayoutStore.defaultEntry(for: part, style: .vinyl)
    }

    private enum VinylLayoutDefaults {
        // 仅保留歌词视口行数；位置/大小全部由 PlayerLayoutStore(.vinyl) 统一管理。
        static let lyricTopRows = 3
        static let lyricBottomRows = 3
    }

    private func toggleFavorite(_ song: Song) {
        Task { @MainActor in
            await favorites.toggleFavorite(song)
        }
    }

    private var playerDustMode: ATMusicPlayerDustMode {
        return ATMusicPlayerDustMode(rawValue: playerDustModeRaw) ?? .off
    }

    private var playerButtonText: Color {
        if playerButtonStyle == .appleMusic { return .white }
        if playerMainIconColorHex.hasPrefix("#"), let color = Color(hex: playerMainIconColorHex) {
            return color
        }
        return palette.text
    }

    private var playerButtonSecondaryText: Color {
        if playerButtonStyle == .appleMusic { return .white.opacity(0.88) }
        if playerSecondaryIconColorHex.hasPrefix("#"), let color = Color(hex: playerSecondaryIconColorHex) {
            return color
        }
        return palette.secondary
    }

    private var albumTitleColor: Color {
        if albumTitleColorHex.hasPrefix("#"), let color = Color(hex: albumTitleColorHex) { return color }
        return palette.text
    }

    private var albumArtistColor: Color {
        if albumArtistColorHex.hasPrefix("#"), let color = Color(hex: albumArtistColorHex) { return color }
        return palette.secondary
    }

    private var albumPreviewLyricColor: Color {
        if albumPreviewLyricColorHex.hasPrefix("#"), let color = Color(hex: albumPreviewLyricColorHex) { return color }
        return palette.text
    }

    private var albumPreviewDimColor: Color {
        if albumPreviewDimColorHex.hasPrefix("#"), let color = Color(hex: albumPreviewDimColorHex) { return color }
        return palette.secondary
    }

    private var progressAccent: Color {
        if progressAccentHex.hasPrefix("#"), let color = Color(hex: progressAccentHex) {
            return color
        }
        return controlAccent
    }

    private var albumTitleForeground: AnyShapeStyle {
        albumForeground(primary: albumTitleColor, secondary: albumPreviewLyricColor)
    }

    private var albumArtistForeground: AnyShapeStyle {
        albumForeground(primary: albumArtistColor, secondary: albumTitleColor)
    }

    private var albumPreviewForeground: AnyShapeStyle {
        albumForeground(primary: albumPreviewLyricColor, secondary: albumTitleColor)
    }

    private var albumPreviewDimForeground: AnyShapeStyle {
        albumTextGradient
            ? AnyShapeStyle(LinearGradient(colors: [albumPreviewDimColor.opacity(0.72), albumArtistColor.opacity(0.62)], startPoint: .leading, endPoint: .trailing))
            : AnyShapeStyle(albumPreviewDimColor)
    }

    private func albumForeground(primary: Color, secondary: Color) -> AnyShapeStyle {
        if albumTextGradient {
            return AnyShapeStyle(LinearGradient(colors: [primary, secondary], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        return AnyShapeStyle(primary)
    }

    private func albumGlow(_ color: Color, strong: Bool = false) -> Color {
        albumTextGlow ? color.opacity((strong ? 0.46 : 0.30) * albumTextGlowIntensity) : .clear
    }

    private var reduceVisualMotion: Bool {
        lowPowerVisualMode || accessibilityReduceMotion
    }

    private var playerVisualsActive: Bool {
        player.isPlaying && !player.isInBackground && !showPlayerSettings && !reduceVisualMotion
    }

    private func openPlayerSettings() {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            showPlayerSettings = true
        }
    }

    private func closePlayerSettings() {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            showPlayerSettings = false
        }
    }

    /// 当前行歌词颜色（可自定义；配色模式关闭时自动跟随封面取色）
    private var lyricCurrentColor: Color {
        guard lyricGradMode == 1 else { return palette.accent }
        switch lyricColorRaw {
        case "white": return .white
        case "amber": return Color.atmusicAmber
        case "cyan": return Color(red: 0.35, green: 0.85, blue: 0.96)
        case "pink": return Color(red: 1.0, green: 0.62, blue: 0.82)
        case "green": return Color(red: 0.42, green: 0.90, blue: 0.62)
        default:
            if lyricColorRaw.hasPrefix("#"), let c = Color(hex: lyricColorRaw) { return c }
            return palette.accent
        }
    }

    /// 未播放歌词颜色（可自定义；配色模式关闭时自动跟随封面取色）
    private var lyricDimColor: Color {
        guard lyricGradMode == 1 else { return palette.secondary }
        switch lyricDimColorRaw {
        case "white": return .white.opacity(0.78)
        case "bluegray": return Color(red: 0.72, green: 0.78, blue: 0.86)
        case "gray": return Color.gray.opacity(0.85)
        case "dark": return Color.black.opacity(0.55)
        default:
            if lyricDimColorRaw.hasPrefix("#"), let c = Color(hex: lyricDimColorRaw) { return c }
            return palette.secondary
        }
    }

    /// 当前行歌词渐变（可自定义起止色；未设置时自动从封面强调色派生，深浅模式自适应）
    /// 配色模式：开（保持自定义）时歌词颜色与渐变都一直用用户选色且切歌后不重置；关（默认）时全部自动跟随封面取色
    private var lyricGradStart: Color {
        if lyricGradMode == 1, lyricGradStartRaw.hasPrefix("#"), let c = Color(hex: lyricGradStartRaw) { return c }
        return lyricCurrentColor
    }
    private var lyricGradEnd: Color {
        if lyricGradMode == 1, lyricGradEndRaw.hasPrefix("#"), let c = Color(hex: lyricGradEndRaw) { return c }
        return mixedColor(lyricCurrentColor, with: colorScheme == .dark ? .white : .black, amount: 0.45)
    }
    private func mixedColor(_ c: Color, with other: Color, amount: CGFloat) -> Color {
        let ui = UIColor(c)
        let ui2 = UIColor(other)
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        ui.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        ui2.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let a = min(max(amount, 0), 1)
        return Color(red: r1 * (1 - a) + r2 * a, green: g1 * (1 - a) + g2 * a, blue: b1 * (1 - a) + b2 * a)
    }

    private func glowName(_ level: Int) -> String {
        switch level {
        case 0: return "关闭"
        case 1: return "柔和"
        case 2: return "标准"
        default: return "强烈"
        }
    }

    /// 发光强度对应的 shadow 半径（0 关闭，最大 32，叠双层光晕更亮）
    private var lyricGlowRadius: CGFloat {
        switch lyricGlowLevel {
        case 0: return 0
        case 1: return 6
        case 2: return 12
        case 3: return 18
        case 4: return 25
        default: return 32
        }
    }

    var body: some View {
        let _ = theme.accent
        Group {
            if DeviceLayoutHelper.isIPadRegular(horizontalSizeClass) {
                IPadPlayerView(
                    song: song,
                    lyrics: lyrics,
                    onFavorite: {
                        guard let song else { return }
                        toggleFavorite(song)
                    },
                    onQueue: {
                        showQueue = true
                    },
                    onComments: {
                        if song != nil { showComments = true }
                    },
                    onSleepTimer: {
                        showSleepTimer = true
                    },
                    onAddToLocalPlaylist: {
                        showAddToLocalPlaylist = true
                    },
                    onDownload: {
                        handlePlayerDownloadTap()
                    },
                    onPlayerSettings: {
                        openPlayerSettings()
                    },
                    onSearchLyrics: {
                        showLyricSearch = true
                    },
                    onLyricsSync: {
                        showLyricsSync = true
                    },
                    onDismiss: {
                        isPresented = false
                    }
                )
            } else if showPlayerSettings {
                Color.clear.ignoresSafeArea()
            } else if coverPlayerStyle == .immersive {
                ImmersivePlayerView(
                    song: song,
                    lyrics: lyrics,
                    isPresented: $isPresented,
                    previewShowLyrics: previewShowLyrics,
                    onOpenSettings: {
                        openPlayerSettings()
                    },
                    onSleepTimer: {
                        showSleepTimer = true
                    },
                    onSongInfo: {
                        openSongInfo()
                    },
                    onSearchLyrics: {
                        showLyricSearch = true
                    },
                    onAddToLocalPlaylist: {
                        showAddToLocalPlaylist = true
                    },
                    onDownload: {
                        handlePlayerDownloadTap()
                    },
                    onLyricsSync: {
                        showLyricsSync = true
                    }
                )
            } else if coverPlayerStyle == .appleMusic {
                ZStack {
                    ReferencePlaybackView(
                        song: song,
                        lyrics: lyrics,
                        showLyrics: $showLyrics,
                        onFavorite: {
                            guard let song else { return }
                            toggleFavorite(song)
                        },
                        onQueue: {
                            showQueue = true
                        },
                        onComments: {
                            if song != nil { showComments = true }
                        },
                        onSleepTimer: {
                            showSleepTimer = true
                        },
                        onAddToLocalPlaylist: {
                            showAddToLocalPlaylist = true
                        },
                        onDownload: {
                            showDownloadPicker = true
                        },
                        onPlayerSettings: {
                            openPlayerSettings()
                        },
                        onSearchLyrics: {
                            showLyricSearch = true
                        },
                        onSongInfo: {
                            openSongInfo()
                        },
                        onLyricsSync: {
                            showLyricsSync = true
                        }
                    )

                    if layoutMode {
                        appleMusicLayoutToolbar
                            .contentShape(Rectangle())
                            .frame(maxWidth: .infinity)
                            .frame(maxHeight: .infinity, alignment: .top)
                            .padding(.top, 54)
                            .transition(.opacity)
                            .zIndex(60)
                    }

                }
            } else if coverPlayerStyle == .vinyl {
                GeometryReader { geo in
                    ZStack {
                        background
                            .ignoresSafeArea()

                        content(geo: geo)

                        controlDeck(bottomInset: geo.safeAreaInsets.bottom)
                            .frame(maxWidth: .infinity)
                            .frame(maxHeight: .infinity, alignment: .bottom)

                        if layoutMode && coverPlayerStyle != .vinyl {
                            layoutToolbar
                                .contentShape(Rectangle())
                                .frame(maxWidth: .infinity)
                                .frame(maxHeight: .infinity, alignment: .top)
                                .padding(.top, 54)
                                .transition(.opacity)
                        }

                    }
                }
            } else {
                GeometryReader { geo in
                    ZStack {
                        background
                            .ignoresSafeArea()

                        VStack(spacing: 0) {
                            headerBar
                            content(geo: geo)
                        }
                        .foregroundStyle(palette.text)

                        controlDeck(bottomInset: geo.safeAreaInsets.bottom)
                            .frame(maxWidth: .infinity)
                            .frame(maxHeight: .infinity, alignment: .bottom)

                        // 布局编辑工具栏：组件选择 + X/Y/Z 滑杆 + 恢复默认 + 完成
                        if layoutMode {
                            layoutToolbar
                                .contentShape(Rectangle())
                                .frame(maxWidth: .infinity)
                                .frame(maxHeight: .infinity, alignment: .top)
                                .padding(.top, 54)
                                .transition(.opacity)
                        }

                    }
                }
            }
        }
        .overlay(alignment: .top) {
            if showMoreSettingsHint {
                Text("点击顶部中间正在播放的标题，可打开更多设置")
                    .font(ATMusicFont.appFont(13, .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.58), in: Capsule())
                    .padding(.top, 62)
                    .transition(.opacity)
                    .zIndex(120)
            }
        }
        .task(id: song?.identityKey) {
            dominantColor = nil
            await MainActor.run {
                coverDrag = .zero
                vinylScrollTarget = nil
                vinylIsUserScrolling = false
                vinylLyricsResumeTask?.cancel()
                vinylLyricsResumeTask = nil
            }
            await loadLyrics()
            await extractCoverPalette()
        }
        .onChange(of: song?.coverURL) { _ in
            Task { await extractCoverPalette() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .atmusicCoverDidUpdate)) { _ in
            dominantColor = nil
            Task { await extractCoverPalette() }
        }
        .onChange(of: layoutData) { newValue in
            PlayerLayoutStore.save(newValue, for: legacyLayoutStyle)
        }
        .onChange(of: coverPlayerStyleRaw) { _ in
            guard coverPlayerStyle != .appleMusic else { return }
            let next = PlayerLayoutStore.load(for: legacyLayoutStyle)
            if next != layoutData { layoutData = next }
        }
        .onReceive(NotificationCenter.default.publisher(for: .atmusicPlayerLayoutDidChange)) { note in
            guard coverPlayerStyle != .appleMusic,
                  let rawStyle = note.userInfo?["style"] as? String,
                  rawStyle == legacyLayoutStyle.rawValue,
                  let incoming = note.userInfo?["data"] as? [String: PlayerLayoutEntry],
                  incoming != layoutData else { return }
            layoutData = incoming
        }
        .onAppear {
            if coverPlayerStyle != .appleMusic {
                let stored = PlayerLayoutStore.load(for: legacyLayoutStyle)
                if stored != layoutData { layoutData = stored }
            }
            layoutPart = PlayerLayoutPart(rawValue: layoutPartRaw) ?? .progress
            showLyrics = previewShowLyrics ?? lastLyricsPage
            if let path = LyricBackgroundStore.restoreFromBackup(), lyricBackgroundImagePath != path {
                lyricBackgroundImagePath = path
            }
            if !playerMoreSettingsHintSeen {
                playerMoreSettingsHintSeen = true
                withAnimation {
                    showMoreSettingsHint = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
                    withAnimation {
                        showMoreSettingsHint = false
                    }
                }
            }
        }
        .onChange(of: showLyrics) { newValue in
            if previewShowLyrics == nil { lastLyricsPage = newValue }
        }
        .onChange(of: previewShowLyrics) { newValue in
            guard let newValue, showLyrics != newValue else { return }
            showLyrics = newValue
        }
        .onChange(of: lastLyricsPage) { newValue in
            guard previewShowLyrics == nil else { return }
            if showLyrics != newValue { showLyrics = newValue }
        }
        .onChange(of: layoutPartRaw) { rawValue in
            layoutPart = PlayerLayoutPart(rawValue: rawValue) ?? .progress
        }
        .sheet(isPresented: $showQueue) {
            QueueView()
                .modifier(SettingsLiquidSheetPresentation())
                .environmentObject(player)
                .environmentObject(theme)
        }
        .sheet(isPresented: $showSleepTimer) { SleepTimerSheet().environmentObject(player) }
        .sheet(isPresented: $showComments) {
            if let song {
                CommentsSheet(song: song)
                    .modifier(SettingsLiquidSheetPresentation())
            }
        }
        .sheet(isPresented: $showPlayerSettings) {
            PlayerSettingsSheet(onDismiss: closePlayerSettings)
                .transaction { transaction in transaction.animation = nil }
                .environmentObject(theme)
                .environmentObject(player)
                .environmentObject(clock)
                .environmentObject(auth)
                .environmentObject(favorites)
        }
        .sheet(item: $shareFile, onDismiss: cleanupSharedFile) { item in
            ShareSheet(items: [item.url])
        }
        .sheet(isPresented: $showAddToLocalPlaylist) {
            if let song {
                AddToPlaylistSheet(song: song)
                    .modifier(SettingsLiquidSheetPresentation())
            }
        }
        .sheet(isPresented: $showSynologyMetadataEditor) {
            if let song, song.source == .synology {
                SynologyMetadataEditorSheet(song: song) { updated in
                    player.replaceSong(updated)
                }
                .transaction { transaction in transaction.animation = nil }
            }
        }
        .sheet(isPresented: $showLocalMetadataEditor) {
            if let song {
                let targetSong = song.source == .local ? song : (DownloadManager.shared.downloadedSongs.first(where: { LocalLibraryStore.isMatchingSong($0, song) }) ?? song)
                LocalSongMetadataEditorSheet(song: targetSong) { updated in
                    let saved = localLibrary.updateImportedSong(updated)
                    if saved { player.replaceSong(updated) }
                    return saved
                }
            }
        }
        .sheet(isPresented: $showLyricSearch) {
            if let song {
                SongLyricsSearchSheet(song: song, onClear: {
                    lyrics = []
                    player.updateCurrentLyrics([], for: song.identityKey)
                    Task {
                        await clearLyrics(for: song)
                    }
                }) { rawLyrics in
                    lyrics = LyricParser.parse(rawLyrics)
                    player.updateCurrentLyrics(lyrics, for: song.identityKey)
                    Task {
                        // 统一写回：NAS（内嵌标签 + 同名 .lrc + 歌词库）、本地（.lrc + 内嵌）、在线（本机缓存）；
                        // 同时覆盖本机歌词缓存，避免切歌再切回来又读到旧歌词。
                        let report = await LyricsPersistence.save(song: song, raw: rawLyrics)
                        await MainActor.run {
                            ToastCenter.shared.show(report.message)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showLyricsSync) {
            if let song {
                LyricsSyncSheet(song: song) { baked in
                    // 烘焙成功后播放页立即用新的时间轴，避免「文件已对齐、屏幕还没对齐」。
                    lyrics = LyricParser.parse(baked)
                    player.updateCurrentLyrics(lyrics, for: song.identityKey)
                }
                .environmentObject(player)
                .environmentObject(theme)
                .environmentObject(clock)
            }
        }
        .sheet(item: $selectedAlbum) { album in
            if album.source == .synology {
                ATMusicNavigationStack {
                    SynologyAlbumView(
                        albumName: album.name,
                        artistName: album.artistName,
                        coverURL: album.coverURL
                    )
                }
                .environmentObject(player)
                .environmentObject(theme)
            } else {
                ATMusicNavigationStack {
                    AlbumDetailView(album: album, isModal: true)
                }
                .environmentObject(player)
                .environmentObject(theme)
            }
        }
        .sheet(isPresented: $showSignalPath) {
            AudioSignalPathSheet(song: song)
                .presentationDetents([.medium, .large])
                .environmentObject(player)
                .environmentObject(theme)
        }
        .sheet(isPresented: $showArtistHome) {
            if !pickedArtistName.isEmpty {
                AllSourcesArtistHomeSheet(
                    artistName: pickedArtistName,
                    initialSongs: song.map { [$0] } ?? []
                )
                    .environmentObject(player)
                    .environmentObject(theme)
            }
        }
        .confirmationDialog("选择歌手", isPresented: $showArtistPicker, titleVisibility: .visible) {
            ForEach(Array(artistNames.enumerated()), id: \.offset) { _, name in
                Button(name) {
                    pickedArtistName = name
                    ATMusicHaptics.tap()
                    showArtistHome = true
                }
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog(downloadedActionDialogTitle, isPresented: $showDownloadedActionDialog, titleVisibility: .visible) {
            downloadedActionDialogButtons
        }
        .confirmationDialog(downloadDialogTitle, isPresented: $showDownloadPicker, titleVisibility: .visible) {
            downloadQualityDialogButtons
        }
        .confirmationDialog("更多操作", isPresented: $showNativeMoreActions, titleVisibility: .visible) {
            nativeMoreActionsButtons
        }
        .overlay(alignment: .bottom) {
            ToastView(center: ToastCenter.shared)
        }
    }

    private var downloadedActionDialogTitle: String {
        "已离线歌曲：\(song?.name ?? "")"
    }

    @ViewBuilder
    private var downloadedActionDialogButtons: some View {
        Button("从本地移除下载", role: .destructive) {
            if let song {
                DownloadManager.shared.removeDownloaded(song: song)
                ToastCenter.shared.show("已从本地移除下载")
            }
        }
        Button("重新下载 (更换音质)") {
            showDownloadPicker = true
        }
        if let song, song.source != .synology {
            Button("转档到群晖 NAS") {
                DownloadManager.shared.startUploadToNAS(song: song)
            }
        }
        Button("查看本地音频参数") {
            if let song, let url = DownloadManager.shared.localAudioURL(for: song) {
                let ext = url.pathExtension.uppercased()
                var sizeStr = "未知大小"
                if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let size = attrs[.size] as? NSNumber {
                    sizeStr = ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .file)
                }
                ToastCenter.shared.show("本地音轨：\(ext) · \(sizeStr)")
            }
        }
        if let song, let url = DownloadManager.shared.localAudioURL(for: song) {
            Button("隔空投送 / 导出") {
                shareFile = ShareFileItem(url: url)
            }
        }
        Button("取消", role: .cancel) {}
    }

    private var downloadDialogTitle: String {
        if let name = song?.name, !name.isEmpty {
            return "下载《\(name)》"
        }
        return "下载当前歌曲"
    }

    @ViewBuilder
    private var downloadQualityDialogButtons: some View {
        ForEach(downloadQualityOptions, id: \.self) { quality in
            Button(quality.displayName) {
                Task { await downloadCurrent(quality) }
            }
        }
        Button("取消", role: .cancel) {}
    }

    @ViewBuilder
    private var nativeMoreActionsButtons: some View {
        if song?.album.isEmpty == false {
            Button("查看专辑") { openAlbumDetail() }
        }
        if song?.source == .synology {
            Button("编辑歌曲信息、封面与歌词") { showSynologyMetadataEditor = true }
        } else if song?.source == .local {
            Button("编辑歌曲信息") { showLocalMetadataEditor = true }
        }
        Button("定时关闭") { showSleepTimer = true }
        Button("添加到本地歌单") { showAddToLocalPlaylist = true }
        moreActionDownloadButtons
        Button("播放器设置") { openPlayerSettings() }
        Button("取消", role: .cancel) {}
    }

    @ViewBuilder
    private var moreActionDownloadButtons: some View {
        if downloadFeatureUnlocked {
            if let song, DownloadManager.shared.isDownloaded(song: song) {
                if song.source != .synology {
                    Button("转档到群晖 NAS") { DownloadManager.shared.startUploadToNAS(song: song) }
                }
                Button("从本地移除下载", role: .destructive) { DownloadManager.shared.removeDownloaded(song: song) }
                Button("重新下载 (更换音质)") { showDownloadPicker = true }
            } else {
                Button(song?.source == .synology ? "离线下载到本机" : "离线下载歌曲") { showDownloadPicker = true }
                if let song, song.source != .synology {
                    Button("转档到群晖 NAS") { DownloadManager.shared.startUploadToNAS(song: song) }
                }
            }
        }
    }

    // MARK: - 背景（主题渐变兜底 + 封面毛玻璃 + 可读性遮罩）
    // 毛玻璃封面为 UIKit 独立图层（CoverBlurBackground），加载/换图不经过 SwiftUI
    // 布局，因此封面加载完成不会引发布局重算，彻底避免"封面加载后错乱"。

    private var background: some View {
        ZStack {
            // 静态渐变：随封面主色取色，不流动（用户要求封面外液态 UI 飘动效果暂停，保持静止）
            LinearGradient(
                colors: [palette.backgroundTop, palette.backgroundBottom],
                startPoint: .top, endPoint: .bottom
            )
            if !lyricBackgroundImagePath.isEmpty && (showLyrics || lyricBackgroundSyncCover) {
                lyricPlayerBackgroundLayer
            } else if theme.backgroundSyncAll, let image = theme.customBackgroundImage(for: colorScheme) {
                WallpaperImage(image: image)
                LinearGradient(
                    colors: colorScheme == .dark
                        ? [.black.opacity(0.40), .black.opacity(0.58)]
                        : [.white.opacity(0.12), .black.opacity(0.24)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            } else {
                CoverBlurBackground(url: song?.coverURL, scheme: colorScheme)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            AmbientGlowView(
                accent: palette.accent,
                secondary: palette.secondary,
                isPlaying: playerVisualsActive,
                dustMode: playerDustMode,
                dustDensity: playerDustDensity,
                dustSize: playerDustSize,
                breath: playerBreath
            )
            if djVisualEnabled && !reduceVisualMotion {
                DJVisualView(
                    accent: palette.accent,
                    secondary: palette.secondary,
                    isPlaying: playerVisualsActive,
                    intensity: djVisualIntensity
                )
            }
            LinearGradient(
                colors: colorScheme == .dark
                    ? [.black.opacity(0.22), .clear, .black.opacity(0.34)]
                    : [.white.opacity(0.08), .clear, .black.opacity(0.12)],
                startPoint: .top, endPoint: .bottom
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var lyricPlayerBackgroundLayer: some View {
        if let image = ATMusicImageFileCache.image(at: lyricBackgroundImagePath) {
            GeometryReader { proxy in
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width + 96, height: proxy.size.height + 96)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                    .blur(radius: CGFloat(lyricBackgroundBlur))
                    .overlay(Color.black.opacity(colorScheme == .dark ? 0.48 : 0.34))
                    .clipped()
            }
            .ignoresSafeArea()
        } else {
            CoverBlurBackground(url: song?.coverURL, scheme: colorScheme)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - 顶栏（收起 / 状态 / 红心 / 队列）

    @ViewBuilder
    private var headerBar: some View {
        HStack(spacing: 12) {
            Button {
                ATMusicHaptics.tap()
                closePlayer()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(playerButtonText)
                    .frame(width: 38, height: 38)
                    .background {
                        playerButtonSurface(size: 38)
                    }
                    .clipShape(Circle())
            }
            .buttonStyle(GlassPressButtonStyle())
            .modifier(Layoutable(part: .topBack, enabled: layoutMode, data: $layoutData, style: legacyLayoutStyle))

            Spacer(minLength: 0)

            Button {
                ATMusicHaptics.tap()
                showNativeMoreActions = true
            } label: {
                VStack(spacing: 2) {
                    Text(LocalizedStringKey(player.isBuffering ? "加载中…" : (player.isPlaying ? "正在播放" : "已暂停")))
                        .font(ATMusicFont.appFont(12, .semibold))
                        .foregroundStyle(palette.secondary)
                        .lineLimit(1)
                    Text(song?.album ?? "AT Music")
                        .font(ATMusicFont.appFont(10))
                        .foregroundStyle(palette.secondary.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(minWidth: 118, maxWidth: 190)
                .contentShape(Rectangle())
            }
            .buttonStyle(GlassPressButtonStyle(scale: 0.98))
            .modifier(Layoutable(part: .topTitle, enabled: layoutMode, data: $layoutData, style: legacyLayoutStyle))

            Spacer(minLength: 0)
            Button {
                ATMusicHaptics.tap()
                if let song {
                    toggleFavorite(song)
                }
            } label: {
                let liked = favorites.isSongLiked(song)
                Image(systemName: liked ? "heart.fill" : "heart")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(liked ? Color(red: 0.95, green: 0.33, blue: 0.42) : playerButtonText)
                    .frame(width: 38, height: 38)
                    .background {
                        playerButtonSurface(size: 38, active: liked)
                    }
                    .clipShape(Circle())
            }
            .buttonStyle(GlassPressButtonStyle())
            .modifier(Layoutable(part: .topFavorite, enabled: false, data: $layoutData, style: legacyLayoutStyle))
        }
        .padding(.horizontal, 20)
        .padding(.top, 2)
        .padding(.bottom, 1)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 15)
                .onEnded { value in
                    if value.translation.height > 35 && abs(value.translation.width) < value.translation.height {
                        ATMusicHaptics.tap()
                        closePlayer()
                    }
                }
        )
    }

    // MARK: - 中间内容区（专辑 / 歌词 两模式独立视图，自动布局居中）

    @ViewBuilder
    private func content(geo: GeometryProxy) -> some View {
        ZStack {
            if song == nil {
                placeholderView
            } else if coverPlayerStyle == .vinyl {
                // 黑胶布局参考 kumone 的 Now Playing / Vinyl 页面结构，保留 AT Music 自己的控制逻辑。
                if showLyrics {
                    vinylLyricsPanel(geo: geo)
                        .transition(.opacity)
                } else {
                    vinylAlbumPanel(geo: geo)
                        .transition(.opacity)
                }
            } else if showLyrics {
                lyricsPanel(geo: geo)
                    .transition(.opacity)
            } else {
                albumPanel(geo: geo)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.default, value: showLyrics)
    }

    /// 封面尺寸：固定算法，与布局时序无关
    private func coverSize(in geo: GeometryProxy) -> CGFloat {
        // 经典封面参考图的基线尺寸。组件默认 scale=1.00 时就应是目标大小，
        // 不再靠布局存储里的 0.82 二次缩放来“凑”视觉。
        min(230, min(geo.size.width * 0.50, geo.size.height * 0.36))
    }

    /// 专辑模式：封面居中 + 歌名/歌手 + 轻点提示（VStack 自动居中）
    @ViewBuilder
    private func albumPanel(geo: GeometryProxy) -> some View {
        switch coverPlayerStyle {
        case .classic, .appleMusic:
            classicAlbumPanel(geo: geo)
        case .vinyl:
            vinylAlbumPanel(geo: geo)
        case .immersive:
            classicAlbumPanel(geo: geo)
        }
    }

    private func vinylAlbumPanel(geo: GeometryProxy) -> some View {
        // 参考用户提供的唱片模式真机图：唱盘是页面视觉中心，歌名/歌手在唱盘下方，
        // 不再额外放一套顶部小封面 Header。布局编辑器的 X=0 / Y=20 就对应这套基线。
        let size = min(304, min(geo.size.width * 0.72, geo.size.height * 0.45))
        let showPreview = !lyrics.isEmpty
        return VStack(spacing: 0) {
            Spacer(minLength: 6)

            VinylTurntableView(
                coverURL: song?.coverURL,
                isPlaying: playerVisualsActive,
                reduceMotion: reduceVisualMotion,
                trackId: song?.id,
                size: size,
                onTap: { toggleLyrics() },
                onNextTrack: { player.next() },
                onPreviousTrack: { player.previous() }
            )
            .modifier(AppleMusicLayoutTransform(entry: vinylLayoutEntry(.vinylAlbum)))

            centeredVinylTrackTitle
                .padding(.horizontal, 34)
                .padding(.top, 12)
                .modifier(AppleMusicLayoutTransform(entry: vinylLayoutEntry(.title)))

            if showPreview {
                vinylMiniLyricsPreview
                    .padding(.top, 10)
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 4)
        .padding(.bottom, deckInset + geo.safeAreaInsets.bottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var vinylMiniLyricsPreview: some View {
        let rows = lyricPreviewRows
        return VStack(spacing: 5) {
            if rows.isEmpty {
                Text("暂无歌词，点击唱盘查看完整歌词")
                    .font(ATMusicFont.appFont(12))
                    .foregroundStyle(albumPreviewDimForeground)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 6) {
                        Text(item.isCurrent ? "●" : "·")
                            .font(ATMusicFont.appFont(8))
                            .foregroundStyle(item.isCurrent ? albumPreviewLyricColor : albumPreviewDimColor.opacity(0.5))
                        Text(item.text)
                            .font(ATMusicFont.appFont(12, item.isCurrent ? .semibold : .regular))
                            .foregroundStyle(item.isCurrent ? albumPreviewForeground : albumPreviewDimForeground)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(height: 5 * 18 + 4 * 3)
        .padding(.horizontal, 40)
        .contentShape(Rectangle())
        .onTapGesture { toggleLyrics() }
    }

    private func vinylLyricsPanel(geo: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            vinylLyricsHeader
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                .modifier(AppleMusicLayoutTransform(entry: vinylLayoutEntry(.vinylLyricsHeader)))
                .zIndex(3)

            Spacer(minLength: 0)

            Group {
                if lyrics.isEmpty {
                    vinylEmptyLyricsView
                } else {
                    let align: HorizontalAlignment = (lyricAlignRaw == "left") ? .leading : .center
                    if #available(iOS 18.0, *) {
                        ScrollView(showsIndicators: false) {
                            LazyVStack(alignment: align, spacing: CGFloat(lyricLineSpacing)) {
                                Color.clear.frame(height: max(vinylLyricsLineSlotHeight * CGFloat(VinylLayoutDefaults.lyricTopRows), 110))
                                ForEach(lyrics.indices, id: \.self) { index in
                                    vinylLyricLine(lyrics[index], isFocused: vinylCurrentVisualIndex == index)
                                        .id(index)
                                }
                                Color.clear.frame(height: max(vinylLyricsLineSlotHeight * CGFloat(VinylLayoutDefaults.lyricBottomRows), 110))
                            }
                            .scrollTargetLayout()
                            .padding(.horizontal, 28)
                        }
                        .scrollPosition(id: $vinylScrollTarget, anchor: .center)
                        .rotation3DEffect(.degrees(Double(lyricTilt)), axis: (x: 1, y: 0, z: 0))
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0.0),
                                    .init(color: .black, location: 0.12),
                                    .init(color: .black, location: 0.84),
                                    .init(color: .clear, location: 1.0)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .onScrollPhaseChange { _, phase in
                            switch phase {
                            case .tracking, .interacting, .decelerating:
                                vinylIsUserScrolling = true
                                vinylLyricsResumeTask?.cancel()
                            case .idle:
                                vinylScheduleLyricsResume()
                            case .animating:
                                break
                            @unknown default:
                                break
                            }
                        }
                        .onAppear { vinylScrollTarget = vinylCurrentLyricIndex }
                        .onChange(of: vinylCurrentLyricIndex) { newIndex in
                            guard let newIndex, !vinylIsUserScrolling else { return }
                            var transaction = Transaction()
                            transaction.animation = nil
                            withTransaction(transaction) {
                                vinylScrollTarget = newIndex
                            }
                        }
                    } else {
                        ScrollView(showsIndicators: false) {
                            LazyVStack(alignment: align, spacing: CGFloat(lyricLineSpacing)) {
                                ForEach(lyrics.indices, id: \.self) { index in
                                    vinylLyricLine(lyrics[index], isFocused: vinylCurrentLyricIndex == index)
                                }
                            }
                            .padding(.horizontal, 28)
                        }
                        .rotation3DEffect(.degrees(Double(lyricTilt)), axis: (x: 1, y: 0, z: 0))
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: vinylLyricsViewportHeightLimit(in: geo))
            .modifier(AppleMusicLayoutTransform(entry: vinylLayoutEntry(.vinylLyricsText)))
            .zIndex(1)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            activeVinylLyricIndex = computeVinylLyricIndex(for: clock.progress)
        }
        .onChange(of: clock.progress) { newProgress in
            let newIndex = computeVinylLyricIndex(for: newProgress)
            if newIndex != activeVinylLyricIndex {
                activeVinylLyricIndex = newIndex
            }
        }
        .onDisappear {
            vinylLyricsResumeTask?.cancel()
        }
    }

    private var vinylLyricsHeader: some View {
        HStack(spacing: 12) {
            Button {
                ATMusicHaptics.tap()
                toggleLyrics()
            } label: {
                CoverImage(url: song?.coverURL, size: 48, cornerRadius: 10)
                    .shadow(color: .black.opacity(0.26), radius: 9, y: 4)
            }
            .buttonStyle(GlassPressButtonStyle(scale: 0.94))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(song?.name ?? "未在播放")
                        .font(ATMusicFont.appFont(15, .semibold))
                        .foregroundStyle(albumTitleForeground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if showSongVIPBadge, song?.isVIP == true {
                        SongVIPBadgeView()
                    }
                    if let source = song?.source {
                        SourceBadgeView(source: source, compact: true)
                    }
                    AudioQualityCapsule(song: song)
                }
                SongSubtitleMenu(
                    song: song,
                    font: ATMusicFont.appFont(12, .medium),
                    foregroundStyle: albumArtistForeground,
                    alignment: .leading,
                    onSelectArtist: { artist in
                        pickedArtistName = artist
                        showArtistHome = true
                    },
                    onSelectAlbum: { album in
                        selectedAlbum = album
                    }
                )
            }
            Spacer(minLength: 0)

            Button {
                ATMusicHaptics.tap()
                guard let song else { return }
                toggleFavorite(song)
            } label: {
                let liked = favorites.isSongLiked(song)
                Image(systemName: liked ? "heart.fill" : "heart")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(liked ? Color(red: 0.95, green: 0.33, blue: 0.42) : albumTitleColor.opacity(0.78))
                    .frame(width: 38, height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button("音频信号通路") { showSignalPath = true }
                Button("定时关闭") { showSleepTimer = true }
                Button("搜索歌词") { showLyricSearch = true }
                Button("歌词同步校准") { showLyricsSync = true }
                Button("添加到本地歌单") { showAddToLocalPlaylist = true }
                if downloadFeatureUnlocked {
                    Button("下载歌曲") { showDownloadPicker = true }
                }
                Button("播放器设置") { openPlayerSettings() }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(albumTitleForeground.opacity(0.82))
                    .frame(width: 38, height: 38)
                    .contentShape(Rectangle())
            }
        }
        .frame(maxWidth: 420)
    }

    private var centeredVinylTrackTitle: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Text(song?.name ?? "未在播放")
                    .font(ATMusicFont.appFont(17, .bold))
                    .foregroundStyle(albumTitleForeground)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if showSongVIPBadge, song?.isVIP == true {
                    SongVIPBadgeView()
                }
            }
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)

            HStack(spacing: 6) {
                SongSubtitleMenu(
                    song: song,
                    font: ATMusicFont.appFont(12.5, .medium),
                    foregroundStyle: albumArtistForeground,
                    alignment: .center,
                    onSelectArtist: { artist in
                        pickedArtistName = artist
                        showArtistHome = true
                    },
                    onSelectAlbum: { album in
                        selectedAlbum = album
                    }
                )
                HStack(spacing: 6) {
                    if let source = song?.source {
                        SourceBadgeView(source: source, compact: true)
                    }
                    AudioQualityCapsule(song: song)
                }
            }
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
        }
    }

    private var vinylEmptyLyricsView: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "quote.bubble")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(albumArtistForeground.opacity(0.5))
            Text("暂无歌词")
                .font(ATMusicFont.appFont(15, .semibold))
                .foregroundStyle(albumTitleForeground.opacity(0.9))
            Text("点击封面区域返回歌曲页面")
                .font(ATMusicFont.appFont(12))
                .foregroundStyle(albumArtistForeground.opacity(0.56))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            ATMusicHaptics.tap()
            toggleLyrics()
        }
    }

    private func vinylLyricLine(_ line: LyricLine, isFocused: Bool) -> some View {
        Button {
            ATMusicHaptics.tap()
            player.seek(to: LyricTiming.seekTime(for: line, userOffset: activeLyricOffset))
        } label: {
            // 黑胶样式：双语翻译受开关控制，无译文高度为 0；行高跟随内容自然撑开
            let translation = (lyricTranslation && line.translation?.isEmpty == false) ? line.translation : nil
            let primarySize = CGFloat(lyricFontSize) * 1.35
            let translationSize = max(11, primarySize * 0.65)
            let focusedColor = (lyricGradMode == 1) ? lyricCurrentColor : palette.accent
            let dimColor = (lyricGradMode == 1) ? lyricDimColor : palette.secondary
            let glowCol = lyricGlowColor ?? focusedColor
            let align: HorizontalAlignment = (lyricAlignRaw == "left") ? .leading : .center

            VStack(alignment: align, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if align == .center { Spacer(minLength: 0) }
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(ATMusicFont.appFont(primarySize, .semibold))
                        .foregroundStyle(focusedColor.opacity(isFocused ? 1 : 0.36))
                        .shadow(
                            color: isFocused ? glowCol.opacity(lyricGlowRadius > 0 ? 0.9 : 0) : .clear,
                            radius: isFocused ? lyricGlowRadius * 0.45 : 0
                        )
                        .shadow(
                            color: isFocused ? glowCol.opacity(lyricGlowRadius > 0 ? 0.55 : 0) : .clear,
                            radius: isFocused ? lyricGlowRadius : 0
                        )
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                    if align != .center {
                        Spacer(minLength: 8)
                        Text(atmusicTimeString(line.time))
                            .font(ATMusicFont.appFont(11, .semibold, .monospaced))
                            .foregroundStyle(dimColor.opacity(isFocused && vinylIsUserScrolling ? 0.82 : 0))
                            .frame(width: 42, alignment: .trailing)
                    } else {
                        Spacer(minLength: 0)
                    }
                }
                if let translation {
                    Text(translation)
                        .font(ATMusicFont.appFont(translationSize, .medium))
                        .foregroundStyle(dimColor.opacity(isFocused ? 0.68 : 0))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .accessibilityHidden(!isFocused)
                }
            }
            .multilineTextAlignment(align == .leading ? .leading : .center)
            .frame(maxWidth: .infinity, alignment: align == .leading ? .leading : .center)
            .contentShape(Rectangle())
            .scaleEffect(isFocused ? 1.16 : 0.92, anchor: align == .leading ? .leading : .center)
            .blur(radius: isFocused ? 0 : CGFloat(lyricBlurAmount) * 0.7)
        }
        .buttonStyle(.plain)
    }

    private func computeVinylLyricIndex(for progress: Double) -> Int? {
        guard !lyrics.isEmpty else { return nil }
        let effective = LyricTiming.effectiveProgress(progress, userOffset: activeLyricOffset)
        var low = 0
        var high = lyrics.count - 1
        var answer: Int?
        while low <= high {
            let mid = (low + high) / 2
            if lyrics[mid].time <= effective {
                answer = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return answer
    }

    /// 事件驱动缓存：由 .onChange(of: clock.progress) 维护，避免逐行 ForEach 重复二分查找
    private var vinylCurrentLyricIndex: Int? {
        activeVinylLyricIndex
    }

    private var vinylCurrentVisualIndex: Int? {
        vinylIsUserScrolling ? (vinylScrollTarget ?? vinylCurrentLyricIndex) : vinylCurrentLyricIndex
    }

    private var vinylLyricsLineSlotHeight: CGFloat {
        max(56, CGFloat(lyricFontSize) * 1.9 + CGFloat(lyricLineSpacing))
    }

    private var vinylLyricsFocusAnchor: UnitPoint { .center }

    private func vinylLyricsViewportHeightLimit(in geo: GeometryProxy) -> CGFloat {
        let desired = CGFloat(VinylLayoutDefaults.lyricTopRows + VinylLayoutDefaults.lyricBottomRows + 1) * vinylLyricsLineSlotHeight
        let available = max(220, geo.size.height - 100)
        return min(max(220, desired), available)
    }

    private func vinylScheduleLyricsResume() {
        vinylLyricsResumeTask?.cancel()
        vinylLyricsResumeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            vinylIsUserScrolling = false
            if let current = vinylCurrentLyricIndex {
                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) {
                    vinylScrollTarget = current
                }
            }
            vinylLyricsResumeTask = nil
        }
    }


    private func classicAlbumPanel(geo: GeometryProxy) -> some View {
        let size = coverSize(in: geo)
        let coverRadius: CGFloat = circularCover ? size / 2 : min(24, size * 0.08)
        return VStack(spacing: 12) {
            Spacer(minLength: 0)

            Button {
                toggleLyrics()
            } label: {
                ZStack {
                    // 静态装饰层（光晕 + 托盘）：不再呼吸/浮动（用户要求飘动效果暂停），封面本体静止
                    ZStack {
                            // 主色光晕（呼吸）
                            Circle()
                                .fill(palette.accent.opacity(0.24))
                                .frame(width: size * 1.38, height: size * 1.38)
                                .blur(radius: 46)
                                .scaleEffect(1.0)
                            // 次色光晕（反向呼吸，增加层次）
                            Circle()
                                .fill(palette.secondary.opacity(0.15))
                                .frame(width: size * 1.10, height: size * 1.10)
                                .blur(radius: 40)
                                .scaleEffect(1.0)
                            // 液态玻璃托盘（圆形模式用圆形托盘）
                            if circularCover {
                                ATMusicGlass(shape: Circle())
                                    .frame(width: size * 1.10, height: size * 1.10)
                                    .shadow(color: .black.opacity(0.28), radius: 26, y: 12)
                                    .offset(y: 0)
                            } else {
                                ATMusicGlass(shape: RoundedRectangle(cornerRadius: min(30, size * 0.10), style: .continuous))
                                    .frame(width: size * 1.10, height: size * 1.10)
                                    .shadow(color: .black.opacity(0.28), radius: 26, y: 12)
                                    .offset(y: 0)
                            }
                        }
                    .allowsHitTesting(false)

                    // 封面（静态）
                    CoverImage(url: song?.coverURL, size: size, cornerRadius: coverRadius, emptyHint: player.isBuffering ? "等待开始播放…" : nil)
                        .matchedGeometryEffect(id: "playerCover", in: coverNS)
                        .id(song?.identityKey ?? "empty-cover")
                        .modifier(CoverSpin(enabled: circularCover && circularCoverSpin, isPlaying: playerVisualsActive))
                        .overlay {
                            RoundedRectangle(cornerRadius: coverRadius, style: .continuous)
                                .strokeBorder(.white.opacity(0.28), lineWidth: 1)
                        }
                        .overlay {
                            // 顶部玻璃反光
                            RoundedRectangle(cornerRadius: coverRadius, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [.white.opacity(0.28), .white.opacity(0.03), .clear],
                                        startPoint: .top, endPoint: .center
                                    )
                                )
                        }
                        .clipShape(RoundedRectangle(cornerRadius: coverRadius, style: .continuous))
                        .shadow(color: .black.opacity(0.38), radius: 24, y: 12)
                        .rotation3DEffect(.degrees(Double(coverDrag.height / -18)), axis: (x: 1, y: 0, z: 0), perspective: 0.55)
                        .rotation3DEffect(.degrees(Double(coverDrag.width / 18)), axis: (x: 0, y: 1, z: 0), perspective: 0.55)
                        .offset(x: coverDrag.width * 0.05, y: coverDrag.height * 0.05)
                }
                .frame(width: size * 1.10, height: size * 1.10)
                .gesture(
                    DragGesture(minimumDistance: 15)
                        .onChanged { value in
                            guard swipeSwitchSong else { return }
                            coverDrag = value.translation
                            let x = value.translation.width
                            if abs(x) > abs(value.translation.height) {
                                swipeOffset = x
                            }
                        }
                        .onEnded { value in
                            handleSwipeEnd(horizontal: value.translation.width)
                        }
                )
            }
            .buttonStyle(GlassPressButtonStyle(scale: 0.96))
            .modifier(Layoutable(part: .cover, enabled: layoutMode, data: $layoutData, style: legacyLayoutStyle))

            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Text(song?.name ?? "未在播放")
                        .font(ATMusicFont.appFont(22, .bold))
                        .foregroundStyle(albumTitleForeground)
                        .lineLimit(2)
                        .minimumScaleFactor(0.55)
                        .multilineTextAlignment(.center)
                        .shadow(color: albumGlow(albumTitleColor, strong: true), radius: albumTextGlow ? 10 : 0, y: 2)
                    if showSongVIPBadge, song?.isVIP == true {
                        SongVIPBadgeView()
                    }
                    if let source = song?.source {
                        SourceBadgeView(source: source, compact: true)
                    }
                    AudioQualityCapsule(song: song)
                }
                .shadow(color: albumTextGlow ? palette.accent.opacity(0.30) : .clear, radius: albumTextGlow ? 10 : 0)
                SongSubtitleMenu(
                    song: song,
                    font: ATMusicFont.appFont(14, .medium),
                    foregroundStyle: albumArtistForeground,
                    alignment: .center,
                    onSelectArtist: { artist in
                        pickedArtistName = artist
                        showArtistHome = true
                    },
                    onSelectAlbum: { album in
                        selectedAlbum = album
                    }
                )
                .shadow(color: albumGlow(albumArtistColor), radius: albumTextGlow ? 7 : 0, y: 1)
            }
            .padding(.horizontal, 36)
            .modifier(Layoutable(part: .title, enabled: layoutMode, data: $layoutData, style: legacyLayoutStyle))


            // 封面下歌词阅览（固定高度预留，歌词加载后布局不跳动）
            lyricPreviewBox
                .modifier(Layoutable(part: .previewLyric, enabled: layoutMode, data: $layoutData, style: legacyLayoutStyle))

            Spacer(minLength: 0)
        }
        .padding(.bottom, deckInset + geo.safeAreaInsets.bottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 左右滑动切歌：左滑下一首、右滑上一首，仅响应横向手势。
        // 使用 .gesture 与封面点击互斥：拖动时不会误触点击封面。
        .offset(x: swipeOffset)
        .opacity(CGFloat(1) - min(abs(swipeOffset) / CGFloat(260), CGFloat(0.35)))
        .gesture(
            DragGesture(minimumDistance: 15)
                .onChanged { value in
                    guard swipeSwitchSong else { return }
                    coverDrag = value.translation
                    let x = value.translation.width
                    if abs(x) > abs(value.translation.height) {
                        swipeOffset = x
                    }
                }
                .onEnded { value in
                    handleSwipeEnd(horizontal: value.translation.width)
                }
        )
    }


    /// 封面下歌词阅览：最多 5 行，跟随当前播放行自动滚动预览
    private var lyricPreviewBox: some View {
        let rows = lyricPreviewRows
        return VStack(spacing: 3) {
            if rows.isEmpty {
                Text("暂无歌词，点击封面查看完整歌词")
                    .font(ATMusicFont.appFont(12))
                    .foregroundStyle(albumPreviewDimForeground)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, item in
                    HStack(spacing: 6) {
                        Text(item.isCurrent ? "●" : "·")
                            .font(ATMusicFont.appFont(8))
                            .foregroundStyle(item.isCurrent ? albumPreviewLyricColor : albumPreviewDimColor.opacity(0.5))
                        Text(item.text)
                            .font(ATMusicFont.appFont(12, item.isCurrent ? .semibold : .regular))
                            .foregroundStyle(item.isCurrent ? albumPreviewForeground : albumPreviewDimForeground)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .shadow(color: albumGlow(item.isCurrent ? albumPreviewLyricColor : albumPreviewDimColor), radius: albumTextGlow && item.isCurrent ? 8 : 0, y: 1)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(height: 5 * 18 + 4 * 3)
        .padding(.horizontal, 40)
        .contentShape(Rectangle())
        .onTapGesture { toggleLyrics() }
    }

    /// 歌词预览行数据：当前行前后各取几行，最多 5 行
    private struct LyricPreviewRow {
        let text: String
        let isCurrent: Bool
    }

    /// 当前歌词行索引（二分查找，与歌词面板一致）
    private var previewCurrentIndex: Int? {
        guard !lyrics.isEmpty else { return nil }
        var low = 0
        var high = lyrics.count - 1
        var answer: Int?
        while low <= high {
            let mid = (low + high) / 2
            if lyrics[mid].time <= LyricTiming.effectiveProgress(clock.progress, userOffset: activeLyricOffset) {
                answer = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return answer
    }

    private var lyricPreviewRows: [LyricPreviewRow] {
        guard !lyrics.isEmpty else { return [] }
        var rows: [LyricPreviewRow] = []
        if let idx = previewCurrentIndex {
            let start = max(0, idx - 2)
            for i in start..<min(lyrics.count, start + 5) {
                let text = lyrics[i].text
                rows.append(LyricPreviewRow(text: text.isEmpty ? " " : text, isCurrent: i == idx))
            }
        } else {
            for i in 0..<min(5, lyrics.count) {
                let text = lyrics[i].text
                rows.append(LyricPreviewRow(text: text.isEmpty ? " " : text, isCurrent: i == 0))
            }
        }
        return rows
    }


    /// 歌词模式：左上小封面 + 歌名信息条 + 居中歌词（自动布局，歌词可滚动到底部透过底栏玻璃）
    @ViewBuilder
    private func lyricsPanel(geo: GeometryProxy) -> some View {
        ZStack {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                Button {
                    toggleLyrics()
                } label: {
                    CoverImage(url: song?.coverURL, size: 48, cornerRadius: circularCover ? 24 : 12)
                        .matchedGeometryEffect(id: "playerCover", in: coverNS)
                        .modifier(CoverSpin(enabled: circularCover && circularCoverSpin, isPlaying: playerVisualsActive))
                        .overlay {
                            RoundedRectangle(cornerRadius: circularCover ? 24 : 12, style: .continuous)
                                .strokeBorder(.white.opacity(0.2), lineWidth: 1)
                        }
                }
                .buttonStyle(GlassPressButtonStyle(scale: 0.9))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(song?.name ?? "")
                            .font(ATMusicFont.appFont(14, .semibold))
                            .foregroundStyle(palette.text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if showSongVIPBadge, song?.isVIP == true {
                            SongVIPBadgeView()
                        }
                        if let source = song?.source {
                            SourceBadgeView(source: source, compact: true)
                        }
                        AudioQualityCapsule(song: song)
                    }
                    HStack(spacing: 8) {
                        SongSubtitleMenu(
                            song: song,
                            font: ATMusicFont.appFont(12),
                            color: palette.secondary,
                            alignment: .leading,
                            onSelectArtist: { artist in
                                pickedArtistName = artist
                                showArtistHome = true
                            },
                            onSelectAlbum: { album in
                                selectedAlbum = album
                            }
                        )
                        Text(atmusicTimeString(clock.progress))
                            .font(ATMusicFont.appFont(11, .medium))
                            .foregroundStyle(palette.secondary.opacity(0.78))
                            .monospacedDigit()
                    }
                }

                Spacer(minLength: 0)

                Button {
                    ATMusicHaptics.tap()
                    guard let song else { return }
                    toggleFavorite(song)
                } label: {
                    let liked = favorites.isSongLiked(song)
                    Image(systemName: liked ? "heart.fill" : "heart")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(liked ? Color(red: 0.95, green: 0.33, blue: 0.42) : palette.text.opacity(0.80))
                        .frame(width: 38, height: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Menu {
                    Button("音频信号通路") { showSignalPath = true }
                    Button("定时关闭") { showSleepTimer = true }
                    Button("搜索歌词") { showLyricSearch = true }
                    Button("歌词同步校准") { showLyricsSync = true }
                    Button("歌曲信息") { openSongInfo() }
                    Button("添加到歌单") { showAddToLocalPlaylist = true }
                    if downloadFeatureUnlocked {
                        Button("下载歌曲") { showDownloadPicker = true }
                        if let song, song.source != .synology {
                            Button("转档到群晖 NAS") { DownloadManager.shared.startUploadToNAS(song: song) }
                        }
                    }
                    if song?.source == .synology {
                        Button("编辑 NAS 标签、封面与歌词") { showSynologyMetadataEditor = true }
                    } else if song?.source == .local || (song != nil && DownloadManager.shared.isDownloaded(song: song!)) {
                        Button("编辑歌曲信息与封面") { showLocalMetadataEditor = true }
                    }
                    Button("播放器设置") { openPlayerSettings() }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(palette.text.opacity(0.80))
                        .frame(width: 38, height: 38)
                        .contentShape(Rectangle())
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 0)
            .padding(.bottom, 0)

            // 歌词视口截止到底栏上方：当前行在可见区居中（26 版风格，无渐隐遮挡）
            Group {
                if lyrics.isEmpty {
                    emptyLyricsView
                } else {
                    LyricsSection(
                        lyrics: lyrics,
                        accent: lyricCurrentColor,
                        secondary: lyricDimColor,
                        gradientStart: lyricGradStart,
                        gradientEnd: lyricGradEnd,
                        baseFontSize: CGFloat(lyricFontSize) * CGFloat(lyricScale),
                        lineSpacing: CGFloat(lyricLineSpacing),
                        glowRadius: lyricGlowRadius,
                        showTranslation: lyricTranslation,
                        alignment: lyricAlign,
                        offsetX: CGFloat(lyricOffsetX),
                        anchor: lyricAnchor,
                        glowColorOverride: lyricGlowColor,
                        blurStart: CGFloat(lyricBlurStart),
                        blurAmount: CGFloat(lyricBlurAmount),
                        tilt: CGFloat(lyricTilt),
                        tiltY: CGFloat(lyricTiltY),
                        lyricOffset: CGFloat(activeLyricOffset)
                    ) { line in
                        ATMusicHaptics.tap()
                        player.seek(to: LyricTiming.seekTime(for: line, userOffset: activeLyricOffset))
                    }
                    .offset(y: CGFloat(lyricAnchorY))
                }
            }
            .padding(.bottom, deckInset + geo.safeAreaInsets.bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id("lyricsPanel-\(song?.identityKey ?? "none")")
    }

    // MARK: - 空态兜底（歌曲数据为空时不出现空白页）

    private var placeholderView: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(palette.secondary)
            Text("暂无播放内容")
                .font(ATMusicFont.appFont(16, .medium))
                .foregroundStyle(palette.text)
            Text("返回选择一首歌曲即可开始播放")
                .font(ATMusicFont.appFont(13))
                .foregroundStyle(palette.secondary)
            Button {
                ATMusicHaptics.tap()
                closePlayer()
            } label: {
                Text("返回")
                    .font(ATMusicFont.appFont(14, .semibold))
                    .foregroundStyle(palette.text)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 10)
                    .background {
                                                ATMusicGlass(shape: Capsule())
                    }
            }
            .buttonStyle(GlassPressButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 空歌词兜底

    private var emptyLyricsView: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 40)
            VStack(spacing: 10) {
                Image(systemName: "quote.bubble")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(palette.secondary.opacity(0.7))
                Text("暂无歌词")
                    .font(ATMusicFont.appFont(14, .medium))
                    .foregroundStyle(palette.text)
                Text("点击左上角封面返回专辑视图")
                    .font(ATMusicFont.appFont(11))
                    .foregroundStyle(palette.secondary.opacity(0.8))
            }
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 底部控制栏（旧式悬浮布局：进度 / 主控制）

    /// 底部控制栏估算高度（单行控制后降低，给歌词视口更多空间）
    /// 底部控制栏预留高度（越小歌词视口越大；需 >= 控制栏实际高度避免遮挡；可视化开启时控制栏更高）
    private var deckInset: CGFloat { 102 }

    @ViewBuilder
    private func controlDeck(bottomInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            if coverPlayerStyle == .vinyl {
                vinylKumoneProgress
                    .modifier(AppleMusicLayoutTransform(entry: vinylLayoutEntry(.progress)))

                vinylKumoneControlRow
                    .modifier(AppleMusicLayoutTransform(entry: vinylLayoutEntry(.controls)))
            } else {
                progressBlock(
                    styleOverride: playerButtonStyle == .appleMusic ? 0 : nil,
                    accentOverride: playerButtonStyle == .appleMusic ? .white.opacity(0.92) : nil
                )
                .modifier(Layoutable(part: .progress, enabled: layoutMode, data: $layoutData, style: legacyLayoutStyle))

                deckRow
                    .modifier(Layoutable(part: .controls, enabled: layoutMode, data: $layoutData, style: legacyLayoutStyle))
            }
            if coverPlayerStyle != .vinyl {
                deckGrabber
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, max(12, bottomInset + 4))
        .frame(maxWidth: .infinity)
    }

    /// 黑胶样式控制行：播放模式 / 上一首 / 播放暂停 / 下一首 / 播放列表。
    /// 对应参考图中的五个底部控制入口。
    private var vinylKumoneControlRow: some View {
        HStack(spacing: 10) {
            vinylSideControl(icon: player.playMode.icon, active: player.playMode != .sequential) {
                player.togglePlayMode()
            }
            vinylTransportControl(icon: "backward.fill", size: 23) {
                player.previous()
            }

            Spacer(minLength: 0)

            Button {
                ATMusicHaptics.tap()
                player.togglePlayPause()
            } label: {
                PlayPauseMorphIcon(isPlaying: player.isPlaying, size: 29)
                    .frame(width: 62, height: 58)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            vinylTransportControl(icon: "forward.fill", size: 23) {
                player.next()
            }
            vinylSideControl(icon: "list.bullet") {
                showQueue = true
            }
            .modifier(AppleMusicLayoutTransform(entry: vinylLayoutEntry(.queue)))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, minHeight: 58)
    }

    private func vinylSideControl(icon: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            ATMusicHaptics.tap()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(active ? Color.atmusicAmber : .white.opacity(0.86))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func vinylTransportControl(icon: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button {
            ATMusicHaptics.tap()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 44, height: 58)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var vinylKumoneProgress: some View {
        VinylKumoneScrubber()
    }

    /// 底部指示线：只有在指示线附近上滑才呼出评论区（避免误触控制按钮）
    /// 指示线可关闭（透明但保留热区，仍可上滑呼出评论区）
    /// 布局模式下可直接拖动调整位置（与底部其他组件一致），滑杆同步可用
    private var deckGrabber: some View {
        Capsule()
            .fill(deckGrabberEnabled ? palette.secondary.opacity(0.5) : .clear)
            .frame(width: 40, height: 5)
            .overlay {
                if deckGrabberEnabled {
                    Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5)
                }
            }
            .padding(.top, 6)
            .padding(.bottom, 8)
            .contentShape(Rectangle())
            .scaleEffect(grabberEntry.scale)
            .offset(x: grabberEntry.x, y: grabberEntry.y)
            .gesture(
                layoutMode
                    ? AnyGesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            layoutPart = .grabber
                            var e = layoutData[PlayerLayoutPart.grabber.rawValue] ?? PlayerLayoutStore.defaultEntry(for: .grabber, style: legacyLayoutStyle)
                            e.x = value.translation.width
                            e.y = value.translation.height
                            layoutData[PlayerLayoutPart.grabber.rawValue] = e
                        })
                    : AnyGesture(DragGesture(minimumDistance: 20)
                        .onEnded { value in
                            if value.translation.height < -45, song != nil {
                                ATMusicHaptics.medium()
                                showComments = true
                            } else if value.translation.height > 45 {
                                ATMusicHaptics.tap()
                                closePlayer()
                            }
                        })
            )
            .onTapGesture {
                guard !layoutMode else { return }
                ATMusicHaptics.tap()
                closePlayer()
            }
    }

    private var subtitle: String {
        guard let song else { return "" }
        let parts = [song.artists, song.album].filter { !$0.isEmpty }
        return parts.isEmpty ? "未知歌曲" : parts.joined(separator: " · ")
    }

    // MARK: - 进度区块（可点按 / 拖动的进度条 + 当前时间 / 总时长 + ±15 秒）

    @ViewBuilder
    private func progressBlock(styleOverride: Int? = nil, accentOverride: Color? = nil) -> some View {
        let isAppleMusicStyle = playerButtonStyle == .appleMusic
        let trackColor: Color = isAppleMusicStyle ? .white.opacity(0.18) : palette.secondary.opacity(0.26)
        let timeColor: Color = isAppleMusicStyle ? .white.opacity(0.58) : palette.secondary
        VStack(spacing: 1) {
            SeekBar(accent: accentOverride ?? progressAccent, track: trackColor, style: styleOverride ?? progressBarStyle)
            HStack(spacing: 6) {
                if !isAppleMusicStyle {
                    seekPillButton("gobackward.15") { player.seekBy(-15) }
                }
                Text(atmusicTimeString(clock.progress))
                    .font(ATMusicFont.appFont(10, .regular, .monospaced))
                    .foregroundStyle(timeColor)
                    .frame(minWidth: 34, alignment: .leading)
                Spacer(minLength: 0)
                Text(atmusicTimeString(clock.duration))
                    .font(ATMusicFont.appFont(10, .regular, .monospaced))
                    .foregroundStyle(timeColor)
                    .frame(minWidth: 34, alignment: .trailing)
                if !isAppleMusicStyle {
                    seekPillButton("goforward.15") { player.seekBy(15) }
                }
            }
        }
    }

    private func seekPillButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button {
            ATMusicHaptics.tap()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.secondary)
                .frame(width: 30, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(GlassPressButtonStyle())
    }

    // MARK: - 合并控制行（循环 / 上一曲 / 播放暂停 / 下一曲 / 播放列表 平行排列，播放键居中）

    private var deckRow: some View {
        Group {
            if playerButtonStyle == .appleMusic {
                appleMusicDeckRow
            } else {
                legacyDeckRow
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 6)
    }

    private var legacyDeckRow: some View {
        HStack(spacing: 16) {
            deckButton(icon: "backward.fill", expand: false, part: .previous) {
                ATMusicHaptics.tap()
                player.previous()
            }
            playButton
            deckButton(icon: "forward.fill", expand: false, part: .next) {
                ATMusicHaptics.tap()
                player.next()
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var appleMusicDeckRow: some View {
        HStack(spacing: 26) {
            Button {
                ATMusicHaptics.tap()
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(playerButtonText)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(Layoutable(part: .previous, enabled: layoutMode, data: $layoutData, style: legacyLayoutStyle))

            Button {
                ATMusicHaptics.tap()
                player.togglePlayPause()
            } label: {
                PlayPauseMorphIcon(isPlaying: player.isPlaying, size: 20)
                    .foregroundStyle(playerButtonStyle == .appleMusic ? Color.white : Color.black)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(Layoutable(part: .controls, enabled: layoutMode, data: $layoutData, style: legacyLayoutStyle))

            Button {
                ATMusicHaptics.tap()
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(playerButtonText)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(Layoutable(part: .next, enabled: layoutMode, data: $layoutData, style: legacyLayoutStyle))
        }
        .frame(maxWidth: .infinity)
    }

    private var secondaryPlayerButtonSize: CGFloat {
        playerButtonStyle == .appleMusic ? 42 : 30
    }

    private var deckPlayerButtonSize: CGFloat {
        playerButtonStyle == .appleMusic ? 46 : 34
    }

    private var primaryPlayerButtonSize: CGFloat {
        playerButtonStyle == .appleMusic ? 62 : 56
    }

    @ViewBuilder
    private func playerButtonSurface(size: CGFloat, active: Bool = false, primary: Bool = false, appleLiquid: Bool = false) -> some View {
        ZStack {
            if active && !primary {
                ATMusicLiquidSelectionSurface(shape: Circle(), accent: controlAccent)
            } else {
                ATMusicGlass(shape: Circle(), forceLiquid: isLiquid)
            }
            if primary {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [controlAccent.opacity(uiStyle == .nativeClean ? 0.24 : 0.62), controlAccentSoft.opacity(uiStyle == .nativeClean ? 0.18 : 0.56)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            Circle()
                .strokeBorder(
                    active || primary
                        ? controlAccent.opacity(0.52)
                        : (isLiquid ? Color.white.opacity(0.35) : Color.primary.opacity(uiStyle == .clear ? 0.12 : 0.08)),
                    lineWidth: primary ? 1.1 : (isLiquid ? 0.8 : 0.65)
                )
        }
        .frame(width: size, height: size)
    }


    private func deckButton(icon: String, accent: Bool = false, expand: Bool = true, part: PlayerLayoutPart? = nil, action: @escaping () -> Void) -> some View {
        Button {
            ATMusicHaptics.tap()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: playerButtonStyle == .appleMusic ? 19 : 17, weight: .medium))
                .foregroundStyle(accent ? controlAccent : playerButtonText)
                .frame(width: deckPlayerButtonSize, height: deckPlayerButtonSize)
                .background {
                    if playerButtonStyle != .appleMusic {
                        playerButtonSurface(size: deckPlayerButtonSize, active: accent, appleLiquid: true)
                    }
                }
                .clipShape(Circle())
        }
        .buttonStyle(GlassPressButtonStyle())
        .frame(maxWidth: expand ? .infinity : nil)
        .modifier(Layoutable(part: part ?? .controls, enabled: layoutMode && part != nil, data: $layoutData, style: legacyLayoutStyle))
    }

    private var playButton: some View {
        Button {
            ATMusicHaptics.tap()
            player.togglePlayPause()
        } label: {
            PlayPauseMorphIcon(isPlaying: player.isPlaying, size: 22)
                .foregroundStyle(playerButtonStyle == .appleMusic ? Color.black : Color.white)
                .frame(width: primaryPlayerButtonSize, height: primaryPlayerButtonSize)
                .background {
                    if playerButtonStyle != .appleMusic {
                        playerButtonSurface(size: primaryPlayerButtonSize, primary: true, appleLiquid: true)
                    }
                }
                .clipShape(Circle())
        }
        .buttonStyle(GlassPressButtonStyle(scale: 0.9))
        .modifier(Layoutable(part: .playPause, enabled: layoutMode, data: $layoutData, style: legacyLayoutStyle))
    }


    // MARK: - 播放器自定义布局工具栏（x / y / z + 恢复默认）

    /// 当前选中组件的绑定（滑杆读写；歌词映射到独立存储的偏移值）
    private var selectedLayoutEntry: Binding<PlayerLayoutEntry> {
        Binding(
            get: {
                switch layoutPart {
                case .lyric:
                    return PlayerLayoutEntry(x: CGFloat(lyricOffsetX), y: CGFloat(lyricAnchorY), scale: CGFloat(lyricScale))
                default:
                    return layoutData[layoutPart.rawValue] ?? PlayerLayoutStore.defaultEntry(for: layoutPart, style: legacyLayoutStyle)
                }
            },
            set: { newValue in
                switch layoutPart {
                case .lyric:
                    lyricOffsetX = Double(newValue.x)
                    lyricAnchorY = Double(newValue.y)
                    lyricScale = Double(newValue.scale)
                default:
                    layoutData[layoutPart.rawValue] = newValue
                }
            }
        )
    }

    /// 指示线位置（存于布局数据字典，X / Y 偏移）
    private var grabberEntry: PlayerLayoutEntry {
        layoutData[PlayerLayoutPart.grabber.rawValue] ?? PlayerLayoutStore.defaultEntry(for: .grabber, style: legacyLayoutStyle)
    }

    /// 各组件 X 滑杆范围
    private var layoutXRange: ClosedRange<CGFloat> {
        switch layoutPart {
        case .lyric:
            return -80...80
        case .topBack, .topTitle, .topFavorite, .cover, .title, .previewLyric:
            return -180...180
        default:
            return -140...140
        }
    }

    /// 各组件 Y 滑杆范围
    private var layoutYRange: ClosedRange<CGFloat> {
        switch layoutPart {
        case .lyric: return -80...80
        case .topBack, .topTitle, .topFavorite: return -80...160
        case .cover, .title, .previewLyric:
            return -220...220
        case .grabber: return -120...120
        default: return -300...300
        }
    }

    private var layoutToolbar: some View {
        VStack(spacing: 10) {
            HStack {
                Text("自定义布局")
                    .font(ATMusicFont.appFont(15, .bold))
                Spacer()
                Button {
                    ATMusicHaptics.select()
                    layoutMode = false
                } label: {
                    Text("完成")
                        .font(ATMusicFont.appFont(13, .semibold))
                        .foregroundStyle(Color.atmusicAmber)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background { ATMusicSurface(shape: Capsule()) }
                }
                .buttonStyle(.plain)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(PlayerLayoutPart.editableCases) { part in
                        Button {
                            ATMusicHaptics.select()
                            layoutPart = part
                            layoutPartRaw = part.rawValue
                        } label: {
                            Text(LocalizedStringKey(part.rawValue))
                                .font(ATMusicFont.appFont(12, .semibold))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .atmusicSelectionForeground(selected: layoutPart == part, accent: .atmusicAmber, unselected: palette.secondary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 7)
                                .background {
                                    ATMusicSelectableSurface(
                                        selected: layoutPart == part,
                                        shape: Capsule(),
                                        accent: .atmusicAmber
                                    )
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            layoutSlider("X", value: selectedLayoutEntry.x, range: layoutXRange)
            layoutSlider("Y", value: selectedLayoutEntry.y, range: layoutYRange)
            layoutSlider("大小", value: selectedLayoutEntry.scale, range: 0.3...1.5, step: 0.05, format: "%.2f")
            HStack(spacing: 10) {
                Button {
                    resetCurrentLayoutPart()
                    ATMusicHaptics.success()
                } label: {
                    Label("恢复默认", systemImage: "arrow.counterclockwise")
                        .font(ATMusicFont.appFont(13, .medium))
                        .foregroundStyle(Color.atmusicAmber)
                }
                .buttonStyle(.plain)
                Spacer()
                Text("编辑模式：顶部、经典封面、歌词和底部控件都可调")
                    .font(ATMusicFont.appFont(11))
                    .foregroundStyle(palette.secondary)
            }
        }
        .padding(14)
        .background {
            ATMusicGlass(shape: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .padding(.horizontal, 12)
    }

    private var appleMusicLayoutToolbar: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Apple Music 实时布局")
                    .font(ATMusicFont.appFont(15, .bold))
                Spacer()
                Button {
                    ATMusicHaptics.select()
                    layoutMode = false
                } label: {
                    Text("完成")
                        .font(ATMusicFont.appFont(13, .semibold))
                        .foregroundStyle(Color.atmusicAmber)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background { ATMusicSurface(shape: Capsule()) }
                }
                .buttonStyle(.plain)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(AppleMusicLayoutPart.allCases) { part in
                        appleLayoutChip(part.rawValue, isSelected: appleLayoutPart == part) {
                            appleLayoutPart = part
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    appleMusicLayoutSliders
                    appleMusicAppearanceControls
                    HStack(spacing: 10) {
                        Button {
                            resetAppleMusicCurrentLayoutPart()
                            ATMusicHaptics.success()
                        } label: {
                            Label("恢复当前", systemImage: "arrow.counterclockwise")
                                .font(ATMusicFont.appFont(13, .medium))
                                .foregroundStyle(Color.atmusicAmber)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button {
                            resetAppleMusicSettings()
                            ATMusicHaptics.success()
                        } label: {
                            Label("恢复全部", systemImage: "arrow.counterclockwise.circle")
                                .font(ATMusicFont.appFont(13, .medium))
                                .foregroundStyle(Color.atmusicAmber)
                        }
                        .buttonStyle(.plain)
                    }
                    Text("X / Y / 大小和 Apple Music 外观会立即同步到当前播放页")
                        .font(ATMusicFont.appFont(11))
                        .foregroundStyle(palette.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: 430)
        }
        .padding(14)
        .background {
            ATMusicGlass(shape: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .padding(.horizontal, 12)
    }

    private func appleLayoutChip(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            ATMusicHaptics.select()
            action()
        } label: {
            Text(LocalizedStringKey(title))
                .font(ATMusicFont.appFont(12, .semibold))
                .atmusicSelectionForeground(selected: isSelected, accent: .atmusicAmber, unselected: palette.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background {
                    ATMusicSelectableSurface(selected: isSelected, shape: Capsule(), accent: .atmusicAmber)
                }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var appleMusicLayoutSliders: some View {
        VStack(spacing: 6) {
            layoutSlider("X", value: appleMusicEntryBinding.x, range: -180...180)
            layoutSlider("Y", value: appleMusicEntryBinding.y, range: -240...240)
            layoutSlider("大小", value: appleMusicEntryBinding.scale, range: 0.3...1.5, step: 0.05, format: "%.2f")
        }
    }

    private var appleMusicEntryBinding: Binding<PlayerLayoutEntry> {
        Binding(
            get: { appleLayout.entry(for: appleLayoutPart) },
            set: { appleLayout.set($0, for: appleLayoutPart) }
        )
    }

    private func resetAppleMusicCurrentLayoutPart() {
        appleLayout.reset(appleLayoutPart)
    }

    private var applePrimaryColorBinding: Binding<Color> {
        Binding(
            get: {
                if applePrimaryHex.hasPrefix("#"), let color = Color(hex: applePrimaryHex) {
                    return color
                }
                return .white
            },
            set: { applePrimaryHex = "#" + UIColor($0).hexString }
        )
    }

    private var appleSecondaryColorBinding: Binding<Color> {
        Binding(
            get: {
                if appleSecondaryHex.hasPrefix("#"), let color = Color(hex: appleSecondaryHex) {
                    return color
                }
                return Color.atmusicComment
            },
            set: { appleSecondaryHex = "#" + UIColor($0).hexString }
        )
    }

    private var appleAccentColorBinding: Binding<Color> {
        Binding(
            get: {
                if appleAccentHex.hasPrefix("#"), let color = Color(hex: appleAccentHex) {
                    return color
                }
                return Color(red: 1.0, green: 0.28, blue: 0.36)
            },
            set: { appleAccentHex = "#" + UIColor($0).hexString }
        )
    }

    private var appleVolumeColorBinding: Binding<Color> {
        Binding(
            get: {
                if appleVolumeHex.hasPrefix("#"), let color = Color(hex: appleVolumeHex) {
                    return color
                }
                return applePrimaryColorBinding.wrappedValue
            },
            set: { appleVolumeHex = "#" + UIColor($0).hexString }
        )
    }

    private var appleMusicAppearanceControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Apple Music 外观")
                .font(ATMusicFont.appFont(12, .semibold))
                .foregroundStyle(Color.atmusicLabel)
                .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("显示音量条", isOn: $appleShowVolume)
                .font(ATMusicFont.appFont(12))
                .tint(Color.atmusicAmber)
            Toggle("同步主页壁纸", isOn: $appleSyncWallpaper)
                .font(ATMusicFont.appFont(12))
                .tint(Color.atmusicAmber)
            if appleSyncWallpaper {
                HStack(spacing: 8) {
                    Text("壁纸模糊")
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(palette.secondary)
                        .frame(width: 58, alignment: .leading)
                    Slider(value: $appleWallpaperBlur, in: 0...32, step: 1)
                        .tint(Color.atmusicAmber)
                    Text("\(Int(appleWallpaperBlur))")
                        .font(ATMusicFont.appFont(11, .semibold, .monospaced))
                        .foregroundStyle(Color.atmusicAmber)
                        .frame(width: 28, alignment: .trailing)
                }
            }
            ColorPicker("主图标与当前歌词", selection: applePrimaryColorBinding, supportsOpacity: false)
                .font(ATMusicFont.appFont(12))
            ColorPicker("次级文字与时间", selection: appleSecondaryColorBinding, supportsOpacity: false)
                .font(ATMusicFont.appFont(12))
            ColorPicker("高亮颜色", selection: appleAccentColorBinding, supportsOpacity: false)
                .font(ATMusicFont.appFont(12))
            ColorPicker("音量条颜色", selection: appleVolumeColorBinding, supportsOpacity: false)
                .font(ATMusicFont.appFont(12))
        }
        .padding(10)
        .background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func resetAppleMusicSettings() {
        appleLayout.resetAll()
        applePrimaryHex = ""
        appleSecondaryHex = ""
        appleAccentHex = ""
        appleVolumeHex = ""
        appleShowVolume = false
        appleShowLyricPreview = true
        appleSyncWallpaper = false
        appleWallpaperBlur = 14
    }

    private func resetCurrentLayoutPart() {
        switch layoutPart {
        case .lyric:
            lyricOffsetX = 0
            lyricAnchorY = 0
            lyricScale = 1
        default:
            layoutData.removeValue(forKey: layoutPart.rawValue)
            PlayerLayoutStore.save(layoutData, for: legacyLayoutStyle)
        }
    }

    private func layoutSlider(_ title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>, step: CGFloat = 1, format: String = "%.0f") -> some View {
        HStack(spacing: 10) {
            Text(LocalizedStringKey(title))
                .font(ATMusicFont.appFont(12, .medium))
                .foregroundStyle(palette.secondary)
                .frame(width: 56, alignment: .leading)
            Slider(value: value, in: range, step: step)
                .tint(Color.atmusicAmber)
                .transaction { transaction in transaction.animation = nil }
            Text(String(format: format, value.wrappedValue))
                .font(ATMusicFont.appFont(11, .regular, .monospaced))
                .foregroundStyle(palette.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }

    // MARK: - 分享


    /// 各平台歌曲链接（网易云 / QQ音乐 / 酷狗音乐）
    private func shareURL(for song: Song) -> URL? {
        switch song.source {
        case .netease:
            return URL(string: "https://music.163.com/#/song?id=\(song.id)")
        case .qq:
            if let mid = song.qqMid, !mid.isEmpty {
                return URL(string: "https://y.qq.com/n/ryqq/songDetail/\(mid)")
            }
            let encoded = song.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? song.name
            return URL(string: "https://y.qq.com/n/ryqq/search?w=\(encoded)")
        case .kugou:
            let encoded = song.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? song.name
            return URL(string: "https://www.kugou.com/yy/html/search.html#searchType=song&searchKeyWord=\(encoded)")
        case .local:
            return nil
        case .synology, .subsonic, .jellyfin, .webdav:
            return nil
        }
    }

    // MARK: - 下载

    private func handlePlayerDownloadTap() {
        guard let song else { return }
        if DownloadManager.shared.isDownloaded(song: song) {
            showDownloadedActionDialog = true
            ATMusicHaptics.tap()
        } else if DownloadManager.shared.isDownloading(song: song) {
            let task = DownloadManager.shared.activeDownloads.first(where: { $0.song.identityKey == song.identityKey })
            if let task {
                ATMusicHaptics.tap()
                if task.status == .downloading {
                    DownloadManager.shared.pauseDownload(id: task.id)
                } else if task.status == .paused {
                    DownloadManager.shared.resumeDownload(id: task.id)
                }
            }
        } else {
            showDownloadPicker = true
            ATMusicHaptics.tap()
        }
    }

    private func downloadCurrent(_ quality: DownloadQuality) async {
        guard let song else { return }
        UserDefaults.standard.set(quality.rawValue, forKey: ThirdPartyAudioQuality.downloadStorageKey)
        ATMusicHaptics.medium()
        DownloadManager.shared.startDownload(song: song, quality: quality)
    }

    /// 分享面板关闭后清理临时下载文件（不占用户存储）
    private func cleanupSharedFile() {
        if let url = sharedFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        sharedFileURL = nil
        shareFile = nil
    }

    // MARK: - 动作

    /// 全部歌手名（多歌手歌曲点击时弹出选择，避免只打开第一位）
    private var artistNames: [String] {
        guard let artists = song?.artists else { return [] }
        return artists
            .replacingOccurrences(of: " / ", with: "/")
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).description }
            .filter { !$0.isEmpty }
    }

    /// 首位歌手名（用于跳转歌手主页）
    private var primaryArtistName: String {
        artistNames.first ?? ""
    }


    private func openAlbumDetail() {
        guard let song else { return }
        let albumName = song.album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !albumName.isEmpty else {
            ToastCenter.shared.show("当前歌曲没有专辑信息")
            return
        }
        let albumID: String
        switch song.source {
        case .synology:
            albumID = "synology-(albumName)-(song.artists)"
        case .netease:
            // Song 不总是携带专辑 ID；AlbumDetailView 会在无效 ID 时按歌手+专辑回退搜索。
            albumID = "netease-(song.id)"
        default:
            albumID = "(song.source.rawValue)-(song.id)"
        }
        ATMusicHaptics.tap()
        selectedAlbum = Album(
            id: albumID,
            name: albumName,
            artistName: song.artists,
            coverURL: song.coverURL,
            source: song.source,
            trackCount: nil
        )
    }

    private func openSongInfo() {
        guard let song else { return }
        switch song.source {
        case .synology:
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) { showSynologyMetadataEditor = true }
        case .local:
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) { showLocalMetadataEditor = true }
        default:
            ToastCenter.shared.show("在线歌曲信息由平台维护，NAS 或本地歌曲支持手动编辑")
        }
    }

    private func toggleLyrics() {
        ATMusicHaptics.tap()
        withAnimation {
            showLyrics.toggle()
        }
    }

    private func closePlayer() {
        isPresented = false
    }

    /// 左右切歌：松手后旧封面沿手势方向飞出，新封面从对侧滑入（左滑下一首，右滑上一首）。
    private func handleSwipeEnd(horizontal: CGFloat) {
        guard swipeSwitchSong else { return }
        let x = horizontal
        if x < -70 {
            ATMusicHaptics.tap()
            coverDrag = .zero
            flySwipe(direction: -1)
        } else if x > 70 {
            ATMusicHaptics.tap()
            coverDrag = .zero
            flySwipe(direction: 1)
        } else {
            withAnimation {
                swipeOffset = 0
                coverDrag = .zero
            }
        }
    }

    private func flySwipe(direction: CGFloat) {
        if direction < 0 { player.next() } else { player.previous() }
        withAnimation {
            swipeOffset = 0
            coverDrag = .zero
        }
    }

    private func loadLyrics() async {
        lyrics = []
        guard let song else { return }
        let identity = song.identityKey
        let parsed = await SongLyricsLoader.loadLyrics(for: song)
        guard self.song?.identityKey == identity else { return }
        self.lyrics = parsed
        player.updateCurrentLyrics(parsed, for: identity)
    }

    /// 当前歌曲没有歌词时，从可用平台候选中按歌名/歌手/专辑相似度选择最高项。
    private func autoMatchedLyrics(for song: Song) async -> String? {
        let candidates: [Song]
        if song.source == .synology {
            let matches = await SynologyAPI.shared.metadataCandidates(for: song)
            candidates = matches.map(\.song)
        } else if song.source == .netease {
            candidates = (try? await NetEaseAPI.shared.search(keyword: "\(song.name) \(song.artists)", limit: 12)) ?? []
        } else if song.source == .qq {
            candidates = (try? await QQMusicAPI.shared.searchSongs(keyword: "\(song.name) \(song.artists)", limit: 12)) ?? []
        } else if song.source == .kugou {
            candidates = (try? await KugouMusicAPI.shared.searchSongs(keyword: "\(song.name) \(song.artists)", limit: 12)) ?? []
        } else {
            async let netease = (try? await NetEaseAPI.shared.search(keyword: "\(song.name) \(song.artists)", limit: 8)) ?? []
            async let qq = (try? await QQMusicAPI.shared.searchSongs(keyword: "\(song.name) \(song.artists)", limit: 8)) ?? []
            async let kugou = (try? await KugouMusicAPI.shared.searchSongs(keyword: "\(song.name) \(song.artists)", limit: 8)) ?? []
            let all = await (netease, qq, kugou)
            candidates = all.0 + all.1 + all.2
        }

        for candidate in candidates.sorted(by: { lyricMatchScore($0, to: song) > lyricMatchScore($1, to: song) }).prefix(8) {
            if let raw = await fetchLyrics(for: candidate), !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return raw
            }
        }
        return nil
    }

    private func fetchLyrics(for song: Song) async -> String? {
        switch song.source {
        case .netease:
            guard let result = try? await NetEaseAPI.shared.lyricWithTranslation(id: song.id) else { return nil }
            return result.lrc
        case .qq:
            guard let mid = song.qqMid else { return nil }
            return try? await QQMusicAPI.shared.lyric(songmid: mid)
        case .kugou:
            guard let hash = song.kugouHash else { return nil }
            return await KugouMusicAPI.shared.lyric(hash: hash, duration: song.duration)
        case .synology, .local:
            return nil
        case .subsonic:
            return try? await SubsonicAPI.shared.lyrics(song: song)
        case .jellyfin:
            return try? await JellyfinAPI.shared.lyrics(song: song)
        case .webdav:
            return try? await WebDAVAPI.shared.lyrics(song: song)
        }
    }

    private func lyricMatchScore(_ candidate: Song, to target: Song) -> Int {
        func normalize(_ value: String) -> String {
            value.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let targetName = normalize(target.name)
        let candidateName = normalize(candidate.name)
        var score = 0
        if candidateName == targetName { score += 100 } else if candidateName.contains(targetName) || targetName.contains(candidateName) { score += 60 }
        let targetArtists = normalize(target.artists)
        let candidateArtists = normalize(candidate.artists)
        if !targetArtists.isEmpty, candidateArtists == targetArtists { score += 45 } else if !targetArtists.isEmpty && (candidateArtists.contains(targetArtists) || targetArtists.contains(candidateArtists)) { score += 25 }
        let targetAlbum = normalize(target.album)
        let candidateAlbum = normalize(candidate.album)
        if !targetAlbum.isEmpty, candidateAlbum == targetAlbum { score += 20 } else if !targetAlbum.isEmpty && candidateAlbum.contains(targetAlbum) { score += 8 }
        if target.duration > 0, candidate.duration > 0, abs(target.duration - candidate.duration) < 3 { score += 12 }
        return score
    }

    private func clearLyrics(for song: Song) async {
        // 内嵌标签、同名 .lrc、歌词库与本机缓存一起清，才不会"清了又回来"
        let message = await LyricsPersistence.clear(song: song)
        ToastCenter.shared.show(message)
    }

    /// 一次性提取当前封面主色，带动整个播放器配色动态变化（失败时保持主题回退色，不影响任何功能）
    private func extractCoverPalette() async {
        guard let url = song?.coverURL else { return }
        let resolved = ManagedAudioPath.resolveFileURL(url) ?? url
        let cacheKey = resolved.absoluteString
        if let cached = PaletteColorCache.shared.color(for: cacheKey) {
            await MainActor.run {
                withAnimation {
                    dominantColor = cached
                }
            }
            return
        }
        do {
            let image: UIImage?
            if resolved.isFileURL {
                image = UIImage(contentsOfFile: resolved.path)
            } else if let cached = ATMusicRemoteCoverCache.image(for: resolved) {
                image = cached
            } else {
                var req = URLRequest(url: resolved)
                req.timeoutInterval = 6
                req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
                let (data, _) = try await URLSession.shared.data(for: req)
                image = UIImage(data: data)
                if let image {
                    ATMusicRemoteCoverCache.store(image, for: resolved)
                }
            }
            guard let image,
                  let dominant = PaletteExtractor.dominantColor(in: image) else { return }
            PaletteColorCache.shared.store(dominant, for: cacheKey)
            await MainActor.run {
                withAnimation {
                    dominantColor = dominant
                }
            }
        } catch {
            // 提取失败：静默保持回退色
        }
    }

}

private struct LyricsSearchCandidate: Identifiable {
    let id: String
    let providerName: String
    let lyrics: String
    let song: Song
}

/// 歌词页专用搜索弹框。封面候选不在这里展示，封面搜索统一放在歌曲信息编辑页。
private struct SongLyricsSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    let song: Song
    let onClear: () -> Void
    let onSelect: (String) -> Void

    @State private var query: String
    @State private var candidates: [LyricsSearchCandidate] = []
    @State private var isLoading = true
    @State private var message = "正在搜索歌词…"

    init(song: Song, onClear: @escaping () -> Void, onSelect: @escaping (String) -> Void) {
        self.song = song
        self.onClear = onClear
        self.onSelect = onSelect
        _query = State(initialValue: song.name)
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button("清除歌词") {
                        candidates = []
                        message = "当前歌曲暂无歌词"
                        onClear()
                    }
                    .font(ATMusicFont.appFont(12, .medium))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: true, vertical: false)

                    TextField("歌曲 / 歌手 / 专辑", text: $query)
                        .textFieldStyle(.roundedBorder)

                    Button("搜索") {
                        Task { await search() }
                    }
                    .font(ATMusicFont.appFont(12, .semibold))
                    .foregroundStyle(Color.atmusicAmber)
                    .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

                List {
                if isLoading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(message)
                            .foregroundStyle(.secondary)
                    }
                } else if candidates.isEmpty {
                    Text(message)
                        .foregroundStyle(.secondary)
                } else {
                    Section("搜索结果") {
                        ForEach(candidates) { candidate in
                            Button {
                                onSelect(candidate.lyrics)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text("\(candidate.song.name) - \(candidate.song.artists) - \(candidate.song.album)")
                                            .font(ATMusicFont.appFont(14, .semibold))
                                            .foregroundStyle(Color.atmusicLabel)
                                            .lineLimit(2)
                                        Spacer()
                                        VStack(alignment: .trailing, spacing: 2) {
                                            Text(candidate.providerName)
                                                .font(ATMusicFont.appFont(10))
                                                .foregroundStyle(Color.atmusicComment)
                                            if candidate.id == candidates.first?.id {
                                                Text("最匹配")
                                                    .font(ATMusicFont.appFont(10, .semibold))
                                                    .foregroundStyle(Color.atmusicAmber)
                                            }
                                        }
                                    }
                                    Text(lyricsPreview(candidate.lyrics))
                                        .font(ATMusicFont.appFont(12))
                                        .foregroundStyle(Color.atmusicComment)
                                        .lineLimit(3)
                                }
                                .padding(.vertical, 5)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                }
            }
            .navigationTitle("搜索歌词")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .task { await search() }
    }

    private func search() async {
        var found: [LyricsSearchCandidate] = []
        let searchText = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? song.name : query.trimmingCharacters(in: .whitespacesAndNewlines)
        switch song.source {
        case .synology:
            let matches = await SynologyAPI.shared.metadataCandidates(for: song)
            for candidate in matches.prefix(10) {
                if let raw = await SynologyAPI.shared.onlineLyrics(for: candidate.song), !raw.isEmpty {
                    found.append(LyricsSearchCandidate(id: candidate.id, providerName: candidate.providerName, lyrics: raw, song: candidate.song))
                }
            }
        case .subsonic:
            let subsonicMatches = (try? await SubsonicAPI.shared.searchAllVariants(keyword: searchText, limit: 20))?.songs ?? [song]
            for candidate in subsonicMatches.sorted(by: { lyricCandidateScore($0, to: song) > lyricCandidateScore($1, to: song) }).prefix(10) {
                guard let raw = try? await SubsonicAPI.shared.lyrics(song: candidate), !raw.isEmpty else { continue }
                found.append(LyricsSearchCandidate(id: candidate.identityKey, providerName: "Subsonic", lyrics: raw, song: candidate))
            }
        case .jellyfin:
            let jellyfinMatches = (try? await JellyfinAPI.shared.searchAllVariants(keyword: searchText, limit: 20))?.songs ?? [song]
            for candidate in jellyfinMatches.sorted(by: { lyricCandidateScore($0, to: song) > lyricCandidateScore($1, to: song) }).prefix(10) {
                guard let raw = try? await JellyfinAPI.shared.lyrics(song: candidate), !raw.isEmpty else { continue }
                found.append(LyricsSearchCandidate(id: candidate.identityKey, providerName: "Jellyfin", lyrics: raw, song: candidate))
            }
        case .webdav:
            let webdavMatches = (try? await WebDAVAPI.shared.searchAllVariants(keyword: searchText, limit: 20))?.songs ?? [song]
            for candidate in webdavMatches.sorted(by: { lyricCandidateScore($0, to: song) > lyricCandidateScore($1, to: song) }).prefix(10) {
                guard let raw = try? await WebDAVAPI.shared.lyrics(song: candidate), !raw.isEmpty else { continue }
                found.append(LyricsSearchCandidate(id: candidate.identityKey, providerName: "WebDAV", lyrics: raw, song: candidate))
            }
        case .netease:
            let matches = (try? await NetEaseAPI.shared.search(keyword: searchText, limit: 20)) ?? [song]
            for candidate in matches.sorted(by: { lyricCandidateScore($0, to: song) > lyricCandidateScore($1, to: song) }).prefix(10) {
                if let result = try? await NetEaseAPI.shared.lyricWithTranslation(id: candidate.id),
                   let raw = result.lrc, !raw.isEmpty {
                    found.append(LyricsSearchCandidate(id: "netease-\(candidate.id)", providerName: "网易云音乐", lyrics: raw, song: candidate))
                }
            }
        case .qq:
            let matches = (try? await QQMusicAPI.shared.searchSongs(keyword: searchText, limit: 20)) ?? [song]
            for candidate in matches.sorted(by: { lyricCandidateScore($0, to: song) > lyricCandidateScore($1, to: song) }).prefix(10) {
                guard let mid = candidate.qqMid,
                      let raw = try? await QQMusicAPI.shared.lyric(songmid: mid),
                      !raw.isEmpty else { continue }
                found.append(LyricsSearchCandidate(id: "qq-\(mid)", providerName: "QQ音乐", lyrics: raw, song: candidate))
            }
        case .kugou:
            let matches = (try? await KugouMusicAPI.shared.searchSongs(keyword: searchText, limit: 20)) ?? [song]
            for candidate in matches.sorted(by: { lyricCandidateScore($0, to: song) > lyricCandidateScore($1, to: song) }).prefix(10) {
                guard let hash = candidate.kugouHash else { continue }
                let raw = await KugouMusicAPI.shared.lyric(hash: hash, duration: candidate.duration)
                if !raw.isEmpty {
                    found.append(LyricsSearchCandidate(id: "kugou-\(hash)", providerName: "酷狗音乐", lyrics: raw, song: candidate))
                }
            }
        case .local:
            let matches = (try? await NetEaseAPI.shared.search(keyword: searchText, limit: 20)) ?? []
            for candidate in matches.sorted(by: { lyricCandidateScore($0, to: song) > lyricCandidateScore($1, to: song) }).prefix(10) {
                if let result = try? await NetEaseAPI.shared.lyricWithTranslation(id: candidate.id),
                   let raw = result.lrc, !raw.isEmpty {
                    found.append(LyricsSearchCandidate(id: "netease-\(candidate.id)", providerName: "网易云音乐", lyrics: raw, song: candidate))
                }
            }
        }

        await MainActor.run {
            candidates = found.sorted { lyricCandidateScore($0.song, to: song) > lyricCandidateScore($1.song, to: song) }
            isLoading = false
            message = found.isEmpty ? "暂未找到歌词，可在歌曲信息中手动粘贴 LRC。" : "点击任一结果载入当前播放页"
        }
    }

    private func lyricCandidateScore(_ candidate: Song, to target: Song) -> Int {
        func normalize(_ value: String) -> String { value.lowercased().filter { $0.isLetter || $0.isNumber } }
        let name = normalize(candidate.name), targetName = normalize(target.name)
        let artists = normalize(candidate.artists), targetArtists = normalize(target.artists)
        let album = normalize(candidate.album), targetAlbum = normalize(target.album)
        var score = name == targetName ? 100 : (name.contains(targetName) || targetName.contains(name) ? 60 : 0)
        if !targetArtists.isEmpty { score += artists == targetArtists ? 45 : (artists.contains(targetArtists) || targetArtists.contains(artists) ? 25 : 0) }
        if !targetAlbum.isEmpty, album == targetAlbum { score += 20 }
        return score
    }

    private func lyricsPreview(_ raw: String) -> String {
        raw
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .prefix(3)
            .joined(separator: "\n")
    }
}

/// 黑胶页专用的白色极简进度条：非拖动时隐藏滑块，拖动时才显示。
private struct VinylKumoneScrubber: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var clock: PlaybackClock
    @State private var isDragging = false
    @State private var dragProgress = 0.0

    private var currentProgress: Double {
        isDragging ? dragProgress : clock.progress
    }

    private var fraction: Double {
        guard clock.duration > 0 else { return 0 }
        return min(max(currentProgress / clock.duration, 0), 1)
    }

    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.25))
                        .frame(height: 4)
                    Capsule()
                        .fill(.white)
                        .frame(width: max(4, width * fraction), height: 4)
                    Circle()
                        .fill(.white)
                        .frame(width: isDragging ? 13 : 9, height: isDragging ? 13 : 9)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .offset(x: width * fraction - (isDragging ? 6.5 : 4.5))
                        .opacity(isDragging ? 1 : 0)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard clock.duration > 0 else { return }
                            isDragging = true
                            dragProgress = min(max(value.location.x / width, 0), 1) * clock.duration
                        }
                        .onEnded { _ in
                            player.seek(to: dragProgress)
                            isDragging = false
                        }
                )
            }
            .frame(height: 14)

            HStack {
                Text(atmusicTimeString(currentProgress))
                Spacer(minLength: 0)
                Text(atmusicTimeString(clock.duration))
            }
            .font(ATMusicFont.appFont(10, .regular, .monospaced))
            .foregroundStyle(.white.opacity(0.55))
            .monospacedDigit()
        }
    }
}

// MARK: - 自定义进度条（点击 / 拖动均可跳转，配色跟随封面主色）

struct SeekBar: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var clock: PlaybackClock
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @AppStorage("atmusic.hideDynamicEffects") private var lowPowerVisualMode = false
    let accent: Color
    let track: Color
    /// 进度条样式：0 流光 / 1 辉光 / 2 极光 / 3 波浪
    var style: Int = 0

    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    /// 流光样式：光点游动相位（0→1 往返）
    @State private var flowPhase: CGFloat = 0
    @State private var lastPreviewSecond: Int?

    private var progress: Double {
        scrubbing ? scrubValue : clock.progress
    }

    private var reduceVisualMotion: Bool {
        lowPowerVisualMode || accessibilityReduceMotion
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let total = max(clock.duration, 1)
            let ratio = min(max(progress / total, 0), 1)
            let thumbX = min(max(width * ratio, 10), max(width - 10, 10))

            ZStack(alignment: .leading) {
                // 轨道与已播放段（按样式）
                switch style {
                case 1:
                    // 辉光：全宽渐变底轨 + 明亮已播放段 + 底部柔光
                    Capsule()
                        .fill(
                            LinearGradient(colors: [accent.opacity(0.28), track.opacity(0.5), accent.opacity(0.18)],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                        .frame(height: 7)
                    Capsule()
                        .fill(
                            LinearGradient(colors: [.white.opacity(0.9), accent],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                        .frame(width: thumbX, height: 7)
                        .shadow(color: accent.opacity(0.65), radius: 5, y: 1)
                    Capsule()
                        .fill(.white.opacity(0.85))
                        .frame(width: max(3, thumbX - 4), height: 2)
                        .offset(y: -2)
                        .clipShape(Capsule())
                case 2:
                    // 极光：发丝细线 + 极光渐变 + 大号光晕滑块
                    Capsule()
                        .fill(track.opacity(0.6))
                        .frame(height: 2.5)
                    Capsule()
                        .fill(
                            LinearGradient(colors: [accent, .white.opacity(0.85), accent.opacity(0.6)],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                        .frame(width: thumbX, height: 2.5)
                        .shadow(color: accent.opacity(0.7), radius: 4)
                    Circle()
                        .fill(.white.opacity(0.16))
                        .frame(width: 30, height: 30)
                        .overlay {
                            Circle()
                                .fill(
                                    LinearGradient(colors: [.white, accent.opacity(0.85)],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                                )
                                .frame(width: 18, height: 18)
                                .overlay {
                                    Circle().strokeBorder(.white.opacity(0.95), lineWidth: 1)
                                }
                        }
                        .shadow(color: accent.opacity(0.85), radius: scrubbing ? 9 : 6)
                        .scaleEffect(scrubbing ? 1.15 : 1)
                        .offset(x: thumbX - 15)
                        .animation(.default, value: scrubbing)
                case 3:
                    // 波浪：正弦波形，已播放段高亮发光
                    WaveBar(ratio: ratio, accent: accent, track: track, width: width, isPlaying: player.isPlaying && !player.isInBackground && !reduceVisualMotion)
                default:
                    // 流光：清透轨道 + 渐变已播放段 + 顶部高光 + 游动光点
                    Capsule()
                        .fill(track.opacity(0.55))
                        .frame(height: 5)
                    ATMusicGlass(shape: Capsule())
                        .frame(height: 5)
                        .overlay {
                            Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
                        }
                    Capsule()
                        .fill(
                            LinearGradient(colors: [accent, accent.opacity(0.6), .white.opacity(0.85)],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                        .frame(width: thumbX, height: 5)
                        .shadow(color: accent.opacity(0.45), radius: 4, y: 1)
                        .overlay(alignment: .top) {
                            LinearGradient(colors: [.white.opacity(0.55), .clear],
                                           startPoint: .top, endPoint: .bottom)
                                .frame(height: 2.5)
                                .clipShape(Capsule())
                        }
                    if player.isPlaying && !player.isInBackground && !reduceVisualMotion {
                        // 游动光点仅在播放中运行，暂停后不保留 repeatForever 动画。
                        ZStack {
                            Circle()
                                .fill(.white.opacity(0.35))
                                .blur(radius: 4)
                                .frame(width: 14, height: 14)
                            Circle()
                                .fill(.white.opacity(0.95))
                                .frame(width: 5, height: 5)
                                .shadow(color: .white.opacity(0.7), radius: 2)
                        }
                        .offset(x: max(2, thumbX - 5) * flowPhase)
                        .animation(.linear(duration: 2.4).repeatForever(autoreverses: true), value: flowPhase)
                    }
                }

                // 滑块（流光/辉光/波浪用发光圆点；极光自带大滑块）
                if style != 2 {
                    Circle()
                        .fill(.white)
                        .frame(width: scrubbing ? 22 : 14, height: scrubbing ? 22 : 14)
                        .overlay {
                            Circle().strokeBorder(.white.opacity(0.95), lineWidth: 0.8)
                        }
                        .shadow(color: accent.opacity(0.7), radius: scrubbing ? 10 : 3.5, y: scrubbing ? 3 : 1)
                        .offset(x: thumbX - (scrubbing ? 11 : 7))
                        .animation(.default, value: scrubbing)
                }

                if scrubbing {
                    Text(atmusicTimeString(scrubValue))
                        .font(ATMusicFont.appFont(11, .semibold, .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background {
                            Capsule()
                                .fill(.black.opacity(0.48))
                                .overlay {
                                    Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.7)
                                }
                        }
                        .shadow(color: accent.opacity(0.35), radius: 10, y: 4)
                        .offset(x: min(max(thumbX - 31, 0), max(width - 62, 0)), y: -25)
                        .transition(.opacity)
                }
            }
            .frame(width: width, height: 42)
            .onAppear {
                if player.isPlaying, !reduceVisualMotion, flowPhase == 0 { flowPhase = 1 }
            }
            .onChange(of: player.isPlaying) { playing in
                flowPhase = (playing && !reduceVisualMotion) ? 1 : 0
            }
            .onChange(of: reduceVisualMotion) { reduced in
                flowPhase = (player.isPlaying && !reduced) ? 1 : 0
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !scrubbing {
                            ATMusicHaptics.medium()
                        }
                        scrubbing = true
                        let raw = min(max(value.location.x / width, 0), 1) * total
                        let snapped = raw.rounded()
                        scrubValue = snapped
                        let previewSecond = Int(snapped)
                        if previewSecond != lastPreviewSecond, previewSecond % 15 == 0 {
                            ATMusicHaptics.select()
                        }
                        lastPreviewSecond = previewSecond
                    }
                    .onEnded { _ in
                        ATMusicHaptics.tap()
                        player.seek(to: scrubValue)
                        scrubbing = false
                        lastPreviewSecond = nil
                    }
            )
        }
        .frame(height: 42)
        .animation(.default, value: scrubbing)
    }
}


// MARK: - 波浪进度条（正弦波形：已播放段高亮，波面缓慢流动）

private struct WaveShape: Shape {
    var phase: CGFloat = 0
    var amplitude: CGFloat = 3.2

    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let mid = rect.midY
        let freq: CGFloat = 2.4
        path.move(to: CGPoint(x: 0, y: mid))
        var x: CGFloat = 0
        while x <= rect.width {
            let y = mid + sin(x / rect.width * .pi * 2 * freq + phase * .pi * 2) * amplitude
            path.addLine(to: CGPoint(x: x, y: y))
            x += 2
        }
        return path
    }
}

private struct WaveBar: View {
    let ratio: Double
    let accent: Color
    let track: Color
    let width: CGFloat
    let isPlaying: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isPlaying)) { context in
            let phase: CGFloat = isPlaying
                ? CGFloat((context.date.timeIntervalSinceReferenceDate / 3).truncatingRemainder(dividingBy: 1))
                : 0
            ZStack(alignment: .leading) {
                // 辉光底层光晕（已播放段模糊扩散，辉光渐变氛围）
                WaveShape(phase: phase)
                    .stroke(accent.opacity(0.5), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .blur(radius: 8)
                    .frame(width: width, height: 16)
                    .frame(width: max(0, width * CGFloat(ratio)), alignment: .leading)
                    .clipped()
                // 未播放波形（暗色渐变轨道）
                WaveShape(phase: phase)
                    .stroke(
                        LinearGradient(colors: [accent.opacity(0.25), track.opacity(0.45), accent.opacity(0.15)],
                                       startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 2.6, lineCap: .round)
                    )
                    .frame(width: width, height: 16)
                // 已播放波形（辉光渐变高亮：白→主色→淡，双阴影辉光）
                WaveShape(phase: phase)
                    .stroke(
                        LinearGradient(colors: [.white.opacity(0.95), accent, accent.opacity(0.6)],
                                       startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 3.6, lineCap: .round)
                    )
                    .shadow(color: accent.opacity(0.8), radius: 6, y: 1)
                    .shadow(color: accent.opacity(0.45), radius: 14)
                    .frame(width: width, height: 16)
                    .frame(width: max(0, width * CGFloat(ratio)), alignment: .leading)
                    .clipped()
            }
            .frame(height: 20)
        }
    }
}


// MARK: - 歌词（居中显示 + 逐行高亮 + 自动滚动 + 点击跳转）

struct LyricsSection: View {
    @EnvironmentObject private var clock: PlaybackClock
    let lyrics: [LyricLine]
    let accent: Color
    let secondary: Color
    var gradientStart: Color? = nil
    var gradientEnd: Color? = nil
    var baseFontSize: CGFloat = 17
    var lineSpacing: CGFloat = 24
    var glowRadius: CGFloat = 9
    /// 显示歌词翻译（当前行下方小字）
    var showTranslation: Bool = false
    /// 歌词对齐样式（居中 / 居左）
    var alignment: HorizontalAlignment = .center
    /// 歌词水平偏移
    var offsetX: CGFloat = 0
    /// 当前行在视口中的垂直锚点
    var anchor: UnitPoint = .center
    /// 自定义发光颜色（nil 时跟随当前行颜色 / 封面取色）
    var glowColorOverride: Color? = nil
    /// 歌词模糊控制：距当前行几行后开始模糊 + 模糊强度（0 = 完全关闭模糊）
    var blurStart: CGFloat = 1
    var blurAmount: CGFloat = 1.1
    /// 歌词 3D 倾斜角度（绕 X 轴，顶部向后倒，0 = 关闭）
    var tilt: CGFloat = 0
    /// 歌词左右倾斜角度（绕 Y 轴，负值向左、正值向右，0 = 关闭）
    var tiltY: CGFloat = 0
    /// 歌词进度偏移（秒）：正数提前、负数延后
    var lyricOffset: CGFloat = 0
    let onTapLine: (LyricLine) -> Void

    /// 长按歌词进入多选复制模式（可多选 / 全选复制）
    @State private var selectionMode = false
    @State private var selected: Set<Int> = []
    /// iOS 27 原生滚动位置；手动滚动时它同时充当视觉焦点。
    @State private var scrollTarget: Int?
    /// 当前高亮歌词行索引（事件驱动缓存：只在换行时更新，阻断 250ms 连续重绘）
    @State private var activeCurrentIndex: Int? = nil
    /// 用户手动滚动时暂停自动跟随，停手后延迟恢复。
    @State private var isUserScrolling = false
    @State private var resumeScrollTask: Task<Void, Never>?

    /// 二分查找计算指定进度下的歌词行索引
    private func computeLyricIndex(for progress: Double) -> Int? {
        guard !lyrics.isEmpty else { return nil }
        let effective = LyricTiming.effectiveProgress(progress, userOffset: Double(lyricOffset))
        var low = 0
        var high = lyrics.count - 1
        var answer: Int?
        while low <= high {
            let mid = (low + high) / 2
            if lyrics[mid].time <= effective {
                answer = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return answer
    }

    private var currentIndex: Int? {
        activeCurrentIndex
    }

    @ViewBuilder
    var body: some View {
        if #available(iOS 18.0, *) {
            modernLyricsBody
        } else {
            compatibilityLyricsBody
        }
    }

    @available(iOS 18.0, *)
    private var modernLyricsBody: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: lineSpacing) {
                ForEach(Array(lyrics.enumerated()), id: \.offset) { index, line in
                    lyricRow(index: index, line: line)
                        .id(index)
                        .scrollTransition(.interactive, axis: .vertical) { content, phase in
                            content
                                .scaleEffect(phase.isIdentity ? 1.0 : 0.94, anchor: alignment == .leading ? .leading : .center)
                                .opacity(phase.isIdentity ? 1.0 : 0.58)
                        }
                        .contentShape(Rectangle())
                        .overlay(alignment: .topTrailing) {
                            if selectionMode {
                                Image(systemName: selected.contains(index) ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(selected.contains(index) ? accent : secondary.opacity(0.55))
                                    .padding(.trailing, 10)
                                    .padding(.top, 2)
                                    .contentTransition(.symbolEffect(.replace))
                                    .transition(.opacity)
                            }
                        }
                        .onTapGesture {
                            if selectionMode {
                                withAnimation { toggleSelect(index) }
                            } else {
                                onTapLine(line)
                            }
                        }
                        .onLongPressGesture(minimumDuration: 0.35) {
                            ATMusicHaptics.medium()
                            withAnimation {
                                if !selectionMode {
                                    selectionMode = true
                                    selected = [index]
                                } else {
                                    toggleSelect(index)
                                }
                            }
                        }
                }
            }
            .scrollTargetLayout()
            .padding(.vertical, max(120, (baseFontSize * 2.0 + baseFontSize * 0.7 + lineSpacing * 0.4 + 4) * 2.4))
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .offset(x: offsetX)
        .scrollPosition(id: $scrollTarget, anchor: .center)
        .atmusicScrollIndicatorsHidden()
        .rotation3DEffect(.degrees(Double(tilt)), axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.5)
        .rotation3DEffect(.degrees(Double(tiltY)), axis: (x: 0, y: 1, z: 0), anchor: .center, perspective: 0.5)
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .black, location: 0.10),
                    .init(color: .black, location: 0.90),
                    .init(color: .clear, location: 1.0)
                ],
                startPoint: .top, endPoint: .bottom
            )
        )
        .overlay(alignment: .top) {
            if selectionMode {
                selectionBar
                    .padding(.top, 4)
                    .transition(.opacity)
            }
        }
        .onScrollPhaseChange { _, phase in
            switch phase {
            case .tracking, .interacting, .decelerating:
                isUserScrolling = true
                resumeScrollTask?.cancel()
            case .idle:
                scheduleLyricsFollowResume()
            case .animating:
                break
            @unknown default:
                break
            }
        }
        .onAppear {
            let initial = computeLyricIndex(for: clock.progress)
            activeCurrentIndex = initial
            scrollTarget = initial
        }
        .onChange(of: clock.progress) { newProgress in
            let newIndex = computeLyricIndex(for: newProgress)
            if newIndex != activeCurrentIndex {
                activeCurrentIndex = newIndex
            }
        }
        .onChange(of: lyricOffset) { _ in
            let newIndex = computeLyricIndex(for: clock.progress)
            if newIndex != activeCurrentIndex {
                activeCurrentIndex = newIndex
            }
        }
        .onChange(of: activeCurrentIndex) { newIndex in
            guard let newIndex, !isUserScrolling else { return }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) {
                scrollTarget = newIndex
            }
        }
        // 字号/行距动态变化后，强制高亮行按新行高重新对齐视口中心（scrollPosition 会重新计算锚点）
        .onChange(of: baseFontSize) { _ in
            recenterToCurrentLyric()
        }
        .onChange(of: lineSpacing) { _ in
            recenterToCurrentLyric()
        }
        .onChange(of: showTranslation) { _ in
            recenterToCurrentLyric()
        }
        .onDisappear {
            resumeScrollTask?.cancel()
        }
    }

    /// 低系统版本只保留基础可滚动歌词；iOS 27 主路径完全不走这里。
    private var compatibilityLyricsBody: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: lineSpacing) {
                ForEach(Array(lyrics.enumerated()), id: \.offset) { index, line in
                    lyricRow(index: index, line: line)
                        .id(index)
                        .contentShape(Rectangle())
                        .onTapGesture { onTapLine(line) }
                }
            }
            .padding(.top, 210)
            .padding(.bottom, 210)
        }
        .offset(x: offsetX)
        .atmusicScrollIndicatorsHidden()
    }

    private func recenterToCurrentLyric() {
        guard !isUserScrolling, let currentIndex else { return }
        withAnimation(.spring(response: 0.50, dampingFraction: 0.82)) {
            scrollTarget = currentIndex
        }
    }

    private func scheduleLyricsFollowResume() {
        resumeScrollTask?.cancel()
        resumeScrollTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            isUserScrolling = false
            guard let currentIndex else { return }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) {
                scrollTarget = currentIndex
            }
        }
    }

    /// Apple Music 风格渐隐：当前行最大最亮，已播放行与未播放行按距离逐层变暗变淡
    private func lyricRow(index: Int, line: LyricLine) -> some View {
        let playbackIndex = currentIndex ?? 0
        // 手动滚动时，以视口中心行为清晰度焦点；颜色和渐变仍只跟随实际播放行。
        // 这样拖动歌词不会暂停播放，也不会让整页歌词一起变糊。
        let visualIndex = isUserScrolling ? (scrollTarget ?? currentIndex) : currentIndex
        let isCurrent = currentIndex != nil && index == playbackIndex
        let isFocused = index == visualIndex
        let isPlayed = (currentIndex ?? -1) >= 0 && index < playbackIndex
        let distance = abs(index - (visualIndex ?? playbackIndex))
        let opacity: Double = isFocused
            ? 1.0
            : (isPlayed ? 0.28 : 0.62) - Double(min(distance, 4)) * 0.05
        let size = baseFontSize
        // 歌词行模糊：当前行与邻近行保持清晰，距离越远才越柔和（避免只剩一行清晰显得突兀）
        // 模糊起始距离与强度由用户控制（0 强度 = 完全关闭模糊）
        let blurRadius: CGFloat = isFocused ? 0 : min(CGFloat(max(distance - Int(blurStart), 0)) * blurAmount, 7.0)

        // 当前行用渐变（封面色或自定义），光晕跟随渐变起始色
        let lineStyle: AnyShapeStyle
        if isCurrent, let gradientStart, let gradientEnd {
            lineStyle = AnyShapeStyle(LinearGradient(colors: [gradientStart, gradientEnd], startPoint: .top, endPoint: .bottom))
        } else {
            lineStyle = AnyShapeStyle(isCurrent ? accent : secondary)
        }
        let glowColor = glowColorOverride ?? (gradientStart ?? accent)

        let lineFont: Font = ATMusicFont.appFont(size)
        // 译文行仅在“显示翻译且该行有译文”时渲染；无译文时不占高度（高度为 0），行距可真正压小
        let translation = (showTranslation && line.translation?.isEmpty == false) ? line.translation : nil
        // 行高跟随实际内容自然撑开，无固定槽位下限：正文最多两行、翻译行恒占位（" "），
        // 单行歌词行距可真正调小，多行 + 翻译自动变高；翻译显隐不改几何高度。
        // 每行自身中心即内容中心，scrollPosition(.center) 把高亮行滚到视口中心，
        // 因此一行、两行、三行带翻译时文字内容始终居中。

        return VStack(alignment: alignment == .leading ? .leading : .center, spacing: 3) {
            Text(line.text.isEmpty ? " " : line.text)
                .font(lineFont)
                .foregroundStyle(lineStyle)
                // 双层光晕：内层亮、外层宽，发光更明显
                .shadow(
                    color: isCurrent ? glowColor.opacity(glowRadius > 0 ? 0.9 : 0) : .clear,
                    radius: isCurrent ? glowRadius * 0.45 : 0
                )
                .shadow(
                    color: isCurrent ? glowColor.opacity(glowRadius > 0 ? 0.55 : 0) : .clear,
                    radius: isCurrent ? glowRadius : 0
                )
                .blur(radius: blurRadius)
                .opacity(max(opacity, 0.15))
                .scaleEffect(isFocused ? 1.10 : max(0.92, 1.0 - CGFloat(min(distance, 2)) * 0.04), anchor: alignment == .leading ? .leading : .center)
                .multilineTextAlignment(alignment == .leading ? .leading : .center)
                .lineLimit(2)
                .minimumScaleFactor(0.82)
                .fixedSize(horizontal: false, vertical: true)
            if let translation {
                Text(translation)
                    .font(ATMusicFont.appFont(size * 0.68, .regular))
                    .foregroundStyle(secondary.opacity(isCurrent ? 0.9 : 0))
                    .multilineTextAlignment(alignment == .leading ? .leading : .center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .blur(radius: blurRadius * 0.5)
                    .opacity(max(opacity, 0.2))
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .center)
        .padding(.horizontal, alignment == .leading ? 40 : 36)
        .overlay(alignment: .trailing) {
            Text(atmusicTimeString(line.time))
                .font(ATMusicFont.appFont(11, .semibold, .monospaced))
                .foregroundStyle(secondary.opacity(isUserScrolling && isFocused ? 0.82 : 0))
                .frame(width: 42, alignment: .trailing)
                .padding(.trailing, alignment == .leading ? 40 : 36)
                .accessibilityHidden(!(isUserScrolling && isFocused))
        }
        .animation(.spring(response: 0.48, dampingFraction: 0.82), value: isFocused)
        .animation(.spring(response: 0.48, dampingFraction: 0.82), value: isCurrent)
    }

    private func toggleSelect(_ index: Int) {
        if selected.contains(index) {
            selected.remove(index)
        } else {
            selected.insert(index)
        }
    }

    private func copySelected() {
        let text = selected.sorted()
            .compactMap { idx -> String? in
                lyrics.indices.contains(idx) ? lyrics[idx].text : nil
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
        ATMusicHaptics.success()
        withAnimation {
            selectionMode = false
            selected = []
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 16) {
            Button {
                withAnimation { selected = Set(lyrics.indices) }
            } label: {
                Text("全选")
                    .font(ATMusicFont.appFont(13, .medium))
                    .foregroundStyle(accent)
            }
            .buttonStyle(.plain)
            Button {
                copySelected()
            } label: {
                Text(selected.isEmpty ? "复制" : "复制 (\(selected.count))")
                    .font(ATMusicFont.appFont(13, .semibold))
                    .foregroundStyle(accent)
            }
            .buttonStyle(.plain)
            Spacer()
            Button {
                withAnimation {
                    selectionMode = false
                    selected = []
                }
            } label: {
                Text("取消")
                    .font(ATMusicFont.appFont(13))
                    .foregroundStyle(secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background {
            ATMusicGlass(shape: Capsule())
                .overlay {
                    Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.7)
                }
        }
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }

}

// MARK: - 歌词渐变预设（一键组合：渐变起止色 + 发光强度）

struct LyricPreset {
    let name: String
    let start: String
    let end: String
    let glow: Int

    static let all: [LyricPreset] = [
        LyricPreset(name: "晨曦金", start: "#FFD08A", end: "#FF7A3D", glow: 2),
        LyricPreset(name: "冰蓝极光", start: "#8FD8FF", end: "#5B6BFF", glow: 2),
        LyricPreset(name: "霓虹紫", start: "#E8A2FF", end: "#8A2BE2", glow: 3),
        LyricPreset(name: "草莓奶昔", start: "#FF9AB5", end: "#FF5E8A", glow: 1),
        LyricPreset(name: "鎏金夜曲", start: "#F5D98B", end: "#C9A227", glow: 2),
        LyricPreset(name: "薄荷气泡", start: "#A8F0D4", end: "#2BC48D", glow: 2),
    ]
}

// MARK: - 播放器设置（更多菜单 → 播放器设置：进度条样式 / 背景光晕 / 歌词字号 / 颜色色盘）

struct PlayerSettingsSheet: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var clock: PlaybackClock
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var favorites: FavoritesStore
    private let onDismiss: (() -> Void)?
    @AppStorage("atmusic.playerDustMode") private var playerDustModeRaw = ATMusicPlayerDustMode.off.rawValue
    @AppStorage("atmusic.playerDustDensity") private var playerDustDensity = 1.0
    @AppStorage("atmusic.playerDustSize") private var playerDustSize = 1.0
    @AppStorage("atmusic.playerControlsUseCoverColor") private var controlsUseCoverColor = true
    @AppStorage("atmusic.playerMainIconColorHex") private var playerMainIconColorHex = ""
    @AppStorage("atmusic.playerSecondaryIconColorHex") private var playerSecondaryIconColorHex = ""
    @AppStorage("atmusic.playerPrimaryButtonColorHex") private var playerPrimaryButtonColorHex = ""
    @AppStorage("atmusic.progressBarStyle") private var progressBarStyle = 0
    @AppStorage("atmusic.progressAccentHex") private var progressAccentHex = ""
    @AppStorage("atmusic.lyricFontSize") private var fontSize = 17
    @AppStorage("atmusic.lyricSpacing") private var lineSpacing = 16
    @AppStorage("atmusic.lyricGlow") private var glowLevel = 1
    @AppStorage("atmusic.lyricColor") private var currentColorRaw = "accent"
    @AppStorage("atmusic.lyricDimColor") private var dimColorRaw = "dim"
    @AppStorage("atmusic.lyricGradStart") private var gradStartRaw = ""
    @AppStorage("atmusic.lyricGradEnd") private var gradEndRaw = ""
    @AppStorage("atmusic.lyricGradMode") private var gradMode = 0
    @AppStorage("atmusic.lyricTranslation") private var lyricTranslation = true
    @AppStorage("atmusic.playerLayoutMode") private var layoutMode = false
    @AppStorage("atmusic.playerLayoutSelectedPart") private var layoutPartRaw = PlayerLayoutPart.progress.rawValue
    @AppStorage("atmusic.lyricAlignRaw") private var lyricAlignRaw = "center"
    @AppStorage("atmusic.lyricOffsetX") private var lyricOffsetX = 0.0
    @AppStorage("atmusic.lyricAnchorY") private var lyricAnchorY = 0.0
    @AppStorage("atmusic.deckGrabberEnabled") private var deckGrabberEnabled = true
    @AppStorage("atmusic.circularCover") private var circularCover = true
    @AppStorage("atmusic.circularCoverSpin") private var circularCoverSpin = true
    @AppStorage("atmusic.djVisual") private var djVisualEnabled = false
    @AppStorage("atmusic.djVisualIntensity") private var djVisualIntensity = 0.8
    @AppStorage("atmusic.lyricGlowColorRaw") private var glowColorRaw = ""
    @AppStorage("atmusic.swipeSwitchSong") private var swipeSwitchSong = true
    @AppStorage("atmusic.lyricBlurStart") private var lyricBlurStart = 1
    @AppStorage("atmusic.lyricBlurAmount") private var lyricBlurAmount = 1.1
    @AppStorage("atmusic.lyricTilt") private var lyricTilt = 0
    @AppStorage("atmusic.lyricTiltY") private var lyricTiltY = 0
    @AppStorage("atmusic.lyricOffset") private var lyricOffset = 0.0
    @AppStorage("atmusic.lyricBackground.image") private var lyricBackgroundImagePath = ""
    @AppStorage("atmusic.lyricBackground.blur") private var lyricBackgroundBlur = 12.0
    @AppStorage("atmusic.lyricBackground.syncCover") private var lyricBackgroundSyncCover = false
    @AppStorage("atmusic.albumTitleColorHex") private var albumTitleColorHex = ""
    @AppStorage("atmusic.albumArtistColorHex") private var albumArtistColorHex = ""
    @AppStorage("atmusic.albumPreviewLyricColorHex") private var albumPreviewLyricColorHex = ""
    @AppStorage("atmusic.albumPreviewDimColorHex") private var albumPreviewDimColorHex = ""
    @AppStorage("atmusic.albumTextGradient") private var albumTextGradient = false
    @AppStorage("atmusic.albumTextGlow") private var albumTextGlow = false
    @AppStorage("atmusic.albumTextGlowIntensity") private var albumTextGlowIntensity = 1.0
    @AppStorage("atmusic.coverPlayerStyle") private var coverPlayerStyleRaw = ATMusicCoverPlayerStyle.appleMusic.rawValue
    @AppStorage("atmusic.appleMusic.showLyricPreview") private var appleShowLyricPreview = true
    @Environment(\.dismiss) private var dismiss
    @State private var showLayoutEditor = false
    @ObservedObject private var appleLayout = AppleMusicLayoutStore.shared

    init(onDismiss: (() -> Void)? = nil) {
        self.onDismiss = onDismiss
    }


    /// 当前行高亮色：色盘选色写入 hex，关闭面板后依然生效
    private var currentColor: Binding<Color> {
        Binding(
            get: {
                if currentColorRaw.hasPrefix("#"), let c = Color(hex: currentColorRaw) { return c }
                return Color.atmusicAmber
            },
            set: { newValue in
                currentColorRaw = "#" + UIColor(newValue).hexString
                gradMode = 1
            }
        )
    }

    /// 未播放歌词颜色：同上
    private var dimColor: Binding<Color> {
        Binding(
            get: {
                if dimColorRaw.hasPrefix("#"), let c = Color(hex: dimColorRaw) { return c }
                return Color.atmusicComment
            },
            set: { newValue in
                dimColorRaw = "#" + UIColor(newValue).hexString
                gradMode = 1
            }
        )
    }

    /// 歌词发光颜色：留空时跟随当前行颜色 / 封面取色
    private var glowColor: Binding<Color> {
        Binding(
            get: {
                if glowColorRaw.hasPrefix("#"), let c = Color(hex: glowColorRaw) { return c }
                return Color.atmusicAmber
            },
            set: { newValue in
                glowColorRaw = "#" + UIColor(newValue).hexString
            }
        )
    }

    /// 进度条单独颜色：留空时跟随播放控件颜色


    private var albumTitleColor: Binding<Color> {
        Binding(
            get: {
                if albumTitleColorHex.hasPrefix("#"), let c = Color(hex: albumTitleColorHex) { return c }
                return Color.atmusicLabel
            },
            set: { albumTitleColorHex = "#" + UIColor($0).hexString }
        )
    }

    private var albumArtistColor: Binding<Color> {
        Binding(
            get: {
                if albumArtistColorHex.hasPrefix("#"), let c = Color(hex: albumArtistColorHex) { return c }
                return Color.atmusicComment
            },
            set: { albumArtistColorHex = "#" + UIColor($0).hexString }
        )
    }

    private var albumPreviewLyricColor: Binding<Color> {
        Binding(
            get: {
                if albumPreviewLyricColorHex.hasPrefix("#"), let c = Color(hex: albumPreviewLyricColorHex) { return c }
                return Color.atmusicLabel
            },
            set: { albumPreviewLyricColorHex = "#" + UIColor($0).hexString }
        )
    }

    private var albumPreviewDimColor: Binding<Color> {
        Binding(
            get: {
                if albumPreviewDimColorHex.hasPrefix("#"), let c = Color(hex: albumPreviewDimColorHex) { return c }
                return Color.atmusicComment
            },
            set: { albumPreviewDimColorHex = "#" + UIColor($0).hexString }
        )
    }


    /// iOS 27 风格的播放器设置入口：布局编辑器和播放器风格放在最上方，
    /// 让用户不需要进入播放页调试条，也可以在手机上完成调整并保存。
    private var layoutEditorCard: some View {
        settingCard("自定义布局") {
            Button {
                ATMusicHaptics.select()
                showLayoutEditor = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                        .frame(width: 34, height: 34)
                        .background(Color.atmusicAmber.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("打开播放器布局编辑器")
                            .font(ATMusicFont.appFont(14, .semibold))
                            .foregroundStyle(Color.atmusicLabel)
                        Text("拖动、缩放、旋转和调整透明度，修改会自动保存在本机")
                            .font(ATMusicFont.appFont(11))
                            .foregroundStyle(Color.atmusicComment)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.atmusicComment)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    /// 设置首页的封面风格选择，和布局编辑器保持同一套持久化选项。
    private var coverStyleCard: some View {
        settingCard("封面") {
            Text("播放器风格")
                .font(ATMusicFont.appFont(13, .semibold))
                .foregroundStyle(Color.atmusicLabel)
            ForEach(ATMusicCoverPlayerStyle.allCases) { style in
                let selected = coverPlayerStyleRaw == style.rawValue
                Button {
                    coverPlayerStyleRaw = style.rawValue
                    ATMusicHaptics.select()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: style.icon)
                            .font(.system(size: 14, weight: .semibold))
                                                        .atmusicSelectionForeground(selected: selected, accent: .atmusicAmber, unselected: Color.atmusicAmber)
                            .frame(width: 32, height: 32)
                            .background {
                                ATMusicSelectableSurface(selected: selected, shape: Circle(), accent: .atmusicAmber)
                            }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(LocalizedStringKey(style.title))
                                .font(ATMusicFont.appFont(13, .semibold))
                                .foregroundStyle(Color.atmusicLabel)
                            Text(LocalizedStringKey(style.subtitle))
                                .font(ATMusicFont.appFont(11))
                                .foregroundStyle(Color.atmusicComment)
                                .lineLimit(1)
                        }
                        Spacer()
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.atmusicAmber)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity)
                    .background {
                        ATMusicSelectableSurface(
                            selected: selected,
                            shape: RoundedRectangle(cornerRadius: 14, style: .continuous),
                            accent: .atmusicAmber
                        )
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 渐变起始色：空值时自动用主题强调色


    /// 渐变结束色：空值时自动用主题次色


    var body: some View {
        let _ = theme.accent
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.34)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Capsule()
                    .fill(Color.atmusicComment.opacity(0.62))
                    .frame(width: 38, height: 5)
                    .padding(.top, 10)
                    .padding(.bottom, 13)

                HStack(alignment: .center) {
                    Text("播放器设置")
                        .font(ATMusicFont.appFont(20, .bold))
                        .foregroundStyle(Color.atmusicLabel)
                    Spacer()
                    Button("完成") {
                        if let onDismiss {
                            onDismiss()
                        } else {
                            dismiss()
                        }
                    }
                    .font(ATMusicFont.appFont(15, .semibold))
                    .foregroundStyle(Color.atmusicLabel)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Color.atmusicComment.opacity(0.18), in: Capsule())
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 18)

                ScrollView {
                    LazyVStack(spacing: 12) {
                        layoutEditorCard
                        coverStyleCard
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 34)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
                .atmusicScrollIndicatorsHidden()
            }
            .background {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
                    .overlay(Color.black.opacity(0.22))
            }
            .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
            .padding(.top, 42)
        }

        .onAppear {
            if let path = LyricBackgroundStore.restoreFromBackup(), lyricBackgroundImagePath != path {
                lyricBackgroundImagePath = path
            }
        }
        .fullScreenCover(isPresented: $showLayoutEditor) {
            PlayerLayoutEditorSheet()
                .environmentObject(theme)
                .environmentObject(player)
                .environmentObject(clock)
                .environmentObject(auth)
                .environmentObject(favorites)
        }
    }

    // MARK: - 设置卡片（液态玻璃圆角分组，紧凑排版）

    /// 设置卡片容器：液态玻璃圆角卡片
    private func settingCard<Content: View>(_ title: String, isExpanded: Binding<Bool>? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if let isExpanded {
                Button {
                    withAnimation(.snappy(duration: 0.16)) {
                        isExpanded.wrappedValue.toggle()
                    }
                    ATMusicHaptics.select()
                } label: {
                    HStack(spacing: 10) {
                        Text(LocalizedStringKey(title))
                            .font(ATMusicFont.appFont(13, .bold))
                            .foregroundStyle(Color.atmusicLabel)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.atmusicComment)
                            .rotationEffect(.degrees(isExpanded.wrappedValue ? 0 : -90))
                            .frame(width: 24, height: 24)
                    }
                    .frame(minHeight: 38)
                    .contentShape(Rectangle())
                }
                .buttonStyle(GlassPressButtonStyle(scale: 0.98))

                if isExpanded.wrappedValue {
                    content()
                        .transition(.opacity)
                }
            } else {
                Text(LocalizedStringKey(title))
                    .font(ATMusicFont.appFont(14, .bold))
                    .foregroundStyle(Color.atmusicLabel)
                content()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                SettingsCompactGlassSurface(cornerRadius: 16)
            }
    }

    /// 开关行（标题 + 可选的短说明）
    private func settingToggle(_ title: String, isOn: Binding<Bool>, caption: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(LocalizedStringKey(title), isOn: isOn)
                .tint(Color.atmusicAmber)
                .font(ATMusicFont.appFont(14))
            if let caption {
                Text(LocalizedStringKey(caption))
                    .font(ATMusicFont.appFont(12))
                    .foregroundStyle(Color.atmusicComment)
            }
        }
    }

    /// 滑块行（标题 + 数值内联显示）
    private func settingSlider<L: View>(_ title: String, valueText: String, @ViewBuilder slider: () -> L) -> some View {
        VStack(spacing: 5) {
            HStack {
                Text(LocalizedStringKey(title))
                    .font(ATMusicFont.appFont(13))
                    .foregroundStyle(Color.atmusicLabel)
                Spacer()
                Text(atmusicLocalizedSettingValue(valueText))
                    .font(ATMusicFont.appFont(12, .semibold))
                    .foregroundStyle(Color.atmusicAmber)
            }
            slider()
        }
    }


    private func glowName(_ level: Int) -> String {
        switch level {
        case 0: return "关闭"
        case 1: return "柔和"
        case 2: return "标准"
        case 3: return "强烈"
        case 4: return "明亮"
        default: return "极亮"
        }
    }
}

struct ShareFileItem: Identifiable {
    let id = UUID()
    let url: URL
}

// MARK: - 原生系统分享面板（UIActivityViewController 封装，直接调系统自带分享）

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        // iPad 弹出需要 popover 锚点，否则会崩溃
        if let popover = controller.popoverPresentationController {
            popover.sourceView = controller.view
            popover.permittedArrowDirections = []
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - 圆形封面旋转（播放中匀速旋转，暂停即停）
struct CoverSpin: ViewModifier {
    let enabled: Bool
    let isPlaying: Bool

    func body(content: Content) -> some View {
        if enabled {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isPlaying)) { context in
                let angle = (context.date.timeIntervalSinceReferenceDate * 15)
                    .truncatingRemainder(dividingBy: 360)
                return content
                    .rotationEffect(.degrees(angle))
            }
        } else {
            content
        }
    }
}

// MARK: - 播放器设置项紧凑分组卡片（跟随全局 UI 样式）

private struct CompactSettingGroup<Content: View>: View {
    @AppStorage("atmusic.uiStyle") private var uiStyleRaw = ATMusicUIStyle.liquid.rawValue
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ATMusicGlass(shape: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}
