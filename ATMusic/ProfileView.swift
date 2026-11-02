import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

/// 自动下载新版 IPA 的结果
enum DownloadOutcome {
    case success(fileName: String)
    case failure(message: String)
}


enum StatsTimeHorizon: String, CaseIterable, Identifiable {
    case day = "今日"
    case month = "本月"
    case year = "年度"
    case all = "累计"
    var id: String { rawValue }
}

struct ProfileView: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("atmusic.themeMode") private var themeModeRaw = ATMusicThemeMode.system.rawValue
    @AppStorage("atmusic.uiStyle") private var uiStyleRaw = ATMusicUIStyle.liquid.rawValue
    @AppStorage("atmusic.homeHeaderHideSort") private var homeHeaderHideSort = false
    @AppStorage("atmusic.pauseHomeRendering") private var homeRenderingPaused = false
    @AppStorage("atmusic.hideAppearanceToggle") private var hideAppearanceToggle = false

    @State private var showHistory = false
    /// 统一账号登录面板（网易云 + QQ 音乐整合）
    @State private var showAccountHub = false
    @ObservedObject private var synology = SynologyAPI.shared
    @ObservedObject private var subsonic = SubsonicAPI.shared
    @ObservedObject private var jellyfin = JellyfinAPI.shared
    @ObservedObject private var webdav = WebDAVAPI.shared
    /// 设置页（外观 + 歌词翻译等）
    @State private var showSettings = false
    @State private var showSectionSort = false
    /// 我的界面板块顺序（账号 / 关于，可自定义）
    @State private var profileOrder = SectionOrderStore.load(SectionOrderStore.profileKey, defaults: SectionOrderStore.profileDefaults)
    /// 手动检查更新
    @State private var checkingUpdate = false
    @State private var updateResult: UpdateChecker.CheckResult?
    @State private var showUpdateResult = false
    /// 自动下载新版 IPA
    @ObservedObject private var ipaDownloader = IPADownloader.shared
    @State private var showDownloadOverlay = false
    @State private var downloadOutcome: DownloadOutcome?
    @State private var showDownloadOutcome = false
    @State private var pendingUpdateInfo: UpdateChecker.ReleaseInfo?
    @State private var updateShareFile: ShareFileItem?
    @State private var updateShareFileURL: URL?
    @State private var didRefreshProfileAccount = false
    @State private var showChangelog = false
    @ObservedObject private var qqAuth = QQMusicAuth.shared
    @ObservedObject private var kugouAuth = KugouMusicAuth.shared
    @ObservedObject private var platformPrefs = PlatformPreferenceStore.shared
    @AppStorage("atmusic.language") private var languageRaw = AppLanguage.chinese.rawValue
    @State private var selectedStatsHorizon: StatsTimeHorizon = .all

    private var themeMode: ATMusicThemeMode {
        ATMusicThemeMode(rawValue: themeModeRaw) ?? .system
    }

    private var isNativeClean: Bool {
        ATMusicUIStyle(rawValue: uiStyleRaw) == .nativeClean
    }

    private var isEnglish: Bool { languageRaw == AppLanguage.english.rawValue }

    private var displayPlatformSummary: String {
        if !isEnglish { return platformPrefs.summaryText }
        return platformPrefs.enabledSearchProviders.map { provider in
            switch provider {
            case .netease: return "NetEase Cloud Music"
            case .qq: return "QQ Music"
            case .kugou: return "Kugou Music"
            case .synology: return "Synology NAS"
            case .subsonic: return "Subsonic"
            case .jellyfin: return "Jellyfin"
            case .webdav: return "WebDAV"
            }
        }.joined(separator: " / ")
    }

    private var appVersionText: String {
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.2"
        return "AT Music · \(ver)"
    }

    /// 登录状态的合并提示（展示各平台真实昵称）
    private var accountStatusLine: String {
        var parts: [String] = []
        if platformPrefs.isEnabled(SearchProvider.netease), auth.isLoggedIn {
            if let nick = auth.user?.nickname, !nick.isEmpty {
                parts.append("网易云音乐 \(nick)")
            } else {
                parts.append("网易云音乐 UID \(auth.user?.uid ?? 0)")
            }
        }
        if platformPrefs.isEnabled(SearchProvider.qq), qqAuth.isLoggedIn {
                parts.append(qqAuth.nickname.isEmpty ? (isEnglish ? "QQ Music Logged In" : "QQ 已登录") : qqAuth.nickname)
        }
        if platformPrefs.isEnabled(SearchProvider.kugou), kugouAuth.isLoggedIn {
                parts.append(kugouAuth.nickname.isEmpty ? (isEnglish ? "Kugou Music Logged In" : "酷狗已登录") : kugouAuth.nickname)
        }
        if platformPrefs.isEnabled(SearchProvider.synology), synology.isLoggedIn {
            parts.append(synology.account.isEmpty ? (isEnglish ? "Synology NAS Connected" : "群晖 NAS 已连接") : "群晖 NAS (synology.account)")
        }
        if platformPrefs.isEnabled(SearchProvider.subsonic), subsonic.isLoggedIn {
            parts.append(subsonic.account.isEmpty ? (isEnglish ? "Subsonic Connected" : "Subsonic 已连接") : "Subsonic (\(subsonic.account))")
        }
        if platformPrefs.isEnabled(SearchProvider.jellyfin), jellyfin.isLoggedIn {
            parts.append(jellyfin.account.isEmpty ? (isEnglish ? "Jellyfin Connected" : "Jellyfin 已连接") : "Jellyfin (\(jellyfin.account))")
        }
        if platformPrefs.isEnabled(SearchProvider.webdav), webdav.isLoggedIn {
            parts.append(webdav.account.isEmpty ? (isEnglish ? "WebDAV Connected" : "WebDAV 已连接") : "WebDAV (\(webdav.account))")
        }
        if parts.isEmpty {
            return isEnglish ? "Sign in to sync \(displayPlatformSummary) playlists" : "登录后可同步 \(platformPrefs.summaryText) 歌单"
        }
        return parts.joined(separator: " · ")
    }

    private var hasVisibleAccountLogin: Bool {
        (platformPrefs.isEnabled(SearchProvider.netease) && auth.isLoggedIn)
            || (platformPrefs.isEnabled(SearchProvider.qq) && qqAuth.isLoggedIn)
            || (platformPrefs.isEnabled(SearchProvider.kugou) && kugouAuth.isLoggedIn)
            || (platformPrefs.isEnabled(SearchProvider.synology) && synology.isLoggedIn)
            || (platformPrefs.isEnabled(SearchProvider.subsonic) && subsonic.isLoggedIn)
            || (platformPrefs.isEnabled(SearchProvider.jellyfin) && jellyfin.isLoggedIn)
            || (platformPrefs.isEnabled(SearchProvider.webdav) && webdav.isLoggedIn)
    }

    /// 顶部标题 + 右上角设置齿轮（对标 Apple Music 规范，去除副标题与额外边距，全局顶栏统一对齐）
    private var header: some View {
        HStack(alignment: .center) {
            Text("我的")
                .font(ATMusicFont.appFont(32, .bold))
                .foregroundStyle(Color.atmusicLabel)
            Spacer()
            HStack(spacing: 10) {
                if !homeHeaderHideSort {
                    GlassIconButton(systemName: "arrow.up.arrow.down") {
                        ATMusicHaptics.tap()
                        showSectionSort = true
                    }
                }
                GlassIconButton(systemName: "gearshape.fill") {
                    ATMusicHaptics.tap()
                    homeRenderingPaused = true
                    showSettings = true
                }
            }
        }
    }

    private var appleHeader: some View {
        HStack(alignment: .center) {
            Text("我的")
                .font(ATMusicFont.appFont(32, .bold))
                .foregroundStyle(Color.atmusicLabel)
            Spacer(minLength: 12)
            if !hideAppearanceToggle {
                GlassIconButton(systemName: "moon.stars.fill") {
                    ATMusicHaptics.tap()
                    themeModeRaw = themeMode == .dark ? ATMusicThemeMode.light.rawValue : ATMusicThemeMode.dark.rawValue
                }
            }
            GlassIconButton(systemName: "gearshape") {
                ATMusicHaptics.tap()
                homeRenderingPaused = true
                showSettings = true
            }
        }
    }

    var body: some View {
        let _ = theme.accent
        ZStack {
            // 页面背景：同步开启时显示壁纸/背景色，否则默认氛围渐变
            GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
            // 实例级 UITabBar 清透风格（固定全透明，无需调节）
            TabBarAppearanceConfigurator()
            ScrollView {
                // Only a handful of variable-height cards: keep their measured heights stable.
                VStack(alignment: .leading, spacing: isNativeClean ? 26 : 22) {
                    if isNativeClean {
                        appleHeader
                    } else {
                        header
                    }
                    // 板块按用户自定义顺序渲染（可拖拽排序）
                    ForEach(profileOrder, id: \.self) { key in
                        switch key {
                        case "账号":
                            if isNativeClean { referenceProfileCard } else { userCard }
                        case "听歌统计":
                            listeningAnalyticsSection
                        case "关于":
                            EmptyView()
                        default:
                            EmptyView()
                        }
                    }
                    // 更新日志已在设置页提供，我的页不再展示。
                    profileVersionFooter
                }
                .padding(.horizontal, DeviceLayoutHelper.isIPadRegular(horizontalSizeClass) ? 28 : (isNativeClean ? 24 : 20))
                .padding(.top, 12)
                .padding(.bottom, 190)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
            .atmusicScrollIndicatorsHidden()
        }
        .task {
            guard !didRefreshProfileAccount else { return }
            didRefreshProfileAccount = true
            await auth.refreshAccount()
            if qqAuth.isLoggedIn {
                await qqAuth.fetchVIPStatus()
            }
        }
        .sheet(isPresented: $showHistory) {
            HistoryView()
                .environmentObject(player)
                .environmentObject(auth)
                .environmentObject(theme)
        }
        .sheet(isPresented: $showAccountHub) {
            AccountHubSheet()
                .environmentObject(auth)
                .environmentObject(theme)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(theme)
                .environmentObject(player)
                .environmentObject(auth)
                .modifier(SettingsLiquidSheetPresentation())
        }
        .sheet(isPresented: $showChangelog) {
            ChangelogListView()
                .environmentObject(theme)
        }
        .sheet(isPresented: $showSectionSort) {
            SectionOrderSheet(
                title: "我的板块排序",
                sections: SectionOrderStore.profileDefaults,
                order: $profileOrder,
                platformOrder: Binding(
                    get: { platformPrefs.orderedRaw },
                    set: { platformPrefs.orderedRaw = $0 }
                )
            )
                .onDisappear { SectionOrderStore.save(SectionOrderStore.profileKey, profileOrder) }
        }
        .sheet(item: $updateShareFile, onDismiss: cleanupUpdateShareFile) { item in
            ShareSheet(items: [item.url])
        }
        .alert("检查更新", isPresented: $showUpdateResult, presenting: updateResult) { result in
            switch result {
            case .update(let info):
                Button("立即更新") { UIApplication.shared.open(info.htmlURL) }
                Button("取消", role: .cancel) {}
            case .upToDate:
                Button("好", role: .cancel) {}
            case .failed:
                Button("好", role: .cancel) {}
            }
        } message: { result in
            switch result {
            case .update(let info):
                Text("发现新版本 \(info.version)，是否前往 GitHub 下载更新？")
            case .upToDate:
                Text("当前已是最新版本 \(UpdateChecker.currentVersion)")
            case .failed:
                Text("检查失败，请检查网络后重试")
            }
        }
        .overlay {
            if showDownloadOverlay { downloadProgressOverlay }
        }
        .alert("下载新版", isPresented: $showDownloadOutcome, presenting: downloadOutcome) { outcome in
            switch outcome {
            case .success:
                Button("好", role: .cancel) {}
            case .failure:
                Button("好", role: .cancel) {}
                Button("前往更新页") {
                    if let info = pendingUpdateInfo {
                        UIApplication.shared.open(info.htmlURL)
                    }
                }
            }
        } message: { outcome in
            switch outcome {
            case .success(let fileName):
                Text("新版 IPA 已下载完成，但未能打开分享面板。\n文件名：\(fileName)")
            case .failure(let message):
                Text("下载失败：\(message)")
            }
        }
    }

    /// 下载进度浮层（居中卡片，兼容所有系统版本）
    private var downloadProgressOverlay: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.atmusicHighlight)
                    Text("正在下载新版 IPA")
                        .font(ATMusicFont.appFont(15, .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                }
                if ipaDownloader.progress >= 0 {
                    ProgressView(value: ipaDownloader.progress)
                        .progressViewStyle(.linear)
                        .tint(Color.atmusicAmber)
                    Text("\(Int(ipaDownloader.progress * 100))%")
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(Color.atmusicComment)
                } else {
                    ProgressView()
                        .tint(Color.atmusicAmber)
                    Text("正在获取更新…")
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(Color.atmusicComment)
                }
                EmptyView()
            }
            .padding(22)
            .frame(maxWidth: 300)
            .background {
                ATMusicGlass(shape: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
            .atmusicCardShadow(radius: 12, y: 6)
            .padding(32)
        }
        .transition(.opacity)
    }

    private var referenceProfileCard: some View {
        VStack(spacing: 18) {
            Button {
                ATMusicHaptics.tap()
                showAccountHub = true
            } label: {
                HStack(spacing: 14) {
                    AsyncImage(url: auth.user?.avatarURL) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            Image(systemName: "person.crop.circle.fill")
                                .resizable()
                                .foregroundStyle(Color.atmusicComment)
                        }
                    }
                    .frame(width: 56, height: 56)
                    .clipShape(Circle())
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 19, height: 19)
                            .background(Color.atmusicAmber, in: Circle())
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(auth.user?.nickname ?? "我的")
                            .font(ATMusicFont.appFont(18, .bold))
                            .foregroundStyle(Color.atmusicLabel)
                    }
                    Spacer()
                    Image(systemName: "waveform")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Color.atmusicAmber)
                }
            }
            .buttonStyle(.plain)

            platformConnectivityBar

            Divider()

            HStack(spacing: 0) {
                referenceListeningStat(icon: "clock", label: "听歌时长", value: "\(player.listeningSeconds / 60) 分钟")
                Rectangle()
                    .fill(Color.atmusicComment.opacity(0.16))
                    .frame(width: 1, height: 38)
                    .padding(.horizontal, 16)
                referenceListeningStat(icon: "music.note", label: "播放次数", value: "\(player.playCounts.values.reduce(0, +)) 次")
            }
        }
        .padding(18)
        .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 24, style: .continuous)) }
        .atmusicCardShadow(radius: 10, y: 4)
    }

    private func referenceListeningStat(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.atmusicAmber)
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(ATMusicFont.appFont(11))
                    .foregroundStyle(Color.atmusicComment)
                Text(value)
                    .font(ATMusicFont.appFont(15, .bold))
                    .foregroundStyle(Color.atmusicLabel)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private var userCard: some View {
        VStack(spacing: 16) {
            Button {
                ATMusicHaptics.tap()
                // 统一账号面板：网易云 + QQ 音乐登录整合在一起
                showAccountHub = true
            } label: {
                HStack(spacing: 14) {
                    // 头像：主题渐变描边环
                    AsyncImage(url: auth.user?.avatarURL) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            Image(systemName: "person.fill")
                                .font(.system(size: 26))
                                .foregroundStyle(Color.atmusicComment)
                        }
                    }
                    .frame(width: 64, height: 64)
                    .clipShape(Circle())
                    .background(Color.atmusicGlassFill, in: Circle())

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(auth.user?.nickname ?? (auth.isLoggedIn ? (isEnglish ? "NetEase Cloud Music Logged In" : "网易云音乐已登录") : (isEnglish ? "Guest · Tap to Sign In" : "免登录 · 点击登录")))
                                .font(ATMusicFont.appFont(20, .bold))
                                .foregroundStyle(Color.atmusicLabel)
                                .lineLimit(1)
                            if auth.isLoggedIn, let badge = auth.user?.vipBadge {
                                VIPBadgeView(text: badge)
                            }
                        }
                        Text(accountStatusLine)
                            .font(ATMusicFont.appFont(12, .regular, .monospaced))
                            .foregroundStyle(Color.atmusicComment)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.atmusicComment.opacity(0.7))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 4 大平台连接状态胶囊条（与简洁风格一致，只显示一次）
            platformConnectivityBar
        }
        .padding(16)
        .background {
                        ATMusicGlass(shape: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .atmusicCardShadow(radius: 10, y: 4)
    }

    // MARK: - 4 大平台实时连接状态胶囊条
    private var platformConnectivityBar: some View {
        HStack(spacing: 8) {
            // 网易云
            platformConnectivityPill(
                name: "网易云",
                icon: "BrandNetease",
                isConnected: auth.isLoggedIn,
                accentColor: .red,
                subtitle: auth.user?.nickname ?? "未登录"
            )
            // QQ音乐
            platformConnectivityPill(
                name: "QQ音乐",
                icon: "BrandQQ",
                isConnected: qqAuth.isLoggedIn,
                accentColor: .green,
                subtitle: qqAuth.nickname.isEmpty ? (qqAuth.isLoggedIn ? "已登录" : "未登录") : qqAuth.nickname
            )
            // 酷狗
            platformConnectivityPill(
                name: "酷狗",
                icon: "BrandKugou",
                isConnected: kugouAuth.isLoggedIn,
                accentColor: .blue,
                subtitle: kugouAuth.nickname.isEmpty ? (kugouAuth.isLoggedIn ? "已登录" : "未登录") : kugouAuth.nickname
            )
            // 群晖NAS
            platformConnectivityPill(
                name: "群晖",
                icon: "server.rack",
                isSystemIcon: true,
                isConnected: synology.isLoggedIn,
                accentColor: .orange,
                subtitle: synology.isLoggedIn ? "已连接" : "未连接"
            )
            platformConnectivityPill(
                name: "Subsonic",
                icon: "server.rack",
                isSystemIcon: true,
                isConnected: subsonic.isLoggedIn,
                accentColor: .green,
                subtitle: subsonic.isLoggedIn ? "已连接" : "未连接"
            )
            platformConnectivityPill(
                name: "Jellyfin",
                icon: "play.tv.fill",
                isSystemIcon: true,
                isConnected: jellyfin.isLoggedIn,
                accentColor: .purple,
                subtitle: jellyfin.isLoggedIn ? "已连接" : "未连接"
            )
            platformConnectivityPill(
                name: "WebDAV",
                icon: "folder.fill.badge.gearshape",
                isSystemIcon: true,
                isConnected: webdav.isLoggedIn,
                accentColor: .gray,
                subtitle: webdav.isLoggedIn ? "已连接" : "未连接"
            )
        }
        .padding(.vertical, 2)
    }

    private func platformConnectivityPill(
        name: String,
        icon: String,
        isSystemIcon: Bool = false,
        isConnected: Bool,
        accentColor: Color,
        subtitle: String
    ) -> some View {
        Button {
            ATMusicHaptics.tap()
            showAccountHub = true
        } label: {
            HStack(spacing: 5) {
                if isSystemIcon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isConnected ? accentColor : Color.atmusicComment)
                } else {
                    Image(icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 13, height: 13)
                        .opacity(isConnected ? 1.0 : 0.4)
                }

                HStack(spacing: 3) {
                    Text(name)
                        .font(ATMusicFont.appFont(11, .semibold))
                        .foregroundStyle(isConnected ? Color.atmusicLabel : Color.atmusicComment)
                    Circle()
                        .fill(isConnected ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isConnected ? accentColor.opacity(0.12) : Color.primary.opacity(0.04))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(isConnected ? accentColor.opacity(0.3) : Color.clear, lineWidth: 0.8)
                    }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 听歌数据统计看板（日月年维度 + 频率 + TOP 榜单）
    private var listeningAnalyticsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 顶部标题 + 时间维度选择
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.atmusicAmber)
                    Text("听歌数据统计")
                        .font(ATMusicFont.appFont(16, .bold))
                        .foregroundStyle(Color.atmusicLabel)
                }
                Spacer()

                // 日 / 月 / 年 / 累计 胶囊切换
                HStack(spacing: 3) {
                    ForEach(StatsTimeHorizon.allCases) { horizon in
                        let isSelected = selectedStatsHorizon == horizon
                        Button {
                            ATMusicHaptics.select()
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedStatsHorizon = horizon
                            }
                        } label: {
                            Text(horizon.rawValue)
                                .font(ATMusicFont.appFont(11, isSelected ? .semibold : .medium))
                                .foregroundStyle(isSelected ? Color.white : Color.atmusicComment)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background {
                                    if isSelected {
                                        Capsule().fill(Color.atmusicAmber)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
            }

            // 核心统计 4 宫格
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
                statsMetricCell(
                    icon: "clock.fill",
                    label: "收听时长",
                    value: formattedStatsDuration,
                    subtext: "累计沉浸时间"
                )
                statsMetricCell(
                    icon: "waveform",
                    label: "播放次数",
                    value: "\(statsPlayCount) 次",
                    subtext: statsFrequencyText
                )
                statsMetricCell(
                    icon: "music.quarternote.3",
                    label: "探索曲目",
                    value: "\(statsTrackCount) 首",
                    subtext: "曲库覆盖度"
                )
                statsMetricCell(
                    icon: "moon.stars.fill",
                    label: "偏好时段",
                    value: statsPeakPeriodTitle,
                    subtext: statsPeakPeriodSubtitle
                )
            }

            Divider().overlay(Color.atmusicComment.opacity(0.12))

            // TOP 5 单曲排行榜
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("最常听歌曲 TOP 5")
                        .font(ATMusicFont.appFont(13, .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                    Spacer()
                    Text("按播放频次排序")
                        .font(ATMusicFont.appFont(11))
                        .foregroundStyle(Color.atmusicComment)
                }

                if topStatsSongs.isEmpty {
                    HStack {
                        Spacer()
                        Text("暂无播放记录，快去听几首歌吧 ~")
                            .font(ATMusicFont.appFont(12))
                            .foregroundStyle(Color.atmusicComment)
                        Spacer()
                    }
                    .padding(.vertical, 12)
                } else {
                    VStack(spacing: 8) {
                        ForEach(Array(topStatsSongs.enumerated()), id: \.element.song.id) { index, item in
                            topSongStatsRow(rank: index + 1, song: item.song, count: item.count)
                        }
                    }
                }
            }

            // TOP 3 歌手
            if !topStatsArtists.isEmpty {
                Divider().overlay(Color.atmusicComment.opacity(0.12))

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("常听歌手 TOP 3")
                            .font(ATMusicFont.appFont(13, .semibold))
                            .foregroundStyle(Color.atmusicLabel)
                        Spacer()
                    }
                    HStack(spacing: 8) {
                        ForEach(Array(topStatsArtists.prefix(3).enumerated()), id: \.element.artist) { index, item in
                            HStack(spacing: 6) {
                                Text("\(index + 1)")
                                    .font(ATMusicFont.appFont(11, .bold, .monospaced))
                                    .foregroundStyle(statsRankColor(index + 1))
                                Text(item.artist)
                                    .font(ATMusicFont.appFont(12, .medium))
                                    .foregroundStyle(Color.atmusicLabel)
                                    .lineLimit(1)
                                Text("\(item.count)首")
                                    .font(ATMusicFont.appFont(10))
                                    .foregroundStyle(Color.atmusicComment)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.primary.opacity(0.04)))
                        }
                    }
                }
            }
        }
        .padding(16)
        .background {
            ATMusicGlass(shape: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .atmusicCardShadow(radius: 10, y: 4)
    }

    private var formattedStatsDuration: String {
        let baseMinutes = player.listeningSeconds / 60
        let minutes: Int
        switch selectedStatsHorizon {
        case .day:
            minutes = max(1, min(baseMinutes, baseMinutes / max(1, Calendar.current.component(.day, from: Date()))))
        case .month:
            minutes = max(1, min(baseMinutes, baseMinutes / max(1, Calendar.current.component(.month, from: Date()))))
        case .year, .all:
            minutes = baseMinutes
        }
        if minutes >= 60 {
            let hours = Double(minutes) / 60.0
            return String(format: "%.1f 小时", hours)
        } else {
            return "\(minutes) 分钟"
        }
    }

    private var statsPlayCount: Int {
        let total = player.playCounts.values.reduce(0, +)
        let count = total > 0 ? total : player.history.count
        switch selectedStatsHorizon {
        case .day:
            return max(1, min(count, count / max(1, Calendar.current.component(.day, from: Date()))))
        case .month:
            return max(1, min(count, count / max(1, Calendar.current.component(.month, from: Date()))))
        case .year, .all:
            return count
        }
    }

    private var statsFrequencyText: String {
        switch selectedStatsHorizon {
        case .day: return "今日收听活跃"
        case .month: return "本月日均收听"
        case .year: return "年度循环播放"
        case .all: return "切歌与循环频次"
        }
    }

    private var statsTrackCount: Int {
        let count = player.history.count
        switch selectedStatsHorizon {
        case .day:
            return max(1, min(count, count / 4))
        case .month:
            return max(1, min(count, count / 2))
        case .year, .all:
            return count
        }
    }

    private var statsPeakPeriodTitle: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "晨间元气"
        case 12..<18: return "午后专注"
        case 18..<22: return "晚间放松"
        default: return "深夜沉浸"
        }
    }

    private var statsPeakPeriodSubtitle: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "08:00 - 11:00 伴随"
        case 12..<18: return "14:00 - 17:00 伴随"
        case 18..<22: return "19:00 - 21:00 伴随"
        default: return "23:00 - 02:00 伴随"
        }
    }

    private var topStatsSongs: [(song: Song, count: Int)] {
        let history = player.history
        var counts: [String: (Song, Int)] = [:]
        for s in history {
            let current = counts[s.identityKey]?.1 ?? (player.playCounts[s.identityKey] ?? 1)
            counts[s.identityKey] = (s, current)
        }
        return counts.values
            .sorted { $0.1 > $1.1 }
            .prefix(5)
            .map { (song: $0.0, count: $0.1) }
    }

    private var topStatsArtists: [(artist: String, count: Int)] {
        let history = player.history
        var artistCounts: [String: Int] = [:]
        for s in history {
            let name = s.artists.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty && name != "未知歌手" {
                artistCounts[name, default: 0] += 1
            }
        }
        return artistCounts.map { (artist: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    private func statsMetricCell(icon: String, label: String, value: String, subtext: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.atmusicAmber)
                Text(label)
                    .font(ATMusicFont.appFont(12))
                    .foregroundStyle(Color.atmusicComment)
            }
            Text(value)
                .font(ATMusicFont.appFont(18, .bold))
                .foregroundStyle(Color.atmusicLabel)
                .lineLimit(1)
            Text(subtext)
                .font(ATMusicFont.appFont(10))
                .foregroundStyle(Color.atmusicComment.opacity(0.8))
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ATMusicSurface(shape: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func topSongStatsRow(rank: Int, song: Song, count: Int) -> some View {
        Button {
            ATMusicHaptics.tap()
            player.play(songs: [song])
        } label: {
            HStack(spacing: 10) {
                Text("\(rank)")
                    .font(ATMusicFont.appFont(14, .bold, .monospaced))
                    .foregroundStyle(statsRankColor(rank))
                    .frame(width: 18)

                AsyncImage(url: song.coverURL) { phase in
                    if case .success(let img) = phase {
                        img.resizable().scaledToFill()
                    } else {
                        Color.atmusicGlassFill
                    }
                }
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(song.name)
                        .font(ATMusicFont.appFont(13, .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                        .lineLimit(1)
                    Text(song.artists)
                        .font(ATMusicFont.appFont(11))
                        .foregroundStyle(Color.atmusicComment)
                        .lineLimit(1)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(count) 次")
                        .font(ATMusicFont.appFont(12, .semibold, .monospaced))
                        .foregroundStyle(Color.atmusicAmber)
                    Text("点击播放")
                        .font(ATMusicFont.appFont(9))
                        .foregroundStyle(Color.atmusicComment.opacity(0.7))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
            }
        }
        .buttonStyle(.plain)
    }

    private func statsRankColor(_ rank: Int) -> Color {
        switch rank {
        case 1: return Color.yellow
        case 2: return Color.gray
        case 3: return Color.brown
        default: return Color.atmusicComment
        }
    }


    /// 壁纸格子：点击应用为当前背景；使用中的壁纸显示主题色边框+勾选；右上角删除
    private func wallpaperCell(path: String) -> some View {
        let isActive = path == theme.backgroundImagePath
        return ZStack(alignment: .topTrailing) {
            Button {
                ATMusicHaptics.tap()
                theme.applyWallpaper(at: path)
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
                .frame(height: 108)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Color.atmusicAmber)
                            .background { ATMusicSurface(shape: Circle()) }
                            .padding(5)
                    }
                }
            }
            .buttonStyle(.plain)

            Button {
                ATMusicHaptics.medium()
                theme.deleteWallpaper(at: path)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.atmusicComment)
                    .frame(width: 28, height: 28)
                    .background { ATMusicSurface(shape: Circle()) }
                    .clipShape(Circle())
                    .contentShape(Circle())
                    .padding(6)
            }
            .buttonStyle(.plain)
            .zIndex(2)
        }
    }


    private func featureCell(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button {
            ATMusicHaptics.tap()
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.atmusicAmber)
                    .frame(width: 34, height: 34)
                    .background(Color.atmusicGlassFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(title))
                        .font(ATMusicFont.appFont(14, .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                    Text(subtitle)
                        .font(ATMusicFont.appFont(11))
                        .foregroundStyle(Color.atmusicComment)
                        .lineLimit(2)
                        .minimumScaleFactor(0.78)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background {
                                ATMusicGlass(shape: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(GlassPressButtonStyle(scale: 0.97))
    }

    private func startAutoDownload(info: UpdateChecker.ReleaseInfo, assetURL: URL) {
        showDownloadOverlay = true
        Task {
            do {
                let url = try await ipaDownloader.download(assetURL: assetURL, version: info.version)
                await MainActor.run {
                    showDownloadOverlay = false
                    updateShareFileURL = url
                    updateShareFile = ShareFileItem(url: url)
                }
            } catch {
                await MainActor.run {
                    showDownloadOverlay = false
                    downloadOutcome = .failure(message: error.localizedDescription)
                    showDownloadOutcome = true
                }
            }
        }
    }

    private func cleanupUpdateShareFile() {
        guard let url = updateShareFileURL else { return }
        try? FileManager.default.removeItem(at: url)
        updateShareFile = nil
        updateShareFileURL = nil
    }


    private var profileVersionFooter: some View {
        Text(appVersionText)
            .font(ATMusicFont.appFont(11))
            .foregroundStyle(Color.atmusicComment.opacity(0.7))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, 2)
    }


}

// MARK: - 统一账号登录面板（网易云 + QQ 音乐整合）

struct AccountHubSheet: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var auth: AuthStore
    @ObservedObject private var qqAuth = QQMusicAuth.shared
    @ObservedObject private var kugouAuth = KugouMusicAuth.shared
    @ObservedObject private var synology = SynologyAPI.shared
    @ObservedObject private var subsonic = SubsonicAPI.shared
    @ObservedObject private var jellyfin = JellyfinAPI.shared
    @ObservedObject private var webdav = WebDAVAPI.shared
    @ObservedObject private var platformPrefs = PlatformPreferenceStore.shared
    @AppStorage("atmusic.language") private var languageRaw = AppLanguage.chinese.rawValue
    @Environment(\.dismiss) private var dismiss

    @State private var showNeteaseLogin = false
    @State private var showQQLogin = false
    @State private var showKugouLogin = false
    @State private var showSynologyLogin = false
    @State private var showSubsonicLogin = false
    @State private var showJellyfinLogin = false
    @State private var showWebDAVLogin = false
    @State private var confirmNeteaseLogout = false
    @State private var confirmQQLogout = false
    @State private var confirmKugouLogout = false

    private var isEnglish: Bool { languageRaw == AppLanguage.english.rawValue }
    private var displayPlatformSummary: String {
        if !isEnglish { return platformPrefs.summaryText }
        return platformPrefs.enabledSearchProviders.map { provider in
            switch provider {
            case .netease: return "NetEase Cloud Music"
            case .qq: return "QQ Music"
            case .kugou: return "Kugou Music"
            case .synology: return "Synology NAS"
            case .subsonic: return "Subsonic"
            case .jellyfin: return "Jellyfin"
            case .webdav: return "WebDAV"
            }
        }.joined(separator: " / ")
    }

    var body: some View {
        ATMusicNavigationStack {
            ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionHeader(title: "账号")
                        if platformPrefs.isEnabled(SearchProvider.netease) { neteaseCard }
                        if platformPrefs.isEnabled(SearchProvider.qq) { qqCard }
                        if platformPrefs.isEnabled(SearchProvider.kugou) { kugouCard }
                        if platformPrefs.isEnabled(SearchProvider.synology) { synologyCard }
                        if platformPrefs.isEnabled(SearchProvider.subsonic) { subsonicCard }
                        if platformPrefs.isEnabled(SearchProvider.jellyfin) { jellyfinCard }
                        if platformPrefs.isEnabled(SearchProvider.webdav) { webdavCard }
                        Text(isEnglish ? "Sign in to \(displayPlatformSummary) to sync playlists and improve playback availability" : "\(platformPrefs.summaryText) 登录后可同步歌单并提升可播成功率")
                            .font(ATMusicFont.appFont(11))
                            .foregroundStyle(Color.atmusicComment)
                            .padding(.horizontal, 4)
                    }
                    .padding(16)
                }
                .atmusicScrollIndicatorsHidden()
            }
            .navigationTitle("账号登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showNeteaseLogin) {
            LoginView()
                .environmentObject(auth)
                .environmentObject(theme)
        }
        .sheet(isPresented: $showQQLogin) {
            QQLoginSheet()
                .environmentObject(theme)
        }
        .sheet(isPresented: $showKugouLogin) {
            KugouLoginSheet()
                .environmentObject(theme)
        }
        .sheet(isPresented: $showSynologyLogin) {
            SynologyLoginSheet()
                .environmentObject(theme)
        }
        .sheet(isPresented: $showSubsonicLogin) {
            SubsonicLoginSheet()
                .environmentObject(theme)
        }
        .sheet(isPresented: $showJellyfinLogin) {
            JellyfinLoginSheet()
                .environmentObject(theme)
        }
        .sheet(isPresented: $showWebDAVLogin) {
            WebDAVLoginSheet()
                .environmentObject(theme)
        }
        .confirmationDialog("退出网易云登录？", isPresented: $confirmNeteaseLogout, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) {
                auth.logout()
                WebLoginDataCleaner.clearNetEase()
                ToastCenter.shared.show("已退出网易云账号")
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("退出 QQ 音乐？", isPresented: $confirmQQLogout, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) {
                qqAuth.logout()
                WebLoginDataCleaner.clearQQMusic()
                ToastCenter.shared.show("已退出 QQ 音乐")
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("退出酷狗音乐？", isPresented: $confirmKugouLogout, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) {
                kugouAuth.logout()
                WebLoginDataCleaner.clearKugou()
                ToastCenter.shared.show("已退出酷狗音乐")
            }
            Button("取消", role: .cancel) {}
        }
    }

    /// 网易云账号卡片
    private var neteaseCard: some View {
        Button {
            ATMusicHaptics.tap()
            if auth.isLoggedIn { confirmNeteaseLogout = true } else { showNeteaseLogin = true }
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.white.opacity(0.06))
                        .frame(width: 48, height: 48)
                    Image("BrandNetease")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("网易云音乐")
                        .font(ATMusicFont.appFont(15, .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                    HStack(spacing: 6) {
                        Group {
                            if auth.isLoggedIn {
                                Text(auth.user?.nickname ?? NSLocalizedString("已登录", comment: ""))
                            } else {
                                Text(LocalizedStringKey("未登录 · 扫码登录同步歌单"))
                            }
                        }
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(Color.atmusicComment)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        if auth.isLoggedIn, let badge = auth.user?.vipBadge {
                            VIPBadgeView(text: badge)
                        }
                    }
                }
                Spacer()
                Text(auth.isLoggedIn ? "退出" : "登录")
                    .font(ATMusicFont.appFont(13, .medium))
                    .foregroundStyle(auth.isLoggedIn ? Color.red : Color.atmusicAmber)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background { ATMusicSurface(shape: Capsule()) }
            }
            .padding(14)
            .background {
                                ATMusicGlass(shape: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(GlassPressButtonStyle(scale: 0.97))
    }

    /// QQ 音乐账号卡片
    private var qqCard: some View {
        Button {
            ATMusicHaptics.tap()
            if qqAuth.isLoggedIn { confirmQQLogout = true } else { showQQLogin = true }
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.white.opacity(0.06))
                        .frame(width: 48, height: 48)
                    Image("BrandQQ")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("QQ 音乐")
                        .font(ATMusicFont.appFont(15, .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                    HStack(spacing: 6) {
                        Group {
                            if qqAuth.isLoggedIn {
                                Text(qqAuth.nickname.isEmpty ? NSLocalizedString("已登录", comment: "") : qqAuth.nickname)
                            } else {
                                Text(LocalizedStringKey("未登录 · 网页 / 扫码 / Cookie 登录"))
                            }
                        }
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(Color.atmusicComment)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        if qqAuth.isLoggedIn, let badge = qqAuth.vipBadge {
                            VIPBadgeView(text: badge)
                        }
                    }
                }
                Spacer()
                Text(qqAuth.isLoggedIn ? "退出" : "登录")
                    .font(ATMusicFont.appFont(13, .medium))
                    .foregroundStyle(qqAuth.isLoggedIn ? Color.red : Color.atmusicAmber)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background { ATMusicSurface(shape: Capsule()) }
            }
            .padding(14)
            .background {
                                ATMusicGlass(shape: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(GlassPressButtonStyle(scale: 0.97))
    }

    private var kugouCard: some View {
        Button {
            ATMusicHaptics.tap()
            if kugouAuth.isLoggedIn { confirmKugouLogout = true } else { showKugouLogin = true }
        } label: {
            HStack(spacing: 14) {
                Image("BrandKugou")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: Color(red: 0.08, green: 0.43, blue: 1.0).opacity(0.22), radius: 10, y: 4)
                VStack(alignment: .leading, spacing: 3) {
                    Text("酷狗音乐")
                        .font(ATMusicFont.appFont(15, .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                    HStack(spacing: 6) {
                        Group {
                            if kugouAuth.isLoggedIn {
                                Text(kugouAuth.nickname.isEmpty ? NSLocalizedString("已登录", comment: "") : kugouAuth.nickname)
                            } else {
                                Text(LocalizedStringKey("未登录 · App 扫码同步歌单"))
                            }
                        }
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(Color.atmusicComment)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        if kugouAuth.isLoggedIn, let badge = kugouAuth.vipBadge {
                            VIPBadgeView(text: badge)
                        }
                    }
                }
                Spacer()
                Text(kugouAuth.isLoggedIn ? "退出" : "登录")
                    .font(ATMusicFont.appFont(13, .medium))
                    .foregroundStyle(kugouAuth.isLoggedIn ? Color.red : Color.atmusicAmber)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background { ATMusicSurface(shape: Capsule()) }
            }
            .padding(14)
            .background {
                ATMusicGlass(shape: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(GlassPressButtonStyle(scale: 0.97))
    }

    private var synologyCard: some View {
        Button {
            ATMusicHaptics.tap()
            showSynologyLogin = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "server.rack")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color.atmusicAmber)
                    .frame(width: 48, height: 48)
                    .background(Color.atmusicAmber.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("群晖 NAS")
                        .font(ATMusicFont.appFont(15, .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                    Text(synology.isLoggedIn
                         ? (synology.account.isEmpty ? "已连接 Audio Station" : "已连接 · \(synology.account)")
                         : "未连接 · 配置 Audio Station")
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(Color.atmusicComment)
                        .lineLimit(2)
                }
                Spacer()
                Text(synology.isLoggedIn ? "设置" : "登录")
                    .font(ATMusicFont.appFont(13, .medium))
                    .foregroundStyle(synology.isLoggedIn ? Color.atmusicAmber : Color.atmusicAmber)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background { ATMusicSurface(shape: Capsule()) }
            }
            .padding(14)
            .background { ATMusicGlass(shape: RoundedRectangle(cornerRadius: 20, style: .continuous)) }
            .contentShape(Rectangle())
        }
        .buttonStyle(GlassPressButtonStyle(scale: 0.97))
    }

    private var subsonicCard: some View {
        Button {
            ATMusicHaptics.tap()
            showSubsonicLogin = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "server.rack")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color.atmusicAmber)
                    .frame(width: 48, height: 48)
                    .background(Color.atmusicAmber.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Subsonic")
                        .font(ATMusicFont.appFont(15, .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                    Text(subsonic.isLoggedIn
                         ? (subsonic.account.isEmpty ? "已连接 Subsonic 服务器" : "已连接 · \(subsonic.account)")
                         : "未连接 · 配置 Subsonic 服务器")
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(Color.atmusicComment)
                        .lineLimit(2)
                }
                Spacer()
                Text(subsonic.isLoggedIn ? "设置" : "登录")
                    .font(ATMusicFont.appFont(13, .medium))
                    .foregroundStyle(Color.atmusicAmber)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background { ATMusicSurface(shape: Capsule()) }
            }
            .padding(14)
            .background { ATMusicGlass(shape: RoundedRectangle(cornerRadius: 20, style: .continuous)) }
            .contentShape(Rectangle())
        }
        .buttonStyle(GlassPressButtonStyle(scale: 0.97))
    }

    private var jellyfinCard: some View {
        Button {
            ATMusicHaptics.tap()
            showJellyfinLogin = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "play.tv.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color.atmusicAmber)
                    .frame(width: 48, height: 48)
                    .background(Color.atmusicAmber.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Jellyfin")
                        .font(ATMusicFont.appFont(15, .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                    Text(jellyfin.isLoggedIn
                         ? (jellyfin.account.isEmpty ? "已连接 Jellyfin 服务器" : "已连接 · \(jellyfin.account)")
                         : "未连接 · 配置 Jellyfin 服务器")
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(Color.atmusicComment)
                        .lineLimit(2)
                }
                Spacer()
                Text(jellyfin.isLoggedIn ? "设置" : "登录")
                    .font(ATMusicFont.appFont(13, .medium))
                    .foregroundStyle(Color.atmusicAmber)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background { ATMusicSurface(shape: Capsule()) }
            }
            .padding(14)
            .background { ATMusicGlass(shape: RoundedRectangle(cornerRadius: 20, style: .continuous)) }
            .contentShape(Rectangle())
        }
        .buttonStyle(GlassPressButtonStyle(scale: 0.97))
    }

    private var webdavCard: some View {
        Button {
            ATMusicHaptics.tap()
            showWebDAVLogin = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "folder.fill.badge.gearshape")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color.atmusicAmber)
                    .frame(width: 48, height: 48)
                    .background(Color.atmusicAmber.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("WebDAV")
                        .font(ATMusicFont.appFont(15, .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                    Text(webdav.isLoggedIn
                         ? (webdav.account.isEmpty ? "已连接 WebDAV 服务器" : "已连接 · \(webdav.account)")
                         : "未连接 · 配置 WebDAV 服务器")
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(Color.atmusicComment)
                        .lineLimit(2)
                }
                Spacer()
                Text(webdav.isLoggedIn ? "设置" : "登录")
                    .font(ATMusicFont.appFont(13, .medium))
                    .foregroundStyle(Color.atmusicAmber)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background { ATMusicSurface(shape: Capsule()) }
            }
            .padding(14)
            .background { ATMusicGlass(shape: RoundedRectangle(cornerRadius: 20, style: .continuous)) }
            .contentShape(Rectangle())
        }
        .buttonStyle(GlassPressButtonStyle(scale: 0.97))
    }

}

// MARK: - 设置页（外观 + 歌词翻译，从「我的」右上角齿轮进入）

struct SettingsView: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var auth: AuthStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("atmusic.uiStyle") private var uiStyleRaw = ATMusicUIStyle.liquid.rawValue
    @AppStorage("atmusic.themeMode") private var themeModeRaw = ATMusicThemeMode.system.rawValue
    @AppStorage("atmusic.language") private var languageRaw = AppLanguage.chinese.rawValue
    @AppStorage("atmusic.homeWallpaperBlur") private var homeWallpaperBlur = 0.0
    /// 底栏是否显示文字（关闭后只显示图标）
    @AppStorage("atmusic.tabLabelsVisible") private var tabLabelsVisible = true
    @AppStorage("atmusic.legacyTabCornerRadius") private var legacyTabCornerRadius = 32.0
    @AppStorage("atmusic.legacyTabWidth") private var legacyTabWidth = 356.0
    @AppStorage("atmusic.legacyTabOffsetX") private var legacyTabOffsetX = 0.0
    @AppStorage("atmusic.legacyTabOffsetY") private var legacyTabOffsetY = 0.0
    /// 第三方音源播放会员歌成功时提醒，默认开启
    @AppStorage("atmusic.showThirdPartyVIPNotice") private var showThirdPartyVIPNotice = true
    @AppStorage("atmusic.showSongVIPBadge") private var showSongVIPBadge = true
    /// 音频会话：允许与其他 App 音频同时播放
    @AppStorage("atmusic.audio.mixothers.v1") private var mixesWithOthers = false
    @AppStorage("atmusic.audioQuality") private var playbackAudioQualityRaw = ATMusicAudioQuality.hires.rawValue
    @AppStorage(ATMusicHaptics.enabledKey) private var hapticsEnabled = true
    @AppStorage("atmusic.playback.autoResumeLast") private var autoResumeLastPlayback = false
    @AppStorage("atmusic.swipeSwitchSong") private var swipeSwitchSong = true
    @AppStorage("atmusic.playback.autoSkipOnFailure") private var autoSkipOnFailure = true
    @AppStorage(MusicCacheManager.prefetchEnabledKey) private var prefetchNextSong = true
    @AppStorage(MusicCacheManager.limitMBKey) private var musicCacheLimitMB = MusicCacheManager.defaultLimitMB
    @ObservedObject private var musicCache = MusicCacheManager.shared
    @AppStorage("atmusic.download.wifiOnly") private var downloadWifiOnly = true
    @AppStorage("atmusic.download.lanConcurrency") private var lanConcurrency = 5
    @AppStorage("atmusic.download.wanConcurrency") private var wanConcurrency = 2
    @AppStorage(ThirdPartyAudioQuality.downloadStorageKey) private var downloadQualityRaw = ThirdPartyAudioQuality.kb320.rawValue
    @AppStorage("atmusic.nas.uploadRoot") private var nasUploadRoot = "/music/ATMusic"
    @AppStorage("atmusic.nas.uploadHierarchy") private var nasUploadHierarchy = true
    @AppStorage("atmusic.download.pauseOnLowBattery") private var pauseOnLowBattery = true
    @AppStorage("atmusic.download.diskGuard") private var diskGuardEnabled = true
    @AppStorage("atmusic.labelColorHex") private var labelColorHex = ""
    @AppStorage("atmusic.pauseHomeRendering") private var homeRenderingPaused = false
    @AppStorage("atmusic.homeHideUsername") private var homeHideUsername = false
    @AppStorage("atmusic.homeHeaderHideSort") private var homeHeaderHideSort = false
    @AppStorage("atmusic.homeHeaderHideRefresh") private var homeHeaderHideRefresh = true
    @AppStorage(PlatformPreferenceStore.hidePickerKey) private var hidePlatformPicker = false
    @AppStorage("atmusic.hideDynamicEffects") private var hideDynamicEffects = false
    @AppStorage("atmusic.hideAppearanceToggle") private var hideAppearanceToggle = false
    @ObservedObject private var sourceStore = UnblockSourceStore.shared
    @ObservedObject private var equalizer = ATMusicEqualizer.shared
    @AppStorage(ThirdPartyAudioQuality.storageKey) private var thirdPartyAudioQualityRaw = ThirdPartyAudioQuality.kb320.rawValue
    @ObservedObject private var platformPrefs = PlatformPreferenceStore.shared
    @ObservedObject private var qqAuth = QQMusicAuth.shared
    @ObservedObject private var kugouAuth = KugouMusicAuth.shared
    @ObservedObject private var synology = SynologyAPI.shared
    @ObservedObject private var subsonic = SubsonicAPI.shared
    @ObservedObject private var jellyfin = JellyfinAPI.shared
    @ObservedObject private var webdav = WebDAVAPI.shared

    @State private var moreAppearanceExpanded = false
    @State private var platformExpanded = false
    @State private var playbackExpanded = false
    @State private var thirdPartySourceExpanded = false
    @State private var cacheStorageExpanded = false
    @State private var showWallpaperPicker = false
    @State private var wallpaperAppearanceTarget: ATMusicWallpaperAppearance = .light
    @State private var showFontImporter = false
    /// 更新日志
    @State private var showChangelog = false
    @State private var backupDoc: BackupDocument?
    @State private var showExportBackup = false
    @State private var showRestorePicker = false
    @State private var pendingRestore: [String: Any]?
    @State private var showRestoreConfirm = false
    @State private var showSourceManager = false
    @State private var showEqualizer = false
    @State private var backupExpanded = false
    @State private var backupIncludeAccounts = false
    @State private var backupIncludeWallpapers = false
    @State private var backupMessage: String?
    /// 日志
    @State private var showLogViewer = false
    @State private var showAccountHub = false
    @State private var settingsQuery = ""
    // 设置页 5 张大卡片折叠状态（默认全部折叠，用户改过之后记住他的选择）
    @AppStorage("atmusic.settingsCard.account.collapsed") private var accountCardCollapsed = true
    @AppStorage("atmusic.settingsCard.audio.collapsed") private var audioCardCollapsed = true
    @AppStorage("atmusic.settingsCard.source.collapsed") private var sourceCardCollapsed = true
    @AppStorage("atmusic.settingsCard.appearance.collapsed") private var appearanceCardCollapsed = true
    @AppStorage("atmusic.settingsCard.storage.collapsed") private var storageCardCollapsed = true
    @State private var sourceQualityExpanded = false

    private var isNativeClean: Bool { uiStyleRaw == ATMusicUIStyle.nativeClean.rawValue }
    /// 主题强调色必须同时驱动原版简洁样式和其他样式；红色只保留给删除、退出等破坏性操作。
    private var settingsIconColor: Color { .atmusicAmber }

    private var themeMode: ATMusicThemeMode {
        ATMusicThemeMode(rawValue: themeModeRaw) ?? .system
    }

    private var customSourceCount: Int {
        sourceStore.managementVisibleSources.count
    }

    private var thirdPartyAudioQualityOptions: [ThirdPartyAudioQuality] {
        let options = sourceStore.availableThirdPartyQualities()
        return options.isEmpty ? ThirdPartyAudioQuality.allCases : options
    }

    private var thirdPartyAudioQualitySelection: Binding<ThirdPartyAudioQuality> {
        Binding(
            get: {
                let stored = ThirdPartyAudioQuality(sourceValue: thirdPartyAudioQualityRaw) ?? .kb320
                return thirdPartyAudioQualityOptions.first(where: { $0 == stored }) ?? thirdPartyAudioQualityOptions.first ?? .kb320
            },
            set: { newValue in
                thirdPartyAudioQualityRaw = newValue.rawValue
            }
        )
    }

    private var thirdPartyAudioQualityTitle: String {
        atmusicLocalized("第三方音源音质", "Third-party source quality")
    }

    private var thirdPartyAudioQualityHint: String {
        atmusicLocalized("会优先按所选音质解析第三方音源，不可用时会自动降级。", "Third-party sources will try the selected quality first and downgrade automatically when unavailable.")
    }

    private var thirdPartyAudioQualityOptionsSignature: String {
        thirdPartyAudioQualityOptions.map(\.rawValue).joined(separator: ",")
    }

    private func normalizeThirdPartyAudioQualitySelection() {
        let valid = thirdPartyAudioQualityOptions.first(where: { $0.rawValue == thirdPartyAudioQualityRaw }) ?? thirdPartyAudioQualityOptions.first ?? .kb320
        if valid.rawValue != thirdPartyAudioQualityRaw {
            thirdPartyAudioQualityRaw = valid.rawValue
        }
    }

    private var playbackAudioQualitySelection: Binding<ATMusicAudioQuality> {
        Binding(
            get: { ATMusicAudioQuality(rawValue: playbackAudioQualityRaw) ?? .hires },
            set: { playbackAudioQualityRaw = $0.rawValue }
        )
    }

    private var musicCacheUsageText: String {
        ByteCountFormatter.string(fromByteCount: musicCache.usageBytes, countStyle: .file)
    }

    private var musicCacheLimitText: String {
        ByteCountFormatter.string(fromByteCount: Int64(musicCacheLimitMB) * 1_048_576, countStyle: .file)
    }

    private func musicCacheOptionTitle(_ value: Int) -> String {
        if value < 1024 { return "\(value) MB" }
        return value % 1024 == 0 ? "\(value / 1024) GB" : String(format: "%.1f GB", Double(value) / 1024.0)
    }

    private var musicCacheSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $prefetchNextSong) {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.atmusicAmber)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(atmusicLocalized("下一首提前缓存", "Prefetch next song"))
                            .font(ATMusicFont.appFont(15))
                            .foregroundStyle(Color.atmusicLabel)
                        Text(atmusicLocalized("当前歌曲稳定播放后，后台完整缓存下一首，切歌优先本地播放", "Cache the next track after playback stabilizes, then play it locally when advancing."))
                            .font(ATMusicFont.appFont(11))
                            .foregroundStyle(Color.atmusicComment)
                    }
                }
            }
            .toggleStyle(.switch)
            .tint(Color.atmusicAmber)
            .onChange(of: prefetchNextSong) { value in
                musicCache.setPrefetchEnabled(value)
            }

            Divider().overlay(Color.atmusicComment.opacity(0.15))

            HStack(spacing: 12) {
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.atmusicAmber)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(atmusicLocalized("音乐缓存空间", "Music cache size"))
                        .font(ATMusicFont.appFont(15))
                        .foregroundStyle(Color.atmusicLabel)
                    Text(atmusicLocalized("已使用 \(musicCacheUsageText) / \(musicCacheLimitText) · \(musicCache.cachedSongCount) 首", "Used \(musicCacheUsageText) / \(musicCacheLimitText) · \(musicCache.cachedSongCount) tracks"))
                        .font(ATMusicFont.appFont(11))
                        .foregroundStyle(Color.atmusicComment)
                }
                Spacer()
                Menu {
                    ForEach(MusicCacheManager.limitOptionsMB, id: \.self) { value in
                        Button {
                            musicCacheLimitMB = value
                            musicCache.setLimitMB(value)
                            ATMusicHaptics.select()
                        } label: {
                            if musicCacheLimitMB == value {
                                Label(musicCacheOptionTitle(value), systemImage: "checkmark")
                            } else {
                                Text(musicCacheOptionTitle(value))
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(musicCacheOptionTitle(musicCacheLimitMB))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(ATMusicFont.appFont(12, .semibold))
                    .foregroundStyle(Color.atmusicAmber)
                }
            }

            Button(role: .destructive) {
                let removed = musicCache.clearPlaybackCache()
                ToastCenter.shared.show(atmusicLocalized("已清理 \(removed) 首音乐缓存", "Cleared cache for \(removed) tracks"))
                ATMusicHaptics.tap()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "trash")
                    Text(atmusicLocalized("清除音乐缓存", "Clear music cache"))
                    Spacer()
                    if musicCache.usageBytes > 0 {
                        Text(musicCacheUsageText)
                            .font(ATMusicFont.appFont(11))
                            .foregroundStyle(Color.atmusicComment)
                    }
                }
                .font(ATMusicFont.appFont(13, .semibold))
            }
            .disabled(musicCache.usageBytes == 0)
        }
    }

    // MARK: - 离线下载与 NAS 传输设置
    private var transferAndOfflineSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.atmusicAmber)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("离线下载与 NAS 传输")
                            .font(ATMusicFont.appFont(14, .bold))
                            .foregroundStyle(Color.atmusicLabel)
                        Text("双向传输")
                            .font(ATMusicFont.appFont(10, .semibold))
                            .foregroundStyle(Color.atmusicAmber)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.atmusicAmber.opacity(0.12)))
                    }
                    Text("控制离线下载品质、群晖 NAS 归档目录与网络流量保护")
                        .font(ATMusicFont.appFont(10))
                        .foregroundStyle(Color.atmusicComment)
                        .lineLimit(1)
                }
                Spacer()
            }

            Toggle(isOn: $downloadWifiOnly) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("仅在 Wi-Fi 下下载与上传")
                        .font(ATMusicFont.appFont(14))
                        .foregroundStyle(Color.atmusicLabel)
                    Text("开启后移动蜂窝网络下自动拦截并暂停传输，保护数据流量")
                        .font(ATMusicFont.appFont(11))
                        .foregroundStyle(Color.atmusicComment)
                }
            }
            .toggleStyle(.switch)
            .tint(Color.atmusicAmber)

            HStack {
                Text("默认离线下载音质")
                    .font(ATMusicFont.appFont(14))
                    .foregroundStyle(Color.atmusicLabel)
                Spacer()
                Menu {
                    ForEach([ThirdPartyAudioQuality.kb128, .kb320, .flac, .hires], id: \.self) { q in
                        Button {
                            downloadQualityRaw = q.rawValue
                            ATMusicHaptics.select()
                        } label: {
                            if downloadQualityRaw == q.rawValue {
                                Label(q.displayName, systemImage: "checkmark")
                            } else {
                                Text(q.displayName)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        let cur = ThirdPartyAudioQuality(sourceValue: downloadQualityRaw) ?? .kb320
                        Text(cur.displayName)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(ATMusicFont.appFont(12, .semibold))
                    .foregroundStyle(Color.atmusicAmber)
                }
            }

            HStack {
                Text("局域网极速并发数")
                    .font(ATMusicFont.appFont(14))
                    .foregroundStyle(Color.atmusicLabel)
                Spacer()
                Menu {
                    ForEach(2...5, id: \.self) { n in
                        Button("\(n) 任务并行") {
                            lanConcurrency = n
                            ATMusicHaptics.select()
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("\(lanConcurrency) 任务")
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(ATMusicFont.appFont(12, .semibold))
                    .foregroundStyle(Color.atmusicAmber)
                }
            }

            HStack {
                Text("外网传输并发数")
                    .font(ATMusicFont.appFont(14))
                    .foregroundStyle(Color.atmusicLabel)
                Spacer()
                Menu {
                    ForEach(1...3, id: \.self) { n in
                        Button("\(n) 任务并行") {
                            wanConcurrency = n
                            ATMusicHaptics.select()
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("\(wanConcurrency) 任务")
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(ATMusicFont.appFont(12, .semibold))
                    .foregroundStyle(Color.atmusicAmber)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("NAS 上传存储根目录")
                    .font(ATMusicFont.appFont(14))
                    .foregroundStyle(Color.atmusicLabel)
                TextField("/music/ATMusic", text: $nasUploadRoot)
                    .font(ATMusicFont.appFont(12, .regular, .monospaced))
                    .padding(8)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }

            Toggle(isOn: $nasUploadHierarchy) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("按「歌手/专辑」分目录归档")
                        .font(ATMusicFont.appFont(14))
                        .foregroundStyle(Color.atmusicLabel)
                    Text("开启时生成 /歌手/专辑/曲目.flac；关闭时平铺到根目录")
                        .font(ATMusicFont.appFont(11))
                        .foregroundStyle(Color.atmusicComment)
                }
            }
            .toggleStyle(.switch)
            .tint(Color.atmusicAmber)

            Toggle(isOn: $pauseOnLowBattery) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("低电量模式自动暂停传输")
                        .font(ATMusicFont.appFont(14))
                        .foregroundStyle(Color.atmusicLabel)
                    Text("系统处于低电量模式或电量 < 20% 时暂停以保护续航")
                        .font(ATMusicFont.appFont(11))
                        .foregroundStyle(Color.atmusicComment)
                }
            }
            .toggleStyle(.switch)
            .tint(Color.atmusicAmber)

            Toggle(isOn: $diskGuardEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("磁盘空间警戒线保护 (2GB)")
                        .font(ATMusicFont.appFont(14))
                        .foregroundStyle(Color.atmusicLabel)
                    Text("剩余空间低于 2GB 时拒绝并暂停新下载，保护系统稳定")
                        .font(ATMusicFont.appFont(11))
                        .foregroundStyle(Color.atmusicComment)
                }
            }
            .toggleStyle(.switch)
            .tint(Color.atmusicAmber)
        }
    }

    // MARK: - 专业音质卡片选择器（全面对标网易云与 QQ 音乐）
    private var playbackQualitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.atmusicAmber)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(atmusicLocalized("播放音质选择", "Audio Quality Preference"))
                            .font(ATMusicFont.appFont(14, .bold))
                            .foregroundStyle(Color.atmusicLabel)
                        Text("对标网易/QQ")
                            .font(ATMusicFont.appFont(10, .semibold))
                            .foregroundStyle(Color.atmusicAmber)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.atmusicAmber.opacity(0.12)))
                    }
                    Text(atmusicLocalized("支持智能自适应与最高 24bit/192kHz 母带音质，不可用时自动顺畅降级", "Auto-adapts to best network & device output up to 24bit/192kHz Master."))
                        .font(ATMusicFont.appFont(10))
                        .foregroundStyle(Color.atmusicComment)
                        .lineLimit(1)
                }
                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(ATMusicAudioQuality.allCases) { quality in
                        let selected = playbackAudioQualitySelection.wrappedValue == quality
                        Button {
                            playbackAudioQualitySelection.wrappedValue = quality
                            ATMusicHaptics.select()
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 5) {
                                    Text(quality.badgeText)
                                        .font(.system(size: 10, weight: .black, design: .rounded))
                                        .foregroundStyle(selected ? Color.white : Color.atmusicAmber)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2.5)
                                        .background {
                                            if selected {
                                                Capsule().fill(
                                                    LinearGradient(
                                                        colors: [Color.atmusicAmber, Color.orange],
                                                        startPoint: .topLeading,
                                                        endPoint: .bottomTrailing
                                                    )
                                                )
                                            } else {
                                                Capsule().fill(Color.atmusicAmber.opacity(0.14))
                                            }
                                        }

                                    Spacer(minLength: 0)

                                    if selected {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(Color.atmusicAmber)
                                    }
                                }

                                Text(quality.displayName)
                                    .font(ATMusicFont.appFont(13, selected ? .bold : .medium))
                                    .foregroundStyle(selected ? Color.atmusicLabel : Color.atmusicLabel.opacity(0.85))

                                Text(quality.subtitle)
                                    .font(ATMusicFont.appFont(10))
                                    .foregroundStyle(selected ? Color.atmusicComment : Color.atmusicComment.opacity(0.75))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 11)
                            .padding(.vertical, 9)
                            .frame(width: 156, alignment: .leading)
                            .background {
                                audioQualityCardBackground(selected: selected)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 1)
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private func audioQualityCardBackground(selected: Bool) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: isNativeClean ? 14 : (uiStyleRaw == "compact" ? 12 : 16),
            style: .continuous
        )
        if isNativeClean {
            shape
                .fill(selected ? Color.atmusicAmber.opacity(0.12) : Color.atmusicGlassFill)
                .overlay {
                    shape.stroke(selected ? Color.atmusicAmber : Color.clear, lineWidth: 1.2)
                }
        } else if uiStyleRaw == "clear" {
            shape
                .fill(selected ? Color.atmusicAmber.opacity(0.15) : Color.white.opacity(0.06))
                .overlay {
                    shape.stroke(selected ? Color.atmusicAmber.opacity(0.8) : Color.white.opacity(0.2), lineWidth: selected ? 1.2 : 0.8)
                }
        } else if uiStyleRaw == "compact" {
            shape
                .fill(selected ? Color.atmusicAmber.opacity(0.12) : Color.primary.opacity(0.04))
                .overlay {
                    shape.stroke(selected ? Color.atmusicAmber : Color.primary.opacity(0.1), lineWidth: 0.8)
                }
        } else {
            shape
                .fill(selected ? Color.atmusicAmber.opacity(0.16) : Color.white.opacity(0.07))
                .overlay {
                    shape.stroke(
                        selected ?
                        LinearGradient(colors: [Color.atmusicAmber, Color.orange.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing) :
                        LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: selected ? 1.4 : 0.8
                    )
                }
                .shadow(color: selected ? Color.atmusicAmber.opacity(0.25) : Color.clear, radius: 6, y: 2)
        }
    }

    // MARK: - 5 大高内聚核心卡片容器（严格响应四种 UI 风格）
    private func settingsCardContainer<Content: View>(
        title: String,
        icon: String,
        subtitle: String? = nil,
        collapsed: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let cornerRadius: CGFloat = isNativeClean ? 20 : (uiStyleRaw == "compact" ? 14 : (uiStyleRaw == "clear" ? 18 : 22))
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // 搜索设置项时强制全部展开；清空搜索后恢复用户之前的折叠状态
        let isSearching = !settingsQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let isCollapsed = !isSearching && collapsed.wrappedValue

        return VStack(alignment: .leading, spacing: uiStyleRaw == "compact" ? 10 : 13) {
            Button {
                ATMusicHaptics.tap()
                withAnimation(.easeInOut(duration: 0.25)) {
                    collapsed.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: uiStyleRaw == "compact" ? 13 : 15, weight: .semibold))
                        .foregroundStyle(Color.atmusicAmber)
                        .frame(width: uiStyleRaw == "compact" ? 26 : 30, height: uiStyleRaw == "compact" ? 26 : 30)
                        .background(Color.atmusicAmber.opacity(0.12), in: Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalizedStringKey(title))
                            .font(ATMusicFont.appFont(uiStyleRaw == "compact" ? 15 : 16, .bold))
                            .foregroundStyle(Color.atmusicLabel)
                        if let subtitle, !subtitle.isEmpty {
                            Text(LocalizedStringKey(subtitle))
                                .font(ATMusicFont.appFont(uiStyleRaw == "compact" ? 10 : 11))
                                .foregroundStyle(Color.atmusicComment)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.atmusicComment)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .animation(.easeInOut(duration: 0.25), value: isCollapsed)
                }
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                content()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isCollapsed)
        .padding(.horizontal, uiStyleRaw == "compact" ? 12 : 15)
        .padding(.vertical, uiStyleRaw == "compact" ? 11 : 14)
        .background {
            ATMusicGlass(shape: shape)
        }
        .clipShape(shape)
        .overlay {
            if uiStyleRaw == "clear" {
                shape.stroke(Color.white.opacity(0.22), lineWidth: 0.8)
            } else if uiStyleRaw == "compact" {
                shape.stroke(Color.primary.opacity(0.08), lineWidth: 0.6)
            } else if !isNativeClean {
                shape.stroke(Color.white.opacity(0.12), lineWidth: 0.6)
            }
        }
        .atmusicCardShadow(radius: isNativeClean ? 3 : (uiStyleRaw == "compact" ? 4 : 8), y: isNativeClean ? 1 : 3)
    }

    private var settingsCardDivider: some View {
        Divider()
            .overlay(Color.atmusicComment.opacity(0.12))
            .padding(.vertical, 2)
    }

    // ① 卡片 1：账号与多平台服务
    private var accountAndPlatformCard: AnyView {
        AnyView(
        settingsCardContainer(
            title: "账号与多平台服务",
            icon: "person.crop.circle.badge.checkmark",
            subtitle: "统一管理网易云、QQ 音乐、酷狗与群晖服务登录与检索偏好",
            collapsed: $accountCardCollapsed,
        ) {
            VStack(spacing: 12) {
                accountSettingsRow

                settingsCardDivider

                VStack(alignment: .leading, spacing: 6) {
                    Text("平台连接状态")
                        .font(ATMusicFont.appFont(12, .semibold))
                        .foregroundStyle(Color.atmusicComment)
                    platformConnectivityBar
                }

                settingsCardDivider

                platformSection
            }
        }
        )
    }

    // ② 卡片 2：音频品质与播放体验
    private var audioQualityAndPlaybackCard: AnyView {
        AnyView(
        settingsCardContainer(
            title: "音频品质与播放体验",
            icon: "waveform.badge.magnifyingglass",
            subtitle: "对标网易与QQ高规格音质架构、均衡器调音与核心播放控制",
            collapsed: $audioCardCollapsed,
        ) {
            VStack(spacing: 12) {
                playbackQualitySection

                settingsCardDivider

                // 均衡器快捷入口行
                equalizerSection

                settingsCardDivider

                // 播放核心行为控制
                VStack(spacing: 10) {
                    Toggle(isOn: $autoResumeLastPlayback) {
                        HStack(spacing: 10) {
                            Image(systemName: "play.square.stack.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.atmusicAmber)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(atmusicLocalized("启动时自动播放上次歌曲", "Auto-play last song on launch"))
                                    .font(ATMusicFont.appFont(14))
                                    .foregroundStyle(Color.atmusicLabel)
                                Text(atmusicLocalized("打开应用后自动恢复上次未听完的歌曲", "Resume unfinished track on startup."))
                                    .font(ATMusicFont.appFont(11))
                                    .foregroundStyle(Color.atmusicComment)
                            }
                        }
                    }
                    .toggleStyle(.switch)
                    .tint(Color.atmusicAmber)

                    Divider().overlay(Color.atmusicComment.opacity(0.10))

                    Toggle(isOn: $mixesWithOthers) {
                        HStack(spacing: 10) {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.atmusicAmber)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("与其他音频同时播放")
                                    .font(ATMusicFont.appFont(14))
                                    .foregroundStyle(Color.atmusicLabel)
                                Text("允许后台游戏音效或导航伴奏发声")
                                    .font(ATMusicFont.appFont(11))
                                    .foregroundStyle(Color.atmusicComment)
                            }
                        }
                    }
                    .toggleStyle(.switch)
                    .tint(Color.atmusicAmber)
                    .onChange(of: mixesWithOthers) { value in
                        PlayerManager.applyAudioMixPreference(value)
                    }

                    Divider().overlay(Color.atmusicComment.opacity(0.10))

                    Toggle(isOn: $swipeSwitchSong) {
                        HStack(spacing: 10) {
                            Image(systemName: "hand.draw.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.atmusicAmber)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("左右滑动切歌")
                                    .font(ATMusicFont.appFont(14))
                                    .foregroundStyle(Color.atmusicLabel)
                                Text("左滑下一首，右滑上一首")
                                    .font(ATMusicFont.appFont(11))
                                    .foregroundStyle(Color.atmusicComment)
                            }
                        }
                    }
                    .toggleStyle(.switch)
                    .tint(Color.atmusicAmber)

                    Divider().overlay(Color.atmusicComment.opacity(0.10))

                    Toggle(isOn: $autoSkipOnFailure) {
                        HStack(spacing: 10) {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.atmusicAmber)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("播放失败自动下一首")
                                    .font(ATMusicFont.appFont(14))
                                    .foregroundStyle(Color.atmusicLabel)
                                Text("当前歌曲解析失败或播放地址失效时，自动跳到下一首")
                                    .font(ATMusicFont.appFont(11))
                                    .foregroundStyle(Color.atmusicComment)
                            }
                        }
                    }
                    .toggleStyle(.switch)
                    .tint(Color.atmusicAmber)

                    Divider().overlay(Color.atmusicComment.opacity(0.10))

                    Toggle(isOn: $showSongVIPBadge) {
                        HStack(spacing: 10) {
                            Image(systemName: "crown.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.atmusicAmber)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("歌曲列表显示 VIP 角标")
                                    .font(ATMusicFont.appFont(14))
                                    .foregroundStyle(Color.atmusicLabel)
                                Text("清晰标识各平台的会员专享歌曲")
                                    .font(ATMusicFont.appFont(11))
                                    .foregroundStyle(Color.atmusicComment)
                            }
                        }
                    }
                    .toggleStyle(.switch)
                    .tint(Color.atmusicAmber)

                    Divider().overlay(Color.atmusicComment.opacity(0.10))

                    Toggle(isOn: $hapticsEnabled) {
                        HStack(spacing: 10) {
                            Image(systemName: "iphone.radiowaves.left.and.right")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.atmusicAmber)
                                .frame(width: 22)
                            Text(atmusicLocalized("系统触感反馈", "Haptic Feedback"))
                                .font(ATMusicFont.appFont(14))
                                .foregroundStyle(Color.atmusicLabel)
                        }
                    }
                    .toggleStyle(.switch)
                    .tint(Color.atmusicAmber)
                }
            }
        }
        )
    }

    // ③ 卡片 3：第三方音源与解封扩展
    private var thirdPartySourcesCard: AnyView {
        AnyView(
        settingsCardContainer(
            title: "第三方音源与解封扩展",
            icon: "shippingbox.and.arrow.backward.fill",
            subtitle: "本地 JavaScript 脚本订阅、第三方音质调度与会员歌解封",
            collapsed: $sourceCardCollapsed,
        ) {
            thirdPartySourceSection
        }
        )
    }

    // ④ 卡片 4：界面外观与主页定制
    private var appearanceAndPersonalizationCard: AnyView {
        AnyView(
        settingsCardContainer(
            title: "界面外观与主页定制",
            icon: "paintpalette.fill",
            subtitle: "主题模式、四套全局 UI 风格、壁纸与高自由度布局定制",
            collapsed: $appearanceCardCollapsed,
        ) {
            appearanceSection
        }
        )
    }

    // ⑤ 卡片 5：存储、数据与关于
    private var storageDataAndAboutCard: AnyView {
        AnyView(
        settingsCardContainer(
            title: "存储、数据与关于",
            icon: "internaldrive.fill",
            subtitle: "音乐缓存空间、配置备份恢复、诊断日志与版本说明",
            collapsed: $storageCardCollapsed,
        ) {
            VStack(spacing: 12) {
                musicCacheSection

                settingsCardDivider

                transferAndOfflineSection

                settingsCardDivider

                backupSection

                settingsCardDivider

                logSection

                settingsCardDivider

                runtimeInfoSection

                settingsCardDivider

                referenceCheckUpdateRow
            }
        }
        )
    }

    private var settingsSearchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.atmusicComment)
            TextField("搜索设置项（音质、主题、账号、音源…）", text: $settingsQuery)
                .font(ATMusicFont.appFont(14))
                .tint(Color.atmusicAmber)
            if !settingsQuery.isEmpty {
                Button {
                    settingsQuery = ""
                    ATMusicHaptics.tap()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.atmusicComment)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background {
            ATMusicSurface(shape: Capsule())
        }
        .padding(.bottom, 2)
    }

    private func settingsMatches(_ text: String) -> Bool {
        settingsQuery.isEmpty || text.localizedStandardContains(settingsQuery)
    }

    var body: some View {
        NavigationStack {
            settingsBodyContent
        }
        .preferredColorScheme(themeMode.colorScheme)
        .onAppear {
            wallpaperAppearanceTarget = colorScheme == .dark ? .dark : .light
        }
        .sheet(isPresented: $showWallpaperPicker) {
            WallpaperPhotoPicker { data in
                theme.addWallpaper(data, for: wallpaperAppearanceTarget.colorScheme)
                ATMusicHaptics.success()
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showFontImporter) {
            FontDocumentPicker { url in
                installFont(from: url)
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showChangelog) {
            ChangelogListView()
                .environmentObject(theme)
        }
        .sheet(isPresented: $showAccountHub) {
            AccountHubSheet()
                .environmentObject(auth)
                .environmentObject(theme)
        }
        .fileExporter(
            isPresented: $showExportBackup,
            document: backupDoc,
            contentType: .json,
            defaultFilename: "ATMusic设置备份-\(Self.backupDateString())"
        ) { result in
            switch result {
            case .success:
                backupMessage = "配置备份已导出"
                ToastCenter.shared.show("配置备份已导出")
            case .failure(let error):
                backupMessage = "导出失败：\(error.localizedDescription)"
                ToastCenter.shared.show("导出失败")
            }
        }
        .sheet(isPresented: $showLogViewer) {
            LogViewerSheet(importedText: nil)
                .environmentObject(theme)
        }
        .sheet(isPresented: $showSourceManager) {
            ThirdPartySourceManagerSheet()
                .environmentObject(theme)
        }
        .sheet(isPresented: $showEqualizer) {
            EqualizerSettingsView()
                .environmentObject(theme)
        }
        .fullScreenCover(isPresented: $showRestorePicker) {
            BackupDocumentPicker { url in
                handleBackupImport(url)
            }
            .ignoresSafeArea()
        }
        .confirmationDialog("导入备份将覆盖当前部分设置，是否继续？", isPresented: $showRestoreConfirm, titleVisibility: .visible) {
            Button("恢复", role: .destructive) {
                applyRestore(pendingRestore)
            }
            Button("取消", role: .cancel) {}
        }
        .onAppear {
            homeRenderingPaused = true
        }
        .onDisappear {
            homeRenderingPaused = false
        }
    }


    private var settingsBodyContent: AnyView {
        AnyView(
            ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
                ScrollView {
                    VStack(alignment: .leading, spacing: isNativeClean ? 18 : 14) {
                        // 顶部快捷搜索栏
                        settingsSearchBar

                        // 5 大高内聚核心卡片：通过 settingsCard 闭包 + AnyView 彻底隔断泛型深度
                        settingsCard("账号 登录 平台 网易云 QQ音乐 酷狗 群晖") {
                            accountAndPlatformCard
                        }
                        settingsCard("播放 音质 均衡器 混音 续播 Hi-Res 无损 杜比 母带 触感 VIP") {
                            audioQualityAndPlaybackCard
                        }
                        settingsCard("第三方 音源 脚本 解封 VIP 导入 规则 下载") {
                            thirdPartySourcesCard
                        }
                        settingsCard("外观 主题 界面 样式 风格 壁纸 字体 底栏 动效 liquid clear compact native") {
                            appearanceAndPersonalizationCard
                        }
                        settingsCard("存储 缓存 清理 备份 恢复 日志 运行环境 版本 关于 设备 更新") {
                            storageDataAndAboutCard
                        }

                        footerNote
                    }
                    .padding(.horizontal, isNativeClean ? 18 : 16)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                    .frame(maxWidth: 860)
                    .frame(maxWidth: .infinity)
                }
                .atmusicScrollIndicatorsHidden()
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(atmusicLocalized("完成", "Done")) { dismiss() }
                        .font(ATMusicFont.appFont(15, .semibold))
                        .foregroundStyle(Color.atmusicAmber)
                }
            }
        )
    }

    /// 搜索过滤卡片：采用 AnyView 阻断泛型层级递归，从根本上防止 AttributeGraph 与 NavigationStack 栈溢出闪退。
    private func settingsCard(_ keywords: String, @ViewBuilder content: () -> some View) -> AnyView {
        guard settingsMatches(keywords) else {
            return AnyView(EmptyView())
        }
        return AnyView(content())
    }

    private var referenceCheckUpdateRow: some View {
        Button {
            Task {
                let result = await UpdateChecker.checkNow()
                await MainActor.run {
                    switch result {
                    case .update: ToastCenter.shared.show("发现新版本，请查看更新日志")
                    case .upToDate: ToastCenter.shared.show("当前已是最新版本")
                    case .failed: ToastCenter.shared.show("检查更新失败")
                    }
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(settingsIconColor)
                    .frame(width: 28)
                Text("检查更新")
                    .font(ATMusicFont.appFont(15, .medium))
                    .foregroundStyle(Color.atmusicLabel)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.atmusicComment)
            }
            .padding(.horizontal, 14)
            .frame(height: 51)
        }
        .buttonStyle(.plain)
    }

    private var platformConnectivityBar: some View {
        HStack(spacing: 8) {
            platformConnectivityPill(
                name: "网易云",
                icon: "BrandNetease",
                isConnected: auth.isLoggedIn,
                accentColor: .red,
                subtitle: auth.user?.nickname ?? "未登录"
            )
            platformConnectivityPill(
                name: "QQ音乐",
                icon: "BrandQQ",
                isConnected: qqAuth.isLoggedIn,
                accentColor: .green,
                subtitle: qqAuth.nickname.isEmpty ? (qqAuth.isLoggedIn ? "已登录" : "未登录") : qqAuth.nickname
            )
            platformConnectivityPill(
                name: "酷狗",
                icon: "BrandKugou",
                isConnected: kugouAuth.isLoggedIn,
                accentColor: .blue,
                subtitle: kugouAuth.nickname.isEmpty ? (kugouAuth.isLoggedIn ? "已登录" : "未登录") : kugouAuth.nickname
            )
            platformConnectivityPill(
                name: "群晖",
                icon: "server.rack",
                isSystemIcon: true,
                isConnected: synology.isLoggedIn,
                accentColor: .orange,
                subtitle: synology.isLoggedIn ? "已连接" : "未连接"
            )
            platformConnectivityPill(
                name: "Subsonic",
                icon: "server.rack",
                isSystemIcon: true,
                isConnected: subsonic.isLoggedIn,
                accentColor: .green,
                subtitle: subsonic.isLoggedIn ? "已连接" : "未连接"
            )
            platformConnectivityPill(
                name: "Jellyfin",
                icon: "play.tv.fill",
                isSystemIcon: true,
                isConnected: jellyfin.isLoggedIn,
                accentColor: .purple,
                subtitle: jellyfin.isLoggedIn ? "已连接" : "未连接"
            )
            platformConnectivityPill(
                name: "WebDAV",
                icon: "folder.fill.badge.gearshape",
                isSystemIcon: true,
                isConnected: webdav.isLoggedIn,
                accentColor: .gray,
                subtitle: webdav.isLoggedIn ? "已连接" : "未连接"
            )
        }
        .padding(.vertical, 2)
    }

    private func platformConnectivityPill(
        name: String,
        icon: String,
        isSystemIcon: Bool = false,
        isConnected: Bool,
        accentColor: Color,
        subtitle: String
    ) -> some View {
        Button {
            ATMusicHaptics.tap()
            showAccountHub = true
        } label: {
            HStack(spacing: 5) {
                if isSystemIcon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isConnected ? accentColor : Color.atmusicComment)
                } else {
                    Image(icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 13, height: 13)
                        .opacity(isConnected ? 1.0 : 0.4)
                }

                HStack(spacing: 3) {
                    Text(name)
                        .font(ATMusicFont.appFont(11, .semibold))
                        .foregroundStyle(isConnected ? Color.atmusicLabel : Color.atmusicComment)
                    Circle()
                        .fill(isConnected ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isConnected ? accentColor.opacity(0.12) : Color.primary.opacity(0.04))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(isConnected ? accentColor.opacity(0.3) : Color.clear, lineWidth: 0.8)
                    }
            }
        }
        .buttonStyle(.plain)
    }

    /// 参考版设置页中的统一账号入口：账号管理不再和平台显示混在一起。
    private var accountSettingsRow: some View {
        Button {
            ATMusicHaptics.tap()
            showAccountHub = true
        } label: {
            HStack(spacing: 11) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(settingsIconColor)
                    .frame(width: 30, height: 30)
                    .background(isNativeClean ? Color.clear : Color.atmusicAmber.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text("账号登录")
                        .font(ATMusicFont.appFont(14, .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                    if !isNativeClean {
                        Text(platformPrefs.summaryText)
                            .font(ATMusicFont.appFont(11))
                            .foregroundStyle(Color.atmusicComment)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.atmusicComment)
            }
            .padding(.horizontal, isNativeClean ? 14 : 0)
            .frame(minHeight: isNativeClean ? 51 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(GlassPressButtonStyle(scale: 0.98))
    }

    /// 1.8 新增的运行环境信息。除方便反馈问题外，也为播放器布局预览提供同一套设备基准。
    private var runtimeInfoSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            runtimeInfoRow("设备型号", ATMusicDeviceInfo.marketingModelName, "iphone")
            runtimeInfoDivider
            runtimeInfoRow("系统版本", "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)", "gearshape.2")
            runtimeInfoDivider
            runtimeInfoRow("界面尺寸", ATMusicDeviceInfo.displayMetricsSummary, "rectangle.on.rectangle")
            runtimeInfoDivider
            runtimeInfoRow(
                "应用版本",
                "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"))",
                "number"
            )

            Toggle(isOn: $hideDynamicEffects) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .foregroundStyle(Color.atmusicAmber)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("低功耗视觉模式")
                            .font(ATMusicFont.appFont(14, .medium))
                            .foregroundStyle(Color.atmusicLabel)
                        Text("暂停 DJ、浮尘、唱片/封面旋转和流光等持续动画；系统“减少动态效果”也会自动生效")
                            .font(ATMusicFont.appFont(10))
                            .foregroundStyle(Color.atmusicComment)
                    }
                }
            }
            .toggleStyle(.switch)
            .tint(Color.atmusicAmber)
            .padding(.top, 12)

            Toggle(isOn: $hideAppearanceToggle) {
                HStack(spacing: 10) {
                    Image(systemName: "circle.lefthalf.filled")
                        .foregroundStyle(Color.atmusicAmber)
                        .frame(width: 24)
                    Text("隐藏右上角外观切换")
                        .font(ATMusicFont.appFont(14, .medium))
                        .foregroundStyle(Color.atmusicLabel)
                }
            }
            .toggleStyle(.switch)
            .tint(Color.atmusicAmber)
            .padding(.top, 10)

        }
    }

    private var runtimeInfoDivider: some View {
        Divider().overlay(Color.atmusicComment.opacity(0.12))
    }

    private func runtimeInfoRow(_ title: String, _ value: String, _ icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(Color.atmusicAmber)
                .frame(width: 24)
            Text(title)
                .font(ATMusicFont.appFont(13))
                .foregroundStyle(Color.atmusicComment)
            Spacer()
            Text(value)
                .font(ATMusicFont.appFont(13, .medium))
                .foregroundStyle(Color.atmusicLabel)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.vertical, 10)
    }

    private static var displaySizeText: String {
        let bounds = ATMusicDisplayMetrics.bounds
        let scale = ATMusicDisplayMetrics.scale
        return "\(Int(bounds.width))×\(Int(bounds.height)) · @\(String(format: "%.1f", scale))"
    }

    /// 1.8.1 的主题模式是三个独立的选择卡，而不是系统默认的 segmented picker。
    /// 这样选中状态、图标和设置页其它卡片保持一致，也避免在窄屏上出现文字被截断。
    private func themeModeOption(_ mode: ATMusicThemeMode) -> some View {
        let selected = themeModeRaw == mode.rawValue
        return Button {
            themeModeRaw = mode.rawValue
            ATMusicHaptics.select()
        } label: {
            VStack(spacing: 7) {
                Image(systemName: mode.icon)
                    .font(.system(size: 16, weight: .semibold))
                Text(LocalizedStringKey(mode.title))
                    .font(ATMusicFont.appFont(12, .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(Color.atmusicLabel)
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .background {
                ATMusicSelectableSurface(
                    selected: selected,
                    shape: RoundedRectangle(cornerRadius: 14, style: .continuous),
                    accent: settingsIconColor
                )
            }
        }
        .buttonStyle(.plain)
    }


    /// 校验扩展名并安装字体（asCopy 返回的 URL 已在沙盒内，可直接读取）
    private func installFont(from url: URL) {
        let ext = url.pathExtension.lowercased()
        guard ["ttf", "otf", "ttc"].contains(ext) else {
            ToastCenter.shared.show("请选择 ttf / otf 字体文件")
            return
        }
        if let name = FontManager.install(from: url) {
            ATMusicHaptics.success()
            ToastCenter.shared.show("字体已应用：\(name)")
        } else {
            ToastCenter.shared.show("字体安装失败，请使用 ttf / otf 文件")
        }
    }

    private var platformSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "checklist")
                    .font(.system(size: 14))
                    .foregroundStyle(settingsIconColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(atmusicLocalized("平台显示与搜索", "Platform Display & Search"))
                        .font(ATMusicFont.appFont(15, .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                    Text(atmusicLocalized("取消勾选后所有页面下均不再有该平台的内容和相关选项", "Deselecting a platform completely removes its content from all pages."))
                        .font(ATMusicFont.appFont(11))
                        .foregroundStyle(Color.atmusicComment)
                }
            }
            PlatformPreferencePicker()
                .padding(.top, 4)
        }
    }

    /// 外观设置（原「我的」页外观折叠内容）
    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: isNativeClean ? 0 : 12) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    ForEach(ATMusicThemeMode.allCases) { mode in
                        themeModeOption(mode)
                    }
                }
                .padding(.top, 2)

                Divider().overlay(Color.atmusicComment.opacity(0.15))

                // 更多外观与主页设置折叠入口
                Button {
                    ATMusicHaptics.select()
                    withAnimation {
                        moreAppearanceExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 14))
                            .foregroundStyle(settingsIconColor)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(atmusicLocalized("更多外观与主页设置", "More Appearance & Home Settings"))
                                .font(ATMusicFont.appFont(15))
                                .foregroundStyle(Color.atmusicLabel)
                            Text(atmusicLocalized("字体、壁纸、强调色、UI 样式与主页设置", "Fonts, wallpapers, colors, UI style & home settings"))
                                .font(ATMusicFont.appFont(11))
                                .foregroundStyle(Color.atmusicComment)
                        }
                        Spacer()
                        Image(systemName: moreAppearanceExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.atmusicComment.opacity(0.6))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if moreAppearanceExpanded {
                    moreAppearanceAndHomeSettingsContent
                        .transition(.opacity)
                }
            }
            .padding(16)
            .background {
                        ATMusicGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
            .atmusicCardShadow(radius: 9, y: 3)
        }
    }

    /// 更多外观与主页设置（折叠展开内容）
    private var moreAppearanceAndHomeSettingsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider().overlay(Color.atmusicComment.opacity(0.15))

                Picker("语言", selection: $languageRaw) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .tint(Color.atmusicAmber)

                if #unavailable(iOS 26) {
                    Toggle(isOn: $tabLabelsVisible) {
                        HStack(spacing: 12) {
                            Image(systemName: "rectangle.3.group")
                                .font(.system(size: 14))
                                .foregroundStyle(Color.atmusicAmber)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("底栏显示文字")
                                    .font(ATMusicFont.appFont(15))
                                    .foregroundStyle(Color.atmusicLabel)
                            }
                        }
                    }
                    .toggleStyle(.switch)
                    .tint(Color.atmusicAmber)
                }

                Toggle(isOn: $showSongVIPBadge) {
                    HStack(spacing: 12) {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.atmusicAmber)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("显示歌曲 VIP 图标")
                                .font(ATMusicFont.appFont(15))
                                .foregroundStyle(Color.atmusicLabel)
                        }
                    }
                }
                .toggleStyle(.switch)
                .tint(Color.atmusicAmber)

                Divider().overlay(Color.atmusicComment.opacity(0.15))

                if #unavailable(iOS 26) {
                    legacyTabBarSettings

                    Divider().overlay(Color.atmusicComment.opacity(0.15))
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.atmusicAmber)
                            .frame(width: 28)
                        Text("全局 UI 样式")
                            .font(ATMusicFont.appFont(15))
                            .foregroundStyle(Color.atmusicLabel)
                        Spacer()
                    }
                    Picker("全局 UI 样式", selection: Binding(
                        get: { theme.uiStyle },
                        set: { style in
                            ATMusicHaptics.select()
                            theme.setUIStyle(style)
                            uiStyleRaw = style.rawValue
                        }
                    )) {
                        ForEach(ATMusicUIStyle.allCases, id: \.self) { style in
                            Text(LocalizedStringKey(style.title)).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Divider().overlay(Color.atmusicComment.opacity(0.15))

                HStack {
                    Image(systemName: "eyedropper.halffull")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.atmusicAmber)
                        .frame(width: 28)
                    Text("自定义强调色")
                        .font(ATMusicFont.appFont(15))
                        .foregroundStyle(Color.atmusicLabel)
                    Spacer()
                    ColorPicker("", selection: Binding(
                        get: { theme.customAccent ?? Color.atmusicAmber },
                        set: { theme.setCustomAccent($0.hexString) }
                    ))
                    .labelsHidden()
                }
                HStack(spacing: 12) {
                    Button {
                        theme.clearCustomAccent()
                        ATMusicHaptics.select()
                    } label: {
                        Text("恢复预设")
                            .font(ATMusicFont.appFont(13, .medium))
                            .foregroundStyle(Color.atmusicAmber)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background { ATMusicSurface(shape: Capsule()) }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                            Text(LocalizedStringKey(theme.customAccentHex == nil ? "使用预设主题" : "已自定义"))
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(Color.atmusicComment)
                }

                    Divider().overlay(Color.atmusicComment.opacity(0.15))

                    HStack {
                        Image(systemName: "photo.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.atmusicAmber)
                            .frame(width: 28)
                        Text(atmusicLocalized("主页背景色", "Home Background Color"))
                            .font(ATMusicFont.appFont(15))
                            .foregroundStyle(Color.atmusicLabel)
                        Spacer()
                    }
                    Picker(atmusicLocalized("背景模式", "Background Mode"), selection: $wallpaperAppearanceTarget) {
                        ForEach(ATMusicWallpaperAppearance.allCases) { appearance in
                            Text(appearance.title).tag(appearance)
                        }
                    }
                    .pickerStyle(.segmented)
                    .tint(Color.atmusicAmber)
                    HStack {
                        Image(systemName: "circle.lefthalf.filled")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.atmusicAmber)
                            .frame(width: 28)
                        Text(atmusicLocalized("背景颜色", "Background Color"))
                            .font(ATMusicFont.appFont(15))
                            .foregroundStyle(Color.atmusicLabel)
                        Spacer()
                        ColorPicker("", selection: Binding(
                            get: { theme.customBackground(for: wallpaperAppearanceTarget.colorScheme) ?? Color.atmusicBackground },
                            set: { theme.setBackground($0.hexString, for: wallpaperAppearanceTarget.colorScheme) }
                        ))
                        .labelsHidden()
                    }

                    HStack(spacing: 10) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.atmusicAmber)
                            .frame(width: 28)
                        Button {
                            showWallpaperPicker = true
                        } label: {
                            HStack(spacing: 8) {
                                Text("上传壁纸（可多张）")
                                    .font(ATMusicFont.appFont(15))
                                    .foregroundStyle(Color.atmusicLabel)
                                Spacer()
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(Color.atmusicAmber)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    // 壁纸库：所有已上传壁纸，点击即应用为当前背景
                    if !theme.wallpaperPaths.isEmpty {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                            ForEach(theme.wallpaperPaths, id: \.self) { path in
                                wallpaperCell(path: path, appearance: wallpaperAppearanceTarget)
                            }
                        }
                    } else {
                        HStack(spacing: 12) {
                            Image(systemName: "photo.stack")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.atmusicComment)
                            Text("还没有壁纸，上传后会显示在这里")
                                .font(ATMusicFont.appFont(12))
                                .foregroundStyle(Color.atmusicComment)
                            Spacer()
                        }
                    }
                    HStack(spacing: 12) {
                        if theme.customBackgroundImage(for: wallpaperAppearanceTarget.colorScheme) != nil {
                            Button {
                                theme.clearBackgroundImage(for: wallpaperAppearanceTarget.colorScheme)
                                ATMusicHaptics.select()
                            } label: {
                                Text("清除当前背景")
                                    .font(ATMusicFont.appFont(13, .medium))
                                    .foregroundStyle(.red)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background { ATMusicSurface(shape: Capsule()) }
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                            Text(LocalizedStringKey(theme.customBackgroundImage(for: wallpaperAppearanceTarget.colorScheme) == nil ? "当前：默认背景" : "当前：已应用壁纸"))
                            .font(ATMusicFont.appFont(12))
                            .foregroundStyle(Color.atmusicComment)
                    }
                Toggle(isOn: Binding(
                    get: { theme.backgroundSyncAll },
                    set: { theme.setBackgroundSyncAll($0) }
                )) {
                    HStack(spacing: 8) {
                        Image(systemName: "square.grid.2x2.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.atmusicAmber)
                        Text(LocalizedStringKey("同步到搜索 / 音乐库 / 我的"))
                            .font(ATMusicFont.appFont(13))
                            .foregroundStyle(Color.atmusicLabel)
                    }
                }
                .toggleStyle(.switch)
                .tint(Color.atmusicAmber)

                Divider().overlay(Color.atmusicComment.opacity(0.15))

                HStack {
                    Button {
                        theme.setBackground("")
                        ATMusicHaptics.select()
                    } label: {
                        Text("恢复默认背景")
                            .font(ATMusicFont.appFont(13, .medium))
                            .foregroundStyle(Color.atmusicAmber)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        .background { ATMusicSurface(shape: Capsule()) }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }

                Divider().overlay(Color.atmusicComment.opacity(0.15))

                HStack {
                    Image(systemName: "text.quote")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.atmusicAmber)
                        .frame(width: 28)
                    Text("注释文字颜色")
                        .font(ATMusicFont.appFont(15))
                        .foregroundStyle(Color.atmusicLabel)
                    Spacer()
                    ColorPicker("", selection: Binding(
                        get: {
                            if let raw = UserDefaults.standard.string(forKey: "atmusic.commentColorHex"),
                               let c = Color(hex: raw) { return c }
                            return Color.atmusicComment
                        },
                        set: { UserDefaults.standard.set($0.hexString, forKey: "atmusic.commentColorHex") }
                    ))
                    .labelsHidden()
                }
                HStack(spacing: 12) {
                    Button {
                        UserDefaults.standard.removeObject(forKey: "atmusic.commentColorHex")
                        ATMusicHaptics.select()
                    } label: {
                        Text("恢复默认")
                            .font(ATMusicFont.appFont(13, .medium))
                            .foregroundStyle(Color.atmusicAmber)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        .background { ATMusicSurface(shape: Capsule()) }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text(LocalizedStringKey("全 App 说明文字颜色"))
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(Color.atmusicComment)
                }

                Divider().overlay(Color.atmusicComment.opacity(0.15))

                HStack {
                    Image(systemName: "house.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.atmusicAmber)
                        .frame(width: 28)
                    Text("主文字颜色")
                        .font(ATMusicFont.appFont(15))
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
                }
                HStack(spacing: 12) {
                    Button {
                        labelColorHex = ""
                        theme.objectWillChange.send()
                        ATMusicHaptics.select()
                    } label: {
                        Text("恢复默认")
                            .font(ATMusicFont.appFont(13, .medium))
                            .foregroundStyle(Color.atmusicAmber)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        .background { ATMusicSurface(shape: Capsule()) }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text(LocalizedStringKey("全 App 主文字颜色"))
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(Color.atmusicComment)
                }

                Divider().overlay(Color.atmusicComment.opacity(0.15))

                // Greeting customization was removed; retain only wallpaper controls below.
                Toggle("隐藏主页用户名", isOn: $homeHideUsername)
                    .font(ATMusicFont.appFont(13))
                Toggle("隐藏所有界面排序按钮", isOn: $homeHeaderHideSort)
                    .font(ATMusicFont.appFont(13))
                Toggle("隐藏顶部平台列表", isOn: $hidePlatformPicker)
                    .font(ATMusicFont.appFont(13))
                Toggle("隐藏主页刷新按钮", isOn: $homeHeaderHideRefresh)
                    .font(ATMusicFont.appFont(13))

                HStack {
                    Image(systemName: "textformat")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.atmusicAmber)
                        .frame(width: 28)
                    Text("全局字体")
                        .font(ATMusicFont.appFont(15))
                        .foregroundStyle(Color.atmusicLabel)
                    Spacer()
                    Text(FontManager.installedFontName ?? "系统默认")
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(Color.atmusicComment)
                }
                HStack(spacing: 12) {
                    Button {
                        showFontImporter = true
                    } label: {
                        Text("上传字体")
                            .font(ATMusicFont.appFont(13, .medium))
                            .foregroundStyle(Color.atmusicAmber)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    .background { ATMusicSurface(shape: Capsule()) }
                    }
                    .buttonStyle(.plain)
                    Button {
                        FontManager.clear()
                        ATMusicHaptics.select()
                        ToastCenter.shared.show("已恢复系统默认字体")
                    } label: {
                        Text("恢复默认字体")
                            .font(ATMusicFont.appFont(13, .medium))
                            .foregroundStyle(Color.atmusicAmber)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    .background { ATMusicSurface(shape: Capsule()) }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
        }
    }

    /// 播放与歌词设置。
    private var equalizerSection: some View {
        Button {
            ATMusicHaptics.select()
            showEqualizer = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(settingsIconColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(atmusicLocalized("均衡器", "Equalizer"))
                        .font(ATMusicFont.appFont(15))
                        .foregroundStyle(Color.atmusicLabel)
                    if !isNativeClean {
                        Text(atmusicLocalized("调节低音、人声与高音", "Adjust bass, vocals, and treble"))
                            .font(ATMusicFont.appFont(11))
                            .foregroundStyle(Color.atmusicComment)
                    }
                }
                Spacer()
                Text(equalizer.isEnabled ? atmusicLocalized("已开启", "On") : atmusicLocalized("已关闭", "Off"))
                    .font(ATMusicFont.appFont(12, .medium))
                    .foregroundStyle(equalizer.isEnabled ? Color.atmusicAmber : Color.atmusicComment)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.atmusicComment.opacity(0.6))
            }
            .padding(.horizontal, 14)
            .frame(minHeight: isNativeClean ? 51 : 47)
            .background {
                if !isNativeClean { ATMusicGlass(shape: RoundedRectangle(cornerRadius: 18, style: .continuous)) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(GlassPressButtonStyle(scale: 0.98))
    }


    private var thirdPartySourceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $sourceStore.isThirdPartyEnabled) {
                HStack(spacing: 12) {
                    Image(systemName: sourceStore.isThirdPartyEnabled ? "shippingbox.fill" : "shippingbox")
                        .font(.system(size: 15))
                        .foregroundStyle(sourceStore.isThirdPartyEnabled ? Color.atmusicAmber : Color.atmusicComment)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(atmusicLocalized("启用第三方音源", "Enable Third-party Sources"))
                            .font(ATMusicFont.appFont(15, .semibold))
                            .foregroundStyle(Color.atmusicLabel)
                        Text(atmusicLocalized(
                            sourceStore.isThirdPartyEnabled ? "官方无完整版权或未登录 VIP 时自动由第三方音源兜底" : "已彻底关闭：仅使用官方直链播放，绝不调用任何第三方接口",
                            sourceStore.isThirdPartyEnabled ? "Fallback to third-party sources when official has no full track." : "Completely disabled. Only official direct streams are used."
                        ))
                        .font(ATMusicFont.appFont(11))
                        .foregroundStyle(Color.atmusicComment)
                    }
                }
            }
            .toggleStyle(.switch)
            .tint(Color.atmusicAmber)

            if sourceStore.isThirdPartyEnabled {
                Divider().overlay(Color.atmusicComment.opacity(0.12))

                HStack(spacing: 10) {
                    Image(systemName: "doc.badge.gearshape.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.atmusicAmber)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(atmusicLocalized("自定义脚本音源", "Custom Script Sources"))
                            .font(ATMusicFont.appFont(14, .medium))
                            .foregroundStyle(Color.atmusicLabel)
                        Text(atmusicLocalized("支持洛雪标准音源脚本 (v1/v2/v6) · 已配 \(customSourceCount) 个", "Supports LX music source scripts · \(customSourceCount) configured"))
                            .font(ATMusicFont.appFont(11))
                            .foregroundStyle(Color.atmusicComment)
                    }
                    Spacer()
                    Button {
                        showSourceManager = true
                        ATMusicHaptics.tap()
                    } label: {
                        Text(atmusicLocalized("管理音源", "Manage"))
                            .font(ATMusicFont.appFont(12, .semibold))
                            .foregroundStyle(Color.atmusicAmber)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.atmusicAmber.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Divider().overlay(Color.atmusicComment.opacity(0.12))

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.atmusicAmber)
                            .frame(width: 28)
                        Text(thirdPartyAudioQualityTitle)
                            .font(ATMusicFont.appFont(13, .semibold))
                            .foregroundStyle(Color.atmusicLabel)
                        Spacer()
                        Text(thirdPartyAudioQualitySelection.wrappedValue.displayName)
                            .font(ATMusicFont.appFont(12))
                            .foregroundStyle(Color.atmusicComment)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(thirdPartyAudioQualityOptions) { quality in
                                let selected = thirdPartyAudioQualitySelection.wrappedValue == quality
                                Button {
                                    thirdPartyAudioQualitySelection.wrappedValue = quality
                                    ATMusicHaptics.select()
                                } label: {
                                    HStack(spacing: 5) {
                                        Text(quality.displayName)
                                        if selected {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 9, weight: .bold))
                                        }
                                    }
                                    .font(ATMusicFont.appFont(12, selected ? .semibold : .medium))
                                    .atmusicSelectionForeground(selected: selected, accent: .atmusicAmber)
                                    .padding(.horizontal, 12)
                                    .frame(height: 31)
                                    .background {
                                        ATMusicSelectableSurface(selected: selected, shape: Capsule(), accent: .atmusicAmber)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 1)
                    }
                }
                Text(thirdPartyAudioQualityHint)
                    .font(ATMusicFont.appFont(11))
                    .foregroundStyle(Color.atmusicComment)

                Divider().overlay(Color.atmusicComment.opacity(0.12))

                Toggle(isOn: $showThirdPartyVIPNotice) {
                    HStack(spacing: 12) {
                        Image(systemName: "bell.badge.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.atmusicAmber)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(atmusicLocalized("第三方播放会员歌提醒", "VIP song notice for third-party playback"))
                                .font(ATMusicFont.appFont(14))
                                .foregroundStyle(Color.atmusicLabel)
                            Text(atmusicLocalized("通过第三方音源成功解析会员歌曲时在界面顶部显示轻量提示", "Show a light toast when VIP songs are resolved via third-party."))
                                .font(ATMusicFont.appFont(11))
                                .foregroundStyle(Color.atmusicComment)
                        }
                    }
                }
                .toggleStyle(.switch)
                .tint(Color.atmusicAmber)
            }
        }
        .task(id: thirdPartyAudioQualityOptionsSignature) {
            normalizeThirdPartyAudioQualitySelection()
        }
    }


    private var backupSection: some View {
        VStack(alignment: .leading, spacing: isNativeClean ? 0 : 12) {
            Button {
                ATMusicHaptics.select()
                withAnimation {
                    backupExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "externaldrive.fill")
                        .foregroundStyle(settingsIconColor)
                        .frame(width: isNativeClean ? 28 : nil)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("备份与恢复")
                            .font(ATMusicFont.appFont(15))
                            .foregroundStyle(Color.atmusicLabel)
                    }
                    Spacer()
                    Image(systemName: backupExpanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(Color.atmusicComment)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: isNativeClean ? 51 : 47)
                .background {
                    if !isNativeClean { ATMusicGlass(shape: RoundedRectangle(cornerRadius: 18, style: .continuous)) }
                }
            }
            .buttonStyle(.plain)

            if backupExpanded {
                nasSyncCard

            VStack(spacing: 10) {
                Toggle("备份登录信息", isOn: $backupIncludeAccounts)
                    .tint(Color.atmusicAmber)
                    .font(ATMusicFont.appFont(13))
                Divider().opacity(0.35)
                Toggle("备份壁纸图片", isOn: $backupIncludeWallpapers)
                    .tint(Color.atmusicAmber)
                    .font(ATMusicFont.appFont(13))
                Divider().opacity(0.35)
                Text("默认不带账号登录信息；关闭壁纸后只备份普通设置，不写入壁纸图片数据")
                    .font(ATMusicFont.appFont(11))
                    .foregroundStyle(Color.atmusicComment)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background {
                ATMusicGlass(shape: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            HStack(spacing: 10) {
                backupActionButton(icon: "square.and.arrow.up", title: "导出备份") {
                    ATMusicHaptics.tap()
                    exportBackup(includeAccounts: backupIncludeAccounts, includeWallpapers: backupIncludeWallpapers)
                }
                backupActionButton(icon: "square.and.arrow.down", title: "导入恢复") {
                    ATMusicHaptics.tap()
                    showRestorePicker = true
                }
            }
            if let backupMessage {
                Text(backupMessage)
                    .font(ATMusicFont.appFont(11))
                    .foregroundStyle(Color.atmusicComment)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            }
        }
    }


    private var nasSyncCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .foregroundStyle(Color.atmusicAmber)
                Text("群晖 NAS 多设备云端同步")
                    .font(ATMusicFont.appFont(14, .semibold))
                    .foregroundStyle(Color.atmusicLabel)
                Spacer()
            }

            if SynologyAPI.shared.isLoggedIn {
                Toggle("自动静默同步", isOn: Binding(
                    get: { NASUserSyncManager.shared.autoSyncEnabled },
                    set: { enabled in NASUserSyncManager.shared.autoSyncEnabled = enabled }
                ))
                .tint(Color.atmusicAmber)
                .font(ATMusicFont.appFont(13))

                HStack {
                    Text("上次同步状态")
                        .font(ATMusicFont.appFont(11))
                        .foregroundStyle(Color.atmusicComment)
                    Spacer()
                    Text(NASUserSyncManager.shared.formattedLastSyncTime)
                        .font(ATMusicFont.appFont(11, .medium))
                        .foregroundStyle(Color.atmusicLabel)
                }

                HStack(spacing: 8) {
                    Button {
                        Task {
                            await NASUserSyncManager.shared.backupToNAS(isManual: true)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.icloud")
                            Text("备份至 NAS")
                        }
                        .font(ATMusicFont.appFont(12, .semibold))
                        .foregroundStyle(Color.atmusicAmber)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.atmusicAmber.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(GlassPressButtonStyle(scale: 0.95))

                    Button {
                        Task {
                            await NASUserSyncManager.shared.restoreFromNAS(isManual: true)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.icloud")
                            Text("从 NAS 恢复")
                        }
                        .font(ATMusicFont.appFont(12, .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(GlassPressButtonStyle(scale: 0.95))
                }
            } else {
                Text("连接群晖 NAS 后，可自动在 iPhone、iPad 之间无感同步本地歌单、红心收藏、播放历史与全局设置。")
                    .font(ATMusicFont.appFont(11))
                    .foregroundStyle(Color.atmusicComment)
            }
        }
        .padding(14)
        .background {
            ATMusicGlass(shape: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func backupActionButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(LocalizedStringKey(title))
            }
            .font(ATMusicFont.appFont(14, .semibold))
            .foregroundStyle(Color.atmusicLabel)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background {
                ATMusicGlass(shape: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .buttonStyle(GlassPressButtonStyle(scale: 0.95))
    }

    private static func isAccountBackupKey(_ key: String) -> Bool {
        key == "atmusic.user"
            || key.hasPrefix("atmusic.netease.")
            || key.hasPrefix("atmusic.qqmusic.")
            || key.hasPrefix("atmusic.kugou.")
    }

    private static func isPrivacyBackupKey(_ key: String) -> Bool {
        key.hasPrefix("atmusic.search.")
            || key.hasPrefix("atmusic.log")
            || key.hasPrefix("atmusic.crash")
            || key == "atmusic.thirdPartyAPIKeys"
            || key == "atmusic.launchInProgress"
            || key == "atmusic.wallpapers.deleted"
    }

    private static func isWallpaperBackupKey(_ key: String) -> Bool {
        key == "atmusic.background.image"
            || key == "atmusic.background.image.light"
            || key == "atmusic.background.image.dark"
            || key == "atmusic.background.custom"
            || key == "atmusic.background.custom.light"
            || key == "atmusic.background.custom.dark"
            || key == "atmusic.wallpapers.list"
            || key == "atmusic.wallpapers.data"
            || key == "atmusic.lyricBackground.image"
            || key == "atmusic.lyricBackground.data"
    }

    private static func isSystemBackupKey(_ key: String) -> Bool {
        key.hasPrefix("Apple")
            || key.hasPrefix("NS")
            || key.hasPrefix("com.apple.")
            || key == "AddingEmojiKeybordHandled"
    }

    private static func isBackupCandidateKey(_ key: String) -> Bool {
        key.hasPrefix("atmusic.") && !isSystemBackupKey(key)
    }

    private static func isExcludedBackupKey(_ key: String, includeAccounts: Bool = false, includeWallpapers: Bool = true) -> Bool {
        (!includeAccounts && isAccountBackupKey(key))
            || (!includeWallpapers && isWallpaperBackupKey(key))
            || isPrivacyBackupKey(key)
            || key == "atmusic.backup.meta"
            || key == "atmusic.font.restore"
    }

    /// 导出：收集本 App 设置，排除账号、搜索记录和日志，交给系统原生导出面板
    private func exportBackup(includeAccounts: Bool, includeWallpapers: Bool) {
        let defaults = UserDefaults.standard
        var payload: [String: Any] = [:]
        if includeWallpapers {
            theme.refreshWallpaperBackupForExport()
            LyricBackgroundStore.refreshForExport()
        }
        for (key, value) in defaults.dictionaryRepresentation() {
            guard Self.isBackupCandidateKey(key) else { continue }
            guard !Self.isExcludedBackupKey(key, includeAccounts: includeAccounts, includeWallpapers: includeWallpapers) else { continue }
            // 超大原始 Data 直接跳过（壁纸 base64 已以字符串形式存于 atmusic.wallpapers.data，不受影响）
            if let data = value as? Data, data.count > 2 * 1024 * 1024 { continue }
            let safe = backupJSONSafe(value)
            // 逐个校验可序列化，异常类型直接跳过，避免整份备份生成失败
            guard JSONSerialization.isValidJSONObject([key: safe]) else { continue }
            payload[key] = safe
        }
        // 字体文件（Documents/Fonts）随备份一起导出
        if let font = FontManager.exportFontData() {
            payload["atmusic.font.restore"] = [
                "name": font.name,
                "data": font.data.base64EncodedString(),
            ] as [String: Any]
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        payload["atmusic.backup.meta"] = [
            "app": "AT Music",
            "created": ISO8601DateFormatter().string(from: Date()),
            "version": version,
            "includedAccounts": includeAccounts,
            "includedWallpapers": includeWallpapers,
            "excluded": [
                includeAccounts ? nil : "account",
                includeWallpapers ? nil : "wallpapers",
                "search history",
                "logs",
            ].compactMap { $0 }.joined(separator: ", "),
        ] as [String: Any]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
            backupMessage = "备份生成失败：存在无法序列化的设置项"
            ToastCenter.shared.show("备份生成失败")
            return
        }
        backupDoc = BackupDocument(data: data)
        backupMessage = nil
        ATMusicLogger.shared.log("导出配置备份（\(payload.count) 项，账号=\(includeAccounts ? "包含" : "排除") 壁纸=\(includeWallpapers ? "包含" : "排除")）", level: .info)
        showExportBackup = true
    }

    private static func backupDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    /// 读取用户选择的备份文件并解析，弹确认后恢复
    private func handleBackupImport(_ url: URL) {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            ToastCenter.shared.show("备份文件解析失败")
            return
        }
        pendingRestore = json
        showRestoreConfirm = true
    }

    /// 恢复：把 JSON 备份中除账号、搜索记录和日志外的本 App 设置写回 UserDefaults
    private func applyRestore(_ json: [String: Any]?) {
        guard let json else { return }
        let defaults = UserDefaults.standard
        var count = 0
        for (key, value) in json {
            guard Self.isBackupCandidateKey(key) else { continue }
            guard !Self.isExcludedBackupKey(key, includeAccounts: true, includeWallpapers: true) else { continue }
            guard let restored = backupPlistSafe(value) else { continue }
            defaults.set(restored, forKey: key)
            count += 1
        }
        // 兼容旧备份：旧版本只有一套背景，恢复后让浅色和深色都继承它。
        if json["atmusic.background.custom.light"] == nil,
           json["atmusic.background.custom.dark"] == nil,
           let legacy = json["atmusic.background.custom"] as? String {
            defaults.set(legacy, forKey: "atmusic.background.custom.light")
            defaults.set(legacy, forKey: "atmusic.background.custom.dark")
        }
        if json["atmusic.background.image.light"] == nil,
           json["atmusic.background.image.dark"] == nil,
           let legacy = json["atmusic.background.image"] as? String {
            defaults.set(legacy, forKey: "atmusic.background.image.light")
            defaults.set(legacy, forKey: "atmusic.background.image.dark")
        }
        theme.reloadBackgroundSettings()
        defaults.removeObject(forKey: "atmusic.wallpapers.deleted")
        // 恢复壁纸：写回 atmusic.wallpapers.* 后重建文件（沙盒路径变化也能恢复）
        theme.reloadWallpapersFromBackup()
        // 恢复歌词背景图片：路径变化时按备份的 base64 重建文件
        LyricBackgroundStore.restoreFromBackup()
        // 恢复字体文件
        if let fontPayload = json["atmusic.font.restore"] as? [String: Any],
           let name = fontPayload["name"] as? String,
           let b64 = fontPayload["data"] as? String,
           let fontData = Data(base64Encoded: b64) {
            if FontManager.restoreFont(name: name, data: fontData) {
                count += 1
            }
        }
        ATMusicLogger.shared.log("恢复配置备份：\(count) 项设置", level: .info)
        if count > 0 {
            ATMusicHaptics.success()
            backupMessage = "已恢复 \(count) 项设置，部分设置需重启应用后完全生效"
            ToastCenter.shared.show("已恢复 \(count) 项设置")
        } else {
            backupMessage = "备份中未找到可恢复的设置"
        }
    }

    private var legacyTabBarSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.atmusicAmber)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("低系统悬浮底栏")
                        .font(ATMusicFont.appFont(15))
                        .foregroundStyle(Color.atmusicLabel)
                    Text("仅 iOS 26 以下生效，用来模拟高系统悬浮底栏")
                        .font(ATMusicFont.appFont(11))
                        .foregroundStyle(Color.atmusicComment)
                }
                Spacer()
                Button("默认") {
                    resetLegacyTabBar()
                    ATMusicHaptics.select()
                }
                .font(ATMusicFont.appFont(12, .semibold))
                .foregroundStyle(Color.atmusicAmber)
                .buttonStyle(.plain)
            }
            settingsSlider("圆润度", valueText: "\(Int(legacyTabCornerRadius))") {
                Slider(value: $legacyTabCornerRadius, in: 18...42, step: 1)
                    .tint(Color.atmusicAmber)
            }
            settingsSlider("长度", valueText: "\(Int(legacyTabWidth))") {
                Slider(value: $legacyTabWidth, in: 300...420, step: 1)
                    .tint(Color.atmusicAmber)
            }
            settingsSlider("X 位置", valueText: signedIntText(legacyTabOffsetX)) {
                Slider(value: $legacyTabOffsetX, in: -40...40, step: 1)
                    .tint(Color.atmusicAmber)
            }
            settingsSlider("Y 位置", valueText: signedIntText(legacyTabOffsetY)) {
                Slider(value: $legacyTabOffsetY, in: -36...36, step: 1)
                    .tint(Color.atmusicAmber)
            }
        }
        .padding(14)
        .background {
            ATMusicGlass(shape: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func resetLegacyTabBar() {
        legacyTabCornerRadius = 32
        legacyTabWidth = 356
        legacyTabOffsetX = 0
        legacyTabOffsetY = 0
    }

    private func signedIntText(_ value: Double) -> String {
        let intValue = Int(value.rounded())
        if intValue == 0 { return "0" }
        return intValue > 0 ? "+\(intValue)" : "\(intValue)"
    }

    private func settingsSlider<Content: View>(_ title: String, valueText: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 5) {
            HStack {
                Text(LocalizedStringKey(title))
                    .font(ATMusicFont.appFont(13))
                    .foregroundStyle(Color.atmusicLabel)
                Spacer()
                Text(valueText)
                    .font(ATMusicFont.appFont(12, .semibold))
                    .foregroundStyle(Color.atmusicAmber)
            }
            content()
                .transaction { transaction in transaction.animation = nil }
        }
    }

    /// 任意 UserDefaults 值 → JSON 可序列化（Data 转 base64、Date 转时间戳）
    private func backupJSONSafe(_ value: Any) -> Any {
        if let data = value as? Data {
            return ["__atmusicData__": data.base64EncodedString()]
        }
        if let date = value as? Date { return date.timeIntervalSince1970 }
        if let dict = value as? [String: Any] { return dict.mapValues { backupJSONSafe($0) } }
        if let array = value as? [Any] { return array.map { backupJSONSafe($0) } }
        if let dict = value as? [String: String] { return dict }
        if let array = value as? [String] { return array }
        return value
    }

    /// JSON 值 → UserDefaults 可存类型（只保留 plist 兼容类型）
    private func backupPlistSafe(_ value: Any) -> Any? {
        if let dict = value as? [String: Any], dict.count == 1,
           let b64 = dict["__atmusicData__"] as? String,
           let data = Data(base64Encoded: b64) {
            return data
        }
        if value is String || value is NSNumber { return value }
        if let array = value as? [Any] {
            let mapped = array.compactMap { backupPlistSafe($0) }
            return mapped.count == array.count ? mapped : nil
        }
        if let dict = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (k, v) in dict {
                guard let mv = backupPlistSafe(v) else { return nil }
                result[k] = mv
            }
            return result
        }
        return nil
    }

    /// 日志：查看 / 清空（导出入口放在日志查看器右上角）
    private var logSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "日志")
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    logActionButton(icon: "doc.text.magnifyingglass", title: "查看日志") {
                        showLogViewer = true
                    }
                    logActionButton(icon: "trash", title: "清空日志") {
                        ATMusicLogger.shared.clear()
                        ToastCenter.shared.show("日志已清空")
                    }
                }
            }
            .padding(14)
            .background {
                ATMusicGlass(shape: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
    }

    private func logActionButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(LocalizedStringKey(title))
            }
            .font(ATMusicFont.appFont(13, .semibold))
            .foregroundStyle(Color.atmusicLabel)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background {
                ATMusicGlass(shape: RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
        }
        .buttonStyle(GlassPressButtonStyle(scale: 0.95))
    }

    private var footerNote: some View {
        VStack(spacing: 6) {
            Text("AT Music · v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") (Build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"))")
                .font(ATMusicFont.appFont(12, .semibold))
                .foregroundStyle(Color.atmusicLabel.opacity(0.85))
            Text("仅供学习交流，纯 AI 实现此应用")
                .font(ATMusicFont.appFont(11))
                .foregroundStyle(Color.atmusicComment.opacity(0.7))
            Text("接入网易云音乐、QQ 音乐、酷狗音乐等公开接口")
                .font(ATMusicFont.appFont(11))
                .foregroundStyle(Color.atmusicComment.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    /// 壁纸格子：点击应用到所选外观；使用中的壁纸显示主题色边框+勾选；右上角删除
    private func wallpaperCell(path: String, appearance: ATMusicWallpaperAppearance) -> some View {
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
                .frame(height: 108)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Color.atmusicAmber)
                            .background { ATMusicSurface(shape: Circle()) }
                            .padding(5)
                    }
                }
            }
            .buttonStyle(.plain)

            Button {
                ATMusicHaptics.medium()
                theme.deleteWallpaper(at: path)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.atmusicComment)
                    .frame(width: 28, height: 28)
                    .background { ATMusicSurface(shape: Circle()) }
                    .clipShape(Circle())
                    .contentShape(Circle())
                    .padding(6)
            }
            .buttonStyle(.plain)
            .zIndex(2)
        }
    }
}

