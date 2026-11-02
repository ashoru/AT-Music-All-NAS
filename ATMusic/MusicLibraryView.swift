import SwiftUI


@MainActor
final class PlaylistActivityStore: ObservableObject {
    static let shared = PlaylistActivityStore()

    @Published private(set) var activity: [String: TimeInterval]
    private let defaults = UserDefaults.standard
    private let key = "atmusic.musicLibrary.playlistActivity.v1"

    private init() {
        activity = defaults.dictionary(forKey: key) as? [String: TimeInterval] ?? [:]
    }

    func mark(_ playlistID: String, at date: Date = Date()) {
        activity[playlistID] = date.timeIntervalSince1970
        defaults.set(activity, forKey: key)
    }

    func timestamp(for playlistID: String) -> TimeInterval {
        activity[playlistID] ?? 0
    }
}

@MainActor
final class MusicLibraryPlaylistStore: ObservableObject {
    static let shared = MusicLibraryPlaylistStore()

    @Published private(set) var netease: [Playlist] = []
    @Published private(set) var qq: [Playlist] = []
    @Published private(set) var kugou: [Playlist] = []
    @Published private(set) var synology: [Playlist] = []
    @Published private(set) var subsonic: [Playlist] = []
    @Published private(set) var jellyfin: [Playlist] = []
    @Published private(set) var webdav: [Playlist] = []
    @Published private(set) var isLoading = false

    private init() {}

    func load(auth: AuthStore, force: Bool = false) async {
        if !force {
            hydrateCachedPlaylists(auth: auth)
        }
        isLoading = netease.isEmpty && qq.isEmpty && kugou.isEmpty && synology.isEmpty && subsonic.isEmpty && jellyfin.isEmpty && webdav.isEmpty

        // 真正的渐进并发：每个平台完成后立刻更新对应区域，
        // 不再等最慢的平台结束才一次性提交整个“我的歌单”。
        let neteaseTask = Task { @MainActor in
            let value = await fetchNetease(auth: auth, force: force)
            netease = SyncedPlaylistOrderStore.shared.ordered(value, source: .netease)
        }
        let qqTask = Task { @MainActor in
            let value = await fetchQQ(force: force)
            qq = SyncedPlaylistOrderStore.shared.ordered(value, source: .qq)
        }
        let kugouTask = Task { @MainActor in
            let value = await fetchKugou(force: force)
            kugou = SyncedPlaylistOrderStore.shared.ordered(value, source: .kugou)
        }
        let synologyTask = Task { @MainActor in
            synology = await fetchSynology(force: force)
        }
        let subsonicTask = Task { @MainActor in
            subsonic = await fetchSubsonic(force: force)
        }
        let jellyfinTask = Task { @MainActor in
            jellyfin = await fetchJellyfin(force: force)
        }
        let webdavTask = Task { @MainActor in
            webdav = await fetchWebDAV(force: force)
        }

        _ = await neteaseTask.value
        _ = await qqTask.value
        _ = await kugouTask.value
        _ = await synologyTask.value
        _ = await subsonicTask.value
        _ = await jellyfinTask.value
        _ = await webdavTask.value
        isLoading = false
    }

    private func hydrateCachedPlaylists(auth: AuthStore) {
        if !auth.playlists.isEmpty {
            netease = SyncedPlaylistOrderStore.shared.ordered(auth.playlists, source: .netease)
        }

        let qqAuth = QQMusicAuth.shared
        let qqAccountID = qqAuth.rawUin.isEmpty ? qqAuth.playlistUin : qqAuth.rawUin
        if qqAuth.isLoggedIn,
           let cached = SyncedPlaylistCache.shared.cachedPlaylists(source: .qq, accountID: qqAccountID) {
            qq = SyncedPlaylistOrderStore.shared.ordered(cached.playlists, source: .qq)
        }

        let kugouAuth = KugouMusicAuth.shared
        if kugouAuth.isLoggedIn,
           let cached = SyncedPlaylistCache.shared.cachedPlaylists(source: .kugou, accountID: kugouAuth.userId) {
            kugou = SyncedPlaylistOrderStore.shared.ordered(cached.playlists, source: .kugou)
        }

        let api = SynologyAPI.shared
        let accountID = api.account.isEmpty ? "synology" : api.account
        if api.isLoggedIn,
           let cached = SyncedPlaylistCache.shared.cachedPlaylists(source: .synology, accountID: accountID) {
            synology = cached.playlists
        }
        let subsonicAPI = SubsonicAPI.shared
        let subsonicAccountID = subsonicAPI.account.isEmpty ? "subsonic" : subsonicAPI.account
        if subsonicAPI.isLoggedIn,
           let cached = SyncedPlaylistCache.shared.cachedPlaylists(source: .subsonic, accountID: subsonicAccountID) {
            subsonic = cached.playlists
        }
        let jellyfinAPI = JellyfinAPI.shared
        let jellyfinAccountID = jellyfinAPI.account.isEmpty ? "jellyfin" : jellyfinAPI.account
        if jellyfinAPI.isLoggedIn,
           let cached = SyncedPlaylistCache.shared.cachedPlaylists(source: .jellyfin, accountID: jellyfinAccountID) {
            jellyfin = cached.playlists
        }
        let webdavAPI = WebDAVAPI.shared
        let webdavAccountID = webdavAPI.account.isEmpty ? "webdav" : webdavAPI.account
        if webdavAPI.isLoggedIn,
           let cached = SyncedPlaylistCache.shared.cachedPlaylists(source: .webdav, accountID: webdavAccountID) {
            webdav = cached.playlists
        }
    }

    private func fetchNetease(auth: AuthStore, force: Bool) async -> [Playlist] {
        await auth.loadLibrary(force: force)
        return auth.playlists
    }

    private func fetchQQ(force: Bool) async -> [Playlist] {
        let auth = QQMusicAuth.shared
        guard auth.isLoggedIn else { return [] }
        let accountID = auth.rawUin.isEmpty ? auth.playlistUin : auth.rawUin
        let cache = SyncedPlaylistCache.shared
        var fallback: [Playlist] = []
        if let cached = cache.cachedPlaylists(source: .qq, accountID: accountID) {
            fallback = cached.playlists
            if !force, cache.isFresh(cached) { return cached.playlists }
        }
        let remote = (try? await QQMusicAPI.shared.userPlaylists(uin: auth.uin)) ?? []
        if !remote.isEmpty {
            cache.savePlaylists(remote, source: .qq, accountID: accountID)
            return remote
        }
        return fallback
    }

    private func fetchKugou(force: Bool) async -> [Playlist] {
        let auth = KugouMusicAuth.shared
        guard auth.isLoggedIn else { return [] }
        let cache = SyncedPlaylistCache.shared
        let accountID = auth.userId
        var fallback: [Playlist] = []
        if let cached = cache.cachedPlaylists(source: .kugou, accountID: accountID) {
            fallback = cached.playlists
            if !force, cache.isFresh(cached) { return cached.playlists }
        }
        let remote = (try? await KugouMusicAPI.shared.userPlaylists()) ?? []
        if !remote.isEmpty {
            cache.savePlaylists(remote, source: .kugou, accountID: accountID)
            return remote
        }
        return fallback
    }

    private func fetchSynology(force: Bool) async -> [Playlist] {
        let api = SynologyAPI.shared
        guard api.isLoggedIn else { return [] }
        let accountID = api.account.isEmpty ? "synology" : api.account
        let cache = SyncedPlaylistCache.shared
        var fallback: [Playlist] = []
        if let cached = cache.cachedPlaylists(source: .synology, accountID: accountID) {
            fallback = cached.playlists
            if !force, cache.isFresh(cached) { return cached.playlists }
        }
        let remote = (try? await api.allPlaylists()) ?? []
        if !remote.isEmpty {
            cache.savePlaylists(remote, source: .synology, accountID: accountID)
            return remote
        }
        return fallback
    }

    private func fetchSubsonic(force: Bool) async -> [Playlist] {
        let api = SubsonicAPI.shared
        guard api.isLoggedIn else { return [] }
        let accountID = api.account.isEmpty ? "subsonic" : api.account
        let cache = SyncedPlaylistCache.shared
        var fallback: [Playlist] = []
        if let cached = cache.cachedPlaylists(source: .subsonic, accountID: accountID) {
            fallback = cached.playlists
            if !force, cache.isFresh(cached) { return cached.playlists }
        }
        let remote = (try? await api.allPlaylists()) ?? []
        if !remote.isEmpty {
            cache.savePlaylists(remote, source: .subsonic, accountID: accountID)
            return remote
        }
        return fallback
    }

    private func fetchJellyfin(force: Bool) async -> [Playlist] {
        let api = JellyfinAPI.shared
        guard api.isLoggedIn else { return [] }
        let accountID = api.account.isEmpty ? "jellyfin" : api.account
        let cache = SyncedPlaylistCache.shared
        var fallback: [Playlist] = []
        if let cached = cache.cachedPlaylists(source: .jellyfin, accountID: accountID) {
            fallback = cached.playlists
            if !force, cache.isFresh(cached) { return cached.playlists }
        }
        let remote = (try? await api.allPlaylists()) ?? []
        if !remote.isEmpty {
            cache.savePlaylists(remote, source: .jellyfin, accountID: accountID)
            return remote
        }
        return fallback
    }

    private func fetchWebDAV(force: Bool) async -> [Playlist] {
        let api = WebDAVAPI.shared
        guard api.isLoggedIn else { return [] }
        let accountID = api.account.isEmpty ? "webdav" : api.account
        let cache = SyncedPlaylistCache.shared
        var fallback: [Playlist] = []
        if let cached = cache.cachedPlaylists(source: .webdav, accountID: accountID) {
            fallback = cached.playlists
            if !force, cache.isFresh(cached) { return cached.playlists }
        }
        let remote = (try? await api.allPlaylists()) ?? []
        if !remote.isEmpty {
            cache.savePlaylists(remote, source: .webdav, accountID: accountID)
            return remote
        }
        return fallback
    }
}

private struct MusicLibraryPlaylistItem: Identifiable {
    enum Kind {
        case remote(Playlist)
        case local(UUID)
    }

    let id: String
    let title: String
    let subtitle: String
    let coverURL: URL?
    let source: SongSource
    let kind: Kind
    var fallbackActivity: TimeInterval = 0

    var semanticPriority: Int {
        switch kind {
        case .local:
            let value = title.lowercased()
            return Self.looksLikeFavorite(value) ? 0 : 2
        case .remote(let playlist):
            if playlist.isNetEaseLikedPlaylist { return 1 }
            if playlist.source == .qq, playlist.id == QQMusicAPI.qqLikedPlaylistID { return 1 }
            return Self.looksLikeFavorite(playlist.name.lowercased()) ? 1 : 2
        }
    }

    private static func looksLikeFavorite(_ value: String) -> Bool {
        value.contains("红心")
            || value.contains("我喜欢")
            || value.contains("我的喜欢")
            || value.contains("喜欢的音乐")
            || value.contains("我的收藏")
            || value.contains("收藏歌单")
            || value.contains("liked")
            || value.contains("favorite")
    }
}

struct MusicLibraryHomeView: View {
    var onOpenProfile: () -> Void = {}

    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ObservedObject private var localStore = LocalLibraryStore.shared
    @ObservedObject private var playlistStore = MusicLibraryPlaylistStore.shared
    @ObservedObject private var favPlaylistStore = FavoritePlaylistStore.shared
    @ObservedObject private var activityStore = PlaylistActivityStore.shared
    @ObservedObject private var synology = SynologyAPI.shared
    @ObservedObject private var subsonic = SubsonicAPI.shared
    @ObservedObject private var jellyfin = JellyfinAPI.shared
    @ObservedObject private var webdav = WebDAVAPI.shared
    @ObservedObject private var platformPrefs = PlatformPreferenceStore.shared
    @ObservedObject private var favorites = FavoritesStore.shared
    @AppStorage("atmusic.uiStyle") private var uiStyleRaw = ATMusicUIStyle.liquid.rawValue
    @State private var playlistFilter: String = "全部"
    @State private var showCreatePlaylist = false
    @State private var newPlaylistName = ""

    private var allFavoriteSongs: [Song] {
        favorites.unifiedFavoriteSongs()
    }

