import SwiftUI
import AVFoundation
import CryptoKit
import UniformTypeIdentifiers
import UIKit

// MARK: - 本地音乐库区块（音乐库页面顶部：本机歌单，可新建 / 播放 / 添加歌曲）

struct LocalMusicSection: View {
    fileprivate enum SyncTarget: String, CaseIterable, Identifiable {
        case netease = "网易云音乐"
        case qq = "QQ音乐"
        case kugou = "酷狗音乐"

        var id: String { rawValue }
    }

    @ObservedObject private var store = LocalLibraryStore.shared
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var theme: ThemeStore
    @AppStorage("atmusic.language") private var languageRaw = AppLanguage.chinese.rawValue

    @State private var showCreate = false
    @State private var showPlaylistOrder = false
    @State private var newName = ""
    @State private var selected: LocalPlaylist?
    @State private var syncing = false
    @State private var syncMessage = ""
    @State private var showSyncPicker = false
    @State private var selectedSyncTargets: Set<SyncTarget> = []
    @State private var showAudioImporter = false
    @State private var showLocalManager = false
    @State private var importingAudio = false
    @State private var importMessage = ""
    @State private var selectedImportedSong: Song?

    private var emptyLocalPlaylistText: String {
        if languageRaw == AppLanguage.english.rawValue {
            return "No local playlists yet\nCreate a playlist and save favorite songs on this device"
        }
        return "还没有本地歌单\n新建一个歌单，把喜欢的歌曲收藏到本机"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("本地音乐库")
                    .font(ATMusicFont.appFont(21, .bold))
                    .foregroundStyle(Color.atmusicLabel)
                Spacer(minLength: 8)
                Button {
                    newName = ""
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.atmusicAmber)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("新建本地歌单")
                .help("新建本地歌单")
                Button {
                    showPlaylistOrder = true
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.atmusicAmber)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("排序本地歌单")
                .help("排序本地歌单")
                Button {
                    showAudioImporter = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.atmusicAmber)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("导入本地音乐")
                .help("导入本地音乐")
                Button {
                    showLocalManager = true
                } label: {
                    Image(systemName: "folder.badge.gearshape")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.atmusicAmber)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("管理本地音乐")
                .help("管理本地音乐")
            }
            VStack(alignment: .leading, spacing: 6) {
                GlassButton(
                    title: syncing ? "正在同步歌单…" : "一键同步歌单",
                    systemName: "arrow.triangle.2.circlepath",
                    prominent: true
                ) {
                    showSyncPicker = true
                }
                .disabled(syncing)
                Text("选择两个或三个平台，合并同步到一个本地歌单")
                    .font(ATMusicFont.appFont(11))
                    .foregroundStyle(Color.atmusicComment)
            }
            if !syncMessage.isEmpty {
                Text(syncMessage)
                    .font(ATMusicFont.appFont(12, .medium))
                    .foregroundStyle(Color.atmusicSage)
            }
            if importingAudio {
                HStack(spacing: 8) {
                    ProgressView().tint(Color.atmusicAmber)
                    Text("正在导入本地音乐…")
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(Color.atmusicComment)
                }
            } else if !importMessage.isEmpty {
                Text(importMessage)
                    .font(ATMusicFont.appFont(12, .medium))
                    .foregroundStyle(Color.atmusicSage)
            }
            if store.playlists.isEmpty {
                EmptyStateView(
                    icon: "internaldrive",
                    text: emptyLocalPlaylistText
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(store.playlists) { playlist in
                        Button {
                            selected = playlist
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(LinearGradient(colors: [Color.atmusicAmber.opacity(0.75), Color.atmusicAmber.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .frame(width: 56, height: 56)
                                    Image(systemName: "music.note.list")
                                        .font(.system(size: 20, weight: .semibold))
                                        .foregroundStyle(.white)
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(playlist.name)
                                        .font(ATMusicFont.appFont(15, .medium))
                                        .foregroundStyle(Color.atmusicLabel)
                                        .lineLimit(1)
                                    Text(atmusicLocalSongCountText(playlist.songs.count))
                                        .font(ATMusicFont.appFont(12))
                                        .foregroundStyle(Color.atmusicComment)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.atmusicComment.opacity(0.6))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                store.movePlaylist(id: playlist.id, offset: -1)
                            } label: {
                                Label("移到前面", systemImage: "arrow.up")
                            }
                            Button {
                                store.movePlaylist(id: playlist.id, offset: 1)
                            } label: {
                                Label("移到后面", systemImage: "arrow.down")
                            }
                            Button(role: .destructive) {
                                ATMusicHaptics.tap()
                                store.deletePlaylist(id: playlist.id)
                                ToastCenter.shared.show("已删除本地歌单")
                            } label: {
                                Label("删除歌单", systemImage: "trash")
                            }
                        }
                        Divider().overlay(Color.atmusicComment.opacity(0.12))
                    }
                }
                .padding(.vertical, 6)
                .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 22, style: .continuous)) }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .atmusicCardShadow(radius: 8, y: 3)
            }
            if !store.importedSongs.isEmpty {
                importedSongsSection
            }
        }
        .alert("新建本地歌单", isPresented: $showCreate) {
            TextField("歌单名称", text: $newName)
            Button("创建") {
                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                let playlist = store.createPlaylist(name: name)
                selected = playlist
                newName = ""
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("本地歌单保存在设备上，覆盖安装不会丢失，不依赖平台账号")
        }
        .sheet(isPresented: $showSyncPicker) {
            SyncPlatformPicker(
                selectedTargets: $selectedSyncTargets,
                onCancel: {
                    showSyncPicker = false
                },
                onConfirm: {
                    let targets = selectedSyncTargets
                    showSyncPicker = false
                    Task { await sync(targets: targets) }
                }
            )
        }
        .sheet(isPresented: $showPlaylistOrder) {
            LocalPlaylistOrderSheet()
                .environmentObject(theme)
        }
        .sheet(item: $selected) { playlist in
            LocalPlaylistDetailSheet(playlistID: playlist.id)
                .environmentObject(player)
                .environmentObject(auth)
        }
        .sheet(isPresented: $showAudioImporter) {
            LocalAudioDocumentPicker { urls in
                showAudioImporter = false
                importAudio(urls)
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showLocalManager) {
            LocalMusicManagementSheet()
                .environmentObject(player)
                .environmentObject(theme)
        }
        .sheet(item: $selectedImportedSong) { song in
            AddToPlaylistSheet(song: song)
                .environmentObject(theme)
        }
    }

    private var importedSongsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("本地歌曲")
                    .font(ATMusicFont.appFont(18, .bold))
                    .foregroundStyle(Color.atmusicLabel)
                Spacer()
                Text("\(store.importedSongs.count) 首")
                    .font(ATMusicFont.appFont(12))
                    .foregroundStyle(Color.atmusicComment)
            }
            LazyVStack(spacing: 0) {
                ForEach(Array(store.importedSongs.enumerated()), id: \.element.identityKey) { index, song in
                    SongCell(song: song, glassRow: true, playbackIndex: index, onTap: {
                        player.play(songs: store.importedSongs, startAt: index)
                    })
                    .contextMenu {
                        Button {
                            selectedImportedSong = song
                        } label: {
                            Label("加入本地歌单", systemImage: "plus.circle")
                        }
                        Button(role: .destructive) {
                            DownloadManager.shared.removeDownloaded(song: song)
                        } label: {
                            Label("从本地彻底删除", systemImage: "trash")
                        }
                    }
                    Divider().overlay(Color.atmusicComment.opacity(0.12))
                }
            }
            .padding(.vertical, 6)
            .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 22, style: .continuous)) }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .atmusicCardShadow(radius: 8, y: 3)
        }
    }

    private func importAudio(_ urls: [URL]) {
        guard !urls.isEmpty, !importingAudio else { return }
        importingAudio = true
        importMessage = ""
        Task {
            let report = await LocalAudioImportService.shared.importFiles(urls)
            await MainActor.run {
                store.addImportedSongs(report.songs)
                importingAudio = false
                importMessage = report.message
                if !report.songs.isEmpty { ATMusicHaptics.success() }
                ToastCenter.shared.show(report.message)
            }
        }
    }

    private func sync(targets: Set<SyncTarget>) async {
        guard !syncing else { return }
        guard targets.count >= 2 else {
            ToastCenter.shared.show("至少选择两个平台")
            return
        }
        syncing = true
        syncMessage = ""
        var songs: [Song] = []
        var details: [String] = []
        if targets.contains(.netease), let user = auth.user, auth.isLoggedIn {
            do {
                let lists = try await NetEaseAPI.shared.userPlaylists(uid: user.uid)
                let liked = lists.first { list in
                    let name = list.name.replacingOccurrences(of: " ", with: "")
                    return name.contains("喜欢") || name.contains("我喜欢")
                }
                if let liked {
                    let neteaseSongs = try await NetEaseAPI.shared.playlistTracks(id: liked.id)
                    songs.append(contentsOf: neteaseSongs)
                    details.append(platformSongCount("网易云", neteaseSongs.count))
                } else {
                    details.append(NSLocalizedString("网易云未找到喜欢歌单", comment: ""))
                }
            } catch {
                ATMusicLogger.shared.log("三平台同步：网易云失败 \(error.localizedDescription)", level: .error)
                details.append(NSLocalizedString("网易云请求失败", comment: ""))
            }
        } else if targets.contains(.netease) {
            details.append(NSLocalizedString("网易云未登录", comment: ""))
        }
        if targets.contains(.netease), !favorites.neteaseFavoriteSongs.isEmpty {
            let cachedIDs = Set(songs.filter { $0.source == .netease }.map(\.id))
            let cached = favorites.neteaseFavoriteSongs.filter { !cachedIDs.contains($0.id) }
            songs.append(contentsOf: cached)
            if !cached.isEmpty { details.append(String(format: NSLocalizedString("网易云缓存补充 %d 首", comment: ""), cached.count)) }
        }
        if targets.contains(.qq), QQMusicAuth.shared.isLoggedIn {
            do {
                let qqSongs = try await QQMusicAPI.shared.favoriteSongs(limit: 0)
                songs.append(contentsOf: qqSongs)
                details.append(platformSongCount("QQ音乐", qqSongs.count))
            } catch {
                ATMusicLogger.shared.log("三平台同步：QQ音乐失败 \(error.localizedDescription)", level: .error)
                details.append(NSLocalizedString("QQ音乐请求失败", comment: ""))
            }
        } else if targets.contains(.qq) {
            details.append(NSLocalizedString("QQ音乐未登录", comment: ""))
        }
        if targets.contains(.kugou), KugouMusicAuth.shared.isLoggedIn {
            do {
                let lists = try await KugouMusicAPI.shared.userPlaylists()
                ATMusicLogger.shared.log("三平台同步：酷狗歌单 \(lists.map(\.name).joined(separator: "|"))", level: .info)
                let liked = lists.first { list in
                    let name = list.name.replacingOccurrences(of: " ", with: "")
                    return name.contains("喜欢") || name.contains("收藏") || name.contains("红心")
                }
                if let liked {
                    let kugouSongs = try await KugouMusicAPI.shared.playlistSongs(listID: liked.id)
                    songs.append(contentsOf: kugouSongs)
                    details.append(platformSongCount("酷狗音乐", kugouSongs.count))
                } else {
                    details.append(NSLocalizedString("酷狗音乐未找到喜欢歌单", comment: ""))
                }
            } catch {
                ATMusicLogger.shared.log("三平台同步：酷狗音乐失败 \(error.localizedDescription)", level: .error)
                details.append(NSLocalizedString("酷狗音乐请求失败", comment: ""))
            }
        } else if targets.contains(.kugou) {
            details.append(NSLocalizedString("酷狗音乐未登录", comment: ""))
        }
        var unique: [Song] = []
        var seen = Set<String>()
        for song in songs where seen.insert(song.identityKey).inserted { unique.append(song) }
        let playlistName: String
        playlistName = targets
            .sorted { $0.rawValue < $1.rawValue }
            .map(\.rawValue)
            .joined(separator: " + ") + "喜欢"
        let added = store.syncSongs(unique, intoPlaylistNamed: playlistName)
        syncing = false
        syncMessage = details.joined(separator: NSLocalizedString("，", comment: "")) + String(format: NSLocalizedString("；合计 %d 首", comment: ""), unique.count)
        ToastCenter.shared.show(unique.isEmpty ? NSLocalizedString("没有获取到该平台的喜欢歌曲", comment: "") : String(format: NSLocalizedString("已同步 %d 首，新增 %d 首到本地歌单“%@”", comment: ""), unique.count, added, playlistName))
    }

    private func platformSongCount(_ platform: String, _ count: Int) -> String {
        String(format: NSLocalizedString("%@ %d 首", comment: ""), NSLocalizedString(platform, comment: ""), count)
    }
}