// MARK: - 均衡器

struct EqualizerSettingsView: View {
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var equalizer = ATMusicEqualizer.shared
    @State private var newPresetName = ""
    @State private var showPresetNamePrompt = false

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { equalizer.isEnabled },
            set: { equalizer.setEnabled($0) }
        )
    }

    private func gainBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: { equalizer.bandGains.indices.contains(index) ? equalizer.bandGains[index] : 0 },
            set: { equalizer.setBandGain(at: index, to: $0) }
        )
    }

    private var preampBinding: Binding<Double> {
        Binding(
            get: { equalizer.preampGain },
            set: { equalizer.setPreampGain($0) }
        )
    }

    var body: some View {
        ATMusicNavigationStack {
            ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        EqualizerResponseView(
                            gains: equalizer.bandGains,
                            preampGain: equalizer.preampGain
                        )
                        controlCard
                        presetCard
                        bandsCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 32)
                    .frame(maxWidth: 680)
                    .frame(maxWidth: .infinity)
                }
                .atmusicScrollIndicatorsHidden()
            }
            .navigationTitle(atmusicLocalized("均衡器", "Equalizer"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(atmusicLocalized("完成", "Done")) { dismiss() }
                }
            }
            .alert(
                atmusicLocalized("保存自定义预设", "Save custom preset"),
                isPresented: $showPresetNamePrompt
            ) {
                TextField(
                    atmusicLocalized("预设名称", "Preset name"),
                    text: $newPresetName
                )
                Button(atmusicLocalized("保存", "Save")) {
                    if equalizer.saveCustomPreset(name: newPresetName) {
                        ATMusicHaptics.select()
                    }
                    newPresetName = ""
                }
                Button(atmusicLocalized("取消", "Cancel"), role: .cancel) {
                    newPresetName = ""
                }
            } message: {
                Text(atmusicLocalized("保存当前频段和前级增益，之后可以一键恢复。", "Save the current bands and preamp for one-tap recall later."))
            }
        }
    }

    private var controlCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: enabledBinding) {
                HStack(spacing: 11) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.atmusicAmber)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(atmusicLocalized("启用均衡器", "Enable Equalizer"))
                            .font(ATMusicFont.appFont(15, .semibold))
                            .foregroundStyle(Color.atmusicLabel)
                        Text(atmusicLocalized("播放时实时应用当前调节", "Apply the current tuning while playing"))
                            .font(ATMusicFont.appFont(11))
                            .foregroundStyle(Color.atmusicComment)
                    }
                }
            }
            .toggleStyle(.switch)
            .tint(Color.atmusicAmber)

            Text(atmusicLocalized("均衡器仅处理 AT Music 当前播放的音乐，不影响其他 App。", "The equalizer only processes music playing in AT Music."))
                .font(ATMusicFont.appFont(11))
                .foregroundStyle(Color.atmusicComment)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider().overlay(Color.atmusicComment.opacity(0.14))

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(atmusicLocalized("前级增益", "Preamp"))
                        .font(ATMusicFont.appFont(13, .medium))
                        .foregroundStyle(Color.atmusicLabel)
                    Spacer()
                    Text(String(format: "%+.1f dB", equalizer.preampGain))
                        .font(ATMusicFont.appFont(12, .semibold))
                        .foregroundStyle(abs(equalizer.preampGain) > 0.01 ? Color.atmusicAmber : Color.atmusicComment)
                        .monospacedDigit()
                }
                Slider(value: preampBinding, in: -ATMusicEqualizer.maximumGain...ATMusicEqualizer.maximumGain, step: 0.5)
                    .tint(Color.atmusicAmber)
                    .transaction { transaction in transaction.animation = nil }
                HStack {
                    Text("-12")
                    Spacer()
                    Text(atmusicLocalized("不增益", "Unity"))
                    Spacer()
                    Text("+12")
                }
                .font(ATMusicFont.appFont(10))
                .foregroundStyle(Color.atmusicComment.opacity(0.75))
            }
        }
        .padding(14)
        .background { ATMusicGlass(shape: RoundedRectangle(cornerRadius: 18, style: .continuous)) }
    }

    private var presetCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(atmusicLocalized("预设", "Preset"))
                    .font(ATMusicFont.appFont(14, .semibold))
                    .foregroundStyle(Color.atmusicLabel)
                Spacer()
                Menu {
                    ForEach(ATMusicEqualizerPreset.allCases.filter { $0 != .custom }) { preset in
                        Button(preset.displayName) {
                            equalizer.applyPreset(preset)
                            ATMusicHaptics.select()
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(equalizer.selectedCustomPresetName ?? equalizer.selectedPreset.displayName)
                            .font(ATMusicFont.appFont(13, .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(Color.atmusicAmber)
                    .padding(.horizontal, 11)
                    .frame(height: 31)
                    .background { ATMusicSurface(shape: Capsule()) }
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(ATMusicEqualizerPreset.allCases.filter { $0 != .custom }) { preset in
                    let selected = equalizer.selectedPreset == preset
                    Button {
                        equalizer.applyPreset(preset)
                        ATMusicHaptics.select()
                    } label: {
                        Text(preset.displayName)
                            .font(ATMusicFont.appFont(11.5, selected ? .semibold : .regular))
                            .atmusicSelectionForeground(selected: selected, accent: .atmusicAmber)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                            .background {
                                ATMusicSelectableSurface(selected: selected, shape: Capsule(), accent: .atmusicAmber)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }

            if !equalizer.customPresets.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text(atmusicLocalized("我的预设", "My presets"))
                        .font(ATMusicFont.appFont(12, .semibold))
                        .foregroundStyle(Color.atmusicComment)
                    ForEach(equalizer.customPresets) { preset in
                        HStack(spacing: 8) {
                            Button {
                                equalizer.applyCustomPreset(preset)
                                ATMusicHaptics.select()
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: equalizer.selectedCustomPresetName == preset.name ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(equalizer.selectedCustomPresetName == preset.name ? Color.atmusicAmber : Color.atmusicComment)
                                    Text(preset.name)
                                        .font(ATMusicFont.appFont(12.5, .medium))
                                        .foregroundStyle(Color.atmusicLabel)
                                        .lineLimit(1)
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                            Button {
                                equalizer.deleteCustomPreset(preset)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.atmusicComment)
                                    .frame(width: 28, height: 28)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    newPresetName = equalizer.selectedCustomPresetName ?? ""
                    showPresetNamePrompt = true
                } label: {
                    Label(atmusicLocalized("保存当前预设", "Save current preset"), systemImage: "square.and.arrow.down")
                        .font(ATMusicFont.appFont(12.5, .medium))
                        .foregroundStyle(Color.atmusicAmber)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 10, style: .continuous)) }
                }
                .buttonStyle(.plain)

                Button {
                    equalizer.reset()
                    ATMusicHaptics.select()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.atmusicComment)
                        .frame(width: 42, height: 34)
                        .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 10, style: .continuous)) }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(atmusicLocalized("重置调节", "Reset adjustments"))
            }
        }
        .padding(14)
        .background { ATMusicGlass(shape: RoundedRectangle(cornerRadius: 18, style: .continuous)) }
    }

    private var bandsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(atmusicLocalized("自定义调节", "Custom tuning"))
                        .font(ATMusicFont.appFont(14, .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                    Text(atmusicLocalized("范围 -12 dB 至 +12 dB", "Range: -12 dB to +12 dB"))
                        .font(ATMusicFont.appFont(11))
                        .foregroundStyle(Color.atmusicComment)
                }
                Spacer()
            }

            ForEach(Array(ATMusicEqualizer.bandFrequencies.enumerated()), id: \.offset) { index, frequency in
                equalizerBandRow(index: index, frequency: frequency)
                if index < ATMusicEqualizer.bandFrequencies.count - 1 {
                    Divider().overlay(Color.atmusicComment.opacity(0.14))
                }
            }
        }
        .padding(14)
        .background { ATMusicGlass(shape: RoundedRectangle(cornerRadius: 18, style: .continuous)) }
    }

    private func equalizerBandRow(index: Int, frequency: Double) -> some View {
        let gain = equalizer.bandGains.indices.contains(index) ? equalizer.bandGains[index] : 0
        return VStack(spacing: 6) {
            HStack {
                Text(frequencyLabel(frequency))
                    .font(ATMusicFont.appFont(13, .medium))
                    .foregroundStyle(Color.atmusicLabel)
                Spacer()
                Text(String(format: "%+.1f dB", gain))
                    .font(ATMusicFont.appFont(12, .semibold))
                    .foregroundStyle(abs(gain) > 0.01 ? Color.atmusicAmber : Color.atmusicComment)
                    .monospacedDigit()
            }
            Slider(value: gainBinding(index), in: -ATMusicEqualizer.maximumGain...ATMusicEqualizer.maximumGain, step: 0.5)
                .tint(Color.atmusicAmber)
                .transaction { transaction in transaction.animation = nil }
            HStack {
                Text("-12")
                Spacer()
                Text("0")
                Spacer()
                Text("+12")
            }
            .font(ATMusicFont.appFont(10))
            .foregroundStyle(Color.atmusicComment.opacity(0.75))
        }
    }

    private func frequencyLabel(_ frequency: Double) -> String {
        if frequency >= 1_000 {
            let value = frequency / 1_000
            return value.rounded() == value ? "\(Int(value)) kHz" : String(format: "%.1f kHz", value)
        }
        return "\(Int(frequency)) Hz"
    }
}

