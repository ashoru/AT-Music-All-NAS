import SwiftUI
import MediaPlayer
import AVKit

/// iPad 侧边栏导航目的地项（对标 Apple Music iPad 完整资料库层级）
enum IPadSidebarDestination: Hashable, Identifiable {
    case tab(RootTab)
    case transferCenter
    case localMusic
    case history
    case favorites
    case synology
    case subsonic
    case jellyfin
    case webdav
    case settings

    var id: String {
        switch self {
        case .tab(let tab): return "tab-\(tab.rawValue)"
        case .transferCenter: return "transferCenter"
        case .localMusic: return "localMusic"
        case .history: return "history"
        case .favorites: return "favorites"
        case .synology: return "synology"
        case .subsonic: return "subsonic"
        case .jellyfin: return "jellyfin"
        case .webdav: return "webdav"
        case .settings: return "settings"
        }
    }

    var title: String {
        switch self {
        case .tab(let tab): return tab.title
        case .transferCenter: return "传输中心"
        case .localMusic: return "本地音乐"
        case .history: return "最近播放"
        case .favorites: return "我喜欢的音乐"
        case .synology: return "群晖 NAS"
        case .subsonic: return "Subsonic"
        case .jellyfin: return "Jellyfin"
        case .webdav: return "WebDAV"
        case .settings: return "设置"
        }
    }

    var icon: String {
        switch self {
        case .tab(let tab): return tab.icon
        case .transferCenter: return "arrow.down.circle.fill"
        case .localMusic: return "internaldrive.fill"
        case .history: return "clock.fill"
        case .favorites: return "heart.fill"
        case .synology: return "externaldrive.fill"
        case .subsonic: return "server.rack"
        case .jellyfin: return "play.tv.fill"
        case .webdav: return "folder.fill.badge.gearshape"
        case .settings: return "gearshape.fill"
        }
    }
}

/// iPad 专属 Apple Music 官方级多栏与自适应架构根视图
/// 采用 NavigationSplitView 双栏/多栏架构，完美兼容 1/3 屏、1/2 半分屏、大分屏、横屏与竖屏；
/// 严格遵循 Apple Music iPadOS 人机交互规范，并完整支持软件 4 套 UI 调节（liquid、clear、compact、nativeClean）。
struct IPadRootView: View {
    @Binding var selection: RootTab
    @Binding var showPlayer: Bool
    var nowPlayingTransition: Namespace.ID

    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var favorites: FavoritesStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("atmusic.uiStyle") private var uiStyleRaw = ATMusicUIStyle.liquid.rawValue
    @ObservedObject private var downloadManager = DownloadManager.shared
    @ObservedObject private var synology = SynologyAPI.shared
    @ObservedObject private var subsonic = SubsonicAPI.shared
    @ObservedObject private var jellyfin = JellyfinAPI.shared
    @ObservedObject private var webdav = WebDAVAPI.shared

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var activeDestination: IPadSidebarDestination = .tab(.discover)
    @State private var showSettingsSheet = false

    private var uiStyle: ATMusicUIStyle {
        uiStyleRaw == "outline" ? .clear : (ATMusicUIStyle(rawValue: uiStyleRaw) ?? .liquid)
    }

    private var isNativeClean: Bool { uiStyle == .nativeClean }
    private var isCompact: Bool { uiStyle == .compact }