    private var isNativeClean: Bool {
        ATMusicUIStyle(rawValue: uiStyleRaw) == .nativeClean
    }


    private var filteredPlaylists: [MusicLibraryPlaylistItem] {
        let all = homePlaylists
        switch playlistFilter {
        case "本地":
            return all.filter { $0.source == .local }
        case "网易云":
            return all.filter { $0.source == .netease }
        case "QQ":
            return all.filter { $0.source == .qq }
        case "酷狗":
            return all.filter { $0.source == .kugou }
        case "NAS":
            return all.filter { $0.source == .synology }
        case "Subsonic":
            return all.filter { $0.source == .subsonic }
        case "Jellyfin":
            return all.filter { $0.source == .jellyfin }
        case "WebDAV":
            return all.filter { $0.source == .webdav }
        default:
            return all
        }
    }

    private var homePlaylists: [MusicLibraryPlaylistItem] {
        var groups: [[MusicLibraryPlaylistItem]] = []

        let localItems = localStore.playlists.map {
            MusicLibraryPlaylistItem(
                id: "local-\($0.id.uuidString)",
                title: $0.name,
                subtitle: "本地 · \(atmusicLocalSongCountText($0.songs.count))",
                coverURL: $0.coverURL ?? $0.songs.first?.coverURL,
                source: .local,
                kind: .local($0.id),
                fallbackActivity: $0.createdAt.timeIntervalSince1970
            )
        }
        if !localItems.isEmpty { groups.append(localItems) }

        let remoteGroups: [[Playlist]] = [
            platformPrefs.isEnabled(SearchProvider.netease) ? playlistStore.netease : [],
            platformPrefs.isEnabled(SearchProvider.qq) ? playlistStore.qq : [],
            platformPrefs.isEnabled(SearchProvider.kugou) ? playlistStore.kugou : [],
            platformPrefs.isEnabled(SearchProvider.synology) ? playlistStore.synology : [],
            platformPrefs.isEnabled(SearchProvider.subsonic) ? playlistStore.subsonic : [],
            platformPrefs.isEnabled(SearchProvider.jellyfin) ? playlistStore.jellyfin : [],
            platformPrefs.isEnabled(SearchProvider.webdav) ? playlistStore.webdav : []
        ]
        for group in remoteGroups where !group.isEmpty {
            groups.append(group.map { playlist in
                MusicLibraryPlaylistItem(
                    id: "\(playlist.source.rawValue)-\(playlist.id)",
                    title: playlist.name,
                    subtitle: "\(playlist.source.atmusicDisplayName) · \(atmusicSongCountText(playlist.trackCount))",
                    coverURL: playlist.coverURL,
                    source: playlist.source,
                    kind: .remote(playlist)
                )
            })
        }

        var result: [MusicLibraryPlaylistItem] = []
        var index = 0
        while result.count < 8 {
            var appended = false
            for group in groups where index < group.count {
                result.append(group[index])
                appended = true
                if result.count == 8 { break }
            }
            if !appended { break }
            index += 1
        }
        return result
    }

    var body: some View {
        let _ = theme.accent
        ATMusicNavigationStack {
            ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
                ScrollView {
                    VStack(alignment: .leading, spacing: isNativeClean ? 26 : 22) {
                        header
                        favoriteHeroCard
                        quickAccess
                        playlistsPreview
                    }
                    .padding(.horizontal, DeviceLayoutHelper.isIPadRegular(horizontalSizeClass) ? 28 : (isNativeClean ? 24 : 20))
                    .padding(.top, 12)
                    .padding(.bottom, 190)
                    .frame(maxWidth: DeviceLayoutHelper.contentMaxWidth(for: horizontalSizeClass))
                    .frame(maxWidth: .infinity)
                }
                .atmusicScrollIndicatorsHidden()
                .refreshable { await playlistStore.load(auth: auth, force: true) }
            }
            .navigationBarHidden(true)
        }
        .task {
            async let p: () = playlistStore.load(auth: auth, force: false)
            async let f: () = favorites.syncAllFromCloud()
            _ = await (p, f)
        }
        .refreshable {
            async let p: () = playlistStore.load(auth: auth, force: true)
            async let f: () = favorites.syncAllFromCloud()
            _ = await (p, f)
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text("音乐库")
                .font(ATMusicFont.appFont(32, .bold))
                .foregroundStyle(Color.atmusicLabel)
            Spacer()
        }
    }

    private var favoriteHeroCard: some View {
        NavigationLink {
            UnifiedFavoritesDetailView()
        } label: {
            HStack(spacing: 15) {
                // 封面展示：前几首歌曲的封面缩略图或高质感红心微光背景
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.94, green: 0.22, blue: 0.35), Color(red: 0.88, green: 0.14, blue: 0.45)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 80, height: 80)
                        .shadow(color: Color.red.opacity(0.28), radius: 8, y: 4)

                    let covers = Array(allFavoriteSongs.compactMap(\.coverURL).prefix(4))
                    if covers.count >= 4 {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)], spacing: 2) {
                            ForEach(0..<4, id: \.self) { idx in
                                CoverImage(url: covers[idx], size: 36, cornerRadius: 4)
                            }
                        }
                        .frame(width: 74, height: 74)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.black.opacity(0.22))
                            Image(systemName: "heart.fill")
                                .font(.system(size: 26, weight: .bold))
                                .foregroundStyle(.white)
                                .shadow(radius: 4)
                        }
                    } else if let firstCover = covers.first {
                        CoverImage(url: firstCover, size: 80, cornerRadius: 18)
                            .overlay {
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color.black.opacity(0.24))
                                Image(systemName: "heart.fill")
                                    .font(.system(size: 28, weight: .bold))
                                    .foregroundStyle(.white)
                                    .shadow(radius: 4)
                            }
                    } else {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("我喜欢的音乐")
                        .font(ATMusicFont.appFont(18, .bold))
                        .foregroundStyle(Color.atmusicLabel)

                    Text("\(allFavoriteSongs.count) 首歌曲 · 同步本地与平台红心")
                        .font(ATMusicFont.appFont(12, .medium))
                        .foregroundStyle(Color.atmusicComment)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        Button {
                            if !allFavoriteSongs.isEmpty {
                                player.play(songs: allFavoriteSongs, startAt: 0)
                                ATMusicHaptics.tap()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 10, weight: .bold))
                                Text("播放全部")
                                    .font(ATMusicFont.appFont(12, .semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(Color.atmusicAmber, in: Capsule())
                        }
                        .buttonStyle(.plain)

                        Button {
                            if !allFavoriteSongs.isEmpty {
                                player.play(songs: allFavoriteSongs.shuffled(), startAt: 0)
                                ATMusicHaptics.tap()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "shuffle")
                                    .font(.system(size: 10, weight: .bold))
                                Text("随机播放")
                                    .font(ATMusicFont.appFont(12, .semibold))
                            }
                            .foregroundStyle(Color.atmusicLabel)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 2)
                }

                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.atmusicComment.opacity(0.6))
            }
            .padding(14)
            .background {
                ATMusicGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        }
        .buttonStyle(GlassPressButtonStyle(scale: 0.98))
    }

    private var quickAccess: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("快捷浏览")
                .font(ATMusicFont.appFont(16, .bold))
                .foregroundStyle(Color.atmusicLabel)

            if DeviceLayoutHelper.isIPadRegular(horizontalSizeClass) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: quickAccessColumnCount), spacing: 12) {
                    recentCard
                    localCard
                    transferCenterCard
                    favPlaylistsCard
                    if synology.isLoggedIn {
                        nasCard
                    }
                    if subsonic.isLoggedIn {
                        subsonicCard
                    }
                    if jellyfin.isLoggedIn {
                        jellyfinCard
                    }
                    if webdav.isLoggedIn {
                        webdavCard
                    }
                }
                .buttonStyle(GlassPressButtonStyle(scale: 0.97))
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    recentCard
                    localCard
                    transferCenterCard
                    favPlaylistsCard
                    if synology.isLoggedIn {
                        nasCard
                    }
                    if subsonic.isLoggedIn {
                        subsonicCard
                    }
                    if jellyfin.isLoggedIn {
                        jellyfinCard
                    }
                    if webdav.isLoggedIn {
                        webdavCard
                    }
                }
                .buttonStyle(GlassPressButtonStyle(scale: 0.97))
            }
        }
    }

    private var recentCard: some View {
        NavigationLink {
            MusicLibraryHistoryView()
        } label: {
            MusicLibraryQuickCard(
                title: "最近播放",
                subtitle: "\(player.history.count) 首",
                systemImage: "clock.arrow.circlepath",
                enabled: true
            )
        }
    }

    private var transferCenterCard: some View {
        NavigationLink {
            TransferCenterView()
        } label: {
            MusicLibraryQuickCard(
                title: "传输中心",
                subtitle: DownloadManager.shared.transferCardSubtitle,
                systemImage: "arrow.up.arrow.down.circle.fill",
                enabled: true
            )
        }
    }

    private var localCard: some View {
        NavigationLink {
            LocalMusicBrowserView()
        } label: {
            MusicLibraryQuickCard(
                title: "本地音乐",
                subtitle: "\(localStore.importedSongs.count) 首",
                systemImage: "internaldrive.fill",
                enabled: true
            )
        }
    }

    private var favPlaylistsCard: some View {
        NavigationLink {
            MusicLibraryAllPlaylistsView(initialFilter: .favorites)
        } label: {
            MusicLibraryQuickCard(
                title: "收藏歌单",
                subtitle: "\(favPlaylistStore.playlists.count) 个",
                systemImage: "heart.rectangle.fill",
                enabled: true
            )
        }
    }

    private var quickAccessColumnCount: Int {
        4 + (synology.isLoggedIn ? 1 : 0) + (subsonic.isLoggedIn ? 1 : 0) + (jellyfin.isLoggedIn ? 1 : 0) + (webdav.isLoggedIn ? 1 : 0)
    }

    private var nasCard: some View {
        NavigationLink {
            SynologyFileLibraryView()
        } label: {
            MusicLibraryQuickCard(
                title: "NAS 文件",
                subtitle: "浏览文件夹",
                systemImage: "externaldrive.fill",
                enabled: true
            )
        }
    }

    private var subsonicCard: some View {
        NavigationLink {
            SubsonicMusicView()
        } label: {
            MusicLibraryQuickCard(
                title: "Subsonic",
                subtitle: "浏览音乐库",
                systemImage: "server.rack",
                enabled: true
            )
        }
    }

    private var jellyfinCard: some View {
        NavigationLink {
            JellyfinMusicView()
        } label: {
            MusicLibraryQuickCard(
                title: "Jellyfin",
                subtitle: "浏览音乐库",
                systemImage: "play.tv.fill",
                enabled: true
            )
        }
    }

    private var webdavCard: some View {
        NavigationLink {
            WebDAVMusicView()
        } label: {
            MusicLibraryQuickCard(
                title: "WebDAV",
                subtitle: "浏览音乐库",
                systemImage: "folder.fill.badge.gearshape",
                enabled: true
            )
        }
    }


    private var availableFilterTags: [String] {
        var tags = ["全部", "本地"]
        if platformPrefs.isEnabled(SearchProvider.netease) { tags.append("网易云") }
        if platformPrefs.isEnabled(SearchProvider.qq) { tags.append("QQ") }
        if platformPrefs.isEnabled(SearchProvider.kugou) { tags.append("酷狗") }
        if platformPrefs.isEnabled(SearchProvider.synology) { tags.append("NAS") }
        if platformPrefs.isEnabled(SearchProvider.subsonic) { tags.append("Subsonic") }
        if platformPrefs.isEnabled(SearchProvider.jellyfin) { tags.append("Jellyfin") }
        if platformPrefs.isEnabled(SearchProvider.webdav) { tags.append("WebDAV") }
        return tags
    }

    private var playlistsPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("我的歌单")
                    .font(ATMusicFont.appFont(18, .bold))
                    .foregroundStyle(Color.atmusicLabel)
                Spacer()
                HStack(spacing: 12) {
                    Button {
                        newPlaylistName = ""
                        showCreatePlaylist = true
                        ATMusicHaptics.tap()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .bold))
                            Text("新建本地")
                                .font(ATMusicFont.appFont(13, .semibold))
                        }
                        .foregroundStyle(Color.atmusicAmber)
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        MusicLibraryAllPlaylistsView()
                    } label: {
                        HStack(spacing: 4) {
                            Text("全部")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .font(ATMusicFont.appFont(13, .semibold))
                        .foregroundStyle(Color.atmusicComment)
                    }
                    .buttonStyle(.plain)
                }
            }

            // 分类胶囊筛选行 [ 全部 / 本地 / 网易云 / QQ / 酷狗 ]
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(availableFilterTags, id: \.self) { tag in
                        let isSelected = playlistFilter == tag
                        Button {
                            playlistFilter = tag
                            ATMusicHaptics.select()
                        } label: {
                            Text(tag)
                                .font(ATMusicFont.appFont(12, isSelected ? .semibold : .medium))
                                .foregroundStyle(isSelected ? Color.white : Color.atmusicLabel)
                                .padding(.horizontal, 12)
                                .frame(height: 28)
                                .background(
                                    isSelected ? Color.atmusicAmber : Color.primary.opacity(0.06),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 1)
            }

            let displayList = filteredPlaylists
            if displayList.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.atmusicAmber)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(playlistFilter == "全部" ? "还没有歌单" : "没有\(playlistFilter)分类歌单")
                            .font(ATMusicFont.appFont(14, .semibold))
                            .foregroundStyle(Color.atmusicLabel)
                        Text(playlistFilter == "本地" ? "点击右上角「新建」可创建本地歌单" : "登录平台或新建歌单后会显示在这里")
                            .font(ATMusicFont.appFont(12))
                            .foregroundStyle(Color.atmusicComment)
                    }
                    Spacer()
                }
                .padding(14)
                .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 18, style: .continuous)) }
            } else if DeviceLayoutHelper.isIPadRegular(horizontalSizeClass) {
                LazyVGrid(columns: DeviceLayoutHelper.adaptiveCardColumns(for: horizontalSizeClass, minWidth: 160, maxWidth: 240, spacing: 16), spacing: 18) {
                    ForEach(displayList) { item in
                        iPadPlaylistItemCard(item)
                    }
                }
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(displayList) { item in
                        playlistLink(item)
                        if item.id != displayList.last?.id {
                            Divider()
                                .overlay(Color.atmusicComment.opacity(0.12))
                                .padding(.leading, 66)
                        }
                    }
                }
                .padding(.vertical, 4)
                .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 20, style: .continuous)) }
            }
        }
        .alert("新建本地歌单", isPresented: $showCreatePlaylist) {
            TextField("歌单名称", text: $newPlaylistName)
            Button("取消", role: .cancel) {}
            Button("创建") {
                let trimmed = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                _ = localStore.createPlaylist(name: trimmed)
                ATMusicHaptics.success()
                ToastCenter.shared.show("已创建歌单「\(trimmed)」")
            }
        }
    }

    @ViewBuilder
    private func iPadPlaylistItemCard(_ item: MusicLibraryPlaylistItem) -> some View {
        switch item.kind {
        case .remote(let playlist):
            NavigationLink {
                PlaylistView(playlist: playlist)
            } label: {
                MediaSquareCard(playlist: playlist)
            }
            .buttonStyle(GlassPressButtonStyle(scale: 0.97))
        case .local(let id):
            NavigationLink {
                LocalPlaylistBrowserView(playlistID: id)
            } label: {
                MediaSquareCard(
                    title: item.title,
                    subtitle: item.subtitle,
                    coverURL: item.coverURL,
                    source: .local,
                    showSourceBadge: true
                )
            }
            .buttonStyle(GlassPressButtonStyle(scale: 0.97))
        }
    }

    @ViewBuilder
    private func playlistLink(_ item: MusicLibraryPlaylistItem) -> some View {
        switch item.kind {
        case .remote(let playlist):
            NavigationLink {
                PlaylistView(playlist: playlist)
                    .onAppear { activityStore.mark(item.id) }
            } label: {
                MusicLibraryPlaylistRow(item: item)
            }
            .buttonStyle(.plain)
        case .local(let id):
            NavigationLink {
                LocalPlaylistBrowserView(playlistID: id)
                    .onAppear { activityStore.mark(item.id) }
            } label: {
                MusicLibraryPlaylistRow(item: item)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct MusicLibraryQuickCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let enabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(enabled ? Color.atmusicAmber : Color.atmusicComment)
            Text(title)
                .font(ATMusicFont.appFont(14, .semibold))
                .foregroundStyle(Color.atmusicLabel)
                .lineLimit(1)
            Text(subtitle)
                .font(ATMusicFont.appFont(10))
                .foregroundStyle(Color.atmusicComment)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .padding(12)
        .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 18, style: .continuous)) }
        .opacity(enabled ? 1 : 0.72)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct MusicLibraryPlaylistRow: View {
    let item: MusicLibraryPlaylistItem

    var body: some View {
        HStack(spacing: 12) {
            if item.source == .local, item.coverURL == nil {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color.atmusicAmber.opacity(0.12))
                    Image(systemName: "music.note.list")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.atmusicAmber)
                }
                .frame(width: 50, height: 50)
            } else {
                CoverImage(url: item.coverURL, size: 50, cornerRadius: 11)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(ATMusicFont.appFont(14, .semibold))
                    .foregroundStyle(Color.atmusicLabel)
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(ATMusicFont.appFont(11))
                    .foregroundStyle(Color.atmusicComment)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if item.source != .local {
                SourceBadgeView(source: item.source, compact: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}

private enum MusicLibraryPlaylistFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case favorites = "收藏"
    case local = "本地"
    case netease = "网易云"
    case qq = "QQ"
    case kugou = "酷狗"
    case synology = "NAS"
    case subsonic = "Subsonic"
    case jellyfin = "Jellyfin"
    case webdav = "WebDAV"
    var id: String { rawValue }
}

struct MusicLibraryHistoryView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        ZStack {
            GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
            if player.history.isEmpty {
                EmptyStateView(icon: "clock.arrow.circlepath", text: "暂无播放历史")
            } else if DeviceLayoutHelper.isIPadRegular(horizontalSizeClass) {
                ScrollView {
                    LazyVGrid(columns: DeviceLayoutHelper.songListColumns(for: horizontalSizeClass, spacing: 16), spacing: 8) {
                        ForEach(Array(player.history.enumerated()), id: \.element.identityKey) { index, song in
                            SongCell(song: song, glassRow: true, playbackContext: player.history, playbackIndex: index, onTap: {
                                player.play(songs: player.history, startAt: index)
                            })
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.primary.opacity(0.03))
                            }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 16)
                    .padding(.bottom, 120)
                }
                .frame(maxWidth: DeviceLayoutHelper.contentMaxWidth(for: horizontalSizeClass))
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(Array(player.history.enumerated()), id: \.element.identityKey) { index, song in
                        SongCell(song: song, glassRow: false, playbackContext: player.history, playbackIndex: index, onTap: {
                            player.play(songs: player.history, startAt: index)
                        })
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                    .onDelete { offsets in
                        player.removeHistory(at: offsets)
                    }
                }
                .atmusicScrollContentBackgroundHidden()
                .listStyle(.plain)
            }
        }
        .navigationTitle("最近播放")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !player.history.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清空") {
                        ATMusicHaptics.tap()
                        player.clearHistory()
                    }
                }
            }
        }
    }
}

