import SwiftUI

/// 统一加歌面板（阶段 3）：替代旧的 AddToPlaylistSheet（仅网易 + 加歌即红心）
/// 与 AddToLocalPlaylistSheet（仅本地），三组目标一次到位：本地 / 网易 / NAS。
///
/// - 本地：行内直接显示「已在其中 / 部分已在」状态，点按可加入或移除。
/// - 网易：不逐单查成员（每单都要一次网络请求），点按直接加入，服务端去重。
/// - NAS：只接受 NAS 曲库内的歌曲（有 synologyId/path 的），其它歌曲无法写入 Audio Station。
/// - QQ、酷狗：平台加歌接口未封装，不列入直接目标，底部注明转存本地路径。
/// - 旧的「加歌即红心」隐藏副作用改为显式开关，默认关。
struct AddToPlaylistSheet: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var auth: AuthStore
    @ObservedObject private var localStore = LocalLibraryStore.shared
    @ObservedObject private var synology = SynologyAPI.shared
    @Environment(\.dismiss) private var dismiss

    private let favorites = FavoritesStore.shared

    let songs: [Song]

    init(song: Song) {
        self.songs = [song]
    }

    init(songs: [Song]) {
        self.songs = songs
    }

    @State private var nasPlaylists: [Playlist] = []
    @State private var showCreateField = false
    @State private var newName = ""
    @State private var createTarget: CreateTarget = .local
    @State private var alsoFavorite = false
    @State private var message: String?

    private enum CreateTarget: String, CaseIterable, Identifiable {
        case local = "本地歌单"
        case netease = "网易歌单"
        case nas = "NAS 歌单"
        var id: String { rawValue }
    }

    private enum LocalMembership {
        case none, partial(Int, Int), all
    }

    private func localMembership(for playlist: LocalPlaylist) -> LocalMembership {
        let contained = songs.filter { song in
            playlist.songs.contains { LocalLibraryStore.isMatchingSong($0, song) }
        }.count
        if contained == songs.count { return .all }
        if contained == 0 { return .none }
        return .partial(contained, songs.count)
    }

    private var nasEligibleSongs: [Song] {
        songs.filter { song in
            !(song.synologyId?.isEmpty ?? true) || !(song.synologyPath?.isEmpty ?? true)
        }
    }

    private var neteaseEligibleSongs: [Song] {
        songs.filter { $0.id != 0 }
    }

    var body: some View {
        let _ = theme.accent
        ATMusicNavigationStack {
            List {
                // MARK: - 本地歌单
                Section(songs.count > 1 ? "本地歌单（批量加入 \(songs.count) 首）" : "本地歌单") {
                    if localStore.playlists.isEmpty {
                        Text("还没有本地歌单，先在下面创建一个吧")
                            .foregroundStyle(Color.atmusicComment)
                    } else {
                        ForEach(localStore.playlists) { playlist in
                            let membership = localMembership(for: playlist)
                            Button {
                                Task { await toggleLocal(playlist, membership: membership) }
                            } label: {
                                HStack(spacing: 12) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(LinearGradient(colors: [Color.atmusicAmber.opacity(0.75), Color.atmusicAmber.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                            .frame(width: 40, height: 40)
                                        Image(systemName: "music.note.list")
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(.white)
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(playlist.name)
                                            .font(ATMusicFont.appFont(15, .medium))
                                            .foregroundStyle(Color.atmusicLabel)
                                            .lineLimit(1)
                                        Text(atmusicLocalSongCountText(playlist.songs.count))
                                            .font(ATMusicFont.appFont(11))
                                            .foregroundStyle(Color.atmusicComment)
                                    }
                                    Spacer()
                                    switch membership {
                                    case .all:
                                        Text("已在其中")
                                            .font(ATMusicFont.appFont(12, .medium))
                                            .foregroundStyle(Color.atmusicSage)
                                    case .partial(let have, let total):
                                        Text("已有 \(have)/\(total) 首")
                                            .font(ATMusicFont.appFont(12, .medium))
                                            .foregroundStyle(Color.atmusicAmber)
                                    case .none:
                                        Image(systemName: "plus.circle.fill")
                                            .font(.system(size: 15))
                                            .foregroundStyle(Color.atmusicAmber)
                                    }
                                }
                            }
                        }
                    }
                }

                // MARK: - 网易歌单
                Section("网易歌单") {
                    if !auth.isLoggedIn {
                        Text("登录网易云后可加入云端歌单")
                            .foregroundStyle(Color.atmusicComment)
                    } else if auth.playlists.isEmpty {
                        Text("暂无网易歌单，请先在歌单管理里创建一个")
                            .foregroundStyle(Color.atmusicComment)
                    } else {
                        ForEach(auth.playlists) { playlist in
                            Button {
                                Task { await addToNetEase(playlist) }
                            } label: {
                                HStack(spacing: 12) {
                                    CoverImage(url: playlist.coverURL, size: 38, cornerRadius: 8)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(playlist.name)
                                            .font(ATMusicFont.appFont(15))
                                            .foregroundStyle(Color.atmusicLabel)
                                            .lineLimit(1)
                                        Text(atmusicSongCountText(playlist.trackCount))
                                            .font(ATMusicFont.appFont(11))
                                            .foregroundStyle(Color.atmusicComment)
                                    }
                                    Spacer()
                                    Image(systemName: "plus.circle.fill")
                                        .font(.system(size: 15))
                                        .foregroundStyle(Color.atmusicAmber)
                                }
                            }
                        }
                    }
                }

                // MARK: - NAS 歌单
                if synology.isLoggedIn {
                    Section("NAS 歌单") {
                        if nasPlaylists.isEmpty {
                            Text("暂无 NAS 歌单，请先在 Audio Station 里创建")
                                .foregroundStyle(Color.atmusicComment)
                        } else {
                            ForEach(nasPlaylists) { playlist in
                                Button {
                                    Task { await addToNAS(playlist) }
                                } label: {
                                    HStack(spacing: 12) {
                                        CoverImage(url: playlist.coverURL, size: 38, cornerRadius: 8)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(playlist.name)
                                                .font(ATMusicFont.appFont(15))
                                                .foregroundStyle(Color.atmusicLabel)
                                                .lineLimit(1)
                                            Text(atmusicSongCountText(playlist.trackCount))
                                                .font(ATMusicFont.appFont(11))
                                                .foregroundStyle(Color.atmusicComment)
                                        }
                                        Spacer()
                                        Image(systemName: "plus.circle.fill")
                                            .font(.system(size: 15))
                                            .foregroundStyle(Color.atmusicAmber)
                                    }
                                }
                            }
                        }
                    }
                }

                // MARK: - 新建歌单
                if showCreateField {
                    Section("新建歌单") {
                        TextField("歌单名称", text: $newName)
                            .submitLabel(.done)
                        Picker("建到", selection: $createTarget) {
                            ForEach(CreateTarget.allCases) { target in
                                Text(target.rawValue).tag(target)
                            }
                        }
                        Button {
                            Task { await createAndAdd() }
                        } label: {
                            Text("创建并加入")
                                .font(ATMusicFont.appFont(15, .semibold))
                                .foregroundStyle(Color.atmusicAmber)
                        }
                    }
                } else {
                    Section {
                        Button {
                            showCreateField = true
                        } label: {
                            Label("新建歌单并加入", systemImage: "plus.circle")
                        }
                    }
                }

                Section {
                    Toggle("同时红心收藏", isOn: $alsoFavorite)
                        .font(ATMusicFont.appFont(14))
                } header: {
                    Text("选项")
                } footer: {
                    Text("红心对应各平台的「我喜欢的音乐」，默认不开启。")
                }

                if let message {
                    Section {
                        Text(message)
                            .font(ATMusicFont.appFont(13))
                            .foregroundStyle(Color.atmusicSage)
                    }
                }

                Section {
                    Text("QQ、酷狗歌单暂不支持直接加歌：可在歌单详情里转存为本地歌单后编辑。")
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(Color.atmusicComment)
                }
            }
            .navigationTitle(songs.count > 1 ? "批量加入歌单" : "添加到歌单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .task {
            if synology.isLoggedIn {
                nasPlaylists = (try? await SynologyAPI.shared.allPlaylists()) ?? []
            }
        }
    }

    // MARK: - 动作

    private func applyAlsoFavorite() async {
        guard alsoFavorite else { return }
        for song in songs where !favorites.isLiked(song) {
            _ = await favorites.toggle(song)
        }
    }

    private func toggleLocal(_ playlist: LocalPlaylist, membership: LocalMembership) async {
        switch membership {
        case .all:
            localStore.removeSongs(playlistID: playlist.id, songs: songs)
            ToastCenter.shared.show("已从「\(playlist.name)」移除")
            ATMusicHaptics.tap()
            dismiss()
        default:
            let added = localStore.addSongs(songs, to: playlist.id)
            if added == 0 {
                message = "所选歌曲已全部在「\(playlist.name)」中"
            } else {
                await applyAlsoFavorite()
                ToastCenter.shared.show("已加入「\(playlist.name)」")
                ATMusicHaptics.success()
                dismiss()
            }
        }
    }

    private func addToNetEase(_ playlist: Playlist) async {
        let eligible = neteaseEligibleSongs
        guard !eligible.isEmpty else {
            message = "所选歌曲没有网易云曲目，无法加入网易歌单"
            return
        }
        do {
            let ok = try await NetEaseAPI.shared.addToPlaylist(
                playlistID: playlist.id, songIDs: eligible.map(\.id))
            if ok {
                await PlaylistManagementService.invalidateSongsCache(for: playlist)
                await applyAlsoFavorite()
                ToastCenter.shared.show("已加入「\(playlist.name)」")
                ATMusicHaptics.success()
                dismiss()
            } else {
                message = "加入网易歌单失败，请重试"
            }
        } catch {
            message = error.localizedDescription
        }
    }

    private func addToNAS(_ playlist: Playlist) async {
        let eligible = nasEligibleSongs
        guard !eligible.isEmpty else {
            message = "所选歌曲不在 NAS 曲库中，无法加入 NAS 歌单"
            return
        }
        do {
            let pid = playlist.synologyPlaylistId ?? "\(playlist.id)"
            try await SynologyAPI.shared.appendSongsToNASPlaylist(playlistID: pid, songs: eligible)
            await PlaylistManagementService.invalidateSongsCache(for: playlist)
            await applyAlsoFavorite()
            ToastCenter.shared.show("已加入「\(playlist.name)」")
            ATMusicHaptics.success()
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }

    private func createAndAdd() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        switch createTarget {
        case .local:
            let playlist = localStore.createPlaylist(name: name)
            let added = localStore.addSongs(songs, to: playlist.id)
            if added == 0 {
                message = "歌单已创建，但没有可加入的歌曲"
                return
            }
            await applyAlsoFavorite()
            ToastCenter.shared.show("已创建「\(name)」并加入")
            ATMusicHaptics.success()
            dismiss()
        case .netease:
            guard auth.isLoggedIn else {
                message = "请先登录网易云后再创建云端歌单"
                return
            }
            let eligible = neteaseEligibleSongs
            guard !eligible.isEmpty else {
                message = "所选歌曲没有网易云曲目，无法创建网易歌单"
                return
            }
            do {
                let playlistID = try await NetEaseAPI.shared.createPlaylist(name: name)
                let ok = try await NetEaseAPI.shared.addToPlaylist(playlistID: playlistID, songIDs: eligible.map(\.id))
                if ok {
                    await PlaylistManagementService.invalidateListCache(for: .netease)
                    await auth.loadLibrary()
                    await applyAlsoFavorite()
                    ToastCenter.shared.show("已创建「\(name)」并加入")
                    ATMusicHaptics.success()
                    dismiss()
                } else {
                    message = "歌单已创建，但加入歌曲失败"
                }
            } catch {
                message = error.localizedDescription
            }
        case .nas:
            guard synology.isLoggedIn else {
                message = "请先连接群晖 NAS 后再创建 NAS 歌单"
                return
            }
            let eligible = nasEligibleSongs
            guard !eligible.isEmpty else {
                message = "所选歌曲不在 NAS 曲库中，无法创建 NAS 歌单"
                return
            }
            do {
                _ = try await PlaylistManagementService.shared.exportToNAS(name: name, songs: eligible)
                await applyAlsoFavorite()
                ToastCenter.shared.show("已创建「\(name)」并加入")
                ATMusicHaptics.success()
                dismiss()
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