private struct LocalPlaylistOrderSheet: View {
    @ObservedObject private var store = LocalLibraryStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var editMode: EditMode = .active

    var body: some View {
        ATMusicNavigationStack {
            List {
                ForEach(store.playlists) { playlist in
                    HStack(spacing: 12) {
                        Image(systemName: "music.note.list")
                            .foregroundStyle(Color.atmusicAmber)
                        Text(playlist.name)
                            .foregroundStyle(Color.atmusicLabel)
                        Spacer()
                        Text(atmusicLocalSongCountText(playlist.songs.count))
                            .font(ATMusicFont.appFont(12))
                            .foregroundStyle(Color.atmusicComment)
                    }
                }
                .onMove { offsets, destination in
                    store.movePlaylists(from: offsets, to: destination)
                }
            }
            .environment(\.editMode, $editMode)
            .listStyle(.plain)
            .atmusicScrollContentBackgroundHidden()
            .navigationTitle("歌单排序")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

fileprivate struct SyncPlatformPicker: View {
    @Binding var selectedTargets: Set<LocalMusicSection.SyncTarget>
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var canConfirm: Bool {
        selectedTargets.count >= 2
    }

    var body: some View {
        ATMusicNavigationStack {
            List {
                Section {
                    ForEach(LocalMusicSection.SyncTarget.allCases) { target in
                        Toggle(isOn: Binding(
                            get: { selectedTargets.contains(target) },
                            set: { isSelected in
                                if isSelected {
                                    selectedTargets.insert(target)
                                } else {
                                    selectedTargets.remove(target)
                                }
                            }
                        )) {
                            Label(target.rawValue, systemImage: icon(for: target))
                        }
                    }
                } header: {
                    Text("同步平台")
                } footer: {
                    Text(LocalizedStringKey(canConfirm ? "所选平台的喜欢歌曲会合并到同一个本地歌单。" : "至少选择两个平台。"))
                }
            }
            .navigationTitle("一键同步歌单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("开始同步", action: onConfirm)
                        .disabled(!canConfirm)
                }
            }
        }
        .onAppear {
            selectedTargets = []
        }
    }

    private func icon(for target: LocalMusicSection.SyncTarget) -> String {
        switch target {
        case .netease: return "music.note"
        case .qq: return "q.circle"
        case .kugou: return "dog"
        }
    }
}

// MARK: - 本地歌单详情（播放全部 / 单曲播放 / 移除歌曲 / 添加歌曲）

struct LocalPlaylistDetailSheet: View {
    @ObservedObject private var store = LocalLibraryStore.shared
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.dismiss) private var dismiss

    let playlistID: UUID

    @State private var showSearchAdd = false
    @State private var showRename = false
    @State private var renameText = ""
    @State private var playlistSearchText = ""
    @State private var multiSelectMode = false
    @State private var selectedSongKeys: Set<String> = []
    @State private var showAddSelectedDestination = false
    @State private var dragStartIndex: Int? = nil
    @State private var initialSelectedKeysOnDrag: Set<String>? = nil
    @State private var dragTargetSelected = true
    @State private var lastDragIndex: Int? = nil

    private func handleDragChange(startIndex: Int, deltaRows: Int) {
        let keys = visibleSongs.map(\.element.identityKey)
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

    private var playlist: LocalPlaylist? {
        store.playlists.first { $0.id == playlistID }
    }

    private var visibleSongs: [(offset: Int, element: Song)] {
        guard let playlist else { return [] }
        let keyword = playlistSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let songs = Array(playlist.songs.enumerated())
        guard !keyword.isEmpty else { return songs }
        return songs.filter { _, song in
            song.name.lowercased().contains(keyword)
                || song.artists.lowercased().contains(keyword)
                || song.album.lowercased().contains(keyword)
        }
    }

    var body: some View {
        ATMusicNavigationStack {
            ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
                Group {
                if let playlist {
                    List {
                        Section {
                            HStack(spacing: 12) {
                                GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                                    let songs = store.playbackSongs(for: playlistID)
                                    guard !songs.isEmpty else { return }
                                    player.play(songs: songs, startAt: 0)
                                }
                                GlassButton(title: "随机播放", systemName: "shuffle") {
                                    let songs = store.playbackSongs(for: playlistID)
                                    guard !songs.isEmpty else { return }
                                    player.play(songs: songs.shuffled(), startAt: 0)
                                }
                            }
                        }
                        .listRowBackground(Color.clear)
                        Section {
                            if visibleSongs.isEmpty {
                                EmptyStateView(icon: "magnifyingglass", text: "没有找到匹配歌曲")
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                            } else {
                                ForEach(visibleSongs, id: \.element.identityKey) { index, song in
                                    let resolvedSongs = store.playbackSongs(for: playlistID)
                                    SongCell(
                                        song: song,
                                        glassRow: true,
                                        playbackContext: resolvedSongs,
                                        playbackIndex: index,
                                        onTap: {
                                            player.play(songs: resolvedSongs, startAt: index)
                                        },
                                        isMultiSelecting: multiSelectMode,
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
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                                }
                            }
                        }
                    }
                    .atmusicScrollContentBackgroundHidden()
                    .listStyle(.plain)
                    .searchable(text: $playlistSearchText, placement: .navigationBarDrawer(displayMode: .always), prompt: LocalizedStringKey("搜索本地歌单歌曲"))
                } else {
                    EmptyStateView(icon: "music.note.list", text: "歌单不存在或已删除")
                }
            }
            }
            if multiSelectMode && !selectedSongKeys.isEmpty {
                VStack {
                    Spacer()
                    HStack(spacing: 0) {
                        Button {
                            let songs = selectedSongs
                            guard !songs.isEmpty else { return }
                            player.play(songs: songs, startAt: 0)
                            multiSelectMode = false
                            selectedSongKeys.removeAll()
                        } label: {
                            VStack(spacing: 3) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 15))
                                Text("播放")
                                    .font(ATMusicFont.appFont(10, .medium))
                            }
                            .foregroundStyle(Color.atmusicLabel)
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)

                        Button {
                            let songs = selectedSongs
                            for s in songs.reversed() { player.playNext(s) }
                            ToastCenter.shared.show("已将 \(songs.count) 首歌曲加入下一首播放")
                            multiSelectMode = false
                            selectedSongKeys.removeAll()
                        } label: {
                            VStack(spacing: 3) {
                                Image(systemName: "text.line.first.and.arrowtriangle.forward")
                                    .font(.system(size: 15))
                                Text("下一首")
                                    .font(ATMusicFont.appFont(10, .medium))
                            }
                            .foregroundStyle(Color.atmusicLabel)
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)

                        Button {
                            showAddSelectedDestination = true
                        } label: {
                            VStack(spacing: 3) {
                                Image(systemName: "folder.badge.plus")
                                    .font(.system(size: 15))
                                Text("加其他歌单")
                                    .font(ATMusicFont.appFont(10, .medium))
                            }
                            .foregroundStyle(Color.atmusicLabel)
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .disabled(!hasOtherPlaylist)

                        if SynologyAPI.shared.isLoggedIn {
                            Button {
                                let songs = selectedSongs
                                DownloadManager.shared.startBatchUploadToNAS(songs: songs)
                                multiSelectMode = false
                                selectedSongKeys.removeAll()
                            } label: {
                                VStack(spacing: 3) {
                                    Image(systemName: "externaldrive.badge.plus")
                                        .font(.system(size: 15))
                                    Text("归档NAS")
                                        .font(ATMusicFont.appFont(10, .medium))
                                }
                                .foregroundStyle(Color.atmusicAmber)
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                        }

                        Button {
                            removeSelectedSongs()
                            multiSelectMode = false
                            selectedSongKeys.removeAll()
                        } label: {
                            VStack(spacing: 3) {
                                Image(systemName: "trash")
                                    .font(.system(size: 15))
                                Text("移除")
                                    .font(ATMusicFont.appFont(10, .medium))
                            }
                            .foregroundStyle(Color.red)
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 8)
                    .background {
                        ATMusicGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .shadow(color: Color.black.opacity(0.18), radius: 16, x: 0, y: 6)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            }
            .navigationTitle(multiSelectMode ? "已选择 \(selectedSongKeys.count) 首" : (playlist?.name ?? "本地歌单"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !multiSelectMode {
                        Button("完成") { dismiss() }
                            .font(ATMusicFont.appFont(15, .medium))
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if multiSelectMode {
                        Button(selectedSongKeys.count == visibleSongs.count && !visibleSongs.isEmpty ? "取消全选" : "全选") {
                            ATMusicHaptics.tap()
                            if selectedSongKeys.count == visibleSongs.count {
                                selectedSongKeys.removeAll()
                            } else {
                                selectedSongKeys = Set(visibleSongs.map { $0.element.identityKey })
                            }
                        }
                        .font(ATMusicFont.appFont(13, .semibold))
                        .foregroundStyle(Color.atmusicAmber)

                        Button("完成") {
                            multiSelectMode = false
                            selectedSongKeys.removeAll()
                            ATMusicHaptics.tap()
                        }
                        .font(ATMusicFont.appFont(13, .semibold))
                    } else {
                        Menu {
                            Button {
                                multiSelectMode = true
                                selectedSongKeys.removeAll()
                                ATMusicHaptics.tap()
                            } label: {
                                Label("多选管理", systemImage: "checklist")
                            }
                        Button {
                            if let song = player.currentSong {
                                store.addSong(song, to: playlistID)
                                ATMusicHaptics.success()
                                ToastCenter.shared.show("已加入本地歌单")
                            } else {
                                ToastCenter.shared.show("当前没有播放中的歌曲")
                            }
                        } label: {
                            Label("添加当前播放歌曲", systemImage: "plus.circle")
                        }
                        Button {
                            showSearchAdd = true
                        } label: {
                            Label("搜索添加歌曲", systemImage: "magnifyingglass")
                        }
                        Menu("播放来源") {
                            ForEach(PlaylistSourceStrategy.allCases) { strategy in
                                Button {
                                    store.setSourceStrategy(strategy, for: playlistID)
                                } label: {
                                    Label(strategy.title, systemImage: playlist?.sourceStrategy == strategy ? "checkmark" : "circle")
                                }
                            }
                        }
                        Button {
                            renameText = playlist?.name ?? ""
                            showRename = true
                        } label: {
                            Label("重命名歌单", systemImage: "pencil")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 17, weight: .semibold))
                    }
                }
            }
        }
        .sheet(isPresented: $showSearchAdd) {
            LocalSearchAddSheet(playlistID: playlistID)
                .environmentObject(player)
                .environmentObject(auth)
        }
        .alert("重命名歌单", isPresented: $showRename) {
            TextField("歌单名称", text: $renameText)
            Button("保存") {
                let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                store.renamePlaylist(id: playlistID, name: name)
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog(
            "添加 \(selectedSongKeys.count) 首歌曲到其他本地歌单",
            isPresented: $showAddSelectedDestination,
            titleVisibility: .visible
        ) {
            ForEach(store.playlists.filter { $0.id != playlistID }) { target in
                Button(target.name) {
                    addSelectedSongs(to: target.id)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("已选歌曲会复制到目标歌单，当前歌单中的歌曲不会被移除。")
        }
        .modifier(ATMusicSheetModifier(detents: [.medium, .large], dragIndicator: true))
    }

    private var selectedSongs: [Song] {
        guard let playlist else { return [] }
        return playlist.songs.filter { selectedSongKeys.contains($0.identityKey) }
    }

    private var hasOtherPlaylist: Bool {
        store.playlists.contains { $0.id != playlistID }
    }

    private func toggleSelection(_ song: Song) {
        ATMusicHaptics.select()
        if selectedSongKeys.contains(song.identityKey) {
            selectedSongKeys.remove(song.identityKey)
        } else {
            selectedSongKeys.insert(song.identityKey)
        }
    }

    private func removeSelectedSongs() {
        guard !selectedSongKeys.isEmpty else { return }
        let count = selectedSongKeys.count
        if playlist?.name == "已下载歌曲" {
            let songsToRemove = (playlist?.songs ?? []).filter { selectedSongKeys.contains($0.identityKey) }
            DownloadManager.shared.removeDownloaded(songs: songsToRemove)
        } else {
            selectedSongKeys.forEach { key in
                store.removeSong(playlistID: playlistID, songIdentity: key)
            }
            ATMusicHaptics.success()
            ToastCenter.shared.show("已移除 \(count) 首歌曲")
        }
        selectedSongKeys.removeAll()
        multiSelectMode = false
    }

    private func addSelectedSongs(to destinationID: UUID) {
        guard let playlist else { return }
        let songs = playlist.songs.filter { selectedSongKeys.contains($0.identityKey) }
        let added = store.addSongs(songs, to: destinationID)
        selectedSongKeys.removeAll()
        multiSelectMode = false
        ATMusicHaptics.success()
        let targetName = store.playlists.first(where: { $0.id == destinationID })?.name ?? "目标歌单"
        ToastCenter.shared.show(added == songs.count
            ? "已添加 \(added) 首到「\(targetName)」"
            : "已添加 \(added) 首到「\(targetName)」（重复歌曲已跳过）")
    }
}

// MARK: - 本地歌单搜索添加（网易云 / QQ 音乐）

struct LocalSearchAddSheet: View {
    @ObservedObject private var store = LocalLibraryStore.shared
    @ObservedObject private var platformPrefs = PlatformPreferenceStore.shared
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthStore
    @Environment(\.dismiss) private var dismiss

    let playlistID: UUID
    @State private var keyword = ""
    @State private var results: [Song] = []
    @State private var searching = false
    @State private var provider: SearchProvider = .netease
    private var searchProviders: [SearchProvider] { platformPrefs.enabledSearchProviders }
    @State private var task: Task<Void, Never>?

    var body: some View {
        ATMusicNavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    TextField(atmusicLocalized("输入歌名搜索", "Search by song title"), text: $keyword)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.atmusicGlassFill))
                        .submitLabel(.search)
                        .onSubmit { runSearch() }
                    Button {
                        runSearch()
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(Color.atmusicAmber))
                    }
                }
                .padding(12)
                Picker("平台", selection: $provider) {
                    ForEach(searchProviders) { p in
                        Text(LocalizedStringKey(p.rawValue)).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                if searching {
                    Spacer()
                    ProgressView().tint(Color.atmusicAmber)
                    Spacer()
                } else if results.isEmpty {
                    Spacer()
                    Text("输入歌名搜索，点击结果加入本地歌单")
                        .font(ATMusicFont.appFont(13))
                        .foregroundStyle(Color.atmusicComment)
                    Spacer()
                } else {
                    List {
                        ForEach(Array(results.enumerated()), id: \.element.identityKey) { index, song in
                            SongCell(song: song, glassRow: true, onTap: {
                                store.addSong(song, to: playlistID)
                                ATMusicHaptics.success()
                                ToastCenter.shared.show("已加入本地歌单")
                            })
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("添加歌曲")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .modifier(ATMusicSheetModifier(detents: [.medium, .large], dragIndicator: true))
        .onAppear {
            provider = platformPrefs.ensureVisible(provider)
        }
        .onChange(of: platformPrefs.selectedRaw) { _ in
            let next = platformPrefs.ensureVisible(provider)
            if next != provider { provider = next }
        }
    }

    private func runSearch() {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        task?.cancel()
        task = Task {
            searching = true
            defer { if !Task.isCancelled { searching = false } }
            do {
                let songs: [Song]
                switch provider {
                case .netease:
                    songs = try await NetEaseAPI.shared.search(keyword: trimmed, limit: 30)
                case .qq:
                    songs = try await QQMusicAPI.shared.searchSongs(keyword: trimmed)
                case .kugou:
                    songs = try await KugouMusicAPI.shared.searchSongs(keyword: trimmed)
                case .synology:
                    songs = try await SynologyAPI.shared.search(keyword: trimmed, limit: 30)
                case .subsonic:
                    songs = (try await SubsonicAPI.shared.searchAllVariants(keyword: trimmed, limit: 30)).songs
                case .jellyfin:
                    songs = (try await JellyfinAPI.shared.searchAllVariants(keyword: trimmed, limit: 30)).songs
                case .webdav:
                    songs = (try await WebDAVAPI.shared.searchAllVariants(keyword: trimmed, limit: 30)).songs
                }
                guard !Task.isCancelled else { return }
                results = songs
            } catch {
                guard !Task.isCancelled else { return }
                ToastCenter.shared.show("搜索失败，请稍后再试")
            }
        }
    }

}


// MARK: - 本地音乐管理

struct LocalMusicManagementSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var theme: ThemeStore
    @ObservedObject private var store = LocalLibraryStore.shared
    @ObservedObject private var synology = SynologyAPI.shared
    @State private var searchText = ""
    @State private var editingSong: Song?
    @State private var pendingDelete: Song?
    @State private var showDeleteConfirmation = false

    @State private var isMultiSelecting = false
    @State private var selectedSongKeys: Set<String> = []
    @State private var showBatchAddToPlaylist = false
    @State private var showBatchDeleteAlert = false
    @State private var showBatchEdit = false
    @State private var dragStartIndex: Int? = nil
    @State private var initialSelectedKeysOnDrag: Set<String>? = nil
    @State private var dragTargetSelected = true
    @State private var lastDragIndex: Int? = nil

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

    private var filteredSongs: [Song] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return store.importedSongs }
        return store.importedSongs.filter {
            $0.name.lowercased().contains(keyword)
                || $0.artists.lowercased().contains(keyword)
                || $0.album.lowercased().contains(keyword)
        }
    }

    private var selectedSongs: [Song] {
        store.importedSongs.filter { selectedSongKeys.contains($0.identityKey) }
    }

    var body: some View {
        NavigationView {
            ZStack {
                List {
                    Section {
                        if filteredSongs.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "music.note")
                                    .font(.system(size: 28))
                                    .foregroundStyle(.secondary)
                                Text(searchText.isEmpty ? "还没有本地歌曲" : "没有匹配的本地歌曲")
                                    .foregroundStyle(.secondary)
                                Text(searchText.isEmpty ? "点击音乐库右上角的导入按钮添加音频" : "尝试搜索标题、歌手或专辑")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 36)
                        } else {
                            ForEach(Array(filteredSongs.enumerated()), id: \.element.identityKey) { index, song in
                                let isSelected = selectedSongKeys.contains(song.identityKey)
                                if isMultiSelecting {
                                    HStack(spacing: 12) {
                                        MultiSelectCheckmark(
                                            isSelected: isSelected,
                                            index: index,
                                            rowHeight: 56,
                                            onToggle: {
                                                ATMusicHaptics.select()
                                                if isSelected {
                                                    selectedSongKeys.remove(song.identityKey)
                                                } else {
                                                    selectedSongKeys.insert(song.identityKey)
                                                }
                                            },
                                            onDragChange: { startIdx, deltaRows in
                                                handleDragChange(startIndex: startIdx, deltaRows: deltaRows)
                                            },
                                            onDragEnd: {
                                                handleDragEnd()
                                            }
                                        )
                                        CoverImage(url: song.coverURL, size: 46, cornerRadius: 10)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(song.name)
                                                .font(ATMusicFont.appFont(15))
                                                .foregroundStyle(Color.atmusicLabel)
                                                .lineLimit(1)
                                            Text("\(song.artists) · \(song.album)")
                                                .font(ATMusicFont.appFont(12))
                                                .foregroundStyle(Color.atmusicComment)
                                                .lineLimit(1)
                                            Text(song.formattedDuration)
                                                .font(ATMusicFont.appFont(11))
                                                .foregroundStyle(Color.atmusicComment.opacity(0.8))
                                        }
                                        Spacer(minLength: 8)
                                    }
                                    .frame(height: 56)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        ATMusicHaptics.select()
                                        if isSelected {
                                            selectedSongKeys.remove(song.identityKey)
                                        } else {
                                            selectedSongKeys.insert(song.identityKey)
                                        }
                                    }
                                } else {
                                    Button {
                                        editingSong = song
                                    } label: {
                                        HStack(spacing: 12) {
                                            CoverImage(url: song.coverURL, size: 46, cornerRadius: 10)
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(song.name)
                                                    .font(ATMusicFont.appFont(15))
                                                    .foregroundStyle(Color.atmusicLabel)
                                                    .lineLimit(1)
                                                Text("\(song.artists) · \(song.album)")
                                                    .font(ATMusicFont.appFont(12))
                                                    .foregroundStyle(Color.atmusicComment)
                                                    .lineLimit(1)
                                                Text(song.formattedDuration)
                                                    .font(ATMusicFont.appFont(11))
                                                    .foregroundStyle(Color.atmusicComment.opacity(0.8))
                                            }
                                            Spacer(minLength: 8)
                                            Image(systemName: "chevron.right")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(Color.atmusicComment.opacity(0.55))
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        deleteButton(for: song)
                                    }
                                    .contextMenu {
                                        Button {
                                            editingSong = song
                                        } label: {
                                            Label("编辑标签和封面", systemImage: "pencil")
                                        }
                                        Button {
                                            let index = filteredSongs.firstIndex(where: { $0.identityKey == song.identityKey }) ?? 0
                                            player.play(songs: filteredSongs, startAt: index)
                                        } label: {
                                            Label("播放", systemImage: "play.fill")
                                        }
                                        if synology.isLoggedIn {
                                            Button {
                                                DownloadManager.shared.startUploadToNAS(song: song)
                                            } label: {
                                                Label("上传归档到群晖 NAS", systemImage: "externaldrive.badge.plus")
                                            }
                                        }
                                        deleteButton(for: song)
                                    }
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("本地歌曲")
                            Spacer()
                            Text("\(store.importedSongs.count) 首")
                                .foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("这里管理的是应用内副本。删除后不会影响原始文件，也不会删除平台上的歌曲。")
                            .padding(.bottom, isMultiSelecting && !selectedSongKeys.isEmpty ? 80 : 0)
                    }
                }
                .listStyle(.insetGrouped)
                .searchable(text: $searchText, prompt: "搜索本地歌曲")

                if isMultiSelecting && !selectedSongKeys.isEmpty {
                    VStack {
                        Spacer()
                        batchActionFloatingBar
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .navigationTitle(isMultiSelecting ? "已选择 \(selectedSongKeys.count) 首" : "本地音乐管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isMultiSelecting {
                        Button(selectedSongKeys.count == filteredSongs.count && !filteredSongs.isEmpty ? "取消全选" : "全选") {
                            if selectedSongKeys.count == filteredSongs.count {
                                selectedSongKeys.removeAll()
                            } else {
                                selectedSongKeys = Set(filteredSongs.map { $0.identityKey })
                            }
                        }
                    } else {
                        Button("完成") { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if !store.importedSongs.isEmpty {
                        Button(isMultiSelecting ? "完成" : "多选") {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                isMultiSelecting.toggle()
                                if !isMultiSelecting {
                                    selectedSongKeys.removeAll()
                                }
                            }
                        }
                    }
                }
            }
            .sheet(item: $editingSong) { song in
                LocalSongMetadataEditorSheet(song: song) { updated in
                    let saved = store.updateImportedSong(updated)
                    if saved { player.replaceSong(updated) }
                    return saved
                }
            }
            .sheet(isPresented: $showBatchAddToPlaylist) {
                AddToPlaylistSheet(songs: selectedSongs)
                    .environmentObject(theme)
            }
            .sheet(isPresented: $showBatchEdit) {
                LocalBatchMetadataEditorSheet(songs: selectedSongs)
                    .environmentObject(player)
                    .environmentObject(theme)
            }
            .confirmationDialog("删除本地歌曲？", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
                Button("删除应用内副本", role: .destructive) {
                    guard let song = pendingDelete else { return }
                    DownloadManager.shared.removeDownloaded(song: song)
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("原始文件不会被删除，但应用内复制的音频、封面和歌词会移入回收隔离目录。")
            }
            .confirmationDialog("批量删除本地歌曲？", isPresented: $showBatchDeleteAlert, titleVisibility: .visible) {
                Button("删除选中的 \(selectedSongKeys.count) 首歌曲副本", role: .destructive) {
                    let songs = selectedSongs
                    DownloadManager.shared.removeDownloaded(songs: songs)
                    isMultiSelecting = false
                    selectedSongKeys.removeAll()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("原始文件不会被删除，但应用内复制的音频、封面和歌词会移入回收隔离目录。")
            }
        }
    }

    private var batchActionFloatingBar: some View {
        HStack(spacing: 0) {
            Button {
                let songs = selectedSongs
                guard !songs.isEmpty else { return }
                player.play(songs: songs, startAt: 0)
                isMultiSelecting = false
                selectedSongKeys.removeAll()
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 15))
                    Text("播放")
                        .font(ATMusicFont.appFont(10, .medium))
                }
                .foregroundStyle(Color.atmusicLabel)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)

            Button {
                let songs = selectedSongs
                for s in songs.reversed() {
                    player.playNext(s)
                }
                ToastCenter.shared.show("已将 \(songs.count) 首歌曲加入下一首播放")
                isMultiSelecting = false
                selectedSongKeys.removeAll()
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "text.line.first.and.arrowtriangle.forward")
                        .font(.system(size: 15))
                    Text("下一首")
                        .font(ATMusicFont.appFont(10, .medium))
                }
                .foregroundStyle(Color.atmusicLabel)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)

            Button {
                showBatchAddToPlaylist = true
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 15))
                    Text("加歌单")
                        .font(ATMusicFont.appFont(10, .medium))
                }
                .foregroundStyle(Color.atmusicLabel)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)

            Button {
                showBatchEdit = true
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 15))
                    Text("批量编辑")
                        .font(ATMusicFont.appFont(10, .medium))
                }
                .foregroundStyle(Color.atmusicLabel)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)

            if synology.isLoggedIn {
                Button {
                    let songs = selectedSongs
                    DownloadManager.shared.startBatchUploadToNAS(songs: songs)
                    isMultiSelecting = false
                    selectedSongKeys.removeAll()
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "externaldrive.badge.plus")
                            .font(.system(size: 15))
                        Text("归档NAS")
                            .font(ATMusicFont.appFont(10, .medium))
                    }
                    .foregroundStyle(Color.atmusicAmber)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }

            Button {
                showBatchDeleteAlert = true
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "trash")
                        .font(.system(size: 15))
                    Text("删除")
                        .font(ATMusicFont.appFont(10, .medium))
                }
                .foregroundStyle(Color.red)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .background {
            ATMusicGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: Color.black.opacity(0.18), radius: 16, x: 0, y: 6)
        }
    }

    @ViewBuilder
    private func deleteButton(for song: Song) -> some View {
        Button(role: .destructive) {
            pendingDelete = song
            showDeleteConfirmation = true
        } label: {
            Label("删除本地歌曲副本", systemImage: "trash")
        }
    }
}