struct MusicLibraryAllPlaylistsView: View {
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ObservedObject private var localStore = LocalLibraryStore.shared
    @ObservedObject private var playlistStore = MusicLibraryPlaylistStore.shared
    @ObservedObject private var activityStore = PlaylistActivityStore.shared
    @ObservedObject private var platformPrefs = PlatformPreferenceStore.shared

    @State private var filter: MusicLibraryPlaylistFilter
    @State private var searchText = ""
    @State private var isManaging = false
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var showDeleteConfirm = false
    @State private var showMergeSheet = false
    @State private var mergeSongs: [Song] = []
    @State private var showCreateAlert = false
    @State private var newCreateName = ""
    @State private var createSource: SongSource = .local
    @State private var renameItem: MusicLibraryPlaylistItem?
    @State private var renameText = ""
    @State private var showRenameAlert = false
    @State private var descItem: MusicLibraryPlaylistItem?
    @State private var descText = ""
    @State private var showDescAlert = false
    @State private var coverLocalID: UUID?
    @State private var showCoverPicker = false
    @State private var dragStartIndex: Int?
    @State private var dragTargetSelected: Bool = true
    @State private var lastDragIndex: Int?
    @State private var initialSelectedIDsOnDrag: Set<String>? = nil

    fileprivate init(initialFilter: MusicLibraryPlaylistFilter = .all) {
        self._filter = State(initialValue: initialFilter)
    }

    private var selectedItems: [MusicLibraryPlaylistItem] {
        let selected = selectedIDs
        return items.filter { selected.contains($0.id) }
    }

    private func toggleItemSelection(_ item: MusicLibraryPlaylistItem) {
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
        ATMusicHaptics.tap()
    }

    private func handlePlaylistDragChange(startIndex: Int, deltaRows: Int) {
        let allIDs = items.map(\.id)
        guard startIndex >= 0, startIndex < allIDs.count else { return }
        if dragStartIndex == nil {
            dragStartIndex = startIndex
            initialSelectedIDsOnDrag = selectedIDs
            let willSelect = !selectedIDs.contains(allIDs[startIndex])
            dragTargetSelected = willSelect
            lastDragIndex = nil
        }
        guard let start = dragStartIndex, let initial = initialSelectedIDsOnDrag else { return }
        let current = min(max(0, start + deltaRows), allIDs.count - 1)
        guard current != lastDragIndex else { return }
        lastDragIndex = current
        ATMusicHaptics.select()

        let low = min(start, current)
        let high = max(start, current)
        var updated = initial
        for idx in low...high {
            let id = allIDs[idx]
            if dragTargetSelected {
                updated.insert(id)
            } else {
                updated.remove(id)
            }
        }
        selectedIDs = updated
    }

    private func handlePlaylistDragEnd() {
        dragStartIndex = nil
        initialSelectedIDsOnDrag = nil
        lastDragIndex = nil
    }

    @ViewBuilder
    private func playlistItemDestination(_ item: MusicLibraryPlaylistItem) -> some View {
        switch item.kind {
        case .remote(let playlist):
            PlaylistView(playlist: playlist)
                .onAppear { activityStore.mark(item.id) }
        case .local(let id):
            LocalPlaylistBrowserView(playlistID: id)
                .onAppear { activityStore.mark(item.id) }
        }
    }

    @ViewBuilder
    private func playlistItemLabel(_ item: MusicLibraryPlaylistItem, isCard: Bool) -> some View {
        if isCard {
            switch item.kind {
            case .remote(let playlist):
                MediaSquareCard(playlist: playlist)
            case .local:
                MediaSquareCard(title: item.title, subtitle: item.subtitle, coverURL: item.coverURL, showSourceBadge: false)
            }
        } else {
            MusicLibraryPlaylistRow(item: item)
        }
    }

    private func selectionBadge(for item: MusicLibraryPlaylistItem) -> some View {
        let selected = selectedIDs.contains(item.id)
        return Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(selected ? Color.atmusicAmber : Color.atmusicComment)
            .background(Circle().fill(Color.black.opacity(0.35)))
            .padding(8)
    }

    @ViewBuilder
    private func playlistItemCore(_ item: MusicLibraryPlaylistItem, index: Int, isCard: Bool) -> some View {
        if isManaging {
            playlistItemContent(item, index: index, isCard: isCard)
                .contextMenu {
                    manageMenu(for: item)
                }
        } else {
            playlistItemContent(item, index: index, isCard: isCard)
        }
    }

    @ViewBuilder
    private func playlistItemContent(_ item: MusicLibraryPlaylistItem, index: Int, isCard: Bool) -> some View {
        if isSelecting {
            if isCard {
                Button {
                    toggleItemSelection(item)
                } label: {
                    playlistItemLabel(item, isCard: isCard)
                        .overlay(alignment: .topTrailing) {
                            selectionBadge(for: item)
                        }
                }
            } else {
                HStack(spacing: 12) {
                    MultiSelectCheckmark(
                        isSelected: selectedIDs.contains(item.id),
                        index: index,
                        rowHeight: 60,
                        onToggle: {
                            toggleItemSelection(item)
                        },
                        onDragChange: { startIdx, deltaRows in
                            handlePlaylistDragChange(startIndex: startIdx, deltaRows: deltaRows)
                        },
                        onDragEnd: {
                            handlePlaylistDragEnd()
                        }
                    )
                    playlistItemLabel(item, isCard: false)
                }
                .multiSelectRow(index: index, coordinateSpace: "AllPlaylistsListSpace")
                .contentShape(Rectangle())
                .onTapGesture {
                    toggleItemSelection(item)
                }
            }
        } else {
            NavigationLink {
                playlistItemDestination(item)
            } label: {
                playlistItemLabel(item, isCard: isCard)
            }
        }
    }

