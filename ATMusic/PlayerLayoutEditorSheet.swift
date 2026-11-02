import SwiftUI
import UIKit

/// 全新播放器布局与歌词编辑器：
/// 1. 分屏设计：上半区吸顶固定微缩实时真机预览（Sticky Live Preview），下半区独立滑动多功能控制台，彻底解决“无法边调边看”的痛点；
/// 2. 四套播放器（Apple Music / 沉浸式 / 黑胶唱片 / 经典模式）统一归整，随时切换预览；
/// 3. 四套样式的组件坐标、缩放、歌词字体字号、行距、高亮与常规颜色、翻译开关、发光辉光、3D 景深全部支持针对性独立微调并持久化保存。
struct PlayerLayoutEditorSheet: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var clock: PlaybackClock
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var favorites: FavoritesStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appleLayout = AppleMusicLayoutStore.shared

    // 播放器风格与外观
    @AppStorage("atmusic.coverPlayerStyle") private var coverPlayerStyleRaw = ATMusicCoverPlayerStyle.appleMusic.rawValue
    // 按钮样式按播放器样式独立设置（经典/唱片/沉浸式各记各的；Apple Music 风格天生无圆圈）
    @AppStorage("atmusic.playerButtonStyle.classic") private var classicButtonStyleRaw = ATMusicPlayerButtonStyle.appleMusic.rawValue
    @AppStorage("atmusic.playerButtonStyle.vinyl") private var vinylButtonStyleRaw = ATMusicPlayerButtonStyle.appleMusic.rawValue
    @AppStorage("atmusic.playerButtonStyle.immersive") private var immersiveButtonStyleRaw = ATMusicPlayerButtonStyle.appleMusic.rawValue

    // MARK: - 从播放器设置页按功能归位迁移的视觉设置（与播放器设置页共用同一套 key，实时预览调整）
    // 歌词排版
    @AppStorage("atmusic.lyricBlurStart") private var lyricBlurStart = 1
    @AppStorage("atmusic.lyricTiltY") private var lyricTiltY = 0
    // 色彩发光：渐变色
    @AppStorage("atmusic.lyricGradStart") private var gradStartRaw = ""
    @AppStorage("atmusic.lyricGradEnd") private var gradEndRaw = ""
    // 色彩发光：歌词背景
    @AppStorage("atmusic.lyricBackground.image") private var lyricBackgroundImagePath = ""
    @State private var showLyricBackgroundPicker = false
    @AppStorage("atmusic.lyricBackground.blur") private var lyricBackgroundBlur = 12.0
    @AppStorage("atmusic.lyricBackground.syncCover") private var lyricBackgroundSyncCover = false
    // 色彩发光：封面文字
    @AppStorage("atmusic.albumTextGradient") private var albumTextGradient = false
    @AppStorage("atmusic.albumTextGlow") private var albumTextGlow = false
    @AppStorage("atmusic.albumTextGlowIntensity") private var albumTextGlowIntensity = 1.0
    @AppStorage("atmusic.albumTitleColorHex") private var albumTitleColorHex = ""
    @AppStorage("atmusic.albumArtistColorHex") private var albumArtistColorHex = ""
    @AppStorage("atmusic.albumPreviewLyricColorHex") private var albumPreviewLyricColorHex = ""
    @AppStorage("atmusic.albumPreviewDimColorHex") private var albumPreviewDimColorHex = ""
    // 色彩发光：播放器控件与进度条
    @AppStorage("atmusic.playerControlsUseCoverColor") private var controlsUseCoverColor = true
    @AppStorage("atmusic.playerMainIconColorHex") private var playerMainIconColorHex = ""
    @AppStorage("atmusic.playerSecondaryIconColorHex") private var playerSecondaryIconColorHex = ""
    @AppStorage("atmusic.playerPrimaryButtonColorHex") private var playerPrimaryButtonColorHex = ""
    @AppStorage("atmusic.progressAccentHex") private var progressAccentHex = ""
    @AppStorage("atmusic.progressBarStyle") private var progressBarStyle = 0
    @AppStorage("atmusic.playerBreath") private var breath = 0.6
    @AppStorage("atmusic.playerDustMode") private var playerDustModeRaw = ATMusicPlayerDustMode.off.rawValue
    @AppStorage("atmusic.playerDustDensity") private var playerDustDensity = 1.0
    @AppStorage("atmusic.playerDustSize") private var playerDustSize = 1.0
    @AppStorage("atmusic.djVisual") private var djVisualEnabled = false
    @AppStorage("atmusic.djVisualIntensity") private var djVisualIntensity = 0.8
    // 组件布局：指示线
    @AppStorage("atmusic.deckGrabberEnabled") private var deckGrabberEnabled = true
    @AppStorage("atmusic.appleMusic.showLyricPreview") private var showLyricPreview = true
    @AppStorage("atmusic.appleMusic.showVolume") private var showVolume = false
    @AppStorage("atmusic.appleMusic.syncWallpaper") private var syncWallpaper = false
    @AppStorage("atmusic.appleMusic.primaryHex") private var primaryHex = ""
    @AppStorage("atmusic.appleMusic.secondaryHex") private var secondaryHex = ""
    @AppStorage("atmusic.appleMusic.accentHex") private var accentHex = ""
    @AppStorage("atmusic.appleMusic.volumeHex") private var volumeHex = ""
    @AppStorage("atmusic.circularCover") private var circularCover = true

    // 歌词字体、排版与色彩设置（四套通用/全局持久化）
    @AppStorage("atmusic.lyricFontSize") private var lyricFontSize = 17
    @AppStorage("atmusic.lyricSpacing") private var lyricLineSpacing = 24
    @AppStorage("atmusic.lyricOffset") private var lyricOffset = 0.0
    @AppStorage("atmusic.lyricTranslation") private var lyricTranslation = true
    @AppStorage("atmusic.lyricAlignRaw") private var lyricAlignRaw = "center"
    @AppStorage("atmusic.lyricTilt") private var lyricTilt = 0
    @AppStorage("atmusic.lyricGradMode") private var lyricGradMode = 0
    @AppStorage("atmusic.lyricColor") private var lyricColorRaw = "accent"
    @AppStorage("atmusic.lyricDimColor") private var lyricDimColorRaw = "dim"
    @AppStorage("atmusic.lyricGlow") private var lyricGlowLevel = 1
    @AppStorage("atmusic.lyricGlowColorRaw") private var lyricGlowColorRaw = ""
    @AppStorage("atmusic.lyricBlurAmount") private var lyricBlurAmount = 1.1

    // 编辑器界面状态
    @State private var editorTab: Int = 0 // 0: 组件布局, 1: 歌词排版, 2: 色彩发光, 3: 预设重置
    @State private var previewMode: Int = 0 // 0: 封面页, 1: 歌词页
    @State private var selectedApplePart: AppleMusicLayoutPart = .cover
    @State private var selectedLegacyPart: PlayerLayoutPart = .cover
    @State private var legacyLayoutData: [String: PlayerLayoutEntry] = PlayerLayoutStore.load()
    @State private var realLyrics: [LyricLine] = []

    private var activeStyle: ATMusicCoverPlayerStyle {
        ATMusicCoverPlayerStyle(rawValue: coverPlayerStyleRaw) ?? .appleMusic
    }

    private var activeLegacyStyle: ATMusicCoverPlayerStyle {
        activeStyle == .vinyl ? .vinyl : (activeStyle == .immersive ? .immersive : .classic)
    }

    /// 当前选中播放器样式的按钮风格（读写各自独立的 key）
    private var activeButtonStyleRaw: Binding<String> {
        switch activeStyle {
        case .immersive: return $immersiveButtonStyleRaw
        case .vinyl: return $vinylButtonStyleRaw
        case .classic: return $classicButtonStyleRaw
        case .appleMusic: return .constant(ATMusicPlayerButtonStyle.appleMusic.rawValue)
        }
    }

    // MARK: - 迁移设置的辅助
    private var tiltYText: String {
        if lyricTiltY == 0 { return "关闭" }
        return lyricTiltY > 0 ? "右倾 \(lyricTiltY)°" : "左倾 \(-lyricTiltY)°"
    }

    private var gradStart: Binding<Color> {
        Binding(
            get: {
                if gradStartRaw.hasPrefix("#"), let c = Color(hex: gradStartRaw) { return c }
                return Color.atmusicAmber
            },
            set: { newValue in
                gradStartRaw = "#" + UIColor(newValue).hexString
                lyricGradMode = 1
            }
        )
    }

    private var gradEnd: Binding<Color> {
        Binding(
            get: {
                if gradEndRaw.hasPrefix("#"), let c = Color(hex: gradEndRaw) { return c }
                return Color.atmusicAmber
            },
            set: { newValue in
                gradEndRaw = "#" + UIColor(newValue).hexString
                lyricGradMode = 1
            }
        )
    }

    private var playerMainIconColor: Binding<Color> {
        Binding(
            get: {
                if playerMainIconColorHex.hasPrefix("#"), let c = Color(hex: playerMainIconColorHex) { return c }
                return Color.atmusicLabel
            },
            set: { playerMainIconColorHex = "#" + UIColor($0).hexString }
        )
    }

    private var playerSecondaryIconColor: Binding<Color> {
        Binding(
            get: {
                if playerSecondaryIconColorHex.hasPrefix("#"), let c = Color(hex: playerSecondaryIconColorHex) { return c }
                return Color.atmusicLabel.opacity(0.7)
            },
            set: { playerSecondaryIconColorHex = "#" + UIColor($0).hexString }
        )
    }

    private var playerPrimaryButtonColor: Binding<Color> {
        Binding(
            get: {
                if playerPrimaryButtonColorHex.hasPrefix("#"), let c = Color(hex: playerPrimaryButtonColorHex) { return c }
                return Color.atmusicAmber
            },
            set: { playerPrimaryButtonColorHex = "#" + UIColor($0).hexString }
        )
    }

    private var progressAccentColor: Binding<Color> {
        Binding(
            get: {
                if progressAccentHex.hasPrefix("#"), let c = Color(hex: progressAccentHex) { return c }
                return Color.atmusicAmber
            },
            set: { newValue in
                progressAccentHex = "#" + UIColor(newValue).hexString
            }
        )
    }

    private func coverTextColor(hex: Binding<String>, fallback: Color) -> Binding<Color> {
        Binding(
            get: {
                if hex.wrappedValue.hasPrefix("#"), let c = Color(hex: hex.wrappedValue) { return c }
                return fallback
            },
            set: { hex.wrappedValue = "#" + UIColor($0).hexString }
        )
    }

    private var dustModeSelector: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text("背景浮尘")
                    .font(ATMusicFont.appFont(13, .semibold))
                    .foregroundStyle(Color.atmusicLabel)
                Text("关闭可隐藏播放页小白点，动态轻雪只在播放时运动")
                    .font(ATMusicFont.appFont(12))
                    .foregroundStyle(Color.atmusicComment)
            }
            HStack(spacing: 8) {
                ForEach(ATMusicPlayerDustMode.allCases) { mode in
                    let selected = playerDustModeRaw == mode.rawValue
                    Button {
                        playerDustModeRaw = mode.rawValue
                        ATMusicHaptics.select()
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: mode.icon)
                                .font(.system(size: 14, weight: .semibold))
                            Text(LocalizedStringKey(mode.title))
                                .font(ATMusicFont.appFont(11, .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.78)
                        }
                        .atmusicSelectionForeground(selected: selected, accent: .atmusicAmber)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background {
                            ATMusicSelectableSurface(
                                selected: selected,
                                shape: RoundedRectangle(cornerRadius: 13, style: .continuous),
                                accent: .atmusicAmber
                            )
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// 进度条样式：全局 UI 样式统一选中态。
    private var progressStyleGrid: some View {
        let styles: [(Int, String, String)] = [
            (0, "流光", "rays"),
            (1, "辉光", "sun.max"),
            (2, "极光", "sparkles"),
            (3, "波浪", "waveform"),
        ]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            ForEach(styles, id: \.0) { idx, name, icon in
                let selected = progressBarStyle == idx
                Button {
                    progressBarStyle = idx
                    ATMusicHaptics.select()
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: icon)
                            .font(.system(size: 15, weight: .medium))
                        Text(name)
                            .font(ATMusicFont.appFont(11, .medium))
                    }
                    .atmusicSelectionForeground(selected: selected, accent: .atmusicAmber)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background {
                        ATMusicSelectableSurface(
                            selected: selected,
                            shape: RoundedRectangle(cornerRadius: 12, style: .continuous),
                            accent: .atmusicAmber
                        )
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var selectedEntry: Binding<PlayerLayoutEntry> {
        Binding(
            get: {
                if activeStyle == .appleMusic {
                    return appleLayout.entry(for: selectedApplePart)
                }
                return legacyLayoutData[selectedLegacyPart.rawValue] ?? PlayerLayoutStore.defaultEntry(for: selectedLegacyPart, style: activeLegacyStyle)
            },
            set: { newValue in
                if activeStyle == .appleMusic {
                    appleLayout.set(newValue, for: selectedApplePart)
                } else {
                    legacyLayoutData[selectedLegacyPart.rawValue] = newValue
                    PlayerLayoutStore.save(legacyLayoutData, for: activeLegacyStyle)
                }
            }
        )
    }

    private var lyricOffsetText: String {
        if lyricOffset == 0 { return "同步" }
        return lyricOffset > 0
            ? "提前 " + String(format: "%.1f", lyricOffset) + "s"
            : "延后 " + String(format: "%.1f", -lyricOffset) + "s"
    }

    private var glowLevelText: String {
        switch lyricGlowLevel {
        case 0: return "关闭"
        case 1: return "柔和"
        case 2: return "标准"
        default: return "强烈"
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color(UIColor.systemBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                // 1. 顶栏导航与播放器风格切换
                topNavigationBar
                styleSelectorBar
                buttonStyleSelectorBar

                Divider().overlay(Color.primary.opacity(0.08))

                // 2. 【上半区：吸顶固定微缩实时真机预览】（手指滑动下半区时始终固定可见，实现“边调边看”）
                stickyLivePreviewHeader
                    .padding(.vertical, 8)
                    .background(Color(UIColor.secondarySystemBackground).opacity(0.85))

                Divider().overlay(Color.primary.opacity(0.08))

                // 3. 【下半区：模块化多功能控制台】（独立滚动区）
                VStack(spacing: 0) {
                    controlTabBar
                        .padding(.top, 8)
                        .padding(.horizontal, 16)

                    ScrollView(showsIndicators: true) {
                        VStack(spacing: 14) {
                            switch editorTab {
                            case 0:
                                componentLayoutTab
                            case 1:
                                lyricsTypographyTab
                            case 2:
                                colorAndGlowTab
                            default:
                                presetAndResetTab
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .padding(.bottom, 40)
                    }
                }
            }
        }
        .onAppear {
            if activeStyle != .appleMusic {
                legacyLayoutData = PlayerLayoutStore.load(for: activeLegacyStyle)
            }
        }
        .task(id: player.currentSong?.identityKey) {
            await reloadRealLyrics()
        }
        .fullScreenCover(isPresented: $showLyricBackgroundPicker) {
            WallpaperPhotoPicker { data in
                if let path = LyricBackgroundStore.save(data) {
                    lyricBackgroundImagePath = path
                    ATMusicHaptics.success()
                    ToastCenter.shared.show("歌词背景已应用")
                } else {
                    ToastCenter.shared.show("歌词背景保存失败")
                }
            }
            .ignoresSafeArea()
        }
    }

    private func reloadRealLyrics() async {
        guard let song = player.currentSong else {
            realLyrics = []
            return
        }
        if player.currentLyricsSongIdentity == song.identityKey && !player.currentLyrics.isEmpty {
            realLyrics = player.currentLyrics
            return
        }
        let loaded = await SongLyricsLoader.loadLyrics(for: song)
        if !loaded.isEmpty {
            realLyrics = loaded
            player.updateCurrentLyrics(loaded, for: song.identityKey)
        }
    }

    // MARK: - 顶栏与播放器风格切换

    private var topNavigationBar: some View {
        HStack {
            Button("取消") {
                dismiss()
            }
            .font(ATMusicFont.appFont(15, .medium))
            .foregroundStyle(Color.atmusicComment)

            Spacer()

            Text("播放器与歌词编辑器")
                .font(ATMusicFont.appFont(16, .bold))
                .foregroundStyle(Color.atmusicLabel)

            Spacer()

            Button("完成") {
                ATMusicHaptics.success()
                dismiss()
            }
            .font(ATMusicFont.appFont(15, .bold))
            .foregroundStyle(Color.atmusicAmber)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private var styleSelectorBar: some View {
        HStack(spacing: 6) {
            ForEach(ATMusicCoverPlayerStyle.allCases, id: \.self) { style in
                let isSelected = coverPlayerStyleRaw == style.rawValue
                Button {
                    coverPlayerStyleRaw = style.rawValue
                    if style != .appleMusic {
                        legacyLayoutData = PlayerLayoutStore.load(for: activeLegacyStyle)
                    }
                    ATMusicHaptics.select()
                } label: {
                    Text(style.title)
                        .font(ATMusicFont.appFont(12, isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Color.white : Color.atmusicLabel)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(
                            isSelected ? Color.atmusicAmber : Color.primary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    /// 按钮样式选择：下方实时预览渲染的是真实播放器，切换即时可见
    /// 按钮样式选择：作用于当前选中的播放器样式（Apple Music 风格天生无圆圈，不显示）
    @ViewBuilder
    private var buttonStyleSelectorBar: some View {
        if activeStyle != .appleMusic {
            HStack(spacing: 6) {
                Text("\(activeStyle.title)按钮")
                    .font(ATMusicFont.appFont(12, .medium))
                    .foregroundStyle(Color.atmusicComment)
                    .padding(.leading, 16)
                    .layoutPriority(1)
                ForEach(ATMusicPlayerButtonStyle.allCases) { style in
                    let isSelected = activeButtonStyleRaw.wrappedValue == style.rawValue
                    Button {
                        activeButtonStyleRaw.wrappedValue = style.rawValue
                        ATMusicHaptics.select()
                    } label: {
                        Text(style.title)
                            .font(ATMusicFont.appFont(12, isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? Color.white : Color.atmusicLabel)
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                            .background(
                                isSelected ? Color.atmusicAmber : Color.primary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.trailing, 16)
            .padding(.bottom, 8)
        }
    }


    // MARK: - 【上半区：吸顶固定微缩实时真机预览】

    private var stickyLivePreviewHeader: some View {
        HStack(spacing: 16) {
            // 左侧：微缩真机模型（高度固定约 210 pt，保持完美 iPhone 比例）
            miniDeviceModel
                .frame(width: 98, height: 212)
                .shadow(color: Color.black.opacity(0.18), radius: 10, y: 5)

            // 右侧：预览控制面板与即时状态
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("实时预览联动")
                        .font(ATMusicFont.appFont(14, .bold))
                        .foregroundStyle(Color.atmusicLabel)
                    Text("拖动滑杆毫秒级刷新，直视真机效果")
                        .font(ATMusicFont.appFont(11))
                        .foregroundStyle(Color.atmusicComment)
                        .lineLimit(1)
                }

                // 封面页 / 歌词页 切换胶囊
                HStack(spacing: 4) {
                    previewModeButton(title: "封面页", mode: 0, icon: "photo.fill")
                    previewModeButton(title: "歌词页", mode: 1, icon: "quote.bubble.fill")
                }
                .padding(3)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                // 当前正在编辑的组件标签
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.atmusicAmber)
                    Text("正在调整: \(currentEditingPartName)")
                        .font(ATMusicFont.appFont(12, .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.atmusicAmber.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                // 快捷复位当前组件
                Button {
                    resetCurrentPart()
                    ATMusicHaptics.tap()
                    ToastCenter.shared.show("已复位「\(currentEditingPartName)」")
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 10, weight: .bold))
                        Text("复位当前组件")
                            .font(ATMusicFont.appFont(11, .medium))
                    }
                    .foregroundStyle(Color.atmusicComment)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .frame(height: 226)
    }

    private func previewModeButton(title: String, mode: Int, icon: String) -> some View {
        Button {
            previewMode = mode
            ATMusicHaptics.select()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10))
                Text(title).font(ATMusicFont.appFont(12, previewMode == mode ? .semibold : .medium))
            }
            .foregroundStyle(previewMode == mode ? Color.white : Color.atmusicLabel)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(previewMode == mode ? Color.atmusicAmber : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var currentEditingPartName: String {
        if editorTab == 1 { return "歌词排版" }
        if editorTab == 2 { return "色彩与发光" }
        if activeStyle == .appleMusic {
            return selectedApplePart.rawValue
        } else {
            return selectedLegacyPart.rawValue
        }
    }

    // MARK: - 微缩真机模型视图

    private var miniDeviceModel: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let corner = w * 0.16

            ZStack {
                // 金属机身边框
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.gray.opacity(0.7), Color.black, Color.gray.opacity(0.8)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                // 黑色边框
                RoundedRectangle(cornerRadius: corner - 1.5, style: .continuous)
                    .fill(Color.black)
                    .padding(1.5)

                // 真机屏幕（内部等比缩放渲染真实播放器）
                ZStack {
                    livePlayerContentView
                }
                .clipShape(RoundedRectangle(cornerRadius: corner - 3, style: .continuous))
                .padding(3)

                // 灵动岛小装饰
                Capsule()
                    .fill(Color.black)
                    .frame(width: w * 0.32, height: 6.5)
                    .offset(y: -h / 2 + 7.5)
            }
        }
    }

    @ViewBuilder
    private var livePlayerContentView: some View {
        let bounds = ATMusicDisplayMetrics.bounds
        let designWidth = bounds.width
        let designHeight = bounds.height
        let scale = 92.0 / designWidth

        GeometryReader { geometry in
            ZStack {
                if activeStyle == .appleMusic {
                    ReferencePlaybackView(
                        song: previewSong,
                        lyrics: effectiveLyrics,
                        showLyrics: Binding(get: { previewMode == 1 }, set: { _ in }),
                        onFavorite: {},
                        onQueue: {},
                        onComments: {},
                        onSleepTimer: {},
                        onAddToLocalPlaylist: {},
                        onDownload: {},
                        onPlayerSettings: {},
                        onSearchLyrics: {},
                        onSongInfo: {},
                        onLyricsSync: {}
                    )
                } else if activeStyle == .immersive {
                    ImmersivePlayerView(
                        song: previewSong,
                        lyrics: effectiveLyrics,
                        isPresented: .constant(true),
                        previewShowLyrics: previewMode == 1,
                        onOpenSettings: {},
                        onSleepTimer: {},
                        onSongInfo: {},
                        onSearchLyrics: {},
                        onAddToLocalPlaylist: {},
                        onDownload: {}
                    )
                } else {
                    PlayerView(
                        isPresented: .constant(true),
                        previewShowLyrics: previewMode == 1
                    )
                }
            }
            .environmentObject(theme)
            .environmentObject(player)
            .environmentObject(clock)
            .environmentObject(auth)
            .environmentObject(favorites)
            .environment(\.colorScheme, .dark)
            .frame(width: designWidth, height: designHeight)
            .scaleEffect(scale, anchor: .center)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .allowsHitTesting(false)
        }
    }

    private var previewSong: Song {
        player.currentSong ?? Song(
            id: 1999001,
            name: "七里香",
            artists: "周杰伦",
            album: "七里香",
            coverURL: URL(string: "https://p1.music.126.net/14nQjLlh9u5-m-Ld9D-Uwg==/109951165434190875.jpg"),
            duration: 299,
            source: .netease
        )
    }

    /// 实时联动歌词：
    /// 1. 优先使用当前播放曲目已加载的真实歌词；
    /// 2. 若未播放或歌曲无歌词，基于当前播放进度动态生成模拟歌词，保证高亮行与实际时间戳完美契合。
    private var effectiveLyrics: [LyricLine] {
        if !realLyrics.isEmpty {
            return realLyrics
        }
        if player.currentLyricsSongIdentity == previewSong.identityKey && !player.currentLyrics.isEmpty {
            return player.currentLyrics
        }
        let baseTime = clock.progress
        let title = previewSong.name
        let artist = previewSong.artists
        return [
            LyricLine(time: max(0, baseTime - 12), text: "\(title) - \(artist)", translation: "Current Track"),
            LyricLine(time: max(0, baseTime - 6), text: "正在实时播放此曲目", translation: "Now Playing Live Preview"),
            LyricLine(time: baseTime, text: "歌词排版与发光色彩实时调试中", translation: "Typography and glow effects adjusting"),
            LyricLine(time: baseTime + 6, text: "所见即所得，毫秒级真机渲染", translation: "WYSIWYG real-time rendering"),
            LyricLine(time: baseTime + 12, text: "纯粹沉浸，尽享动听旋律", translation: "Enjoy the beautiful melody")
        ]
    }

    // MARK: - 控制台 Tab 切换栏

    private var controlTabBar: some View {
        HStack(spacing: 8) {
            tabButton(title: "组件布局", index: 0, icon: "square.dashed")
            tabButton(title: "歌词排版", index: 1, icon: "textformat")
            tabButton(title: "色彩发光", index: 2, icon: "paintpalette.fill")
            tabButton(title: "预设重置", index: 3, icon: "arrow.counterclockwise")
        }
    }

    private func tabButton(title: String, index: Int, icon: String) -> some View {
        Button {
            editorTab = index
            if index == 1 || index == 2 {
                // 歌词排版或色彩发光Tab：自动切到歌词页预览，边调边看
                previewMode = 1
            } else if index == 0 {
                if (activeStyle == .appleMusic && selectedApplePart == .previewLyric) ||
                   (activeStyle != .appleMusic && selectedLegacyPart == .lyric) {
                    previewMode = 1
                } else {
                    previewMode = 0
                }
            }
            ATMusicHaptics.select()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 11))
                Text(title).font(ATMusicFont.appFont(12, editorTab == index ? .semibold : .medium))
            }
            .foregroundStyle(editorTab == index ? Color.atmusicAmber : Color.atmusicComment)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(editorTab == index ? Color.atmusicAmber.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tab 0: 组件布局微调 (位置与尺寸)

    private var componentLayoutTab: some View {
        VStack(spacing: 12) {
            // 组件选择器
            VStack(alignment: .leading, spacing: 8) {
                Text("选择要微调的组件")
                    .font(ATMusicFont.appFont(13, .semibold))
                    .foregroundStyle(Color.atmusicLabel)

                if activeStyle == .appleMusic {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(AppleMusicLayoutPart.allCases) { part in
                                componentPill(name: part.rawValue, isSelected: selectedApplePart == part) {
                                    selectedApplePart = part
                                    if part == .previewLyric {
                                        previewMode = 1
                                    } else {
                                        previewMode = 0
                                    }
                                }
                            }
                        }
                    }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(visibleLegacyParts) { part in
                                componentPill(name: part.rawValue, isSelected: selectedLegacyPart == part) {
                                    selectedLegacyPart = part
                                    if part == .lyric {
                                        previewMode = 1
                                    } else {
                                        previewMode = 0
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(14)
            .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 16, style: .continuous)) }

            // 底部指示线（从播放器设置页迁移）
            VStack(alignment: .leading, spacing: 8) {
                Toggle("显示底部指示线", isOn: $deckGrabberEnabled)
                    .font(ATMusicFont.appFont(14, .medium))
                    .tint(Color.atmusicAmber)
                Text("关闭后隐藏指示线，仍可上滑呼出评论区")
                    .font(ATMusicFont.appFont(11))
                    .foregroundStyle(Color.atmusicComment)
            }
            .padding(14)
            .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 16, style: .continuous)) }

            // X/Y 偏移、Scale、Rotation、Opacity 滑杆控制板
            VStack(spacing: 10) {
                sliderRow(title: "水平 X", value: selectedEntry.x, range: -180...180, format: "%.0f pt") {
                    selectedEntry.wrappedValue.x = 0
                }
                sliderRow(title: "垂直 Y", value: selectedEntry.y, range: -260...260, format: "%.0f pt") {
                    selectedEntry.wrappedValue.y = 0
                }
                sliderRow(title: "大小缩放", value: selectedEntry.scale, range: 0.3...1.8, step: 0.05, format: "%.2fx") {
                    selectedEntry.wrappedValue.scale = 1.0
                }
                sliderRow(title: "旋转角度", value: selectedEntry.rotation, range: -180...180, format: "%.0f°") {
                    selectedEntry.wrappedValue.rotation = 0
                }
                sliderRow(title: "透明度", value: selectedEntry.opacity, range: 0...1, step: 0.05, format: "%.0f%%", multiplier: 100) {
                    selectedEntry.wrappedValue.opacity = 1.0
                }
            }
            .padding(14)
            .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 16, style: .continuous)) }
        }
    }

    private func componentPill(name: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            ATMusicHaptics.select()
        } label: {
            Text(name)
                .font(ATMusicFont.appFont(12, isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Color.white : Color.atmusicLabel)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(isSelected ? Color.atmusicAmber : Color.primary.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func sliderRow(
        title: String,
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>,
        step: CGFloat = 1,
        format: String,
        multiplier: CGFloat = 1,
        onReset: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                    .font(ATMusicFont.appFont(13, .medium))
                    .foregroundStyle(Color.atmusicLabel)
                Spacer()
                Text(String(format: format, value.wrappedValue * multiplier))
                    .font(ATMusicFont.appFont(12, .semibold, .monospaced))
                    .foregroundStyle(Color.atmusicAmber)
                Button("重置") {
                    onReset()
                    ATMusicHaptics.select()
                }
                .font(ATMusicFont.appFont(11))
                .foregroundStyle(Color.atmusicComment)
            }
            Slider(value: value, in: range, step: step)
                .tint(Color.atmusicAmber)
        }
    }

    // MARK: - Tab 1: 歌词排版定制 (四套播放器专属联动)

    private var lyricsTypographyTab: some View {
        VStack(spacing: 12) {
            VStack(spacing: 14) {
                Toggle("显示双语翻译", isOn: $lyricTranslation)
                    .font(ATMusicFont.appFont(14, .medium))
                    .tint(Color.atmusicAmber)

                Divider().overlay(Color.atmusicComment.opacity(0.12))

                // 字号大小
                VStack(spacing: 4) {
                    HStack {
                        Text("默认歌词字号")
                            .font(ATMusicFont.appFont(13, .medium))
                            .foregroundStyle(Color.atmusicLabel)
                        Spacer()
                        Text("\(lyricFontSize) pt")
                            .font(ATMusicFont.appFont(12, .semibold, .monospaced))
                            .foregroundStyle(Color.atmusicAmber)
                    }
                    Slider(value: Binding(
                        get: { Double(lyricFontSize) },
                        set: { lyricFontSize = Int($0) }
                    ), in: 12...32, step: 1)
                    .tint(Color.atmusicAmber)
                }

                Divider().overlay(Color.atmusicComment.opacity(0.12))

                // 行间距
                VStack(spacing: 4) {
                    HStack {
                        Text("歌词行间距")
                            .font(ATMusicFont.appFont(13, .medium))
                            .foregroundStyle(Color.atmusicLabel)
                        Spacer()
                        Text("\(lyricLineSpacing) pt")
                            .font(ATMusicFont.appFont(12, .semibold, .monospaced))
                            .foregroundStyle(Color.atmusicAmber)
                    }
                    Slider(value: Binding(
                        get: { Double(lyricLineSpacing) },
                        set: { lyricLineSpacing = Int($0) }
                    ), in: 0...40, step: 2)
                    .tint(Color.atmusicAmber)
                }

                Divider().overlay(Color.atmusicComment.opacity(0.12))

                // 对齐方式
                HStack {
                    Text("歌词对齐方式")
                        .font(ATMusicFont.appFont(13, .medium))
                        .foregroundStyle(Color.atmusicLabel)
                    Spacer()
                    Picker("对齐", selection: $lyricAlignRaw) {
                        Text("居中对齐").tag("center")
                        Text("靠左对齐").tag("left")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 140)
                }

                Divider().overlay(Color.atmusicComment.opacity(0.12))

                // 3D 景深倾斜
                VStack(spacing: 4) {
                    HStack {
                        Text("3D 空间立体景深倾斜")
                            .font(ATMusicFont.appFont(13, .medium))
                            .foregroundStyle(Color.atmusicLabel)
                        Spacer()
                        Text("\(lyricTilt)°")
                            .font(ATMusicFont.appFont(12, .semibold, .monospaced))
                            .foregroundStyle(Color.atmusicAmber)
                    }
                    Slider(value: Binding(
                        get: { Double(lyricTilt) },
                        set: { lyricTilt = Int($0) }
                    ), in: 0...45, step: 1)
                    .tint(Color.atmusicAmber)
                }

                Divider().overlay(Color.atmusicComment.opacity(0.12))

                // 模糊起始距离（从播放器设置页迁移）
                VStack(spacing: 4) {
                    HStack {
                        Text("模糊起始距离")
                            .font(ATMusicFont.appFont(13, .medium))
                            .foregroundStyle(Color.atmusicLabel)
                        Spacer()
                        Text("\(lyricBlurStart) 行")
                            .font(ATMusicFont.appFont(12, .semibold, .monospaced))
                            .foregroundStyle(Color.atmusicAmber)
                    }
                    Slider(value: Binding(
                        get: { Double(lyricBlurStart) },
                        set: { lyricBlurStart = Int($0) }
                    ), in: 0...4, step: 1)
                    .tint(Color.atmusicAmber)
                }

                Divider().overlay(Color.atmusicComment.opacity(0.12))

                // 左右倾斜（从播放器设置页迁移）
                VStack(spacing: 4) {
                    HStack {
                        Text("左右倾斜")
                            .font(ATMusicFont.appFont(13, .medium))
                            .foregroundStyle(Color.atmusicLabel)
                        Spacer()
                        Text(tiltYText)
                            .font(ATMusicFont.appFont(12, .semibold, .monospaced))
                            .foregroundStyle(Color.atmusicAmber)
                    }
                    Slider(value: Binding(
                        get: { Double(lyricTiltY) },
                        set: { lyricTiltY = Int($0) }
                    ), in: -45...45, step: 1)
                    .tint(Color.atmusicAmber)
                }

                Divider().overlay(Color.atmusicComment.opacity(0.12))

                // 歌词同步时间偏移校准
                VStack(spacing: 4) {
                    HStack {
                        Text("歌词默认偏移（全局）")
                            .font(ATMusicFont.appFont(13, .medium))
                            .foregroundStyle(Color.atmusicLabel)
                        Spacer()
                        Text(lyricOffsetText)
                            .font(ATMusicFont.appFont(12, .semibold, .monospaced))
                            .foregroundStyle(Color.atmusicAmber)
                        Button("归零") {
                            lyricOffset = 0
                            ATMusicHaptics.select()
                        }
                        .font(ATMusicFont.appFont(11))
                        .foregroundStyle(Color.atmusicComment)
                    }
                    Slider(value: $lyricOffset, in: -3.0...3.0, step: 0.1)
                        .tint(Color.atmusicAmber)
                    Text("逐曲校准请在播放页「更多 → 歌词同步校准」里做：单曲偏移优先于这里的默认值，并可一键烘焙写回文件。")
                        .font(ATMusicFont.appFont(10))
                        .foregroundStyle(Color.atmusicComment.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 16, style: .continuous)) }
        }
    }

    // MARK: - Tab 2: 色彩、发光与视觉渲染

    private var colorAndGlowTab: some View {
        VStack(spacing: 12) {
            VStack(spacing: 14) {
                // 1. 歌词色彩调整区（根据播放器风格自动适配对应调色盘）
                // 1. 歌词色彩调整区（所有播放器统一支持：跟随封面主色 vs 自定义颜色）
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("高亮歌词颜色模式")
                            .font(ATMusicFont.appFont(13, .medium))
                            .foregroundStyle(Color.atmusicLabel)
                        Spacer()
                        Picker("模式", selection: $lyricGradMode) {
                            Text("跟随封面主色").tag(0)
                            Text("自定义颜色").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 170)
                    }

                    if lyricGradMode == 1 {
                        HStack {
                            Text("当前高亮行歌词颜色")
                                .font(ATMusicFont.appFont(13, .medium))
                                .foregroundStyle(Color.atmusicLabel)
                            Spacer()
                            Button("重置") {
                                lyricColorRaw = "accent"
                                ATMusicHaptics.select()
                            }
                            .font(ATMusicFont.appFont(11))
                            .foregroundStyle(Color.atmusicComment)
                            ColorPicker("", selection: Binding(
                                get: {
                                    if let c = Color(hex: lyricColorRaw) { return c }
                                    return Color.atmusicAmber
                                },
                                set: { lyricColorRaw = $0.hexString }
                            ), supportsOpacity: false)
                            .labelsHidden()
                        }

                        HStack {
                            Text("常规未播放歌词颜色")
                                .font(ATMusicFont.appFont(13, .medium))
                                .foregroundStyle(Color.atmusicLabel)
                            Spacer()
                            Button("重置") {
                                lyricDimColorRaw = "dim"
                                ATMusicHaptics.select()
                            }
                            .font(ATMusicFont.appFont(11))
                            .foregroundStyle(Color.atmusicComment)
                            ColorPicker("", selection: Binding(
                                get: {
                                    if let c = Color(hex: lyricDimColorRaw) { return c }
                                    return Color.gray.opacity(0.85)
                                },
                                set: { lyricDimColorRaw = $0.hexString }
                            ), supportsOpacity: false)
                            .labelsHidden()
                        }
                    } else {
                        Text("当前已启用智能取色：自动随歌曲封面主色调渲染高亮行，带来最佳沉浸感。")
                            .font(ATMusicFont.appFont(11))
                            .foregroundStyle(Color.atmusicComment)
                    }

                    if activeStyle == .appleMusic {
                        Divider().overlay(Color.atmusicComment.opacity(0.12))

                        Toggle("显示音量条", isOn: $showVolume).tint(Color.atmusicAmber).font(ATMusicFont.appFont(13, .medium))
                        Toggle("显示封面页歌词预览", isOn: $showLyricPreview).tint(Color.atmusicAmber).font(ATMusicFont.appFont(13, .medium))
                        Toggle("同步主页壁纸", isOn: $syncWallpaper).tint(Color.atmusicAmber).font(ATMusicFont.appFont(13, .medium))
                    }
                }

                Divider().overlay(Color.atmusicComment.opacity(0.12))

                // 2. 歌词发光与光晕渲染（四套播放器通用生效）
                VStack(spacing: 4) {
                    HStack {
                        Text("歌词双层辉光发光强度")
                            .font(ATMusicFont.appFont(13, .medium))
                            .foregroundStyle(Color.atmusicLabel)
                        Spacer()
                        Text(glowLevelText)
                            .font(ATMusicFont.appFont(12, .semibold))
                            .foregroundStyle(Color.atmusicAmber)
                    }
                    Slider(value: Binding(
                        get: { Double(lyricGlowLevel) },
                        set: { lyricGlowLevel = Int($0) }
                    ), in: 0...4, step: 1)
                    .tint(Color.atmusicAmber)
                }

                // 自定义发光光晕取色
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("双层发光光晕取色")
                            .font(ATMusicFont.appFont(13, .medium))
                            .foregroundStyle(Color.atmusicLabel)
                        Text(lyricGlowColorRaw.isEmpty ? "默认跟随当前高亮歌词色" : "已自定义发光光晕")
                            .font(ATMusicFont.appFont(11))
                            .foregroundStyle(Color.atmusicComment)
                    }
                    Spacer()
                    if !lyricGlowColorRaw.isEmpty {
                        Button("恢复默认") {
                            lyricGlowColorRaw = ""
                            ATMusicHaptics.select()
                        }
                        .font(ATMusicFont.appFont(11))
                        .foregroundStyle(Color.atmusicComment)
                    }
                    ColorPicker("", selection: Binding(
                        get: {
                            if let c = Color(hex: lyricGlowColorRaw) { return c }
                            return Color.atmusicAmber
                        },
                        set: { lyricGlowColorRaw = $0.hexString }
                    ), supportsOpacity: false)
                    .labelsHidden()
                }

                Divider().overlay(Color.atmusicComment.opacity(0.12))

                // 3. 非当前行高斯虚化模糊（四套播放器通用生效）
                VStack(spacing: 4) {
                    HStack {
                        Text("非当前行高斯虚化度")
                            .font(ATMusicFont.appFont(13, .medium))
                            .foregroundStyle(Color.atmusicLabel)
                        Spacer()
                        Text(String(format: "%.1f", lyricBlurAmount))
                            .font(ATMusicFont.appFont(12, .semibold, .monospaced))
                            .foregroundStyle(Color.atmusicAmber)
                    }
                    Slider(value: $lyricBlurAmount, in: 0...3.0, step: 0.1)
                        .tint(Color.atmusicAmber)
                }

                Divider().overlay(Color.atmusicComment.opacity(0.12))

                // 4. 自定义渐变色（从播放器设置页迁移；开启自定义配色后生效）
                if lyricGradMode == 1 {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("自定义渐变色")
                            .font(ATMusicFont.appFont(13, .semibold))
                            .foregroundStyle(Color.atmusicLabel)
                        HStack {
                            Text("渐变起始色")
                                .font(ATMusicFont.appFont(13, .medium))
                                .foregroundStyle(Color.atmusicLabel)
                            Spacer()
                            ColorPicker("", selection: gradStart, supportsOpacity: false)
                                .labelsHidden()
                        }
                        HStack {
                            Text("渐变结束色")
                                .font(ATMusicFont.appFont(13, .medium))
                                .foregroundStyle(Color.atmusicLabel)
                            Spacer()
                            ColorPicker("", selection: gradEnd, supportsOpacity: false)
                                .labelsHidden()
                        }
                    }

                    Divider().overlay(Color.atmusicComment.opacity(0.12))
                }

                // 5. 歌词背景（从播放器设置页迁移）
                VStack(alignment: .leading, spacing: 8) {
                    Text("歌词背景")
                        .font(ATMusicFont.appFont(13, .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("歌词界面背景图")
                                .font(ATMusicFont.appFont(13, .medium))
                                .foregroundStyle(Color.atmusicLabel)
                            Text(lyricBackgroundImagePath.isEmpty ? "未设置" : "已使用自定义图片")
                                .font(ATMusicFont.appFont(11))
                                .foregroundStyle(Color.atmusicComment)
                        }
                        Spacer()
                        Button("上传") {
                            showLyricBackgroundPicker = true
                            ATMusicHaptics.tap()
                        }
                        .font(ATMusicFont.appFont(12, .semibold))
                        .foregroundStyle(Color.atmusicAmber)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background { ATMusicSurface(shape: Capsule()) }
                        .buttonStyle(.plain)
                        if !lyricBackgroundImagePath.isEmpty {
                            Button("清除") {
                                LyricBackgroundStore.clear()
                                lyricBackgroundImagePath = ""
                                ATMusicHaptics.select()
                            }
                            .font(ATMusicFont.appFont(12, .semibold))
                            .foregroundStyle(Color.red)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background { ATMusicSurface(shape: Capsule()) }
                            .buttonStyle(.plain)
                        }
                    }
                    if !lyricBackgroundImagePath.isEmpty {
                        VStack(spacing: 4) {
                            HStack {
                                Text("背景模糊")
                                    .font(ATMusicFont.appFont(13, .medium))
                                    .foregroundStyle(Color.atmusicLabel)
                                Spacer()
                                Text("\(Int(lyricBackgroundBlur))")
                                    .font(ATMusicFont.appFont(12, .semibold, .monospaced))
                                    .foregroundStyle(Color.atmusicAmber)
                            }
                            Slider(value: $lyricBackgroundBlur, in: 0...30, step: 1)
                                .tint(Color.atmusicAmber)
                        }
                        Toggle("同步到封面页背景", isOn: $lyricBackgroundSyncCover)
                            .font(ATMusicFont.appFont(13, .medium))
                            .tint(Color.atmusicAmber)
                        Text("开启后播放器封面界面也使用这张自定义背景")
                            .font(ATMusicFont.appFont(11))
                            .foregroundStyle(Color.atmusicComment)
                    }
                }

                Divider().overlay(Color.atmusicComment.opacity(0.12))

                // 6. 封面文字（从播放器设置页迁移）
                VStack(alignment: .leading, spacing: 8) {
                    Text("封面文字")
                        .font(ATMusicFont.appFont(13, .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                    Toggle("文字渐变", isOn: $albumTextGradient)
                        .font(ATMusicFont.appFont(13, .medium))
                        .tint(Color.atmusicAmber)
                    Toggle("文字高光", isOn: $albumTextGlow)
                        .font(ATMusicFont.appFont(13, .medium))
                        .tint(Color.atmusicAmber)
                    if albumTextGlow {
                        VStack(spacing: 4) {
                            HStack {
                                Text("高光强度")
                                    .font(ATMusicFont.appFont(13, .medium))
                                    .foregroundStyle(Color.atmusicLabel)
                                Spacer()
                                Text("\(Int((albumTextGlowIntensity * 100).rounded()))%")
                                    .font(ATMusicFont.appFont(12, .semibold, .monospaced))
                                    .foregroundStyle(Color.atmusicAmber)
                            }
                            Slider(value: $albumTextGlowIntensity, in: 0.2...2.0, step: 0.05)
                                .tint(Color.atmusicAmber)
                        }
                    }
                    HStack {
                        Text("歌名颜色")
                            .font(ATMusicFont.appFont(13, .medium))
                            .foregroundStyle(Color.atmusicLabel)
                        Spacer()
                        ColorPicker("", selection: coverTextColor(hex: $albumTitleColorHex, fallback: Color.atmusicLabel), supportsOpacity: false)
                            .labelsHidden()
                    }
                    HStack {
                        Text("歌手颜色")
                            .font(ATMusicFont.appFont(13, .medium))
                            .foregroundStyle(Color.atmusicLabel)
                        Spacer()
                        ColorPicker("", selection: coverTextColor(hex: $albumArtistColorHex, fallback: Color.atmusicLabel.opacity(0.7)), supportsOpacity: false)
                            .labelsHidden()
                    }
                    HStack {
                        Text("预览歌词颜色")
                            .font(ATMusicFont.appFont(13, .medium))
                            .foregroundStyle(Color.atmusicLabel)
                        Spacer()
                        ColorPicker("", selection: coverTextColor(hex: $albumPreviewLyricColorHex, fallback: Color.atmusicLabel), supportsOpacity: false)
                            .labelsHidden()
                    }
                    HStack {
                        Text("预览未播放颜色")
                            .font(ATMusicFont.appFont(13, .medium))
                            .foregroundStyle(Color.atmusicLabel)
                        Spacer()
                        ColorPicker("", selection: coverTextColor(hex: $albumPreviewDimColorHex, fallback: Color.atmusicLabel.opacity(0.5)), supportsOpacity: false)
                            .labelsHidden()
                    }
                    Button("恢复封面文字默认") {
                        albumTitleColorHex = ""
                        albumArtistColorHex = ""
                        albumPreviewLyricColorHex = ""
                        albumPreviewDimColorHex = ""
                        albumTextGradient = false
                        albumTextGlow = false
                        albumTextGlowIntensity = 1.0
                        ATMusicHaptics.select()
                    }
                    .font(ATMusicFont.appFont(12, .semibold))
                    .foregroundStyle(Color.atmusicAmber)
                }

                Divider().overlay(Color.atmusicComment.opacity(0.12))

                // 7. 播放器控件（从播放器设置页迁移）
                VStack(alignment: .leading, spacing: 8) {
                    Text("播放器控件")
                        .font(ATMusicFont.appFont(13, .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                    Toggle("控件跟随封面取色", isOn: $controlsUseCoverColor)
                        .font(ATMusicFont.appFont(13, .medium))
                        .tint(Color.atmusicAmber)
                    Text("关闭后使用全局主题色")
                        .font(ATMusicFont.appFont(11))
                        .foregroundStyle(Color.atmusicComment)
                    HStack {
                        Text("主图标颜色")
                            .font(ATMusicFont.appFont(13, .medium))
                            .foregroundStyle(Color.atmusicLabel)
                        Spacer()
                        ColorPicker("", selection: playerMainIconColor, supportsOpacity: false)
                            .labelsHidden()
                    }
                    HStack {
                        Text("次级图标颜色")
                            .font(ATMusicFont.appFont(13, .medium))
                            .foregroundStyle(Color.atmusicLabel)
                        Spacer()
                        ColorPicker("", selection: playerSecondaryIconColor, supportsOpacity: false)
                            .labelsHidden()
                    }
                    HStack {
                        Text("播放按钮强调色")
                            .font(ATMusicFont.appFont(13, .medium))
                            .foregroundStyle(Color.atmusicLabel)
                        Spacer()
                        ColorPicker("", selection: playerPrimaryButtonColor, supportsOpacity: false)
                            .labelsHidden()
                    }
                    Button("恢复控件颜色默认") {
                        playerMainIconColorHex = ""
                        playerSecondaryIconColorHex = ""
                        playerPrimaryButtonColorHex = ""
                        ATMusicHaptics.select()
                    }
                    .font(ATMusicFont.appFont(12, .semibold))
                    .foregroundStyle(Color.atmusicAmber)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("进度条颜色")
                                .font(ATMusicFont.appFont(13, .medium))
                                .foregroundStyle(Color.atmusicLabel)
                            Text(progressAccentHex.isEmpty ? "跟随播放控件" : "自定义")
                                .font(ATMusicFont.appFont(11))
                                .foregroundStyle(Color.atmusicComment)
                        }
                        Spacer()
                        ColorPicker("", selection: progressAccentColor)
                            .labelsHidden()
                        Button("跟随") {
                            progressAccentHex = ""
                            ATMusicHaptics.select()
                        }
                        .font(ATMusicFont.appFont(12, .semibold))
                        .foregroundStyle(Color.atmusicAmber)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.atmusicAmber.opacity(0.12), in: Capsule())
                        .buttonStyle(.plain)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("进度条样式")
                            .font(ATMusicFont.appFont(13, .medium))
                            .foregroundStyle(Color.atmusicLabel)
                        progressStyleGrid
                    }
                }

                Divider().overlay(Color.atmusicComment.opacity(0.12))

                // 8. 背景光晕 / 浮尘 / DJ 光效（从播放器设置页迁移）
                VStack(alignment: .leading, spacing: 8) {
                    Text("氛围光效")
                        .font(ATMusicFont.appFont(13, .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                    VStack(spacing: 4) {
                        HStack {
                            Text("背景光晕强度")
                                .font(ATMusicFont.appFont(13, .medium))
                                .foregroundStyle(Color.atmusicLabel)
                            Spacer()
                            Text("\(Int((breath * 100).rounded()))%")
                                .font(ATMusicFont.appFont(12, .semibold, .monospaced))
                                .foregroundStyle(Color.atmusicAmber)
                        }
                        Slider(value: $breath, in: 0...1, step: 0.05)
                            .tint(Color.atmusicAmber)
                    }
                    dustModeSelector
                    if playerDustModeRaw == ATMusicPlayerDustMode.snow.rawValue {
                        VStack(spacing: 4) {
                            HStack {
                                Text("浮尘密度")
                                    .font(ATMusicFont.appFont(13, .medium))
                                    .foregroundStyle(Color.atmusicLabel)
                                Spacer()
                                Text(String(format: "%.1fx", playerDustDensity))
                                    .font(ATMusicFont.appFont(12, .semibold, .monospaced))
                                    .foregroundStyle(Color.atmusicAmber)
                            }
                            Slider(value: $playerDustDensity, in: 0.4...2.6, step: 0.1)
                                .tint(Color.atmusicAmber)
                        }
                        VStack(spacing: 4) {
                            HStack {
                                Text("浮尘大小")
                                    .font(ATMusicFont.appFont(13, .medium))
                                    .foregroundStyle(Color.atmusicLabel)
                                Spacer()
                                Text(String(format: "%.1fx", playerDustSize))
                                    .font(ATMusicFont.appFont(12, .semibold, .monospaced))
                                    .foregroundStyle(Color.atmusicAmber)
                            }
                            Slider(value: $playerDustSize, in: 0.8...2.8, step: 0.1)
                                .tint(Color.atmusicAmber)
                        }
                    }
                    Toggle("DJ 节奏脉冲光效", isOn: $djVisualEnabled)
                        .font(ATMusicFont.appFont(13, .medium))
                        .tint(Color.atmusicAmber)
                    Text("封面背后随节拍扩散光环")
                        .font(ATMusicFont.appFont(11))
                        .foregroundStyle(Color.atmusicComment)
                    if djVisualEnabled {
                        VStack(spacing: 4) {
                            HStack {
                                Text("光效强度")
                                    .font(ATMusicFont.appFont(13, .medium))
                                    .foregroundStyle(Color.atmusicLabel)
                                Spacer()
                                Text("\(Int((djVisualIntensity * 100).rounded()))%")
                                    .font(ATMusicFont.appFont(12, .semibold, .monospaced))
                                    .foregroundStyle(Color.atmusicAmber)
                            }
                            Slider(value: $djVisualIntensity, in: 0...1, step: 0.05)
                                .tint(Color.atmusicAmber)
                        }
                    }
                }

                Divider().overlay(Color.atmusicComment.opacity(0.12))

                // 9. 一键恢复默认配色
                Button {
                    lyricGradMode = 0
                    lyricColorRaw = "accent"
                    lyricDimColorRaw = "dim"
                    lyricGlowColorRaw = ""
                    lyricGlowLevel = 1
                    lyricBlurAmount = 1.1
                    primaryHex = ""
                    secondaryHex = ""
                    accentHex = ""
                    volumeHex = ""
                    ATMusicHaptics.success()
                    ToastCenter.shared.show("已重置为默认配色")
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.counterclockwise.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                        Text("恢复默认配色方案")
                            .font(ATMusicFont.appFont(13, .semibold))
                    }
                    .foregroundStyle(Color.atmusicAmber)
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(Color.atmusicAmber.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 16, style: .continuous)) }
        }
    }


    // MARK: - Tab 3: 预设与重置

    private var presetAndResetTab: some View {
        VStack(spacing: 12) {
            Button {
                resetCurrentPart()
                ATMusicHaptics.success()
                ToastCenter.shared.show("已恢复当前组件默认")
            } label: {
                HStack {
                    Image(systemName: "arrow.counterclockwise")
                    Text("恢复当前组件为默认参数")
                    Spacer()
                }
                .font(ATMusicFont.appFont(14, .semibold))
                .foregroundStyle(Color.atmusicLabel)
                .padding(14)
                .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 14, style: .continuous)) }
            }
            .buttonStyle(.plain)

            Button {
                resetCurrentStyleLayout()
                ATMusicHaptics.success()
                ToastCenter.shared.show("已重置「\(activeStyle.title)」布局为初始状态")
            } label: {
                HStack {
                    Image(systemName: "trash")
                    Text("重置当前播放器为初始默认布局")
                    Spacer()
                }
                .font(ATMusicFont.appFont(14, .semibold))
                .foregroundStyle(Color.red)
                .padding(14)
                .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 14, style: .continuous)) }
            }
            .buttonStyle(.plain)
        }
    }

    private var visibleLegacyParts: [PlayerLayoutPart] {
        switch activeStyle {
        case .vinyl:
            return [.vinylAlbum, .title, .vinylLyricsHeader, .vinylLyricsText, .progress, .controls, .queue]
        case .classic:
            return [.topBack, .topTitle, .topFavorite, .cover, .title, .previewLyric, .progress, .previous, .playPause, .next, .queue, .grabber]
        case .appleMusic:
            return []
        case .immersive:
            if previewMode == 0 {
                return [.cover, .title, .progress, .controls, .loop, .previous, .playPause, .next, .queue]
            } else {
                return [.topTitle, .lyric, .progress, .controls, .loop, .previous, .playPause, .next, .queue]
            }
        }
    }

    private func resetCurrentPart() {
        if activeStyle == .appleMusic {
            appleLayout.reset(selectedApplePart)
        } else {
            legacyLayoutData[selectedLegacyPart.rawValue] = PlayerLayoutStore.defaultEntry(for: selectedLegacyPart, style: activeLegacyStyle)
            PlayerLayoutStore.save(legacyLayoutData, for: activeLegacyStyle)
        }
    }

    private func resetCurrentStyleLayout() {
        if activeStyle == .appleMusic {
            appleLayout.resetAll()
        } else {
            legacyLayoutData = [:]
            PlayerLayoutStore.reset(for: activeLegacyStyle)
        }
    }
}
