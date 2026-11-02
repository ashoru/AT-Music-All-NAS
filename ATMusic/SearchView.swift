import SwiftUI

// MARK: - 流式标签布局（热搜标签云）

@available(iOS 16, *)
struct FlowLayout: Layout {
    var spacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

extension SearchProvider {
    /// 主题色渐变：网易云红 / QQ 绿 / 群晖深蓝
    var tint: LinearGradient {
        switch self {
        case .netease: return LinearGradient(
            colors: [Color(red: 0.93, green: 0.22, blue: 0.16), Color(red: 0.80, green: 0.15, blue: 0.12)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
        case .qq: return LinearGradient(
            colors: [Color(red: 0.15, green: 0.78, blue: 0.55), Color(red: 0.05, green: 0.58, blue: 0.42)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
        case .kugou: return LinearGradient(
            colors: [Color(red: 0.12, green: 0.58, blue: 0.95), Color(red: 0.02, green: 0.32, blue: 0.72)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
        case .synology: return LinearGradient(
            colors: [Color(red: 0.08, green: 0.45, blue: 0.85), Color(red: 0.02, green: 0.25, blue: 0.60)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
        case .subsonic: return LinearGradient(
            colors: [Color(red: 0.26, green: 0.62, blue: 0.28), Color(red: 0.13, green: 0.42, blue: 0.18)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
        case .jellyfin: return LinearGradient(
            colors: [Color(red: 0.65, green: 0.33, blue: 0.86), Color(red: 0.42, green: 0.16, blue: 0.62)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
        case .webdav: return LinearGradient(
            colors: [Color(red: 0.55, green: 0.55, blue: 0.58), Color(red: 0.32, green: 0.32, blue: 0.35)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

enum SearchResultType: String, CaseIterable, Identifiable {
    case song = "歌曲"
    case artist = "歌手"
    case album = "专辑"
    case playlist = "歌单"

    var id: String { rawValue }
}

private struct SynologySearchEntry: Identifiable {
    let id: String
    let names: [String]
    let subtitle: String
    let coverURL: URL?
}

private struct SynologyArtistSelection: Identifiable {
    let id: String
    let name: String
    let coverURL: URL?
}

private struct SynologyAlbumSelection: Identifiable, Hashable {
    let id: String
    let name: String
    let artistName: String
    let coverURL: URL?
}

private enum SearchRoute: Hashable {
    case album(Album)
    case playlist(Playlist)
    case synologyAlbum(SynologyAlbumSelection)
}

/// 聚合“综合”页的完整快照。
///
/// 必须使用单个 State 原子提交，不能将歌曲、歌手、专辑和歌单分别写入
/// 多个 State。后者会让 SwiftUI 在同一次网络回包中连续重建整棵结果视图，
/// 真机上会表现为结果反复闪烁。
private struct AggregateOverviewSnapshot {
    let songs: [Song]
    let artists: [Artist]
    let albums: [Album]
    let playlists: [Playlist]
}

struct SearchView: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("atmusic.uiStyle") private var uiStyleRaw = ATMusicUIStyle.liquid.rawValue
    @State private var keyword = ""
    @AppStorage("atmusic.search.provider") private var providerRaw = SearchProvider.netease.rawValue
    @State private var provider: SearchProvider = .netease
    /// 搜索页聚合当前“平台显示”中启用的音源；关闭的平台不参与搜索，也不出现在筛选器里。
    @State private var aggregateSearch = true
    @ObservedObject private var platformPrefs = PlatformPreferenceStore.shared
    @ObservedObject private var synology = SynologyAPI.shared
    private var searchProviders: [SearchProvider] { platformPrefs.enabledSearchProviders }
    @State private var resultType: SearchResultType = .song
    /// 聚合搜索默认展示 1.8 风格的综合结果；分类胶囊仍可切换到单一类型。
    @State private var aggregateOverview = true
    @State private var songResults: [Song] = []
    @State private var artistResults: [Artist] = []
    @State private var albumResults: [Album] = []
    @State private var playlistResults: [Playlist] = []
    // 综合页只接收一个原子快照；分类页仍使用上面四组实时结果。
    @State private var overviewSnapshot: AggregateOverviewSnapshot?
    @State private var synologyArtistEntries: [SynologySearchEntry] = []
    @State private var synologyAlbumEntries: [SynologySearchEntry] = []
    @State private var synologySearchSongs: [Song] = []
    @State private var hotWordsByProvider: [SearchProvider: [String]] = [:]
    @State private var hotLoadingProviders: Set<SearchProvider> = []
    @State private var hotUnavailableProviders: Set<SearchProvider> = []
    /// 热搜也做代际保护：平台范围变化后，旧请求晚回包不能污染当前空搜索页。
    @State private var hotWordsGeneration = 0
    @State private var searching = false
    @State private var errorMessage: String?
    @State private var showAddToPlaylist: Song?
    @State private var selectedArtist: Artist?
    @State private var selectedSynologyArtist: SynologyArtistSelection?
    @State private var navigationPath: [SearchRoute] = []
    @ObservedObject private var historyStore = SearchHistoryStore.shared
    @State private var debounceTask: Task<Void, Never>?
    @State private var searchTask: Task<Void, Never>?
    @State private var nasIndexRefreshTask: Task<Void, Never>?
    /// 平台/聚合范围经常会在同一次点击里连续改变两个状态；合并成一次搜索。
    @State private var scopeRefreshTask: Task<Void, Never>?
    /// 点击热搜/历史记录时 keyword 会同步变化；该标记用于跳过这一次输入 debounce，
    /// 因为按钮本身已经立即发起搜索。
    @State private var immediateKeyword: String?
    /// 同一关键词、范围和分类只允许一个在途请求。输入框提交、索引通知和
    /// 页面事件偶尔会在同一帧同时到达，若全部放行会让新旧结果互相覆盖。
    @State private var activeSearchKey: String?
    /// 每次搜索递增；网络层无法立即取消时，用它拒绝旧请求的迟到回包。
    @State private var searchGeneration = 0
    /// UIKit 输入框控制器（提交拼音、收起键盘等由它统一处理）
    @State private var searchController = SearchFieldController()

    private var isNativeClean: Bool {
        ATMusicUIStyle(rawValue: uiStyleRaw) == .nativeClean
    }

    private var searchScopeName: String {
        aggregateSearch ? "聚合" : provider.rawValue
    }

    private var totalSearchResultCount: Int {
        songResults.count + artistResults.count + albumResults.count + playlistResults.count
    }

    private var overviewResultCount: Int {
        overviewSongs.count + overviewArtists.count + overviewAlbums.count + overviewPlaylists.count
    }

    private var overviewSongs: [Song] { overviewSnapshot?.songs ?? [] }
    private var overviewArtists: [Artist] { overviewSnapshot?.artists ?? [] }
    private var overviewAlbums: [Album] { overviewSnapshot?.albums ?? [] }
    private var overviewPlaylists: [Playlist] { overviewSnapshot?.playlists ?? [] }
    private var hasOverviewSnapshot: Bool { overviewSnapshot != nil }

    /// 空搜索页聚合已启用的平台热搜。搜索范围严格是“聚合”或“单一平台”，
    /// 不保留历史的多选状态，以免显示与实际请求范围不一致。
    private var referenceHotWords: [String] {
        var seen = Set<String>()
        var words: [String] = []
        for source in searchProviders {
            for word in hotWordsByProvider[source] ?? [] {
                let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, seen.insert(trimmed.localizedLowercase).inserted else { continue }
                words.append(trimmed)
                if words.count == 10 { return words }
            }
        }
        return words
    }

    private func isEnabledAggregateSource(_ source: SongSource, in enabled: Set<SearchProvider>) -> Bool {
        guard let provider = source.searchProvider else { return true }
        return enabled.contains(provider)
    }

    private func resetOverviewSnapshot() {
        overviewSnapshot = nil
    }

    private func filterOverviewSnapshot(enabledProviders: Set<SearchProvider>) {
        guard let snapshot = overviewSnapshot else { return }
        overviewSnapshot = AggregateOverviewSnapshot(
            songs: snapshot.songs.filter { isEnabledAggregateSource($0.source, in: enabledProviders) },
            artists: snapshot.artists.filter { isEnabledAggregateSource($0.source, in: enabledProviders) },
            albums: snapshot.albums.filter { isEnabledAggregateSource($0.source, in: enabledProviders) },
            playlists: snapshot.playlists.filter { isEnabledAggregateSource($0.source, in: enabledProviders) }
        )
    }

    private func captureOverviewSnapshot(from result: AggregatedSearchResult, localPlaylists: [Playlist]) {
        overviewSnapshot = AggregateOverviewSnapshot(
            songs: result.songs,
            artists: result.artists,
            albums: result.albums,
            playlists: localPlaylists + result.playlists
        )
    }

    /// 流式回包期间只追加新项目，保留屏幕上已显示项目的位置和视图身份。
    /// 最终结果仍会按相关性一次性排序提交。
    private func stableAppend<Element>(
        current: [Element],
        incoming: [Element],
        identity: (Element) -> String
    ) -> [Element] {
        var seen = Set(current.map(identity))
        var result = current
        result.append(contentsOf: incoming.filter { seen.insert(identity($0)).inserted })
        return result
    }

    /// 立即使当前请求失效。网络层即使不能立刻取消，generation 也会拒绝迟到回包。
    private func invalidateSearchPipeline(cancelDebounce: Bool = true) {
        if cancelDebounce { debounceTask?.cancel() }
        scopeRefreshTask?.cancel()
        nasIndexRefreshTask?.cancel()
        searchTask?.cancel()
        searchGeneration &+= 1
        activeSearchKey = nil
        searching = false
    }

    private func clearSearchResults() {
        songResults = []
        artistResults = []
        albumResults = []
        playlistResults = []
        resetOverviewSnapshot()
        synologyArtistEntries = []
        synologyAlbumEntries = []
        synologySearchSongs = []
        errorMessage = nil
    }

    /// 平台和“聚合/单平台”经常在一次菜单操作中连续变化。短暂合并后只按最终状态搜一次。
    private func scheduleScopeRefresh(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        scopeRefreshTask?.cancel()
        scopeRefreshTask = Task {
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            guard keyword.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
            await startSearch(trimmed)
        }
    }

    /// 热搜/历史/歌手名点击：立即搜索，同时抑制由 keyword 赋值产生的那一次 debounce。
    private func runImmediateSearch(_ text: String, updateKeyword: Bool = false, recordHistory: Bool = true) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        debounceTask?.cancel()
        nasIndexRefreshTask?.cancel()
        if updateKeyword, keyword != trimmed {
            immediateKeyword = trimmed
            keyword = trimmed
        }
        if recordHistory { historyStore.record(trimmed) }
        Task { await startSearch(trimmed) }
    }

    /// NAS 索引可能在很短时间内连续发布分页进度。合并这些通知，等索引稳定
    /// 后只补搜一次；执行前再次确认关键词没有变化，避免旧 NAS 事件顶掉新搜索。
    private func scheduleNASIndexRefresh(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        nasIndexRefreshTask?.cancel()
        nasIndexRefreshTask = Task {
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled else { return }
            guard keyword.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
            await startSearch(trimmed)
        }
    }

    var body: some View {
        let _ = theme.accent
        ATMusicNavigationStackWithPath(path: $navigationPath) {
            ZStack(alignment: .top) {
            // 页面背景：同步开启时显示壁纸/背景色，否则默认氛围渐变
            GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
            // 实例级 UITabBar 清透风格（固定全透明，无需调节）
            TabBarAppearanceConfigurator()
            VStack(spacing: 0) {
                headerTitle
                    .padding(.horizontal, DeviceLayoutHelper.isIPadRegular(horizontalSizeClass) ? 28 : (isNativeClean ? 24 : 20))
                    .padding(.top, 12)
                    .padding(.bottom, 12)

                searchField
                    .padding(.horizontal, DeviceLayoutHelper.isIPadRegular(horizontalSizeClass) ? 28 : (isNativeClean ? 24 : 20))
                    .padding(.bottom, 10)

                contentArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: DeviceLayoutHelper.contentMaxWidth(for: horizontalSizeClass))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .navigationTitle(keyword.isEmpty ? "搜索" : keyword)
            .navigationBarHidden(true)
            .atmusicNavigationDestination(for: SearchRoute.self) { route in
                searchDestination(route)
            }
        }
        .task {
            await loadAllHotWords()
        }
        .onChange(of: keyword) { newValue in
            debounceTask?.cancel()
            nasIndexRefreshTask?.cancel()
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)

            // 程序化点击热搜/历史记录已经立即搜索，不再额外安排 400ms debounce。
            if immediateKeyword == trimmed {
                immediateKeyword = nil
                return
            }
            immediateKeyword = nil

            guard !trimmed.isEmpty else {
                invalidateSearchPipeline(cancelDebounce: false)
                clearSearchResults()
                return
            }

            // 用户已经输入了新关键词，立即让旧请求失效；旧结果可暂时留在屏幕上，
            // 等新搜索原子提交后再替换，避免输入过程中整页闪空。
            invalidateSearchPipeline(cancelDebounce: false)
            searching = true
            debounceTask = Task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                await startSearch(trimmed)
            }
        }
        .onChange(of: provider) { _ in
            providerRaw = provider.rawValue
            // 聚合模式只关心 enabledSearchProviders；provider 只是下次单平台搜索的备用值，
            // 不能因为它变化就清空/重搜当前聚合页。
            guard !aggregateSearch else { return }
            invalidateSearchPipeline()
            aggregateOverview = false
            if provider == .synology { resultType = .song }
            let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            searching = true
            scheduleScopeRefresh(trimmed)
        }
        .onChange(of: aggregateSearch) { enabled in
            invalidateSearchPipeline()
            aggregateOverview = enabled
            if !enabled, provider == .synology { resultType = .song }
            let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            searching = true
            scheduleScopeRefresh(trimmed)
        }
        .onChange(of: synology.libraryIndexRevision) { _ in
            // 首次搜索先显示 Audio Station 的快速结果；完整 NAS 索引完成后，
            // 自动重搜当前关键词，把曲库后部的歌曲、歌手和专辑补进来。
            let nasParticipates = aggregateSearch
                ? searchProviders.contains(.synology)
                : provider == .synology
            guard nasParticipates, !synology.isLibraryIndexLoading else { return }
            let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            scheduleNASIndexRefresh(trimmed)
        }
        .onChange(of: synology.isLibraryIndexLoading) { loading in
            // 索引按分页更新 revision；只在整次索引结束后补搜一次，不能每页
            // 都重启聚合搜索，否则结果会在多组快照之间持续闪烁。
            guard !loading else { return }
            let nasParticipates = aggregateSearch
                ? searchProviders.contains(.synology)
                : provider == .synology
            let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard nasParticipates, !trimmed.isEmpty else { return }
            scheduleNASIndexRefresh(trimmed)
        }
        .onAppear {
            provider = platformPrefs.ensureVisible(SearchProvider(rawValue: providerRaw) ?? .netease)
        }
        // 直接观察值变化，不能订阅计算型 AnyPublisher。后者在视图重建时会
        // 重新订阅并立即回放当前值，形成“结果更新 → 重绘 → 再次搜索”的循环。
        .onChange(of: platformPrefs.selectedRaw) { _ in
            let next = platformPrefs.ensureVisible(provider)
            if next != provider {
                provider = next
            }
            if aggregateSearch {
                let enabled = Set(searchProviders)
                songResults.removeAll { !isEnabledAggregateSource($0.source, in: enabled) }
                playlistResults.removeAll { !isEnabledAggregateSource($0.source, in: enabled) }
                artistResults.removeAll { !isEnabledAggregateSource($0.source, in: enabled) }
                albumResults.removeAll { !isEnabledAggregateSource($0.source, in: enabled) }
                filterOverviewSnapshot(enabledProviders: enabled)
                Task { await loadAllHotWords() }
                let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    invalidateSearchPipeline()
                    searching = true
                    scheduleScopeRefresh(trimmed)
                }
            } else {
                Task { await loadAllHotWords() }
            }
        }
        .sheet(item: $showAddToPlaylist) { song in
            AddToPlaylistSheet(song: song)
                .environmentObject(theme)
        }
        .sheet(item: $selectedArtist) { artist in
            AllSourcesArtistHomeSheet(
                artistName: artist.name,
                initialSongs: songResults.filter { $0.artists.localizedCaseInsensitiveContains(artist.name) }
            )
                .environmentObject(player)
                .environmentObject(theme)
        }
        .sheet(item: $selectedSynologyArtist) { artist in
            ATMusicNavigationStack {
                AllSourcesArtistHomeSheet(artistName: artist.name, initialSongs: synologySearchSongs)
            }
            .environmentObject(player)
            .environmentObject(theme)
        }
    }

    @ViewBuilder
    private func searchDestination(_ route: SearchRoute) -> some View {
        switch route {
        case .album(let album):
            AlbumDetailView(album: album, isModal: false)
                .environmentObject(player)
                .environmentObject(theme)
        case .playlist(let playlist):
            PlaylistView(playlist: playlist)
                .environmentObject(player)
                .environmentObject(auth)
                .environmentObject(theme)
        case .synologyAlbum(let album):
            SynologyAlbumView(
                albumName: album.name,
                artistName: album.artistName,
                coverURL: album.coverURL,
                initialSongs: synologySearchSongs,
                isModal: false
            )
            .environmentObject(player)
            .environmentObject(theme)
        }
    }

    // MARK: - 顶部标题

    private var headerTitle: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(keyword.isEmpty ? "搜索" : keyword)
                .font(ATMusicFont.appFont(keyword.isEmpty ? 32 : 42, .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.62)
                .foregroundStyle(Color.atmusicLabel)
            Spacer(minLength: 0)
            if isNativeClean {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.atmusicComment.opacity(0.7))
                    .frame(width: 36, height: 36)
                    .background { ATMusicGlass(shape: Circle()) }
                    .clipShape(Circle())
                    .accessibilityLabel("账户")
            }
        }
    }

    // MARK: - 内容区（热搜 / 分类+结果 固定占满剩余高度，切换不引起布局跳动）

    @ViewBuilder
    private var contentArea: some View {
        if keyword.isEmpty {
            // 所有主题沿用 1.8 的搜索首屏层级，避免切换主题后交互变成另一套。
            referenceSearchLanding
        } else {
            VStack(spacing: 0) {
                providerPicker
                typeTabs
                resultsArea
            }
        }
    }

    // MARK: - 搜索框（液态玻璃胶囊）

    private var searchField: some View {
        // 音源选择统一置于结果区，输入框保持 1.8 的简洁层级。
        referenceSearchField
    }


    /// 复刻 1.8.1 的简洁搜索框：视觉上只保留放大镜和输入区；聚合/单平台
    /// 选择仍可由放大镜按钮打开，因此 NAS 与多平台能力不会消失。
    private var referenceSearchField: some View {
        HStack(spacing: 10) {
            Menu {
                Button {
                    aggregateSearch = true
                    ATMusicHaptics.tap()
                } label: {
                    Label("聚合搜索", systemImage: aggregateSearch ? "checkmark" : "square.stack.3d.up.fill")
                }
                Divider()
                ForEach(searchProviders) { source in
                    Button {
                        aggregateSearch = false
                        provider = source
                        ATMusicHaptics.tap()
                    } label: {
                        Label(source.rawValue, systemImage: !aggregateSearch && provider == source ? "checkmark" : source.icon)
                    }
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.atmusicComment)
                    .frame(width: 25, height: 32)
            }
            .menuStyle(.borderlessButton)

            SearchTextField(
                text: $keyword,
                controller: searchController,
                placeholder: atmusicLocalized("搜索歌曲、歌手、专辑", "Search songs, artists, or albums"),
                textColor: UIColor.atmusicLabel,
                onSubmit: { text in
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    runImmediateSearch(trimmed, updateKeyword: true)
                }
            )
            .frame(height: 34)

            if searching {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 20)
            } else if !keyword.isEmpty {
                Button {
                    keyword = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.atmusicComment.opacity(0.78))
                }
                .buttonStyle(.plain)
                .frame(width: 20)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 58)
        .background { ATMusicSurface(shape: Capsule()) }
        .overlay { Capsule().strokeBorder(Color.atmusicComment.opacity(0.16), lineWidth: 0.7) }
        .clipShape(Capsule())
        .frame(maxWidth: .infinity)
    }

    /// 搜索框左侧音源切换：默认全网聚合，也可直接锁定单个平台。
    private var searchScopeMenu: some View {
        Menu {
            Button {
                ATMusicHaptics.tap()
                aggregateSearch = true
            } label: {
                Label("聚合", systemImage: aggregateSearch ? "checkmark" : "square.stack.3d.up.fill")
            }

            Divider()

            ForEach(searchProviders) { source in
                Button {
                    ATMusicHaptics.tap()
                    aggregateSearch = false
                    if source != provider {
                        provider = source
                    }
                } label: {
                    Label(source.rawValue, systemImage: !aggregateSearch && source == provider ? "checkmark" : source.icon)
                }
            }
        } label: {
            HStack(spacing: 4) {
                if aggregateSearch {
                    Image(systemName: "square.stack.3d.up.fill")
                } else if let imageName = provider.brandImageName {
                    Image(imageName)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: provider.icon)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(aggregateSearch ? AnyShapeStyle(Color.atmusicAmber) : AnyShapeStyle(provider.tint))
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel(aggregateSearch ? "全网搜索" : "\(provider.rawValue)搜索")
    }

    // MARK: - 平台选择（1.8 搜索平台胶囊）

    private var providerPicker: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("搜索平台")
                    .font(ATMusicFont.appFont(15, .medium))
                    .foregroundStyle(Color.atmusicComment)
                Spacer(minLength: 0)
                Text(aggregateSearch ? "聚合" : provider.rawValue)
                    .font(ATMusicFont.appFont(15, .semibold))
                    .foregroundStyle(Color.accentColor)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    searchPlatformPill(title: "聚合", systemImage: "checkmark", selected: aggregateSearch) {
                        aggregateSearch = true
                        aggregateOverview = true
                        ATMusicHaptics.tap()
                    }
                    ForEach(searchProviders) { item in
                        searchPlatformPill(
                            title: item.rawValue,
                            systemImage: item.brandImageName == nil ? item.icon : nil,
                            selected: !aggregateSearch && provider == item
                        ) {
                            ATMusicHaptics.tap()
                            // 搜索平台是单选：要么全网聚合，要么锁定一个平台。
                            // 不再在聚合页内增减平台，避免一次点按触发多轮并发请求。
                            if aggregateSearch || provider != item {
                                aggregateSearch = false
                                provider = item
                            }
                        }
                    }
                }
                .padding(.horizontal, 1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    private func searchPlatformPill(title: String, systemImage: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if title == "聚合" {
                    Image(systemName: selected ? "checkmark" : "square.stack.3d.up.fill")
                        .font(.system(size: 13, weight: .bold))
                } else if let imageName = SearchProvider(rawValue: title)?.brandImageName {
                    Image(imageName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 15, height: 15)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(title)
                    .font(ATMusicFont.appFont(15, .semibold))
            }
            .atmusicSelectionForeground(selected: selected, accent: .atmusicAmber)
            .padding(.horizontal, 18)
            .frame(height: 44)
            .background {
                ATMusicSelectableSurface(selected: selected, shape: Capsule(), accent: .atmusicAmber)
            }
        }
        .buttonStyle(GlassPressButtonStyle(scale: 0.95))
    }

    // MARK: - 分类选择（歌曲 / 歌手 / 专辑）

    private var typeTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 12) {
            if aggregateSearch {
                Button {
                    ATMusicHaptics.tap()
                    aggregateOverview = true
                } label: {
                    Text("综合")
                        .font(ATMusicFont.appFont(15, .semibold))
                        .atmusicSelectionForeground(selected: aggregateOverview, accent: .atmusicAmber)
                        .padding(.horizontal, 24)
                        .frame(height: 44)
                        .background {
                            ATMusicSelectableSurface(selected: aggregateOverview, shape: Capsule(), accent: .atmusicAmber)
                        }
                }
                .buttonStyle(GlassPressButtonStyle(scale: 0.95))
            }
            ForEach(SearchResultType.allCases) { type in
                Button {
                    ATMusicHaptics.tap()
                    let wasOverview = aggregateOverview
                    if aggregateSearch {
                        selectAggregateResultType(type)
                        return
                    }
                    aggregateOverview = false
                    guard resultType != type || wasOverview else { return }
                    resultType = type
                    let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    // 切换分类：清空该分类旧结果并立即进入加载态，避免显示过期数据或空态闪烁
                    invalidateSearchPipeline()
                    switch type {
                    case .song: songResults = []
                    case .artist: artistResults = []
                    case .album: albumResults = []
                    case .playlist: playlistResults = []
                    }
                    errorMessage = nil
                    searching = true
                    runImmediateSearch(trimmed, recordHistory: false)
                } label: {
                    Text(LocalizedStringKey(type.rawValue))
                        .font(ATMusicFont.appFont(15, .semibold))
                        .atmusicSelectionForeground(selected: !aggregateOverview && resultType == type, accent: .atmusicAmber)
                        .padding(.horizontal, 24)
                        .frame(height: 44)
                        .background {
                            ATMusicSelectableSurface(
                                selected: !aggregateOverview && resultType == type,
                                shape: Capsule(),
                                accent: .atmusicAmber
                            )
                        }
                }
                .buttonStyle(GlassPressButtonStyle(scale: 0.95))
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    // MARK: - 热搜（排名卡片）


    /// 参考 1.8.1 搜索空态：说明图标、引导文案、双列热门词与历史搜索。
    private var referenceSearchLanding: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 58, weight: .light))
                        .foregroundStyle(Color.atmusicComment.opacity(0.75))
                    Text("搜索歌曲、歌手、专辑或歌单")
                        .font(ATMusicFont.appFont(20, .bold))
                        .foregroundStyle(Color.atmusicLabel)
                    Text("使用搜索框开始，聚合搜索也可以切换到单个平台。")
                        .font(ATMusicFont.appFont(13))
                        .foregroundStyle(Color.atmusicComment)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 76)
                .padding(.bottom, 30)

                HStack {
                    Label("热门搜索", systemImage: "flame.fill")
                        .font(ATMusicFont.appFont(18, .bold))
                        .foregroundStyle(Color.atmusicLabel)
                    Spacer()
                    referenceSearchScopeMenu
                }

                if referenceHotWords.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在汇总各平台热搜…")
                            .font(ATMusicFont.appFont(13))
                            .foregroundStyle(Color.atmusicComment)
                    }
                    .padding(.vertical, 18)
                } else {
                    LazyVGrid(
                        columns: DeviceLayoutHelper.isIPadRegular(horizontalSizeClass)
                            ? [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 12)]
                            : [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(referenceHotWords, id: \.self) { word in
                            Button {
                                searchController.dismissKeyboard()
                                runImmediateSearch(word, updateKeyword: true)
                            } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: "magnifyingglass")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Color.accentColor)
                                    Text(word)
                                        .font(ATMusicFont.appFont(14, .medium))
                                        .foregroundStyle(Color.atmusicLabel)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 14)
                                .frame(height: 44)
                                .background { ATMusicSurface(shape: Capsule()) }
                                .overlay { Capsule().strokeBorder(Color.atmusicComment.opacity(0.13), lineWidth: 0.7) }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 16)
                }

                SearchHistorySection { word in
                    searchController.dismissKeyboard()
                    runImmediateSearch(word, updateKeyword: true)
                }
                .padding(.top, 28)
                Spacer().frame(height: 160)
            }
            .padding(.horizontal, 24)
        }
        .atmusicScrollIndicatorsHidden()
        .atmusicScrollDismissesKeyboard()
    }

    private var referenceSearchScopeMenu: some View {
        Menu {
            Button {
                aggregateSearch = true
                ATMusicHaptics.tap()
            } label: {
                Label("聚合", systemImage: aggregateSearch ? "checkmark" : "square.stack.3d.up.fill")
            }
            Divider()
            ForEach(searchProviders) { source in
                Button {
                    aggregateSearch = false
                    provider = source
                } label: {
                    Label(source.rawValue, systemImage: !aggregateSearch && provider == source ? "checkmark" : source.icon)
                }
            }
        } label: {
            Text(aggregateSearch ? "聚合" : provider.rawValue)
                .font(ATMusicFont.appFont(13, .medium))
                .foregroundStyle(Color.atmusicComment)
        }
        .menuStyle(.borderlessButton)
    }

    @ViewBuilder
    private func hotProviderSection(_ source: SearchProvider) -> some View {
        SectionHeader(title: "\(source.rawValue)热搜")
        if let words = hotWordsByProvider[source], !words.isEmpty {
            if #available(iOS 16, *) {
                FlowLayout(spacing: 10) {
                    ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                        hotTag(index: index, word: word)
                    }
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], alignment: .leading, spacing: 10) {
                    ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                        hotTag(index: index, word: word)
                    }
                }
            }
        } else if hotLoadingProviders.contains(source) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在加载\(source.rawValue)热搜…")
                    .font(ATMusicFont.appFont(13))
                    .foregroundStyle(Color.atmusicComment)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
        } else {
            Text(source == .synology ? "NAS 没有公共热搜接口，请直接输入关键词搜索本地音乐" : "暂时没有获取到热搜，直接输入关键词即可搜索")
                .font(ATMusicFont.appFont(13))
                .foregroundStyle(Color.atmusicComment)
                .padding(.vertical, 8)
        }
    }

    /// 热搜前三名渐变配色（更亮眼：橙红 / 金黄 / 冰蓝）
    private let hotRankColors: [[Color]] = [
        [Color(red: 1.00, green: 0.62, blue: 0.18), Color(red: 0.95, green: 0.25, blue: 0.18)],
        [Color(red: 1.00, green: 0.82, blue: 0.30), Color(red: 0.98, green: 0.56, blue: 0.12)],
        [Color(red: 0.55, green: 0.85, blue: 1.00), Color(red: 0.30, green: 0.52, blue: 0.98)],
    ]
    private let hotRankIcons = ["crown.fill", "flame.fill", "sparkles"]

    /// 热搜标签：前三名渐变发光圆标（更亮眼），其余为普通序号
    private func hotTag(index: Int, word: String) -> some View {
        let top3 = index < 3
        return Button {
            ATMusicHaptics.tap()
            searchController.dismissKeyboard()
            runImmediateSearch(word, updateKeyword: true)
        } label: {
            HStack(spacing: 7) {
                if top3 {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: hotRankColors[index],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 24, height: 24)
                            .shadow(color: hotRankColors[index][0].opacity(0.6), radius: 6, y: 2)
                            .overlay {
                                Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1)
                            }
                        Image(systemName: hotRankIcons[index])
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                    }
                } else {
                    Text("\(index + 1)")
                        .font(ATMusicFont.appFont(11, .bold, .rounded))
                        .foregroundStyle(Color.atmusicComment)
                        .frame(width: 18, height: 18)
                }
                Text(word)
                    .font(ATMusicFont.appFont(top3 ? 15 : 14, top3 ? .bold : .medium))
                    .foregroundStyle(top3 ? Color.atmusicLabel : Color.atmusicComment)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background {
                ATMusicGlass(shape: Capsule())
            }
            .overlay {
                if top3 {
                    Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.8)
                }
            }
        }
        .buttonStyle(GlassPressButtonStyle(scale: 0.92))
    }

    // MARK: - 结果区

    @ViewBuilder
    private var resultsArea: some View {
        if provider == .synology && !aggregateSearch {
            synologySearchResultsArea
        } else if aggregateSearch && aggregateOverview {
            allSearchResultsArea
        } else {
            switch resultType {
            case .song: songResultsArea
            case .artist: artistResultsArea
            case .album: albumResultsArea
            case .playlist: playlistResultsArea
            }
        }
    }

    private var playlistResultsArea: some View {
        Group {
            if let errorMessage, playlistResults.isEmpty {
                ErrorStateView(message: errorMessage) { submitSearch() }
            } else if searching && playlistResults.isEmpty {
                LoadingStateView()
            } else if playlistResults.isEmpty {
                EmptyStateView(icon: "music.note.list", text: "未找到相关歌单")
            } else {
                ScrollView {
                    LazyVGrid(columns: DeviceLayoutHelper.adaptiveCardColumns(for: horizontalSizeClass, minWidth: 150, maxWidth: 240, spacing: 16), spacing: 18) {
                        ForEach(playlistResults, id: \.identityKey) { playlist in
                            Button {
                                ATMusicHaptics.tap()
                                openRoute(.playlist(playlist))
                            } label: {
                                MediaSquareCard(playlist: playlist)
                            }
                            .buttonStyle(GlassPressButtonStyle(scale: 0.97))
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 180)
                }
                .atmusicScrollIndicatorsHidden()
                .atmusicScrollDismissesKeyboard()
            }
        }
    }


    /// 1.8 的聚合结果页：一次搜索同时给出四类结果，按内容分区而不是按音源分组。
    /// 每一行保留来源徽标，点歌手/专辑/歌单仍进入对应详情页。
    private var allSearchResultsArea: some View {
        let hasResults = hasOverviewSnapshot && (!overviewSongs.isEmpty || !overviewArtists.isEmpty || !overviewAlbums.isEmpty || !overviewPlaylists.isEmpty)
        return Group {
            if let errorMessage, !hasResults {
                ErrorStateView(message: errorMessage) { submitSearch() }
            } else if searching && !hasResults {
                LoadingStateView()
            } else if !hasResults {
                EmptyStateView(icon: "magnifyingglass", text: "未找到相关内容")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        aggregateSummary

                        if !overviewSongs.isEmpty {
                            aggregateSongSection
                        }
                        if !overviewArtists.isEmpty {
                            aggregateArtistSection
                        }
                        if !overviewAlbums.isEmpty {
                            aggregateAlbumSection
                        }
                        if !overviewPlaylists.isEmpty {
                            aggregatePlaylistSection
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 180)
                    .frame(maxWidth: DeviceLayoutHelper.contentMaxWidth(for: horizontalSizeClass))
                    .frame(maxWidth: .infinity)
                }
                .atmusicScrollIndicatorsHidden()
                .atmusicScrollDismissesKeyboard()
                .overlay(alignment: .top) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.atmusicAmber)
                        .padding(.top, 4)
                        .opacity(searching ? 1 : 0)
                }
            }
        }
    }

    private var aggregateSummary: some View {
        Text("找到 \(overviewResultCount) 项 · \(searchScopeName)")
            .font(ATMusicFont.appFont(14))
            .foregroundStyle(Color.atmusicComment)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 从“综合”进入某个分类时，必须在同一个事务里同时切页面和灌入快照。
    /// 否则 albumResults / playlistResults 仍为空，第一次进入“更多专辑/更多歌单”会显示空页，
    /// 直到用户再切一次分类才被补齐。
    private func selectAggregateResultType(_ type: SearchResultType) {
        aggregateOverview = false
        resultType = type
        guard let snapshot = overviewSnapshot else { return }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            switch type {
            case .song:
                songResults = snapshot.songs
            case .artist:
                artistResults = snapshot.artists
            case .album:
                albumResults = snapshot.albums
            case .playlist:
                playlistResults = snapshot.playlists
            }
        }
    }

    private func aggregateSectionHeader(_ title: String, count: Int, icon: String, type: SearchResultType) -> some View {
        Button {
            ATMusicHaptics.tap()
            selectAggregateResultType(type)
        } label: {
            HStack(spacing: 7) {
                Text(title)
                    .font(ATMusicFont.appFont(28, .bold))
                    .foregroundStyle(Color.atmusicLabel)
                Image(systemName: "chevron.right")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color.atmusicComment)
                Text("\(count)")
                    .font(ATMusicFont.appFont(13, .medium))
                    .foregroundStyle(Color.atmusicComment)
                Spacer(minLength: 0)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor.opacity(0.85))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var aggregateArtistSection: some View {
        let artistCount = DeviceLayoutHelper.isIPadRegular(horizontalSizeClass) ? 6 : 3
        return VStack(alignment: .leading, spacing: 8) {
            aggregateSectionHeader("歌手", count: overviewArtists.count, icon: "person.2.fill", type: .artist)
            LazyVGrid(columns: DeviceLayoutHelper.adaptiveCardColumns(for: horizontalSizeClass, minWidth: 120, maxWidth: 180, spacing: 16), spacing: 18) {
                ForEach(Array(overviewArtists.prefix(artistCount)), id: \.identityKey) { artist in
                    Button {
                        ATMusicHaptics.tap()
                        openArtist(artist)
                    } label: {
                        VStack(spacing: 6) {
                            CoverImage(url: artist.coverURL, size: 120, cornerRadius: 60)
                            Text(artist.name)
                                .font(ATMusicFont.appFont(14, .medium))
                                .foregroundStyle(Color.atmusicLabel)
                                .lineLimit(1)
                            Text(artist.source.atmusicDisplayName)
                                .font(ATMusicFont.appFont(12))
                                .foregroundStyle(Color.atmusicComment)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GlassPressButtonStyle(scale: 0.98))
                }
            }
        }
    }

    private var aggregateAlbumSection: some View {
        let albumCount = DeviceLayoutHelper.isIPadRegular(horizontalSizeClass) ? 6 : 3
        return VStack(alignment: .leading, spacing: 8) {
            aggregateSectionHeader("专辑", count: overviewAlbums.count, icon: "square.stack.fill", type: .album)
            LazyVGrid(columns: DeviceLayoutHelper.adaptiveCardColumns(for: horizontalSizeClass, minWidth: 140, maxWidth: 200, spacing: 16), spacing: 18) {
                ForEach(Array(overviewAlbums.prefix(albumCount)), id: \.identityKey) { album in
                    Button {
                        ATMusicHaptics.tap()
                        openAlbum(album)
                    } label: {
                        MediaSquareCard(album: album)
                    }
                    .buttonStyle(GlassPressButtonStyle(scale: 0.98))
                }
            }
        }
    }

    private var aggregatePlaylistSection: some View {
        let playlistCount = DeviceLayoutHelper.isIPadRegular(horizontalSizeClass) ? 6 : 3
        return VStack(alignment: .leading, spacing: 8) {
            aggregateSectionHeader("歌单", count: overviewPlaylists.count, icon: "music.note.list", type: .playlist)
            LazyVGrid(columns: DeviceLayoutHelper.adaptiveCardColumns(for: horizontalSizeClass, minWidth: 140, maxWidth: 200, spacing: 16), spacing: 18) {
                ForEach(Array(overviewPlaylists.prefix(playlistCount)), id: \.identityKey) { playlist in
                    Button {
                        ATMusicHaptics.tap()
                        openRoute(.playlist(playlist))
                    } label: {
                        MediaSquareCard(playlist: playlist)
                    }
                    .buttonStyle(GlassPressButtonStyle(scale: 0.98))
                }
            }
        }
    }

    private var aggregateSongSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                aggregateSectionHeader("歌曲", count: overviewSongs.count, icon: "music.note", type: .song)
                Button {
                    ATMusicHaptics.tap()
                    player.play(songs: overviewSongs, startAt: 0)
                } label: {
                    Label("播放全部", systemImage: "play.fill")
                        .font(ATMusicFont.appFont(12, .semibold))
                        .foregroundStyle(Color.atmusicAmber)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background { ATMusicSurface(shape: Capsule()) }
                }
                .buttonStyle(GlassPressButtonStyle(scale: 0.97))
            }
            let songCount = DeviceLayoutHelper.isIPadRegular(horizontalSizeClass) ? 8 : 6
            if DeviceLayoutHelper.isIPadRegular(horizontalSizeClass) {
                LazyVGrid(columns: DeviceLayoutHelper.songListColumns(for: horizontalSizeClass, spacing: 16), spacing: 8) {
                    ForEach(Array(overviewSongs.prefix(songCount).enumerated()), id: \.element.identityKey) { index, song in
                        SongCell(song: song, suppressNativeCleanRowGlass: isNativeClean, onTap: {
                            ATMusicHaptics.tap()
                            player.play(songs: overviewSongs, startAt: index)
                        })
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background {
                            if !isNativeClean {
                                ATMusicSurface(shape: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                        }
                    }
                }
            } else {
                ForEach(Array(overviewSongs.prefix(songCount).enumerated()), id: \.element.identityKey) { index, song in
                    SongCell(song: song, suppressNativeCleanRowGlass: isNativeClean, onTap: {
                        ATMusicHaptics.tap()
                        player.play(songs: overviewSongs, startAt: index)
                    })
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background {
                        if !isNativeClean {
                            ATMusicSurface(shape: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var synologySearchResultsArea: some View {
        switch resultType {
        case .song:
            synologySongResultsArea
        case .artist:
            synologyArtistResultsArea
        case .album:
            albumResultsArea
        case .playlist:
            synologyPlaylistResultsArea
        }
    }

    private var synologySongResultsArea: some View {
        Group {
            if let errorMessage, songResults.isEmpty {
                ErrorStateView(message: errorMessage) { submitSearch() }
            } else if searching && songResults.isEmpty {
                LoadingStateView()
            } else if songResults.isEmpty {
                EmptyStateView(icon: "music.note", text: "群晖 NAS 未找到相关歌曲")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("歌曲")
                                .font(ATMusicFont.appFont(17, .bold))
                                .foregroundStyle(Color.atmusicLabel)
                            Spacer()
                            Button {
                                ATMusicHaptics.tap()
                                player.play(songs: songResults, startAt: 0)
                            } label: {
                                Label("播放全部", systemImage: "play.fill")
                                    .font(ATMusicFont.appFont(12, .semibold))
                                    .foregroundStyle(Color.atmusicAmber)
                            }
                            .buttonStyle(GlassPressButtonStyle(scale: 0.97))
                        }
                        if DeviceLayoutHelper.isIPadRegular(horizontalSizeClass) {
                            LazyVGrid(columns: DeviceLayoutHelper.songListColumns(for: horizontalSizeClass, spacing: 16), spacing: 8) {
                                ForEach(Array(songResults.enumerated()), id: \.element.identityKey) { index, song in
                                    SongCell(song: song, suppressNativeCleanRowGlass: isNativeClean, onTap: {
                                        player.play(songs: songResults, startAt: index)
                                    })
                                }
                            }
                        } else {
                            ForEach(Array(songResults.enumerated()), id: \.element.identityKey) { index, song in
                                SongCell(song: song, suppressNativeCleanRowGlass: isNativeClean, onTap: {
                                    player.play(songs: songResults, startAt: index)
                                })
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 180)
                    .frame(maxWidth: DeviceLayoutHelper.contentMaxWidth(for: horizontalSizeClass))
                    .frame(maxWidth: .infinity)
                }
                .atmusicScrollIndicatorsHidden()
                .atmusicScrollDismissesKeyboard()
            }
        }
    }

    private var synologyArtistResultsArea: some View {
        Group {
            if let errorMessage, synologyArtistEntries.isEmpty {
                ErrorStateView(message: errorMessage) { submitSearch() }
            } else if searching && synologyArtistEntries.isEmpty {
                LoadingStateView()
            } else if synologyArtistEntries.isEmpty {
                EmptyStateView(icon: "person.crop.circle", text: "群晖 NAS 未找到相关歌手")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        synologyEntrySection(title: "歌手", entries: synologyArtistEntries, icon: "person.crop.circle") { entry in
                            let name = entry.names.first ?? entry.subtitle
                            selectedSynologyArtist = SynologyArtistSelection(id: entry.id, name: name, coverURL: entry.coverURL)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 180)
                }
                .atmusicScrollIndicatorsHidden()
                .atmusicScrollDismissesKeyboard()
            }
        }
    }

    private var synologyAlbumResultsArea: some View {
        Group {
            if let errorMessage, synologyAlbumEntries.isEmpty {
                ErrorStateView(message: errorMessage) { submitSearch() }
            } else if searching && synologyAlbumEntries.isEmpty {
                LoadingStateView()
            } else if synologyAlbumEntries.isEmpty {
                EmptyStateView(icon: "square.stack", text: "群晖 NAS 未找到相关专辑")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        synologyEntrySection(title: "专辑", entries: synologyAlbumEntries, icon: "square.stack") { entry in
                            let album = SynologyAlbumSelection(
                                id: entry.id,
                                name: entry.names.first ?? "未命名专辑",
                                artistName: entry.subtitle,
                                coverURL: entry.coverURL
                            )
                            openRoute(.synologyAlbum(album))
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 180)
                }
                .atmusicScrollIndicatorsHidden()
                .atmusicScrollDismissesKeyboard()
            }
        }
    }

    private var synologyPlaylistResultsArea: some View {
        playlistResultsArea
    }

    private func synologyEntrySection(title: String, entries: [SynologySearchEntry], icon: String, action: @escaping (SynologySearchEntry) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(ATMusicFont.appFont(17, .bold))
                .foregroundStyle(Color.atmusicLabel)
            ForEach(entries) { entry in
                Button { action(entry) } label: {
                    HStack(spacing: 12) {
                        if let coverURL = entry.coverURL {
                            CoverImage(url: coverURL, size: 46, cornerRadius: title == "歌手" ? 23 : 6)
                        } else {
                            Image(systemName: icon)
                                .font(.system(size: 21))
                                .foregroundStyle(Color.atmusicComment)
                                .frame(width: 46, height: 46)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.names.joined(separator: " / "))
                                .font(ATMusicFont.appFont(15, .medium))
                                .foregroundStyle(Color.atmusicLabel)
                                .lineLimit(2)
                            SourceBadgeView(source: .synology, compact: true)
                            if !entry.subtitle.isEmpty {
                                Text(entry.subtitle)
                                    .font(ATMusicFont.appFont(12))
                                    .foregroundStyle(Color.atmusicComment)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(Color.atmusicComment)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var songResultsArea: some View {
        Group {
            if let errorMessage, songResults.isEmpty {
                ErrorStateView(message: errorMessage) { submitSearch() }
            } else if searching && songResults.isEmpty {
                LoadingStateView()
            } else if songResults.isEmpty {
                EmptyStateView(icon: "music.note", text: "\(searchScopeName)未找到相关歌曲")
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Text(atmusicLocalized("找到 \(songResults.count) 首 · \(searchScopeName)", aggregateSearch ? "Found \(songResults.count) songs · All sources" : "Found \(songResults.count) songs · \(atmusicPlatformName(provider) )"))
                                .font(ATMusicFont.appFont(12))
                                .foregroundStyle(Color.atmusicComment)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                                .truncationMode(.tail)
                                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                                .layoutPriority(1)
                            Button {
                                ATMusicHaptics.tap()
                                player.play(songs: songResults, startAt: 0)
                            } label: {
                                Label("播放全部", systemImage: "play.fill")
                                    .font(ATMusicFont.appFont(12, .semibold))
                                    .foregroundStyle(Color.atmusicAmber)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background { ATMusicSurface(shape: Capsule()) }
                            }
                            .buttonStyle(GlassPressButtonStyle(scale: 0.97))
                            .fixedSize(horizontal: true, vertical: false)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                        if DeviceLayoutHelper.isIPadRegular(horizontalSizeClass) {
                            LazyVGrid(columns: DeviceLayoutHelper.songListColumns(for: horizontalSizeClass, spacing: 16), spacing: 8) {
                                ForEach(Array(songResults.enumerated()), id: \.element.identityKey) { index, song in
                                    SongCell(song: song, suppressNativeCleanRowGlass: isNativeClean, onTap: {
                                        ATMusicHaptics.tap()
                                        player.play(songs: songResults, startAt: index)
                                    })
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background {
                                        ATMusicSurface(shape: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    }
                                }
                            }
                        } else {
                            ForEach(Array(songResults.enumerated()), id: \.element.identityKey) { index, song in
                                SongCell(song: song, suppressNativeCleanRowGlass: isNativeClean, onTap: {
                                    ATMusicHaptics.tap()
                                    player.play(songs: songResults, startAt: index)
                                })
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background {
                                    ATMusicSurface(shape: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 180)
                    .frame(maxWidth: DeviceLayoutHelper.contentMaxWidth(for: horizontalSizeClass))
                    .frame(maxWidth: .infinity)
                }
                .atmusicScrollIndicatorsHidden()
                .atmusicScrollDismissesKeyboard()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.atmusicAmber)
                        .padding(.top, 10)
                        .opacity(searching && songResults.isEmpty ? 1 : 0)
                }
            }
        }
    }

    private var artistResultsArea: some View {
        Group {
            if let errorMessage, artistResults.isEmpty {
                ErrorStateView(message: errorMessage) { submitSearch() }
            } else if searching && artistResults.isEmpty {
                LoadingStateView()
            } else if artistResults.isEmpty {
                EmptyStateView(icon: "person.crop.circle", text: "\(searchScopeName)未找到相关歌手")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text(atmusicLocalized("找到 \(artistResults.count) 位 · \(searchScopeName)", aggregateSearch ? "Found \(artistResults.count) artists · All sources" : "Found \(artistResults.count) artists · \(atmusicPlatformName(provider) )"))
                                .font(ATMusicFont.appFont(12))
                                .foregroundStyle(Color.atmusicComment)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                                .truncationMode(.tail)
                                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                                .layoutPriority(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                        LazyVGrid(columns: DeviceLayoutHelper.adaptiveCardColumns(for: horizontalSizeClass, minWidth: 140, maxWidth: 220, spacing: 16), spacing: 18) {
                            ForEach(artistResults, id: \.identityKey) { artist in
                                Button {
                                    ATMusicHaptics.tap()
                                    searchController.dismissKeyboard()
                                    openArtist(artist)
                                } label: {
                                    VStack(spacing: 6) {
                                        CoverImage(url: artist.coverURL, size: 120, cornerRadius: 60)
                                        Text(artist.name)
                                            .font(ATMusicFont.appFont(14, .medium))
                                            .foregroundStyle(Color.atmusicLabel)
                                            .lineLimit(1)
                                        Text(artist.source.atmusicDisplayName)
                                            .font(ATMusicFont.appFont(12))
                                            .foregroundStyle(Color.atmusicComment)
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(GlassPressButtonStyle(scale: 0.97))
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 180)
                }
                .atmusicScrollIndicatorsHidden()
                .atmusicScrollDismissesKeyboard()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.atmusicAmber)
                        .padding(.top, 10)
                        .opacity(searching && artistResults.isEmpty ? 1 : 0)
                }
            }
        }
    }

    private var albumResultsArea: some View {
        Group {
            if let errorMessage, albumResults.isEmpty {
                ErrorStateView(message: errorMessage) { submitSearch() }
            } else if searching && albumResults.isEmpty {
                LoadingStateView()
            } else if albumResults.isEmpty {
                EmptyStateView(icon: "square.stack", text: "\(searchScopeName)未找到相关专辑")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text(atmusicLocalized("找到 \(albumResults.count) 张 · \(searchScopeName)", aggregateSearch ? "Found \(albumResults.count) albums · All sources" : "Found \(albumResults.count) albums · \(atmusicPlatformName(provider) )"))
                                .font(ATMusicFont.appFont(12))
                                .foregroundStyle(Color.atmusicComment)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                                .truncationMode(.tail)
                                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                                .layoutPriority(1)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                        LazyVGrid(columns: DeviceLayoutHelper.adaptiveCardColumns(for: horizontalSizeClass, minWidth: 150, maxWidth: 240, spacing: 16), spacing: 18) {
                            ForEach(albumResults, id: \.identityKey) { album in
                                Button {
                                    ATMusicHaptics.tap()
                                    searchController.dismissKeyboard()
                                    openAlbum(album)
                                } label: {
                                    MediaSquareCard(album: album)
                                }
                                .buttonStyle(GlassPressButtonStyle(scale: 0.97))
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 180)
                }
                .atmusicScrollIndicatorsHidden()
                .atmusicScrollDismissesKeyboard()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.atmusicAmber)
                        .padding(.top, 10)
                        .opacity(searching && albumResults.isEmpty ? 1 : 0)
                }
            }
        }
    }

    // MARK: - 动作

    private func openAlbum(_ album: Album) {
        ATMusicHaptics.tap()
        searchController.dismissKeyboard()
        if album.source == .synology {
            let searchSongs = songResults.filter { $0.source == .synology }
            let item = SynologyAlbumSelection(
                id: album.id,
                name: album.name,
                artistName: album.artistName,
                coverURL: album.coverURL
            )
            // NAS 搜索结果先作为详情页首屏候选，完整目录随后由详情页补齐。
            synologySearchSongs = searchSongs
            openRoute(.synologyAlbum(item))
        } else {
            openRoute(.album(album))
        }
    }

    private func openRoute(_ route: SearchRoute) {
        navigationPath.append(route)
    }

    private func openArtist(_ artist: Artist) {
        ATMusicHaptics.tap()
        searchController.dismissKeyboard()
        if artist.source == .synology {
            synologySearchSongs = songResults.filter { $0.source == .synology }
            selectedSynologyArtist = SynologyArtistSelection(
                id: artist.id,
                name: artist.name,
                coverURL: artist.coverURL
            )
        } else {
            selectedArtist = artist
        }
    }

    /// 重新搜索（错误重试按钮调用：读取当前输入框文本）
    private func submitSearch() {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        runImmediateSearch(trimmed)
    }


    /// 并发加载各平台热搜。NAS 没有公共热搜接口，直接标记为不可用，不能把空数组当成“还在加载”。
    private func loadAllHotWords() async {
        hotWordsGeneration &+= 1
        let generation = hotWordsGeneration
        let providers = aggregateSearch ? searchProviders : [provider]
        hotLoadingProviders = Set(providers.filter { $0 != .synology && $0 != .subsonic && $0 != .jellyfin && $0 != .webdav })
        hotUnavailableProviders = Set(providers.filter { $0 == .synology || $0 == .subsonic || $0 == .jellyfin || $0 == .webdav })
        hotWordsByProvider = hotWordsByProvider.filter { providers.contains($0.key) }

        for source in providers where source != .synology && source != .subsonic && source != .jellyfin && source != .webdav {
            Task {
                let words: [String]?
                switch source {
                case .netease:
                    words = try? await NetEaseAPI.shared.hotSearch()
                case .qq:
                    words = try? await QQMusicAPI.shared.hotKeys()
                case .kugou:
                    let values = await KugouMusicAPI.shared.hotWords()
                    words = values.isEmpty ? nil : values
                case .synology:
                    words = nil
                case .subsonic, .jellyfin, .webdav:
                    words = nil
                }
                await MainActor.run {
                    guard hotWordsGeneration == generation else { return }
                    hotLoadingProviders.remove(source)
                    if let words, !words.isEmpty {
                        hotWordsByProvider[source] = Array(words.prefix(20))
                        hotUnavailableProviders.remove(source)
                    } else {
                        hotUnavailableProviders.insert(source)
                    }
                }
            }
        }
    }

    private func makeSynologyArtistEntries(_ artists: [Artist], songs: [Song]) -> [SynologySearchEntry] {
        var entries: [SynologySearchEntry] = []
        var indexes: [String: Int] = [:]
        for artist in artists {
            let key = synologyCanonicalName(artist.name)
            guard !key.isEmpty else { continue }
            if let index = indexes[key] {
                if !entries[index].names.contains(artist.name) {
                    entries[index] = SynologySearchEntry(id: entries[index].id, names: entries[index].names + [artist.name], subtitle: entries[index].subtitle, coverURL: entries[index].coverURL)
                }
            } else {
                let cover = artist.coverURL ?? songs.first(where: { $0.artists.localizedCaseInsensitiveContains(artist.name) })?.coverURL
                let names = synologyAliases(for: key, existing: [artist.name])
                indexes[key] = entries.count
                entries.append(SynologySearchEntry(id: "artist-\(key)", names: names, subtitle: "群晖音乐库歌手", coverURL: cover))
            }
        }
        return entries
    }

    private func makeSynologyAlbumEntries(_ albums: [Album], songs: [Song]) -> [SynologySearchEntry] {
        var entries: [SynologySearchEntry] = []
        var indexes: [String: Int] = [:]
        for album in albums {
            let key = synologyCanonicalName(album.name + "|" + album.artistName)
            guard !key.isEmpty else { continue }
            let cover = album.coverURL ?? songs.first(where: { $0.album == album.name })?.coverURL
            if let index = indexes[key] {
                if !entries[index].names.contains(album.name) {
                    entries[index] = SynologySearchEntry(id: entries[index].id, names: entries[index].names + [album.name], subtitle: entries[index].subtitle, coverURL: entries[index].coverURL ?? cover)
                }
            } else {
                indexes[key] = entries.count
                entries.append(SynologySearchEntry(id: "album-\(key)", names: [album.name], subtitle: album.artistName, coverURL: cover))
            }
        }
        return entries
    }

    private func synologyCanonicalName(_ value: String) -> String {
        let simplified = value.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? value
        return simplified
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private func synologyAliases(for key: String, existing: [String]) -> [String] {
        return existing
    }


    /// 搜索页只请求当前选中的分类。之前每次输入都会同时请求歌曲、歌手、专辑三套接口，
    /// 结果页实际上只显示其中一类，造成了明显的网络和 UI 重建开销。
    private func fetchSelectedSearchResult(provider: SearchProvider, type: SearchResultType, keyword: String) async throws -> (songs: [Song], artists: [Artist], albums: [Album]) {
        switch (provider, type) {
        case (.netease, .song):
            return (try await NetEaseAPI.shared.search(keyword: keyword, limit: 40), [], [])
        case (.netease, .artist):
            return ([], try await NetEaseAPI.shared.searchArtists(keyword: keyword), [])
        case (.netease, .album):
            return ([], [], try await NetEaseAPI.shared.searchAlbums(keyword: keyword))
        case (.qq, .song):
            return (try await QQMusicAPI.shared.searchSongs(keyword: keyword), [], [])
        case (.qq, .artist):
            return ([], try await QQMusicAPI.shared.searchArtists(keyword: keyword), [])
        case (.qq, .album):
            return ([], [], try await QQMusicAPI.shared.searchAlbums(keyword: keyword))
        case (.kugou, .song):
            return (try await KugouMusicAPI.shared.searchSongs(keyword: keyword, limit: 40), [], [])
        case (.kugou, .artist):
            return ([], try await KugouMusicAPI.shared.searchArtists(keyword: keyword), [])
        case (.kugou, .album):
            return ([], [], try await KugouMusicAPI.shared.searchAlbums(keyword: keyword))
        case (.subsonic, .song):
            return ((try await SubsonicAPI.shared.searchAllVariants(keyword: keyword, limit: 40)).songs, [], [])
        case (.subsonic, .artist):
            return ([], (try await SubsonicAPI.shared.searchAllVariants(keyword: keyword, limit: 40)).artists, [])
        case (.subsonic, .album):
            return ([], [], (try await SubsonicAPI.shared.searchAllVariants(keyword: keyword, limit: 40)).albums)
        case (.jellyfin, .song):
            return ((try await JellyfinAPI.shared.searchAllVariants(keyword: keyword, limit: 40)).songs, [], [])
        case (.jellyfin, .artist):
            return ([], (try await JellyfinAPI.shared.searchAllVariants(keyword: keyword, limit: 40)).artists, [])
        case (.jellyfin, .album):
            return ([], [], (try await JellyfinAPI.shared.searchAllVariants(keyword: keyword, limit: 40)).albums)
        case (.webdav, .song):
            return ((try await WebDAVAPI.shared.searchAllVariants(keyword: keyword, limit: 40)).songs, [], [])
        case (.webdav, .artist):
            return ([], (try await WebDAVAPI.shared.searchAllVariants(keyword: keyword, limit: 40)).artists, [])
        case (.webdav, .album):
            return ([], [], (try await WebDAVAPI.shared.searchAllVariants(keyword: keyword, limit: 40)).albums)
        case (.synology, _), (_, .playlist):
            return ([], [], [])
        }
    }

    private func startSearch(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // 所有搜索结果必须对应当前可见输入；延迟 NAS/旧 UI 任务不能反向覆盖新关键词。
        guard keyword.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
        let selectedProvider = provider
        let selectedType = resultType
        let selectedAggregate = aggregateSearch
        let selectedProviders = selectedAggregate ? searchProviders : [selectedProvider]
        let providerKey = selectedProviders.map(\.rawValue).joined(separator: ",")
        let requestKey = "\(trimmed.lowercased())|\(selectedAggregate)|\(providerKey)|\(selectedType.rawValue)"
        // 同一请求仍在执行时直接合并。真机日志曾显示同一关键词在一秒内被
        // 索引通知等事件触发 3～4 次，这是综合结果反复闪烁的直接原因。
        guard activeSearchKey != requestKey else {
            ATMusicLogger.shared.log("合并重复搜索：\(requestKey)", level: .debug)
            return
        }
        searchTask?.cancel()
        searchGeneration &+= 1
        let generation = searchGeneration
        activeSearchKey = requestKey
        searchTask = Task {
            await MainActor.run {
                searching = true
                errorMessage = nil
            }
            ATMusicLogger.shared.log("搜索：\(selectedProvider.rawValue) [\(selectedType.rawValue)] \(trimmed)", level: .info)
            defer {
                Task { @MainActor in
                    guard searchGeneration == generation else { return }
                    if activeSearchKey == requestKey { activeSearchKey = nil }
                    if !Task.isCancelled { searching = false }
                }
            }
            if selectedAggregate {
                let localPlaylists = await MainActor.run {
                    auth.playlists.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
                }
                let aggregate = await AggregatedSearchService.shared.searchStreaming(keyword: trimmed, providers: selectedProviders) { partial in
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard aggregateSearch, searchGeneration == generation else { return }
                        if aggregateOverview {
                            // 流式响应：最先给结果的直接显示，后续平台给结果的往前插队刷新快照
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                captureOverviewSnapshot(from: partial, localPlaylists: localPlaylists)
                            }
                        } else {
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                switch resultType {
                                case .song:
                                    songResults = stableAppend(
                                        current: songResults,
                                        incoming: partial.songs,
                                        identity: { $0.identityKey }
                                    )
                                case .artist:
                                    artistResults = stableAppend(
                                        current: artistResults,
                                        incoming: partial.artists,
                                        identity: { "\($0.source.rawValue)|\($0.id)" }
                                    )
                                case .album:
                                    albumResults = stableAppend(
                                        current: albumResults,
                                        incoming: partial.albums,
                                        identity: { "\($0.source.rawValue)|\($0.id)" }
                                    )
                                case .playlist:
                                    playlistResults = stableAppend(
                                        current: playlistResults,
                                        incoming: localPlaylists + partial.playlists,
                                        identity: { $0.identityKey }
                                    )
                                }
                            }
                        }
                        // 已有任一音源返回结果时，先清除“全部音源失败”的错误状态。
                        if errorMessage != nil,
                           (!partial.songs.isEmpty || !partial.artists.isEmpty || !partial.albums.isEmpty || !partial.playlists.isEmpty) {
                            errorMessage = nil
                        }
                    }
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard aggregateSearch, searchGeneration == generation else { return }
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        // 综合页只提交一个完整快照，避免四组结果的连续写入
                        // 让整页在一帧内反复拆除/重建。若用户此时已进入分类，
                        // 只更新当前可见的那一组结果。
                        if !aggregateOverview {
                            switch resultType {
                            case .song: songResults = aggregate.songs
                            case .artist: artistResults = aggregate.artists
                            case .album: albumResults = aggregate.albums
                            case .playlist: playlistResults = localPlaylists + aggregate.playlists
                            }
                        }
                        captureOverviewSnapshot(from: aggregate, localPlaylists: localPlaylists)
                    }
                    errorMessage = aggregate.songs.isEmpty && aggregate.artists.isEmpty && aggregate.albums.isEmpty && aggregate.playlists.isEmpty && !aggregate.failedProviders.isEmpty
                        ? "当前音源暂时不可用，请稍后重试" : nil
                    if !aggregate.songs.isEmpty { ATMusicHaptics.success() }
                }
                ATMusicLogger.shared.log("聚合搜索完成：\(trimmed) 音源=\(selectedProviders.count) 歌曲\(aggregate.songs.count)/歌手\(aggregate.artists.count)/专辑\(aggregate.albums.count)/歌单\(aggregate.playlists.count)", level: .info)
                return
            }
            if selectedType == .playlist, selectedProvider != .synology {
                let remote: [Playlist]
                switch selectedProvider {
                case .netease:
                    remote = (try? await NetEaseAPI.shared.searchPlaylists(keyword: trimmed, limit: 40)) ?? []
                case .qq:
                    remote = (try? await QQMusicAPI.shared.searchPlaylists(keyword: trimmed, limit: 40)) ?? []
                case .kugou:
                    remote = (try? await KugouMusicAPI.shared.searchPlaylists(keyword: trimmed, limit: 40)) ?? []
                case .synology:
                    remote = []
                case .subsonic:
                    remote = (try? await SubsonicAPI.shared.allPlaylists())?.filter { $0.name.localizedCaseInsensitiveContains(trimmed) } ?? []
                case .jellyfin:
                    remote = (try? await JellyfinAPI.shared.allPlaylists())?.filter { $0.name.localizedCaseInsensitiveContains(trimmed) } ?? []
                case .webdav:
                    remote = (try? await WebDAVAPI.shared.allPlaylists())?.filter { $0.name.localizedCaseInsensitiveContains(trimmed) } ?? []
                }
                let local = await MainActor.run {
                    auth.playlists.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard provider == selectedProvider, resultType == selectedType else { return }
                    playlistResults = local + remote
                }
                return
            }
            if selectedProvider != .synology {
                do {
                    let result = try await fetchSelectedSearchResult(provider: selectedProvider, type: selectedType, keyword: trimmed)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard provider == selectedProvider else { return }
                        songResults = result.songs
                        artistResults = result.artists
                        albumResults = result.albums
                        errorMessage = nil
                    }
                    ATMusicLogger.shared.log("搜索完成：\(selectedProvider.rawValue) 全部分类 \(trimmed) 结果=歌曲\(result.songs.count)/歌手\(result.artists.count)/专辑\(result.albums.count)", level: .info)
                } catch {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard provider == selectedProvider else { return }
                        errorMessage = error.localizedDescription
                    }
                }
                return
            }
            do {
                switch (selectedProvider, selectedType) {
                case (.netease, .song):
                    let songs = try await NetEaseAPI.shared.search(keyword: trimmed, limit: 40)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard provider == selectedProvider, resultType == selectedType else { return }
                        songResults = songs
                        if !songs.isEmpty { ATMusicHaptics.success() }
                    }
                case (.netease, .artist):
                    let artists = try await NetEaseAPI.shared.searchArtists(keyword: trimmed)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard provider == selectedProvider, resultType == selectedType else { return }
                        artistResults = artists
                    }
                case (.netease, .album):
                    let albums = try await NetEaseAPI.shared.searchAlbums(keyword: trimmed)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard provider == selectedProvider, resultType == selectedType else { return }
                        albumResults = albums
                    }
                case (.qq, .song):
                    let songs = try await QQMusicAPI.shared.searchSongs(keyword: trimmed)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard provider == selectedProvider, resultType == selectedType else { return }
                        songResults = songs
                        if !songs.isEmpty { ATMusicHaptics.success() }
                    }
                case (.qq, .artist):
                    let artists = try await QQMusicAPI.shared.searchArtists(keyword: trimmed)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard provider == selectedProvider, resultType == selectedType else { return }
                        artistResults = artists
                    }
                case (.qq, .album):
                    let albums = try await QQMusicAPI.shared.searchAlbums(keyword: trimmed)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard provider == selectedProvider, resultType == selectedType else { return }
                        albumResults = albums
                    }
                case (.kugou, .song):
                    let songs = try await KugouMusicAPI.shared.searchSongs(keyword: trimmed, limit: 40)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard provider == selectedProvider, resultType == selectedType else { return }
                        songResults = songs
                        if !songs.isEmpty { ATMusicHaptics.success() }
                    }
                case (.kugou, .artist):
                    let artists = try await KugouMusicAPI.shared.searchArtists(keyword: trimmed)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard provider == selectedProvider, resultType == selectedType else { return }
                        artistResults = artists
                    }
                case (.kugou, .album):
                    let albums = try await KugouMusicAPI.shared.searchAlbums(keyword: trimmed)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard provider == selectedProvider, resultType == selectedType else { return }
                        albumResults = albums
                    }
                case (.synology, .song), (.synology, .artist), (.synology, .album):
                    let result = try await SynologyAPI.shared.searchAllVariants(keyword: trimmed, limit: 200)
                    let songs = result.songs
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard provider == selectedProvider, resultType == selectedType else { return }
                        songResults = songs
                        synologySearchSongs = songs
                        synologyArtistEntries = makeSynologyArtistEntries(result.artists, songs: songs)
                        synologyAlbumEntries = makeSynologyAlbumEntries(result.albums, songs: songs)
                        let resolvedAlbums = result.albums.map { album -> Album in
                            let cover = album.coverURL
                                ?? songs.first(where: { $0.album.localizedCaseInsensitiveCompare(album.name) == .orderedSame })?.coverURL
                                ?? songs.first(where: { $0.album.localizedStandardContains(album.name) || album.name.localizedStandardContains($0.album) })?.coverURL
                            return Album(
                                id: album.id,
                                name: album.name,
                                artistName: album.artistName,
                                coverURL: cover,
                                source: .synology,
                                trackCount: album.trackCount
                            )
                        }
                        albumResults = resolvedAlbums
                        if !songs.isEmpty { ATMusicHaptics.success() }
                    }
                case (.synology, .playlist):
                    let playlists = try await SynologyAPI.shared.allPlaylists()
                    let matches = playlists.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard provider == selectedProvider, resultType == selectedType else { return }
                        playlistResults = matches
                    }
                case (.subsonic, _), (.jellyfin, _), (.webdav, _):
                    // 新 NAS 走上面 fetchSelected/歌单分支，不进这段群晖专属搜索块。
                    break
                case (.netease, .playlist), (.qq, .playlist), (.kugou, .playlist):
                    break
                }
                let count = await MainActor.run {
                    switch selectedType {
                    case .song: return songResults.count
                    case .artist: return selectedProvider == .synology ? synologyArtistEntries.count : artistResults.count
                    case .album: return selectedProvider == .synology ? synologyAlbumEntries.count : albumResults.count
                    case .playlist: return playlistResults.count
                    }
                }
                ATMusicLogger.shared.log("搜索完成：\(selectedProvider.rawValue) [\(selectedType.rawValue)] \(trimmed) 结果=\(count)", level: .info)
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard provider == selectedProvider else { return }
                    errorMessage = error.localizedDescription
                }
                ATMusicLogger.shared.log("搜索失败：\(selectedProvider.rawValue) \(trimmed) - \(error.localizedDescription)", level: .error)
            }
        }
        await searchTask?.value
    }
}