struct LocalSongMetadataEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var player: PlayerManager
    let song: Song
    let onSave: (Song) -> Bool

    @State private var title: String
    @State private var artist: String
    @State private var album: String
    @State private var albumArtist: String
    @State private var genre: String
    @State private var year: String
    @State private var trackNumber: String
    @State private var discNumber: String
    @State private var comment: String
    @State private var coverURL: URL?
    @State private var coverData: Data?
    @State private var editingField: SongMetadataField?
    @State private var showCoverSearch = false
    @State private var saving = false
    @State private var message = ""

    init(song: Song, onSave: @escaping (Song) -> Bool) {
        self.song = song
        self.onSave = onSave
        _title = State(initialValue: song.name)
        _artist = State(initialValue: song.artists)
        _album = State(initialValue: song.album)
        _albumArtist = State(initialValue: song.albumArtist ?? "")
        _genre = State(initialValue: song.genre ?? "")
        _year = State(initialValue: song.year ?? "")
        _trackNumber = State(initialValue: song.trackNumber > 0 ? String(song.trackNumber) : "")
        _discNumber = State(initialValue: song.discNumber > 0 ? String(song.discNumber) : "")
        _comment = State(initialValue: song.comment ?? "")
        _coverURL = State(initialValue: song.coverURL)
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        MetadataStaticRow(title: "文件路径", value: song.localRelativePath ?? "未知", multiline: true)
                        MetadataStaticRow(title: "来源", value: "导入的本地音乐")
                        MetadataStaticRow(title: "格式", value: ((song.localRelativePath ?? "") as NSString).pathExtension.uppercased().isEmpty ? "音频文件" : ((song.localRelativePath ?? "") as NSString).pathExtension.uppercased())
                    }
                    .padding(.horizontal, 20).padding(.vertical, 18)
                    Divider().overlay(Color.atmusicSecondary.opacity(0.26))
                    localTagRows
                    if !message.isEmpty {
                        Text(message)
                            .font(ATMusicFont.appFont(12))
                            .foregroundStyle(Color.atmusicComment)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20).padding(.top, 14)
                    }
                    VStack(spacing: 10) {
                        Button(saving ? "保存中…" : "保存已修改的标签") { save() }
                            .font(ATMusicFont.appFont(15, .semibold))
                            .foregroundStyle(Color.atmusicLabel)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background {
                                ATMusicLiquidSelectionSurface(
                                    shape: RoundedRectangle(cornerRadius: 14, style: .continuous),
                                    accent: .atmusicAmber
                                )
                            }
                            .buttonStyle(.plain)
                            .opacity(saving ? 0.55 : 1)
                            .disabled(saving)
                        Button("取消") { dismiss() }.foregroundStyle(Color.atmusicLabel)
                    }
                    .padding(20)
                }
                .padding(.top, 10)
            }
            .background(Color.atmusicBackground.ignoresSafeArea())
            .navigationTitle("歌曲信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .modifier(ATMusicSheetModifier(detents: [.medium, .large], dragIndicator: true))
        .fullScreenCover(item: $editingField) { field in
            SongMetadataFieldEditor(field: field, initialValue: value(for: field)) { value in
                set(value, for: field)
            }
        }
        .fullScreenCover(isPresented: $showCoverSearch) {
            SongCoverSearchGridSheet(song: song) { candidate in
                coverURL = candidate.song.coverURL
                coverData = nil
            } onPickData: { data in
                coverData = data
                coverURL = nil
            }
        }
    }

    private var localTagRows: some View {
        VStack(spacing: 0) {
            Button { showCoverSearch = true } label: {
                HStack(spacing: 16) {
                    Text("封面").foregroundStyle(Color.atmusicComment)
                    Spacer()
                    Group {
                        if let coverData, let image = UIImage(data: coverData) {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            CoverImage(url: coverURL, size: 48, cornerRadius: 8)
                        }
                    }
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Image(systemName: "pencil").foregroundStyle(Color.atmusicComment)
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            ForEach(SongMetadataField.allCases) { field in
                Divider().padding(.leading, 20).overlay(Color.atmusicSecondary.opacity(0.26))
                Button { editingField = field } label: {
                    HStack(spacing: 14) {
                        Text(field.title).foregroundStyle(Color.atmusicComment)
                        Spacer(minLength: 16)
                        Text(value(for: field).isEmpty ? "未填写" : value(for: field))
                            .foregroundStyle(value(for: field).isEmpty ? Color.atmusicComment.opacity(0.7) : Color.atmusicLabel)
                            .multilineTextAlignment(.trailing)
                            .lineLimit(field == .comment ? 2 : 1)
                        Image(systemName: "pencil").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.atmusicComment)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 15)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func value(for field: SongMetadataField) -> String {
        switch field {
        case .title: return title
        case .artist: return artist
        case .album: return album
        case .albumArtist: return albumArtist
        case .genre: return genre
        case .year: return year
        case .trackNumber: return trackNumber
        case .discNumber: return discNumber
        case .comment: return comment
        }
    }

    private func set(_ value: String, for field: SongMetadataField) {
        switch field {
        case .title: title = value
        case .artist: artist = value
        case .album: album = value
        case .albumArtist: albumArtist = value
        case .genre: genre = value
        case .year: year = value
        case .trackNumber: trackNumber = value
        case .discNumber: discNumber = value
        case .comment: comment = value
        }
    }

    private func save() {
        Task { await saveInternal() }
    }

    @MainActor
    private func saveInternal() async {
        saving = true
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)
        var updatedCoverURL = coverURL
        var newCoverImage: UIImage? = nil
        do {
            if let coverData, let image = UIImage(data: coverData),
               let jpeg = image.jpegData(compressionQuality: 0.92),
               let relativePath = song.localRelativePath {
                let baseName = ((relativePath as NSString).lastPathComponent as NSString).deletingPathExtension
                let previousCoverURL = song.coverURL
                updatedCoverURL = try LocalAudioFileManager.shared.writeSupportData(
                    jpeg,
                    relativePath: "ATMusicAudio/Artwork/\(baseName)-\(UUID().uuidString).jpg"
                )
                if let previousCoverURL, previousCoverURL != updatedCoverURL {
                    LocalAudioFileManager.shared.removeManagedArtworkIfNeeded(previousCoverURL)
                    ATMusicRemoteCoverCache.remove(for: previousCoverURL)
                    if previousCoverURL.isFileURL {
                        ATMusicImageFileCache.remove(previousCoverURL.path)
                    }
                }
                newCoverImage = image
            } else if let chosenCoverURL = coverURL, !chosenCoverURL.isFileURL, let relativePath = song.localRelativePath {
                message = "正在下载并保存封面…"
                var req = URLRequest(url: chosenCoverURL)
                req.timeoutInterval = 12
                if let (data, resp) = try? await URLSession.shared.data(for: req),
                   let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                   let img = UIImage(data: data),
                   let jpeg = img.jpegData(compressionQuality: 0.92) {
                    let baseName = ((relativePath as NSString).lastPathComponent as NSString).deletingPathExtension
                    let previousCoverURL = song.coverURL
                    if let localArtworkURL = try? LocalAudioFileManager.shared.writeSupportData(
                        jpeg,
                        relativePath: "ATMusicAudio/Artwork/\(baseName)-\(UUID().uuidString).jpg"
                    ) {
                        if let previousCoverURL, previousCoverURL != localArtworkURL {
                            LocalAudioFileManager.shared.removeManagedArtworkIfNeeded(previousCoverURL)
                            ATMusicRemoteCoverCache.remove(for: previousCoverURL)
                            if previousCoverURL.isFileURL {
                                ATMusicImageFileCache.remove(previousCoverURL.path)
                            }
                        }
                        updatedCoverURL = localArtworkURL
                        newCoverImage = img
                    }
                }
            } else if let chosenCoverURL = coverURL, chosenCoverURL.isFileURL {
                if let data = try? Data(contentsOf: chosenCoverURL), let img = UIImage(data: data) {
                    newCoverImage = img
                }
            }

            if let newCoverImage {
                if let updatedCoverURL {
                    ATMusicRemoteCoverCache.store(newCoverImage, for: updatedCoverURL)
                }
                if let oldCover = song.coverURL {
                    ATMusicRemoteCoverCache.store(newCoverImage, for: oldCover)
                }
                if let chosenCoverURL = coverURL {
                    ATMusicRemoteCoverCache.store(newCoverImage, for: chosenCoverURL)
                }
            }

            let updated = Song(
                id: song.id,
                name: trimmedTitle,
                artists: trimmedArtist.isEmpty ? "未知艺术家" : trimmedArtist,
                album: trimmedAlbum.isEmpty ? "未知专辑" : trimmedAlbum,
                coverURL: updatedCoverURL,
                duration: song.duration,
                source: .local,
                localRelativePath: song.localRelativePath,
                albumArtist: albumArtist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : albumArtist.trimmingCharacters(in: .whitespacesAndNewlines),
                genre: genre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : genre.trimmingCharacters(in: .whitespacesAndNewlines),
                year: year.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : year.trimmingCharacters(in: .whitespacesAndNewlines),
                comment: comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : comment.trimmingCharacters(in: .whitespacesAndNewlines),
                discNumber: max(1, TrackSequencing.parseNumber(discNumber, range: 1...999) ?? song.discNumber),
                trackNumber: TrackSequencing.parseNumber(trackNumber, range: 0...999) ?? 0,
                fee: song.fee
            )
            guard onSave(updated) else {
                saving = false
                message = "保存失败：本地音乐库未能保存新标签"
                return
            }
            if let updatedCoverURL, updatedCoverURL.isFileURL,
               !FileManager.default.fileExists(atPath: updatedCoverURL.path) {
                saving = false
                message = "保存失败：新封面文件校验失败"
                return
            }
            LocalLibraryStore.shared.updateImportedSong(updated)
            player.replaceSong(updated)
            DetailSongsCache.shared.updateSong(updated)
            if let updatedCoverURL {
                NotificationCenter.default.post(name: .atmusicCoverDidUpdate, object: updatedCoverURL)
            }
            if let oldCover = song.coverURL, oldCover != updatedCoverURL {
                NotificationCenter.default.post(name: .atmusicCoverDidUpdate, object: oldCover)
            }
            NotificationCenter.default.post(name: .atmusicSongMetadataDidUpdate, object: updated)

            // 资料库已存好；接着把同一份信息物理写进音频文件本体（失败只记录，不推翻保存结果）。
            message = "正在把标签与封面写入音频文件…"
            let embedResult = await LocalTagWriteback.writeAsync(
                song: updated,
                coverData: LocalTagWriteback.coverData(for: updated, newImage: newCoverImage, explicitData: coverData)
            )
            ATMusicHaptics.success()
            switch embedResult {
            case .success(let report):
                ToastCenter.shared.show("已更新并写回文件（\(report.summary)）")
            case .failure(let error):
                ATMusicLogger.shared.log("⚠️ 本地歌曲标签内嵌失败：\(updated.name) - \(error.localizedDescription)", level: .warn)
                ToastCenter.shared.show("信息已更新，但写回文件失败：\(error.localizedDescription)")
            }
            dismiss()
        } catch {
            saving = false
            message = "保存失败：\(error.localizedDescription)"
        }
    }
}

/// 批量编辑本地离线歌曲信息：统一修改演出者、专辑名称、专辑演出者、流派、年份、备注与封面。
struct LocalBatchMetadataEditorSheet: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.dismiss) private var dismiss
    let songs: [Song]

    @State private var artist = ""
    @State private var album = ""
    @State private var albumArtist = ""
    @State private var genre = ""
    @State private var year = ""
    @State private var comment = ""
    @State private var trackStart = "1"
    @State private var discOverride = ""
    @State private var sequentialEnabled = false
    @State private var numberingOverrides: [String: TrackNumberingOverride] = [:]
    @State private var numberingOrder: [String] = []
    @State private var selectedCoverURL: URL?
    @State private var selectedCoverData: Data?
    @State private var selectedCoverThumbnail: UIImage?
    @State private var showCoverPicker = false
    @State private var isSaving = false
    @State private var message = ""
    @State private var savedCount: Int?

    private var discOverrideNumber: Int? {
        TrackSequencing.parseNumber(discOverride, range: 1...999)
    }

    private var numberingPlan: TrackSequencing.Plan {
        TrackSequencing.plan(
            songs: songs,
            order: numberingOrder,
            discOverride: discOverrideNumber,
            startTrack: TrackSequencing.parseNumber(trackStart, range: 1...999) ?? 1
        )
    }

    var body: some View {
        NavigationView {
            ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        // 1. 顶部选中歌曲概览
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("批量修改 \(songs.count) 首本地离线歌曲")
                                    .font(ATMusicFont.appFont(15, .semibold))
                                    .foregroundStyle(Color.atmusicLabel)
                                Spacer()
                                if let savedCount {
                                    Text("已更新 \(savedCount)/\(songs.count) 首")
                                        .font(ATMusicFont.appFont(13, .semibold))
                                        .foregroundStyle(theme.accent.highlight)
                                }
                            }
                            // 歌曲横向预览卡片
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(Array(songs.prefix(15)), id: \.identityKey) { s in
                                        HStack(spacing: 6) {
                                            CoverImage(url: s.coverURL, size: 28, cornerRadius: 6)
                                            Text(s.name)
                                                .font(ATMusicFont.appFont(12))
                                                .foregroundStyle(Color.atmusicLabel)
                                                .lineLimit(1)
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.primary.opacity(0.06), in: Capsule())
                                    }
                                    if songs.count > 15 {
                                        Text("等共 \(songs.count) 首")
                                            .font(ATMusicFont.appFont(11))
                                            .foregroundStyle(Color.atmusicComment)
                                    }
                                }
                            }
                        }
                        .padding(14)
                        .background(Color.atmusicCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                        // 2. 统一专辑封面设置
                        VStack(alignment: .leading, spacing: 10) {
                            Text("专辑封面（可选）")
                                .font(ATMusicFont.appFont(13, .semibold))
                                .foregroundStyle(Color.atmusicComment)
                            Button {
                                showCoverPicker = true
                            } label: {
                                HStack(spacing: 12) {
                                    if let selectedCoverThumbnail {
                                        Image(uiImage: selectedCoverThumbnail)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 48, height: 48)
                                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    } else if let selectedCoverData, let img = UIImage(data: selectedCoverData) {
                                        Image(uiImage: img)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 48, height: 48)
                                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    } else if let selectedCoverURL {
                                        CoverImage(url: selectedCoverURL, size: 48, cornerRadius: 10)
                                    } else {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(Color.primary.opacity(0.08))
                                            .frame(width: 48, height: 48)
                                            .overlay {
                                                Image(systemName: "photo.badge.plus")
                                                    .font(.system(size: 20))
                                                    .foregroundStyle(Color.atmusicAmber)
                                            }
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(selectedCoverData != nil || selectedCoverURL != nil ? "已选择新封面" : "点击选择统一专辑封面")
                                            .font(ATMusicFont.appFont(14, .medium))
                                            .foregroundStyle(Color.atmusicLabel)
                                        Text(selectedCoverData != nil || selectedCoverURL != nil ? "所有选中的歌曲将统一更换为该封面" : "支持在线搜索或从相册选择")
                                            .font(ATMusicFont.appFont(11))
                                            .foregroundStyle(Color.atmusicComment)
                                    }
                                    Spacer()
                                    if selectedCoverData != nil || selectedCoverURL != nil || selectedCoverThumbnail != nil {
                                        Button {
                                            selectedCoverData = nil
                                            selectedCoverURL = nil
                                            selectedCoverThumbnail = nil
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 16))
                                                .foregroundStyle(Color.atmusicComment)
                                        }
                                        .buttonStyle(.plain)
                                    } else {
                                        Image(systemName: "chevron.right")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(Color.atmusicComment.opacity(0.5))
                                    }
                                }
                                .padding(12)
                                .background(Color.atmusicCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }

                        // 3. 元数据输入字段
                        VStack(alignment: .leading, spacing: 10) {
                            Text("标签字段（留空项保持原样不变）")
                                .font(ATMusicFont.appFont(13, .semibold))
                                .foregroundStyle(Color.atmusicComment)

                            VStack(spacing: 8) {
                                batchInputField(title: "演出者", placeholder: "留空保持原样", text: $artist)
                                batchInputField(title: "专辑名称", placeholder: "留空保持原样", text: $album)
                                batchInputField(title: "专辑演出者", placeholder: "留空保持原样", text: $albumArtist)
                                batchInputField(title: "流派", placeholder: "留空保持原样", text: $genre)
                                batchInputField(title: "专辑年份", placeholder: "留空保持原样", text: $year, keyboard: .numberPad)
                                batchInputField(title: "备注", placeholder: "留空保持原样", text: $comment)
                            }
                            .padding(12)
                            .background(Color.atmusicCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }

                        // 3.5 曲目编号（盘号 / 音轨号）
                        TrackNumberingCard(
                            songs: songs,
                            order: $numberingOrder,
                            startTrack: $trackStart,
                            discOverride: $discOverride,
                            sequentialEnabled: $sequentialEnabled,
                            overrides: $numberingOverrides
                        )

                        if !message.isEmpty {
                            Text(message)
                                .font(ATMusicFont.appFont(12))
                                .foregroundStyle(theme.accent.highlight)
                        }

                        if isSaving {
                            ProgressView(value: Double(savedCount ?? 0), total: Double(songs.count))
                                .tint(Color.atmusicAmber)
                                .padding(.vertical, 4)
                        }

                        GlassButton(
                            title: isSaving ? "正在写入本地库…" : "保存并应用到 \(songs.count) 首歌曲",
                            systemName: "checkmark.circle.fill",
                            prominent: true
                        ) {
                            Task { await save() }
                        }
                        .disabled(isSaving)
                        .padding(.top, 8)
                    }
                    .padding(20)
                }
            }
            .navigationTitle("批量编辑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showCoverPicker) {
            if let first = songs.first {
                SongCoverSearchGridSheet(song: first) { candidate in
                    selectedCoverURL = candidate.song.coverURL
                    selectedCoverData = nil
                    selectedCoverThumbnail = nil
                    showCoverPicker = false
                } onPickData: { data in
                    let optimized = SynologyAPI.shared.optimizedCoverData(data)
                    selectedCoverData = optimized
                    selectedCoverThumbnail = UIImage(data: optimized)
                    selectedCoverURL = nil
                    showCoverPicker = false
                }
            }
        }
    }

    @ViewBuilder
    private func batchInputField(title: String, placeholder: String, text: Binding<String>, keyboard: UIKeyboardType = .default) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(ATMusicFont.appFont(14))
                .foregroundStyle(Color.atmusicLabel)
                .frame(width: 80, alignment: .leading)
            TextField(placeholder, text: text)
                .font(ATMusicFont.appFont(14))
                .keyboardType(keyboard)
            if !text.wrappedValue.isEmpty {
                Button {
                    text.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.atmusicComment.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
    }

    @MainActor
    private func save() async {
        guard !isSaving else { return }
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAlbumArtist = albumArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGenre = genre.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedYear = year.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)

        let hasFieldChanges = !trimmedArtist.isEmpty || !trimmedAlbum.isEmpty || !trimmedAlbumArtist.isEmpty || !trimmedGenre.isEmpty || !trimmedYear.isEmpty || !trimmedComment.isEmpty
        let hasCoverChanges = selectedCoverURL != nil || selectedCoverData != nil
        let hasNumberingChanges = sequentialEnabled || discOverrideNumber != nil || !numberingOverrides.isEmpty

        guard hasFieldChanges || hasCoverChanges || hasNumberingChanges else {
            message = "请至少输入一项需要修改的字段、曲目编号或选择专辑封面"
            return
        }

        isSaving = true
        message = "正在准备封面与元数据…"

        // 统一处理封面落盘（预压缩尺寸防 OOM）
        var sharedCoverURL: URL? = nil
        var sharedCoverImage: UIImage? = nil
        if let data = selectedCoverData {
            let optimized = SynologyAPI.shared.optimizedCoverData(data)
            if let img = UIImage(data: optimized), let jpeg = img.jpegData(compressionQuality: 0.88) {
                sharedCoverURL = try? LocalAudioFileManager.shared.writeSupportData(
                    jpeg,
                    relativePath: "ATMusicAudio/Artwork/batch-\(UUID().uuidString).jpg"
                )
                if let sharedCoverURL {
                    ATMusicRemoteCoverCache.store(img, for: sharedCoverURL)
                }
                sharedCoverImage = img
            }
        } else if let remoteURL = selectedCoverURL {
            if remoteURL.isFileURL {
                sharedCoverURL = remoteURL
                if let data = try? Data(contentsOf: remoteURL) {
                    let optimized = SynologyAPI.shared.optimizedCoverData(data)
                    if let img = UIImage(data: optimized) {
                        sharedCoverImage = img
                    }
                }
            } else {
                var req = URLRequest(url: remoteURL)
                req.timeoutInterval = 15
                if let (data, resp) = try? await URLSession.shared.data(for: req),
                   let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                   !data.isEmpty {
                    let optimized = SynologyAPI.shared.optimizedCoverData(data)
                    if let img = UIImage(data: optimized), let jpeg = img.jpegData(compressionQuality: 0.88) {
                        sharedCoverURL = try? LocalAudioFileManager.shared.writeSupportData(
                            jpeg,
                            relativePath: "ATMusicAudio/Artwork/batch-\(UUID().uuidString).jpg"
                        )
                        if let sharedCoverURL {
                            ATMusicRemoteCoverCache.store(img, for: sharedCoverURL)
                        }
                        sharedCoverImage = img
                    }
                }
            }
        }

        var saved = 0
        var allUpdated: [Song] = []
        let plan = sequentialEnabled ? numberingPlan : nil
        for song in songs {
            let numbers = plan?.assignment(for: song.identityKey)
            let manual = numberingOverrides[song.identityKey]
            let discForSong = manual.flatMap { TrackSequencing.parseNumber($0.disc, range: 1...999) }
                ?? numbers?.disc
                ?? discOverrideNumber
                ?? song.discNumber
            // 手改优先：清空格子即「该曲不写曲目号」，不再回落到自动编号
            let trackForSong: Int? = manual.map { TrackSequencing.parseNumber($0.track, range: 0...999) ?? 0 } ?? numbers?.track
            let newArtist = trimmedArtist.isEmpty ? song.artists : trimmedArtist
            let newAlbum = trimmedAlbum.isEmpty ? song.album : trimmedAlbum
            let newAlbumArtist = trimmedAlbumArtist.isEmpty ? song.albumArtist : trimmedAlbumArtist
            let newGenre = trimmedGenre.isEmpty ? song.genre : trimmedGenre
            let newYear = trimmedYear.isEmpty ? song.year : trimmedYear
            let newComment = trimmedComment.isEmpty ? song.comment : trimmedComment
            let newCoverURL = sharedCoverURL ?? song.coverURL

            let updated = Song(
                id: song.id,
                name: song.name,
                artists: newArtist,
                album: newAlbum,
                coverURL: newCoverURL,
                duration: song.duration,
                source: .local,
                localRelativePath: song.localRelativePath,
                albumArtist: newAlbumArtist,
                genre: newGenre,
                year: newYear,
                comment: newComment,
                discNumber: discForSong,
                trackNumber: trackForSong ?? song.trackNumber,
                fee: song.fee
            )
            allUpdated.append(updated)

            if player.currentSong?.identityKey == updated.identityKey {
                player.replaceSong(updated)
            }
            if let sharedCoverImage {
                if let old = song.coverURL {
                    ATMusicRemoteCoverCache.store(sharedCoverImage, for: old)
                    NotificationCenter.default.post(name: .atmusicCoverDidUpdate, object: old)
                }
            }
            NotificationCenter.default.post(name: .atmusicSongMetadataDidUpdate, object: updated)
            saved += 1
            savedCount = saved
            message = "正在写入本地库…（\(saved)/\(songs.count)）"
        }

        // 统一批量落盘并更新索引，单次完成所有写入
        if !allUpdated.isEmpty {
            LocalLibraryStore.shared.updateImportedSongs(allUpdated)
            DetailSongsCache.shared.updateSongs(allUpdated)
        }

        if let sharedCoverURL {
            NotificationCenter.default.post(name: .atmusicCoverDidUpdate, object: sharedCoverURL)
        }
        NotificationCenter.default.post(name: .atmusicSongMetadataDidUpdate, object: nil)

        // 索引落盘之后再逐首把标签写进音频文件本体（逐个顺序执行，避免同时重写多个大文件）。
        if !allUpdated.isEmpty {
            message = "正在把标签写回音频文件…（0/\(allUpdated.count)）"
            var written = 0
            var failed = 0
            let coverPayload = sharedCoverImage.flatMap { LocalTagWriteback.optimizedCover($0) }
            for updated in allUpdated {
                switch await LocalTagWriteback.writeAsync(song: updated, coverData: coverPayload) {
                case .success:
                    written += 1
                case .failure(let error):
                    failed += 1
                    if failed <= 3 {
                        ATMusicLogger.shared.log("⚠️ 批量内嵌标签失败：\(updated.name) - \(error.localizedDescription)", level: .warn)
                    }
                }
                message = "正在把标签写回音频文件…（\(written + failed)/\(allUpdated.count)）"
            }
            isSaving = false
            ATMusicHaptics.success()
            if failed == 0 {
                ToastCenter.shared.show("批量修改完成：\(saved) 首已更新并写回文件")
            } else {
                ToastCenter.shared.show("批量修改完成：\(saved) 首已更新，\(written) 首写回文件，\(failed) 首仅存资料库")
            }
            dismiss()
            return
        }

        isSaving = false
        ATMusicHaptics.success()
        ToastCenter.shared.show("批量修改完成（\(saved) 首已更新）")
        dismiss()
    }
}