    init(
        selection: Binding<RootTab>,
        showPlayer: Binding<Bool>,
        nowPlayingTransition: Namespace.ID
    ) {
        self._selection = selection
        self._showPlayer = showPlayer
        self.nowPlayingTransition = nowPlayingTransition
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarContent
                .navigationTitle("音乐")
                .navigationSplitViewColumnWidth(min: 250, ideal: 285, max: 320)
        } detail: {
            detailHostContent
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            syncDestinationFromSelection()
        }
        .onChange(of: selection) { _ in
            syncDestinationFromSelection()
        }
        .sheet(isPresented: $showSettingsSheet) {
            SettingsView()
                .environmentObject(theme)
                .environmentObject(player)
                .environmentObject(auth)
                .modifier(SettingsLiquidSheetPresentation())
        }
    }

    private func syncDestinationFromSelection() {
        if case .tab(let currentTab) = activeDestination, currentTab == selection {
            return
        }
        activeDestination = .tab(selection)
    }

    // MARK: - 侧边栏主体 (对标 Apple Music iPad)

    private var sidebarContent: some View {
        VStack(spacing: 0) {
            List {
                // 1. 发现大类
                Section("发现") {
                    sidebarRow(for: .tab(.discover), customTitle: "主页")
                    sidebarRow(for: .tab(.featured), customTitle: "精选乐馆")
                    sidebarRow(for: .tab(.search), customTitle: "全网搜索")
                }

                // 2. 资料库大类
                Section("资料库") {
                    sidebarRow(for: .tab(.library), customTitle: "音乐库")
                    sidebarRow(for: .favorites)
                    sidebarRow(for: .history)
                    sidebarRow(for: .transferCenter, badgeCount: activeTransferCount)
                    sidebarRow(for: .localMusic)
                    if synology.isLoggedIn {
                        sidebarRow(for: .synology)
                    }
                    if subsonic.isLoggedIn {
                        sidebarRow(for: .subsonic)
                    }
                    if jellyfin.isLoggedIn {
                        sidebarRow(for: .jellyfin)
                    }
                    if webdav.isLoggedIn {
                        sidebarRow(for: .webdav)
                    }
                }

                // 3. 账户与设置
                Section("设置与账户") {
                    sidebarRow(for: .tab(.profile), customTitle: "个人中心")
                    sidebarRow(for: .settings, customTitle: "偏好设置")
                }

                // 4. 音频输出 (隔空播放)
                Section("音频输出") {
                    airPlayRow
                }
            }
            .listStyle(.sidebar)

            // 侧栏底置 MiniPlayer（仅在侧栏展开且有歌曲时展示）
            if let song = player.currentSong {
                sidebarMiniPlayer(song: song)
            }
        }
    }

    private var activeTransferCount: Int {
        downloadManager.activeDownloads.filter { $0.status != .completed }.count +
        downloadManager.activeUploads.filter { $0.status != .completed }.count
    }

    // MARK: - 侧栏行项（四种 UI 风格联动高亮）

    @ViewBuilder
    private func sidebarRow(for destination: IPadSidebarDestination, customTitle: String? = nil, badgeCount: Int = 0) -> some View {
        let isSelected = activeDestination == destination
        let title = customTitle ?? destination.title

        Button {
            ATMusicHaptics.select()
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                activeDestination = destination
                if case .tab(let tab) = destination {
                    selection = tab
                }
            }
        } label: {
            HStack(spacing: isCompact ? 8 : 12) {
                Image(systemName: destination.icon)
                    .font(.system(size: isCompact ? 15 : 17, weight: isSelected ? .bold : .medium))
                    .foregroundStyle(isSelected ? Color.atmusicAmber : Color.atmusicLabel)
                    .frame(width: 24, alignment: .center)

                Text(title)
                    .font(ATMusicFont.appFont(isCompact ? 13 : 15, isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.atmusicLabel : Color.atmusicLabel.opacity(0.85))

                Spacer(minLength: 4)

                if badgeCount > 0 {
                    Text("\(badgeCount)")
                        .font(ATMusicFont.appFont(11, .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.atmusicAmber, in: Capsule())
                }
            }
            .padding(.vertical, isCompact ? 5 : 7)
            .padding(.horizontal, isCompact ? 8 : 10)
            .contentShape(Rectangle())
            .background {
                if isSelected {
                    sidebarSelectionBackground
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var sidebarSelectionBackground: some View {
        switch uiStyle {
        case .liquid:
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.atmusicAmber.opacity(0.16))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.atmusicAmber.opacity(0.25), lineWidth: 1)
                }
        case .clear:
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.atmusicAmber, lineWidth: 1.2)
        case .compact:
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.08))
        case .nativeClean:
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.07))
        }
    }



    private var airPlayRow: some View {
        HStack(spacing: 12) {
            Label("隔空播放 (AirPlay)", systemImage: "airplayaudio")
                .font(ATMusicFont.appFont(isCompact ? 12 : 14))
                .foregroundStyle(Color.atmusicLabel)
            Spacer()
            AirPlayRoutePicker(
                tintColor: colorScheme == .dark ? .white : .black,
                activeTintColor: UIColor(Color.atmusicAmber)
            )
            .frame(width: 32, height: 32)
        }
        .padding(.vertical, 2)
    }

    // MARK: - 侧栏底置迷你播放器 (Apple Music 风格精致卡片)

    private func sidebarMiniPlayer(song: Song) -> some View {
        VStack(spacing: 0) {
            // 极细微进度条指示线
            GeometryReader { geo in
                let current = player.clock.currentTime
                let total = max(player.clock.duration, 1)
                let pct = min(max(current / total, 0), 1)

                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.06))
                        .frame(height: 2)

                    Rectangle()
                        .fill(Color.atmusicAmber)
                        .frame(width: geo.size.width * CGFloat(pct), height: 2)
                }
            }
            .frame(height: 2)

            HStack(spacing: 12) {
                CoverImage(url: song.coverURL, size: 46, cornerRadius: 10)
                    .frame(width: 46, height: 46)
                    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.12), radius: 6, x: 0, y: 3)

                VStack(alignment: .leading, spacing: 3) {
                    Text(song.title)
                        .font(ATMusicFont.appFont(14, .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                        .lineLimit(1)

                    Text(song.artist)
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(Color.atmusicComment)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Button {
                    ATMusicHaptics.tap()
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.atmusicLabel)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)

                Button {
                    ATMusicHaptics.tap()
                    player.nextTrack()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.atmusicComment)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background {
            miniPlayerBackground
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            showPlayer = true
        }
    }

    @ViewBuilder
    private var miniPlayerBackground: some View {
        switch uiStyle {
        case .liquid:
            ATMusicGlass(shape: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.30 : 0.10), radius: 10, x: 0, y: 4)
        case .clear:
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                }
        case .compact:
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
        case .nativeClean:
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.06))
        }
    }

    // MARK: - 右侧主展示区 (Detail Content)

    @ViewBuilder
    private var detailHostContent: some View {
        ZStack(alignment: .bottomTrailing) {
            detailMainView
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 当侧栏在 1/2 分屏、1/3 分屏或手动折叠（detailOnly）时，在右下角悬浮展示浮动播放条胶囊
            if columnVisibility == .detailOnly, player.currentSong != nil {
                MiniPlayerView(
                    showPlayer: $showPlayer,
                    presentation: .dock,
                    transitionNamespace: nowPlayingTransition,
                    compact: false
                )
                .environmentObject(player.clock)
                .padding(.horizontal, 24)
                .padding(.bottom, 22)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private var detailMainView: some View {
        switch activeSidebarItemClean {
        case .tab(.discover):
            DiscoverView(onOpenProfile: { activeDestination = .tab(.profile); selection = .profile })
        case .tab(.featured):
            FeaturedView(onOpenProfile: { activeDestination = .tab(.profile); selection = .profile })
        case .tab(.library):
            MusicLibraryHomeView(onOpenProfile: { activeDestination = .tab(.profile); selection = .profile })
        case .tab(.profile):
            ProfileView()
        case .tab(.search):
            SearchView()
        case .transferCenter:
            ATMusicNavigationStack {
                TransferCenterView()
            }
            .environmentObject(player)
            .environmentObject(theme)
            .environmentObject(auth)
        case .localMusic:
            ATMusicNavigationStack {
                LocalMusicBrowserView()
            }
            .environmentObject(player)
            .environmentObject(theme)
            .environmentObject(auth)
        case .history:
            ATMusicNavigationStack {
                MusicLibraryHistoryView()
            }
            .environmentObject(player)
            .environmentObject(theme)
        case .favorites:
            ATMusicNavigationStack {
                UnifiedFavoritesDetailView()
            }
            .environmentObject(player)
            .environmentObject(theme)
            .environmentObject(favorites)
        case .synology:
            ATMusicNavigationStack {
                SynologyFileLibraryView()
            }
            .environmentObject(player)
            .environmentObject(theme)
        case .subsonic:
            ATMusicNavigationStack {
                SubsonicMusicView()
            }
            .environmentObject(player)
            .environmentObject(theme)
        case .jellyfin:
            ATMusicNavigationStack {
                JellyfinMusicView()
            }
            .environmentObject(player)
            .environmentObject(theme)
        case .webdav:
            ATMusicNavigationStack {
                WebDAVMusicView()
            }
            .environmentObject(player)
            .environmentObject(theme)
        case .settings:
            AnyView(
                SettingsView()
                    .environmentObject(theme)
                    .environmentObject(player)
                    .environmentObject(auth)
                    .environmentObject(favorites)
            )
        }
    }

    private var activeSidebarItemClean: IPadSidebarDestination {
        activeDestination
    }
}