    /// 管理模式长按菜单：只按 135 能力矩阵出项，不支持的操作直接不出现。
    /// NAS 改名无已验证接口，故只出转存 / 收藏 / 删除，不出改名；换封面、去重只对本地有意义。
    @ViewBuilder
    private func manageMenu(for item: MusicLibraryPlaylistItem) -> some View {
        let caps = PlaylistCapabilities.forSource(item.source)
        if item.source == .local || item.source == .netease {
            Button {
                renameItem = item
                renameText = item.title
                showRenameAlert = true
            } label: {
                Label("重命名", systemImage: "character.cursor.ibeam")
            }
        }
        if caps.canEditDescription {
            Button {
                descItem = item
                descText = currentDescription(for: item)
                showDescAlert = true
            } label: {
                Label("编辑简介", systemImage: "text.quote")
            }
        }
        if item.source == .local {
            Button {
                if case .local(let id) = item.kind {
                    coverLocalID = id
                    showCoverPicker = true
                }
            } label: {
                Label("换封面", systemImage: "photo")
            }
            Button {
                dedupeLocal(item)
            } label: {
                Label("去重", systemImage: "square.stack.3d.up")
            }
        }
        if item.source != .local {
            Button {
                Task {
                    selectedIDs = [item.id]
                    await exportSelectedToLocal()
                }
            } label: {
                Label("转存本地", systemImage: "square.and.arrow.down")
            }
        }
        if case .remote(let playlist) = item.kind {
            Button {
                FavoritePlaylistStore.shared.toggle(playlist)
            } label: {
                Label(
                    FavoritePlaylistStore.shared.isFavorite(playlist) ? "取消收藏" : "收藏歌单",
                    systemImage: "heart"
                )
            }
        }
        if caps.canDelete {
            Button(role: .destructive) {
                selectedIDs = [item.id]
                showDeleteConfirm = true
            } label: {
                Label("删除歌单", systemImage: "trash")
            }
        }
    }