// MARK: - 本地音频导入

struct LocalAudioImportReport: Sendable {
    let songs: [Song]
    let importedCount: Int
    let duplicateCount: Int
    let failedCount: Int

    var message: String {
        "已导入 \(importedCount) 首，重复 \(duplicateCount) 首，失败 \(failedCount) 首"
    }
}

final class LocalAudioImportService: @unchecked Sendable {
    static let shared = LocalAudioImportService()
    private let manager = LocalAudioFileManager.shared
    private let supportedExtensions: Set<String> = ["mp3", "m4a", "mp4", "aac", "alac", "flac", "wav", "aiff", "aif"]

    private init() {}

    func importFiles(_ urls: [URL]) async -> LocalAudioImportReport {
        var songs: [Song] = []
        var duplicateCount = 0
        var failedCount = 0
        for url in urls {
            do {
                guard supportedExtensions.contains(url.pathExtension.lowercased()) else {
                    throw LibraryStorageError.unsupportedSchema
                }
                let hash = try sha256(of: url)
                if manager.findDuplicate(sha256: hash) != nil {
                    duplicateCount += 1
                    continue
                }
                let metadata = readMetadata(from: url)
                let songID = stableID(hash)
                let record = try manager.registerFile(
                    sourceTempURL: url,
                    songId: "local-\(hash)",
                    originalFilename: url.lastPathComponent,
                    kind: .userImported,
                    sha256: hash
                )
                var coverURL: URL?
                if let artwork = metadata.artwork {
                    let coverPath = "ATMusicAudio/Artwork/\(record.id).jpg"
                    coverURL = try manager.writeSupportData(artwork, relativePath: coverPath)
                }
                let lrcPath = url.deletingPathExtension().lastPathComponent + ".lrc"
                if let lrcURL = url.deletingLastPathComponent().appendingPathComponent(lrcPath) as URL?,
                   let lrcData = try? Data(contentsOf: lrcURL), !lrcData.isEmpty {
                    let localLRCPath = (record.relativePath as NSString).deletingPathExtension + ".lrc"
                    _ = try? manager.writeSupportData(lrcData, relativePath: localLRCPath)
                }
                songs.append(Song(
                    id: songID,
                    name: metadata.title,
                    artists: metadata.artist,
                    album: metadata.album,
                    coverURL: coverURL,
                    duration: metadata.duration,
                    source: .local,
                    localRelativePath: record.relativePath
                ))
            } catch {
                failedCount += 1
                ATMusicLogger.shared.log("本地音频导入失败：\(url.lastPathComponent) \(error.localizedDescription)", level: .warn)
            }
        }
        return LocalAudioImportReport(songs: songs, importedCount: songs.count, duplicateCount: duplicateCount, failedCount: failedCount)
    }

