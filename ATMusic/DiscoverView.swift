import SwiftUI
import UIKit

private enum DiscoverRoute: Hashable {
    case topList(TopList)
    case playlist(Playlist)
    case qqTopList(QQTopInfo)
    case kugouTopList(KugouTopInfo)
    case dailySongs([Song])
}

struct DiscoverView: View {
    var onOpenProfile: () -> Void = {}
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ObservedObject private var platformPrefs = PlatformPreferenceStore.shared
    @ObservedObject private var synologySession = SynologyAPI.shared
    @ObservedObject private var subsonicSession = SubsonicAPI.shared
    @ObservedObject private var jellyfinSession = JellyfinAPI.shared
    @ObservedObject private var webdavSession = WebDAVAPI.shared

    @State private var topLists: [TopList] = []
    @State private var dailySongs: [Song] = []
    @State private var personalized: [Playlist] = []

    @State private var loading = true
    @State private var errorMessage: String?
    @State private var navigationPath: [DiscoverRoute] = []
    @State private var legacyRoute: DiscoverRoute?
    @State private var recommendationActionLoading: String?
    @State private var showSectionSort = false
    /// 主页板块顺序（每日推荐 / 排行榜 / 歌单广场，可自定义）
    @State private var homeOrder = SectionOrderStore.load(SectionOrderStore.homeKey, defaults: SectionOrderStore.homeDefaults)

    /// 三个平台都保留每日推荐、排行榜和歌单板块，QQ 歌单板块展示官网推荐的热门歌单。
    private var availableSections: [String] { SectionOrderStore.homeDefaults }
    /// 首页数据源：记住上次选择，下次打开仍保持该平台（默认网易云）
    @AppStorage("atmusic.homeSource") private var homeSourceRaw = SearchProvider.netease.rawValue
    /// 首页范围：聚合全部音源，或锁定单个平台。
    @AppStorage("atmusic.homeScope") private var homeScopeRaw = "single"
    @AppStorage("atmusic.home18DefaultApplied") private var home18DefaultApplied = false
    @AppStorage("atmusic.homeHideUsername") private var homeHideUsername = false
    @AppStorage("atmusic.pauseHomeRendering") private var homeRenderingPaused = false
    @AppStorage("atmusic.homeHeaderHideSort") private var homeHeaderHideSort = false
    @AppStorage("atmusic.homeHeaderHideRefresh") private var homeHeaderHideRefresh = true
    @AppStorage("atmusic.homeWallpaperBlur") private var homeWallpaperBlur = 0.0
    @AppStorage(PlatformPreferenceStore.hidePickerKey) private var hidePlatformPicker = false
    @AppStorage("atmusic.uiStyle") private var uiStyleRaw = ATMusicUIStyle.liquid.rawValue
    @AppStorage("atmusic.showSongVIPBadge") private var showSongVIPBadge = true
    private var homeProviders: [SearchProvider] { platformPrefs.enabledSearchProviders }
    /// 首页数据源：网易云 / QQ音乐（与搜索页同一控件样式）
    private var source: SearchProvider {
        guard let saved = SearchProvider(rawValue: homeSourceRaw), homeProviders.contains(saved) else {
            return homeProviders.first ?? .netease
        }
        return saved
    }
    private var isHomeAggregate: Bool { homeScopeRaw == "aggregate" }
    private var isNativeClean: Bool { ATMusicUIStyle(rawValue: uiStyleRaw) == .nativeClean }

    /// 横向滚动方形卡封面边长（四风格统一）
    private func hScrollCardSize(isIPadRegular: Bool) -> CGFloat {
        if isIPadRegular { return 176 }
        if isNativeClean { return 140 }
        if uiStyleRaw == ATMusicUIStyle.compact.rawValue { return 120 }
        return 136
    }

    /// 推荐功能卡圆角（四风格统一）
    private var featureCardRadius: CGFloat {
        if isNativeClean { return 12 }
        if uiStyleRaw == ATMusicUIStyle.compact.rawValue { return 14 }
        return 18
    }

    @State private var qqTopLists: [QQTopInfo] = []
    @State private var kugouTopLists: [KugouTopInfo] = []
    /// 首页加载去重：SwiftUI 视图刷新时 .task 可能被重复触发，避免网络请求风暴。
    @State private var activeLoadKey: String?
    @State private var lastLoadedKey = ""
    @State private var lastLoadedAt = Date.distantPast
    /// 聚合页上次完成加载所属的小时桶（NAS 今日推荐按小时换批的依据）；
    /// 页面常驻时靠它发现“已跨小时”，触发重新取数换批。
    @State private var aggregateHourBucket: Int?
    @Environment(\.scenePhase) private var scenePhase
    /// 首次启动免责声明：确认进入后若加载失败自动刷新
    @AppStorage("atmusic.disclaimerAccepted") private var disclaimerAccepted = false
    /// 网易云歌单广场当前分类（「全部」展示官方精品歌单）
    /// 官方歌单分类列表