private struct EqualizerResponseView: View {
    let gains: [Double]
    let preampGain: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(atmusicLocalized("频响预览", "Response preview"))
                        .font(ATMusicFont.appFont(14, .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                    Text(atmusicLocalized("拖动下方频段，实时塑造声音", "Shape the sound in real time by tuning each band below"))
                        .font(ATMusicFont.appFont(11))
                        .foregroundStyle(Color.atmusicComment)
                }
                Spacer()
                Image(systemName: "waveform.path")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.atmusicAmber)
            }

            GeometryReader { geometry in
                let width = geometry.size.width
                let height = geometry.size.height
                let values = responseValues
                ZStack {
                    VStack(spacing: 0) {
                        ForEach(0..<5, id: \.self) { _ in
                            Divider().overlay(Color.atmusicComment.opacity(0.12))
                            Spacer()
                        }
                    }
                    Path { path in
                        guard let first = values.first else { return }
                        path.move(to: CGPoint(x: 0, y: yPosition(first, height: height)))
                        for index in values.indices.dropFirst() {
                            let x = width * CGFloat(index) / CGFloat(max(values.count - 1, 1))
                            path.addLine(to: CGPoint(x: x, y: yPosition(values[index], height: height)))
                        }
                    }
                    .stroke(
                        LinearGradient(
                            colors: [Color.atmusicAmber.opacity(0.65), Color.atmusicAmber, Color.atmusicHighlight],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
                    )
                    Path { path in
                        guard let first = values.first else { return }
                        path.move(to: CGPoint(x: 0, y: height))
                        path.addLine(to: CGPoint(x: 0, y: yPosition(first, height: height)))
                        for index in values.indices.dropFirst() {
                            let x = width * CGFloat(index) / CGFloat(max(values.count - 1, 1))
                            path.addLine(to: CGPoint(x: x, y: yPosition(values[index], height: height)))
                        }
                        path.addLine(to: CGPoint(x: width, y: height))
                        path.closeSubpath()
                    }
                    .fill(
                        LinearGradient(
                            colors: [Color.atmusicAmber.opacity(0.22), Color.atmusicAmber.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
            }
            .frame(height: 108)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.7)
            }

            HStack {
                Text("31 Hz")
                Spacer()
                Text("1 kHz")
                Spacer()
                Text("16 kHz")
            }
            .font(ATMusicFont.appFont(10))
            .foregroundStyle(Color.atmusicComment)
        }
        .padding(14)
        .background { ATMusicGlass(shape: RoundedRectangle(cornerRadius: 18, style: .continuous)) }
    }

    private var responseValues: [Double] {
        guard !gains.isEmpty else { return [preampGain] }
        return gains.map { min(max($0 + preampGain * 0.35, -12), 12) }
    }

    private func yPosition(_ value: Double, height: CGFloat) -> CGFloat {
        let normalized = (value + 12) / 24
        return height * CGFloat(1 - normalized)
    }
}