    private struct Metadata {
        let title: String
        let artist: String
        let album: String
        let duration: TimeInterval
        let artwork: Data?
    }

    private func readMetadata(from url: URL) -> Metadata {
        let asset = AVURLAsset(url: url)
        let values = asset.commonMetadata
        func string(for key: AVMetadataKey) -> String? {
            guard let item = values.first(where: { $0.commonKey == key }) else { return nil }
            if let value = item.stringValue { return value }
            if let number = item.numberValue { return number.stringValue }
            return nil
        }
        let titleValue = string(for: .commonKeyTitle)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = titleValue?.isEmpty == false ? titleValue! : url.deletingPathExtension().lastPathComponent
        let artistValue = string(for: .commonKeyArtist)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = artistValue?.isEmpty == false ? artistValue! : "未知艺术家"
        let album = string(for: .commonKeyAlbumName)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let artwork = values.first(where: { $0.commonKey == .commonKeyArtwork })?.dataValue
        let duration = asset.duration.isNumeric && asset.duration.seconds.isFinite ? max(0, asset.duration.seconds) : 0
        return Metadata(title: title, artist: artist, album: album, duration: duration, artwork: artwork)
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func stableID(_ value: String) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 { hash ^= UInt64(byte); hash &*= 1_099_511_628_211 }
        let result = Int(hash & 0x7fff_ffff_ffff_ffff)
        return result == 0 ? 1 : result
    }
}

extension LocalAudioFileManager {
    func removeManagedArtworkIfNeeded(_ url: URL) {
        guard url.isFileURL else { return }
        let root = ManagedAudioPath.documents
            .appendingPathComponent("ATMusicAudio/Artwork", isDirectory: true)
            .standardizedFileURL
        let target = url.standardizedFileURL
        guard target.path.hasPrefix(root.path + "/") else { return }
        try? FileManager.default.removeItem(at: target)
    }

    func writeSupportData(_ data: Data, relativePath: String) throws -> URL {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: temp, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temp) }
        return try copySupportFile(sourceURL: temp, relativePath: relativePath)
    }
}

struct LocalAudioDocumentPicker: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.audio], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: LocalAudioDocumentPicker
        init(_ parent: LocalAudioDocumentPicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.onPick(urls)
        }
    }
}