    var body: some View {
        let _ = theme.accent
        ATMusicNavigationStackWithPath(path: $navigationPath) {
        ZStack {
            // 主页背景：壁纸/背景色永远在发现页生效（homeMode），同步开启时其他页面也生效
            GlassBackdrop(customColor: theme.customBackground, homeMode: true, wallpaperBlur: CGFloat(homeWallpaperBlur))
            // 实例级 UITabBar 清透风格（固定全透明，无需调节）
            TabBarAppearanceConfigurator()
            if #unavailable(iOS 16.0) {
                NavigationLink(
                    destination: discoverDestination(legacyRoute ?? .dailySongs([])),
                    isActive: Binding(
                        get: { legacyRoute != nil },
                        set: { if !$0 { legacyRoute = nil } }
                    )
                ) {
                    EmptyView()
                }
                .hidden()
            }
            ScrollView(.vertical, showsIndicators: false) {
                if !homeRenderingPaused {
                    VStack(alignment: .leading, spacing: isNativeClean ? 20 : 26) {
                        header
                        if !hidePlatformPicker {
                            providerPicker
                        }
                        if !isHomeAggregate && source == .synology {
                            SynologyAppleHomeSection()
                                .environmentObject(theme)
                                .environmentObject(player)
                        } else if let errorMessage {
                            ErrorStateView(message: errorMessage) {
                                Task { await load(force: true) }
                            }
                        } else if loading {
                            LoadingStateView()
                        } else {
                            // 板块按用户自定义顺序渲染（可拖拽排序）
                            ForEach(homeOrder.filter { availableSections.contains($0) }, id: \.self) { key in
                                switch key {
                                case "每日推荐":
                                    if isHomeAggregate || source == .netease || source == .kugou || !dailySongs.isEmpty {
                                        dailySection
                                    }
                                case "排行榜":
                                    if hasRankData { topListsSection }
                                case "最近播放":
                                    recentPlayedSection
                                default:
                                    EmptyView()
                                }
                            }
                        }
                    }
                    .padding(.horizontal, DeviceLayoutHelper.isIPadRegular(horizontalSizeClass) ? 28 : (isNativeClean ? 24 : 20))
                    .padding(.top, 12)
                    .padding(.bottom, 190)
                    .frame(maxWidth: DeviceLayoutHelper.contentMaxWidth(for: horizontalSizeClass))
                    .frame(maxWidth: .infinity)
                }
            }
            .atmusicScrollIndicatorsHidden()
            .refreshable {
                guard !homeRenderingPaused else { return }
                await load(force: true)
            }
            .task(id: "\(homeScopeRaw)-\(source.rawValue)-\(homeRenderingPaused)") {
                guard !homeRenderingPaused else { return }
                await load(force: false)
            }
            .onAppear {
                if !home18DefaultApplied {
                    homeScopeRaw = "single"
                    if platformPrefs.isEnabled(SearchProvider.netease) {
                        homeSourceRaw = SearchProvider.netease.rawValue
                    }
                    home18DefaultApplied = true
                }
                guard !homeRenderingPaused else { return }
                guard let saved = SearchProvider(rawValue: homeSourceRaw), homeProviders.contains(saved) else {
                    homeSourceRaw = (homeProviders.first ?? .netease).rawValue
                    return
                }
            }
            // 平台显示变化时立即无缝刷新并清除已隐藏平台的内容
            .onChange(of: platformPrefs.selectedRaw) { _ in
                let next = platformPrefs.ensureVisible(source)
                if next != source {
                    homeSourceRaw = next.rawValue
                }
                let enabledSources = Set(homeProviders.map(\.songSource))
                dailySongs.removeAll { !enabledSources.contains($0.source) }
                personalized.removeAll { !enabledSources.contains($0.source) }
                if !enabledSources.contains(.netease) { topLists = [] }
                if !enabledSources.contains(.qq) { qqTopLists = [] }
                if !enabledSources.contains(.kugou) { kugouTopLists = [] }
                Task { await load(force: true) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .atmusicPlatformPreferencesDidChange)) { _ in
                let next = platformPrefs.ensureVisible(source)
                if next != source {
                    homeSourceRaw = next.rawValue
                }
                let enabledSources = Set(homeProviders.map(\.songSource))
                dailySongs.removeAll { !enabledSources.contains($0.source) }
                personalized.removeAll { !enabledSources.contains($0.source) }
                if !enabledSources.contains(.netease) { topLists = [] }
                if !enabledSources.contains(.qq) { qqTopLists = [] }
                if !enabledSources.contains(.kugou) { kugouTopLists = [] }
                Task { await load(force: true) }
            }
            .onChange(of: source) { _ in
                guard !homeRenderingPaused else { return }
                homeOrder = SectionOrderStore.load(SectionOrderStore.homeKey, defaults: availableSections)
            }
            .onChange(of: disclaimerAccepted) { accepted in
                guard !homeRenderingPaused else { return }
                // 免责声明确认进入后：若首页加载失败则自动刷新（无需手动下拉）
                if accepted, errorMessage != nil {
                    Task { await load(force: true) }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .atmusicNeteaseLoginDidUpdate)) { _ in
                guard !homeRenderingPaused else { return }
                guard platformPrefs.isEnabled(SearchProvider.netease) else { return }
                reloadAfterLoginUpdate(.netease)
            }
            .onReceive(NotificationCenter.default.publisher(for: .atmusicQQLoginDidUpdate)) { _ in
                guard !homeRenderingPaused else { return }
                guard platformPrefs.isEnabled(SearchProvider.qq) else { return }
                reloadAfterLoginUpdate(.qq)
            }
            .onReceive(NotificationCenter.default.publisher(for: .atmusicKugouLoginDidUpdate)) { _ in
                guard !homeRenderingPaused else { return }
                guard platformPrefs.isEnabled(SearchProvider.kugou) else { return }
                reloadAfterLoginUpdate(.kugou)
            }
            // NAS 会话恢复/登录晚于聚合页首次加载时补刷新——其余三个平台都有登录刷新，
            // 此前唯独 NAS 缺失，会话一慢聚合页里 NAS 就整场缺席（2026-10-22 iPad 实报）。
            .onChange(of: synologySession.isLoggedIn) { loggedIn in
                guard !homeRenderingPaused else { return }
                guard loggedIn, platformPrefs.isEnabled(SearchProvider.synology) else { return }
                reloadAfterLoginUpdate(.synology)
            }
            .onChange(of: subsonicSession.isLoggedIn) { loggedIn in
                guard !homeRenderingPaused else { return }
                guard loggedIn, platformPrefs.isEnabled(SearchProvider.subsonic) else { return }
                reloadAfterLoginUpdate(.subsonic)
            }
            .onChange(of: jellyfinSession.isLoggedIn) { loggedIn in
                guard !homeRenderingPaused else { return }
                guard loggedIn, platformPrefs.isEnabled(SearchProvider.jellyfin) else { return }
                reloadAfterLoginUpdate(.jellyfin)
            }
            .onChange(of: webdavSession.isLoggedIn) { loggedIn in
                guard !homeRenderingPaused else { return }
                guard loggedIn, platformPrefs.isEnabled(SearchProvider.webdav) else { return }
                reloadAfterLoginUpdate(.webdav)
            }
            // 跨小时换批触发：NAS 今日推荐按小时种子轮换，但页面常驻/回前台时
            // .task 不会重新触发，旧批次会一直挂着（用户实报“NAS 歌单没变化”）。
            .onChange(of: scenePhase) { phase in
                if phase == .active { checkHourRollover() }
            }
            .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
                checkHourRollover()
            }
            .sheet(isPresented: $showSectionSort) {
                SectionOrderSheet(
                    title: "主页板块排序",
                    sections: availableSections,
                    order: $homeOrder,
                    platformOrder: Binding(
                        get: { platformPrefs.orderedRaw },
                        set: { platformPrefs.orderedRaw = $0 }
                    )
                )
                    .onDisappear { SectionOrderStore.save(SectionOrderStore.homeKey, homeOrder) }
            }
        }
            .atmusicNavigationDestination(for: DiscoverRoute.self) { route in
                discoverDestination(route)
            }
        }
    }

    @ViewBuilder
    private func discoverDestination(_ route: DiscoverRoute) -> some View {
        switch route {
        case .topList(let topList):
            TopListDetailView(topList: topList)
                .environmentObject(player)
                .environmentObject(auth)
        case .playlist(let playlist):
            PlaylistView(playlist: playlist)
                .environmentObject(player)
                .environmentObject(auth)
        case .qqTopList(let info):
            QQTopListDetailView(topID: info.id, name: info.name)
                .environmentObject(player)
                .environmentObject(auth)
        case .kugouTopList(let info):
            KugouTopListDetailView(topList: info)
                .environmentObject(player)
                .environmentObject(auth)
        case .dailySongs(let songs):
            DailySongsSheet(songs: songs)
                .environmentObject(player)
                .environmentObject(auth)
        }
    }

    private func openRoute(_ route: DiscoverRoute) {
        if #available(iOS 16.0, *) {
            navigationPath.append(route)
        } else {
            legacyRoute = route
        }
    }

    /// 顶部问候区：大标题 + 刷新按钮（对标 Apple Music 规范，去除副标题与额外边距，全局顶栏统一对齐）
    private var header: some View {
        HStack(alignment: .center) {
            Menu {
                homePlatformSelectionMenu
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(LocalizedStringKey(homeHeaderTitle))
                        .font(ATMusicFont.appFont(32, .bold))
                        .foregroundStyle(Color.atmusicLabel)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.atmusicComment)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("切换主页平台")

            Spacer()

            HStack(spacing: 10) {
                if isNativeClean {
                    Button {
                        ATMusicHaptics.tap()
                        onOpenProfile()
                    } label: {
                        AsyncImage(url: auth.user?.avatarURL) { phase in
                            if case .success(let image) = phase {
                                image.resizable().scaledToFill()
                            } else {
                                Image(systemName: "person.crop.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(Color.atmusicComment)
                            }
                        }
                        .frame(width: 42, height: 42)
                        .clipShape(Circle())
                        .background { ATMusicGlass(shape: Circle()) }
                    }
                    .buttonStyle(GlassPressButtonStyle(scale: 0.97))
                    .accessibilityLabel("我的")
                }
                if !homeHeaderHideSort {
                    GlassIconButton(systemName: "arrow.up.arrow.down") {
                        ATMusicHaptics.tap()
                        showSectionSort = true
                    }
                }
                if !homeHeaderHideRefresh {
                    GlassIconButton(systemName: "arrow.clockwise") {
                        ATMusicHaptics.tap()
                        Task { await load(force: true) }
                    }
                }
            }
        }
    }

    /// 主页平台切换：所有 UI 风格使用同一套紧凑胶囊。
    private var providerPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                homeProviderPill(
                    title: "聚合",
                    systemImage: "square.stack.3d.up.fill",
                    brandImageName: nil,
                    selected: isHomeAggregate,
                    tint: .atmusicAmber
                ) {
                    ATMusicHaptics.select()
                    homeScopeRaw = "aggregate"
                }

                ForEach(homeProviders) { provider in
                    homeProviderPill(
                        title: provider.rawValue,
                        systemImage: provider.brandImageName == nil ? provider.icon : nil,
                        brandImageName: provider.brandImageName,
                        selected: !isHomeAggregate && source == provider,
                        tint: .atmusicAmber
                    ) {
                        ATMusicHaptics.select()
                        homeScopeRaw = "single"
                        homeSourceRaw = provider.rawValue
                    }
                }
            }
            .padding(.vertical, 2)
            .padding(.trailing, isNativeClean ? 24 : 4)
        }
        .atmusicScrollIndicatorsHidden()
    }

    private func homeProviderPill(
        title: String,
        systemImage: String?,
        brandImageName: String?,
        selected: Bool,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let brandImageName {
                    Image(brandImageName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 15, height: 15)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(LocalizedStringKey(title))
                    .font(ATMusicFont.appFont(13, .semibold))
            }
            .atmusicSelectionForeground(selected: selected, accent: tint)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background {
                ATMusicSelectableSurface(selected: selected, shape: Capsule(), accent: tint)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(GlassPressButtonStyle(scale: 0.96))
    }

    private var homeHeaderTitle: String {
        if isHomeAggregate { return "聚合" }
        return source.rawValue
    }

    private var homeHeaderSubtitle: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let greeting: String
        switch hour {
        case 5..<12: greeting = "早上好"
        case 12..<18: greeting = "下午好"
        default: greeting = "晚上好"
        }
        if let nickname = auth.user?.nickname, !nickname.isEmpty {
            return "\(greeting) · \(nickname)"
        }
        return greeting
    }

    /// 每日推荐封面右下角播放状态：当前播放中显示动态指示器，暂停显示暂停，其余显示播放
    @ViewBuilder


    /// 网易云排行榜：全部榜单保留，热歌榜置顶
    private var neteaseTopLists: [TopList] {
        let preferredIDs = [19_723_756, 3_779_629, 2_884_035, 3_778_678, 60_198]
        let byID = Dictionary(uniqueKeysWithValues: topLists.map { ($0.id, $0) })
        let preferred = preferredIDs.compactMap { byID[$0] }
        if !preferred.isEmpty {
            return preferred
        }
        var list = topLists
        if let hot = list.first(where: { $0.name.contains("热歌榜") }),
           let idx = list.firstIndex(where: { $0.id == hot.id }), idx != 0 {
            list.remove(at: idx)
            list.insert(hot, at: 0)
        }
        return list
    }


    /// 当前平台是否有排行榜数据（网易云用 topLists，QQ 用 qqTopLists）
    private var hasRankData: Bool {
        if isHomeAggregate {
            return !topLists.isEmpty || !qqTopLists.isEmpty || !kugouTopLists.isEmpty
        }
        switch source {
        case .netease: return !topLists.isEmpty
        case .qq: return !qqTopLists.isEmpty
        case .kugou: return !kugouTopLists.isEmpty
        case .synology, .subsonic, .jellyfin, .webdav: return false
        }
    }

    // MARK: - 排行榜

    @ViewBuilder
    private var topListsSection: some View {
        if isHomeAggregate {
            aggregateTopListsSection
        } else {
            singlePlatformTopListsSection
        }
    }

    private var singlePlatformTopListsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "排行榜")
            if !hasRankData {
                EmptyStateView(icon: "chart.bar.xaxis", text: "排行榜暂时没有内容")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        switch source {
                        case .netease:
                            ForEach(neteaseTopLists, id: \.id) { item in
                                aggregateRankCard(name: atmusicChartName(item.name), subtitle: atmusicChartSubtitle(item.updateFrequency), coverURL: item.coverURL) {
                                    openRoute(DiscoverRoute.topList(item))
                                }
                            }
                        case .qq:
                            ForEach(qqTopLists, id: \.id) { item in
                                aggregateRankCard(name: atmusicChartName(item.name), subtitle: atmusicChartSubtitle(item.subTitle), coverURL: item.coverURL) {
                                    openRoute(DiscoverRoute.qqTopList(item))
                                }
                            }
                        case .kugou:
                            ForEach(kugouTopLists, id: \.id) { item in
                                aggregateRankCard(name: atmusicChartName(item.name), subtitle: atmusicChartSubtitle(item.updateFrequency), coverURL: item.coverURL) {
                                    openRoute(DiscoverRoute.kugouTopList(item))
                                }
                            }
                        case .synology, .subsonic, .jellyfin, .webdav:
                            EmptyView()
                        }
                    }
                    .padding(.vertical, 2)
                }
                .padding(.trailing, isNativeClean ? -24 : 0)
            }
        }
        .id("rankTopSection")
    }

    private var aggregateTopListsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "聚合排行榜")
            VStack(alignment: .leading, spacing: 20) {
                if platformPrefs.isEnabled(SearchProvider.netease), !topLists.isEmpty {
                    aggregateRankRow(title: "网易云音乐") {
                        ForEach(neteaseTopLists, id: \.id) { item in
                            aggregateRankCard(name: atmusicChartName(item.name), subtitle: atmusicChartSubtitle(item.updateFrequency), coverURL: item.coverURL) {
                                openRoute(DiscoverRoute.topList(item))
                            }
                        }
                    }
                }
                if platformPrefs.isEnabled(SearchProvider.qq), !qqTopLists.isEmpty {
                    aggregateRankRow(title: "QQ音乐") {
                        ForEach(qqTopLists, id: \.id) { item in
                            aggregateRankCard(name: atmusicChartName(item.name), subtitle: atmusicChartSubtitle(item.subTitle), coverURL: item.coverURL) {
                                openRoute(DiscoverRoute.qqTopList(item))
                            }
                        }
                    }
                }
                if platformPrefs.isEnabled(SearchProvider.kugou), !kugouTopLists.isEmpty {
                    aggregateRankRow(title: "酷狗音乐") {
                        ForEach(kugouTopLists, id: \.id) { item in
                            aggregateRankCard(name: atmusicChartName(item.name), subtitle: atmusicChartSubtitle(item.updateFrequency), coverURL: item.coverURL) {
                                openRoute(DiscoverRoute.kugouTopList(item))
                            }
                        }
                    }
                }
            }
        }
    }

    private func aggregateRankRow<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(ATMusicFont.appFont(16, .bold))
                .foregroundStyle(Color.atmusicLabel)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    content()
                }
                .padding(.vertical, 2)
            }
            .padding(.trailing, isNativeClean ? -24 : 0)
        }
    }

    private func aggregateRankCard(name: String, subtitle: String, coverURL: URL?, action: @escaping () -> Void) -> some View {
        let cardSize = hScrollCardSize(isIPadRegular: DeviceLayoutHelper.isIPadRegular(horizontalSizeClass))
        return Button {
            ATMusicHaptics.tap()
            action()
        } label: {
            MediaSquareCard(title: name, subtitle: subtitle, coverURL: coverURL, showSourceBadge: false, fixedCoverSize: cardSize)
        }
        .buttonStyle(GlassPressButtonStyle(scale: 0.96))
    }


    // MARK: - 每日推荐

    @ViewBuilder
    private var dailySection: some View {
        if isHomeAggregate {
            aggregateRecommendationCards
        } else {
            singlePlatformRecommendationCards
        }
    }


    private var aggregateRecommendationCards: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "推荐")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    recommendationCard(
                        title: "跨平台推荐",
                        subtitle: dailyRecommendationSubtitle,
                        icon: "sparkles",
                        coverURL: dailySongs.first?.coverURL,
                        gradient: [Color(red: 0.23, green: 0.38, blue: 0.82), Color(red: 0.53, green: 0.28, blue: 0.77)],
                        loadingKey: nil
                    ) {
                        openDailyRecommendations()
                    }

                    if homeProviders.contains(.netease) {
                        recommendationCard(
                            title: "红心雷达",
                            subtitle: "网易云 · 根据红心歌曲持续发现",
                            icon: "heart.circle.fill",
                            coverURL: player.currentSong?.coverURL,
                            gradient: [Color(red: 0.84, green: 0.16, blue: 0.38), Color(red: 0.98, green: 0.43, blue: 0.35)],
                            loadingKey: "heartbeat"
                        ) {
                            startHeartbeatMode()
                        }

                        recommendationCard(
                            title: "私人漫游",
                            subtitle: "网易云 · 从喜欢的歌开始漫游",
                            icon: "wave.3.right.circle.fill",
                            coverURL: nil,
                            gradient: [Color(red: 0.16, green: 0.22, blue: 0.42), Color(red: 0.41, green: 0.28, blue: 0.65)],
                            loadingKey: "fm"
                        ) {
                            startPersonalFM()
                        }
                    }

                    if homeProviders.contains(.kugou) {
                        recommendationCard(
                            title: "私人漫游",
                            subtitle: "酷狗音乐 · 个性推荐",
                            icon: "wave.3.right.circle.fill",
                            coverURL: nil,
                            gradient: [Color(red: 0.08, green: 0.46, blue: 0.82), Color(red: 0.18, green: 0.72, blue: 0.72)],
                            loadingKey: "kugouFM"
                        ) {
                            startKugouPersonalFM()
                        }
                    }
                }
                .padding(.vertical, 3)
            }
            .padding(.trailing, isNativeClean ? -24 : 0)
        }
    }

    private var singlePlatformRecommendationCards: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "推荐")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    recommendationCard(
                        title: "每日推荐",
                        subtitle: dailyRecommendationSubtitle,
                        icon: "calendar",
                        coverURL: dailySongs.first?.coverURL,
                        gradient: [Color(red: 0.95, green: 0.36, blue: 0.28), Color(red: 0.96, green: 0.68, blue: 0.30)],
                        loadingKey: nil,
                        isWide: source == .qq
                    ) {
                        openDailyRecommendations()
                    }

                    if source == .netease {
                        recommendationCard(
                            title: "红心雷达",
                            subtitle: "根据红心歌曲持续发现相似音乐",
                            icon: "heart.circle.fill",
                            coverURL: player.currentSong?.coverURL,
                            gradient: [Color(red: 0.84, green: 0.16, blue: 0.38), Color(red: 0.98, green: 0.43, blue: 0.35)],
                            loadingKey: "heartbeat"
                        ) {
                            startHeartbeatMode()
                        }

                        recommendationCard(
                            title: "私人漫游",
                            subtitle: "从喜欢的歌开始漫游",
                            icon: "wave.3.right.circle.fill",
                            coverURL: nil,
                            gradient: [Color(red: 0.16, green: 0.22, blue: 0.42), Color(red: 0.41, green: 0.28, blue: 0.65)],
                            loadingKey: "fm"
                        ) {
                            startPersonalFM()
                        }
                    } else if source == .kugou {
                        recommendationCard(
                            title: "私人漫游",
                            subtitle: "酷狗音乐个性推荐",
                            icon: "wave.3.right.circle.fill",
                            coverURL: nil,
                            gradient: [Color(red: 0.08, green: 0.46, blue: 0.82), Color(red: 0.18, green: 0.72, blue: 0.72)],
                            loadingKey: "kugouFM"
                        ) {
                            startKugouPersonalFM()
                        }
                    }
                }
                .padding(.vertical, 3)
            }
            .padding(.trailing, isNativeClean ? -24 : 0)
        }
    }


    private var dailyRecommendationSubtitle: String {
        if dailySongs.isEmpty {
            return atmusicLocalized("每天 6:00 更新", "Refreshes at 6:00 daily")
        }
        return String(format: atmusicLocalized("%d 首 · 每天 6:00 更新", "%d songs · refreshes at 6:00 daily"), dailySongs.count)
    }

    private func recommendationCard(
        title: String,
        subtitle: String,
        icon: String,
        coverURL: URL?,
        gradient: [Color],
        loadingKey: String?,
        cardSize: CGFloat? = nil,
        isWide: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let isRegular = DeviceLayoutHelper.isIPadRegular(horizontalSizeClass)
        let defaultSize: CGFloat = isRegular ? 180 : (isNativeClean ? 160 : 168)
        let resolvedCardSize = cardSize ?? defaultSize
        let cardWidth = isWide ? (isRegular ? 380 : resolvedCardSize * 2) : resolvedCardSize
        let cardHeight = resolvedCardSize
        return Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                if let coverURL {
                    CoverImage(url: coverURL, size: resolvedCardSize, cornerRadius: featureCardRadius, width: cardWidth, height: cardHeight)
                        .overlay {
                            LinearGradient(
                                colors: [.black.opacity(0.05), .black.opacity(0.62)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                } else {
                    RoundedRectangle(cornerRadius: featureCardRadius, style: .continuous)
                        .fill(LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: cardWidth, height: cardHeight)
                        .overlay(alignment: .topTrailing) {
                            Circle()
                                .fill(.white.opacity(0.16))
                                .frame(width: 92, height: 92)
                                .blur(radius: 3)
                                .offset(x: 24, y: -26)
                        }
                        .overlay(alignment: .center) {
                            Image(systemName: icon)
                                .font(.system(size: 46, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.32))
                                .offset(x: 34, y: -18)
                        }
                }

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 7) {
                        Image(systemName: icon)
                            .font(.system(size: 15, weight: .bold))
                        if let loadingKey, recommendationActionLoading == loadingKey {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(0.72)
                        }
                    }
                    .foregroundStyle(.white.opacity(0.92))
                    Spacer(minLength: 0)
                    Text(LocalizedStringKey(title))
                        .font(ATMusicFont.appFont(isNativeClean ? 20 : 18, .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(ATMusicFont.appFont(12, .semibold))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                }
                .padding(14)
            }
            .frame(width: cardWidth, height: cardHeight)
            .clipShape(RoundedRectangle(cornerRadius: featureCardRadius, style: .continuous))
            .shadow(color: Color.black.opacity(isNativeClean ? 0.06 : 0.12), radius: 16, x: 0, y: 8)
            .contentShape(RoundedRectangle(cornerRadius: featureCardRadius, style: .continuous))
        }
        .buttonStyle(GlassPressButtonStyle(scale: 0.95))
        .disabled(loadingKey != nil && recommendationActionLoading != nil)
    }

    private func openDailyRecommendations() {
        ATMusicHaptics.tap()
        guard !dailySongs.isEmpty else {
            ToastCenter.shared.show("推荐内容正在加载")
            return
        }
        openRoute(.dailySongs(dailySongs))
    }

    private func startPersonalFM() {
        guard auth.isLoggedIn else {
            ToastCenter.shared.show("请先登录网易云音乐")
            return
        }
        guard recommendationActionLoading == nil else { return }
        recommendationActionLoading = "fm"
        Task {
            defer { Task { @MainActor in recommendationActionLoading = nil } }
            do {
                let songs = try await NetEaseAPI.shared.personalFM()
                await MainActor.run {
                    if songs.isEmpty {
                        ToastCenter.shared.show("私人漫游暂时没有推荐")
                    } else {
                        player.play(songs: songs, startAt: 0)
                        ToastCenter.shared.show("已开启私人漫游")
                    }
                }
            } catch {
                await MainActor.run {
                    ATMusicLogger.shared.log("私人漫游加载失败：\(error.localizedDescription)", level: .error)
                    ToastCenter.shared.show("私人漫游加载失败")
                }
            }
        }
    }

    private func startKugouPersonalFM() {
        guard KugouMusicAuth.shared.isLoggedIn else {
            ToastCenter.shared.show("请先登录酷狗音乐")
            return
        }
        guard recommendationActionLoading == nil else { return }
        recommendationActionLoading = "kugouFM"
        Task {
            defer { Task { @MainActor in recommendationActionLoading = nil } }
            do {
                let songs = try await KugouMusicAPI.shared.personalFM(limit: 12)
                await MainActor.run {
                    if songs.isEmpty {
                        ToastCenter.shared.show("私人漫游暂时没有推荐")
                    } else {
                        player.play(songs: songs, startAt: 0)
                        ToastCenter.shared.show("已开启私人漫游")
                    }
                }
            } catch {
                await MainActor.run {
                    ATMusicLogger.shared.log("酷狗私人漫游加载失败：\(error.localizedDescription)", level: .error)
                    ToastCenter.shared.show("私人漫游加载失败")
                }
            }
        }
    }

    private func startHeartbeatMode() {
        guard let uid = auth.user?.uid else {
            ToastCenter.shared.show("请先登录网易云音乐")
            return
        }
        guard recommendationActionLoading == nil else { return }
        recommendationActionLoading = "heartbeat"
        Task {
            defer { Task { @MainActor in recommendationActionLoading = nil } }
            do {
                let playlists = try await NetEaseAPI.shared.userPlaylists(uid: uid)
                let liked = playlists.first(where: { $0.isNetEaseLikedPlaylist })
                let songs: [Song]
                if let liked {
                    let likedSongs = try await NetEaseAPI.shared.playlistTracks(id: liked.id)
                    guard let seed = likedSongs.randomElement() else {
                        await MainActor.run { ToastCenter.shared.show("先收藏一些喜欢的歌曲吧") }
                        return
                    }
                    songs = try await NetEaseAPI.shared.intelligenceList(songID: seed.id, playlistID: liked.id)
                    ATMusicLogger.shared.log("心动模式：喜欢歌单 specialType=\(liked.specialType) id=\(liked.id) seed=\(seed.id) 返回 \(songs.count) 首", level: songs.isEmpty ? .warn : .info)
                } else if let seed = dailySongs.randomElement() ?? player.currentSong {
                    songs = try await NetEaseAPI.shared.simiSongs(id: seed.id)
                    ATMusicLogger.shared.log("心动模式：未找到喜欢歌单，使用相似歌曲兜底 seed=\(seed.id) 返回 \(songs.count) 首", level: songs.isEmpty ? .warn : .info)
                } else {
                    await MainActor.run { ToastCenter.shared.show("先播放或收藏一些歌曲吧") }
                    return
                }
                await MainActor.run {
                    if songs.isEmpty {
                        ToastCenter.shared.show("心动模式暂时不可用")
                    } else {
                        player.play(songs: songs, startAt: 0)
                        ToastCenter.shared.show("已开启心动模式")
                    }
                }
            } catch {
                await MainActor.run {
                    ATMusicLogger.shared.log("心动模式加载失败：\(error.localizedDescription)", level: .error)
                    ToastCenter.shared.show("心动模式加载失败")
                }
            }
        }
    }

    @ViewBuilder
    private var homePlatformSelectionMenu: some View {
        let current = SearchProvider(rawValue: homeSourceRaw) ?? homeProviders.first ?? .netease
        Button {
            ATMusicHaptics.select()
            homeScopeRaw = "aggregate"
        } label: {
            Label("聚合全部音源", systemImage: isHomeAggregate ? "checkmark" : "square.stack.3d.up.fill")
        }
        Divider()
        ForEach(homeProviders) { provider in
            Button {
                ATMusicHaptics.select()
                homeScopeRaw = "single"
                homeSourceRaw = provider.rawValue
            } label: {
                Label(LocalizedStringKey(provider.rawValue), systemImage: !isHomeAggregate && provider == current ? "checkmark" : provider.icon)
            }
        }
    }

    // MARK: - 最近播放（原“歌单广场”栏改为最近播放歌曲，方块横滑）

    /// 当前主页显示的最近播放歌曲：
    /// 聚合页按播放顺序展示所有平台的最近播放；单平台主页只显示本平台的最近播放。
    /// 合并多个歌曲数组并按 identityKey 去重，保持输入顺序（推荐栏合并每日推荐 / 红心 / 私人FM）。
    private static func mergeDaily(_ arrays: [[Song]]) -> [Song] {
        var seen = Set<String>()
        var result: [Song] = []
        for arr in arrays {
            for song in arr where seen.insert(song.identityKey).inserted {
                result.append(song)
            }
        }
        return Array(result.prefix(60))
    }
    private var recentPlayedSongs: [Song] {
        if isHomeAggregate { return player.history }
        let songSource = source.songSource
        return player.history.filter { $0.source == songSource }
    }

    @ViewBuilder
    private var recentPlayedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "最近播放")
            if recentPlayedSongs.isEmpty {
                EmptyStateView(icon: "clock.arrow.circlepath", text: "暂无最近播放")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(Array(recentPlayedSongs.enumerated()), id: \.element.identityKey) { index, song in
                            recentSongCard(song, index: index)
                        }
                    }
                    .padding(.vertical, 2)
                    .padding(.trailing, isNativeClean ? 24 : 4)
                }
                .atmusicScrollIndicatorsHidden()
            }
        }
    }

    private func recentSongCard(_ song: Song, index: Int) -> some View {
        let size = hScrollCardSize(isIPadRegular: DeviceLayoutHelper.isIPadRegular(horizontalSizeClass))
        return Button {
            ATMusicHaptics.tap()
            player.play(songs: recentPlayedSongs, startAt: index)
        } label: {
            MediaSquareCard(title: song.name, subtitle: song.artists, coverURL: song.coverURL, source: song.source, showSourceBadge: isHomeAggregate, fixedCoverSize: size, titleLineLimit: 1)
        }
        .buttonStyle(GlassPressButtonStyle(scale: 0.96))
    }


    // MARK: - 动作

    @MainActor
    private func load(force: Bool = false) async {
        guard !homeRenderingPaused else { return }
        if isHomeAggregate {
            await loadAggregate(force: force)
            return
        }
        let cache = DiscoverCache.shared
        let requestedSource = source
        let loadKey = requestedSource.rawValue
        if activeLoadKey == loadKey {
            return
        }
        if !force,
           lastLoadedKey == loadKey,
           Date().timeIntervalSince(lastLoadedAt) < 20,
           hasAnyData {
            loading = false
            errorMessage = nil
            return
        }
        activeLoadKey = loadKey
        defer {
            if activeLoadKey == loadKey {
                activeLoadKey = nil
            }
        }
        let cacheable = true
        var workingSnapshot = DiscoverCache.Snapshot()

        if let cached = cache.cached(for: requestedSource), !force, cacheable {
            guard !Task.isCancelled, requestedSource == source else { return }
            workingSnapshot = cached
            apply(cached)
            loading = false
            errorMessage = nil
            lastLoadedKey = loadKey
            lastLoadedAt = Date()
            if cache.isFresh(cached) { return }
            // 缓存过期：先展示旧快照，后台渐进式刷新。
        } else {
            // 只有“刷新当前平台”才保留屏幕上的现有内容。
            // 从另一个平台切过来时绝不能把上一平台的数据混入新平台。
            if force, lastLoadedKey == loadKey, hasAnyData {
                workingSnapshot = currentSnapshot()
            } else if lastLoadedKey != loadKey {
                apply(DiscoverCache.Snapshot())
            }
            loading = workingSnapshot.isEmpty
            errorMessage = nil
        }

        // 单平台采用渐进式并发加载：每日推荐 / 排行榜 / 歌单谁先回来谁先显示。
        workingSnapshot.savedAt = Date()
        let loggedIn = auth.isLoggedIn

        await withTaskGroup(of: DiscoverCache.Snapshot.self) { group in
            switch requestedSource {
            case .netease:
                group.addTask {
                    var part = DiscoverCache.Snapshot()
                    part.topLists = (try? await NetEaseAPI.shared.topLists()) ?? []
                    return part
                }
                group.addTask {
                    var part = DiscoverCache.Snapshot()
                    part.dailySongs = (try? await NetEaseAPI.shared.dailyRecommend()) ?? []
                    return part
                }
                group.addTask {
                    var part = DiscoverCache.Snapshot()
                    part.personalized = await NetEaseAPI.shared.recommendedHomePlaylists(loggedIn: loggedIn, limit: 18)
                    return part
                }

            case .qq:
                group.addTask {
                    var part = DiscoverCache.Snapshot()
                    let rec = (try? await QQMusicAPI.shared.recommendSongs(limit: 30)) ?? []
                    let fav = (try? await QQMusicAPI.shared.favoriteSongs()) ?? []
                    part.dailySongs = Self.mergeDaily([rec, fav])
                    return part
                }
                group.addTask {
                    var part = DiscoverCache.Snapshot()
                    part.qqTopLists = (try? await QQMusicAPI.shared.topLists()) ?? []
                    return part
                }
                group.addTask {
                    var part = DiscoverCache.Snapshot()
                    part.personalized = (try? await QQMusicAPI.shared.hotPlaylists(limit: 18)) ?? []
                    return part
                }

            case .kugou:
                group.addTask {
                    var part = DiscoverCache.Snapshot()
                    let fm = (try? await KugouMusicAPI.shared.personalFM(limit: 12)) ?? []
                    if let songs = try? await KugouMusicAPI.shared.everydayRecommend(limit: 30), !songs.isEmpty {
                        part.dailySongs = Self.mergeDaily([songs, fm])
                    } else {
                        part.dailySongs = (try? await KugouMusicAPI.shared.searchSongs(keyword: "热门歌曲", limit: 30)) ?? []
                    }
                    return part
                }
                group.addTask {
                    var part = DiscoverCache.Snapshot()
                    part.kugouTopLists = (try? await KugouMusicAPI.shared.topLists(limit: 10)) ?? []
                    return part
                }
                group.addTask {
                    var part = DiscoverCache.Snapshot()
                    part.personalized = (try? await KugouMusicAPI.shared.recommendPlaylists(limit: 12)) ?? []
                    return part
                }

            case .synology:
                group.addTask {
                    await fetchNASHomeSnapshot()
                }
            case .subsonic, .jellyfin, .webdav:
                group.addTask {
                    await fetchNewNASHomeSnapshot(for: requestedSource)
                }
            }

            for await part in group {
                guard !Task.isCancelled, !isHomeAggregate, requestedSource == source else {
                    group.cancelAll()
                    return
                }
                mergeHomeSnapshotPart(part, into: &workingSnapshot)
                if !workingSnapshot.isEmpty {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        apply(workingSnapshot)
                    }
                    loading = false
                    errorMessage = nil
                }
            }
        }

        guard !Task.isCancelled, !isHomeAggregate, requestedSource == source else { return }
        workingSnapshot.savedAt = Date()
        if cacheable, !workingSnapshot.isEmpty {
            cache.save(workingSnapshot, for: requestedSource)
        }
        loading = false
        errorMessage = workingSnapshot.isEmpty ? "暂时没有获取到主页内容" : nil
        lastLoadedKey = loadKey
        lastLoadedAt = Date()
    }

    private func currentSnapshot() -> DiscoverCache.Snapshot {
        var snapshot = DiscoverCache.Snapshot()
        snapshot.dailySongs = dailySongs
        snapshot.topLists = topLists
        snapshot.personalized = personalized
        snapshot.qqTopLists = qqTopLists
        snapshot.kugouTopLists = kugouTopLists
        snapshot.savedAt = Date()
        return snapshot
    }

    private func mergeHomeSnapshotPart(
        _ part: DiscoverCache.Snapshot,
        into snapshot: inout DiscoverCache.Snapshot
    ) {
        if !part.dailySongs.isEmpty { snapshot.dailySongs = part.dailySongs }
        if !part.topLists.isEmpty { snapshot.topLists = part.topLists }
        if !part.personalized.isEmpty { snapshot.personalized = part.personalized }
        if !part.qqTopLists.isEmpty { snapshot.qqTopLists = part.qqTopLists }
        if !part.kugouTopLists.isEmpty { snapshot.kugouTopLists = part.kugouTopLists }
        snapshot.savedAt = Date()
    }

    @MainActor
    private func loadAggregate(force: Bool) async {
        let loadKey = "aggregate"
        if activeLoadKey == loadKey { return }
        if !force,
           lastLoadedKey == loadKey,
           Date().timeIntervalSince(lastLoadedAt) < 20,
           hasAnyData {
            loading = false
            errorMessage = nil
            return
        }
        activeLoadKey = loadKey
        let wasAlreadyAggregate = lastLoadedKey == loadKey
        loading = !(wasAlreadyAggregate && hasAnyData)
        errorMessage = nil
        defer {
            if activeLoadKey == loadKey { activeLoadKey = nil }
        }

        var snapshotsByProvider: [SearchProvider: DiscoverCache.Snapshot] = [:]
        let cache = DiscoverCache.shared

        // 聚合主页无论普通进入还是手动刷新，都先用各平台磁盘快照拼出基线。
        // 这样从单平台切到聚合不会短暂显示上一平台内容，刷新时也不会整页闪空。
        for provider in homeProviders {
            if let cached = cache.cached(for: provider) {
                snapshotsByProvider[provider] = cached
            }
        }
        let cachedSnapshot = combineAggregateSnapshots(
            homeProviders.compactMap { snapshotsByProvider[$0] }
        )
        if !cachedSnapshot.isEmpty {
            apply(cachedSnapshot)
            loading = false
        } else if !wasAlreadyAggregate {
            apply(DiscoverCache.Snapshot())
            loading = true
        }

        let providers = homeProviders
        await withTaskGroup(of: (SearchProvider, DiscoverCache.Snapshot).self) { group in
            for provider in providers {
                group.addTask { [self] in
                    await fetchAggregatePart(for: provider)
                }
            }
            for await (provider, snapshot) in group {
                guard !Task.isCancelled, isHomeAggregate else { return }
                if !snapshot.isEmpty {
                    snapshotsByProvider[provider] = snapshot
                    cache.save(snapshot, for: provider)

                    // 首次安装通常没有任何缓存。旧逻辑必须等所有平台都返回后才结束
                    // Loading，其中一个平台慢就会让聚合主页长时间空白。
                    // 现在任一平台先返回即可立刻展示，后续平台到达时无动画补齐内容。
                    let partialSnapshot = combineAggregateSnapshots(
                        homeProviders.compactMap { snapshotsByProvider[$0] }
                    )
                    if !partialSnapshot.isEmpty {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            apply(partialSnapshot)
                        }
                        loading = false
                        errorMessage = nil
                    }
                }
            }
        }
        guard isHomeAggregate else { return }
        let finalSnapshot = combineAggregateSnapshots(homeProviders.compactMap { snapshotsByProvider[$0] })
        if !finalSnapshot.isEmpty {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                apply(finalSnapshot)
            }
        }
        // 自愈：NAS 已启用且会话有效，但合并结果里一首 NAS 歌都没有（多半是会话恢复
        // 晚于本次加载、或整库首建超时被竞速丢弃），单独补拉一次 NAS 并合并进来——
        // 不能让 NAS 在聚合页整场缺席、只能等用户手动下拉刷新。
        if providers.contains(.synology),
           SynologyAPI.shared.isLoggedIn,
           !finalSnapshot.dailySongs.contains(where: { $0.source == .synology }) {
            let nasSnapshot = await fetchNASHomeSnapshot()
            if !nasSnapshot.isEmpty {
                snapshotsByProvider[.synology] = nasSnapshot
                cache.save(nasSnapshot, for: .synology)
                let healedSnapshot = combineAggregateSnapshots(homeProviders.compactMap { snapshotsByProvider[$0] })
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    apply(healedSnapshot)
                }
            }
        }
        loading = false
        errorMessage = hasAnyData ? nil : "暂时没有获取到聚合首页内容"
        lastLoadedKey = loadKey
        lastLoadedAt = Date()
        aggregateHourBucket = Int(Date().timeIntervalSince1970 / 3600)
    }

    /// 当前小时与上次聚合加载的小时不同（NAS 今日推荐应换批）时重新加载。
    /// 小时内保持稳定是既定设计（116），这里只补“跨小时页面还活着”的触发缺口。
    private func checkHourRollover() {
        guard isHomeAggregate, !homeRenderingPaused else { return }
        let bucket = Int(Date().timeIntervalSince1970 / 3600)
        if let loaded = aggregateHourBucket, loaded != bucket {
            Task { await load() }
        }
    }

    private func combineAggregateSnapshots(_ snapshots: [DiscoverCache.Snapshot]) -> DiscoverCache.Snapshot {
        var result = DiscoverCache.Snapshot()
        result.savedAt = Date()

        var seenSongs = Set<String>()
        result.dailySongs = snapshots.flatMap(\.dailySongs).filter {
            seenSongs.insert($0.identityKey).inserted
        }
        result.topLists = snapshots.flatMap(\.topLists)
        result.qqTopLists = snapshots.flatMap(\.qqTopLists)
        result.kugouTopLists = snapshots.flatMap(\.kugouTopLists)

        var seenPlaylists = Set<String>()
        result.personalized = snapshots.flatMap(\.personalized).filter {
            seenPlaylists.insert($0.identityKey).inserted
        }
        return result
    }

    private func fetchAggregatePart(for provider: SearchProvider) async -> (SearchProvider, DiscoverCache.Snapshot) {
        // 某个平台不可用时不能让聚合首页永远停在等待状态。
        // NAS 首次加载要整库建索引，明显慢于在线平台：单独放宽到 30 秒，
        // 否则大曲库设备上 NAS 快照永远赢不了竞速、聚合页永远没有 NAS。
        let timeoutNanoseconds: UInt64 = (provider == .synology || provider == .subsonic || provider == .jellyfin || provider == .webdav) ? 30_000_000_000 : 10_000_000_000
        return await withTaskGroup(of: (SearchProvider, DiscoverCache.Snapshot).self) { group in
            group.addTask { [self] in
                switch provider {
                case .synology:
                    return (provider, await fetchNASHomeSnapshot())
                case .subsonic, .jellyfin, .webdav:
                    return (provider, await fetchNewNASHomeSnapshot(for: provider))
                case .netease, .qq, .kugou:
                    let snapshot = (try? await fetchSnapshot(for: provider)) ?? DiscoverCache.Snapshot()
                    return (provider, snapshot)
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return (provider, DiscoverCache.Snapshot())
            }
            let first = await group.next() ?? (provider, DiscoverCache.Snapshot())
            group.cancelAll()
            return first
        }
    }


    private func reloadAfterLoginUpdate(_ provider: SearchProvider) {
        if isHomeAggregate {
            Task { await load(force: true) }
        } else if source == provider {
            Task { await load(force: true) }
        } else {
            homeScopeRaw = "single"
            homeSourceRaw = provider.rawValue
        }
    }


    private func fetchSnapshot(for source: SearchProvider) async throws -> DiscoverCache.Snapshot {
        var snapshot = DiscoverCache.Snapshot()
        snapshot.savedAt = Date()
        switch source {
        case .qq:
            async let a: [Song] = (try? await QQMusicAPI.shared.recommendSongs(limit: 30)) ?? []
            async let b: [QQTopInfo] = (try? await QQMusicAPI.shared.topLists()) ?? []
            async let c: [Playlist] = (try? await QQMusicAPI.shared.hotPlaylists(limit: 18)) ?? []
            async let d: [Song] = (try? await QQMusicAPI.shared.favoriteSongs()) ?? []
            let (dr, tl, pp, fav) = await (a, b, c, d)
            if pp.isEmpty {
                ATMusicLogger.shared.log("QQ音乐热门歌单为空：保留板块并显示空状态", level: .warn)
            }
            snapshot.dailySongs = Self.mergeDaily([dr, fav])
            snapshot.qqTopLists = tl
            snapshot.personalized = pp
        case .netease:
            async let a = NetEaseAPI.shared.topLists()
            async let b = NetEaseAPI.shared.dailyRecommend()
            async let c = NetEaseAPI.shared.recommendedHomePlaylists(loggedIn: auth.isLoggedIn, limit: 18)
            let (tl, dr, pp) = try await (a, b, c)
            snapshot.topLists = tl
            snapshot.dailySongs = dr
            snapshot.personalized = pp
        case .kugou:
            async let songs = loadKugouDailySongs(limit: 30)
            async let ranks = KugouMusicAPI.shared.topLists(limit: 10)
            async let playlists = KugouMusicAPI.shared.recommendPlaylists(limit: 12)
            let (daily, top, pp) = try await (songs, ranks, playlists)
            snapshot.dailySongs = daily
            snapshot.kugouTopLists = top
            snapshot.personalized = pp
        case .synology, .subsonic, .jellyfin, .webdav:
            // NAS 内容由音乐库页面按登录状态加载，不参与发现页推荐快照；
            // 聚合页的 NAS 歌单走 fetchNASHomeSnapshot / fetchNewNASHomeSnapshot。
            break
        }
        return snapshot
    }


    private func fetchNASHomeSnapshot() async -> DiscoverCache.Snapshot {
        var snapshot = DiscoverCache.Snapshot()
        guard SynologyAPI.shared.isLoggedIn else { return snapshot }
        // 歌单与整库并行取，避免串行耗时叠加后被聚合竞速丢弃
        async let playlistsTask: [Playlist] = SynologyAPI.shared.allPlaylists(pageSize: 18)
        async let libraryTask: [Song] = SynologyAPI.shared.librarySongs()
        snapshot.personalized = (try? await playlistsTask) ?? []
        if let songs = try? await libraryTask {
            snapshot.dailySongs = SynologyAPI.hourlyRecommendedSongs(from: songs, count: 30)
        }
        return snapshot
    }

    /// 新 NAS 后端的聚合快照：只有歌单，没有每日推荐（新后端没有群晖那样的
    /// 整库 hourly 推荐接口，不编造推荐）。歌单上限 18 张，与群晖快照口径一致。
    private func fetchNewNASHomeSnapshot(for provider: SearchProvider) async -> DiscoverCache.Snapshot {
        var snapshot = DiscoverCache.Snapshot()
        switch provider {
        case .subsonic:
            guard SubsonicAPI.shared.isLoggedIn else { return snapshot }
            let playlists = (try? await SubsonicAPI.shared.allPlaylists()) ?? []
            snapshot.personalized = Array(playlists.prefix(18))
        case .jellyfin:
            guard JellyfinAPI.shared.isLoggedIn else { return snapshot }
            let playlists = (try? await JellyfinAPI.shared.allPlaylists()) ?? []
            snapshot.personalized = Array(playlists.prefix(18))
        case .webdav:
            guard WebDAVAPI.shared.isLoggedIn else { return snapshot }
            let playlists = (try? await WebDAVAPI.shared.allPlaylists()) ?? []
            snapshot.personalized = Array(playlists.prefix(18))
        default:
            break
        }
        return snapshot
    }

    private func loadKugouDailySongs(limit: Int) async -> [Song] {
        let fm = (try? await KugouMusicAPI.shared.personalFM(limit: 12)) ?? []
        if let songs = try? await KugouMusicAPI.shared.everydayRecommend(limit: limit), !songs.isEmpty {
            return Self.mergeDaily([songs, fm])
        }
        return (try? await KugouMusicAPI.shared.searchSongs(keyword: "热门歌曲", limit: limit)) ?? []
    }

    @MainActor
    private func apply(_ snapshot: DiscoverCache.Snapshot) {
        dailySongs = snapshot.dailySongs
        topLists = snapshot.topLists
        personalized = snapshot.personalized
        qqTopLists = snapshot.qqTopLists
        kugouTopLists = snapshot.kugouTopLists
    }

    private var hasAnyData: Bool {
        !dailySongs.isEmpty || !topLists.isEmpty || !personalized.isEmpty
            || !qqTopLists.isEmpty || !kugouTopLists.isEmpty
    }
}