/// 专辑详情页：点击搜索结果直接进入专辑内容，不再把专辑名当作歌曲关键词重新搜索。
struct AlbumDetailView: View {
    let album: Album
    var isModal: Bool = true
    @EnvironmentObject private var player: PlayerManager
    @ObservedObject private var theme = ThemeStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var tracks: [Song] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showArtistHome = false
    @State private var isBatchDownloading = false
    @State private var isBatchUploading = false
    @State private var isMultiSelecting = false
    @State private var selectedSongKeys: Set<String> = []
    @State private var dragStartIndex: Int? = nil
    @State private var initialSelectedKeysOnDrag: Set<String>? = nil
    @State private var dragTargetSelected = true
    @State private var lastDragIndex: Int? = nil
    @State private var showBatchAddToPlaylist = false
    @State private var sortedTracks: [Song] = []
    @State private var discGroups: [(disc: Int, songs: [Song])] = []

    private func recomputeSortedTracksAndDiscGroups() {
        let sorted = tracks.sorted {
            if $0.discNumber != $1.discNumber {
                return $0.discNumber < $1.discNumber
            }
            if $0.trackNumber != $1.trackNumber {
                return $0.trackNumber < $1.trackNumber
            }
            return $0.id < $1.id
        }
        sortedTracks = sorted

        let explicit = Dictionary(grouping: sorted, by: { $0.discNumber })
        if explicit.keys.count > 1 {
            discGroups = explicit.keys.sorted().map { ($0, explicit[$0]!) }
            return
        }
        var groups: [(disc: Int, songs: [Song])] = []
        var currentDisc = 1
        var currentSongs: [Song] = []
        var prevTrack = 0
        for song in sorted {
            let trk = song.trackNumber
            if trk == 1 && prevTrack >= 1 && !currentSongs.isEmpty {
                groups.append((disc: currentDisc, songs: currentSongs))
                currentDisc += 1
                currentSongs = [song]
                prevTrack = 1
            } else {
                currentSongs.append(song)
                if trk > 0 { prevTrack = trk }
            }
        }
        if !currentSongs.isEmpty {
            groups.append((disc: currentDisc, songs: currentSongs))
        }
        if groups.count > 1 {
            discGroups = groups
            return
        }
        discGroups = explicit.keys.sorted().map { ($0, explicit[$0]!) }
    }

