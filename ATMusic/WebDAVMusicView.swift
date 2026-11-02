import SwiftUI

/// WebDAV 音乐浏览主界面。WebDAV 的"专辑/艺术家"是基于目录结构的启发式模拟，精度不如
/// Subsonic/Jellyfin 的标签驱动分类，因此把"文件夹浏览"作为主入口（最贴近 WebDAV 的文件本质，
/// 用户理解成本最低），专辑/艺术家/歌单/搜索作为辅助分类方式。
struct WebDAVMusicView: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @ObservedObject private var webdav = WebDAVAPI.shared

    private enum Mode: Int, CaseIterable {
        case folders, albums, artists, playlists, search

        var title: String {
            switch self {
            case .folders: return "文件夹"
            case .albums: return "专辑"
            case .artists: return "艺术家"
            case .playlists: return "歌单"
            case .search: return "搜索"
            }
        }
    }

    @State private var mode: Mode = .folders
    @State private var showConfigSheet = false

    var body: some View {
        ZStack {
            GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)

            if !webdav.isLoggedIn {
                notConnectedView
            } else {
                VStack(spacing: 0) {
                    modePicker
                    content
                }
            }
        }
        .navigationTitle("WebDAV 音乐库")
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
            WebDAVLoginSheet().environmentObject(theme)
        }
    }

    private var notConnectedView: some View {
        VStack(spacing: 20) {
            Image(systemName: "folder.fill.badge.gearshape")
                .font(.system(size: 64))
                .foregroundStyle(Color.atmusicAmber)
            Text("尚未连接 WebDAV")
                .font(ATMusicFont.appFont(18, .bold))
                .foregroundStyle(Color.atmusicLabel)
            Text("连接您的 WebDAV 服务\n即可在 AT Music 中播放私有音乐文件")
                .font(ATMusicFont.appFont(13))
                .foregroundStyle(Color.atmusicComment)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
            Button {
                showConfigSheet = true
            } label: {
                Text("立即连接")
                    .font(ATMusicFont.appFont(15, .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                    .background(Color.atmusicAmber, in: Capsule())
            }
            .buttonStyle(GlassPressButtonStyle())
        }
        .padding(32)
    }

    private var modePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Mode.allCases, id: \.rawValue) { m in
                    Button {
                        mode = m
                    } label: {
                        Text(m.title)
                            .font(ATMusicFont.appFont(13, mode == m ? .semibold : .regular))
                            .foregroundStyle(mode == m ? Color.white : Color.atmusicLabel)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(mode == m ? Color.atmusicAmber : Color.primary.opacity(0.06), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .folders: WebDAVFolderBrowser(player: player)
        case .albums: WebDAVAlbumsList(player: player)
        case .artists: WebDAVArtistsList(player: player)
        case .playlists: WebDAVPlaylistsList(player: player)
        case .search: WebDAVSearchView(player: player)
        }
    }
}

// MARK: - 文件夹浏览

private struct WebDAVFolderBrowser: View {
    let player: PlayerManager
    @State private var pathStack: [String] = []
    @State private var songsInFolder: [Song] = []
    @State private var subfolders: [String] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var currentPath: String {
        pathStack.last ?? WebDAVAPI.shared.musicRoot
    }

    var body: some View {
        VStack(spacing: 0) {
            if !pathStack.isEmpty {
                HStack {
                    Button {
                        pathStack.removeLast()
                    } label: {
                        Label("返回上级", systemImage: "chevron.left")
                            .font(ATMusicFont.appFont(13, .semibold))
                            .foregroundStyle(Color.atmusicAmber)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }

            if isLoading {
                LoadingStateView()
            } else if let errorMessage {
                ErrorStateView(message: errorMessage) { Task { await load() } }
            } else {
                List {
                    ForEach(subfolders, id: \.self) { folder in
                        Button {
                            pathStack.append(folder)
                        } label: {
                            Label((folder as NSString).lastPathComponent, systemImage: "folder.fill")
                                .foregroundStyle(Color.atmusicLabel)
                        }
                    }
                    ForEach(Array(songsInFolder.enumerated()), id: \.element.identityKey) { index, song in
                        SongCell(song: song, playbackContext: songsInFolder, playbackIndex: index) {
                            player.play(songs: songsInFolder, startAt: index)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .task(id: currentPath) { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let (folders, songs) = try await WebDAVAPI.shared.listFolder(path: currentPath)
            subfolders = folders
            songsInFolder = songs
            isLoading = false
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 专辑（启发式）

private struct WebDAVAlbumsList: View {
    let player: PlayerManager
    @State private var albums: [Album] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                LoadingStateView()
            } else if let errorMessage {
                ErrorStateView(message: errorMessage) { Task { await load() } }
            } else {
                List(albums) { album in
                    NavigationLink {
                        WebDAVAlbumDetailView(album: album, player: player)
                    } label: {
                        Label(album.name, systemImage: "square.stack.fill")
                            .foregroundStyle(Color.atmusicLabel)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            albums = try await WebDAVAPI.shared.fetchAlbums(for: nil)
            isLoading = false
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }
}

private struct WebDAVAlbumDetailView: View {
    let album: Album
    let player: PlayerManager
    @State private var songs: [Song] = []

    var body: some View {
        List {
            ForEach(Array(songs.enumerated()), id: \.element.identityKey) { index, song in
                SongCell(song: song, playbackContext: songs, playbackIndex: index) {
                    player.play(songs: songs, startAt: index)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .navigationTitle(album.name)
        .task {
            songs = (try? await WebDAVAPI.shared.fetchSongs(for: album)) ?? []
        }
    }
}

// MARK: - 艺术家（启发式）

private struct WebDAVArtistsList: View {
    let player: PlayerManager
    @State private var artists: [Artist] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                LoadingStateView()
            } else if let errorMessage {
                ErrorStateView(message: errorMessage) { Task { await load() } }
            } else {
                List(artists) { artist in
                    NavigationLink {
                        WebDAVArtistAlbumsView(artist: artist, player: player)
                    } label: {
                        Label(artist.name, systemImage: "person.fill")
                            .foregroundStyle(Color.atmusicLabel)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            artists = try await WebDAVAPI.shared.fetchArtists()
            isLoading = false
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }
}

private struct WebDAVArtistAlbumsView: View {
    let artist: Artist
    let player: PlayerManager
    @State private var albums: [Album] = []

    var body: some View {
        List(albums) { album in
            NavigationLink {
                WebDAVAlbumDetailView(album: album, player: player)
            } label: {
                Label(album.name, systemImage: "square.stack.fill")
                    .foregroundStyle(Color.atmusicLabel)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .navigationTitle(artist.name)
        .task {
            albums = (try? await WebDAVAPI.shared.fetchAlbums(for: artist)) ?? []
        }
    }
}

// MARK: - 歌单

private struct WebDAVPlaylistsList: View {
    let player: PlayerManager
    @State private var playlists: [Playlist] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showCreate = false
    @State private var newName = ""

    var body: some View {
        Group {
            if isLoading {
                LoadingStateView()
            } else if let errorMessage {
                ErrorStateView(message: errorMessage) { Task { await load() } }
            } else {
                List {
                    ForEach(playlists) { playlist in
                        NavigationLink {
                            WebDAVPlaylistDetailView(playlist: playlist, player: player, onDeleted: { Task { await load() } })
                        } label: {
                            Label(playlist.name, systemImage: "music.note.list")
                                .foregroundStyle(Color.atmusicLabel)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showCreate = true } label: {
                    Image(systemName: "plus.circle")
                }
            }
        }
        .alert("新建歌单", isPresented: $showCreate) {
            TextField("歌单名称", text: $newName)
            Button("创建") {
                Task {
                    _ = try? await WebDAVAPI.shared.createPlaylist(name: newName, songs: [])
                    newName = ""
                    await load()
                }
            }
            Button("取消", role: .cancel) {}
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            playlists = try await WebDAVAPI.shared.allPlaylists()
            isLoading = false
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }
}

private struct WebDAVPlaylistDetailView: View {
    let playlist: Playlist
    let player: PlayerManager
    var onDeleted: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var songs: [Song] = []

    var body: some View {
        List {
            ForEach(Array(songs.enumerated()), id: \.element.identityKey) { index, song in
                SongCell(song: song, playbackContext: songs, playbackIndex: index) {
                    player.play(songs: songs, startAt: index)
                }
            }
            .onDelete { offsets in
                songs.remove(atOffsets: offsets)
                Task { _ = try? await WebDAVAPI.shared.updatePlaylist(playlist, songs: songs) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .navigationTitle(playlist.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    Task {
                        _ = try? await WebDAVAPI.shared.deletePlaylist(playlist)
                        onDeleted()
                        dismiss()
                    }
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .task {
            songs = (try? await WebDAVAPI.shared.playlistSongs(playlist: playlist)) ?? []
        }
    }
}

// MARK: - 搜索

private struct WebDAVSearchView: View {
    let player: PlayerManager
    @State private var keyword = ""
    @State private var result: NASSearchResult?
    @State private var isSearching = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.atmusicComment)
                TextField("搜索歌曲 / 专辑 / 艺术家", text: $keyword)
                    .font(ATMusicFont.appFont(14))
                    .onSubmit { Task { await search() } }
            }
            .padding(12)
            .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            .padding(16)

            if isSearching {
                LoadingStateView()
            } else if let result {
                List {
                    if !result.songs.isEmpty {
                        Section("歌曲") {
                            ForEach(Array(result.songs.enumerated()), id: \.element.identityKey) { index, song in
                                SongCell(song: song, playbackContext: result.songs, playbackIndex: index) {
                                    player.play(songs: result.songs, startAt: index)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            Spacer()
        }
    }

    private func search() async {
        guard !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSearching = true
        result = try? await WebDAVAPI.shared.searchAllVariants(keyword: keyword, limit: 100)
        isSearching = false
    }
}