/// 聚合首页的完整歌单承载页：让首页保持轻量，所有平台的歌单仍可一处浏览。
private struct AggregatePlaylistLibrarySheet: View {
    @Environment(\.dismiss) private var dismiss
    let groups: [(SongSource, [Playlist])]
    let onSelect: (Playlist) -> Void

    var body: some View {
        NavigationView {
            List {
                ForEach(Array(groups.enumerated()), id: \.element.0) { _, group in
                    Section {
                        ForEach(group.1, id: \.identityKey) { playlist in
                            Button {
                                onSelect(playlist)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    CoverImage(url: playlist.coverURL, size: 52, cornerRadius: 10)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(playlist.name)
                                            .font(ATMusicFont.appFont(15, .semibold))
                                            .foregroundStyle(Color.atmusicLabel)
                                            .lineLimit(2)
                                        Text(playlist.trackCount > 0 ? atmusicSongCountText(playlist.trackCount) : "歌单")
                                            .font(ATMusicFont.appFont(12))
                                            .foregroundStyle(Color.atmusicComment)
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Color.atmusicComment)
                                }
                                .padding(.vertical, 3)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        HStack(spacing: 7) {
                            Text(sourceTitle(group.0))
                            SourceBadgeView(source: group.0, compact: true)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("全部歌单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .modifier(ATMusicSheetModifier(detents: [.large], dragIndicator: true))
    }

    private func sourceTitle(_ source: SongSource) -> String {
        switch source {
        case .netease: return "网易云音乐"
        case .qq: return "QQ音乐"
        case .kugou: return "酷狗音乐"
        case .synology: return "群晖 NAS"
        case .subsonic: return "Subsonic"
        case .jellyfin: return "Jellyfin"
        case .webdav: return "WebDAV"
        case .local: return "本地音乐"
        }
    }
}

// MARK: - QQ 峰尖榜详情

struct QQTopListDetailView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let topID: Int
    let name: String
    @State private var tracks: [Song] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var isMultiSelecting = false
    @State private var selectedSongKeys: Set<String> = []
    @State private var dragStartIndex: Int? = nil
    @State private var initialSelectedKeysOnDrag: Set<String>? = nil
    @State private var dragTargetSelected = true
    @State private var filteredTracks: [Song] = []

    private func recomputeFilteredTracks() {
        let kw = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kw.isEmpty else {
            filteredTracks = tracks
            return
        }
        filteredTracks = tracks.filter { song in
            song.name.lowercased().contains(kw)
                || song.artists.lowercased().contains(kw)
                || song.album.lowercased().contains(kw)
        }
    }
    @State private var lastDragIndex: Int? = nil
    @State private var showBatchAddToPlaylist = false

    private var selectedSongs: [Song] {
        filteredTracks.filter { selectedSongKeys.contains($0.identityKey) }
    }

    private func toggleSelection(_ song: Song) {
        if selectedSongKeys.contains(song.identityKey) {
            selectedSongKeys.remove(song.identityKey)
        } else {
            selectedSongKeys.insert(song.identityKey)
        }
    }

    private func handleDragChange(startIndex: Int, deltaRows: Int) {
        let keys = filteredTracks.map(\.identityKey)
        guard startIndex >= 0, startIndex < keys.count else { return }
        if dragStartIndex == nil {
            dragStartIndex = startIndex
            initialSelectedKeysOnDrag = selectedSongKeys
            let willSelect = !selectedSongKeys.contains(keys[startIndex])
            dragTargetSelected = willSelect
            lastDragIndex = nil
        }
        guard let start = dragStartIndex, let initial = initialSelectedKeysOnDrag else { return }
        let current = min(max(0, start + deltaRows), keys.count - 1)
        guard current != lastDragIndex else { return }
        lastDragIndex = current
        ATMusicHaptics.select()

        let low = min(start, current)
        let high = max(start, current)
        var updated = initial
        for idx in low...high {
            let k = keys[idx]
            if dragTargetSelected {
                updated.insert(k)
            } else {
                updated.remove(k)
            }
        }
        selectedSongKeys = updated
    }

    private func handleDragEnd() {
        dragStartIndex = nil
        initialSelectedKeysOnDrag = nil
        lastDragIndex = nil
    }

    @ViewBuilder
    private func chartSongRow(song: Song, index: Int) -> some View {
        SongCell(
            song: song,
            glassRow: true,
            playbackContext: filteredTracks,
            playbackIndex: index,
            onTap: {
                player.play(songs: filteredTracks, startAt: index)
            },
            isMultiSelecting: isMultiSelecting,
            isSelected: selectedSongKeys.contains(song.identityKey),
            onToggleSelection: {
                toggleSelection(song)
            },
            onDragSelectionChange: { startIdx, deltaRows in
                handleDragChange(startIndex: startIdx, deltaRows: deltaRows)
            },
            onDragSelectionEnd: {
                handleDragEnd()
            },
            selectionIndex: index
        )
    }

    init(topID: Int, name: String) {
        self.topID = topID
        self.name = name
    }

    var body: some View {
        let _ = theme.accent
        ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
                Group {
                if loading {
                    LoadingStateView()
                } else if let errorMessage {
                    ErrorStateView(message: errorMessage) {
                        Task { await load() }
                    }
                } else if DeviceLayoutHelper.isIPadRegular(horizontalSizeClass) {
                    iPadQQTopListLayout
                } else {
                    List {
                        Section {
                            HStack(spacing: 12) {
                                GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                                    guard !filteredTracks.isEmpty else { return }
                                    player.play(songs: filteredTracks, startAt: 0)
                                }
                                GlassButton(title: "随机播放", systemName: "shuffle") {
                                    guard !filteredTracks.isEmpty else { return }
                                    player.play(songs: filteredTracks, startAt: Int.random(in: 0..<filteredTracks.count))
                                }
                            }
                            .listRowBackground(Color.clear)
                            .padding(.vertical, 8)
                        }
                        Section {
                            ForEach(Array(filteredTracks.enumerated()), id: \.element.identityKey) { index, song in
                                chartSongRow(song: song, index: index)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                            }
                        }
                    }
                    .atmusicScrollContentBackgroundHidden()
                    .listStyle(.plain)
                }
            }

            if isMultiSelecting && !selectedSongKeys.isEmpty {
                VStack {
                    Spacer()
                    UniversalBatchActionBar(
                        selectedCount: selectedSongKeys.count,
                        totalCount: filteredTracks.count,
                        actions: [
                            BatchActionItem(id: "play", title: "播放", systemImage: "play.fill") {
                                let songs = selectedSongs
                                player.play(songs: songs, startAt: 0)
                                isMultiSelecting = false
                                selectedSongKeys.removeAll()
                            },
                            BatchActionItem(id: "playNext", title: "下一首", systemImage: "text.line.first.and.arrowtriangle.forward") {
                                let songs = selectedSongs
                                player.playNext(songs: songs)
                                isMultiSelecting = false
                                selectedSongKeys.removeAll()
                            },
                            BatchActionItem(id: "queue", title: "加队列", systemImage: "text.badge.plus") {
                                let songs = selectedSongs
                                player.appendToQueue(songs: songs)
                                isMultiSelecting = false
                                selectedSongKeys.removeAll()
                            },
                            BatchActionItem(id: "playlist", title: "加歌单", systemImage: "folder.badge.plus") {
                                showBatchAddToPlaylist = true
                            },
                            BatchActionItem(id: "download", title: "下载", systemImage: "arrow.down.circle") {
                                let songs = selectedSongs
                                DownloadManager.shared.startBatchDownload(songs: songs)
                                isMultiSelecting = false
                                selectedSongKeys.removeAll()
                            },
                            BatchActionItem(id: "archive", title: "归档NAS", systemImage: "externaldrive.badge.plus", tint: Color.atmusicAmber, disabled: !SynologyAPI.shared.isLoggedIn) {
                                let songs = selectedSongs
                                DownloadManager.shared.startBatchUploadToNAS(songs: songs)
                                isMultiSelecting = false
                                selectedSongKeys.removeAll()
                            }
                        ]
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .navigationTitle(isMultiSelecting ? (selectedSongKeys.isEmpty ? "选择歌曲" : "已选 \(selectedSongKeys.count) 首") : atmusicChartName(name))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: atmusicLocalized("搜索榜单歌曲", "Search chart songs"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isMultiSelecting {
                    HStack(spacing: 12) {
                        Button(selectedSongKeys.count == filteredTracks.count && !filteredTracks.isEmpty ? "取消全选" : "全选") {
                            ATMusicHaptics.tap()
                            if selectedSongKeys.count == filteredTracks.count {
                                selectedSongKeys.removeAll()
                            } else {
                                selectedSongKeys = Set(filteredTracks.map(\.identityKey))
                            }
                        }
                        .font(ATMusicFont.appFont(13, .semibold))
                        .foregroundStyle(Color.atmusicAmber)

                        Button("完成") {
                            ATMusicHaptics.tap()
                            isMultiSelecting = false
                            selectedSongKeys.removeAll()
                        }
                        .font(ATMusicFont.appFont(13, .semibold))
                    }
                } else {
                    Menu {
                        Button {
                            ATMusicHaptics.select()
                            isMultiSelecting = true
                        } label: {
                            Label("多选歌曲", systemImage: "checklist")
                        }
                        .disabled(filteredTracks.isEmpty)

                        Button {
                            DownloadManager.shared.startBatchDownload(songs: filteredTracks)
                            ToastCenter.shared.show("已将 \(filteredTracks.count) 首榜单歌曲加入下载")
                        } label: {
                            Label("下载全部歌曲", systemImage: "arrow.down.circle")
                        }
                        .disabled(filteredTracks.isEmpty)

                        if SynologyAPI.shared.isLoggedIn {
                            Button {
                                DownloadManager.shared.startBatchUploadToNAS(songs: filteredTracks)
                                ToastCenter.shared.show("已将 \(filteredTracks.count) 首榜单歌曲加入归档")
                            } label: {
                                Label("全部归档至群晖 NAS", systemImage: "externaldrive.badge.plus")
                            }
                            .disabled(filteredTracks.isEmpty)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("更多操作")
                }
            }
        }
        .sheet(isPresented: $showBatchAddToPlaylist) {
            AddToPlaylistSheet(songs: selectedSongs)
                .environmentObject(theme)
        }
        .task { await load() }
        .onChange(of: tracks) { _ in recomputeFilteredTracks() }
        .onChange(of: searchText) { _ in recomputeFilteredTracks() }
    }


    private var iPadQQTopListLayout: some View {
        HStack(alignment: .top, spacing: 32) {
            VStack(alignment: .leading, spacing: 18) {
                if let cover = tracks.first?.coverURL {
                    CoverImage(url: cover, size: 240, cornerRadius: 24)
                        .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 10)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(LinearGradient(colors: [Color.green.opacity(0.8), Color.mint.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 240, height: 240)
                        Image(systemName: "chart.bar.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(.white)
                    }
                    .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 10)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(atmusicChartName(name))
                        .font(ATMusicFont.appFont(22, .bold))
                        .foregroundStyle(Color.atmusicLabel)
                        .lineLimit(2)

                    Text("QQ 音乐 · 官方排行榜")
                        .font(ATMusicFont.appFont(13, .medium))
                        .foregroundStyle(Color.atmusicComment)

                    Text(atmusicSongCountText(filteredTracks.count))
                        .font(ATMusicFont.appFont(13))
                        .foregroundStyle(Color.atmusicComment)
                }

                if !filteredTracks.isEmpty {
                    HStack(spacing: 12) {
                        GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                            player.play(songs: filteredTracks, startAt: 0)
                        }
                        GlassIconButton(systemName: "shuffle", size: 44, active: false) {
                            player.play(songs: filteredTracks.shuffled(), startAt: 0)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(width: 260)
            .padding(.leading, 32)
            .padding(.top, 24)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("歌曲列表 (\(filteredTracks.count))")
                            .font(ATMusicFont.appFont(16, .bold))
                            .foregroundStyle(Color.atmusicLabel)
                        Spacer()
                    }
                    .padding(.top, 24)

                    LazyVGrid(columns: DeviceLayoutHelper.songListColumns(for: horizontalSizeClass, spacing: 16), spacing: 8) {
                        ForEach(Array(filteredTracks.enumerated()), id: \.element.identityKey) { index, song in
                            chartSongRow(song: song, index: index)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.primary.opacity(0.03))
                            }
                        }
                    }
                }
                .padding(.trailing, 32)
                .padding(.bottom, 120)
            }
        }
    }

    @MainActor
    private func load() async {
        let cache = DetailSongsCache.shared
        let cacheKey = "qq-top-\(topID)"
        if let cached = cache.cachedSongs(for: cacheKey) {
            tracks = cached.songs
            loading = false
            errorMessage = nil
            if cache.isFresh(cached) {
                return
            }
        } else {
            loading = true
            errorMessage = nil
        }
        do {
            let songs = try await QQMusicAPI.shared.topListSongs(topid: topID)
            if !songs.isEmpty {
                tracks = songs
                cache.save(songs, for: cacheKey)
            }
            loading = false
        } catch {
            if tracks.isEmpty {
                errorMessage = error.localizedDescription
            } else {
                ATMusicLogger.shared.log(
                    "QQ 排行榜详情后台刷新失败，继续使用缓存 topID=\(topID) error=\(error.localizedDescription)",
                    level: .warn
                )
            }
            loading = false
        }
    }
}

// MARK: - QQ 歌单内歌曲

struct QQPlaylistSongsSheet: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let playlist: Playlist
    @State private var tracks: [Song] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var filteredTracks: [Song] = []

    private func recomputeFilteredTracks() {
        let kw = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kw.isEmpty else {
            filteredTracks = tracks
            return
        }
        filteredTracks = tracks.filter { song in
            song.name.lowercased().contains(kw)
                || song.artists.lowercased().contains(kw)
                || song.album.lowercased().contains(kw)
        }
    }

    var body: some View {
        let _ = theme.accent
        ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
                Group {
                if loading {
                    LoadingStateView()
                } else if let errorMessage {
                    ErrorStateView(message: errorMessage) {
                        Task { await load() }
                    }
                } else if DeviceLayoutHelper.isIPadRegular(horizontalSizeClass) {
                    iPadQQPlaylistLayout
                } else {
                    List {
                        Section {
                            HStack(spacing: 12) {
                                GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                                    guard !filteredTracks.isEmpty else { return }
                                    player.play(songs: filteredTracks, startAt: 0)
                                }
                                GlassButton(title: "随机播放", systemName: "shuffle") {
                                    guard !filteredTracks.isEmpty else { return }
                                    player.play(songs: filteredTracks, startAt: Int.random(in: 0..<filteredTracks.count))
                                }
                            }
                            .listRowBackground(Color.clear)
                            .padding(.vertical, 8)
                        }
                        Section {
                            ForEach(Array(filteredTracks.enumerated()), id: \.element.identityKey) { index, song in
                                SongCell(song: song, glassRow: true, onTap: {
                                    player.play(songs: filteredTracks, startAt: index)
                                })
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                            }
                        }
                    }
                    .atmusicScrollContentBackgroundHidden()
                    .listStyle(.plain)
                }
            }
            }
            .navigationTitle(playlist.name)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: atmusicLocalized("搜索歌单内歌曲", "Search playlist songs"))
        .task { await load() }
        .onChange(of: tracks) { _ in recomputeFilteredTracks() }
        .onChange(of: searchText) { _ in recomputeFilteredTracks() }
    }


    private var iPadQQPlaylistLayout: some View {
        HStack(alignment: .top, spacing: 32) {
            VStack(alignment: .leading, spacing: 18) {
                CoverImage(url: playlist.coverURL, size: 240, cornerRadius: 24)
                    .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 10)

                VStack(alignment: .leading, spacing: 8) {
                    Text(playlist.name)
                        .font(ATMusicFont.appFont(22, .bold))
                        .foregroundStyle(Color.atmusicLabel)
                        .lineLimit(2)

                    if !playlist.creatorName.isEmpty {
                        Text(playlist.creatorName)
                            .font(ATMusicFont.appFont(13, .medium))
                            .foregroundStyle(Color.atmusicComment)
                    }

                    Text(atmusicSongCountText(filteredTracks.count))
                        .font(ATMusicFont.appFont(13))
                        .foregroundStyle(Color.atmusicComment)
                }

                if !filteredTracks.isEmpty {
                    HStack(spacing: 12) {
                        GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                            player.play(songs: filteredTracks, startAt: 0)
                        }
                        GlassIconButton(systemName: "shuffle", size: 44, active: false) {
                            player.play(songs: filteredTracks.shuffled(), startAt: 0)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(width: 260)
            .padding(.leading, 32)
            .padding(.top, 24)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("歌曲列表 (\(filteredTracks.count))")
                            .font(ATMusicFont.appFont(16, .bold))
                            .foregroundStyle(Color.atmusicLabel)
                        Spacer()
                    }
                    .padding(.top, 24)

                    LazyVGrid(columns: DeviceLayoutHelper.songListColumns(for: horizontalSizeClass, spacing: 16), spacing: 8) {
                        ForEach(Array(filteredTracks.enumerated()), id: \.element.identityKey) { index, song in
                            SongCell(
                                song: song,
                                glassRow: true,
                                playbackContext: filteredTracks,
                                playbackIndex: index,
                                onTap: {
                                    player.play(songs: filteredTracks, startAt: index)
                                }
                            )
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.primary.opacity(0.03))
                            }
                        }
                    }
                }
                .padding(.trailing, 32)
                .padding(.bottom, 120)
            }
        }
    }

    @MainActor
    private func load() async {
        loading = true
        errorMessage = nil
        do {
            tracks = try await QQMusicAPI.shared.playlistSongs(listID: playlist.id)
            loading = false
        } catch {
            errorMessage = error.localizedDescription
            loading = false
        }
    }
}