    private var selectedSongs: [Song] {
        sortedTracks.filter { selectedSongKeys.contains($0.identityKey) }
    }

    private func toggleSelection(_ song: Song) {
        if selectedSongKeys.contains(song.identityKey) {
            selectedSongKeys.remove(song.identityKey)
        } else {
            selectedSongKeys.insert(song.identityKey)
        }
    }

    private func handleDragChange(startIndex: Int, deltaRows: Int) {
        let keys = sortedTracks.map(\.identityKey)
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
    private func albumSongRow(song: Song, index: Int, playbackIndex: Int, trackNumber: Int) -> some View {
        SongCell(
            song: song,
            glassRow: true,
            playbackIndex: playbackIndex,
            trackNumber: trackNumber,
            onTap: {
                player.play(songs: sortedTracks, startAt: playbackIndex)
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

    @MainActor
    private func batchDownloadAlbum() {
        guard !sortedTracks.isEmpty, !isBatchDownloading else { return }
        isBatchDownloading = true
        ATMusicHaptics.medium()
        let quality: DownloadQuality
        let downloadQualityRaw = UserDefaults.standard.string(forKey: ThirdPartyAudioQuality.downloadStorageKey) ?? ThirdPartyAudioQuality.kb320.rawValue
        if UserDefaults.standard.object(forKey: ThirdPartyAudioQuality.downloadStorageKey) == nil {
            quality = ThirdPartyAudioQuality.current
        } else {
            quality = DownloadQuality(sourceValue: downloadQualityRaw) ?? ThirdPartyAudioQuality.current
        }
        DownloadManager.shared.startBatchDownload(songs: sortedTracks, quality: quality)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            isBatchDownloading = false
        }
    }

    @MainActor
    private func batchUploadAlbumToNAS() {
        guard !sortedTracks.isEmpty, !isBatchUploading else { return }
        isBatchUploading = true
        ATMusicHaptics.medium()
        DownloadManager.shared.startBatchUploadToNAS(songs: sortedTracks)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            isBatchUploading = false
        }
    }

    private var albumAccentColor: Color {
        switch album.source {
        case .synology, .subsonic, .jellyfin, .webdav: return Color.atmusicAmber
        case .netease: return Color.red.opacity(0.9)
        case .qq: return Color.green.opacity(0.9)
        case .kugou: return Color.blue.opacity(0.9)
        default: return theme.accent.highlight
        }
    }

    var body: some View {
        ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
                if isLoading {
                    LoadingStateView()
                } else if let errorMessage {
                    ErrorStateView(message: errorMessage) { Task { await load() } }
                } else if DeviceLayoutHelper.isIPadRegular(horizontalSizeClass) {
                    iPadAlbumLayout
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            albumHeaderSection
                                .padding(.horizontal, 16)
                                .padding(.top, 10)

                            // 歌曲列表区域：多 CD 分盘分栏或单 CD 紧凑平铺
                            if discGroups.count > 1 {
                                ForEach(discGroups, id: \.disc) { group in
                                    VStack(alignment: .leading, spacing: 8) {
                                        discSectionHeader(discNumber: group.disc, songs: group.songs)
                                        ForEach(Array(group.songs.enumerated()), id: \.element.identityKey) { index, song in
                                            let displayNo = (song.trackNumber >= 1 && song.trackNumber <= group.songs.count) ? song.trackNumber : (index + 1)
                                            let globalIndex = sortedTracks.firstIndex(of: song) ?? 0
                                            albumSongRow(song: song, index: globalIndex, playbackIndex: globalIndex, trackNumber: displayNo)
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                }
                            } else {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(Array(sortedTracks.enumerated()), id: \.element.identityKey) { index, song in
                                        let displayNo = (song.trackNumber >= 1 && song.trackNumber <= sortedTracks.count) ? song.trackNumber : (index + 1)
                                        albumSongRow(song: song, index: index, playbackIndex: index, trackNumber: displayNo)
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                        .padding(.bottom, 40)
                    }
                    .atmusicScrollIndicatorsHidden()
                }

                if isMultiSelecting && !selectedSongKeys.isEmpty {
                    VStack {
                        Spacer()
                        UniversalBatchActionBar(
                            selectedCount: selectedSongKeys.count,
                            totalCount: sortedTracks.count,
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
                                    let quality: DownloadQuality
                                    let downloadQualityRaw = UserDefaults.standard.string(forKey: ThirdPartyAudioQuality.downloadStorageKey) ?? ThirdPartyAudioQuality.kb320.rawValue
                                    if UserDefaults.standard.object(forKey: ThirdPartyAudioQuality.downloadStorageKey) == nil {
                                        quality = ThirdPartyAudioQuality.current
                                    } else {
                                        quality = DownloadQuality(sourceValue: downloadQualityRaw) ?? ThirdPartyAudioQuality.current
                                    }
                                    DownloadManager.shared.startBatchDownload(songs: songs, quality: quality)
                                    isMultiSelecting = false
                                    selectedSongKeys.removeAll()
                                },
                                BatchActionItem(id: "archive", title: "归档NAS", systemImage: "externaldrive.badge.plus", tint: Color.atmusicAmber, disabled: !SynologyAPI.shared.isLoggedIn || album.source == .synology) {
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
            .navigationTitle(isMultiSelecting ? (selectedSongKeys.isEmpty ? "选择歌曲" : "已选 \(selectedSongKeys.count) 首") : album.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if isMultiSelecting {
                        Button(selectedSongKeys.count == sortedTracks.count && !sortedTracks.isEmpty ? "取消全选" : "全选") {
                            ATMusicHaptics.tap()
                            if selectedSongKeys.count == sortedTracks.count {
                                selectedSongKeys.removeAll()
                            } else {
                                selectedSongKeys = Set(sortedTracks.map(\.identityKey))
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
                    } else {
                        Menu {
                            Button {
                                ATMusicHaptics.select()
                                isMultiSelecting = true
                            } label: {
                                Label("多选歌曲", systemImage: "checklist")
                            }
                            .disabled(sortedTracks.isEmpty)

                            Button {
                                batchDownloadAlbum()
                            } label: {
                                Label(isBatchDownloading ? "正在加入下载..." : "下载全专歌曲", systemImage: "arrow.down.circle")
                            }
                            .disabled(sortedTracks.isEmpty || isBatchDownloading)

                            if SynologyAPI.shared.isLoggedIn && album.source != .synology {
                                Button {
                                    batchUploadAlbumToNAS()
                                } label: {
                                    Label(isBatchUploading ? "正在加入归档..." : "全专归档至群晖 NAS", systemImage: "externaldrive.badge.plus")
                                }
                                .disabled(sortedTracks.isEmpty || isBatchUploading)
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("更多操作")

                        if isModal {
                            Button {
                                dismiss()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(Color.atmusicComment.opacity(0.8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .sheet(isPresented: $showBatchAddToPlaylist) {
                AddToPlaylistSheet(songs: selectedSongs)
                    .environmentObject(theme)
            }
        .task { await load() }
        .onChange(of: tracks) { _ in recomputeSortedTracksAndDiscGroups() }
        .sheet(isPresented: $showArtistHome) {
            ArtistHomeSheet(artistName: album.artistName, artistSource: album.source)
                .environmentObject(player)
                .environmentObject(theme)
        }
        .onReceive(NotificationCenter.default.publisher(for: .atmusicSongMetadataDidUpdate)) { note in
            if let updated = note.object as? Song {
                for i in tracks.indices {
                    let item = tracks[i]
                    if item.identityKey == updated.identityKey || LocalLibraryStore.isMatchingSong(item, updated) || (item.source == updated.source && item.id == updated.id && item.id != 0) {
                        tracks[i] = updated
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .atmusicSynologyMetadataDidUpdate)) { note in
            if let updated = note.object as? Song {
                for i in tracks.indices {
                    let item = tracks[i]
                    if item.identityKey == updated.identityKey || LocalLibraryStore.isMatchingSong(item, updated) || (item.source == updated.source && item.id == updated.id && item.id != 0) {
                        tracks[i] = updated
                    }
                }
            }
        }
    }

    // MARK: - iPad 宽屏两栏全景专辑布局（对标 iPadOS Apple Music 专辑页规范）

    private var iPadAlbumLayout: some View {
        GeometryReader { proxy in
            let availableWidth = proxy.size.width
            if availableWidth >= 740 {
                wideAlbumLayout(availableWidth: availableWidth)
            } else {
                compactAlbumLayout(availableWidth: availableWidth)
            }
        }
    }

    private func wideAlbumLayout(availableWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 28) {
            // 左栏：240pt 大封面 + 专辑属性与 NAS 规格看板 + 快捷播控
            VStack(alignment: .leading, spacing: 18) {
                CoverImage(url: album.coverURL, size: 220, cornerRadius: 22)
                    .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 8)

                VStack(alignment: .leading, spacing: 8) {
                    sourceBadge

                    Text(album.name)
                        .font(ATMusicFont.appFont(22, .bold))
                        .foregroundStyle(Color.atmusicLabel)
                        .lineLimit(3)

                    Button {
                        guard !album.artistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        ATMusicHaptics.tap()
                        showArtistHome = true
                    } label: {
                        HStack(spacing: 4) {
                            Text(album.artistName.isEmpty ? "未知歌手" : album.artistName)
                            if !album.artistName.isEmpty {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .bold))
                            }
                        }
                        .font(ATMusicFont.appFont(14, .medium))
                        .foregroundStyle(album.artistName.isEmpty ? Color.atmusicComment : Color.atmusicAmber)
                    }
                    .buttonStyle(.plain)

                    HStack(spacing: 8) {
                        Text(atmusicSongCountText(sortedTracks.count))
                        if discGroups.count > 1 {
                            Text("· \(discGroups.count) CD 大碟")
                                .font(ATMusicFont.appFont(13, .semibold))
                                .foregroundStyle(Color.atmusicAmber)
                        }
                    }
                    .font(ATMusicFont.appFont(13))
                    .foregroundStyle(Color.atmusicComment)
                }

                if album.source == .synology {
                    nasMasterSpecBar
                }

                if !sortedTracks.isEmpty {
                    HStack(spacing: 12) {
                        GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                            player.play(songs: sortedTracks, startAt: 0)
                        }
                        GlassIconButton(systemName: "shuffle", size: 44, active: false) {
                            guard !sortedTracks.isEmpty else { return }
                            player.play(songs: sortedTracks.shuffled(), startAt: 0)
                        }
                        if discGroups.count > 1 {
                            GlassButton(title: "顺序播放", systemName: "arrow.triangle.swap") {
                                player.play(songs: sortedTracks, startAt: 0)
                            }
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(width: 240)
            .padding(.leading, 28)
            .padding(.top, 24)

            // 右栏：自适应网格或流畅滚动歌曲列表
            let rightWidth = availableWidth - 240 - 28 - 28 - 28
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if discGroups.count > 1 {
                        ForEach(discGroups, id: \.disc) { group in
                            VStack(alignment: .leading, spacing: 10) {
                                discSectionHeader(discNumber: group.disc, songs: group.songs)

                                LazyVGrid(columns: DeviceLayoutHelper.songListColumns(forAvailableWidth: rightWidth, minWidth: 280, spacing: 14), spacing: 8) {
                                    ForEach(Array(group.songs.enumerated()), id: \.element.identityKey) { index, song in
                                        let displayNo = (song.trackNumber >= 1 && song.trackNumber <= group.songs.count) ? song.trackNumber : (index + 1)
                                        let globalIndex = sortedTracks.firstIndex(of: song) ?? 0
                                        albumSongRow(song: song, index: globalIndex, playbackIndex: globalIndex, trackNumber: displayNo)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background {
                                            RoundedRectangle(cornerRadius: 12)
                                                .fill(Color.primary.opacity(0.03))
                                        }
                                    }
                                }
                            }
                            .padding(.bottom, 12)
                        }
                    } else {
                        HStack {
                            Text("歌曲列表 (\(sortedTracks.count))")
                                .font(ATMusicFont.appFont(16, .bold))
                                .foregroundStyle(Color.atmusicLabel)
                            Spacer()
                        }
                        .padding(.top, 4)

                        LazyVGrid(columns: DeviceLayoutHelper.songListColumns(forAvailableWidth: rightWidth, minWidth: 280, spacing: 14), spacing: 8) {
                            ForEach(Array(sortedTracks.enumerated()), id: \.element.identityKey) { index, song in
                                let displayNo = (song.trackNumber >= 1 && song.trackNumber <= sortedTracks.count) ? song.trackNumber : (index + 1)
                                albumSongRow(song: song, index: index, playbackIndex: index, trackNumber: displayNo)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background {
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.primary.opacity(0.03))
                                }
                            }
                        }
                    }
                }
                .padding(.trailing, 28)
                .padding(.bottom, 120)
            }
        }
    }

    private func compactAlbumLayout(availableWidth: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // 顶部横向摘要横幅
                HStack(alignment: .top, spacing: 16) {
                    CoverImage(url: album.coverURL, size: 130, cornerRadius: 16)
                        .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 5)

                    VStack(alignment: .leading, spacing: 6) {
                        sourceBadge
                        Text(album.name)
                            .font(ATMusicFont.appFont(18, .bold))
                            .foregroundStyle(Color.atmusicLabel)
                            .lineLimit(2)

                        Text(album.artistName.isEmpty ? "未知歌手" : album.artistName)
                            .font(ATMusicFont.appFont(13, .medium))
                            .foregroundStyle(Color.atmusicAmber)

                        Text(atmusicSongCountText(sortedTracks.count))
                            .font(ATMusicFont.appFont(11))
                            .foregroundStyle(Color.atmusicComment)

                        Spacer(minLength: 4)

                        HStack(spacing: 10) {
                            GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                                player.play(songs: sortedTracks, startAt: 0)
                            }
                            GlassIconButton(systemName: "shuffle", size: 38, active: false) {
                                guard !sortedTracks.isEmpty else { return }
                                player.play(songs: sortedTracks.shuffled(), startAt: 0)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                if album.source == .synology {
                    nasMasterSpecBar.padding(.horizontal, 20)
                }

                HStack {
                    Text("歌曲列表 (\(sortedTracks.count))")
                        .font(ATMusicFont.appFont(16, .bold))
                        .foregroundStyle(Color.atmusicLabel)
                    Spacer()
                }
                .padding(.horizontal, 20)

                LazyVGrid(columns: DeviceLayoutHelper.songListColumns(forAvailableWidth: availableWidth - 40, minWidth: 280, spacing: 12), spacing: 6) {
                    ForEach(Array(sortedTracks.enumerated()), id: \.element.identityKey) { index, song in
                        let displayNo = (song.trackNumber >= 1 && song.trackNumber <= sortedTracks.count) ? song.trackNumber : (index + 1)
                        albumSongRow(song: song, index: index, playbackIndex: index, trackNumber: displayNo)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.primary.opacity(0.03))
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 120)
            }
        }
    }

    // MARK: - 头部专辑看板与徽标

    private var albumHeaderSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                CoverImage(url: album.coverURL, size: 100, cornerRadius: 18)
                VStack(alignment: .leading, spacing: 6) {
                    // 音源专属属性胶囊（平台 vs NAS 无损库清晰区分）
                    sourceBadge

                    Text(album.name)
                        .font(ATMusicFont.appFont(20, .bold))
                        .foregroundStyle(Color.atmusicLabel)
                        .lineLimit(2)

                    Button {
                        guard !album.artistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        ATMusicHaptics.tap()
                        showArtistHome = true
                    } label: {
                        HStack(spacing: 4) {
                            Text(album.artistName.isEmpty ? "未知歌手" : album.artistName)
                            if !album.artistName.isEmpty {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .bold))
                            }
                        }
                        .font(ATMusicFont.appFont(13, .medium))
                        .foregroundStyle(album.artistName.isEmpty ? Color.atmusicComment : Color.atmusicAmber)
                    }
                    .buttonStyle(.plain)

                    HStack(spacing: 8) {
                        Text(atmusicSongCountText(sortedTracks.count))
                        if discGroups.count > 1 {
                            Text("· \(discGroups.count) CD 大碟")
                                .font(ATMusicFont.appFont(12, .semibold))
                                .foregroundStyle(Color.atmusicAmber)
                        }
                    }
                    .font(ATMusicFont.appFont(12))
                    .foregroundStyle(Color.atmusicComment)
                }
                Spacer(minLength: 0)
            }

            // NAS 专属高解析无损库看板
            if album.source == .synology {
                nasMasterSpecBar
            }

            if !sortedTracks.isEmpty {
                HStack(spacing: 12) {
                    GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                        player.play(songs: sortedTracks, startAt: 0)
                    }
                    .frame(maxWidth: .infinity)

                    GlassButton(title: "随机播放", systemName: "shuffle", prominent: false) {
                        guard !sortedTracks.isEmpty else { return }
                        player.play(songs: sortedTracks.shuffled(), startAt: 0)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// 音源标识胶囊（群晖 NAS 专属琥珀流光徽标 vs 官方云音源）
    @ViewBuilder
    private var sourceBadge: some View {
        if album.source == .synology {
            HStack(spacing: 4) {
                Image(systemName: "externaldrive.fill.badge.checkmark")
                    .font(.system(size: 10, weight: .bold))
                Text("群晖 NAS · 私有无损库")
                    .font(ATMusicFont.appFont(11, .bold))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Color.atmusicAmber.opacity(0.18))
            .foregroundStyle(Color.atmusicAmber)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color.atmusicAmber.opacity(0.35), lineWidth: 0.8)
            )
        } else if album.source == .netease {
            HStack(spacing: 4) {
                Image(systemName: "cloud.fill")
                    .font(.system(size: 10))
                Text("网易云音乐 · 原生接口")
                    .font(ATMusicFont.appFont(11, .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(Color.red.opacity(0.12))
            .foregroundStyle(Color.red.opacity(0.9))
            .clipShape(Capsule())
        } else if album.source == .qq {
            HStack(spacing: 4) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 10))
                Text("QQ 音乐 · 官方音源")
                    .font(ATMusicFont.appFont(11, .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(Color.green.opacity(0.12))
            .foregroundStyle(Color.green.opacity(0.9))
            .clipShape(Capsule())
        } else {
            HStack(spacing: 4) {
                Image(systemName: "music.note")
                    .font(.system(size: 10))
                Text(album.source.rawValue.uppercased())
                    .font(ATMusicFont.appFont(11, .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(Color.atmusicLabel.opacity(0.08))
            .foregroundStyle(Color.atmusicSecondary)
            .clipShape(Capsule())
        }
    }

    /// 群晖 NAS 高保真参数看板
    private var nasMasterSpecBar: some View {
        HStack(spacing: 12) {
            Label("本地局域网直连", systemImage: "bolt.horizontal.fill")
            Spacer()
            Label("无损原盘音质", systemImage: "waveform")
            Spacer()
            Label("支持多音轨/分盘", systemImage: "opticaldisc.fill")
        }
        .font(ATMusicFont.appFont(11, .medium))
        .foregroundStyle(Color.atmusicComment)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.atmusicCard.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.atmusicLabel.opacity(0.12), lineWidth: 0.5)
                )
        )
    }

    /// 多 CD 盘片分栏标头与精美分割符
    private func discSectionHeader(discNumber: Int, songs: [Song]) -> some View {
        VStack(spacing: 8) {
            if discNumber > 1 {
                HStack(spacing: 12) {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [albumAccentColor.opacity(0.0), albumAccentColor.opacity(0.4)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(height: 1)
                    
                    HStack(spacing: 6) {
                        Image(systemName: "opticaldisc")
                            .font(.system(size: 11, weight: .bold))
                        Text("分盘分割")
                            .font(ATMusicFont.appFont(10, .semibold))
                    }
                    .foregroundStyle(albumAccentColor.opacity(0.85))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(albumAccentColor.opacity(0.1))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule().strokeBorder(albumAccentColor.opacity(0.25), lineWidth: 0.8)
                    )
                    
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [albumAccentColor.opacity(0.4), albumAccentColor.opacity(0.0)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(height: 1)
                }
                .padding(.top, 14)
                .padding(.bottom, 6)
            }

            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "opticaldisc.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(albumAccentColor)
                    Text("CD \(discNumber)")
                        .font(ATMusicFont.appFont(14, .bold))
                        .foregroundStyle(Color.atmusicLabel)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(albumAccentColor.opacity(0.12))
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(albumAccentColor.opacity(0.25), lineWidth: 0.8)
                )

                Spacer()

                Text("\(songs.count) 首歌曲")
                    .font(ATMusicFont.appFont(12))
                    .foregroundStyle(Color.atmusicComment)

                Button {
                    if let firstIndex = sortedTracks.firstIndex(where: { $0.identityKey == songs.first?.identityKey }) {
                        ATMusicHaptics.tap()
                        player.play(songs: sortedTracks, startAt: firstIndex)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "play.circle.fill")
                        Text("播放本盘")
                    }
                    .font(ATMusicFont.appFont(12, .semibold))
                    .foregroundStyle(albumAccentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - 数据加载流程（NAS 专属独立纯净库 vs 平台原生接口）

    private func load() async {
        let cache = DetailSongsCache.shared
        let cacheKey = "album-\(album.source.rawValue)-\(album.id)"
        if let cached = cache.cachedSongs(for: cacheKey) {
            await MainActor.run {
                tracks = cached.songs
                isLoading = false
                errorMessage = nil
            }
            if cache.isFresh(cached) {
                return
            }
        }
        await MainActor.run {
            if tracks.isEmpty {
                isLoading = true
            }
            errorMessage = nil
        }

        let result: [Song]
        switch album.source {
        case .synology:
            // 纯净隔离：仅读取 NAS 内专辑歌曲，100% 杜绝流媒体混杂
            let direct = await SynologyAPI.shared.albumSongs(albumName: album.name, artistName: album.artistName)
            if !direct.isEmpty {
                result = direct
            } else {
                let lib = SynologyAPI.shared.cachedLibrarySongs
                let trimmedAlbum = album.name.trimmingCharacters(in: .whitespacesAndNewlines)
                result = lib.filter { song in
                    guard song.source == .synology else { return false }
                    let sAlbum = song.album.trimmingCharacters(in: .whitespacesAndNewlines)
                    return sAlbum.localizedCaseInsensitiveCompare(trimmedAlbum) == .orderedSame ||
                           sAlbum.localizedStandardContains(trimmedAlbum) ||
                           trimmedAlbum.localizedStandardContains(sAlbum)
                }.sorted {
                    if $0.discNumber != $1.discNumber { return $0.discNumber < $1.discNumber }
                    if $0.trackNumber != $1.trackNumber { return $0.trackNumber < $1.trackNumber }
                    return $0.id < $1.id
                }
            }
        case .subsonic:
            result = (try? await SubsonicAPI.shared.fetchSongs(for: album)) ?? []
        case .jellyfin:
            result = (try? await JellyfinAPI.shared.fetchSongs(for: album)) ?? []
        case .webdav:
            result = (try? await WebDAVAPI.shared.fetchSongs(for: album)) ?? []
        case .netease:
            let id = Int(album.id.replacingOccurrences(of: "netease-", with: ""))
            let direct: [Song]
            if let id {
                direct = (try? await NetEaseAPI.shared.albumSongs(albumID: id)) ?? []
            } else {
                direct = []
            }
            if !direct.isEmpty {
                result = direct
            } else {
                result = await searchFallbackSongs(
                    queries: [albumSearchQuery, album.name],
                    search: { query in
                        (try? await NetEaseAPI.shared.search(keyword: query, limit: 100)) ?? []
                    }
                )
            }
        case .qq:
            result = await searchFallbackSongs(
                queries: [albumSearchQuery, album.name],
                search: { query in
                    (try? await QQMusicAPI.shared.searchSongs(keyword: query, limit: 100)) ?? []
                }
            )
        case .kugou:
            result = await searchFallbackSongs(
                queries: [albumSearchQuery, album.name],
                search: { query in
                    (try? await KugouMusicAPI.shared.searchSongs(keyword: query, limit: 100)) ?? []
                }
            )
        case .local:
            result = LocalLibraryStore.shared.importedSongs.filter {
                $0.album.localizedCaseInsensitiveContains(album.name)
                    && $0.artists.localizedCaseInsensitiveContains(album.artistName)
            }.sorted {
                if $0.discNumber != $1.discNumber { return $0.discNumber < $1.discNumber }
                if $0.trackNumber != $1.trackNumber { return $0.trackNumber < $1.trackNumber }
                return $0.id < $1.id
            }
        }

        if !result.isEmpty {
            cache.save(result, for: cacheKey)
        }
        await MainActor.run {
            tracks = result
            isLoading = false
            if result.isEmpty { errorMessage = "未找到专辑歌曲" }
        }
    }

    private var albumSearchQuery: String {
        let artist = album.artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        return artist.isEmpty ? album.name : "\(artist) \(album.name)"
    }

    private func searchFallbackSongs(
        queries: [String],
        search: (String) async -> [Song]
    ) async -> [Song] {
        guard !album.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            ATMusicLogger.shared.log(
                "专辑详情筛选跳过：缺少专辑名，平台=\(album.source.rawValue)",
                level: .debug
            )
            return []
        }
        var tried = Set<String>()
        var albumOnlyCandidates: [Song] = []
        for query in queries {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, tried.insert(trimmed).inserted else { continue }
            let songs = await search(trimmed)
            let matches = songs.filter(albumSongMatches)
            let albumOnlyMatches = songs.filter { albumNamesMatch($0.album, album.name) }
            ATMusicLogger.shared.log(
                "专辑详情筛选：平台=\(album.source.rawValue) 查询=\(trimmed) 原始=\(songs.count) 专辑歌手匹配=\(matches.count) 专辑名匹配=\(albumOnlyMatches.count)",
                level: .debug
            )
            if !matches.isEmpty {
                var seen = Set<String>()
                return matches.filter { seen.insert($0.identityKey).inserted }
            }
            albumOnlyCandidates.append(contentsOf: albumOnlyMatches)
        }
        var seen = Set<String>()
        let fallback = albumOnlyCandidates.filter { seen.insert($0.identityKey).inserted }
        if !fallback.isEmpty {
            ATMusicLogger.shared.log(
                "专辑详情采用专辑名回退：平台=\(album.source.rawValue) 专辑=\(album.name) 数量=\(fallback.count)",
                level: .info
            )
        }
        return fallback
    }

    private func albumSongMatches(_ song: Song) -> Bool {
        guard albumNamesMatch(song.album, album.name) else { return false }
        if normalizedArtist(album.artistName).isEmpty { return true }
        return artistsMatch(expected: album.artistName, actual: song.artists)
    }

    private func normalizedArtist(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "（", with: "(")
            .replacingOccurrences(of: "）", with: ")")
            .replacingOccurrences(of: "#[（(].*?[）)]#", with: "", options: .regularExpression)
            .filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    private func artistTokens(_ value: String) -> [String] {
        let separators = CharacterSet(charactersIn: "/／,，、&＆+＋|｜;；")
        return value
            .components(separatedBy: separators)
            .map(normalizedArtist)
            .filter { !$0.isEmpty }
    }

    private func artistsMatch(expected: String, actual: String) -> Bool {
        let expectedTokens = artistTokens(expected)
        let actualTokens = artistTokens(actual)
        guard !expectedTokens.isEmpty, !actualTokens.isEmpty else { return false }
        return expectedTokens.contains { expectedToken in
            actualTokens.contains { actualToken in
                if expectedToken == actualToken { return true }
                guard min(expectedToken.count, actualToken.count) >= 3 else { return false }
                return expectedToken.hasPrefix(actualToken) || actualToken.hasPrefix(expectedToken)
            }
        }
    }

    private func albumNamesMatch(_ lhs: String, _ rhs: String) -> Bool {
        func normalized(_ value: String) -> String {
            value
                .lowercased()
                .replacingOccurrences(of: "（", with: "(")
                .replacingOccurrences(of: "）", with: ")")
                .replacingOccurrences(of: "[（(].*?[）)]", with: "", options: .regularExpression)
                .filter { !$0.isWhitespace && $0 != "-" && $0 != "·" }
        }
        let a = normalized(lhs)
        let b = normalized(rhs)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a.contains(b) || b.contains(a)
    }
}


// MARK: - 搜索输入框（UIKit 封装：根治中文输入法提交问题）
// SwiftUI TextField 在中文拼音组字中触发 onSubmit 时，binding 可能尚未拿到提交后的文本，
// 且提交瞬间的状态更新可能丢弃未上屏的组字，表现为“输入内容消失、搜索无结果”。
// 改用 UITextField 后：
//  1) 回车/点搜索前先 unmarkText() 强制把拼音提交为汉字，再直接读 field.text（必定最新）；
//  2) 输入内容由 UIKit 持有，SwiftUI 重绘不会清空输入框。

/// 搜索输入框控制器：持有 UITextField 弱引用，供“搜索”按钮与热搜标签操作
final class SearchFieldController {
    weak var textField: UITextField?

    /// 提交拼音组字并返回最新文本，同时收起键盘（点“搜索”按钮调用）
    func commit() -> String {
        guard let field = textField else { return "" }
        if field.markedTextRange != nil {
            field.unmarkText()
        }
        let text = field.text ?? ""
        field.resignFirstResponder()
        return text
    }

    /// 收起键盘（点热搜标签 / 歌手 / 专辑时调用）
    func dismissKeyboard() {
        textField?.resignFirstResponder()
    }
}

struct SearchTextField: UIViewRepresentable {
    @Binding var text: String
    let controller: SearchFieldController
    var placeholder: String = ""
    let textColor: UIColor
    let onSubmit: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = NSLocalizedString(placeholder, comment: "")
        field.font = ATMusicFont.appUIFont(15)
        field.textColor = textColor
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.returnKeyType = .search
        field.clearButtonMode = .never
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.text = text
        field.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)
        controller.textField = field
        return field
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        // 同步最新绑定值；同时刷新 coordinator 持有的父视图，保证闭包/绑定始终是最新实例。
        // 关键：中文/日文 IME 组字期间，UITextField 内部的 marked text 才是真实输入状态，
        // SwiftUI 绑定仍停留在上一次已提交文本。此时绝不能反向覆盖 uiView.text，
        // 否则拼音输入到一半会被旧 keyword 清掉。
        context.coordinator.parent = self
        if uiView.markedTextRange == nil, uiView.text != text {
            uiView.text = text
        }
        uiView.font = ATMusicFont.appUIFont(15)
        uiView.textColor = textColor
        uiView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        uiView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: SearchTextField

        init(_ parent: SearchTextField) {
            self.parent = parent
        }

        @objc func textChanged(_ field: UITextField) {
            // 中文/日文等输入法组字期间不要把拼音中间态写回 SwiftUI，
            // 否则 400ms debounce 可能对尚未提交的 marked text 发网络请求。
            guard field.markedTextRange == nil else { return }
            let value = field.text ?? ""
            if parent.text != value { parent.text = value }
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            // 输入法回车：先强制提交拼音再读取，确保拿到完整中文文本
            if field.markedTextRange != nil {
                field.unmarkText()
            }
            let text = field.text ?? ""
            parent.onSubmit(text)
            field.resignFirstResponder()
            return true
        }

        func textFieldDidEndEditing(_ field: UITextField) {
            let value = field.text ?? ""
            if parent.text != value { parent.text = value }
        }
    }
}
