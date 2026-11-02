import SwiftUI

/// Subsonic 音乐库浏览主界面：艺术家 / 专辑 / 歌单 / 搜索 四个简化入口。
/// 刻意不照搬 SynologyMusicView 的标签回写/歌词批量处理等群晖专属工具——
/// Subsonic 协议本身不支持写回原始文件，这些功能在这个后端上没有对应的服务端能力。
struct SubsonicMusicView: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @ObservedObject private var subsonic = SubsonicAPI.shared

    @State private var selectedTab: Int = 0 // 0: 艺术家 1: 歌单 2: 搜索
    @State private var artists: [Artist] = []
    @State private var playlists: [Playlist] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showConfigSheet = false

    @State private var searchText: String = ""
    @State private var searchResult: NASSearchResult?
    @State private var isSearching = false

    var body: some View {
        ZStack {
            GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)

            if !subsonic.isLoggedIn {
                notConnectedView
            } else if isLoading && artists.isEmpty && playlists.isEmpty {
                LoadingStateView()
            } else if let errorMessage, artists.isEmpty {
                ErrorStateView(message: errorMessage) {
                    Task { await loadData() }
                }
            } else {
                contentBody
            }
        }
        .navigationTitle("Subsonic 音乐库")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showConfigSheet = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.atmusicAmber)
                }
            }
        }
        .sheet(isPresented: $showConfigSheet) {
            SubsonicLoginSheet().environmentObject(theme)
        }
        .task {
            if subsonic.isLoggedIn { await loadData() }
        }
    }

    private var notConnectedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "server.rack")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(Color.atmusicComment)
            Text("尚未连接 Subsonic 服务器")
                .font(ATMusicFont.appFont(15, .medium))
                .foregroundStyle(Color.atmusicLabel)
            GlassButton(title: "立即配置", systemName: "link") {
                showConfigSheet = true
            }
        }
    }

    private var contentBody: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text("艺术家").tag(0)
                Text("歌单").tag(1)
                Text("搜索").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            switch selectedTab {
            case 0: artistsList
            case 1: playlistsList
            default: searchSection
            }
        }
    }

    private var artistsList: some View {
        List(artists) { artist in
            NavigationLink(value: SubsonicRoute.artist(artist)) {
                HStack(spacing: 12) {
                    RemoteCoverThumbnail(url: artist.coverURL, size: 44)
                    Text(artist.name)
                        .font(ATMusicFont.appFont(14))
                        .foregroundStyle(Color.atmusicLabel)
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await loadData() }
        .navigationDestination(for: SubsonicRoute.self) { route in
            switch route {
            case .artist(let artist):
                SubsonicAlbumsListView(artist: artist)
            case .album(let album):
                SubsonicSongsListView(album: album)
            case .playlist(let playlist):
                SubsonicPlaylistSongsView(playlist: playlist)
            }
        }
    }

    private var playlistsList: some View {
        List(playlists) { playlist in
            NavigationLink(value: SubsonicRoute.playlist(playlist)) {
                HStack(spacing: 12) {
                    RemoteCoverThumbnail(url: playlist.coverURL, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(playlist.name)
                            .font(ATMusicFont.appFont(14))
                            .foregroundStyle(Color.atmusicLabel)
                        Text("\(playlist.trackCount) 首")
                            .font(ATMusicFont.appFont(11))
                            .foregroundStyle(Color.atmusicComment)
                    }
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await loadData() }
    }

    private var searchSection: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.atmusicComment)
                TextField("搜索歌曲 / 艺术家 / 专辑", text: $searchText)
                    .font(ATMusicFont.appFont(14))
                    .onSubmit { Task { await performSearch() } }
            }
            .padding(12)
            .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            if isSearching {
                LoadingStateView()
            } else if let searchResult {
                List {
                    if !searchResult.songs.isEmpty {
                        Section("歌曲") {
                            ForEach(searchResult.songs, id: \.identityKey) { song in
                                Button {
                                    player.play(songs: searchResult.songs, startAt: searchResult.songs.firstIndex(of: song) ?? 0)
                                } label: {
                                    SongRow(song: song)
                                }
                            }
                        }
                    }
                    if !searchResult.albums.isEmpty {
                        Section("专辑") {
                            ForEach(searchResult.albums, id: \.identityKey) { album in
                                NavigationLink(value: SubsonicRoute.album(album)) {
                                    Text(album.name)
                                        .font(ATMusicFont.appFont(14))
                                        .foregroundStyle(Color.atmusicLabel)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            } else {
                Spacer()
            }
        }
    }

    private func loadData() async {
        isLoading = true
        errorMessage = nil
        do {
            async let a = subsonic.fetchArtists()
            async let p = subsonic.allPlaylists()
            artists = try await a
            playlists = try await p
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func performSearch() async {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isSearching = true
        searchResult = try? await subsonic.searchAllVariants(keyword: searchText, limit: 50)
        isSearching = false
    }
}

private enum SubsonicRoute: Hashable {
    case artist(Artist)
    case album(Album)
    case playlist(Playlist)
}

private struct SubsonicAlbumsListView: View {
    let artist: Artist
    @State private var albums: [Album] = []
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                LoadingStateView()
            } else {
                List(albums) { album in
                    NavigationLink(value: SubsonicRoute.album(album)) {
                        HStack(spacing: 12) {
                            RemoteCoverThumbnail(url: album.coverURL, size: 44)
                            Text(album.name)
                                .font(ATMusicFont.appFont(14))
                                .foregroundStyle(Color.atmusicLabel)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(artist.name)
        .task {
            albums = (try? await SubsonicAPI.shared.fetchAlbums(for: artist)) ?? []
            isLoading = false
        }
    }
}

private struct SubsonicSongsListView: View {
    let album: Album
    @EnvironmentObject private var player: PlayerManager
    @State private var songs: [Song] = []
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                LoadingStateView()
            } else {
                List {
                    ForEach(songs, id: \.identityKey) { song in
                        Button {
                            player.play(songs: songs, startAt: songs.firstIndex(of: song) ?? 0)
                        } label: {
                            SongRow(song: song)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(album.name)
        .task {
            songs = (try? await SubsonicAPI.shared.fetchSongs(for: album)) ?? []
            isLoading = false
        }
    }
}

private struct SubsonicPlaylistSongsView: View {
    let playlist: Playlist
    @EnvironmentObject private var player: PlayerManager
    @State private var songs: [Song] = []
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                LoadingStateView()
            } else {
                List {
                    ForEach(songs, id: \.identityKey) { song in
                        Button {
                            player.play(songs: songs, startAt: songs.firstIndex(of: song) ?? 0)
                        } label: {
                            SongRow(song: song)
                        }
                    }
                    .onDelete { offsets in
                        var updated = songs
                        updated.remove(atOffsets: offsets)
                        songs = updated
                        Task { _ = try? await SubsonicAPI.shared.updatePlaylist(playlist, songs: updated) }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(playlist.name)
        .task {
            songs = (try? await SubsonicAPI.shared.playlistSongs(playlist: playlist)) ?? []
            isLoading = false
        }
    }
}

/// 简单的歌曲行：封面缩略图 + 标题/歌手，复用于搜索结果与专辑/歌单曲目列表。
private struct SongRow: View {
    let song: Song

    var body: some View {
        HStack(spacing: 12) {
            RemoteCoverThumbnail(url: song.coverURL, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.name)
                    .font(ATMusicFont.appFont(14))
                    .foregroundStyle(Color.atmusicLabel)
                    .lineLimit(1)
                Text(song.artists)
                    .font(ATMusicFont.appFont(11))
                    .foregroundStyle(Color.atmusicComment)
                    .lineLimit(1)
            }
            Spacer()
            Text(song.formattedDuration)
                .font(ATMusicFont.appFont(11))
                .foregroundStyle(Color.atmusicComment)
        }
    }
}

/// 小型远程封面缩略图，自带占位图标，避免在 List 行里重复写 AsyncImage 占位逻辑。
private struct RemoteCoverThumbnail: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Color.black.opacity(0.06)
                    .overlay(Image(systemName: "music.note").foregroundStyle(Color.atmusicComment))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