// MARK: - 每日推荐全部歌曲

struct DailySongsSheet: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let songs: [Song]
    @State private var searchText = ""
    @State private var isMultiSelecting = false
    @State private var selectedSongKeys: Set<String> = []
    @State private var dragStartIndex: Int? = nil
    @State private var initialSelectedKeysOnDrag: Set<String>? = nil
    @State private var dragTargetSelected = true
    @State private var lastDragIndex: Int? = nil
    @State private var showBatchAddToPlaylist = false
    @State private var filteredSongs: [Song] = []

    private func recomputeFilteredSongs() {
        let kw = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kw.isEmpty else {
            filteredSongs = songs
            return
        }
        filteredSongs = songs.filter { song in
            song.name.lowercased().contains(kw)
                || song.artists.lowercased().contains(kw)
                || song.album.lowercased().contains(kw)
        }
    }

    private var selectedSongs: [Song] {
        filteredSongs.filter { selectedSongKeys.contains($0.identityKey) }
    }

    private func toggleSelection(_ song: Song) {
        if selectedSongKeys.contains(song.identityKey) {
            selectedSongKeys.remove(song.identityKey)
        } else {
            selectedSongKeys.insert(song.identityKey)
        }
    }

    private func handleDragChange(startIndex: Int, deltaRows: Int) {
        let keys = filteredSongs.map(\.identityKey)
        guard startIndex >= 0, startIndex < keys.count else { return }
        if dragStartIndex == nil {
            dragStartIndex = startIndex
            initialSelectedKeysOnDrag = selectedSongKeys
            let willSelect = !selectedSongKeys.contains(keys[startIndex])
            dragTargetSelected = willSelect
            lastDragIndex = nil
        }
        guard let start = dragStartIndex, let initial = initialSelectedKeysOnDrag else { return }
        let current = min(max(0, start + deltaRows), keys.count - 1)
        guard current != lastDragIndex else { return }
        lastDragIndex = current
        ATMusicHaptics.select()

        let low = min(start, current)
        let high = max(start, current)
        var updated = initial
        for idx in low...high {
            let k = keys[idx]
            if dragTargetSelected {
                updated.insert(k)
            } else {
                updated.remove(k)
            }
        }
        selectedSongKeys = updated
    }

    private func handleDragEnd() {
        dragStartIndex = nil
        initialSelectedKeysOnDrag = nil
        lastDragIndex = nil
    }

    @ViewBuilder
    private func dailySongRow(song: Song, index: Int) -> some View {
        SongCell(
            song: song,
            glassRow: true,
            playbackContext: filteredSongs,
            playbackIndex: index,
            onTap: {
                ATMusicHaptics.tap()
                player.play(songs: filteredSongs, startAt: index)
            },
            isMultiSelecting: isMultiSelecting,
            isSelected: selectedSongKeys.contains(song.identityKey),
            onToggleSelection: {
                toggleSelection(song)
            },
            onDragSelectionChange: { startIdx, deltaRows in
                handleDragChange(startIndex: startIdx, deltaRows: deltaRows)
            },
            onDragSelectionEnd: {
                handleDragEnd()
            },
            selectionIndex: index
        )
    }

    var body: some View {
        let _ = theme.accent
        ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
                Group {
                if songs.isEmpty {
                    EmptyStateView(icon: "sparkles", text: "今日推荐加载中，下拉刷新试试")
                } else if DeviceLayoutHelper.isIPadRegular(horizontalSizeClass) {
                    iPadDailySongsLayout
                } else {
                    List {
                    Section {
                        HStack(spacing: 12) {
                            GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                                guard !filteredSongs.isEmpty else { return }
                                player.play(songs: filteredSongs, startAt: 0)
                            }
                            GlassButton(title: "随机播放", systemName: "shuffle") {
                                guard !filteredSongs.isEmpty else { return }
                                player.play(songs: filteredSongs, startAt: Int.random(in: 0..<filteredSongs.count))
                            }
                        }
                        .listRowBackground(Color.clear)
                        .padding(.vertical, 8)
                    }
                    Section {
                        ForEach(Array(filteredSongs.enumerated()), id: \.element.identityKey) { index, song in
                            dailySongRow(song: song, index: index)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                    }
                }
                .atmusicScrollContentBackgroundHidden()
                .listStyle(.plain)
                }
            }

            if isMultiSelecting && !selectedSongKeys.isEmpty {
                    VStack {
                        Spacer()
                        UniversalBatchActionBar(
                            selectedCount: selectedSongKeys.count,
                            totalCount: filteredSongs.count,
                            actions: [
                                BatchActionItem(id: "play", title: "播放", systemImage: "play.fill") {
                                    let songs = selectedSongs
                                    player.play(songs: songs, startAt: 0)
                                    isMultiSelecting = false
                                    selectedSongKeys.removeAll()
                                },
                                BatchActionItem(id: "playNext", title: "下一首", systemImage: "text.line.first.and.arrowtriangle.forward") {
                                    let songs = selectedSongs
                                    player.playNext(songs: songs)
                                    isMultiSelecting = false
                                    selectedSongKeys.removeAll()
                                },
                                BatchActionItem(id: "queue", title: "加队列", systemImage: "text.badge.plus") {
                                    let songs = selectedSongs
                                    player.appendToQueue(songs: songs)
                                    isMultiSelecting = false
                                    selectedSongKeys.removeAll()
                                },
                                BatchActionItem(id: "playlist", title: "加歌单", systemImage: "folder.badge.plus") {
                                    showBatchAddToPlaylist = true
                                },
                                BatchActionItem(id: "download", title: "下载", systemImage: "arrow.down.circle") {
                                    let songs = selectedSongs
                                    DownloadManager.shared.startBatchDownload(songs: songs)
                                    isMultiSelecting = false
                                    selectedSongKeys.removeAll()
                                },
                                BatchActionItem(id: "archive", title: "归档NAS", systemImage: "externaldrive.badge.plus", tint: Color.atmusicAmber, disabled: !SynologyAPI.shared.isLoggedIn) {
                                    let songs = selectedSongs
                                    DownloadManager.shared.startBatchUploadToNAS(songs: songs)
                                    isMultiSelecting = false
                                    selectedSongKeys.removeAll()
                                }
                            ]
                        )
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .navigationTitle(isMultiSelecting ? (selectedSongKeys.isEmpty ? "选择歌曲" : "已选 \(selectedSongKeys.count) 首") : "今日推荐")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: atmusicLocalized("搜索每日推荐", "Search daily recommendations"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if isMultiSelecting {
                        HStack(spacing: 12) {
                            Button(selectedSongKeys.count == filteredSongs.count && !filteredSongs.isEmpty ? "取消全选" : "全选") {
                                ATMusicHaptics.tap()
                                if selectedSongKeys.count == filteredSongs.count {
                                    selectedSongKeys.removeAll()
                                } else {
                                    selectedSongKeys = Set(filteredSongs.map(\.identityKey))
                                }
                            }
                            .font(ATMusicFont.appFont(13, .semibold))
                            .foregroundStyle(Color.atmusicAmber)

                            Button("完成") {
                                ATMusicHaptics.tap()
                                isMultiSelecting = false
                                selectedSongKeys.removeAll()
                            }
                            .font(ATMusicFont.appFont(13, .semibold))
                        }
                    } else {
                        Menu {
                            Button {
                                ATMusicHaptics.select()
                                isMultiSelecting = true
                            } label: {
                                Label("多选歌曲", systemImage: "checklist")
                            }
                            .disabled(filteredSongs.isEmpty)

                            Button {
                                DownloadManager.shared.startBatchDownload(songs: filteredSongs)
                                ToastCenter.shared.show("已将 \(filteredSongs.count) 首推荐歌曲加入下载")
                            } label: {
                                Label("下载全部歌曲", systemImage: "arrow.down.circle")
                            }
                            .disabled(filteredSongs.isEmpty)

                            if SynologyAPI.shared.isLoggedIn {
                                Button {
                                    DownloadManager.shared.startBatchUploadToNAS(songs: filteredSongs)
                                    ToastCenter.shared.show("已将 \(filteredSongs.count) 首推荐歌曲加入归档")
                                } label: {
                                    Label("全部归档至群晖 NAS", systemImage: "externaldrive.badge.plus")
                                }
                                .disabled(filteredSongs.isEmpty)
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("更多操作")
                    }
                }
            }
            .sheet(isPresented: $showBatchAddToPlaylist) {
                AddToPlaylistSheet(songs: selectedSongs)
                    .environmentObject(theme)
            }
            .onAppear { recomputeFilteredSongs() }
            .onChange(of: searchText) { _ in recomputeFilteredSongs() }
    }


    private var iPadDailySongsLayout: some View {
        HStack(alignment: .top, spacing: 32) {
            VStack(alignment: .leading, spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.94, green: 0.22, blue: 0.35), Color(red: 0.88, green: 0.14, blue: 0.45)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 240, height: 240)
                        .shadow(color: Color.red.opacity(0.28), radius: 18, x: 0, y: 10)

                    VStack(spacing: 8) {
                        Image(systemName: "calendar")
                            .font(.system(size: 50, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                        Text("\(Calendar.current.component(.day, from: Date()))")
                            .font(ATMusicFont.appFont(40, .bold))
                            .foregroundStyle(.white)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("今日推荐")
                        .font(ATMusicFont.appFont(22, .bold))
                        .foregroundStyle(Color.atmusicLabel)

                    Text("每天 6:00 更新 · 专属定制")
                        .font(ATMusicFont.appFont(13, .medium))
                        .foregroundStyle(Color.atmusicComment)

                    Text(atmusicSongCountText(filteredSongs.count))
                        .font(ATMusicFont.appFont(13))
                        .foregroundStyle(Color.atmusicComment)
                }

                if !filteredSongs.isEmpty {
                    HStack(spacing: 12) {
                        GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                            player.play(songs: filteredSongs, startAt: 0)
                        }
                        GlassIconButton(systemName: "shuffle", size: 44, active: false) {
                            player.play(songs: filteredSongs.shuffled(), startAt: 0)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(width: 260)
            .padding(.leading, 32)
            .padding(.top, 24)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("歌曲列表 (\(filteredSongs.count))")
                            .font(ATMusicFont.appFont(16, .bold))
                            .foregroundStyle(Color.atmusicLabel)
                        Spacer()
                    }
                    .padding(.top, 24)

                    LazyVGrid(columns: DeviceLayoutHelper.songListColumns(for: horizontalSizeClass, spacing: 16), spacing: 8) {
                        ForEach(Array(filteredSongs.enumerated()), id: \.element.identityKey) { index, song in
                            dailySongRow(song: song, index: index)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.primary.opacity(0.03))
                            }
                        }
                    }
                }
                .padding(.trailing, 32)
                .padding(.bottom, 120)
            }
        }
    }

}
// MARK: - 排行榜详情

