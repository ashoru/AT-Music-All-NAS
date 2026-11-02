import SwiftUI

// MARK: - 适配 4 种全局 UI 样式的设置卡片容器

struct SettingsSectionCard<Content: View>: View {
    @AppStorage("atmusic.uiStyle") private var uiStyleRaw = ATMusicUIStyle.liquid.rawValue
    let title: String
    @ViewBuilder let content: () -> Content

    private var uiStyle: ATMusicUIStyle {
        uiStyleRaw == "outline" ? .clear : (ATMusicUIStyle(rawValue: uiStyleRaw) ?? .liquid)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(ATMusicFont.appFont(14, .semibold))
                .foregroundStyle(Color.atmusicComment)
                .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .background {
                cardBackground
            }
            .clipShape(cardShape)
        }
    }

    private var cardCornerRadius: CGFloat {
        switch uiStyle {
        case .compact: return 14
        case .nativeClean: return 18
        case .clear: return 18
        case .liquid: return 22
        }
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
    }

    @ViewBuilder
    private var cardBackground: some View {
        switch uiStyle {
        case .nativeClean:
            ATMusicGlass(shape: cardShape)
        case .compact:
            ATMusicGlass(shape: cardShape)
                .overlay {
                    cardShape.stroke(Color.primary.opacity(0.08), lineWidth: 0.6)
                }
        case .clear:
            ATMusicGlass(shape: cardShape)
                .overlay {
                    cardShape.stroke(Color.white.opacity(0.16), lineWidth: 0.8)
                }
        case .liquid:
            ATMusicGlass(shape: cardShape)
                .overlay {
                    cardShape.stroke(Color.white.opacity(0.26), lineWidth: 0.9)
                }
        }
    }
}

// MARK: - 背景与壁纸定制二级页

struct SettingsWallpaperAndAppearanceView: View {
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("atmusic.homeWallpaperBlur") private var homeWallpaperBlur = 0.0
    @AppStorage("atmusic.labelColorHex") private var labelColorHex = ""
    @AppStorage("atmusic.homeHideUsername") private var homeHideUsername = false
    @AppStorage("atmusic.homeHeaderHideSort") private var homeHeaderHideSort = false
    @AppStorage("atmusic.homeHeaderHideRefresh") private var homeHeaderHideRefresh = true
    @AppStorage("atmusic.hideAppearanceToggle") private var hideAppearanceToggle = false
    @AppStorage("atmusic.showSongVIPBadge") private var showSongVIPBadge = true
    @AppStorage("atmusic.tabLabelsVisible") private var tabLabelsVisible = true
    @AppStorage("atmusic.legacyTabCornerRadius") private var legacyTabCornerRadius = 32.0
    @AppStorage("atmusic.legacyTabWidth") private var legacyTabWidth = 356.0
    @AppStorage("atmusic.legacyTabOffsetX") private var legacyTabOffsetX = 0.0
    @AppStorage("atmusic.legacyTabOffsetY") private var legacyTabOffsetY = 0.0

    @State private var wallpaperAppearanceTarget: ATMusicWallpaperAppearance = .light
    @State private var showWallpaperPicker = false
    @State private var showFontImporter = false

