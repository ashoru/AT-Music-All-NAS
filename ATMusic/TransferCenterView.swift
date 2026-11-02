import SwiftUI

// MARK: - 传输中心（离线下载队列 · 本地离线库 · 群晖 NAS 归档上传）

struct TransferCenterView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var theme: ThemeStore
    @ObservedObject private var downloadManager = DownloadManager.shared
    @ObservedObject private var synology = SynologyAPI.shared
    @ObservedObject private var archiveStore = NASArchiveStore.shared
    @ObservedObject private var localStore = LocalLibraryStore.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: Int = 0
    @State private var isRepairingArchiveTags = false
    @State private var offlineFilter: Int = 0 // 0: 单曲, 1: 专辑, 2: 歌手
    @State private var shareFile: ShareFileItem?

    @State private var isMultiSelectingOffline: Bool = false
    @State private var selectedOfflineIDs: Set<String> = []
    @State private var showBatchAddToPlaylist: Bool = false
    @State private var showBatchEdit: Bool = false
    @State private var showBatchDeleteAlert: Bool = false
    @State private var showLyricsBatch: Bool = false
    @State private var showCancelAllDownloadsAlert: Bool = false
    @State private var showCancelAllUploadsAlert: Bool = false
    @State private var dragStartIndex: Int?
    @State private var dragTargetSelected: Bool = true
    @State private var lastDragIndex: Int?
    @State private var initialSelectedOfflineIDsOnDrag: Set<String>? = nil

    private func handleOfflineDragChange(startIndex: Int, deltaRows: Int) {
        let keys = downloadManager.downloadedSongs.map(\.identityKey)
        guard startIndex >= 0, startIndex < keys.count else { return }
        if dragStartIndex == nil {
            dragStartIndex = startIndex
            initialSelectedOfflineIDsOnDrag = selectedOfflineIDs
            let willSelect = !selectedOfflineIDs.contains(keys[startIndex])
            dragTargetSelected = willSelect
            lastDragIndex = nil
        }
        guard let start = dragStartIndex, let initial = initialSelectedOfflineIDsOnDrag else { return }
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
        selectedOfflineIDs = updated
    }

    private func handleOfflineDragEnd() {
        dragStartIndex = nil
        initialSelectedOfflineIDsOnDrag = nil
        lastDragIndex = nil
    }

    private var selectedOfflineSongs: [Song] {
        downloadManager.downloadedSongs.filter { selectedOfflineIDs.contains($0.identityKey) }
    }

    private var activeDownloadsCount: Int {
        downloadManager.activeDownloads.filter { $0.status != .completed }.count
    }

    private var activeUploadsCount: Int {
        downloadManager.activeUploads.filter { $0.status != .completed }.count
    }

    private var offlineAlbums: [(name: String, artist: String, coverURL: URL?, songs: [Song])] {
        let grouped = Dictionary(grouping: downloadManager.downloadedSongs) { song in
            let album = song.album.trimmingCharacters(in: .whitespacesAndNewlines)
            return album.isEmpty ? "单曲" : album
        }
        return grouped.map { name, songs in
            (name, songs.first?.artists ?? "未知歌手", songs.first?.coverURL, songs)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var offlineSources: [(source: SongSource, count: Int, songs: [Song])] {
        let grouped = Dictionary(grouping: downloadManager.downloadedSongs) { $0.source }
        let order: [SongSource] = [.netease, .qq, .kugou, .synology, .local]
        return order.compactMap { src in
            guard let songs = grouped[src], !songs.isEmpty else { return nil }
            return (src, songs.count, songs)
        }
    }

    private var offlineArtists: [(name: String, coverURL: URL?, songs: [Song])] {
        var map: [String: [Song]] = [:]
        for song in downloadManager.downloadedSongs {
            let names = song.artists
                .components(separatedBy: " / ")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            for name in names.isEmpty ? ["未知艺术家"] : names {
                map[name, default: []].append(song)
            }
        }
        return map.map { name, songs in (name, songs.first?.coverURL, songs) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        ZStack {
            GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)

            VStack(spacing: 0) {
                tabSelector
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 8)

                TabView(selection: $selectedTab) {
                    downloadQueueSection
                        .tag(0)
                    offlineLibrarySection
                        .tag(1)
                    nasUploadSection
                        .tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .frame(maxWidth: DeviceLayoutHelper.contentMaxWidth(for: horizontalSizeClass))
            .frame(maxWidth: .infinity)

            if isMultiSelectingOffline && !selectedOfflineIDs.isEmpty && selectedTab == 1 {
                VStack {
                    Spacer()
                    offlineBatchFloatingActionBar
                        .padding(.horizontal, 16)
                        .padding(.bottom, 28)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .navigationTitle("传输中心")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                topBarTrailingAction
            }
        }
        .sheet(item: $shareFile) { item in
            ShareSheet(items: [item.url])
        }
        .sheet(isPresented: $showBatchAddToPlaylist) {
            AddToPlaylistSheet(songs: selectedOfflineSongs)
                .environmentObject(theme)
        }
        .sheet(isPresented: $showBatchEdit) {
            LocalBatchMetadataEditorSheet(songs: selectedOfflineSongs)
                .environmentObject(player)
                .environmentObject(theme)
        }
        .sheet(isPresented: $showLyricsBatch) {
            NASBatchMaintenanceSheet()
                .environmentObject(player)
                .environmentObject(theme)
        }
        .confirmationDialog("批量删除离线歌曲", isPresented: $showBatchDeleteAlert, titleVisibility: .visible) {
            Button("从本地移除选中的 \(selectedOfflineIDs.count) 首歌曲", role: .destructive) {
                let songs = selectedOfflineSongs
                downloadManager.removeDownloaded(songs: songs)
                isMultiSelectingOffline = false
                selectedOfflineIDs.removeAll()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后将移除本地受管音频副本以释放设备空间，不会影响在线曲库。")
        }
        .confirmationDialog("取消所有下载任务？", isPresented: $showCancelAllDownloadsAlert, titleVisibility: .visible) {
            Button("取消并清空下载队列", role: .destructive) {
                downloadManager.cancelAllDownloads()
            }
            Button("返回", role: .cancel) {}
        }
        .confirmationDialog("取消所有上传任务？", isPresented: $showCancelAllUploadsAlert, titleVisibility: .visible) {
            Button("取消并清空上传队列", role: .destructive) {
                downloadManager.cancelAllUploads()
            }
            Button("返回", role: .cancel) {}
        }
    }

    // MARK: - 顶部操作与分段器 (原生对齐)

    @ViewBuilder
    private var topBarTrailingAction: some View {
        if selectedTab == 0 && !downloadManager.activeDownloads.isEmpty {
            Button {
                if downloadManager.isPaused {
                    downloadManager.resumeAllDownloads()
                } else {
                    downloadManager.pauseAllDownloads()
                }
            } label: {
                Image(systemName: downloadManager.isPaused ? "play.circle" : "pause.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.atmusicAmber)
            }
        } else if selectedTab == 1 && !downloadManager.downloadedSongs.isEmpty {
            if isMultiSelectingOffline {
                HStack(spacing: 12) {
                    Button(selectedOfflineIDs.count == downloadManager.downloadedSongs.count ? "取消全选" : "全选") {
                        ATMusicHaptics.tap()
                        if selectedOfflineIDs.count == downloadManager.downloadedSongs.count {
                            selectedOfflineIDs.removeAll()
                        } else {
                            selectedOfflineIDs = Set(downloadManager.downloadedSongs.map(\.identityKey))
                        }
                    }
                    .font(ATMusicFont.appFont(13, .semibold))
                    .foregroundStyle(Color.atmusicAmber)

                    Button("完成") {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            isMultiSelectingOffline = false
                            selectedOfflineIDs.removeAll()
                        }
                        ATMusicHaptics.tap()
                    }
                    .font(ATMusicFont.appFont(13, .semibold))
                }
            } else {
                Menu {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            isMultiSelectingOffline = true
                            selectedOfflineIDs.removeAll()
                        }
                        ATMusicHaptics.tap()
                    } label: {
                        Label("多选管理", systemImage: "checklist")
                    }
                    Button(role: .destructive) {
                        showBatchDeleteAlert = true
                    } label: {
                        Label("清空所有离线", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.primary)
                }
            }
        }
    }

    // MARK: - 顶部标签切换器（iOS 原生 Segmented Picker）

    private var tabSelector: some View {
        Picker("传输分类", selection: $selectedTab) {
            Text("下载中\(activeDownloadsCount > 0 ? " (\(activeDownloadsCount))" : "")").tag(0)
            Text("已离线 (\(downloadManager.downloadedSongs.count))").tag(1)
            Text("上传 NAS\(activeUploadsCount > 0 ? " (\(activeUploadsCount))" : "")").tag(2)
        }
        .pickerStyle(.segmented)
    }

    // MARK: - 1. 正在下载视图

    private var downloadQueueSection: some View {
        ScrollView {
            VStack(spacing: 12) {
                if !downloadManager.activeDownloads.isEmpty {
                    downloadGlobalControlBanner
                }

                if downloadManager.activeDownloads.isEmpty {
                    emptyStateView(
                        icon: "arrow.down.circle",
                        title: "暂无正在下载的任务",
                        subtitle: "在歌曲、专辑或歌单中点击下载，即可在此查看实时进度与网速"
                    )
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(downloadManager.activeDownloads) { task in
                            downloadTaskRow(task)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 140)
        }
    }

    private var downloadGlobalControlBanner: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("下载速率")
                        .font(ATMusicFont.appFont(12, .medium))
                        .foregroundStyle(Color.atmusicComment)
                    Text(downloadManager.formattedDownloadSpeed)
                        .font(ATMusicFont.appFont(14, .bold, .monospaced))
                        .foregroundStyle(Color.atmusicAmber)
                }
                Text("剩余 \(activeDownloadsCount) 首歌曲排队中")
                    .font(ATMusicFont.appFont(11))
                    .foregroundStyle(Color.atmusicComment.opacity(0.8))
            }

            Spacer()

            HStack(spacing: 8) {
                Button {
                    if downloadManager.isPaused {
                        downloadManager.resumeAllDownloads()
                    } else {
                        downloadManager.pauseAllDownloads()
                    }
                } label: {
                    Text(downloadManager.isPaused ? "全部继续" : "全部暂停")
                        .font(ATMusicFont.appFont(12, .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    downloadManager.clearFinishedDownloads()
                } label: {
                    Text("清除已完成")
                        .font(ATMusicFont.appFont(12, .semibold))
                        .foregroundStyle(Color.atmusicComment)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    showCancelAllDownloadsAlert = true
                } label: {
                    Text("全部取消")
                        .font(ATMusicFont.appFont(12, .semibold))
                        .foregroundStyle(Color.red.opacity(0.85))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.red.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background {
            ATMusicGlass(shape: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(.horizontal, 16)
    }

    private func downloadTaskRow(_ task: DownloadTaskItem) -> some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                CoverImage(url: task.song.coverURL, size: 48, cornerRadius: 10)
                SourceBadgeView(source: task.song.source, compact: true)
                    .offset(x: 2, y: 2)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(task.song.name)
                        .font(ATMusicFont.appFont(14, .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                        .lineLimit(1)
                    Spacer()
                    Text(task.requestedQuality.displayName)
                        .font(ATMusicFont.appFont(10, .semibold))
                        .foregroundStyle(Color.atmusicAmber)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.atmusicAmber.opacity(0.15), in: Capsule())
                }

                Text(task.song.artists)
                    .font(ATMusicFont.appFont(12))
                    .foregroundStyle(Color.atmusicComment)
                    .lineLimit(1)

                ProgressView(value: task.progress)
                    .tint(Color.atmusicAmber)
                    .scaleEffect(x: 1, y: 0.8, anchor: .center)

                HStack {
                    Text(task.statusDescription)
                        .font(ATMusicFont.appFont(11))
                        .foregroundStyle(task.status == .completed ? Color.atmusicSage : Color.atmusicComment)

                    Spacer()

                    if task.status == .downloading {
                        Text("\(task.formattedProgress) · \(task.formattedSpeed)")
                            .font(ATMusicFont.appFont(10, .regular, .monospaced))
                            .foregroundStyle(Color.atmusicComment)
                    }
                }
            }

            // 控制按键
            HStack(spacing: 10) {
                if task.status == .downloading {
                    Button {
                        downloadManager.pauseDownload(id: task.id)
                    } label: {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.atmusicAmber)
                    }
                    .buttonStyle(.plain)
                } else if task.status == .paused {
                    Button {
                        downloadManager.resumeDownload(id: task.id)
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.atmusicAmber)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    downloadManager.cancelDownload(id: task.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.atmusicComment.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background {
            ATMusicGlass(shape: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    // MARK: - 2. 已离线歌曲库视图

    private var offlineBatchControlBar: some View {
        HStack(spacing: 12) {
            Button {
                if selectedOfflineIDs.count == downloadManager.downloadedSongs.count {
                    selectedOfflineIDs.removeAll()
                } else {
                    selectedOfflineIDs = Set(downloadManager.downloadedSongs.map { $0.identityKey })
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: selectedOfflineIDs.count == downloadManager.downloadedSongs.count && !downloadManager.downloadedSongs.isEmpty ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.atmusicAmber)
                    Text(selectedOfflineIDs.count == downloadManager.downloadedSongs.count && !downloadManager.downloadedSongs.isEmpty ? "取消全选" : "全选")
                        .font(ATMusicFont.appFont(13, .medium))
                        .foregroundStyle(Color.atmusicLabel)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.06), in: Capsule())
            }
            .buttonStyle(.plain)

            Spacer()

            Text("已选 \(selectedOfflineIDs.count) 首")
                .font(ATMusicFont.appFont(13, .semibold))
                .foregroundStyle(Color.atmusicAmber)

            Spacer()

            Button {
                withAnimation {
                    isMultiSelectingOffline = false
                    selectedOfflineIDs.removeAll()
                }
            } label: {
                Text("退出")
                    .font(ATMusicFont.appFont(13, .medium))
                    .foregroundStyle(Color.atmusicComment)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background {
            ATMusicGlass(shape: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(.horizontal, 16)
    }

    private var offlineBatchFloatingActionBar: some View {
        HStack(spacing: 0) {
            Button {
                let songs = selectedOfflineSongs
                guard !songs.isEmpty else { return }
                player.play(songs: songs, startAt: 0)
                isMultiSelectingOffline = false
                selectedOfflineIDs.removeAll()
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
                let songs = selectedOfflineSongs
                for s in songs.reversed() { player.playNext(s) }
                ToastCenter.shared.show("已将 \(songs.count) 首歌曲加入下一首播放")
                isMultiSelectingOffline = false
                selectedOfflineIDs.removeAll()
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
                    let songs = selectedOfflineSongs
                    downloadManager.startBatchUploadToNAS(songs: songs)
                    isMultiSelectingOffline = false
                    selectedOfflineIDs.removeAll()
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
        .frame(maxWidth: 560)
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .background {
            ATMusicGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: Color.black.opacity(0.18), radius: 16, x: 0, y: 6)
        }
    }

    private var offlineLibrarySection: some View {
        ScrollView {
            VStack(spacing: 14) {
                if isMultiSelectingOffline {
                    offlineBatchControlBar
                } else {
                    offlineSummaryCard

                    if !downloadManager.downloadedSongs.isEmpty {
                        offlineFilterPicker
                    }
                }

                if downloadManager.downloadedSongs.isEmpty {
                    emptyStateView(
                        icon: "internaldrive",
                        title: "暂无离线歌曲",
                        subtitle: "下载后的歌曲将自动保存在本机受管沙盒，支持无网络离线 0ms 极速秒播"
                    )
                } else if offlineFilter == 0 || isMultiSelectingOffline {
                    // 单曲列表：iPad 宽屏下采用自适应双列流式排版，iPhone 保持连续紧凑单列
                    if DeviceLayoutHelper.isIPadRegular(horizontalSizeClass) {
                        LazyVGrid(columns: DeviceLayoutHelper.songListColumns(for: horizontalSizeClass, spacing: 16), spacing: 10) {
                            ForEach(Array(downloadManager.downloadedSongs.enumerated()), id: \.element.identityKey) { index, song in
                                let isSelected = selectedOfflineIDs.contains(song.identityKey)
                                SongCell(
                                    song: song,
                                    playbackContext: downloadManager.downloadedSongs,
                                    playbackIndex: index,
                                    onTap: {
                                        player.play(songs: downloadManager.downloadedSongs, startAt: index)
                                    },
                                    isMultiSelecting: isMultiSelectingOffline,
                                    isSelected: isSelected,
                                    onToggleSelection: {
                                        ATMusicHaptics.select()
                                        if isSelected {
                                            selectedOfflineIDs.remove(song.identityKey)
                                        } else {
                                            selectedOfflineIDs.insert(song.identityKey)
                                        }
                                    },
                                    onDragSelectionChange: { startIdx, deltaRows in
                                        handleOfflineDragChange(startIndex: startIdx, deltaRows: deltaRows)
                                    },
                                    onDragSelectionEnd: {
                                        handleOfflineDragEnd()
                                    },
                                    selectionIndex: index
                                )
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background {
                                    ATMusicGlass(shape: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(downloadManager.downloadedSongs.enumerated()), id: \.element.identityKey) { index, song in
                                let isSelected = selectedOfflineIDs.contains(song.identityKey)
                                SongCell(
                                    song: song,
                                    playbackContext: downloadManager.downloadedSongs,
                                    playbackIndex: index,
                                    onTap: {
                                        player.play(songs: downloadManager.downloadedSongs, startAt: index)
                                    },
                                    isMultiSelecting: isMultiSelectingOffline,
                                    isSelected: isSelected,
                                    onToggleSelection: {
                                        ATMusicHaptics.select()
                                        if isSelected {
                                            selectedOfflineIDs.remove(song.identityKey)
                                        } else {
                                            selectedOfflineIDs.insert(song.identityKey)
                                        }
                                    },
                                    onDragSelectionChange: { startIdx, deltaRows in
                                        handleOfflineDragChange(startIndex: startIdx, deltaRows: deltaRows)
                                    },
                                    onDragSelectionEnd: {
                                        handleOfflineDragEnd()
                                    },
                                    selectionIndex: index
                                )
                            }
                        }
                        .padding(.horizontal, 16)
                        .background {
                            ATMusicGlass(shape: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .padding(.horizontal, 16)
                    }
                } else if offlineFilter == 1 {
                    // 按专辑聚合：iPad 宽屏下双列自适应，iPhone 单列
                    LazyVGrid(columns: DeviceLayoutHelper.songListColumns(for: horizontalSizeClass, spacing: 14), spacing: 10) {
                        ForEach(offlineAlbums, id: \.name) { album in
                            HStack(spacing: 12) {
                                CoverImage(url: album.coverURL, size: 48, cornerRadius: 8)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(album.name)
                                        .font(ATMusicFont.appFont(15, .semibold))
                                        .foregroundStyle(Color.atmusicLabel)
                                    Text("\(album.artist) · \(album.songs.count) 首")
                                        .font(ATMusicFont.appFont(12))
                                        .foregroundStyle(Color.atmusicComment)
                                }
                                Spacer()
                                Button {
                                    player.play(songs: album.songs, startAt: 0)
                                } label: {
                                    Image(systemName: "play.circle.fill")
                                        .font(.system(size: 24))
                                        .foregroundStyle(Color.atmusicAmber)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(12)
                            .background {
                                ATMusicGlass(shape: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                } else if offlineFilter == 3 {
                    // 按来源平台聚合
                    LazyVStack(spacing: 12) {
                        ForEach(offlineSources, id: \.source) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 10) {
                                    SourceBadgeView(source: group.source, compact: false)
                                    Text("\(group.count) 首已离线歌曲")
                                        .font(ATMusicFont.appFont(12))
                                        .foregroundStyle(Color.atmusicComment)
                                    Spacer()
                                    Button {
                                        player.play(songs: group.songs, startAt: 0)
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "play.circle.fill")
                                            Text("播放全部")
                                        }
                                        .font(ATMusicFont.appFont(12, .semibold))
                                        .foregroundStyle(Color.atmusicAmber)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(Color.atmusicAmber.opacity(0.12), in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 4)

                                if DeviceLayoutHelper.isIPadRegular(horizontalSizeClass) {
                                    LazyVGrid(columns: DeviceLayoutHelper.songListColumns(for: horizontalSizeClass, spacing: 14), spacing: 8) {
                                        ForEach(Array(group.songs.enumerated()), id: \.element.identityKey) { index, song in
                                            SongCell(song: song, playbackContext: group.songs, playbackIndex: index, onTap: {
                                                player.play(songs: group.songs, startAt: index)
                                            })
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background {
                                                    RoundedRectangle(cornerRadius: 10)
                                                        .fill(Color.primary.opacity(0.03))
                                                }
                                        }
                                    }
                                } else {
                                    LazyVStack(spacing: 0) {
                                        ForEach(Array(group.songs.enumerated()), id: \.element.identityKey) { index, song in
                                            SongCell(song: song, playbackContext: group.songs, playbackIndex: index, onTap: {
                                                player.play(songs: group.songs, startAt: index)
                                            })
                                        }
                                    }
                                }
                            }
                            .padding(12)
                            .background {
                                ATMusicGlass(shape: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                } else {
                    // 按歌手聚合：iPad 宽屏下双列自适应，iPhone 单列
                    LazyVGrid(columns: DeviceLayoutHelper.songListColumns(for: horizontalSizeClass, spacing: 14), spacing: 10) {
                        ForEach(offlineArtists, id: \.name) { artist in
                            HStack(spacing: 12) {
                                CoverImage(url: artist.coverURL, size: 48, cornerRadius: 24)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(artist.name)
                                        .font(ATMusicFont.appFont(15, .semibold))
                                        .foregroundStyle(Color.atmusicLabel)
                                    Text("\(artist.songs.count) 首离线歌曲")
                                        .font(ATMusicFont.appFont(12))
                                        .foregroundStyle(Color.atmusicComment)
                                }
                                Spacer()
                                Button {
                                    player.play(songs: artist.songs, startAt: 0)
                                } label: {
                                    Image(systemName: "play.circle.fill")
                                        .font(.system(size: 24))
                                        .foregroundStyle(Color.atmusicAmber)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(12)
                            .background {
                                ATMusicGlass(shape: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 140)
        }
    }

    private var offlineSummaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("本地受管离线库")
                        .font(ATMusicFont.appFont(16, .bold))
                        .foregroundStyle(Color.atmusicLabel)
                    Text("已离线 \(downloadManager.downloadedSongs.count) 首歌曲 · 占用设备约 \(downloadManager.formattedDownloadedSize)")
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(Color.atmusicComment)
                }
                Spacer()
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.atmusicAmber)
            }

            if !downloadManager.downloadedSongs.isEmpty {
                HStack(spacing: 10) {
                    Button {
                        player.play(songs: downloadManager.downloadedSongs, startAt: 0)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 11))
                            Text("顺序播放")
                                .font(ATMusicFont.appFont(12, .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color.atmusicAmber, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        player.play(songs: downloadManager.downloadedSongs.shuffled(), startAt: 0)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "shuffle")
                                .font(.system(size: 11))
                            Text("随机播放")
                                .font(ATMusicFont.appFont(12, .semibold))
                        }
                        .foregroundStyle(Color.atmusicLabel)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)

                    if synology.isLoggedIn {
                        Button {
                            downloadManager.startBatchUploadToNAS(songs: downloadManager.downloadedSongs)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "externaldrive.badge.plus")
                                    .font(.system(size: 11))
                                Text("全量归档至 NAS")
                                    .font(ATMusicFont.appFont(12, .semibold))
                            }
                            .foregroundStyle(Color.atmusicLabel)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(14)
        .background {
            ATMusicGlass(shape: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .padding(.horizontal, 16)
    }

    private var offlineFilterPicker: some View {
        HStack(spacing: 8) {
            filterButton(title: "单曲", index: 0)
            filterButton(title: "专辑", index: 1)
            filterButton(title: "歌手", index: 2)
            filterButton(title: "来源平台", index: 3)
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    private func filterButton(title: String, index: Int) -> some View {
        let isSelected = offlineFilter == index
        return Button {
            withAnimation { offlineFilter = index }
        } label: {
            Text(title)
                .font(ATMusicFont.appFont(12, isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.atmusicAmber : Color.atmusicComment)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background {
                    if isSelected {
                        Capsule().fill(Color.atmusicAmber.opacity(0.16))
                    } else {
                        Capsule().fill(Color.clear)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 3. 群晖 NAS 上传归档视图

    /// NAS 批量维护入口（歌词写回 / 专辑封面补全）：与「上传归档」「修复标签」同一处。
    private var lyricsBatchCard: some View {
        Button {
            ATMusicHaptics.tap()
            showLyricsBatch = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "quote.bubble")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.atmusicAmber)
                    .frame(width: 38, height: 38)
                    .background(Color.atmusicAmber.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("NAS 批量维护")
                        .font(ATMusicFont.appFont(14, .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                    Text(synology.isLoggedIn
                         ? "歌词写回 · 专辑封面补全，可选文件夹与歌曲"
                         : "需先登录群晖 NAS")
                        .font(ATMusicFont.appFont(11))
                        .foregroundStyle(Color.atmusicComment)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.atmusicComment.opacity(0.5))
            }
            .padding(12)
            .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 16, style: .continuous)) }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .opacity(synology.isLoggedIn ? 1 : 0.55)
        .disabled(!synology.isLoggedIn)
    }

    private var nasUploadSection: some View {
        ScrollView {
            VStack(spacing: 12) {
                nasStatusCard
                lyricsBatchCard

                if !downloadManager.activeUploads.isEmpty {
                    uploadGlobalControlBanner
                }

                if downloadManager.activeUploads.isEmpty {
                    emptyStateView(
                        icon: "externaldrive.badge.plus",
                        title: "暂无上传归档任务",
                        subtitle: "在已离线歌曲列表中点击「上传归档到群晖 NAS」，即可自动将音频、同名歌词与封面打包备份至您的 NAS 音乐库"
                    )
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(downloadManager.activeUploads) { task in
                            uploadTaskRow(task)
                        }
                    }
                    .padding(.horizontal, 16)
                }

                archivedHistorySection
            }
            .padding(.top, 8)
            .padding(.bottom, 140)
        }
    }

    /// 旧版本归档时标签回写被入口作用域校验拦截，归档文件只剩源文件自带标签（可能为空）。
    /// 用账本里保存的歌名/歌手/专辑，经归档专用入口把标签补写回 NAS 上的文件。
    private func repairArchivedTags() {
        guard !isRepairingArchiveTags else { return }
        isRepairingArchiveTags = true
        Task {
            var fixed = 0
            var skipped = 0
            var failed = 0
            for record in archiveStore.recentRecords {
                do {
                    let state = try await SynologyAPI.shared.archivedTagState(path: record.nasPath)
                    if !state.artist.isEmpty {
                        skipped += 1
                        continue
                    }
                    let recordSong = Song(
                        id: 0,
                        name: record.songName,
                        artists: record.artistName,
                        album: record.albumName,
                        coverURL: record.coverURL,
                        duration: 0,
                        source: .synology,
                        synologyPath: record.nasPath
                    )
                    let patch = SynologyTagPatch(
                        title: record.songName,
                        artist: record.artistName,
                        album: record.albumName,
                        albumArtist: record.artistName,
                        genre: nil,
                        year: nil,
                        comment: "AT Music 归档"
                    )
                    try await SynologyAPI.shared.applyArchiveMetadata(nasPath: record.nasPath, song: recordSong, patch: patch, coverData: nil)
                    fixed += 1
                } catch {
                    failed += 1
                    ATMusicLogger.shared.log("⚠️ 归档标签修复失败：\(record.songName) - \(error.localizedDescription)", level: .error)
                }
            }
            ATMusicLogger.shared.log("🧰 归档标签修复完成：补写 \(fixed) 首，已有标签 \(skipped) 首，失败 \(failed) 首", level: .info)
            await MainActor.run {
                isRepairingArchiveTags = false
                ToastCenter.shared.show("标签修复：已补 \(fixed) 首 · 无需修复 \(skipped) 首 · 失败 \(failed) 首")
            }
        }
    }

    private var archivedHistorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.atmusicAmber)
                    Text("历史归档记录（\(archiveStore.recentRecords.count) 首）")
                        .font(ATMusicFont.appFont(13, .bold))
                        .foregroundStyle(Color.atmusicLabel)
                }
                Spacer()
                if !archiveStore.recentRecords.isEmpty {
                    Button(isRepairingArchiveTags ? "修复中…" : "修复标签") {
                        repairArchivedTags()
                    }
                    .font(ATMusicFont.appFont(11))
                    .foregroundStyle(Color.atmusicAmber)
                    .buttonStyle(.plain)
                    .disabled(isRepairingArchiveTags)
                    Button("清空记录") {
                        archiveStore.clearHistory()
                        ATMusicHaptics.tap()
                    }
                    .font(ATMusicFont.appFont(11))
                    .foregroundStyle(Color.atmusicComment)
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)

            if archiveStore.recentRecords.isEmpty {
                HStack {
                    Spacer()
                    Text("暂无归档历史记录")
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(Color.atmusicComment)
                        .padding(.vertical, 16)
                    Spacer()
                }
                .background {
                    ATMusicGlass(shape: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .padding(.horizontal, 16)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(archiveStore.recentRecords) { record in
                        HStack(spacing: 12) {
                            CoverImage(url: record.coverURL, size: 40, cornerRadius: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.songName)
                                    .font(ATMusicFont.appFont(13, .semibold))
                                    .foregroundStyle(Color.atmusicLabel)
                                    .lineLimit(1)
                                Text("\(record.artistName) · \(record.albumName)")
                                    .font(ATMusicFont.appFont(11))
                                    .foregroundStyle(Color.atmusicComment)
                                    .lineLimit(1)
                                Text(record.nasPath)
                                    .font(ATMusicFont.appFont(9, .regular, .monospaced))
                                    .foregroundStyle(Color.atmusicComment.opacity(0.8))
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(record.formattedDate)
                                .font(ATMusicFont.appFont(10, .regular, .monospaced))
                                .foregroundStyle(Color.atmusicComment.opacity(0.7))
                        }
                        .padding(10)
                        .background {
                            ATMusicGlass(shape: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var nasStatusCard: some View {
        let uploadRoot = UserDefaults.standard.string(forKey: "atmusic.nas.uploadRoot") ?? "/music/ATMusic"
        let isHierarchy = UserDefaults.standard.object(forKey: "atmusic.nas.uploadHierarchy") as? Bool ?? true
        let destSummary = isHierarchy ? "\(uploadRoot)/{歌手}/{专辑}/" : "\(uploadRoot)/"
        return HStack(spacing: 12) {
            Image(systemName: synology.isLoggedIn ? "externaldrive.badge.checkmark" : "externaldrive.trianglebadge.exclamationmark")
                .font(.system(size: 28))
                .foregroundStyle(synology.isLoggedIn ? Color.atmusicSage : Color.orange)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(synology.isLoggedIn ? "群晖 NAS · 已连接" : "群晖 NAS · 未登录")
                        .font(ATMusicFont.appFont(15, .bold))
                        .foregroundStyle(Color.atmusicLabel)
                    if synology.isLoggedIn {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(synology.isLanActive ? Color.green : Color.yellow)
                                .frame(width: 7, height: 7)
                            Text(synology.isLanActive ? "局域网高速直连" : "公网安全穿透")
                                .font(ATMusicFont.appFont(10, .semibold))
                                .foregroundStyle(synology.isLanActive ? Color.green : Color.yellow)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                    }
                }
                if synology.isLoggedIn {
                    Text("目标保存路径：\(destSummary)")
                        .font(ATMusicFont.appFont(11))
                        .foregroundStyle(Color.atmusicComment)
                } else {
                    Text("请先登录群晖账号，以使用歌曲云端双向归档功能")
                        .font(ATMusicFont.appFont(11))
                        .foregroundStyle(Color.atmusicComment)
                }
            }
            Spacer()
        }
        .padding(14)
        .background {
            ATMusicGlass(shape: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .padding(.horizontal, 16)
    }

    private var uploadGlobalControlBanner: some View {
        HStack {
            Text("上传队列（\(activeUploadsCount) 首正在处理）")
                .font(ATMusicFont.appFont(13, .semibold))
                .foregroundStyle(Color.atmusicLabel)
            Spacer()

            HStack(spacing: 8) {
                let hasFailed = downloadManager.activeUploads.contains {
                    if case .failed = $0.status { return true }
                    return false
                }
                if hasFailed {
                    Button {
                        downloadManager.retryAllFailedUploads()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .semibold))
                            Text("重试失败")
                                .font(ATMusicFont.appFont(12, .semibold))
                        }
                        .foregroundStyle(Color.atmusicAmber)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.atmusicAmber.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Button("清空已完成") {
                    downloadManager.clearFinishedUploads()
                }
                .font(ATMusicFont.appFont(12))
                .foregroundStyle(Color.atmusicComment)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.06), in: Capsule())
                .buttonStyle(.plain)

                Button("全部取消") {
                    showCancelAllUploadsAlert = true
                }
                .font(ATMusicFont.appFont(12))
                .foregroundStyle(Color.red.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.red.opacity(0.08), in: Capsule())
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
    }

    private func uploadTaskRow(_ task: UploadTaskItem) -> some View {
        HStack(spacing: 12) {
            CoverImage(url: task.song.coverURL, size: 48, cornerRadius: 10)

            VStack(alignment: .leading, spacing: 4) {
                Text(task.song.name)
                    .font(ATMusicFont.appFont(14, .semibold))
                    .foregroundStyle(Color.atmusicLabel)
                    .lineLimit(1)

                Text(task.song.artists)
                    .font(ATMusicFont.appFont(12))
                    .foregroundStyle(Color.atmusicComment)
                    .lineLimit(1)

                ProgressView(value: task.progress)
                    .tint(Color.atmusicSage)
                    .scaleEffect(x: 1, y: 0.8, anchor: .center)

                HStack {
                    Text(task.statusDescription)
                        .font(ATMusicFont.appFont(11))
                        .foregroundStyle(task.status == .completed ? Color.atmusicSage : Color.atmusicComment)
                    Spacer()
                    if task.status == .uploadingAudio {
                        Text("\(task.formattedProgress) · \(task.formattedSpeed)")
                            .font(ATMusicFont.appFont(10, .regular, .monospaced))
                            .foregroundStyle(Color.atmusicComment)
                    }
                }
            }

            HStack(spacing: 10) {
                if case .failed = task.status {
                    Button {
                        downloadManager.retryUpload(id: task.id)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.atmusicAmber)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    downloadManager.cancelUpload(id: task.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.atmusicComment.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background {
            ATMusicGlass(shape: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    // MARK: - 空状态辅助视图

    private func emptyStateView(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Color.atmusicComment.opacity(0.6))
                .padding(.top, 40)
            Text(title)
                .font(ATMusicFont.appFont(16, .bold))
                .foregroundStyle(Color.atmusicLabel)
            Text(subtitle)
                .font(ATMusicFont.appFont(12))
                .foregroundStyle(Color.atmusicComment)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}