struct TopListDetailView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var auth: AuthStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("atmusic.uiStyle") private var uiStyleRaw = ATMusicUIStyle.liquid.rawValue

    /// 榜单页头卡圆角（四风格统一）
    private var headerCardRadius: CGFloat {
        let style = ATMusicUIStyle(rawValue: uiStyleRaw) ?? .liquid
        switch style {
        case .nativeClean: return 12
        case .compact: return 14
        case .clear: return 18
        case .liquid: return 22
        }
    }

    let topList: TopList
    @State private var tracks: [Song] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var isMultiSelecting = false
    @State private var selectedSongKeys: Set<String> = []
    @State private var dragStartIndex: Int? = nil
    @State private var initialSelectedKeysOnDrag: Set<String>? = nil
    @State private var dragTargetSelected = true
    @State private var lastDragIndex: Int? = nil
    @State private var showBatchAddToPlaylist = false
    @State private var filteredTracks: [Song] = []

    private func recomputeFilteredTracks() {
        let kw = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kw.isEmpty else {
            filteredTracks = tracks
            return
        }
        filteredTracks = tracks.filter { song in
            song.name.lowercased().contains(kw)
                || song.artists.lowercased().contains(kw)
                || song.album.lowercased().contains(kw)
        }
    }

    private var selectedSongs: [Song] {
        filteredTracks.filter { selectedSongKeys.contains($0.identityKey) }
    }

    private func toggleSelection(_ song: Song) {
        if selectedSongKeys.contains(song.identityKey) {
            selectedSongKeys.remove(song.identityKey)
        } else {
            selectedSongKeys.insert(song.identityKey)
        }
    }

    private func handleDragChange(startIndex: Int, deltaRows: Int) {
        let keys = filteredTracks.map(\.identityKey)
        guard startIndex >= 0, startIndex < keys.count else { return }
        if dragStartIndex == nil {
            dragStartIndex = startIndex
            initialSelectedKeysOnDrag = selectedSongKeys
            let willSelect = !selectedSongKeys.contains(keys[startIndex])
            dragTargetSelected = willSelect
            lastDragIndex = nil
        }
        guard let start = dragStartIndex, let initial = initialSelectedKeysOnDrag else { return }
        let current = min(max(0, start + deltaRows), keys.count - 1)
        guard current != lastDragIndex else { return }
        lastDragIndex = current
        ATMusicHaptics.select()

        let low = min(start, current)
        let high = max(start, current)
        var updated = initial
        for idx in low...high {
            let k = keys[idx]
            if dragTargetSelected {
                updated.insert(k)
            } else {
                updated.remove(k)
            }
        }
        selectedSongKeys = updated
    }

    private func handleDragEnd() {
        dragStartIndex = nil
        initialSelectedKeysOnDrag = nil
        lastDragIndex = nil
    }

    @ViewBuilder
    private func chartSongRow(song: Song, index: Int) -> some View {
        SongCell(
            song: song,
            glassRow: true,
            playbackContext: filteredTracks,
            playbackIndex: index,
            onTap: {
                player.play(songs: filteredTracks, startAt: index)
            },
            isMultiSelecting: isMultiSelecting,
            isSelected: selectedSongKeys.contains(song.identityKey),
            onToggleSelection: {
                toggleSelection(song)
            },
            onDragSelectionChange: { startIdx, deltaRows in
                handleDragChange(startIndex: startIdx, deltaRows: deltaRows)
            },
            onDragSelectionEnd: {
                handleDragEnd()
            },
            selectionIndex: index
        )
    }

    init(topList: TopList) {
        self.topList = topList
    }

    var body: some View {
        let _ = theme.accent
        ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
                Group {
                if loading {
                    LoadingStateView()
                } else if let errorMessage {
                    ErrorStateView(message: errorMessage) {
                        Task { await load() }
                    }
                } else if DeviceLayoutHelper.isIPadRegular(horizontalSizeClass) {
                    iPadTopListLayout
                } else {
                    List {
                        header
                        Section {
                            HStack(spacing: 12) {
                                GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                                    guard !filteredTracks.isEmpty else { return }
                                    player.play(songs: filteredTracks, startAt: 0)
                                }
                                GlassButton(title: "随机播放", systemName: "shuffle") {
                                    guard !filteredTracks.isEmpty else { return }
                                    player.play(songs: filteredTracks, startAt: Int.random(in: 0..<filteredTracks.count))
                                }
                            }
                            .listRowBackground(Color.clear)
                            .padding(.vertical, 8)
                        }
                        Section {
                            ForEach(Array(filteredTracks.enumerated()), id: \.element.identityKey) { index, song in
                                chartSongRow(song: song, index: index)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                            }
                        }
                    }
                    .atmusicScrollContentBackgroundHidden()
                    .listStyle(.plain)
                }
            }

            if isMultiSelecting && !selectedSongKeys.isEmpty {
                    VStack {
                        Spacer()
                        UniversalBatchActionBar(
                            selectedCount: selectedSongKeys.count,
                            totalCount: filteredTracks.count,
                            actions: [
                                BatchActionItem(id: "play", title: "播放", systemImage: "play.fill") {
                                    let songs = selectedSongs
                                    player.play(songs: songs, startAt: 0)
                                    isMultiSelecting = false
                                    selectedSongKeys.removeAll()
                                },
                                BatchActionItem(id: "playNext", title: "下一首", systemImage: "text.line.first.and.arrowtriangle.forward") {
                                    let songs = selectedSongs
                                    player.playNext(songs: songs)
                                    isMultiSelecting = false
                                    selectedSongKeys.removeAll()
                                },
                                BatchActionItem(id: "queue", title: "加队列", systemImage: "text.badge.plus") {
                                    let songs = selectedSongs
                                    player.appendToQueue(songs: songs)
                                    isMultiSelecting = false
                                    selectedSongKeys.removeAll()
                                },
                                BatchActionItem(id: "playlist", title: "加歌单", systemImage: "folder.badge.plus") {
                                    showBatchAddToPlaylist = true
                                },
                                BatchActionItem(id: "download", title: "下载", systemImage: "arrow.down.circle") {
                                    let songs = selectedSongs
                                    DownloadManager.shared.startBatchDownload(songs: songs)
                                    isMultiSelecting = false
                                    selectedSongKeys.removeAll()
                                },
                                BatchActionItem(id: "archive", title: "归档NAS", systemImage: "externaldrive.badge.plus", tint: Color.atmusicAmber, disabled: !SynologyAPI.shared.isLoggedIn) {
                                    let songs = selectedSongs
                                    DownloadManager.shared.startBatchUploadToNAS(songs: songs)
                                    isMultiSelecting = false
                                    selectedSongKeys.removeAll()
                                }
                            ]
                        )
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .navigationTitle(isMultiSelecting ? (selectedSongKeys.isEmpty ? "选择歌曲" : "已选 \(selectedSongKeys.count) 首") : atmusicChartName(topList.name))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: atmusicLocalized("搜索榜单歌曲", "Search chart songs"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if isMultiSelecting {
                        HStack(spacing: 12) {
                            Button(selectedSongKeys.count == filteredTracks.count && !filteredTracks.isEmpty ? "取消全选" : "全选") {
                                ATMusicHaptics.tap()
                                if selectedSongKeys.count == filteredTracks.count {
                                    selectedSongKeys.removeAll()
                                } else {
                                    selectedSongKeys = Set(filteredTracks.map(\.identityKey))
                                }
                            }
                            .font(ATMusicFont.appFont(13, .semibold))
                            .foregroundStyle(Color.atmusicAmber)

                            Button("完成") {
                                ATMusicHaptics.tap()
                                isMultiSelecting = false
                                selectedSongKeys.removeAll()
                            }
                            .font(ATMusicFont.appFont(13, .semibold))
                        }
                    } else {
                        Menu {
                            Button {
                                ATMusicHaptics.select()
                                isMultiSelecting = true
                            } label: {
                                Label("多选歌曲", systemImage: "checklist")
                            }
                            .disabled(filteredTracks.isEmpty)

                            Button {
                                DownloadManager.shared.startBatchDownload(songs: filteredTracks)
                                ToastCenter.shared.show("已将 \(filteredTracks.count) 首榜单歌曲加入下载")
                            } label: {
                                Label("下载全部歌曲", systemImage: "arrow.down.circle")
                            }
                            .disabled(filteredTracks.isEmpty)

                            if SynologyAPI.shared.isLoggedIn {
                                Button {
                                    DownloadManager.shared.startBatchUploadToNAS(songs: filteredTracks)
                                    ToastCenter.shared.show("已将 \(filteredTracks.count) 首榜单歌曲加入归档")
                                } label: {
                                    Label("全部归档至群晖 NAS", systemImage: "externaldrive.badge.plus")
                                }
                                .disabled(filteredTracks.isEmpty)
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("更多操作")
                    }
                }
            }
            .sheet(isPresented: $showBatchAddToPlaylist) {
                AddToPlaylistSheet(songs: selectedSongs)
                    .environmentObject(theme)
            }
        .task { await load() }
        .onChange(of: tracks) { _ in recomputeFilteredTracks() }
        .onChange(of: searchText) { _ in recomputeFilteredTracks() }
    }


    private var iPadTopListLayout: some View {
        HStack(alignment: .top, spacing: 32) {
            VStack(alignment: .leading, spacing: 18) {
                CoverImage(url: topList.coverURL, size: 240, cornerRadius: 24)
                    .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 10)

                VStack(alignment: .leading, spacing: 8) {
                    Text(atmusicChartName(topList.name))
                        .font(ATMusicFont.appFont(22, .bold))
                        .foregroundStyle(Color.atmusicLabel)
                        .lineLimit(2)

                    Text(atmusicChartSubtitle(topList.updateFrequency))
                        .font(ATMusicFont.appFont(13, .medium))
                        .foregroundStyle(Color.atmusicComment)

                    Text(atmusicSongCountText(filteredTracks.count))
                        .font(ATMusicFont.appFont(13))
                        .foregroundStyle(Color.atmusicComment)
                }

                if !filteredTracks.isEmpty {
                    HStack(spacing: 12) {
                        GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                            player.play(songs: filteredTracks, startAt: 0)
                        }
                        GlassIconButton(systemName: "shuffle", size: 44, active: false) {
                            player.play(songs: filteredTracks.shuffled(), startAt: 0)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(width: 260)
            .padding(.leading, 32)
            .padding(.top, 24)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("歌曲列表 (\(filteredTracks.count))")
                            .font(ATMusicFont.appFont(16, .bold))
                            .foregroundStyle(Color.atmusicLabel)
                        Spacer()
                    }
                    .padding(.top, 24)

                    LazyVGrid(columns: DeviceLayoutHelper.songListColumns(for: horizontalSizeClass, spacing: 16), spacing: 8) {
                        ForEach(Array(filteredTracks.enumerated()), id: \.element.identityKey) { index, song in
                            SongCell(
                                song: song,
                                glassRow: true,
                                playbackContext: filteredTracks,
                                playbackIndex: index,
                                onTap: {
                                    player.play(songs: filteredTracks, startAt: index)
                                }
                            )
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.primary.opacity(0.03))
                            }
                        }
                    }
                }
                .padding(.trailing, 32)
                .padding(.bottom, 120)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            CoverImage(url: topList.coverURL, size: 88, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 6) {
                Text(atmusicChartName(topList.name))
                    .font(ATMusicFont.appFont(18, .bold))
                    .foregroundStyle(Color.atmusicLabel)
                Text(atmusicChartSubtitle(topList.updateFrequency))
                    .font(ATMusicFont.appFont(12))
                    .foregroundStyle(Color.atmusicComment)
                Text(atmusicSongCountText(tracks.count))
                    .font(ATMusicFont.appFont(12))
                    .foregroundStyle(Color.atmusicComment)
            }
            Spacer()
        }
        .padding(14)
        .background {
            ATMusicGlass(shape: RoundedRectangle(cornerRadius: headerCardRadius, style: .continuous))
        }
        .atmusicCardShadow(radius: 8, y: 3)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    @MainActor
    private func load() async {
        let cache = DetailSongsCache.shared
        let cacheKey = "netease-top-\(topList.id)"
        if let cached = cache.cachedSongs(for: cacheKey) {
            tracks = cached.songs
            loading = false
            errorMessage = nil
            if cache.isFresh(cached) {
                return
            }
        } else {
            loading = true
            errorMessage = nil
        }
        do {
            let songs = try await NetEaseAPI.shared.playlistTracks(id: topList.id)
            if !songs.isEmpty {
                tracks = songs
                cache.save(songs, for: cacheKey)
            }
            loading = false
        } catch {
            if tracks.isEmpty {
                errorMessage = error.localizedDescription
            } else {
                ATMusicLogger.shared.log(
                    "网易云排行榜详情后台刷新失败，继续使用缓存 id=\(topList.id) error=\(error.localizedDescription)",
                    level: .warn
                )
            }
            loading = false
        }
    }
}

