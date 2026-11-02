import SwiftUI

/// 歌单内排序方式
enum PlaylistSortMode: String, CaseIterable, Identifiable {
    case original = "默认"
    case name = "歌名"
    case duration = "时长"
    var id: String { rawValue }
}

private struct PlaylistRowItem: Identifiable {
    let index: Int
    let song: Song
    var id: String { "\(index)_\(song.identityKey)" }
}

struct PlaylistView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ObservedObject private var favorites = FavoritesStore.shared
    @ObservedObject private var favoritePlaylists = FavoritePlaylistStore.shared

    let playlist: Playlist
    @State private var displayName: String
    @State private var isEditing = false
    @State private var selectedKeys: Set<String> = []
    @State private var orderVersion = 0
    @State private var showMoveSheet = false
    @State private var showRenameAlert = false
    @State private var renameText = ""
    @State private var showDescriptionAlert = false
    @State private var descriptionText = ""
    @State private var showDeletePlaylistConfirm = false

    init(playlist: Playlist) {
        self.playlist = playlist
        _displayName = State(initialValue: playlist.name)
    }

    private var capabilities: PlaylistCapabilities { PlaylistCapabilities.forSource(playlist.source) }
    private var playlistKey: String { playlist.identityKey }
    private var selectedSongs: [Song] {
        let selected = Set(selectedKeys)
        return displayedTracks.filter { selected.contains($0.identityKey) }
    }
    @State private var tracks: [Song] = []
    @State private var displayedTracks: [Song] = []
    @State private var renderLimit: Int = 100
    @State private var dragCachedKeys: [String] = []

    private var visibleTrackItems: [PlaylistRowItem] {
        let count = min(renderLimit, displayedTracks.count)
        guard count > 0 else { return [] }
        return (0..<count).map { PlaylistRowItem(index: $0, song: displayedTracks[$0]) }
    }

    private func loadMoreTracksIfNeeded(at index: Int) {
        if index >= renderLimit - 25 && renderLimit < displayedTracks.count {
            renderLimit = min(renderLimit + 120, displayedTracks.count)
        }
    }

    private func updateDisplayedTracks() {
        var list = tracks
        if sortMode == .original {
            list = PlaylistSongOrderStore.shared.apply(to: list, playlistKey: playlistKey)
        }
        let kw = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !kw.isEmpty {
            list = list.filter { song in
                song.name.lowercased().contains(kw)
                    || song.artists.lowercased().contains(kw)
                    || song.album.lowercased().contains(kw)
            }
        }
        switch sortMode {
        case .original: break
        case .name:
            list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .duration:
            list.sort { $0.duration < $1.duration }
        }
        displayedTracks = list
        renderLimit = min(100, max(list.count, 0))
    }
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var resolvedCoverURL: URL?
    @State private var resolvedCreatorName: String?
    @State private var resolvedDescriptionText: String?
    @State private var resolvedPopularity: Int?
    @State private var searchText = ""
    @State private var sortMode: PlaylistSortMode = .original
    @State private var showInfo = false
    @State private var isBatchDownloading = false
    @State private var isBatchUploading = false
    @State private var showNASPlaylistEditor = false
    @State private var showNASPlaylistDelete = false
    @State private var dragStartIndex: Int?
    @State private var dragTargetSelected: Bool = true
    @State private var lastDragIndex: Int?
    @State private var initialSelectedKeysOnDrag: Set<String>? = nil

    @MainActor
    private func batchDownloadPlaylist() {
        batchDownload(songs: displayedTracks)
    }

    @MainActor
    private func batchDownloadSelected() {
        batchDownload(songs: selectedSongs)
    }

    @MainActor
    private func batchDownload(songs: [Song]) {
        guard !songs.isEmpty else { return }
        isBatchDownloading = true
        ATMusicHaptics.medium()
        let quality: DownloadQuality
        let downloadQualityRaw = UserDefaults.standard.string(forKey: ThirdPartyAudioQuality.downloadStorageKey) ?? ThirdPartyAudioQuality.kb320.rawValue
        if UserDefaults.standard.object(forKey: ThirdPartyAudioQuality.downloadStorageKey) == nil {
            quality = ThirdPartyAudioQuality.current
        } else {
            quality = DownloadQuality(sourceValue: downloadQualityRaw) ?? ThirdPartyAudioQuality.current
        }
        DownloadManager.shared.startBatchDownload(songs: songs, quality: quality)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            isBatchDownloading = false
        }
    }

    @MainActor
    private func batchUploadPlaylistToNAS() {
        batchUploadToNAS(songs: displayedTracks)
    }

    @MainActor
    private func batchUploadSelectedToNAS() {
        batchUploadToNAS(songs: selectedSongs)
    }

    @MainActor
    private func batchUploadToNAS(songs: [Song]) {
        guard !songs.isEmpty, !isBatchUploading else { return }
        isBatchUploading = true
        ATMusicHaptics.medium()
        DownloadManager.shared.startBatchUploadToNAS(songs: songs)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            isBatchUploading = false
        }
    }
    @AppStorage("atmusic.homeHeaderHideSort") private var hideSortButton = false
    @AppStorage("atmusic.uiStyle") private var uiStyleRaw = ATMusicUIStyle.liquid.rawValue

    private var isNativeClean: Bool {
        ATMusicUIStyle(rawValue: uiStyleRaw) == .nativeClean
    }

    private var playlistPopularityText: String? {
        guard let value = resolvedPopularity ?? playlist.popularity, value > 0 else { return nil }
        if value >= 100_000_000 { return String(format: "播放 %.1f 亿", Double(value) / 100_000_000) }
        if value >= 10_000 { return String(format: "播放 %.1f 万", Double(value) / 10_000) }
        return "播放 \(value)"
    }

    private var displayCreatorName: String {
        let resolved = resolvedCreatorName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !resolved.isEmpty { return resolved }
        let source = playlist.creatorName.trimmingCharacters(in: .whitespacesAndNewlines)
        return source.isEmpty ? playlist.source.atmusicDisplayName : source
    }

    private var displayDescription: String? {
        let resolved = resolvedDescriptionText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !resolved.isEmpty { return resolved }
        let source = playlist.descriptionText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return source.isEmpty ? nil : source
    }

    private var cacheAccountID: String {
        switch playlist.source {
        case .netease:
            return "\(auth.user?.uid ?? 0)"
        case .qq:
            let qqAuth = QQMusicAuth.shared
            return qqAuth.rawUin.isEmpty ? qqAuth.playlistUin : qqAuth.rawUin
        case .kugou:
            return KugouMusicAuth.shared.userId
        case .local:
            return "local"
        case .synology:
            return SynologyAPI.shared.account
        case .subsonic:
            return SubsonicAPI.shared.account
        case .jellyfin:
            return JellyfinAPI.shared.account
        case .webdav:
            return WebDAVAPI.shared.account
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
                        Task { await load(force: true) }
                    }
                } else if isEditing {
                    editList
                } else if DeviceLayoutHelper.isIPadRegular(horizontalSizeClass) {
                    iPadPlaylistLayout
                } else {
                    List {
                        header
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        Section {
                            ForEach(visibleTrackItems) { item in
                                SongCell(song: item.song, playbackIndex: item.index, onTap: {
                                    player.play(songs: displayedTracks, startAt: item.index)
                                })
                                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .onAppear {
                                    loadMoreTracksIfNeeded(at: item.index)
                                }
                            }
                        } header: {
                            HStack(spacing: 6) {
                                Text("歌曲")
                                    .font(ATMusicFont.appFont(16, .bold))
                                Text(atmusicSongCountText(displayedTracks.count))
                                    .font(ATMusicFont.appFont(12, .medium))
                                    .foregroundStyle(Color.atmusicComment)
                                Spacer()
                            }
                            .textCase(nil)
                            .padding(.top, 10)
                            .padding(.bottom, 4)
                        }
                    }
                    .atmusicScrollContentBackgroundHidden()
                    .listStyle(.plain)
                    }
            }
            }
            .overlay(alignment: .bottom) {
                if isEditing {
                    editBottomBar
                }
            }
            .navigationTitle(displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if isEditing {
                        Button(selectedKeys.count == tracks.count && !tracks.isEmpty ? "取消全选" : "全选") {
                            ATMusicHaptics.tap()
                            if selectedKeys.count == tracks.count {
                                selectedKeys.removeAll()
                            } else {
                                selectedKeys = Set(tracks.map(\.identityKey))
                            }
                        }
                        .font(ATMusicFont.appFont(13, .semibold))
                        .foregroundStyle(Color.atmusicAmber)

                        Button("完成") {
                            isEditing = false
                            selectedKeys.removeAll()
                            ATMusicHaptics.tap()
                        }
                        .font(ATMusicFont.appFont(13, .semibold))
                    } else {
                        Menu {
                            Button {
                                if playlist.source == .synology {
                                    showNASPlaylistEditor = true
                                } else {
                                    isEditing = true
                                }
                                ATMusicHaptics.tap()
                            } label: {
                                Label("编辑歌单", systemImage: "pencil")
                            }

                            Button {
                                favoritePlaylists.toggle(playlist)
                                ATMusicHaptics.select()
                            } label: {
                                let isFav = favoritePlaylists.isFavorite(playlist)
                                Label(isFav ? "取消收藏歌单" : "收藏歌单", systemImage: isFav ? "heart.slash" : "heart")
                            }
                        if !hideSortButton {
                            Picker("排序", selection: $sortMode) {
                                ForEach(PlaylistSortMode.allCases) { mode in
                                    Text(LocalizedStringKey(mode.rawValue)).tag(mode)
                                }
                            }
                        }

                        if playlist.source == .netease {
                            Button {
                                renameText = displayName
                                showRenameAlert = true
                            } label: {
                                Label("重命名歌单", systemImage: "character.cursor.ibeam")
                            }
                            Button {
                                descriptionText = displayDescription ?? ""
                                showDescriptionAlert = true
                            } label: {
                                Label("编辑简介", systemImage: "text.quote")
                            }
                            Button {
                                Task { await deduplicate() }
                            } label: {
                                Label("去除重复歌曲", systemImage: "arrow.triangle.2.circlepath")
                            }
                        }

                        if playlist.source != .synology {
                            Button {
                                Task { await exportToLocal() }
                            } label: {
                                Label("转存为本地歌单", systemImage: "square.and.arrow.down")
                            }
                        }

                        if playlist.source == .netease || playlist.source == .qq {
                            Button(role: .destructive) {
                                showDeletePlaylistConfirm = true
                            } label: {
                                Label("删除歌单", systemImage: "trash")
                            }
                        }

                        Button {
                            batchDownloadPlaylist()
                        } label: {
                            Label(isBatchDownloading ? "正在加入下载..." : "下载全部歌曲", systemImage: "arrow.down.circle")
                        }
                        .disabled(displayedTracks.isEmpty || isBatchDownloading)

                        if playlist.source == .synology {
                            Button {
                                showNASPlaylistEditor = true
                            } label: {
                                Label("管理 NAS 歌单曲目", systemImage: "slider.horizontal.3")
                            }
                            Button(role: .destructive) {
                                showNASPlaylistDelete = true
                            } label: {
                                Label("删除 NAS 歌单", systemImage: "trash")
                            }
                        }

                        if SynologyAPI.shared.isLoggedIn && playlist.source != .synology {
                            Button {
                                batchUploadPlaylistToNAS()
                            } label: {
                                Label(isBatchUploading ? "正在加入归档..." : "全单归档至群晖 NAS", systemImage: "externaldrive.badge.plus")
                            }
                            .disabled(displayedTracks.isEmpty || isBatchUploading)
                        }

                        if displayDescription != nil || playlistPopularityText != nil {
                            Button {
                                ATMusicHaptics.tap()
                                showInfo = true
                            } label: {
                                Label("歌单信息", systemImage: "info.circle")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("更多")
                    }
                }
            }
            .sheet(isPresented: $showNASPlaylistEditor) {
                NASPlaylistEditorSheet(playlist: playlist) { updated in
                    Task { await load(force: true) }
                    if updated == nil {
                        Task { await MainActor.run { dismissAfterDelete() } }
                    }
                }
            }
            .confirmationDialog("删除这个 NAS 歌单？", isPresented: $showNASPlaylistDelete, titleVisibility: .visible) {
                Button("删除「\(playlist.name)」", role: .destructive) {
                    Task {
                        try? await SynologyAPI.shared.deleteNASPlaylist(id: playlist.synologyPlaylistId ?? "\(playlist.id)")
                        SynologyAPI.shared.invalidateAllFolderCaches()
                        await MainActor.run {
                            ToastCenter.shared.show("歌单已删除")
                            dismissAfterDelete()
                        }
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("歌单会从 Audio Station 移除，歌曲文件本身不受影响。")
            }
            .sheet(isPresented: $showMoveSheet) {
                PlaylistMoveTargetSheet(
                    songs: selectedSongs,
                    title: capabilities.canRemoveSongs ? "移到歌单" : "复制到歌单",
                    actionLabel: capabilities.canRemoveSongs ? "移入" : "复制"
                ) { target in
                    await moveSelectedSongs(to: target)
                } onCreateLocalCopy: {
                    await copySelectedToLocal()
                }
            }
            .alert("重命名歌单", isPresented: $showRenameAlert) {
                TextField("歌单名称", text: $renameText)
                Button("取消", role: .cancel) {}
                Button("保存") { Task { await renamePlaylist() } }
            }
            .alert("编辑简介", isPresented: $showDescriptionAlert) {
                TextField("歌单简介", text: $descriptionText, axis: .vertical)
                Button("取消", role: .cancel) {}
                Button("保存") { Task { await saveDescription() } }
            }
            .confirmationDialog("确定删除歌单「\(displayName)」吗？", isPresented: $showDeletePlaylistConfirm, titleVisibility: .visible) {
                Button("删除", role: .destructive) { Task { await deletePlaylist() } }
                Button("取消", role: .cancel) {}
            } message: {
                Text("云端歌单删除后不可恢复，本地收藏记录不受影响。")
            }
            .sheet(isPresented: $showInfo) {
                PlaylistInfoSheet(
                    name: displayName,
                    source: playlist.source,
                    creator: displayCreatorName,
                    songCount: tracks.isEmpty ? playlist.trackCount : tracks.count,
                    popularity: playlistPopularityText,
                    description: displayDescription
                )
            }
        .task {
            if let raw = PlaylistSortPreferenceStore.shared.sortModeRaw(for: playlistKey),
               let mode = PlaylistSortMode(rawValue: raw) {
                sortMode = mode
            }
            await load()
        }
        .onChange(of: sortMode) { newValue in
            PlaylistSortPreferenceStore.shared.save(sortModeRaw: newValue.rawValue, for: playlistKey)
            updateDisplayedTracks()
        }
        .onChange(of: searchText) { _ in
            updateDisplayedTracks()
        }
        .onChange(of: orderVersion) { _ in
            updateDisplayedTracks()
        }
        .onChange(of: tracks) { _ in
            updateDisplayedTracks()
        }
        .onAppear {
            if displayedTracks.isEmpty && !tracks.isEmpty {
                updateDisplayedTracks()
            }
        }
    }

    private var iPadPlaylistLayout: some View {
        GeometryReader { proxy in
            let availableWidth = proxy.size.width
            if availableWidth >= 740 {
                widePlaylistLayout(availableWidth: availableWidth)
            } else {
                compactPlaylistLayout(availableWidth: availableWidth)
            }
        }
    }

    private func widePlaylistLayout(availableWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 28) {
            // 左栏：固定封面与歌单主要信息 (类似 Apple Music iPad 宽屏两栏)
            VStack(alignment: .leading, spacing: 18) {
                CoverImage(url: resolvedCoverURL ?? playlist.coverURL, size: 220, cornerRadius: 20)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(width: 220, height: 220)
                    .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 8)

                VStack(alignment: .leading, spacing: 6) {
                    Text(displayName)
                        .font(ATMusicFont.appFont(22, .bold))
                        .foregroundStyle(Color.atmusicLabel)
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        SourceBadgeView(source: playlist.source)
                        Text(displayCreatorName)
                            .font(ATMusicFont.appFont(13, .medium))
                            .foregroundStyle(Color.atmusicComment)
                    }

                    Text(atmusicSongCountText(tracks.isEmpty ? playlist.trackCount : tracks.count))
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(Color.atmusicComment.opacity(0.85))

                    if let popularity = playlistPopularityText {
                        Text(popularity)
                            .font(ATMusicFont.appFont(12))
                            .foregroundStyle(Color.atmusicAmber)
                    }
                }

                HStack(spacing: 12) {
                    GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                        guard !displayedTracks.isEmpty else { return }
                        player.play(songs: displayedTracks, startAt: 0)
                    }
                    .disabled(displayedTracks.isEmpty)

                    GlassIconButton(systemName: "shuffle", size: 44, active: false) {
                        guard !displayedTracks.isEmpty else { return }
                        player.play(songs: displayedTracks.shuffled(), startAt: 0)
                    }
                    .disabled(displayedTracks.isEmpty)
                }

                playlistSearchRow

                if let desc = displayDescription {
                    Text(desc)
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(Color.atmusicComment)
                        .lineLimit(4)
                }

                Spacer(minLength: 0)
            }
            .frame(width: 240)
            .padding(.leading, 28)
            .padding(.top, 24)

            // 右栏：自适应网格或流畅滚动歌曲列表
            let rightWidth = availableWidth - 240 - 28 - 28 - 28
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("歌曲列表 (\(displayedTracks.count))")
                            .font(ATMusicFont.appFont(16, .bold))
                            .foregroundStyle(Color.atmusicLabel)
                        Spacer()
                    }
                    .padding(.top, 24)

                    LazyVGrid(columns: DeviceLayoutHelper.songListColumns(forAvailableWidth: rightWidth, minWidth: 280, spacing: 14), spacing: 8) {
                        ForEach(visibleTrackItems) { item in
                            SongCell(song: item.song, playbackIndex: item.index, onTap: {
                                player.play(songs: displayedTracks, startAt: item.index)
                            })
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.primary.opacity(0.03))
                            }
                            .onAppear {
                                loadMoreTracksIfNeeded(at: item.index)
                            }
                        }
                    }
                }
                .padding(.trailing, 28)
                .padding(.bottom, 120)
            }
        }
    }

    private func compactPlaylistLayout(availableWidth: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // 顶部横向摘要横幅卡片：针对 iPad 竖屏、半分屏优化，杜绝左栏挤压
                HStack(alignment: .top, spacing: 16) {
                    CoverImage(url: resolvedCoverURL ?? playlist.coverURL, size: 130, cornerRadius: 16)
                        .aspectRatio(1, contentMode: .fit)
                        .frame(width: 130, height: 130)
                        .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 5)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(displayName)
                            .font(ATMusicFont.appFont(18, .bold))
                            .foregroundStyle(Color.atmusicLabel)
                            .lineLimit(2)

                        HStack(spacing: 6) {
                            SourceBadgeView(source: playlist.source)
                            Text(displayCreatorName)
                                .font(ATMusicFont.appFont(12, .medium))
                                .foregroundStyle(Color.atmusicComment)
                        }

                        Text(atmusicSongCountText(tracks.isEmpty ? playlist.trackCount : tracks.count))
                            .font(ATMusicFont.appFont(11))
                            .foregroundStyle(Color.atmusicComment)

                        Spacer(minLength: 4)

                        HStack(spacing: 10) {
                            GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                                guard !displayedTracks.isEmpty else { return }
                                player.play(songs: displayedTracks, startAt: 0)
                            }
                            .disabled(displayedTracks.isEmpty)

                            GlassIconButton(systemName: "shuffle", size: 38, active: false) {
                                guard !displayedTracks.isEmpty else { return }
                                player.play(songs: displayedTracks.shuffled(), startAt: 0)
                            }
                            .disabled(displayedTracks.isEmpty)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                playlistSearchRow
                    .padding(.horizontal, 20)

                HStack {
                    Text("歌曲列表 (\(displayedTracks.count))")
                        .font(ATMusicFont.appFont(16, .bold))
                        .foregroundStyle(Color.atmusicLabel)
                    Spacer()
                }
                .padding(.horizontal, 20)

                LazyVGrid(columns: DeviceLayoutHelper.songListColumns(forAvailableWidth: availableWidth - 40, minWidth: 280, spacing: 12), spacing: 6) {
                    ForEach(visibleTrackItems) { item in
                        SongCell(song: item.song, playbackIndex: item.index, onTap: {
                            player.play(songs: displayedTracks, startAt: item.index)
                        })
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.primary.opacity(0.03))
                        }
                        .onAppear {
                            loadMoreTracksIfNeeded(at: item.index)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 120)
            }
        }
    }

    /// 歌单内搜索框：播放全部下方独立一行（四种 UI 风格跟随主题）
    private var playlistSearchRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.atmusicComment)
            TextField("搜索歌单内歌曲", text: $searchText)
                .font(ATMusicFont.appFont(14))
                .tint(Color.atmusicAmber)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    ATMusicHaptics.tap()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.atmusicComment)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background {
            ATMusicSurface(shape: Capsule())
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: isNativeClean ? 14 : 12) {
                CoverImage(url: resolvedCoverURL ?? playlist.coverURL, size: 80, cornerRadius: 14)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(displayName)
                            .font(ATMusicFont.appFont(17, .bold))
                            .foregroundStyle(Color.atmusicLabel)
                            .lineLimit(2)
                        SourceBadgeView(source: playlist.source)
                    }

                    Text(displayCreatorName)
                        .font(ATMusicFont.appFont(11))
                        .foregroundStyle(Color.atmusicComment)
                        .lineLimit(1)

                    Text(atmusicSongCountText(tracks.isEmpty ? playlist.trackCount : tracks.count))
                        .font(ATMusicFont.appFont(11))
                        .foregroundStyle(Color.atmusicComment)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 12) {
                GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                    guard !displayedTracks.isEmpty else { return }
                    player.play(songs: displayedTracks, startAt: 0)
                }
                .disabled(displayedTracks.isEmpty)
                .frame(maxWidth: .infinity)

                GlassButton(title: "随机播放", systemName: "shuffle", prominent: false) {
                    guard !displayedTracks.isEmpty else { return }
                    player.play(songs: displayedTracks.shuffled(), startAt: 0)
                }
                .disabled(displayedTracks.isEmpty)
                .frame(maxWidth: .infinity)
            }

            playlistSearchRow
        }
        .padding(.vertical, 4)
    }



    // MARK: - 编辑态（阶段 2）

    private func handleDragChange(startIndex: Int, deltaRows: Int) {
        if dragStartIndex == nil {
            dragStartIndex = startIndex
            initialSelectedKeysOnDrag = selectedKeys
            dragCachedKeys = displayedTracks.map(\.identityKey)
            let willSelect = startIndex < dragCachedKeys.count ? !selectedKeys.contains(dragCachedKeys[startIndex]) : true
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
        selectedKeys = updated
    }

    private func handleDragEnd() {
        dragStartIndex = nil
        initialSelectedKeysOnDrag = nil
        lastDragIndex = nil
        dragCachedKeys.removeAll()
    }


    private var editHintText: String {
        var parts: [String] = []
        if capabilities.canRemoveSongs {
            parts.append("点行可勾选，底部栏批量删除、移歌、下载、归档")
        } else {
            parts.append("QQ/酷狗歌单不支持直接删歌，可复制到其它歌单")
        }
        if sortMode == .original && searchText.isEmpty {
            parts.append("拖动右侧把手重排（仅影响本机顺序）")
        } else {
            parts.append("请先切回默认排序并清空搜索，再拖动重排")
        }
        return parts.joined(separator: "；") + "。"
    }

    private var editList: some View {
        List {
            Section {
                ForEach(visibleTrackItems) { item in
                    HStack(spacing: 12) {
                        MultiSelectCheckmark(
                            isSelected: selectedKeys.contains(item.song.identityKey),
                            index: item.index,
                            rowHeight: 56,
                            onToggle: {
                                toggleSelection(item.song)
                                ATMusicHaptics.tap()
                            },
                            onDragChange: { startIdx, deltaRows in
                                handleDragChange(startIndex: startIdx, deltaRows: deltaRows)
                            },
                            onDragEnd: {
                                handleDragEnd()
                            }
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.song.name)
                                .font(ATMusicFont.appFont(14, .medium))
                                .foregroundStyle(Color.atmusicLabel)
                                .lineLimit(1)
                            Text(item.song.artists)
                                .font(ATMusicFont.appFont(11))
                                .foregroundStyle(Color.atmusicComment)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if sortMode == .original && searchText.isEmpty {
                            Image(systemName: "line.3.horizontal")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.atmusicComment.opacity(0.55))
                        }
                    }
                    .multiSelectRow(index: item.index, coordinateSpace: "PlaylistEditListSpace")
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .contentShape(Rectangle())
                    .onTapGesture { toggleSelection(item.song) }
                    .onAppear {
                        loadMoreTracksIfNeeded(at: item.index)
                    }
                }
                .onMove { offsets, destination in
                    reorderDisplayedTracks(from: offsets, to: destination)
                }
                .onDelete(perform: capabilities.canRemoveSongs ? { offsets in
                    Task { await removeDisplayedTracks(at: offsets) }
                } : nil)
            } header: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("编辑「\(displayName)」")
                        .font(ATMusicFont.appFont(14, .bold))
                        .foregroundStyle(Color.atmusicLabel)
                    Text(editHintText)
                        .font(ATMusicFont.appFont(11))
                        .foregroundStyle(Color.atmusicComment)
                }
                .textCase(nil)
                .padding(.vertical, 4)
            }

            Section {
                Button(selectedKeys.count == displayedTracks.count && !displayedTracks.isEmpty ? "取消全选" : "全选") {
                    if selectedKeys.count == displayedTracks.count {
                        selectedKeys.removeAll()
                    } else {
                        selectedKeys = Set(displayedTracks.map(\.identityKey))
                    }
                    ATMusicHaptics.tap()
                }
            }
        }
        .atmusicScrollContentBackgroundHidden()
        .listStyle(.plain)
        .environment(\.editMode, .constant(.active))

    }

    private var editBottomBar: some View {
        UniversalBatchActionBar(
            selectedCount: selectedKeys.count,
            totalCount: displayedTracks.count,
            actions: [
                BatchActionItem(id: "play", title: "播放", systemImage: "play.fill", disabled: selectedKeys.isEmpty) {
                    let songs = selectedSongs
                    player.play(songs: songs, startAt: 0)
                    isEditing = false
                    selectedKeys.removeAll()
                },
                BatchActionItem(id: "playNext", title: "下一首", systemImage: "text.line.first.and.arrowtriangle.forward", disabled: selectedKeys.isEmpty) {
                    let songs = selectedSongs
                    player.playNext(songs: songs)
                    isEditing = false
                    selectedKeys.removeAll()
                },
                BatchActionItem(id: "queue", title: "加队列", systemImage: "text.badge.plus", disabled: selectedKeys.isEmpty) {
                    let songs = selectedSongs
                    player.appendToQueue(songs: songs)
                    isEditing = false
                    selectedKeys.removeAll()
                },
                BatchActionItem(id: "move", title: capabilities.canRemoveSongs ? "移歌单" : "存歌单", systemImage: "folder.badge.plus", disabled: selectedKeys.isEmpty) {
                    showMoveSheet = true
                },
                BatchActionItem(id: "download", title: "下载", systemImage: "arrow.down.circle", disabled: selectedKeys.isEmpty || isBatchDownloading) {
                    batchDownloadSelected()
                },
                BatchActionItem(id: "archive", title: "归档NAS", systemImage: "externaldrive.badge.plus", tint: Color.atmusicAmber, disabled: selectedKeys.isEmpty || isBatchUploading || !SynologyAPI.shared.isLoggedIn) {
                    batchUploadSelectedToNAS()
                },
                BatchActionItem(id: "delete", title: "删除", systemImage: "trash", tint: Color.red, disabled: selectedKeys.isEmpty || !capabilities.canRemoveSongs) {
                    Task { await removeSelected() }
                }
            ]
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func toggleSelection(_ song: Song) {
        if selectedKeys.contains(song.identityKey) {
            selectedKeys.remove(song.identityKey)
        } else {
            selectedKeys.insert(song.identityKey)
        }
    }

    private func reorderDisplayedTracks(from offsets: IndexSet, to destination: Int) {
        guard sortMode == .original, searchText.isEmpty else {
            ToastCenter.shared.show("请先切回默认排序并清空搜索，再拖动重排")
            return
        }
        var reordered = displayedTracks
        reordered.move(fromOffsets: offsets, toOffset: destination)
        PlaylistSongOrderStore.shared.saveOrder(reordered, for: playlistKey)
        orderVersion += 1
        updateDisplayedTracks()
        ATMusicHaptics.select()
    }

    private func removeDisplayedTracks(at offsets: IndexSet) async {
        guard capabilities.canRemoveSongs else { return }
        await removeSongs(offsets.map { displayedTracks[$0] })
    }

    private func removeSelected() async {
        await removeSongs(selectedSongs)
    }

    private func removeSongs(_ removing: [Song]) async {
        guard !removing.isEmpty, playlist.source == .netease else { return }
        let ids = removing.map(\.id).filter { $0 != 0 }
        guard !ids.isEmpty else {
            ToastCenter.shared.show("所选歌曲没有网易云曲目，无法移除")
            return
        }
        do {
            let ok = try await NetEaseAPI.shared.removeFromPlaylist(playlistID: playlist.id, songIDs: ids)
            if ok {
                let keys = Set(removing.map(\.identityKey))
                tracks.removeAll { keys.contains($0.identityKey) }
                selectedKeys.subtract(keys)
                updateDisplayedTracks()
                await PlaylistManagementService.invalidateSongsCache(for: playlist)
                ToastCenter.shared.show("已移除 \(removing.count) 首")
                ATMusicHaptics.success()
            } else {
                ToastCenter.shared.show("移除失败，请重试")
            }
        } catch {
            ToastCenter.shared.show("移除失败：\(error.localizedDescription)")
        }
    }

    private func moveSelectedSongs(to target: PlaylistEditTarget) async {
        let moving = selectedSongs
        guard !moving.isEmpty else { return }
        do {
            if capabilities.canRemoveSongs, playlist.source == .netease {
                _ = try await PlaylistManagementService.shared.moveSongs(moving, from: .netease(playlist), to: target)
                let keys = Set(moving.map(\.identityKey))
                tracks.removeAll { keys.contains($0.identityKey) }
                selectedKeys.removeAll()
                updateDisplayedTracks()
                await PlaylistManagementService.invalidateSongsCache(for: playlist)
                ToastCenter.shared.show("已移到「\(target.title)」")
            } else {
                _ = try await PlaylistManagementService.shared.addSongs(moving, to: target)
                selectedKeys.removeAll()
                ToastCenter.shared.show("已复制到「\(target.title)」")
            }
            ATMusicHaptics.success()
        } catch {
            ToastCenter.shared.show("操作失败：\(error.localizedDescription)")
        }
    }

    private func copySelectedToLocal() async {
        let moving = selectedSongs
        guard !moving.isEmpty else { return }
        let created = await PlaylistManagementService.shared.copyToLocal(songs: moving, named: "\(displayName)（本地）")
        selectedKeys.removeAll()
        ToastCenter.shared.show("已转存为本地歌单「\(created.name)」")
        ATMusicHaptics.success()
    }

    private func renamePlaylist() async {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, playlist.source == .netease else { return }
        do {
            let ok = try await NetEaseAPI.shared.renamePlaylist(id: playlist.id, name: name)
            if ok {
                displayName = name
                await PlaylistManagementService.invalidateListCache(for: .netease)
                await auth.loadLibrary()
                ToastCenter.shared.show("已重命名为「\(name)」")
                ATMusicHaptics.success()
            } else {
                ToastCenter.shared.show("重命名失败，请重试")
            }
        } catch {
            ToastCenter.shared.show("重命名失败：\(error.localizedDescription)")
        }
    }

    private func saveDescription() async {
        guard playlist.source == .netease else { return }
        do {
            let ok = try await NetEaseAPI.shared.updatePlaylistDescription(id: playlist.id, description: descriptionText)
            if ok {
                resolvedDescriptionText = descriptionText
                ToastCenter.shared.show("简介已更新")
                ATMusicHaptics.success()
            } else {
                ToastCenter.shared.show("更新失败，请重试")
            }
        } catch {
            ToastCenter.shared.show("更新失败：\(error.localizedDescription)")
        }
    }

    private func deletePlaylist() async {
        switch playlist.source {
        case .netease:
            do {
                let ok = try await NetEaseAPI.shared.deletePlaylist(id: playlist.id)
                if ok {
                    await PlaylistManagementService.invalidateListCache(for: .netease)
                    await auth.loadLibrary()
                    ToastCenter.shared.show("歌单已删除")
                    dismissAfterDelete()
                } else {
                    ToastCenter.shared.show("删除失败，请重试")
                }
            } catch {
                ToastCenter.shared.show("删除失败：\(error.localizedDescription)")
            }
        case .qq:
            do {
                let ok = try await QQMusicAPI.shared.deletePlaylist(dirid: playlist.id)
                if ok {
                    await PlaylistManagementService.invalidateListCache(for: .qq)
                    ToastCenter.shared.show("歌单已删除")
                    dismissAfterDelete()
                } else {
                    ToastCenter.shared.show("删除失败，请确认已登录 QQ 音乐")
                }
            } catch {
                ToastCenter.shared.show("删除失败：\(error.localizedDescription)")
            }
        default:
            break
        }
    }

    private func deduplicate() async {
        guard playlist.source == .netease else { return }
        do {
            let removed = try await PlaylistManagementService.shared.deduplicateNetEasePlaylist(playlist)
            if removed == 0 {
                ToastCenter.shared.show("没有发现重复歌曲")
            } else {
                await load(force: true)
                ToastCenter.shared.show("已去除 \(removed) 首重复歌曲")
                ATMusicHaptics.success()
            }
        } catch {
            ToastCenter.shared.show("去重失败：\(error.localizedDescription)")
        }
    }

    private func exportToLocal() async {
        guard !tracks.isEmpty else {
            ToastCenter.shared.show("歌单是空的")
            return
        }
        let created = await PlaylistManagementService.shared.copyToLocal(songs: tracks, named: "\(displayName)（本地）")
        ToastCenter.shared.show("已转存为本地歌单「\(created.name)」")
        ATMusicHaptics.success()
    }

    private func dismissAfterDelete() {
        dismiss()
    }

    private func load(force: Bool = false) async {
        let cache = SyncedPlaylistCache.shared
        if let cached = cache.cachedSongs(playlist: playlist, accountID: cacheAccountID) {
            tracks = cached.songs
            resolvedCoverURL = cached.songs.first?.coverURL
            updateDisplayedTracks()
            loading = false
            if !force, cache.isFresh(cached) {
                return
            }
        } else {
            loading = true
        }
        errorMessage = nil
        ATMusicLogger.shared.log("歌单页面打开 source=\(playlist.source.rawValue) id=\(playlist.id) name=\(playlist.name) advertisedCount=\(playlist.trackCount)", level: .info)
        do {
            if playlist.source == .synology {
                tracks = try await SynologyAPI.shared.playlistSongs(playlistId: playlist.synologyPlaylistId ?? "\(playlist.id)")
            } else if playlist.source == .kugou {
                tracks = try await KugouMusicAPI.shared.playlistSongs(listID: playlist.id)
            } else if playlist.source == .qq {
                tracks = try await QQMusicAPI.shared.playlistSongs(listID: playlist.id)
                // 云端收藏接口临时被风控或返回空时，至少展示已同步到本机的 QQ 收藏，
                // 避免“我的喜欢”进入后变成空白页面。
                if tracks.isEmpty, playlist.id == QQMusicAPI.qqLikedPlaylistID {
                    tracks = favorites.qqFavoriteSongs
                    ATMusicLogger.shared.log("QQ 我的喜欢页面网络结果为空，使用本地收藏回退 count=\(tracks.count)", level: tracks.isEmpty ? .warn : .info)
                }
            } else {
                async let remoteTracks = NetEaseAPI.shared.playlistTracks(id: playlist.id)
                async let metadata = try? NetEaseAPI.shared.playlistMetadata(id: playlist.id)
                tracks = try await remoteTracks
                if let metadata = await metadata {
                    resolvedCreatorName = metadata.creatorName
                    resolvedDescriptionText = metadata.descriptionText
                    resolvedPopularity = metadata.popularity
                }
            }
            if resolvedCoverURL == nil {
                resolvedCoverURL = tracks.first?.coverURL
            }
            updateDisplayedTracks()
            if !tracks.isEmpty {
                cache.saveSongs(tracks, playlist: playlist, accountID: cacheAccountID)
            }
            ATMusicLogger.shared.log("歌单页面加载完成 source=\(playlist.source.rawValue) id=\(playlist.id) name=\(playlist.name) count=\(tracks.count) error=无", level: tracks.isEmpty ? .warn : .info)
            loading = false
        } catch {
            if tracks.isEmpty {
                errorMessage = error.localizedDescription
            } else {
                ATMusicLogger.shared.log("歌单页面刷新失败，继续使用缓存 source=\(playlist.source.rawValue) id=\(playlist.id) error=\(error.localizedDescription)", level: .warn)
            }
            ATMusicLogger.shared.log("歌单页面加载失败 source=\(playlist.source.rawValue) id=\(playlist.id) name=\(playlist.name) error=\(error.localizedDescription)", level: .error)
            loading = false
        }
    }
}

private struct PlaylistInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    let name: String
    let source: SongSource
    let creator: String
    let songCount: Int
    let popularity: String?
    let description: String?

    var body: some View {
        ATMusicNavigationStack {
            List {
                Section {
                    LabeledContent("来源", value: source.atmusicDisplayName)
                    LabeledContent("创建者", value: creator)
                    LabeledContent("歌曲", value: "\(songCount) 首")
                    if let popularity { LabeledContent("热度", value: popularity) }
                }
                if let description, !description.isEmpty {
                    Section("简介") {
                        Text(description)
                            .font(ATMusicFont.appFont(13))
                            .foregroundStyle(Color.atmusicLabel)
                            .textSelection(.enabled)
                    }
                }
            }
            .atmusicScrollContentBackgroundHidden()
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

/// 1.8.1 歌单详情中的紧凑歌曲行：连续排列、统一行高、只用细分隔线区分歌曲。