    /// 浏览/管理分段：用软件里已有的原生 Picker 分段写法（同 SynologyMusicView、LocalMusicSection 的平台切换），
    /// 不再自造胶囊按钮；四种 UI 下都由系统渲染选中态，液态下走系统 Liquid Glass，简洁下就是 Apple 原生样式。
    private var modeSegmented: some View {
        VStack(spacing: 4) {
            Picker("模式", selection: $isManaging) {
                Text("浏览").tag(false)
                Text("管理").tag(true)
            }
            .pickerStyle(.segmented)
            if isManaging {
                Text("点按多选，长按单条管理")
                    .font(ATMusicFont.appFont(11))
                    .foregroundStyle(Color.atmusicComment)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .onChange(of: isManaging) { managing in
            isSelecting = managing
            selectedIDs.removeAll()
            if managing { ATMusicHaptics.tap() }
        }
    }

    /// 分类分段：同上，原生 Picker 分段，整条固定在顶部，不再是可横向拖动的 ScrollView；
    /// 只出全部、收藏、本地和已启用平台，当前已选的平台即使刚被停用也先留着，避免选中态凭空消失。
    private var visibleFilters: [MusicLibraryPlaylistFilter] {
        var result: [MusicLibraryPlaylistFilter] = [.all, .favorites, .local]
        let platformOptions: [(SearchProvider, MusicLibraryPlaylistFilter)] = [
            (.netease, .netease), (.qq, .qq), (.kugou, .kugou), (.synology, .synology), (.subsonic, .subsonic), (.jellyfin, .jellyfin), (.webdav, .webdav)
        ]
        for (provider, option) in platformOptions {
            if platformPrefs.isEnabled(provider) || filter == option {
                result.append(option)
            }
        }
        return result
    }

    private var filterSegmented: some View {
        Picker("分类", selection: $filter) {
            ForEach(visibleFilters) { option in
                Text(option.rawValue).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .onChange(of: filter) { _ in ATMusicHaptics.select() }
    }

    private var createSourceName: String {
        switch createSource {
        case .local: return "本地"
        case .netease: return "网易云"
        case .qq: return "QQ"
        case .kugou: return "酷狗"
        case .synology: return "NAS"
        case .subsonic: return "Subsonic"
        case .jellyfin: return "Jellyfin"
        case .webdav: return "WebDAV"
        }
    }

    private func beginCreate(source: SongSource) {
        createSource = source
        newCreateName = ""
        showCreateAlert = true
    }

    private func createPlaylistFromManage() {
        let name = newCreateName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        switch createSource {
        case .local:
            _ = localStore.createPlaylist(name: name)
            ToastCenter.shared.show("已创建本地歌单「\(name)」")
        case .netease:
            guard auth.isLoggedIn else {
                ToastCenter.shared.show("请先登录网易云音乐")
                return
            }
            Task {
                do {
                    _ = try await NetEaseAPI.shared.createPlaylist(name: name)
                    ToastCenter.shared.show("歌单「\(name)」已创建")
                    await playlistStore.load(auth: auth, force: true)
                } catch {
                    ToastCenter.shared.show("创建失败：\(error.localizedDescription)")
                }
            }
        case .qq:
            guard QQMusicAuth.shared.isLoggedIn else {
                ToastCenter.shared.show("请先登录 QQ 音乐")
                return
            }
            Task {
                do {
                    let ok = try await QQMusicAPI.shared.createPlaylist(name: name)
                    if ok {
                        ToastCenter.shared.show("歌单「\(name)」已创建")
                        await playlistStore.load(auth: auth, force: true)
                    } else {
                        ToastCenter.shared.show("创建失败，请确认已登录 QQ 音乐")
                    }
                } catch {
                    ToastCenter.shared.show("创建失败：\(error.localizedDescription)")
                }
            }
        default:
            ToastCenter.shared.show("该来源暂不支持在此新建")
        }
    }

    private func currentDescription(for item: MusicLibraryPlaylistItem) -> String {
        switch item.kind {
        case .local(let id):
            return localStore.playlists.first { $0.id == id }?.descriptionText ?? ""
        case .remote(let playlist):
            return playlist.descriptionText ?? ""
        }
    }

    private func saveRename() {
        guard let item = renameItem else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        switch item.kind {
        case .local(let id):
            localStore.renamePlaylist(id: id, name: name)
            ToastCenter.shared.show("已重命名为「\(name)」")
        case .remote(let playlist) where playlist.source == .netease:
            Task {
                do {
                    let ok = try await NetEaseAPI.shared.renamePlaylist(id: playlist.id, name: name)
                    if ok {
                        await PlaylistManagementService.invalidateListCache(for: .netease)
                        await playlistStore.load(auth: auth, force: true)
                        ToastCenter.shared.show("已重命名为「\(name)」")
                    } else {
                        ToastCenter.shared.show("重命名失败，请重试")
                    }
                } catch {
                    ToastCenter.shared.show("重命名失败：\(error.localizedDescription)")
                }
            }
        default:
            break
        }
    }

    private func saveDescription() {
        guard let item = descItem else { return }
        switch item.kind {
        case .local(let id):
            localStore.setDescription(descText, for: id)
            ToastCenter.shared.show("简介已更新")
        case .remote(let playlist) where playlist.source == .netease:
            Task {
                do {
                    let ok = try await NetEaseAPI.shared.updatePlaylistDescription(id: playlist.id, description: descText)
                    if ok {
                        await playlistStore.load(auth: auth, force: true)
                        ToastCenter.shared.show("简介已更新")
                    } else {
                        ToastCenter.shared.show("简介更新失败，请重试")
                    }
                } catch {
                    ToastCenter.shared.show("简介更新失败：\(error.localizedDescription)")
                }
            }
        default:
            break
        }
    }

    private func dedupeLocal(_ item: MusicLibraryPlaylistItem) {
        guard case .local(let id) = item.kind else { return }
        let removed = localStore.deduplicatePlaylist(id: id)
        ToastCenter.shared.show(removed == 0 ? "没有重复歌曲" : "已去掉 \(removed) 首重复歌曲")
    }

    private var batchBar: some View {
        HStack(spacing: 12) {
            Button(selectedIDs.count == items.count && !items.isEmpty ? "取消全选" : "全选") {
                if selectedIDs.count == items.count {
                    selectedIDs.removeAll()
                } else {
                    selectedIDs = Set(items.map(\.id))
                }
                ATMusicHaptics.tap()
            }
            Text(selectedIDs.isEmpty ? "未选择歌单" : "已选 \(selectedIDs.count) 个")
                .font(ATMusicFont.appFont(12, .medium))
                .foregroundStyle(Color.atmusicComment)
            Spacer()
            Button("删除") { showDeleteConfirm = true }
                .disabled(selectedIDs.isEmpty)
            Button("合并到…") { Task { await prepareMerge() } }
                .disabled(selectedIDs.isEmpty)
            Button("转存本地") { Task { await exportSelectedToLocal() } }
                .disabled(selectedIDs.isEmpty)
            Button("完成") {
                isManaging = false
                isSelecting = false
                selectedIDs.removeAll()
            }
        }
        .font(ATMusicFont.appFont(13, .semibold))
        .foregroundStyle(Color.atmusicAmber)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
    }

    private func prepareMerge() async {
        var all: [Song] = []
        var seen = Set<String>()
        for item in selectedItems {
            let songs: [Song]
            switch item.kind {
            case .local(let id):
                songs = localStore.playlists.first { $0.id == id }?.songs ?? []
            case .remote(let playlist):
                songs = await PlaylistManagementService.shared.loadSongs(for: playlist)
            }
            for song in songs where seen.insert(song.identityKey).inserted {
                all.append(song)
            }
        }
        mergeSongs = all
        if all.isEmpty {
            ToastCenter.shared.show("所选歌单是空的或加载失败")
        } else {
            showMergeSheet = true
        }
    }

    private func deleteSelected() async {
        var deleted = 0
        var skipped = 0
        for item in selectedItems {
            switch item.kind {
            case .local(let id):
                localStore.deletePlaylist(id: id)
                deleted += 1
            case .remote(let playlist):
                switch playlist.source {
                case .netease:
                    if (try? await NetEaseAPI.shared.deletePlaylist(id: playlist.id)) == true {
                        await PlaylistManagementService.invalidateListCache(for: .netease)
                        deleted += 1
                    } else { skipped += 1 }
                case .qq:
                    if (try? await QQMusicAPI.shared.deletePlaylist(dirid: playlist.id)) == true {
                        await PlaylistManagementService.invalidateListCache(for: .qq)
                        deleted += 1
                    } else { skipped += 1 }
                case .synology:
                    if let pid = playlist.synologyPlaylistId, !pid.isEmpty,
                       (try? await SynologyAPI.shared.deleteNASPlaylist(id: pid)) != nil {
                        await PlaylistManagementService.invalidateListCache(for: .synology)
                        deleted += 1
                    } else { skipped += 1 }
                case .subsonic:
                    if (try? await SubsonicAPI.shared.deletePlaylist(playlist)) == true {
                        await PlaylistManagementService.invalidateListCache(for: .subsonic)
                        deleted += 1
                    } else { skipped += 1 }
                case .jellyfin:
                    if (try? await JellyfinAPI.shared.deletePlaylist(playlist)) == true {
                        await PlaylistManagementService.invalidateListCache(for: .jellyfin)
                        deleted += 1
                    } else { skipped += 1 }
                case .webdav:
                    if (try? await WebDAVAPI.shared.deletePlaylist(playlist)) == true {
                        await PlaylistManagementService.invalidateListCache(for: .webdav)
                        deleted += 1
                    } else { skipped += 1 }
                case .kugou, .local:
                    skipped += 1
                }
            }
        }
        selectedIDs.removeAll()
        await playlistStore.load(auth: auth, force: true)
        ToastCenter.shared.show(skipped == 0 ? "已删除 \(deleted) 个歌单" : "已删除 \(deleted) 个，\(skipped) 个不支持删除已跳过")
    }

    private func exportSelectedToLocal() async {
        var created = 0
        for item in selectedItems {
            switch item.kind {
            case .local:
                continue
            case .remote(let playlist):
                let songs = await PlaylistManagementService.shared.loadSongs(for: playlist)
                guard !songs.isEmpty else { continue }
                _ = await PlaylistManagementService.shared.copyToLocal(songs: songs, named: "\(playlist.name)（本地）")
                created += 1
            }
        }
        selectedIDs.removeAll()
        ToastCenter.shared.show(created == 0 ? "没有可转存的歌单" : "已转存 \(created) 个歌单到本地")
    }

    private var items: [MusicLibraryPlaylistItem] {
        var result: [MusicLibraryPlaylistItem] = []
        if filter == .all || filter == .favorites {
            result += FavoritePlaylistStore.shared.playlists.map {
                MusicLibraryPlaylistItem(
                    id: "fav-\($0.identityKey)",
                    title: $0.name,
                    subtitle: "收藏 · \($0.source.atmusicDisplayName) · \(atmusicSongCountText($0.trackCount))",
                    coverURL: $0.coverURL,
                    source: $0.source,
                    kind: .remote($0)
                )
            }
        }

        if filter == .all || filter == .local {
            result += localStore.playlists.map {
                MusicLibraryPlaylistItem(
                    id: "local-\($0.id.uuidString)",
                    title: $0.name,
                    subtitle: "本地 · \(atmusicLocalSongCountText($0.songs.count))",
                    coverURL: $0.coverURL ?? $0.songs.first?.coverURL,
                    source: .local,
                    kind: .local($0.id),
                    fallbackActivity: $0.createdAt.timeIntervalSince1970
                )
            }
        }

        func append(_ playlists: [Playlist], when target: MusicLibraryPlaylistFilter) {
            guard filter == .all || filter == target else { return }
            result += playlists.map {
                MusicLibraryPlaylistItem(
                    id: "\($0.source.rawValue)-\($0.id)",
                    title: $0.name,
                    subtitle: "\($0.source.atmusicDisplayName) · \(atmusicSongCountText($0.trackCount))",
                    coverURL: $0.coverURL,
                    source: $0.source,
                    kind: .remote($0)
                )
            }
        }

        if platformPrefs.isEnabled(SearchProvider.netease) { append(playlistStore.netease, when: .netease) }
        if platformPrefs.isEnabled(SearchProvider.qq) { append(playlistStore.qq, when: .qq) }
        if platformPrefs.isEnabled(SearchProvider.kugou) { append(playlistStore.kugou, when: .kugou) }
        if platformPrefs.isEnabled(SearchProvider.synology) { append(playlistStore.synology, when: .synology) }
        if platformPrefs.isEnabled(SearchProvider.subsonic) { append(playlistStore.subsonic, when: .subsonic) }
        if platformPrefs.isEnabled(SearchProvider.jellyfin) { append(playlistStore.jellyfin, when: .jellyfin) }
        if platformPrefs.isEnabled(SearchProvider.webdav) { append(playlistStore.webdav, when: .webdav) }

        let stableIndex = Dictionary(uniqueKeysWithValues: result.enumerated().map { ($0.element.id, $0.offset) })
        result.sort { lhs, rhs in
            if lhs.semanticPriority != rhs.semanticPriority {
                return lhs.semanticPriority < rhs.semanticPriority
            }
            let leftActivity = max(activityStore.timestamp(for: lhs.id), lhs.fallbackActivity)
            let rightActivity = max(activityStore.timestamp(for: rhs.id), rhs.fallbackActivity)
            if leftActivity != rightActivity {
                return leftActivity > rightActivity
            }
            return (stableIndex[lhs.id] ?? 0) < (stableIndex[rhs.id] ?? 0)
        }

        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return result }
        return result.filter { item in
            item.title.lowercased().contains(keyword)
                || item.subtitle.lowercased().contains(keyword)
        }
    }

    var body: some View {
        ZStack {
            GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
            VStack(spacing: 0) {
                filterSegmented
                    .padding(.top, 8)

                if DeviceLayoutHelper.isIPadRegular(horizontalSizeClass) {
                    ScrollView {
                        if items.isEmpty {
                            EmptyStateView(icon: "music.note.list", text: "这个分类还没有歌单")
                                .padding(.top, 60)
                        } else {
                            LazyVGrid(
                                columns: DeviceLayoutHelper.adaptiveCardColumns(for: horizontalSizeClass, minWidth: 160, maxWidth: 240, spacing: 16),
                                spacing: 18
                            ) {
                                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                    playlistItemCore(item, index: index, isCard: true)
                                        .buttonStyle(GlassPressButtonStyle(scale: 0.97))
                                }
                            }
                            .padding(.horizontal, 28)
                            .padding(.top, 16)
                            .padding(.bottom, 120)
                        }
                    }
                    .frame(maxWidth: DeviceLayoutHelper.contentMaxWidth(for: horizontalSizeClass))
                    .frame(maxWidth: .infinity)
                } else {
                    List {
                        if items.isEmpty {
                            EmptyStateView(icon: "music.note.list", text: "这个分类还没有歌单")
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        } else {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                playlistItemCore(item, index: index, isCard: false)
                                    .listRowInsets(EdgeInsets())
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
        .overlay(alignment: .bottom) {
            if isSelecting {
                batchBar
            }
        }
        .navigationTitle("全部歌单")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "搜索歌单名称"
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 14) {
                    Menu {
                        Button("新建本地歌单") { beginCreate(source: .local) }
                        Button("新建网易云歌单") { beginCreate(source: .netease) }
                        Button("新建 QQ 歌单") { beginCreate(source: .qq) }
                    } label: {
                        Image(systemName: "plus")
                    }
                    if isManaging {
                        Button("完成") {
                            isManaging = false
                            isSelecting = false
                            selectedIDs.removeAll()
                            ATMusicHaptics.tap()
                        }
                        .font(ATMusicFont.appFont(15, .semibold))
                    } else {
                        Button("管理") {
                            isManaging = true
                            isSelecting = true
                            selectedIDs.removeAll()
                            ATMusicHaptics.tap()
                        }
                        .font(ATMusicFont.appFont(15))
                    }
                }
            }
        }
        .alert("新建歌单", isPresented: $showCreateAlert) {
            TextField("歌单名称", text: $newCreateName)
            Button("取消", role: .cancel) {}
            Button("创建") { createPlaylistFromManage() }
        } message: {
            Text("将创建到\(createSourceName)")
        }
        .alert("重命名歌单", isPresented: $showRenameAlert) {
            TextField("歌单名称", text: $renameText)
            Button("取消", role: .cancel) {}
            Button("保存") { saveRename() }
        }
        .alert("编辑简介", isPresented: $showDescAlert) {
            TextField("歌单简介", text: $descText, axis: .vertical)
            Button("取消", role: .cancel) {}
            Button("保存") { saveDescription() }
        }
        .sheet(isPresented: $showCoverPicker) {
            if let id = coverLocalID {
                LocalCoverPickerSheet(playlistID: id)
            }
        }
        .sheet(isPresented: $showMergeSheet) {
            PlaylistMoveTargetSheet(
                songs: mergeSongs,
                title: "合并到歌单",
                actionLabel: "合并"
            ) { target in
                do {
                    _ = try await PlaylistManagementService.shared.addSongs(mergeSongs, to: target)
                    selectedIDs.removeAll()
                    ToastCenter.shared.show("已合并到「\(target.title)」")
                    ATMusicHaptics.success()
                } catch {
                    ToastCenter.shared.show("合并失败：\(error.localizedDescription)")
                }
            } onCreateLocalCopy: {
                _ = await PlaylistManagementService.shared.copyToLocal(songs: mergeSongs, named: "合并歌单")
                selectedIDs.removeAll()
                ToastCenter.shared.show("已合并为本地歌单「合并歌单」")
                ATMusicHaptics.success()
            }
        }
        .confirmationDialog("删除所选 \(selectedIDs.count) 个歌单吗？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) { Task { await deleteSelected() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("云端歌单删除后不可恢复；酷狗歌单不支持删除，会自动跳过。")
        }
        .task { await playlistStore.load(auth: auth, force: false) }
        .refreshable { await playlistStore.load(auth: auth, force: true) }
    }
}


struct LocalMusicBrowserView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var theme: ThemeStore
    @ObservedObject private var store = LocalLibraryStore.shared

    @State private var showImporter = false
    @State private var showManager = false
    @State private var showCreatePlaylist = false
    @State private var newPlaylistName = ""
    @State private var importing = false
    @State private var importMessage = ""

    @State private var albums: [(name: String, artist: String, coverURL: URL?, songs: [Song])] = []
    @State private var artists: [(name: String, coverURL: URL?, songs: [Song])] = []

    private func recomputeLibraryGroups() {
        let grouped = Dictionary(grouping: store.importedSongs) { song in
            let album = song.album.trimmingCharacters(in: .whitespacesAndNewlines)
            return album.isEmpty ? "未知专辑" : album
        }
        albums = grouped.map { name, songs in
            (name, songs.first?.artists ?? "", songs.first?.coverURL, songs)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        var map: [String: [Song]] = [:]
        for song in store.importedSongs {
            let names = song.artists
                .components(separatedBy: " / ")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            for name in names.isEmpty ? ["未知艺术家"] : names {
                map[name, default: []].append(song)
            }
        }
        artists = map.map { name, songs in (name, songs.first?.coverURL, songs) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        ZStack {
            GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
            List {
                if importing {
                    HStack(spacing: 10) {
                        ProgressView().tint(Color.atmusicAmber)
                        Text("正在导入本地音乐…")
                            .font(ATMusicFont.appFont(13))
                            .foregroundStyle(Color.atmusicComment)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else if !importMessage.isEmpty {
                    Text(importMessage)
                        .font(ATMusicFont.appFont(12, .medium))
                        .foregroundStyle(Color.atmusicSage)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                Section("浏览") {
                    NavigationLink {
                        TransferCenterView()
                    } label: {
                        MusicBrowseRow(
                            coverURL: nil,
                            title: "传输中心与离线管理",
                            subtitle: DownloadManager.shared.transferCardSubtitle,
                            systemImage: "arrow.up.arrow.down.circle"
                        )
                    }

                    NavigationLink {
                        LocalFileCollectionView(songs: store.importedSongs)
                    } label: {
                        MusicBrowseRow(
                            coverURL: store.importedSongs.first?.coverURL,
                            title: "文件",
                            subtitle: "\(store.importedSongs.count) 个音频文件",
                            systemImage: "doc.on.doc"
                        )
                    }

                    NavigationLink {
                        LocalAlbumCollectionView(albums: albums)
                    } label: {
                        MusicBrowseRow(
                            coverURL: albums.first?.coverURL,
                            title: "专辑",
                            subtitle: "\(albums.count) 个",
                            systemImage: "square.stack"
                        )
                    }

                    NavigationLink {
                        LocalArtistCollectionView(artists: artists)
                    } label: {
                        MusicBrowseRow(
                            coverURL: artists.first?.coverURL,
                            title: "歌手",
                            subtitle: "\(artists.count) 位",
                            systemImage: "person.2"
                        )
                    }

                    NavigationLink {
                        LocalPlaylistCollectionView()
                    } label: {
                        MusicBrowseRow(
                            coverURL: store.playlists.first?.songs.first?.coverURL,
                            title: "本地歌单",
                            subtitle: "\(store.playlists.count) 个",
                            systemImage: "music.note.list"
                        )
                    }
                }
            }
            .atmusicScrollContentBackgroundHidden()
            .listStyle(.plain)
        }
        .navigationTitle("本地音乐")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showImporter = true
                    } label: {
                        Label("导入音乐", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        newPlaylistName = ""
                        showCreatePlaylist = true
                    } label: {
                        Label("新建本地歌单", systemImage: "plus")
                    }
                    Button {
                        showManager = true
                    } label: {
                        Label("管理本地音乐", systemImage: "folder.badge.gearshape")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showImporter) {
            LocalAudioDocumentPicker { urls in
                showImporter = false
                importFiles(urls)
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showManager) {
            LocalMusicManagementSheet()
                .environmentObject(player)
                .environmentObject(theme)
        }
        .alert("新建本地歌单", isPresented: $showCreatePlaylist) {
            TextField("歌单名称", text: $newPlaylistName)
            Button("创建") {
                let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                _ = store.createPlaylist(name: name)
                ATMusicHaptics.success()
                newPlaylistName = ""
            }
            Button("取消", role: .cancel) {}
        }
        .onAppear { recomputeLibraryGroups() }
        .onChange(of: store.importedSongs) { _ in recomputeLibraryGroups() }
    }

    private func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        importing = true
        importMessage = ""
        Task {
            let report = await LocalAudioImportService.shared.importFiles(urls)
            store.addImportedSongs(report.songs)
            importing = false
            importMessage = report.message
            report.importedCount > 0 ? ATMusicHaptics.success() : ATMusicHaptics.tap()
        }
    }
}

private struct MusicBrowseRow: View {
    let coverURL: URL?
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            if let coverURL {
                CoverImage(url: coverURL, size: 50, cornerRadius: 11)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color.atmusicAmber.opacity(0.10))
                    Image(systemName: systemImage)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.atmusicAmber)
                }
                .frame(width: 50, height: 50)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(ATMusicFont.appFont(14, .semibold))
                    .foregroundStyle(Color.atmusicLabel)
                Text(subtitle)
                    .font(ATMusicFont.appFont(11))
                    .foregroundStyle(Color.atmusicComment)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.atmusicComment.opacity(0.55))
        }
        .frame(minHeight: 58)
    }
}

struct LocalFileCollectionView: View {
    @EnvironmentObject private var player: PlayerManager
    let songs: [Song]
    @State private var query = ""
    @State private var displayedSongs: [Song] = []

    private func recomputeDisplayedSongs() {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sorted = songs.sorted {
            originalFilename(for: $0).localizedStandardCompare(originalFilename(for: $1)) == .orderedAscending
        }
        guard !keyword.isEmpty else {
            displayedSongs = sorted
            return
        }
        displayedSongs = sorted.filter { song in
            originalFilename(for: song).lowercased().contains(keyword)
                || song.name.lowercased().contains(keyword)
                || song.artists.lowercased().contains(keyword)
                || song.album.lowercased().contains(keyword)
        }
    }

    var body: some View {
        ZStack {
            GlassBackdrop()
            List {
                if !displayedSongs.isEmpty {
                    Section {
                        HStack(spacing: 10) {
                            GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                                player.play(songs: displayedSongs, startAt: 0)
                            }
                            GlassButton(title: "随机播放", systemName: "shuffle") {
                                player.play(songs: displayedSongs.shuffled(), startAt: 0)
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

                Section {
                    ForEach(Array(displayedSongs.enumerated()), id: \.element.identityKey) { index, song in
                        Button {
                            ATMusicHaptics.tap()
                            player.play(songs: displayedSongs, startAt: index)
                        } label: {
                            HStack(spacing: 12) {
                                CoverImage(url: song.coverURL, size: 46, cornerRadius: 10)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(originalFilename(for: song))
                                        .font(ATMusicFont.appFont(15))
                                        .foregroundStyle(Color.atmusicLabel)
                                        .lineLimit(1)
                                    Text(fileSubtitle(for: song))
                                        .font(ATMusicFont.appFont(12))
                                        .foregroundStyle(Color.atmusicComment)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Text(song.formattedDuration)
                                    .font(ATMusicFont.appFont(12, .regular, .monospaced))
                                    .foregroundStyle(Color.atmusicComment)
                            }
                            .frame(minHeight: 64)
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(Color.atmusicComment.opacity(0.18))
                                    .frame(height: 0.5)
                                    .padding(.leading, 58)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(GlassPressButtonStyle(scale: 0.985))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
            }
            .atmusicScrollContentBackgroundHidden()
            .listStyle(.plain)
        }
        .navigationTitle("文件")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "搜索本地文件")
        .onAppear { recomputeDisplayedSongs() }
        .onChange(of: query) { _ in recomputeDisplayedSongs() }
    }

    private func originalFilename(for song: Song) -> String {
        guard let path = song.localRelativePath,
              let file = LocalAudioFileManager.shared.file(relativePath: path) else {
            return song.name
        }
        return file.originalFilename
    }

    private func fileSubtitle(for song: Song) -> String {
        let artist = song.artists.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = song.album.trimmingCharacters(in: .whitespacesAndNewlines)
        if !artist.isEmpty, !album.isEmpty { return "\(artist) · \(album)" }
        if !artist.isEmpty { return artist }
        if !album.isEmpty { return album }
        return "本地音频"
    }
}

struct LocalSongCollectionView: View {
    @EnvironmentObject private var player: PlayerManager
    let title: String
    let songs: [Song]
    @State private var query = ""

    private var filteredSongs: [Song] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return songs }
        return songs.filter {
            $0.name.lowercased().contains(keyword)
                || $0.artists.lowercased().contains(keyword)
                || $0.album.lowercased().contains(keyword)
        }
    }

    var body: some View {
        List {
            if !filteredSongs.isEmpty {
                Section {
                    HStack(spacing: 10) {
                        GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                            player.play(songs: filteredSongs, startAt: 0)
                        }
                        GlassButton(title: "随机播放", systemName: "shuffle") {
                            player.play(songs: filteredSongs.shuffled(), startAt: 0)
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            Section {
                ForEach(Array(filteredSongs.enumerated()), id: \.element.identityKey) { index, song in
                    SongCell(song: song, glassRow: false, playbackContext: filteredSongs, playbackIndex: index, onTap: {
                        player.play(songs: filteredSongs, startAt: index)
                    })
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
        }
        .atmusicScrollContentBackgroundHidden()
        .listStyle(.plain)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "搜索歌曲")
    }
}


struct LocalAlbumCollectionView: View {
    let albums: [(name: String, artist: String, coverURL: URL?, songs: [Song])]

    var body: some View {
        List {
            ForEach(albums, id: \.name) { album in
                NavigationLink {
                    LocalSongCollectionView(title: album.name, songs: album.songs)
                } label: {
                    MusicBrowseRow(
                        coverURL: album.coverURL,
                        title: album.name,
                        subtitle: album.artist.isEmpty ? "\(album.songs.count) 首" : "\(album.artist) · \(album.songs.count) 首",
                        systemImage: "square.stack"
                    )
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .atmusicScrollContentBackgroundHidden()
        .listStyle(.plain)
        .navigationTitle("专辑")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct LocalArtistCollectionView: View {
    let artists: [(name: String, coverURL: URL?, songs: [Song])]

    var body: some View {
        List {
            ForEach(artists, id: \.name) { artist in
                NavigationLink {
                    LocalSongCollectionView(title: artist.name, songs: artist.songs)
                } label: {
                    MusicBrowseRow(
                        coverURL: artist.coverURL,
                        title: artist.name,
                        subtitle: "\(artist.songs.count) 首",
                        systemImage: "person.crop.circle"
                    )
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .atmusicScrollContentBackgroundHidden()
        .listStyle(.plain)
        .navigationTitle("歌手")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct LocalPlaylistCollectionView: View {
    @ObservedObject private var store = LocalLibraryStore.shared

    var body: some View {
        List {
            ForEach(store.playlists) { playlist in
                NavigationLink {
                    LocalPlaylistBrowserView(playlistID: playlist.id)
                } label: {
                    MusicBrowseRow(
                        coverURL: playlist.coverURL ?? playlist.songs.first?.coverURL,
                        title: playlist.name,
                        subtitle: "\(playlist.songs.count) 首",
                        systemImage: "music.note.list"
                    )
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .atmusicScrollContentBackgroundHidden()
        .listStyle(.plain)
        .navigationTitle("本地歌单")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct LocalPlaylistBrowserView: View {
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = LocalLibraryStore.shared

    let playlistID: UUID
    @State private var query = ""
    @State private var isEditing = false
    @State private var selectedKeys: Set<String> = []
    @State private var showMoveSheet = false
    @State private var showRenameAlert = false
    @State private var renameText = ""
    @State private var showDeleteConfirm = false
    @State private var showCoverPicker = false
    @State private var showDescriptionAlert = false
    @State private var descriptionText = ""
    @State private var dragStartIndex: Int?
    @State private var dragTargetSelected: Bool = true
    @State private var lastDragIndex: Int?
    @State private var initialSelectedKeysOnDrag: Set<String>? = nil

    private var selectedLocalSongs: [Song] {
        let selected = Set(selectedKeys)
        return songs.filter { selected.contains($0.identityKey) }
    }

    private var displayCoverURL: URL? {
        playlist?.coverURL ?? playlist?.songs.first?.coverURL
    }

    private var playlist: LocalPlaylist? {
        store.playlists.first { $0.id == playlistID }
    }

    private var songs: [Song] {
        guard let playlist else { return [] }
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return playlist.songs }
        return playlist.songs.filter {
            $0.name.lowercased().contains(keyword)
                || $0.artists.lowercased().contains(keyword)
                || $0.album.lowercased().contains(keyword)
        }
    }

    var body: some View {
        Group {
            if isEditing {
                localEditList
            } else if DeviceLayoutHelper.isIPadRegular(horizontalSizeClass) {
                iPadLocalPlaylistLayout
            } else {
                List {
                    if !songs.isEmpty {
                        Section {
                            HStack(spacing: 10) {
                                GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                                    player.play(songs: songs, startAt: 0)
                                }
                                GlassButton(title: "随机播放", systemName: "shuffle") {
                                    player.play(songs: songs.shuffled(), startAt: 0)
                                }
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                    }

                    Section {
                        ForEach(Array(songs.enumerated()), id: \.element.identityKey) { index, song in
                            SongCell(song: song, glassRow: false, playbackContext: songs, playbackIndex: index, onTap: {
                                player.play(songs: songs, startAt: index)
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
        .navigationTitle(playlist?.name ?? "本地歌单")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "搜索歌单歌曲")
        .overlay(alignment: .bottom) {
            if isEditing {
                localEditBottomBar
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if isEditing {
                    Button("完成") {
                        isEditing = false
                        selectedKeys.removeAll()
                    }
                } else {
                    Button {
                        isEditing = true
                    } label: {
                        Label("编辑", systemImage: "pencil")
                    }
                    .accessibilityLabel("编辑歌单")
                }
                Menu {
                    Button {
                        renameText = playlist?.name ?? ""
                        showRenameAlert = true
                    } label: {
                        Label("重命名", systemImage: "character.cursor.ibeam")
                    }
                    Button {
                        descriptionText = playlist?.descriptionText ?? ""
                        showDescriptionAlert = true
                    } label: {
                        Label("编辑简介", systemImage: "text.quote")
                    }
                    Button {
                        showCoverPicker = true
                    } label: {
                        Label("更换封面", systemImage: "photo")
                    }
                    Button {
                        let removed = store.deduplicatePlaylist(id: playlistID)
                        ToastCenter.shared.show(removed == 0 ? "没有发现重复歌曲" : "已去除 \(removed) 首重复歌曲")
                        ATMusicHaptics.success()
                    } label: {
                        Label("去除重复歌曲", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button {
                        let removed = store.removeDeadLocalSongs(id: playlistID)
                        ToastCenter.shared.show(removed == 0 ? "没有失效歌曲" : "已清理 \(removed) 首失效歌曲")
                        ATMusicHaptics.success()
                    } label: {
                        Label("清理失效歌曲", systemImage: "trash")
                    }
                    if SynologyAPI.shared.isLoggedIn {
                        Button {
                            Task { await exportLocalToNAS() }
                        } label: {
                            Label("导出到 NAS 歌单", systemImage: "externaldrive.badge.plus")
                        }
                    }
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("删除歌单", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("更多")
            }
        }
        .sheet(isPresented: $showMoveSheet) {
            PlaylistMoveTargetSheet(
                songs: selectedLocalSongs,
                title: "移到歌单",
                actionLabel: "移入"
            ) { target in
                await moveLocalSelected(to: target)
            }
        }
        .sheet(isPresented: $showCoverPicker) {
            LocalCoverPickerSheet(playlistID: playlistID)
        }
        .alert("重命名歌单", isPresented: $showRenameAlert) {
            TextField("歌单名称", text: $renameText)
            Button("取消", role: .cancel) {}
            Button("保存") {
                let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                store.renamePlaylist(id: playlistID, name: name)
                ToastCenter.shared.show("已重命名为「\(name)」")
                ATMusicHaptics.success()
            }
        }
        .alert("编辑简介", isPresented: $showDescriptionAlert) {
            TextField("歌单简介", text: $descriptionText, axis: .vertical)
            Button("取消", role: .cancel) {}
            Button("保存") {
                store.setDescription(descriptionText, for: playlistID)
                ToastCenter.shared.show("简介已更新")
                ATMusicHaptics.success()
            }
        }
        .confirmationDialog("确定删除本地歌单「\(playlist?.name ?? "")」吗？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                store.deletePlaylist(id: playlistID)
                ToastCenter.shared.show("歌单已删除")
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除歌单记录，歌曲文件本身不受影响。")
        }
    }

    private var iPadLocalPlaylistLayout: some View {
        HStack(alignment: .top, spacing: 32) {
            VStack(alignment: .leading, spacing: 18) {
                if let cover = displayCoverURL {
                    CoverImage(url: cover, size: 240, cornerRadius: 24)
                        .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 10)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(LinearGradient(colors: [Color.orange.opacity(0.85), Color.pink.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 240, height: 240)
                        Image(systemName: "music.note.list")
                            .font(.system(size: 64))
                            .foregroundStyle(.white)
                    }
                    .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 10)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(playlist?.name ?? "本地歌单")
                        .font(ATMusicFont.appFont(22, .bold))
                        .foregroundStyle(Color.atmusicLabel)
                        .lineLimit(2)

                    Text("本地自建歌单")
                        .font(ATMusicFont.appFont(13, .medium))
                        .foregroundStyle(Color.atmusicComment)

                    Text(atmusicSongCountText(songs.count))
                        .font(ATMusicFont.appFont(13))
                        .foregroundStyle(Color.atmusicComment)
                }

                if !songs.isEmpty {
                    HStack(spacing: 12) {
                        GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                            player.play(songs: songs, startAt: 0)
                        }
                        GlassIconButton(systemName: "shuffle", size: 44, active: false) {
                            player.play(songs: songs.shuffled(), startAt: 0)
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
                        Text("歌曲列表 (\(songs.count))")
                            .font(ATMusicFont.appFont(16, .bold))
                            .foregroundStyle(Color.atmusicLabel)
                        Spacer()
                    }
                    .padding(.top, 24)

                    LazyVGrid(columns: DeviceLayoutHelper.songListColumns(for: horizontalSizeClass, spacing: 16), spacing: 8) {
                        ForEach(Array(songs.enumerated()), id: \.element.identityKey) { index, song in
                            SongCell(
                                song: song,
                                glassRow: true,
                                playbackContext: songs,
                                playbackIndex: index,
                                onTap: {
                                    player.play(songs: songs, startAt: index)
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

    // MARK: - 本地编辑态（阶段 2）

    private var localEditList: some View {
        List {
            Section {
                ForEach(Array(songs.enumerated()), id: \.element.identityKey) { index, song in
                    HStack(spacing: 12) {
                        MultiSelectCheckmark(
                            isSelected: selectedKeys.contains(song.identityKey),
                            index: index,
                            rowHeight: 52,
                            onToggle: {
                                toggleLocalSelection(song)
                                ATMusicHaptics.tap()
                            },
                            onDragChange: { startIdx, deltaRows in
                                handleLocalDragChange(startIndex: startIdx, deltaRows: deltaRows)
                            },
                            onDragEnd: {
                                handleLocalDragEnd()
                            }
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(song.name)
                                .font(ATMusicFont.appFont(14, .medium))
                                .foregroundStyle(Color.atmusicLabel)
                                .lineLimit(1)
                            Text(song.artists)
                                .font(ATMusicFont.appFont(11))
                                .foregroundStyle(Color.atmusicComment)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if query.isEmpty {
                            Image(systemName: "line.3.horizontal")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.atmusicComment.opacity(0.55))
                        }
                    }
                    .multiSelectRow(index: index, coordinateSpace: "LocalPlaylistEditListSpace")
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .contentShape(Rectangle())
                    .onTapGesture { toggleLocalSelection(song) }
                }
                .onMove { offsets, destination in
                    guard query.isEmpty else {
                        ToastCenter.shared.show("请先清空搜索，再拖动重排")
                        return
                    }
                    store.reorderSongs(playlistID: playlistID, from: offsets, to: destination)
                }
                .onDelete { offsets in
                    let removing = offsets.map { songs[$0] }
                    store.removeSongs(playlistID: playlistID, songs: removing)
                    let keys = Set(removing.map(\.identityKey))
                    selectedKeys.subtract(keys)
                }
            } header: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("编辑「\(playlist?.name ?? "本地歌单")」")
                        .font(ATMusicFont.appFont(14, .bold))
                        .foregroundStyle(Color.atmusicLabel)
                    Text("点行可勾选，底部栏批量删除、移歌、归档；拖动右侧把手重排（搜索时不可重排）。")
                        .font(ATMusicFont.appFont(11))
                        .foregroundStyle(Color.atmusicComment)
                }
                .textCase(nil)
                .padding(.vertical, 4)
            }

            Section {
                Button(selectedKeys.count == songs.count && !songs.isEmpty ? "取消全选" : "全选") {
                    if selectedKeys.count == songs.count {
                        selectedKeys.removeAll()
                    } else {
                        selectedKeys = Set(songs.map(\.identityKey))
                    }
                }
            }
        }
        .atmusicScrollContentBackgroundHidden()
        .listStyle(.plain)
        .environment(\.editMode, .constant(.active))

    }

    private var localEditBottomBar: some View {
        HStack(spacing: 14) {
            Text(selectedKeys.isEmpty ? "未选择歌曲" : "已选 \(selectedKeys.count) 首")
                .font(ATMusicFont.appFont(12, .medium))
                .foregroundStyle(Color.atmusicComment)
            Spacer()
            Button("删除") {
                store.removeSongs(playlistID: playlistID, songs: selectedLocalSongs)
                selectedKeys.removeAll()
                ToastCenter.shared.show("已删除所选歌曲")
            }
            .disabled(selectedKeys.isEmpty)
            Button("移到歌单") {
                showMoveSheet = true
            }
            .disabled(selectedKeys.isEmpty)
            if SynologyAPI.shared.isLoggedIn {
                Button("归档 NAS") {
                    DownloadManager.shared.startBatchUploadToNAS(songs: selectedLocalSongs)
                    selectedKeys.removeAll()
                }
                .disabled(selectedKeys.isEmpty)
            }
        }
        .font(ATMusicFont.appFont(13, .semibold))
        .foregroundStyle(Color.atmusicAmber)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
    }

    private func toggleLocalSelection(_ song: Song) {
        if selectedKeys.contains(song.identityKey) {
            selectedKeys.remove(song.identityKey)
        } else {
            selectedKeys.insert(song.identityKey)
        }
    }

    private func handleLocalDragChange(startIndex: Int, deltaRows: Int) {
        let keys = songs.map(\.identityKey)
        guard startIndex >= 0, startIndex < keys.count else { return }
        if dragStartIndex == nil {
            dragStartIndex = startIndex
            initialSelectedKeysOnDrag = selectedKeys
            let willSelect = !selectedKeys.contains(keys[startIndex])
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
        selectedKeys = updated
    }

    private func handleLocalDragEnd() {
        dragStartIndex = nil
        initialSelectedKeysOnDrag = nil
        lastDragIndex = nil
    }

    private func moveLocalSelected(to target: PlaylistEditTarget) async {
        let moving = selectedLocalSongs
        guard !moving.isEmpty else { return }
        do {
            _ = try await PlaylistManagementService.shared.moveSongs(moving, from: .local(playlistID), to: target)
            selectedKeys.removeAll()
            ToastCenter.shared.show("已移到「\(target.title)」")
            ATMusicHaptics.success()
        } catch {
            ToastCenter.shared.show("操作失败：\(error.localizedDescription)")
        }
    }

    private func exportLocalToNAS() async {
        guard let playlist, !playlist.songs.isEmpty else {
            ToastCenter.shared.show("歌单是空的")
            return
        }
        do {
            _ = try await PlaylistManagementService.shared.exportToNAS(name: playlist.name, songs: playlist.songs)
            ToastCenter.shared.show("已导出到 NAS 歌单「\(playlist.name)」")
            ATMusicHaptics.success()
        } catch {
            ToastCenter.shared.show("导出失败：\(error.localizedDescription)")
        }
    }
}

struct LocalCoverPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = LocalLibraryStore.shared

    let playlistID: UUID

    private var playlist: LocalPlaylist? {
        store.playlists.first { $0.id == playlistID }
    }

    private var coverOptions: [(url: URL, songName: String)] {
        guard let playlist else { return [] }
        var seen = Set<URL>()
        var result: [(URL, String)] = []
        for song in playlist.songs {
            guard let url = song.coverURL, seen.insert(url).inserted else { continue }
            result.append((url, song.name))
        }
        return result
    }

    var body: some View {
        ATMusicNavigationStack {
            List {
                Section {
                    Button("恢复默认（取首歌封面）") {
                        store.setCoverURL(nil, for: playlistID)
                        ToastCenter.shared.show("封面已恢复默认")
                        dismiss()
                    }
                }
                if !coverOptions.isEmpty {
                    Section("从歌单歌曲封面里选") {
                        ForEach(coverOptions, id: \.url) { option in
                            Button {
                                store.setCoverURL(option.url, for: playlistID)
                                ToastCenter.shared.show("封面已更换")
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    CoverImage(url: option.url, size: 44, cornerRadius: 10)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("使用这张封面")
                                            .font(ATMusicFont.appFont(14, .medium))
                                            .foregroundStyle(Color.atmusicLabel)
                                        Text(option.songName)
                                            .font(ATMusicFont.appFont(11))
                                            .foregroundStyle(Color.atmusicComment)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if playlist?.coverURL == option.url {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Color.atmusicAmber)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("更换封面")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

struct SynologyFileLibraryView: View {
    @ObservedObject private var synology = SynologyAPI.shared

    var body: some View {
        if synology.isLoggedIn {
            SynologyFolderView(folderID: nil, title: "NAS 文件")
        } else {
            EmptyStateView(
                icon: "externaldrive.badge.exclamationmark",
                text: "尚未连接群晖 NAS\n请前往“我的” → “账号与登录”完成连接"
            )
            .navigationTitle("NAS 文件")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}


// MARK: - 统一我喜欢的音乐详情页

private struct FavoriteRowItem: Identifiable {
    let index: Int
    let song: Song
    var id: String { "\(index)_\(song.identityKey)" }
}

struct UnifiedFavoritesDetailView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ObservedObject private var localStore = LocalLibraryStore.shared
    @ObservedObject private var favorites = FavoritesStore.shared
    @State private var query = ""
    @State private var selectedPlatformFilter: String = "全部"
    @State private var isSyncing = false
    @State private var isMultiSelecting = false
    @State private var selectedSongKeys: Set<String> = []
    @State private var dragStartIndex: Int? = nil
    @State private var initialSelectedKeysOnDrag: Set<String>? = nil
    @State private var dragTargetSelected = true
    @State private var lastDragIndex: Int? = nil
    @State private var showBatchAddToPlaylist = false
    @State private var displayedSongs: [Song] = []
    @State private var renderLimit: Int = 100
    @State private var dragCachedKeys: [String] = []

    private var selectedSongs: [Song] {
        displayedSongs.filter { selectedSongKeys.contains($0.identityKey) }
    }

    private var visibleFavoriteItems: [FavoriteRowItem] {
        let count = min(renderLimit, displayedSongs.count)
        guard count > 0 else { return [] }
        return (0..<count).map { FavoriteRowItem(index: $0, song: displayedSongs[$0]) }
    }

    private func loadMoreSongsIfNeeded(at index: Int) {
        if index >= renderLimit - 25 && renderLimit < displayedSongs.count {
            renderLimit = min(renderLimit + 120, displayedSongs.count)
        }
    }

    private func updateDisplayedSongs() {
        let base = filteredByPlatformSongs
        let kw = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let result: [Song]
        if kw.isEmpty {
            result = base
        } else {
            result = base.filter {
                $0.name.lowercased().contains(kw)
                    || $0.artists.lowercased().contains(kw)
                    || $0.album.lowercased().contains(kw)
            }
        }
        displayedSongs = result
        renderLimit = min(100, max(result.count, 0))
    }

    private func toggleSelection(_ song: Song) {
        if selectedSongKeys.contains(song.identityKey) {
            selectedSongKeys.remove(song.identityKey)
        } else {
            selectedSongKeys.insert(song.identityKey)
        }
    }

    private func handleDragChange(startIndex: Int, deltaRows: Int) {
        if dragStartIndex == nil {
            dragStartIndex = startIndex
            initialSelectedKeysOnDrag = selectedSongKeys
            dragCachedKeys = displayedSongs.map(\.identityKey)
            let willSelect = startIndex < dragCachedKeys.count ? !selectedSongKeys.contains(dragCachedKeys[startIndex]) : true
            dragTargetSelected = willSelect
            lastDragIndex = nil
        }
        let keys = dragCachedKeys
        guard startIndex >= 0, startIndex < keys.count else { return }
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
        dragCachedKeys.removeAll()
    }

    @ViewBuilder
    private func favoriteSongRow(song: Song, index: Int) -> some View {
        SongCell(
            song: song,
            playbackIndex: index,
            subtitleText: "\(song.artists) · \(song.album)",
            favoriteToggle: {
                Task {
                    await favorites.toggleFavorite(song)
                }
            },
            onTap: {
                player.play(songs: displayedSongs, startAt: index)
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
        .onAppear {
            loadMoreSongsIfNeeded(at: index)
        }
    }

    private var allSongs: [Song] {
        favorites.unifiedFavoriteSongs()
    }

    private var filteredByPlatformSongs: [Song] {
        switch selectedPlatformFilter {
        case "本地":
            return allSongs.filter { $0.source == .local }
        case "网易云":
            return allSongs.filter { $0.source == .netease }
        case "QQ":
            return allSongs.filter { $0.source == .qq }
        case "酷狗":
            return allSongs.filter { $0.source == .kugou }
        case "NAS":
            return allSongs.filter { $0.source == .synology }
        case "Subsonic":
            return allSongs.filter { $0.source == .subsonic }
        case "Jellyfin":
            return allSongs.filter { $0.source == .jellyfin }
        case "WebDAV":
            return allSongs.filter { $0.source == .webdav }
        default:
            return allSongs
        }
    }



    var body: some View {
        ZStack {
            GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
            Group {
                if DeviceLayoutHelper.isIPadRegular(horizontalSizeClass) {
                    iPadFavoritesLayout
                } else {
                    List {
                        Section {
                            platformFilterBar
                                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }

                        if !displayedSongs.isEmpty {
                            Section {
                                HStack(spacing: 10) {
                                    GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                                        player.play(songs: displayedSongs, startAt: 0)
                                    }
                                    GlassButton(title: "随机播放", systemName: "shuffle") {
                                        player.play(songs: displayedSongs.shuffled(), startAt: 0)
                                    }
                                }
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                            }
                        }

                        Section {
                            ForEach(visibleFavoriteItems) { item in
                                favoriteSongRow(song: item.song, index: item.index)
                                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                            }
                        } header: {
                            HStack {
                                Text("\(displayedSongs.count) 首歌曲")
                                    .font(ATMusicFont.appFont(12, .medium))
                                    .foregroundStyle(Color.atmusicComment)
                                Spacer()
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .searchable(text: $query, prompt: "搜索收藏歌曲")
                    .atmusicScrollContentBackgroundHidden()
                }
            }

            if isMultiSelecting && !selectedSongKeys.isEmpty {
                VStack {
                    Spacer()
                    UniversalBatchActionBar(
                        selectedCount: selectedSongKeys.count,
                        totalCount: displayedSongs.count,
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
                            BatchActionItem(id: "unfavorite", title: "取消收藏", systemImage: "heart.slash", tint: Color.red) {
                                let songs = selectedSongs
                                Task {
                                    await favorites.removeFavorites(songs)
                                }
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
        .navigationTitle(isMultiSelecting ? (selectedSongKeys.isEmpty ? "选择歌曲" : "已选 \(selectedSongKeys.count) 首") : "我喜欢的音乐")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isMultiSelecting {
                    HStack(spacing: 12) {
                        Button(selectedSongKeys.count == displayedSongs.count && !displayedSongs.isEmpty ? "取消全选" : "全选") {
                            ATMusicHaptics.tap()
                            if selectedSongKeys.count == displayedSongs.count {
                                selectedSongKeys.removeAll()
                            } else {
                                selectedSongKeys = Set(displayedSongs.map(\.identityKey))
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
                        .disabled(displayedSongs.isEmpty)

                        Button {
                            Task {
                                isSyncing = true
                                ATMusicHaptics.tap()
                                await favorites.syncAllFromCloud()
                                isSyncing = false
                                ToastCenter.shared.show("全平台红心同步已完成")
                                ATMusicHaptics.success()
                            }
                        } label: {
                            Label("同步云端红心", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(isSyncing)

                        Button {
                            DownloadManager.shared.startBatchDownload(songs: displayedSongs)
                        } label: {
                            Label("下载全部歌曲", systemImage: "arrow.down.circle")
                        }
                        .disabled(displayedSongs.isEmpty)

                        if SynologyAPI.shared.isLoggedIn {
                            Button {
                                DownloadManager.shared.startBatchUploadToNAS(songs: displayedSongs)
                            } label: {
                                Label("全单归档至群晖 NAS", systemImage: "externaldrive.badge.plus")
                            }
                            .disabled(displayedSongs.isEmpty)
                        }
                    } label: {
                        if isSyncing {
                            ProgressView().tint(Color.atmusicAmber)
                        } else {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                    .accessibilityLabel("更多操作")
                }
            }
        }
        .sheet(isPresented: $showBatchAddToPlaylist) {
            AddToPlaylistSheet(songs: selectedSongs)
                .environmentObject(theme)
        }
        .task {
            await favorites.syncAllFromCloud()
            updateDisplayedSongs()
        }
        .refreshable {
            await favorites.syncAllFromCloud()
            updateDisplayedSongs()
        }
        .onAppear {
            updateDisplayedSongs()
        }
        .onChange(of: query) { _ in
            updateDisplayedSongs()
        }
        .onChange(of: selectedPlatformFilter) { _ in
            updateDisplayedSongs()
        }
        .onReceive(favorites.objectWillChange) { _ in
            DispatchQueue.main.async {
                updateDisplayedSongs()
            }
        }
    }

    private var platformFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(["全部", "本地", "网易云", "QQ", "酷狗", "NAS", "Subsonic", "Jellyfin", "WebDAV"], id: \.self) { item in
                    let isSelected = selectedPlatformFilter == item
                    let count: Int = {
                        switch item {
                        case "本地": return allSongs.filter { $0.source == .local }.count
                        case "网易云": return allSongs.filter { $0.source == .netease }.count
                        case "QQ": return allSongs.filter { $0.source == .qq }.count
                        case "酷狗": return allSongs.filter { $0.source == .kugou }.count
                        case "NAS": return allSongs.filter { $0.source == .synology }.count
                        case "Subsonic": return allSongs.filter { $0.source == .subsonic }.count
                        case "Jellyfin": return allSongs.filter { $0.source == .jellyfin }.count
                        case "WebDAV": return allSongs.filter { $0.source == .webdav }.count
                        default: return allSongs.count
                        }
                    }()
                    Button {
                        ATMusicHaptics.select()
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedPlatformFilter = item
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(item)
                            Text("\(count)")
                                .font(ATMusicFont.appFont(10, .bold))
                                .opacity(0.8)
                        }
                        .font(ATMusicFont.appFont(13, isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.white : Color.atmusicComment)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background {
                            if isSelected {
                                Capsule().fill(Color.atmusicAmber)
                            } else {
                                Capsule().fill(Color.primary.opacity(0.06))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }

    private var iPadFavoritesLayout: some View {
        GeometryReader { proxy in
            let availableWidth = proxy.size.width
            if availableWidth >= 740 {
                wideFavoritesLayout(availableWidth: availableWidth)
            } else {
                compactFavoritesLayout(availableWidth: availableWidth)
            }
        }
    }

    private func wideFavoritesLayout(availableWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 28) {
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
                        .frame(width: 220, height: 220)
                        .shadow(color: Color.red.opacity(0.28), radius: 18, x: 0, y: 10)

                    let covers = Array(allSongs.compactMap(\.coverURL).prefix(4))
                    if covers.count >= 4 {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 4) {
                            ForEach(0..<4, id: \.self) { idx in
                                CoverImage(url: covers[idx], size: 100, cornerRadius: 10)
                            }
                        }
                        .frame(width: 206, height: 206)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(Color.black.opacity(0.25))
                            Image(systemName: "heart.fill")
                                .font(.system(size: 60, weight: .bold))
                                .foregroundStyle(.white)
                                .shadow(radius: 6)
                        }
                    } else {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 76, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(radius: 6)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("我喜欢的音乐")
                        .font(ATMusicFont.appFont(22, .bold))
                        .foregroundStyle(Color.atmusicLabel)

                    Text("全平台与本地收藏聚合")
                        .font(ATMusicFont.appFont(13, .medium))
                        .foregroundStyle(Color.atmusicComment)

                    Text(atmusicSongCountText(displayedSongs.count))
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(Color.atmusicComment)
                }

                if !displayedSongs.isEmpty {
                    HStack(spacing: 12) {
                        GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                            player.play(songs: displayedSongs, startAt: 0)
                        }
                        GlassIconButton(systemName: "shuffle", size: 44, active: false) {
                            player.play(songs: displayedSongs.shuffled(), startAt: 0)
                        }
                    }
                }

                platformFilterBar
                    .padding(.horizontal, -16)

                Spacer(minLength: 0)
            }
            .frame(width: 240)
            .padding(.leading, 28)
            .padding(.top, 24)

            let rightWidth = availableWidth - 240 - 28 - 28 - 28
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("歌曲列表 (\(displayedSongs.count))")
                            .font(ATMusicFont.appFont(16, .bold))
                            .foregroundStyle(Color.atmusicLabel)
                        Spacer()
                    }
                    .padding(.top, 24)

                    LazyVGrid(columns: DeviceLayoutHelper.songListColumns(forAvailableWidth: rightWidth, minWidth: 280, spacing: 14), spacing: 8) {
                        ForEach(visibleFavoriteItems) { item in
                            favoriteSongRow(song: item.song, index: item.index)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.primary.opacity(0.03))
                            }
                        }
                    }
                }
                .padding(.trailing, 28)
                .padding(.bottom, 120)
            }
        }
    }

    private func compactFavoritesLayout(availableWidth: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color(red: 0.94, green: 0.22, blue: 0.35), Color(red: 0.88, green: 0.14, blue: 0.45)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 120, height: 120)

                        Image(systemName: "heart.fill")
                            .font(.system(size: 48, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(radius: 4)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("我喜欢的音乐")
                            .font(ATMusicFont.appFont(18, .bold))
                            .foregroundStyle(Color.atmusicLabel)

                        Text("全平台与本地收藏聚合 · \(displayedSongs.count) 首")
                            .font(ATMusicFont.appFont(12, .medium))
                            .foregroundStyle(Color.atmusicComment)

                        Spacer(minLength: 4)

                        HStack(spacing: 10) {
                            GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                                player.play(songs: displayedSongs, startAt: 0)
                            }
                            GlassIconButton(systemName: "shuffle", size: 38, active: false) {
                                player.play(songs: displayedSongs.shuffled(), startAt: 0)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                platformFilterBar
                    .padding(.horizontal, 4)

                HStack {
                    Text("歌曲列表 (\(displayedSongs.count))")
                        .font(ATMusicFont.appFont(16, .bold))
                        .foregroundStyle(Color.atmusicLabel)
                    Spacer()
                }
                .padding(.horizontal, 20)

                LazyVGrid(columns: DeviceLayoutHelper.songListColumns(forAvailableWidth: availableWidth - 40, minWidth: 280, spacing: 12), spacing: 6) {
                    ForEach(visibleFavoriteItems) { item in
                        favoriteSongRow(song: item.song, index: item.index)
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
}