// MARK: - 酷狗排行榜详情

struct KugouTopListDetailView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let topList: KugouTopInfo
    @State private var tracks: [Song] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var filteredTracks: [Song] = []

    init(topList: KugouTopInfo) {
        self.topList = topList
    }

    private func recomputeFilteredTracks() {
        let kw = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kw.isEmpty else {
            filteredTracks = tracks
            return
        }
        filteredTracks = tracks.filter { song in
            song.name.lowercased().contains(kw)
                || song.artists.lowercased().contains(kw)
                || song.album.lowercased().contains(kw)
        }
    }

    var body: some View {
        let _ = theme.accent
        ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
                Group {
                if loading {
                    LoadingStateView()
                } else if let errorMessage {
                    ErrorStateView(message: errorMessage) {
                        Task { await load() }
                    }
                } else if tracks.isEmpty {
                    EmptyStateView(icon: "music.note.list", text: atmusicLocalized("该排行榜暂无歌曲", "This chart has no songs yet"))
                } else if DeviceLayoutHelper.isIPadRegular(horizontalSizeClass) {
                    iPadKugouTopListLayout
                } else {
                    List {
                        header
                        Section {
                            HStack(spacing: 12) {
                                GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                                    guard !filteredTracks.isEmpty else { return }
                                    player.play(songs: filteredTracks, startAt: 0)
                                }
                                GlassButton(title: "随机播放", systemName: "shuffle") {
                                    guard !filteredTracks.isEmpty else { return }
                                    player.play(songs: filteredTracks, startAt: Int.random(in: 0..<filteredTracks.count))
                                }
                            }
                            .listRowBackground(Color.clear)
                            .padding(.vertical, 8)
                        }
                        Section {
                            ForEach(Array(filteredTracks.enumerated()), id: \.element.identityKey) { index, song in
                                SongCell(song: song, glassRow: true, onTap: {
                                    player.play(songs: filteredTracks, startAt: index)
                                })
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                            }
                        }
                    }
                    .atmusicScrollContentBackgroundHidden()
                    .listStyle(.plain)
                }
            }
            }
            .navigationTitle(atmusicChartName(topList.name))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: atmusicLocalized("搜索榜单歌曲", "Search chart songs"))
        .task { await load() }
        .onChange(of: tracks) { _ in recomputeFilteredTracks() }
        .onChange(of: searchText) { _ in recomputeFilteredTracks() }
    }


    private var iPadKugouTopListLayout: some View {
        HStack(alignment: .top, spacing: 32) {
            VStack(alignment: .leading, spacing: 18) {
                CoverImage(url: topList.coverURL, size: 240, cornerRadius: 24)
                    .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 10)

                VStack(alignment: .leading, spacing: 8) {
                    Text(atmusicChartName(topList.name))
                        .font(ATMusicFont.appFont(22, .bold))
                        .foregroundStyle(Color.atmusicLabel)
                        .lineLimit(2)

                    if !topList.updateFrequency.isEmpty {
                        Text(atmusicChartSubtitle(topList.updateFrequency))
                            .font(ATMusicFont.appFont(13, .medium))
                            .foregroundStyle(Color.atmusicComment)
                            .lineLimit(2)
                    }

                    Text(atmusicSongCountText(filteredTracks.count))
                        .font(ATMusicFont.appFont(13))
                        .foregroundStyle(Color.atmusicComment)
                }

                if !filteredTracks.isEmpty {
                    HStack(spacing: 12) {
                        GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                            player.play(songs: filteredTracks, startAt: 0)
                        }
                        GlassIconButton(systemName: "shuffle", size: 44, active: false) {
                            player.play(songs: filteredTracks.shuffled(), startAt: 0)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(width: 260)
            .padding(.leading, 32)
            .padding(.top, 24)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("歌曲列表 (\(filteredTracks.count))")
                            .font(ATMusicFont.appFont(16, .bold))
                            .foregroundStyle(Color.atmusicLabel)
                        Spacer()
                    }
                    .padding(.top, 24)

                    LazyVGrid(columns: DeviceLayoutHelper.songListColumns(for: horizontalSizeClass, spacing: 16), spacing: 8) {
                        ForEach(Array(filteredTracks.enumerated()), id: \.element.identityKey) { index, song in
                            SongCell(
                                song: song,
                                glassRow: true,
                                playbackContext: filteredTracks,
                                playbackIndex: index,
                                onTap: {
                                    player.play(songs: filteredTracks, startAt: index)
                                }
                            )
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.primary.opacity(0.03))
                            }
                        }
                    }
                }
                .padding(.trailing, 32)
                .padding(.bottom, 120)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            CoverImage(url: topList.coverURL, size: 88, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 6) {
                Text(atmusicChartName(topList.name))
                    .font(ATMusicFont.appFont(18, .bold))
                    .foregroundStyle(Color.atmusicLabel)
                    .lineLimit(2)
                if !topList.updateFrequency.isEmpty {
                    Text(atmusicChartSubtitle(topList.updateFrequency))
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(Color.atmusicComment)
                }
                Text(atmusicSongCountText(tracks.count))
                    .font(ATMusicFont.appFont(12))
                    .foregroundStyle(Color.atmusicComment)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background {
            ATMusicGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .atmusicCardShadow(radius: 8, y: 3)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    @MainActor
    private func load() async {
        let cache = DetailSongsCache.shared
        let cacheKey = "kugou-top-\(topList.id)"
        if let cached = cache.cachedSongs(for: cacheKey) {
            tracks = cached.songs
            loading = false
            errorMessage = nil
            if cache.isFresh(cached) {
                return
            }
        } else {
            loading = true
            errorMessage = nil
        }
        do {
            let songs = try await KugouMusicAPI.shared.rankSongs(rankID: topList.id)
            if !songs.isEmpty {
                tracks = songs
                cache.save(songs, for: cacheKey)
            }
            loading = false
        } catch {
            if tracks.isEmpty {
                errorMessage = error.localizedDescription
            } else {
                ATMusicLogger.shared.log(
                    "酷狗排行榜详情后台刷新失败，继续使用缓存 id=\(topList.id) error=\(error.localizedDescription)",
                    level: .warn
                )
            }
            loading = false
        }
    }
}

private struct HomeUnifiedSearchSheet: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var platformPrefs = PlatformPreferenceStore.shared

    @State private var keyword = ""
    @State private var results: [Song] = []
    @State private var searching = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var debounceTask: Task<Void, Never>?
    @State private var searchController = SearchFieldController()

    private var providers: [SearchProvider] {
        platformPrefs.enabledSearchProviders
    }

    var body: some View {
        ATMusicNavigationStack {
            ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
            VStack(spacing: 12) {
                searchField
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .navigationTitle("全平台搜索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .onChange(of: keyword) { newValue in
            debounceTask?.cancel()
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                results = []
                errorMessage = nil
                return
            }
            debounceTask = Task {
                try? await Task.sleep(nanoseconds: 420_000_000)
                guard !Task.isCancelled else { return }
                await startSearch(trimmed)
            }
        }
        .onDisappear {
            debounceTask?.cancel()
            searchTask?.cancel()
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.atmusicComment)
            SearchTextField(
                text: $keyword,
                controller: searchController,
                placeholder: atmusicLocalized("搜索三平台歌曲", "Search across three platforms"),
                textColor: UIColor.atmusicLabel,
                onSubmit: { text in
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    debounceTask?.cancel()
                    Task { await startSearch(trimmed) }
                }
            )
            .frame(height: 34)
            .frame(maxWidth: .infinity)

            ZStack {
                ProgressView()
                    .controlSize(.small)
                    .tint(Color.atmusicAmber)
                    .opacity(searching ? 1 : 0)
            }
            .frame(width: 20, height: 22)
            .animation(nil, value: searching)

            ZStack {
                Button {
                    keyword = ""
                    results = []
                    errorMessage = nil
                    debounceTask?.cancel()
                    searchTask?.cancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.atmusicComment.opacity(0.85))
                }
                .buttonStyle(.plain)
                .opacity(keyword.isEmpty ? 0 : 1)
                .disabled(keyword.isEmpty)
            }
            .frame(width: 20, height: 22)

            Button {
                let text = searchController.commit()
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                debounceTask?.cancel()
                Task { await startSearch(trimmed) }
            } label: {
                Text("搜索")
                    .font(ATMusicFont.appFont(13, .semibold))
                    .foregroundStyle(Color.atmusicAmber)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background { ATMusicGlass(shape: Capsule()) }
            }
            .buttonStyle(GlassPressButtonStyle(scale: 0.9))
            .frame(width: 54, height: 30)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background {
            ATMusicGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .atmusicCardShadow(radius: 8, y: 3)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        if keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyStateView(icon: "magnifyingglass", text: "输入歌名后会同时搜索网易云、QQ音乐和酷狗音乐")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage, results.isEmpty {
            ErrorStateView(message: errorMessage) {
                Task { await startSearch(keyword) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if searching && results.isEmpty {
            LoadingStateView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty {
            EmptyStateView(icon: "music.note", text: "暂未找到相关歌曲")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Text(atmusicLocalized("找到 \(results.count) 首 · 全平台", "Found \(results.count) songs · All Platforms"))
                            .font(ATMusicFont.appFont(12))
                            .foregroundStyle(Color.atmusicComment)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                            .truncationMode(.tail)
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                            .layoutPriority(1)
                        Button {
                            ATMusicHaptics.tap()
                            player.play(songs: results, startAt: 0)
                        } label: {
                            Label("播放全部", systemImage: "play.fill")
                                .font(ATMusicFont.appFont(12, .semibold))
                                .foregroundStyle(Color.atmusicAmber)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background { ATMusicGlass(shape: Capsule()) }
                        }
                        .buttonStyle(.plain)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)

                    ForEach(Array(results.enumerated()), id: \.element.identityKey) { index, song in
                        SongCell(song: song, onTap: {
                            ATMusicHaptics.tap()
                            player.play(songs: results, startAt: index)
                        })
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background {
                            ATMusicGlass(shape: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .transition(.opacity)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 120)
            }
            .atmusicScrollIndicatorsHidden()
            .atmusicScrollDismissesKeyboard()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @MainActor
    private func startSearch(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchTask?.cancel()
        searchTask = Task {
            searching = true
            errorMessage = nil
            ATMusicLogger.shared.log("主页聚合搜索：\(trimmed)", level: .info)
            defer { if !Task.isCancelled { searching = false } }

            let enabledProviders = providers
            async let netease: [Song] = searchSongs(on: .netease, keyword: trimmed, enabledProviders: enabledProviders)
            async let qq: [Song] = searchSongs(on: .qq, keyword: trimmed, enabledProviders: enabledProviders)
            async let kugou: [Song] = searchSongs(on: .kugou, keyword: trimmed, enabledProviders: enabledProviders)

            let merged = await (netease + qq + kugou)
            guard !Task.isCancelled else { return }
            results = deduplicated(merged)
            if results.isEmpty {
                errorMessage = "三个平台都没有返回可展示的歌曲"
            } else {
                ATMusicHaptics.success()
            }
            ATMusicLogger.shared.log("主页聚合搜索完成：\(trimmed) 结果=\(results.count)", level: .info)
        }
        await searchTask?.value
    }

    private func searchSongs(on provider: SearchProvider, keyword: String, enabledProviders: [SearchProvider]) async -> [Song] {
        guard enabledProviders.contains(provider) else { return [] }
        switch provider {
        case .netease:
            return (try? await NetEaseAPI.shared.search(keyword: keyword, limit: 30)) ?? []
        case .qq:
            return (try? await QQMusicAPI.shared.searchSongs(keyword: keyword, limit: 30)) ?? []
        case .kugou:
            return (try? await KugouMusicAPI.shared.searchSongs(keyword: keyword, limit: 30)) ?? []
        case .synology:
            return (try? await SynologyAPI.shared.search(keyword: keyword, limit: 30)) ?? []
        case .subsonic:
            return (try? await SubsonicAPI.shared.searchAllVariants(keyword: keyword, limit: 30))?.songs ?? []
        case .jellyfin:
            return (try? await JellyfinAPI.shared.searchAllVariants(keyword: keyword, limit: 30))?.songs ?? []
        case .webdav:
            return (try? await WebDAVAPI.shared.searchAllVariants(keyword: keyword, limit: 30))?.songs ?? []
        }
    }

    private func deduplicated(_ songs: [Song]) -> [Song] {
        var seen = Set<String>()
        var output: [Song] = []
        for song in songs {
            let key = "\(song.source.rawValue)-\(song.name.lowercased())-\(song.artists.lowercased())"
            if seen.insert(key).inserted {
                output.append(song)
            }
        }
        return output
    }
}
