import SwiftUI

// MARK: - 歌手主页（点击播放器顶部歌手名跳转：热门歌曲 + 专辑）

struct ArtistHomeSheet: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.dismiss) private var dismiss
    let artistName: String
    var artistSource: SongSource = .netease
    var artistID: String?

    init(artist: Artist) {
        self.artistName = artist.name
        self.artistSource = artist.source
        self.artistID = artist.id
        _artist = State(initialValue: artist)
    }

    init(artistName: String, artistSource: SongSource = .netease) {
        self.artistName = artistName
        self.artistSource = artistSource
        self.artistID = nil
        _artist = State(initialValue: nil)
    }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var artist: Artist?
    @State private var hotSongs: [Song] = []
    @State private var albums: [Album] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var selectedSection: ArtistHomeSection = .songs
    @State private var isMultiSelecting = false
    @State private var selectedSongKeys: Set<String> = []
    @State private var selectedAlbumKeys: Set<String> = []
    @State private var dragStartIndex: Int? = nil
    @State private var initialSelectedKeysOnDrag: Set<String>? = nil
    @State private var dragTargetSelected = true
    @State private var lastDragIndex: Int? = nil
    @State private var showBatchAddToPlaylist = false

    private var selectedSongs: [Song] {
        displayedHotSongs.filter { selectedSongKeys.contains($0.identityKey) }
    }

    private var selectedAlbums: [Album] {
        albums.filter { selectedAlbumKeys.contains($0.identityKey) }
    }

    private func toggleSelection(_ song: Song) {
        if selectedSongKeys.contains(song.identityKey) {
            selectedSongKeys.remove(song.identityKey)
        } else {
            selectedSongKeys.insert(song.identityKey)
        }
    }

    private func toggleAlbumSelection(_ album: Album) {
        if selectedAlbumKeys.contains(album.identityKey) {
            selectedAlbumKeys.remove(album.identityKey)
        } else {
            selectedAlbumKeys.insert(album.identityKey)
        }
        ATMusicHaptics.tap()
    }

    private func playSelectedAlbums() async {
        let albumsToPlay = selectedAlbums
        var allSongs: [Song] = []
        for album in albumsToPlay {
            let tracks = await DetailSongsCache.fetchSongs(for: album)
            allSongs.append(contentsOf: tracks)
        }
        if !allSongs.isEmpty {
            await MainActor.run {
                player.play(songs: allSongs, startAt: 0)
                ToastCenter.shared.show("已开始播放 \(albumsToPlay.count) 张专辑共 \(allSongs.count) 首")
            }
        }
    }

    private func playNextSelectedAlbums() async {
        let albumsToPlay = selectedAlbums
        var allSongs: [Song] = []
        for album in albumsToPlay {
            let tracks = await DetailSongsCache.fetchSongs(for: album)
            allSongs.append(contentsOf: tracks)
        }
        if !allSongs.isEmpty {
            await MainActor.run {
                player.playNext(songs: allSongs)
                ToastCenter.shared.show("已将 \(albumsToPlay.count) 张专辑共 \(allSongs.count) 首设为下一首播放")
            }
        }
    }

    private func queueSelectedAlbums() async {
        let albumsToQueue = selectedAlbums
        var allSongs: [Song] = []
        for album in albumsToQueue {
            let tracks = await DetailSongsCache.fetchSongs(for: album)
            allSongs.append(contentsOf: tracks)
        }
        if !allSongs.isEmpty {
            await MainActor.run {
                player.appendToQueue(songs: allSongs)
                ToastCenter.shared.show("已将 \(albumsToQueue.count) 张专辑共 \(allSongs.count) 首加入队列")
            }
        }
    }

    private func downloadSelectedAlbums() async {
        let albumsToDownload = selectedAlbums
        var allSongs: [Song] = []
        for album in albumsToDownload {
            let tracks = await DetailSongsCache.fetchSongs(for: album)
            allSongs.append(contentsOf: tracks)
        }
        if !allSongs.isEmpty {
            await MainActor.run {
                DownloadManager.shared.startBatchDownload(songs: allSongs)
                ToastCenter.shared.show("已将 \(albumsToDownload.count) 张专辑共 \(allSongs.count) 首加入下载")
            }
        }
    }

    private func archiveSelectedAlbumsToNAS() async {
        guard SynologyAPI.shared.isLoggedIn else { return }
        let albumsToArchive = selectedAlbums
        var allSongs: [Song] = []
        for album in albumsToArchive {
            let tracks = await DetailSongsCache.fetchSongs(for: album)
            allSongs.append(contentsOf: tracks)
        }
        if !allSongs.isEmpty {
            await MainActor.run {
                DownloadManager.shared.startBatchUploadToNAS(songs: allSongs)
                ToastCenter.shared.show("已将 \(albumsToArchive.count) 张专辑共 \(allSongs.count) 首加入 NAS 归档")
            }
        }
    }

    private func handleDragChange(startIndex: Int, deltaRows: Int) {
        let keys = displayedHotSongs.map(\.identityKey)
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

    private enum ArtistHomeSection: String, CaseIterable, Identifiable {
        case songs = "歌曲"
        case albums = "专辑"

        var id: String { rawValue }
    }

    var body: some View {
        ATMusicNavigationStack {
            ZStack {
                // 歌手页沿用主页壁纸，不受“同步到全部页面”开关影响。
                GlassBackdrop(customColor: theme.customBackground, homeMode: true)
                Group {
                    if loading {
                        LoadingStateView()
                    } else if let errorMessage {
                        ErrorStateView(message: errorMessage) {
                            Task { await load() }
                        }
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 14) {
                                artistHeader
                                Picker("歌手内容", selection: $selectedSection) {
                                    ForEach(ArtistHomeSection.allCases) { section in
                                        Text(section.rawValue).tag(section)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .padding(.horizontal, 16)
                                .onChange(of: selectedSection) { _ in
                                    isMultiSelecting = false
                                    selectedSongKeys.removeAll()
                                    selectedAlbumKeys.removeAll()
                                }

                                if selectedSection == .songs {
                                    hotSongsSection
                                } else {
                                    albumsSection
                                }
                            }
                            .padding(.top, 6)
                            .padding(.bottom, 16)
                        }
                        .atmusicScrollIndicatorsHidden()
                    }
                }

                if isMultiSelecting {
                    if selectedSection == .songs && !selectedSongKeys.isEmpty {
                        VStack {
                            Spacer()
                            UniversalBatchActionBar(
                                selectedCount: selectedSongKeys.count,
                                totalCount: displayedHotSongs.count,
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
                    } else if selectedSection == .albums && !selectedAlbumKeys.isEmpty {
                        VStack {
                            Spacer()
                            UniversalBatchActionBar(
                                selectedCount: selectedAlbumKeys.count,
                                totalCount: albums.count,
                                actions: [
                                    BatchActionItem(id: "play", title: "播放", systemImage: "play.fill") {
                                        Task { await playSelectedAlbums() }
                                        isMultiSelecting = false
                                        selectedAlbumKeys.removeAll()
                                    },
                                    BatchActionItem(id: "playNext", title: "下一首", systemImage: "text.line.first.and.arrowtriangle.forward") {
                                        Task { await playNextSelectedAlbums() }
                                        isMultiSelecting = false
                                        selectedAlbumKeys.removeAll()
                                    },
                                    BatchActionItem(id: "queue", title: "加队列", systemImage: "text.badge.plus") {
                                        Task { await queueSelectedAlbums() }
                                        isMultiSelecting = false
                                        selectedAlbumKeys.removeAll()
                                    },
                                    BatchActionItem(id: "download", title: "下载", systemImage: "arrow.down.circle") {
                                        Task { await downloadSelectedAlbums() }
                                        isMultiSelecting = false
                                        selectedAlbumKeys.removeAll()
                                    },
                                    BatchActionItem(id: "archive", title: "归档NAS", systemImage: "externaldrive.badge.plus", tint: Color.atmusicAmber, disabled: !SynologyAPI.shared.isLoggedIn) {
                                        Task { await archiveSelectedAlbumsToNAS() }
                                        isMultiSelecting = false
                                        selectedAlbumKeys.removeAll()
                                    }
                                ]
                            )
                            .padding(.horizontal, 16)
                            .padding(.bottom, 24)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                }
            }
            .navigationTitle(
                isMultiSelecting
                    ? (selectedSection == .songs
                        ? (selectedSongKeys.isEmpty ? "选择歌曲" : "已选 \(selectedSongKeys.count) 首")
                        : (selectedAlbumKeys.isEmpty ? "选择专辑" : "已选 \(selectedAlbumKeys.count) 张"))
                    : "歌手主页"
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !isMultiSelecting {
                        Button("关闭") { dismiss() }
                            .font(ATMusicFont.appFont(15))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isMultiSelecting {
                        let totalCount = selectedSection == .songs ? displayedHotSongs.count : albums.count
                        let isAll = selectedSection == .songs
                            ? (selectedSongKeys.count == totalCount && !displayedHotSongs.isEmpty)
                            : (selectedAlbumKeys.count == totalCount && !albums.isEmpty)
                        HStack(spacing: 12) {
                            Button(isAll ? "取消全选" : "全选") {
                                ATMusicHaptics.tap()
                                if selectedSection == .songs {
                                    if selectedSongKeys.count == displayedHotSongs.count {
                                        selectedSongKeys.removeAll()
                                    } else {
                                        selectedSongKeys = Set(displayedHotSongs.map(\.identityKey))
                                    }
                                } else {
                                    if selectedAlbumKeys.count == albums.count {
                                        selectedAlbumKeys.removeAll()
                                    } else {
                                        selectedAlbumKeys = Set(albums.map(\.identityKey))
                                    }
                                }
                            }
                            .font(ATMusicFont.appFont(13, .semibold))
                            .foregroundStyle(Color.atmusicAmber)

                            Button("完成") {
                                ATMusicHaptics.tap()
                                isMultiSelecting = false
                                selectedSongKeys.removeAll()
                                selectedAlbumKeys.removeAll()
                            }
                            .font(ATMusicFont.appFont(13, .semibold))
                        }
                    } else {
                        Menu {
                            Button {
                                ATMusicHaptics.select()
                                isMultiSelecting = true
                            } label: {
                                Label(selectedSection == .songs ? "多选歌曲" : "多选专辑", systemImage: "checklist")
                            }
                            .disabled(selectedSection == .songs ? displayedHotSongs.isEmpty : albums.isEmpty)
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
        }
        .task { await load() }
        .modifier(ATMusicSheetModifier(detents: [.large], dragIndicator: true))
    }

    private var artistHeader: some View {
        HStack(spacing: 14) {
            AsyncImage(url: artist?.coverURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(Color.atmusicComment)
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(Circle())
            .background(Color.atmusicGlassFill, in: Circle())

            VStack(alignment: .leading, spacing: 6) {
                Text(artist?.name ?? artistName)
                    .font(ATMusicFont.appFont(20, .bold))
                    .foregroundStyle(Color.atmusicLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                Text(atmusicLocalized("歌曲 \(hotSongs.count) 首 · 专辑 \(albums.count) 张", "Songs: \(hotSongs.count) · Albums: \(albums.count)"))
                    .font(ATMusicFont.appFont(12))
                    .foregroundStyle(Color.atmusicComment)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    private var hotSongsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("热门歌曲")
                .font(ATMusicFont.appFont(17, .bold))
                .foregroundStyle(Color.atmusicLabel)
                .padding(.horizontal, 16)
            if !hotSongs.isEmpty {
                HStack(spacing: 10) {
                    Button {
                        ATMusicHaptics.tap()
                        player.play(songs: displayedHotSongs, startAt: 0)
                        dismiss()
                    } label: {
                        Label("播放全部", systemImage: "play.fill")
                            .font(ATMusicFont.appFont(13, .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(Capsule().fill(Color.atmusicAmber))
                    }
                    .buttonStyle(GlassPressButtonStyle(scale: 0.97))
                    Button {
                        ATMusicHaptics.tap()
                        player.play(songs: displayedHotSongs.shuffled(), startAt: 0)
                        dismiss()
                    } label: {
                        Label("随机播放", systemImage: "shuffle")
                            .font(ATMusicFont.appFont(13, .semibold))
                            .foregroundStyle(Color.atmusicAmber)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(Capsule().strokeBorder(Color.atmusicAmber.opacity(0.5), lineWidth: 1))
                    }
                    .buttonStyle(GlassPressButtonStyle(scale: 0.97))
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 2)
            }
            if !hotSongs.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.atmusicComment)
                    TextField(atmusicLocalized("搜索歌手歌曲", "Search artist songs"), text: $searchText)
                        .font(ATMusicFont.appFont(14))
                        .autocorrectionDisabled()
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.atmusicComment)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 14, style: .continuous)) }
                .padding(.horizontal, 16)
                .padding(.bottom, 2)
            }
            if hotSongs.isEmpty {
                Text("暂无歌曲")
                    .font(ATMusicFont.appFont(13))
                    .foregroundStyle(Color.atmusicComment)
                    .padding(.horizontal, 16)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(displayedHotSongs.enumerated()), id: \.element.identityKey) { index, song in
                        SongCell(
                            song: song,
                            playbackContext: displayedHotSongs,
                            playbackIndex: index,
                            trackNumber: index + 1,
                            subtitleText: song.album,
                            onTap: {
                                player.play(songs: displayedHotSongs, startAt: index)
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
                }
            }
        }
    }

    private var displayedHotSongs: [Song] {
        let kw = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kw.isEmpty else { return hotSongs }
        return hotSongs.filter { song in
            song.name.lowercased().contains(kw)
                || song.artists.lowercased().contains(kw)
                || song.album.lowercased().contains(kw)
        }
    }

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("专辑")
                .font(ATMusicFont.appFont(17, .bold))
                .foregroundStyle(Color.atmusicLabel)
                .padding(.horizontal, 16)
            if albums.isEmpty {
                Text("暂无专辑")
                    .font(ATMusicFont.appFont(13))
                    .foregroundStyle(Color.atmusicComment)
                    .padding(.horizontal, 16)
            } else {
                LazyVGrid(columns: DeviceLayoutHelper.adaptiveCardColumns(for: horizontalSizeClass, minWidth: 140, maxWidth: 200, spacing: 16), spacing: 18) {
                    ForEach(albums) { album in
                        if isMultiSelecting {
                            MediaSquareCard(
                                album: album,
                                showSourceBadge: false,
                                isMultiSelecting: true,
                                isSelected: selectedAlbumKeys.contains(album.identityKey),
                                onToggleSelection: {
                                    toggleAlbumSelection(album)
                                }
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                toggleAlbumSelection(album)
                            }
                        } else {
                            NavigationLink {
                                if album.source == .synology {
                                    SynologyAlbumView(albumName: album.name, artistName: album.artistName, coverURL: album.coverURL, isModal: false)
                                        .environmentObject(player)
                                        .environmentObject(theme)
                                } else {
                                    AlbumDetailView(album: album, isModal: false)
                                        .environmentObject(player)
                                        .environmentObject(theme)
                                }
                            } label: {
                                MediaSquareCard(album: album, showSourceBadge: false)
                            }
                            .buttonStyle(GlassPressButtonStyle(scale: 0.97))
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func load() async {
        loading = true
        errorMessage = nil
        if artistSource == .qq {
            await loadQQArtist()
        } else if artistSource == .kugou {
            await loadKugouArtist()
        } else {
            await loadNetEaseArtist()
        }
    }

    private func loadNetEaseArtist() async {
        do {
            let id: Int
            if let artistID, let parsed = Int(artistID.replacingOccurrences(of: "netease-", with: "")), parsed > 0 {
                id = parsed
            } else {
                let artists = try await NetEaseAPI.shared.searchArtists(keyword: artistName, limit: 5)
                guard let first = artists.first else {
                    errorMessage = "未找到歌手「\(artistName)」"
                    loading = false
                    return
                }
                artist = first
                id = Int(first.id.replacingOccurrences(of: "netease-", with: "")) ?? 0
            }
            async let songs = (try? NetEaseAPI.shared.artistHotSongs(artistID: id, limit: 5_000)) ?? []
            async let albums = (try? NetEaseAPI.shared.artistAlbums(artistID: id, limit: 5_000)) ?? []
            let (s, a) = await (songs, albums)
            hotSongs = s
            self.albums = a
            // 接口异常时兜底：分页搜索补全歌手歌曲（避免再次退回 30 首）。
            if hotSongs.isEmpty {
                var fallback: [Song] = []
                for offset in stride(from: 0, to: 5_000, by: 30) {
                    let page = (try? await NetEaseAPI.shared.search(keyword: artistName, limit: 30, offset: offset)) ?? []
                    if page.isEmpty { break }
                    fallback.append(contentsOf: page)
                    if page.count < 30 { break }
                }
                hotSongs = fallback
            }
            loading = false
        } catch {
            errorMessage = error.localizedDescription
            loading = false
        }
    }

    /// QQ 歌手：优先用歌手 mid 拉热门歌曲，失败则按歌手名搜索 QQ 歌曲（保证不是网易云数据）
    private func loadQQArtist() async {
        var mid: String? = nil
        if let artistID, !artistID.hasPrefix("qq-") {
            mid = artistID
        } else if let first = (try? await QQMusicAPI.shared.searchArtists(keyword: artistName, limit: 5))?.first {
            artist = first
            mid = first.id
        }
        async let remoteSongs = (try? await QQMusicAPI.shared.artistHotSongs(mid: mid, name: artistName, limit: 5_000)) ?? []
        async let remoteAlbums = (try? await QQMusicAPI.shared.artistAlbums(mid: mid, name: artistName, limit: 5_000)) ?? []
        var songs = await remoteSongs
        albums = await remoteAlbums
        if songs.isEmpty {
            var fallback: [Song] = []
            for offset in stride(from: 0, to: 5_000, by: 30) {
                let page = (try? await QQMusicAPI.shared.searchSongs(keyword: artistName, limit: 30, offset: offset)) ?? []
                if page.isEmpty { break }
                fallback.append(contentsOf: page)
                if page.count < 30 { break }
            }
            var seen = Set<String>()
            songs = fallback.filter { seen.insert($0.identityKey).inserted }
        }
        hotSongs = songs
        if albums.isEmpty {
            albums = albumsFromSongs(songs)
        }
        loading = false
    }

    /// 酷狗歌手主页优先走作者歌曲接口，再补 `singer/song` 和综合搜索结果，
    /// 避免部分歌手页只停在首批 19 首。
    private func loadKugouArtist() async {
        let resolvedArtist: Artist?
        if let artistID,
           !artistID.isEmpty,
           !artistID.hasPrefix("qq-") {
            let rawID = artistID.replacingOccurrences(of: "kugou-", with: "")
            resolvedArtist = artist ?? Artist(id: rawID, name: artistName, coverURL: nil, source: .kugou)
        } else {
            resolvedArtist = (try? await KugouMusicAPI.shared.searchArtists(keyword: artistName, limit: 10))?.first
        }
        if let resolvedArtist {
            artist = resolvedArtist
        }
        var songs: [Song] = []
        var primarySongs: [Song] = []
        if let resolvedArtist,
           !resolvedArtist.id.isEmpty,
           !resolvedArtist.id.hasPrefix("qq-") {
            var seen = Set<String>()
            let pageSize = 100
            let maxSongs = 10_000
            for page in 1...(maxSongs / pageSize) {
                let batch = (try? await KugouMusicAPI.shared.artistSongs(
                    authorID: resolvedArtist.id,
                    page: page,
                    limit: pageSize
                )) ?? []
                if batch.isEmpty { break }
                let before = songs.count
                for song in batch where seen.insert(song.identityKey).inserted {
                    songs.append(song)
                    primarySongs.append(song)
                    if songs.count >= maxSongs { break }
                }
                if songs.count >= maxSongs || songs.count == before {
                    break
                }
            }
        }

        // The author endpoint has historically returned only 19 rows for some
        // accounts/charts. Supplement a short result with paged song search.
        if songs.count < 100 {
            async let exact = KugouMusicAPI.shared.searchSongs(keyword: artistName, limit: 1_000)
            async let works = KugouMusicAPI.shared.searchSongs(keyword: "\(artistName) 歌曲", limit: 1_000)
            let candidates = [
                (try? await exact) ?? [],
                (try? await works) ?? [],
            ]
            var seen = Set(songs.map(\.identityKey))
            for song in candidates.flatMap({ $0 }) {
                guard seen.insert(song.identityKey).inserted else { continue }
                songs.append(song)
            }
        }

        if songs.isEmpty {
            async let exact = KugouMusicAPI.shared.searchSongs(keyword: artistName, limit: 1_000)
            async let hot = KugouMusicAPI.shared.searchSongs(keyword: "\(artistName) 热门", limit: 1_000)
            async let works = KugouMusicAPI.shared.searchSongs(keyword: "\(artistName) 歌曲", limit: 1_000)
            let batches = [
                (try? await exact) ?? [],
                (try? await hot) ?? [],
                (try? await works) ?? [],
            ]
            var seen = Set<String>()
            songs = batches.flatMap { $0 }.filter { song in
                seen.insert(song.identityKey).inserted
            }
        }

        hotSongs = songs
        if hotSongs.isEmpty, !primarySongs.isEmpty {
            hotSongs = primarySongs
        }
        albums = albumsFromSongs(hotSongs)
        ATMusicLogger.shared.log("酷狗歌手主页完成：artist=\(artistName) songs=\(hotSongs.count)", level: .debug)
        loading = false
    }

    private func albumsFromSongs(_ songs: [Song]) -> [Album] {
        var seen = Set<String>()
        return songs.compactMap { song in
            let name = song.album.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name != "群晖 NAS" else { return nil }
            let key = "\(song.source.rawValue)|\(name.lowercased())|\(song.artists.lowercased())"
            guard seen.insert(key).inserted else { return nil }
            let count = songs.filter { $0.source == song.source && $0.album == song.album }.count
            return Album(id: "\(song.source.rawValue)-artist-album-\(key)", name: name, artistName: song.artists, coverURL: song.coverURL, source: song.source, trackCount: count)
        }
    }
}

/// 聚合歌手主页：歌曲和专辑严格分栏，内容来自网易云、QQ、酷狗和 NAS。
struct AllSourcesArtistHomeSheet: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var synology = SynologyAPI.shared

    let artistName: String
    let initialSongs: [Song]
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ObservedObject private var platformPrefs = PlatformPreferenceStore.shared
    @State private var songs: [Song] = []
    @State private var albums: [Album] = []
    @State private var loading = true
    @State private var selectedSection: ArtistHomeSection = .songs
    /// 聚合歌手页默认展示全部平台，使用 rawValue 存储以便后续扩展新音源而不改页面结构。
    @State private var selectedSourceRaws: Set<String> = Set([
        SongSource.netease.rawValue,
        SongSource.qq.rawValue,
        SongSource.kugou.rawValue,
        SongSource.synology.rawValue
    ])
    @State private var searchText = ""
    @State private var isMultiSelecting = false
    @State private var selectedSongKeys: Set<String> = []
    @State private var selectedAlbumKeys: Set<String> = []
    @State private var dragStartIndex: Int? = nil
    @State private var initialSelectedKeysOnDrag: Set<String>? = nil
    @State private var dragTargetSelected = true
    @State private var lastDragIndex: Int? = nil
    @State private var showBatchAddToPlaylist = false

    private var selectedSongs: [Song] {
        filteredSongs.filter { selectedSongKeys.contains($0.identityKey) }
    }

    private var selectedAlbums: [Album] {
        visibleAlbums.filter { selectedAlbumKeys.contains($0.identityKey) }
    }

    private func toggleSelection(_ song: Song) {
        if selectedSongKeys.contains(song.identityKey) {
            selectedSongKeys.remove(song.identityKey)
        } else {
            selectedSongKeys.insert(song.identityKey)
        }
    }

    private func toggleAlbumSelection(_ album: Album) {
        if selectedAlbumKeys.contains(album.identityKey) {
            selectedAlbumKeys.remove(album.identityKey)
        } else {
            selectedAlbumKeys.insert(album.identityKey)
        }
        ATMusicHaptics.tap()
    }

    private func playSelectedAlbums() async {
        let albumsToPlay = selectedAlbums
        var allSongs: [Song] = []
        for album in albumsToPlay {
            let tracks = await DetailSongsCache.fetchSongs(for: album)
            allSongs.append(contentsOf: tracks)
        }
        if !allSongs.isEmpty {
            await MainActor.run {
                player.play(songs: allSongs, startAt: 0)
                ToastCenter.shared.show("已开始播放 \(albumsToPlay.count) 张专辑共 \(allSongs.count) 首")
            }
        }
    }

    private func playNextSelectedAlbums() async {
        let albumsToPlay = selectedAlbums
        var allSongs: [Song] = []
        for album in albumsToPlay {
            let tracks = await DetailSongsCache.fetchSongs(for: album)
            allSongs.append(contentsOf: tracks)
        }
        if !allSongs.isEmpty {
            await MainActor.run {
                player.playNext(songs: allSongs)
                ToastCenter.shared.show("已将 \(albumsToPlay.count) 张专辑共 \(allSongs.count) 首设为下一首播放")
            }
        }
    }

    private func queueSelectedAlbums() async {
        let albumsToQueue = selectedAlbums
        var allSongs: [Song] = []
        for album in albumsToQueue {
            let tracks = await DetailSongsCache.fetchSongs(for: album)
            allSongs.append(contentsOf: tracks)
        }
        if !allSongs.isEmpty {
            await MainActor.run {
                player.appendToQueue(songs: allSongs)
                ToastCenter.shared.show("已将 \(albumsToQueue.count) 张专辑共 \(allSongs.count) 首加入队列")
            }
        }
    }

    private func downloadSelectedAlbums() async {
        let albumsToDownload = selectedAlbums
        var allSongs: [Song] = []
        for album in albumsToDownload {
            let tracks = await DetailSongsCache.fetchSongs(for: album)
            allSongs.append(contentsOf: tracks)
        }
        if !allSongs.isEmpty {
            await MainActor.run {
                DownloadManager.shared.startBatchDownload(songs: allSongs)
                ToastCenter.shared.show("已将 \(albumsToDownload.count) 张专辑共 \(allSongs.count) 首加入下载")
            }
        }
    }

    private func archiveSelectedAlbumsToNAS() async {
        guard SynologyAPI.shared.isLoggedIn else { return }
        let albumsToArchive = selectedAlbums
        var allSongs: [Song] = []
        for album in albumsToArchive {
            let tracks = await DetailSongsCache.fetchSongs(for: album)
            allSongs.append(contentsOf: tracks)
        }
        if !allSongs.isEmpty {
            await MainActor.run {
                DownloadManager.shared.startBatchUploadToNAS(songs: allSongs)
                ToastCenter.shared.show("已将 \(albumsToArchive.count) 张专辑共 \(allSongs.count) 首加入 NAS 归档")
            }
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

    private enum ArtistHomeSection: String, CaseIterable, Identifiable {
        case songs = "歌曲"
        case albums = "专辑"
        var id: String { rawValue }
    }

    private var sourceFilterOptions: [SongSource] {
        platformPrefs.enabledSearchProviders.map(\.songSource)
    }

    private func sourceTitle(_ source: SongSource) -> String {
        switch source {
        case .netease: return "网易云音乐"
        case .qq: return "QQ音乐"
        case .kugou: return "酷狗音乐"
        case .local: return "本地音乐"
        case .synology: return "群晖 NAS"
        case .subsonic: return "Subsonic"
        case .jellyfin: return "Jellyfin"
        case .webdav: return "WebDAV"
        }
    }

    private func toggleSource(_ source: SongSource) {
        if selectedSourceRaws.contains(source.rawValue) {
            guard selectedSourceRaws.count > 1 else {
                ToastCenter.shared.show("至少保留一个平台")
                return
            }
            selectedSourceRaws.remove(source.rawValue)
        } else {
            selectedSourceRaws.insert(source.rawValue)
        }
        ATMusicHaptics.select()
    }

    /// 歌手页只依赖这个统一的音源适配器协议。新增平台时注册一个 loader，页面和分栏无需改动。
    private struct SourceLoader {
        let name: String
        let load: @Sendable (String) async -> ([Song], [Album])
    }

    private static var sourceLoaders: [SourceLoader] {
        [
            SourceLoader(name: SongSource.netease.rawValue) { await Self.loadNetEase(name: $0) },
            SourceLoader(name: SongSource.qq.rawValue) { await Self.loadQQ(name: $0) },
            SourceLoader(name: SongSource.kugou.rawValue) { await Self.loadKugou(name: $0) },
            SourceLoader(name: SongSource.synology.rawValue) { await Self.loadNAS(name: $0) },
            SourceLoader(name: SongSource.subsonic.rawValue) { await Self.loadSubsonic(name: $0) },
            SourceLoader(name: SongSource.jellyfin.rawValue) { await Self.loadJellyfin(name: $0) },
            SourceLoader(name: SongSource.webdav.rawValue) { await Self.loadWebDAV(name: $0) },
        ]
    }

    init(artistName: String, initialSongs: [Song] = []) {
        self.artistName = artistName
        self.initialSongs = initialSongs
    }

    var body: some View {
        ATMusicNavigationStack {
            ZStack {
                GlassBackdrop(customColor: theme.customBackground, homeMode: true)
                if loading && songs.isEmpty && albums.isEmpty {
                    LoadingStateView()
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            header
                            Picker("歌手内容", selection: $selectedSection) {
                                ForEach(ArtistHomeSection.allCases) { section in
                                    Text(section.rawValue).tag(section)
                                }
                            }
                            .pickerStyle(.segmented)
                            .padding(.horizontal, 16)
                            .onChange(of: selectedSection) { _ in
                                isMultiSelecting = false
                                selectedSongKeys.removeAll()
                                selectedAlbumKeys.removeAll()
                            }

                            if selectedSection == .songs {
                                songsSection
                            } else {
                                albumsSection
                            }
                        }
                        .padding(.top, 8)
                        .padding(.bottom, 32)
                    }
                    .atmusicScrollIndicatorsHidden()
                }

                if isMultiSelecting {
                    if selectedSection == .songs && !selectedSongKeys.isEmpty {
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
                    } else if selectedSection == .albums && !selectedAlbumKeys.isEmpty {
                        VStack {
                            Spacer()
                            UniversalBatchActionBar(
                                selectedCount: selectedAlbumKeys.count,
                                totalCount: visibleAlbums.count,
                                actions: [
                                    BatchActionItem(id: "play", title: "播放", systemImage: "play.fill") {
                                        Task { await playSelectedAlbums() }
                                        isMultiSelecting = false
                                        selectedAlbumKeys.removeAll()
                                    },
                                    BatchActionItem(id: "playNext", title: "下一首", systemImage: "text.line.first.and.arrowtriangle.forward") {
                                        Task { await playNextSelectedAlbums() }
                                        isMultiSelecting = false
                                        selectedAlbumKeys.removeAll()
                                    },
                                    BatchActionItem(id: "queue", title: "加队列", systemImage: "text.badge.plus") {
                                        Task { await queueSelectedAlbums() }
                                        isMultiSelecting = false
                                        selectedAlbumKeys.removeAll()
                                    },
                                    BatchActionItem(id: "download", title: "下载", systemImage: "arrow.down.circle") {
                                        Task { await downloadSelectedAlbums() }
                                        isMultiSelecting = false
                                        selectedAlbumKeys.removeAll()
                                    },
                                    BatchActionItem(id: "archive", title: "归档NAS", systemImage: "externaldrive.badge.plus", tint: Color.atmusicAmber, disabled: !SynologyAPI.shared.isLoggedIn) {
                                        Task { await archiveSelectedAlbumsToNAS() }
                                        isMultiSelecting = false
                                        selectedAlbumKeys.removeAll()
                                    }
                                ]
                            )
                            .padding(.horizontal, 16)
                            .padding(.bottom, 24)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                }
            }
            .navigationTitle(
                isMultiSelecting
                    ? (selectedSection == .songs
                        ? (selectedSongKeys.isEmpty ? "选择歌曲" : "已选 \(selectedSongKeys.count) 首")
                        : (selectedAlbumKeys.isEmpty ? "选择专辑" : "已选 \(selectedAlbumKeys.count) 张"))
                    : "歌手主页"
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !isMultiSelecting {
                        Button("关闭") { dismiss() }
                            .font(ATMusicFont.appFont(15))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isMultiSelecting {
                        let totalCount = selectedSection == .songs ? filteredSongs.count : visibleAlbums.count
                        let isAll = selectedSection == .songs
                            ? (selectedSongKeys.count == totalCount && !filteredSongs.isEmpty)
                            : (selectedAlbumKeys.count == totalCount && !visibleAlbums.isEmpty)
                        HStack(spacing: 12) {
                            Button(isAll ? "取消全选" : "全选") {
                                ATMusicHaptics.tap()
                                if selectedSection == .songs {
                                    if selectedSongKeys.count == filteredSongs.count {
                                        selectedSongKeys.removeAll()
                                    } else {
                                        selectedSongKeys = Set(filteredSongs.map(\.identityKey))
                                    }
                                } else {
                                    if selectedAlbumKeys.count == visibleAlbums.count {
                                        selectedAlbumKeys.removeAll()
                                    } else {
                                        selectedAlbumKeys = Set(visibleAlbums.map(\.identityKey))
                                    }
                                }
                            }
                            .font(ATMusicFont.appFont(13, .semibold))
                            .foregroundStyle(Color.atmusicAmber)

                            Button("完成") {
                                ATMusicHaptics.tap()
                                isMultiSelecting = false
                                selectedSongKeys.removeAll()
                                selectedAlbumKeys.removeAll()
                            }
                            .font(ATMusicFont.appFont(13, .semibold))
                        }
                    } else {
                        Menu {
                            Button {
                                ATMusicHaptics.select()
                                isMultiSelecting = true
                            } label: {
                                Label(selectedSection == .songs ? "多选歌曲" : "多选专辑", systemImage: "checklist")
                            }
                            .disabled(selectedSection == .songs ? filteredSongs.isEmpty : visibleAlbums.isEmpty)

                            Divider()

                            Menu {
                                Button("全选平台") {
                                    selectedSourceRaws = Set(sourceFilterOptions.map(\.rawValue))
                                    ATMusicHaptics.select()
                                }
                                Divider()
                                ForEach(sourceFilterOptions, id: \.rawValue) { source in
                                    Button {
                                        toggleSource(source)
                                    } label: {
                                        Label(sourceTitle(source), systemImage: selectedSourceRaws.contains(source.rawValue) ? "checkmark.circle.fill" : "circle")
                                    }
                                }
                            } label: {
                                Label("过滤平台", systemImage: "line.3.horizontal.decrease.circle")
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
        }
        .task { await loadAllSources() }
        .onChange(of: synology.libraryIndexRevision) { _ in
            Task { await mergeFullNASArtist() }
        }
        .modifier(ATMusicSheetModifier(detents: [.large], dragIndicator: true))
    }

    private var header: some View {
        HStack(spacing: 14) {
            CoverImage(url: songs.first?.coverURL, size: 76, cornerRadius: 38)
            VStack(alignment: .leading, spacing: 6) {
                Text(artistName)
                    .font(ATMusicFont.appFont(21, .bold))
                    .foregroundStyle(Color.atmusicLabel)
                    .lineLimit(2)
                Text("歌曲 \(visibleSongs.count) 首 · 专辑 \(visibleAlbums.count) 张")
                    .font(ATMusicFont.appFont(12))
                    .foregroundStyle(Color.atmusicComment)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }

    private var songsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "全部歌曲")
                .padding(.horizontal, 16)

            if !filteredSongs.isEmpty {
                HStack(spacing: 12) {
                    GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                        ATMusicHaptics.tap()
                        player.play(songs: filteredSongs, startAt: 0)
                    }
                    .frame(maxWidth: .infinity)

                    GlassButton(title: "随机播放", systemName: "shuffle", prominent: false) {
                        ATMusicHaptics.tap()
                        player.play(songs: filteredSongs.shuffled(), startAt: 0)
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 2)
            }
            if !visibleSongs.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color.atmusicComment)
                    TextField("搜索歌手歌曲", text: $searchText)
                        .font(ATMusicFont.appFont(14))
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 14, style: .continuous)) }
            }
            LazyVStack(spacing: 0) {
                ForEach(Array(filteredSongs.enumerated()), id: \.element.identityKey) { index, song in
                    SongCell(
                        song: song,
                        glassRow: false,
                        playbackContext: filteredSongs,
                        playbackIndex: index,
                        onTap: {
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
            }
            .padding(.horizontal, 16)
        }
    }

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "全部专辑")
                .padding(.horizontal, 16)
            if visibleAlbums.isEmpty {
                Text("暂无专辑")
                    .font(ATMusicFont.appFont(13))
                    .foregroundStyle(Color.atmusicComment)
                    .padding(.horizontal, 16)
            } else {
                LazyVGrid(columns: DeviceLayoutHelper.adaptiveCardColumns(for: horizontalSizeClass, minWidth: 140, maxWidth: 200, spacing: 16), spacing: 18) {
                    ForEach(visibleAlbums) { album in
                        if isMultiSelecting {
                            MediaSquareCard(
                                album: album,
                                showSourceBadge: true,
                                isMultiSelecting: true,
                                isSelected: selectedAlbumKeys.contains(album.identityKey),
                                onToggleSelection: {
                                    toggleAlbumSelection(album)
                                }
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                toggleAlbumSelection(album)
                            }
                        } else {
                            NavigationLink {
                                if album.source == .synology {
                                    SynologyAlbumView(albumName: album.name, artistName: album.artistName, coverURL: album.coverURL, isModal: false)
                                        .environmentObject(player)
                                        .environmentObject(theme)
                                } else {
                                    AlbumDetailView(album: album, isModal: false)
                                        .environmentObject(player)
                                        .environmentObject(theme)
                                }
                            } label: {
                                MediaSquareCard(album: album, showSourceBadge: true)
                            }
                            .buttonStyle(GlassPressButtonStyle(scale: 0.97))
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var filteredSongs: [Song] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return visibleSongs }
        return visibleSongs.filter {
            $0.name.lowercased().contains(query)
                || $0.artists.lowercased().contains(query)
                || $0.album.lowercased().contains(query)
        }
    }

    private var visibleSongs: [Song] {
        songs.filter { selectedSourceRaws.contains($0.source.rawValue) }
    }

    private var visibleAlbums: [Album] {
        albums.filter { selectedSourceRaws.contains($0.source.rawValue) }
    }

    private func loadAllSources() async {
        await MainActor.run {
            songs = initialSongs
            loading = initialSongs.isEmpty
        }
        let enabledRaws = Set(platformPrefs.enabledSearchProviders.map { $0.songSource.rawValue })
        let activeLoaders = Self.sourceLoaders.filter { enabledRaws.contains($0.name) }
        await withTaskGroup(of: ([Song], [Album]).self) { group in
            for loader in activeLoaders {
                group.addTask { await loader.load(artistName) }
            }
            for await result in group {
                await MainActor.run {
                    merge(songs: result.0, albums: result.1)
                    loading = false
                }
            }
        }
        await mergeFullNASArtist()
        await MainActor.run { loading = false }
    }

    private func mergeFullNASArtist() async {
        guard platformPrefs.isEnabled(SearchProvider.synology), synology.isLoggedIn else { return }
        guard let all = try? await synology.librarySongs() else { return }
        let matched = all.filter { Self.artistMatches($0.artists, artistName: artistName) }
        await MainActor.run {
            merge(songs: matched, albums: Self.albumsFromSongs(matched))
            loading = false
        }
    }

    @MainActor
    private func merge(songs newSongs: [Song], albums newAlbums: [Album]) {
        var seenSongs = Set(songs.map(\.identityKey))
        songs.append(contentsOf: newSongs.filter { seenSongs.insert($0.identityKey).inserted })
        // 平台专辑接口可能暂时不可用，但歌曲通常仍带有 album 字段；
        // 先从歌曲补出专辑入口，保证平台不会出现“只有 NAS 有专辑”的空状态。
        let albumsToMerge = newAlbums + Self.albumsFromSongs(newSongs)
        var seenAlbums = Set(albums.map { "\($0.source.rawValue)|\($0.name.lowercased())|\($0.artistName.lowercased())" })
        albums.append(contentsOf: albumsToMerge.filter {
            seenAlbums.insert("\($0.source.rawValue)|\($0.name.lowercased())|\($0.artistName.lowercased())").inserted
        })
    }

    private static func loadNetEase(name: String) async -> ([Song], [Album]) {
        guard let artist = try? await NetEaseAPI.shared.searchArtists(keyword: name, limit: 5), let first = artist.first,
              let id = Int(first.id.replacingOccurrences(of: "netease-", with: "")) else { return ([], []) }
        async let songs = (try? await NetEaseAPI.shared.artistHotSongs(artistID: id, limit: 5_000)) ?? []
        async let albums = (try? await NetEaseAPI.shared.artistAlbums(artistID: id, limit: 5_000)) ?? []
        var songList = await songs
        if songList.count < 100 {
            var fallback = songList
            for offset in stride(from: 0, to: 2_000, by: 100) {
                let batch = (try? await NetEaseAPI.shared.search(keyword: name, limit: 100, offset: offset)) ?? []
                if batch.isEmpty { break }
                fallback.append(contentsOf: batch.filter { artistMatches($0.artists, artistName: name) })
                if batch.count < 100 { break }
            }
            songList = deduplicatedSongs(fallback)
        }
        let albumList = await albums
        return (songList, albumList.isEmpty ? albumsFromSongs(songList) : albumList)
    }

    private static func loadQQ(name: String) async -> ([Song], [Album]) {
        let first = (try? await QQMusicAPI.shared.searchArtists(keyword: name, limit: 5))?.first
        let mid = first?.id.hasPrefix("qq-") == false ? first?.id : nil
        async let songs = (try? await QQMusicAPI.shared.artistHotSongs(mid: mid, name: name, limit: 5_000)) ?? []
        async let albums = (try? await QQMusicAPI.shared.artistAlbums(mid: mid, name: name, limit: 5_000)) ?? []
        var songList = await songs
        if songList.count < 100 {
            var fallback = songList
            for offset in stride(from: 0, to: 2_000, by: 30) {
                let batch = (try? await QQMusicAPI.shared.searchSongs(keyword: name, limit: 30, offset: offset)) ?? []
                if batch.isEmpty { break }
                fallback.append(contentsOf: batch.filter { artistMatches($0.artists, artistName: name) })
                if batch.count < 30 { break }
            }
            songList = deduplicatedSongs(fallback)
        }
        let albumList = await albums
        return (songList, albumList.isEmpty ? albumsFromSongs(songList) : albumList)
    }

    private static func loadKugou(name: String) async -> ([Song], [Album]) {
        guard let artist = try? await KugouMusicAPI.shared.searchArtists(keyword: name, limit: 5), let first = artist.first else { return ([], []) }
        let authorID = first.id.replacingOccurrences(of: "kugou-", with: "")
        var songs: [Song] = []
        var seen = Set<String>()
        for page in 1...100 {
            let batch = (try? await KugouMusicAPI.shared.artistSongs(authorID: authorID, page: page, limit: 100)) ?? []
            if batch.isEmpty { break }
            songs.append(contentsOf: batch.filter { seen.insert($0.identityKey).inserted })
                // 酷狗部分歌手接口会返回不足 100 首的短页，不能据此判断已到末尾。
        }
        if songs.count < 100 {
            let fallback = (try? await KugouMusicAPI.shared.searchSongs(keyword: name, limit: 1_000)) ?? []
            songs.append(contentsOf: fallback.filter { artistMatches($0.artists, artistName: name) })
            songs = deduplicatedSongs(songs)
        }
        return (songs, albumsFromSongs(songs))
    }

    private static func loadNAS(name: String) async -> ([Song], [Album]) {
        let result = try? await SynologyAPI.shared.searchAllVariants(keyword: name, limit: 200)
        let songs = result?.songs ?? []
        return (songs, albumsFromSongs(songs))
    }

    private static func loadSubsonic(name: String) async -> ([Song], [Album]) {
        let result = try? await SubsonicAPI.shared.searchAllVariants(keyword: name, limit: 200)
        let songs = result?.songs ?? []
        return (songs, albumsFromSongs(songs))
    }

    private static func loadJellyfin(name: String) async -> ([Song], [Album]) {
        let result = try? await JellyfinAPI.shared.searchAllVariants(keyword: name, limit: 200)
        let songs = result?.songs ?? []
        return (songs, albumsFromSongs(songs))
    }

    private static func loadWebDAV(name: String) async -> ([Song], [Album]) {
        let result = try? await WebDAVAPI.shared.searchAllVariants(keyword: name, limit: 200)
        let songs = result?.songs ?? []
        return (songs, albumsFromSongs(songs))
    }

    private static func artistMatches(_ value: String, artistName: String) -> Bool {
        let query = normalizeArtist(artistName)
        guard !query.isEmpty else { return false }
        let normalizedValue = normalizeArtist(value)
        if normalizedValue == query || normalizedValue.contains(query) || query.contains(normalizedValue) {
            return true
        }
        return value.split { "/／,，、&＆+＋|｜;；".contains($0) }
            .contains { normalizeArtist(String($0)) == query }
    }

    private static func deduplicatedSongs(_ songs: [Song]) -> [Song] {
        var seen = Set<String>()
        return songs.filter { seen.insert($0.identityKey).inserted }
    }

    private static func normalizeArtist(_ value: String) -> String {
        let simplified = value.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? value
        return simplified.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    private static func albumsFromSongs(_ songs: [Song]) -> [Album] {
        var seen = Set<String>()
        return songs.compactMap { song in
            let name = song.album.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name != "群晖 NAS" else { return nil }
            let key = "\(song.source.rawValue)|\(name.lowercased())|\(song.artists.lowercased())"
            guard seen.insert(key).inserted else { return nil }
            let count = songs.filter { $0.source == song.source && $0.album == name }.count
            return Album(id: "\(song.source.rawValue)-artist-album-\(key)", name: name, artistName: song.artists, coverURL: song.coverURL, source: song.source, trackCount: count)
        }
    }
}