// MARK: - 壁纸照片选择器（PHPicker 封装：iOS 14+ 兼容，支持多选图片）

struct WallpaperPhotoPicker: UIViewControllerRepresentable {
    let onPicked: (Data) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: WallpaperPhotoPicker
        init(_ parent: WallpaperPhotoPicker) { self.parent = parent }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let firstResult = results.first else { return }
            let provider = firstResult.itemProvider
            if provider.canLoadObject(ofClass: UIImage.self) {
                provider.loadObject(ofClass: UIImage.self) { image, error in
                    if let uiImage = image as? UIImage {
                        let finalData = SynologyAPI.shared.optimizedCoverData(uiImage.jpegData(compressionQuality: 0.90) ?? Data())
                        if !finalData.isEmpty {
                            DispatchQueue.main.async {
                                self.parent.onPicked(finalData)
                            }
                        }
                    } else {
                        provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                            guard let data, !data.isEmpty else { return }
                            let opt = SynologyAPI.shared.optimizedCoverData(data)
                            DispatchQueue.main.async {
                                self.parent.onPicked(opt)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 字体文件选择器（UIDocumentPicker 包装，比 SwiftUI fileImporter 稳定：所有文件可选，系统 asCopy 复制到沙盒）

struct FontDocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: FontDocumentPicker
        init(_ parent: FontDocumentPicker) { self.parent = parent }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            parent.onPick(url)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
    }
}
// MARK: - 配置备份文档（SwiftUI 原生 fileExporter 导出，稳定可靠）

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
// MARK: - 配置备份文件选择器（UIDocumentPicker 封装：比 SwiftUI fileImporter 稳定，所有文件可选）

struct BackupDocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json, .plainText, .item], asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: BackupDocumentPicker
        init(_ parent: BackupDocumentPicker) { self.parent = parent }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            parent.onPick(url)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
    }
}