    var body: some View {
        ZStack {
            GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
            ScrollView {
                VStack(spacing: 16) {
                    // 1. 壁纸与背景管理
                    SettingsSectionCard(title: "背景与壁纸") {
                        VStack(spacing: 14) {
                            HStack {
                                Text("外观模式模式匹配")
                                    .font(ATMusicFont.appFont(14, .medium))
                                    .foregroundStyle(Color.atmusicLabel)
                                Spacer()
                                Picker("背景模式", selection: $wallpaperAppearanceTarget) {
                                    ForEach(ATMusicWallpaperAppearance.allCases) { appearance in
                                        Text(appearance.title).tag(appearance)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 140)
                            }

                            HStack {
                                Text("纯色背景")
                                    .font(ATMusicFont.appFont(14, .medium))
                                    .foregroundStyle(Color.atmusicLabel)
                                Spacer()
                                ColorPicker("", selection: Binding(
                                    get: { theme.customBackground(for: wallpaperAppearanceTarget.colorScheme) ?? Color.atmusicBackground },
                                    set: { theme.setBackground($0.hexString, for: wallpaperAppearanceTarget.colorScheme) }
                                ))
                                .labelsHidden()
                            }

                            Divider().overlay(Color.atmusicComment.opacity(0.12))

                            // 上传壁纸按钮
                            HStack {
                                Text("壁纸图库")
                                    .font(ATMusicFont.appFont(14, .medium))
                                    .foregroundStyle(Color.atmusicLabel)
                                Spacer()
                                Button {
                                    showWallpaperPicker = true
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "plus.circle.fill")
                                        Text("添加壁纸")
                                    }
                                    .font(ATMusicFont.appFont(13, .semibold))
                                    .foregroundStyle(Color.atmusicAmber)
                                }
                                .buttonStyle(.plain)
                            }

                            if !theme.wallpaperPaths.isEmpty {
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                                    ForEach(theme.wallpaperPaths, id: \.self) { path in
                                        wallpaperGridCell(path: path, appearance: wallpaperAppearanceTarget)
                                    }
                                }
                            } else {
                                Text("暂无已上传壁纸，点击上方添加")
                                    .font(ATMusicFont.appFont(12))
                                    .foregroundStyle(Color.atmusicComment)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            Divider().overlay(Color.atmusicComment.opacity(0.12))

                            // 主页壁纸模糊调节滑块
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("主页壁纸模糊度")
                                        .font(ATMusicFont.appFont(14, .medium))
                                        .foregroundStyle(Color.atmusicLabel)
                                    Spacer()
                                    Text("\(Int(homeWallpaperBlur)) pt")
                                        .font(ATMusicFont.appFont(12, .semibold))
                                        .foregroundStyle(Color.atmusicComment)
                                }
                                HStack(spacing: 12) {
                                    Slider(value: $homeWallpaperBlur, in: 0...30, step: 1)
                                        .tint(Color.atmusicAmber)
                                    if homeWallpaperBlur > 0 {
                                        Button("清除模糊") {
                                            homeWallpaperBlur = 0
                                            ATMusicHaptics.select()
                                        }
                                        .font(ATMusicFont.appFont(12, .medium))
                                        .foregroundStyle(Color.atmusicAmber)
                                    }
                                }
                            }

                            Divider().overlay(Color.atmusicComment.opacity(0.12))

                            Toggle(isOn: Binding(
                                get: { theme.backgroundSyncAll },
                                set: { theme.setBackgroundSyncAll($0) }
                            )) {
                                Text("同步应用到全软件页面")
                                    .font(ATMusicFont.appFont(14, .medium))
                                    .foregroundStyle(Color.atmusicLabel)
                            }
                            .toggleStyle(.switch)
                            .tint(Color.atmusicAmber)
                        }
                        .padding(14)
                    }

                    // 2. 色彩与字体
                    SettingsSectionCard(title: "颜色与字体定制") {
                        VStack(spacing: 12) {
                            HStack {
                                Text("全局强调色")
                                    .font(ATMusicFont.appFont(14, .medium))
                                    .foregroundStyle(Color.atmusicLabel)
                                Spacer()
                                ColorPicker("", selection: Binding(
                                    get: { theme.customAccent ?? Color.atmusicAmber },
                                    set: { theme.setCustomAccent($0.hexString) }
                                ))
                                .labelsHidden()
                                Button("默认") {
                                    theme.clearCustomAccent()
                                    ATMusicHaptics.select()
                                }
                                .font(ATMusicFont.appFont(12, .medium))
                                .foregroundStyle(Color.atmusicAmber)
                            }

                            Divider().overlay(Color.atmusicComment.opacity(0.12))

                            HStack {
                                Text("全 App 主文字颜色")
                                    .font(ATMusicFont.appFont(14, .medium))
                                    .foregroundStyle(Color.atmusicLabel)
                                Spacer()
                                ColorPicker("", selection: Binding(
                                    get: {
                                        if let c = Color(hex: labelColorHex) { return c }
                                        return Color.atmusicLabel
                                    },
                                    set: {
                                        labelColorHex = $0.hexString
                                        theme.objectWillChange.send()
                                    }
                                ), supportsOpacity: false)
                                .labelsHidden()
                                Button("默认") {
                                    labelColorHex = ""
                                    theme.objectWillChange.send()
                                    ATMusicHaptics.select()
                                }
                                .font(ATMusicFont.appFont(12, .medium))
                                .foregroundStyle(Color.atmusicAmber)
                            }

                            Divider().overlay(Color.atmusicComment.opacity(0.12))

                            HStack {
                                Text("注释文字颜色")
                                    .font(ATMusicFont.appFont(14, .medium))
                                    .foregroundStyle(Color.atmusicLabel)
                                Spacer()
                                ColorPicker("", selection: Binding(
                                    get: {
                                        if let raw = UserDefaults.standard.string(forKey: "atmusic.commentColorHex"),
                                           let c = Color(hex: raw) { return c }
                                        return Color.atmusicComment
                                    },
                                    set: {
                                        UserDefaults.standard.set($0.hexString, forKey: "atmusic.commentColorHex")
                                        theme.objectWillChange.send()
                                    }
                                ))
                                .labelsHidden()
                                Button("默认") {
                                    UserDefaults.standard.removeObject(forKey: "atmusic.commentColorHex")
                                    theme.objectWillChange.send()
                                    ATMusicHaptics.select()
                                }
                                .font(ATMusicFont.appFont(12, .medium))
                                .foregroundStyle(Color.atmusicAmber)
                            }

                            Divider().overlay(Color.atmusicComment.opacity(0.12))

                            HStack {
                                Text("全局字体")
                                    .font(ATMusicFont.appFont(14, .medium))
                                    .foregroundStyle(Color.atmusicLabel)
                                Spacer()
                                Text(FontManager.installedFontName ?? "系统默认")
                                    .font(ATMusicFont.appFont(12))
                                    .foregroundStyle(Color.atmusicComment)
                                Button("上传") {
                                    showFontImporter = true
                                }
                                .font(ATMusicFont.appFont(12, .semibold))
                                .foregroundStyle(Color.atmusicAmber)
                                Button("清除") {
                                    FontManager.clear()
                                    ATMusicHaptics.select()
                                    ToastCenter.shared.show("已恢复系统默认字体")
                                }
                                .font(ATMusicFont.appFont(12, .medium))
                                .foregroundStyle(Color.atmusicComment)
                            }
                        }
                        .padding(14)
                    }

                    // 3. 界面元素可见性
                    SettingsSectionCard(title: "界面显隐与辅助选项") {
                        VStack(spacing: 12) {
                            Toggle("显示歌曲 VIP 图标", isOn: $showSongVIPBadge)
                                .font(ATMusicFont.appFont(14))
                            Divider().overlay(Color.atmusicComment.opacity(0.12))
                            Toggle("隐藏主页用户名", isOn: $homeHideUsername)
                                .font(ATMusicFont.appFont(14))
                            Divider().overlay(Color.atmusicComment.opacity(0.12))
                            Toggle("隐藏主页刷新按钮", isOn: $homeHeaderHideRefresh)
                                .font(ATMusicFont.appFont(14))
                            Divider().overlay(Color.atmusicComment.opacity(0.12))
                            Toggle("隐藏右上角外观切换", isOn: $hideAppearanceToggle)
                                .font(ATMusicFont.appFont(14))
                            Divider().overlay(Color.atmusicComment.opacity(0.12))
                            Toggle("隐藏所有界面排序按钮", isOn: $homeHeaderHideSort)
                                .font(ATMusicFont.appFont(14))
                        }
                        .padding(14)
                    }
                }
                .padding(16)
                .frame(maxWidth: 860)
            }
            .atmusicScrollIndicatorsHidden()
        }
        .navigationTitle("背景与壁纸管理")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showWallpaperPicker) {
            WallpaperPhotoPicker { data in
                theme.addWallpaper(data, for: wallpaperAppearanceTarget.colorScheme)
                ATMusicHaptics.success()
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showFontImporter) {
            FontDocumentPicker { url in
                let ext = url.pathExtension.lowercased()
                guard ["ttf", "otf", "ttc"].contains(ext) else {
                    ToastCenter.shared.show("请选择 ttf / otf 字体文件")
                    return
                }
                if let name = FontManager.install(from: url) {
                    ATMusicHaptics.success()
                    ToastCenter.shared.show("字体已应用：\(name)")
                }
            }
            .ignoresSafeArea()
        }
    }

    private func wallpaperGridCell(path: String, appearance: ATMusicWallpaperAppearance) -> some View {
        let isActive = path == theme.backgroundImagePath(for: appearance.colorScheme)
        return ZStack(alignment: .topTrailing) {
            Button {
                ATMusicHaptics.tap()
                theme.applyWallpaper(at: path, for: appearance.colorScheme)
            } label: {
                Group {
                    if let img = ATMusicImageFileCache.image(at: path) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.atmusicGlassFill
                    }
                }
                .frame(height: 96)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.atmusicAmber)
                            .background(Circle().fill(.white))
                            .padding(4)
                    }
                }
            }
            .buttonStyle(.plain)

            Button {
                theme.deleteWallpaper(at: path)
                ATMusicHaptics.select()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .background(Circle().fill(Color.black.opacity(0.6)))
                    .padding(4)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - 歌词显示偏好二级页

struct SettingsLyricPreferenceView: View {
    @EnvironmentObject private var theme: ThemeStore
    @AppStorage("atmusic.lyricTranslation") private var lyricTranslation = true
    @AppStorage("atmusic.lyricFontSize") private var lyricFontSize = 17
    @AppStorage("atmusic.lyricSpacing") private var lyricSpacing = 24
    @AppStorage("atmusic.lyricBlurAmount") private var lyricBlurAmount = 1.1
    @AppStorage("atmusic.lyricGlow") private var lyricGlowLevel = 1

    var body: some View {
        ZStack {
            GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
            ScrollView {
                VStack(spacing: 16) {
                    SettingsSectionCard(title: "歌词显示偏好") {
                        VStack(spacing: 14) {
                            Toggle("显示歌词翻译", isOn: $lyricTranslation)
                                .font(ATMusicFont.appFont(14, .medium))
                                .tint(Color.atmusicAmber)

                            Divider().overlay(Color.atmusicComment.opacity(0.12))

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("默认歌词字号")
                                        .font(ATMusicFont.appFont(14, .medium))
                                        .foregroundStyle(Color.atmusicLabel)
                                    Spacer()
                                    Text("\(lyricFontSize) pt")
                                        .font(ATMusicFont.appFont(12, .semibold))
                                        .foregroundStyle(Color.atmusicComment)
                                }
                                Slider(value: Binding(
                                    get: { Double(lyricFontSize) },
                                    set: { lyricFontSize = Int($0) }
                                ), in: 12...28, step: 1)
                                .tint(Color.atmusicAmber)
                            }

                            Divider().overlay(Color.atmusicComment.opacity(0.12))

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("歌词行距")
                                        .font(ATMusicFont.appFont(14, .medium))
                                        .foregroundStyle(Color.atmusicLabel)
                                    Spacer()
                                    Text("\(lyricSpacing) pt")
                                        .font(ATMusicFont.appFont(12, .semibold))
                                        .foregroundStyle(Color.atmusicComment)
                                }
                                Slider(value: Binding(
                                    get: { Double(lyricSpacing) },
                                    set: { lyricSpacing = Int($0) }
                                ), in: 0...40, step: 2)
                                .tint(Color.atmusicAmber)
                            }

                            Divider().overlay(Color.atmusicComment.opacity(0.12))

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("歌词发光效果")
                                        .font(ATMusicFont.appFont(14, .medium))
                                        .foregroundStyle(Color.atmusicLabel)
                                    Spacer()
                                    Text(glowLevelText)
                                        .font(ATMusicFont.appFont(12, .semibold))
                                        .foregroundStyle(Color.atmusicComment)
                                }
                                Slider(value: Binding(
                                    get: { Double(lyricGlowLevel) },
                                    set: { lyricGlowLevel = Int($0) }
                                ), in: 0...4, step: 1)
                                .tint(Color.atmusicAmber)
                            }
                        }
                        .padding(14)
                    }
                }
                .padding(16)
                .frame(maxWidth: 860)
            }
            .atmusicScrollIndicatorsHidden()
        }
        .navigationTitle("歌词显示偏好")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var glowLevelText: String {
        switch lyricGlowLevel {
        case 0: return "关闭"
        case 1: return "柔和"
        case 2: return "标准"
        default: return "强烈"
        }
    }
}
