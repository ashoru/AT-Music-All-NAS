import SwiftUI

struct SongCell: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthStore
    @AppStorage("atmusic.uiStyle") private var uiStyleRaw = ATMusicUIStyle.liquid.rawValue
    @AppStorage("atmusic.showSongVIPBadge") private var showSongVIPBadge = true
    @AppStorage(ThirdPartyAudioQuality.downloadStorageKey) private var downloadQualityRaw = ThirdPartyAudioQuality.kb320.rawValue
    private let downloadFeatureUnlocked = true

    let song: Song
    var showCover = true
    /// 保留旧调用参数兼容；歌曲行统一使用 1.8.1 的连续紧凑样式，不再渲染单独玻璃卡片。
    var glassRow = false
    /// 需要整体玻璃容器时，单行保持纯净背景
    var suppressNativeCleanRowGlass = false
    var playbackContext: [Song] = []
    var playbackIndex: Int?
    var trackNumber: Int? = nil
    /// 副标题覆盖；nil 时按默认规则显示艺人/专辑
    var subtitleText: String? = nil
    /// 收藏列表模式：非 nil 时尾部显示红心按钮（替代时长），点击切换收藏
    var favoriteToggle: (() -> Void)? = nil
    var onTap: (() -> Void)? = nil

    // MARK: - 多选支持（嵌入行内，零间距/高度跳变，消除手势冲突与错位）
    var isMultiSelecting: Bool = false
    var isSelected: Bool = false
    var onToggleSelection: (() -> Void)? = nil
    var onDragSelectionChange: ((_ startIndex: Int, _ deltaRows: Int) -> Void)? = nil
    var onDragSelectionEnd: (() -> Void)? = nil
    var selectionIndex: Int = 0

    // MARK: - 标准初始化器（消除多闭包歧义，尾随闭包必定匹配 onTap，点击行即刻播放）
    init(
        song: Song,
        showCover: Bool = true,
        glassRow: Bool = false,
        suppressNativeCleanRowGlass: Bool = false,
        playbackContext: [Song] = [],
        playbackIndex: Int? = nil,
        trackNumber: Int? = nil,
        subtitleText: String? = nil,
        onTap: (() -> Void)? = nil
    ) {
        self.song = song
        self.showCover = showCover
        self.glassRow = glassRow
        self.suppressNativeCleanRowGlass = suppressNativeCleanRowGlass
        self.playbackContext = playbackContext
        self.playbackIndex = playbackIndex
        self.trackNumber = trackNumber
        self.subtitleText = subtitleText
        self.favoriteToggle = nil
        self.isMultiSelecting = false
        self.isSelected = false
        self.onToggleSelection = nil
        self.onDragSelectionChange = nil
        self.onDragSelectionEnd = nil
        self.selectionIndex = 0
        self.onTap = onTap
    }

    // MARK: - 扩展多选初始化器（支持批量选择、滑动多选、收藏红心按钮）
    init(
        song: Song,
        showCover: Bool = true,
        glassRow: Bool = false,
        suppressNativeCleanRowGlass: Bool = false,
        playbackContext: [Song] = [],
        playbackIndex: Int? = nil,
        trackNumber: Int? = nil,
        subtitleText: String? = nil,
        favoriteToggle: (() -> Void)? = nil,
        onTap: (() -> Void)? = nil,
        isMultiSelecting: Bool,
        isSelected: Bool = false,
        onToggleSelection: (() -> Void)? = nil,
        onDragSelectionChange: ((_ startIndex: Int, _ deltaRows: Int) -> Void)? = nil,
        onDragSelectionEnd: (() -> Void)? = nil,
        selectionIndex: Int = 0
    ) {
        self.song = song
        self.showCover = showCover
        self.glassRow = glassRow
        self.suppressNativeCleanRowGlass = suppressNativeCleanRowGlass
        self.playbackContext = playbackContext
        self.playbackIndex = playbackIndex
        self.trackNumber = trackNumber
        self.subtitleText = subtitleText
        self.favoriteToggle = favoriteToggle
        self.isMultiSelecting = isMultiSelecting
        self.isSelected = isSelected
        self.onToggleSelection = onToggleSelection
        self.onDragSelectionChange = onDragSelectionChange
        self.onDragSelectionEnd = onDragSelectionEnd
        self.selectionIndex = selectionIndex
        self.onTap = onTap
    }

    @State private var showAddToPlaylist = false
    @State private var shareFile: ShareFileItem?
    @State private var showDownloadedActionSheet = false
    @State private var showDownloadPicker = false
    @State private var showLocalMetadataEditor = false
    @State private var showSynologyMetadataEditor = false
    @State private var overrideSong: Song? = nil

    private var displayedSong: Song {
        if let overrideSong { return overrideSong }
        if let current = player.currentSong,
           (current.identityKey == song.identityKey || (current.source == song.source && current.id == song.id && current.id != 0)) {
            return current
        }
        return song
    }

    private var isCurrent: Bool {
        player.currentSong?.identityKey == displayedSong.identityKey
    }

    private var isNativeClean: Bool {
        ATMusicUIStyle(rawValue: uiStyleRaw) == .nativeClean
    }

    // MARK: - 四风格统一行规格（nativeClean 严格对标 Apple Music 列表）
    private var rowMinHeight: CGFloat { isNativeClean ? 56 : 64 }
    private var coverSize: CGFloat { isNativeClean ? 44 : 46 }
    private var coverRadius: CGFloat { isNativeClean ? 8 : 10 }
    private var subtitleFontSize: CGFloat { isNativeClean ? 13 : 12 }
    private var dividerLeading: CGFloat {
        (trackNumber != nil || isMultiSelecting ? 38 : 0) + (showCover ? coverSize + 12 : 0)
    }
    private var resolvedSubtitle: String {
        if let subtitleText { return subtitleText }
        return displayedSong.artists.isEmpty ? displayedSong.album : displayedSong.artists
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            if isMultiSelecting {
                MultiSelectCheckmark(
                    isSelected: isSelected,
                    index: selectionIndex,
                    rowHeight: rowMinHeight,
                    onToggle: {
                        onToggleSelection?()
                        ATMusicHaptics.tap()
                    },
                    onDragChange: { startIdx, deltaRows in
                        onDragSelectionChange?(startIdx, deltaRows)
                    },
                    onDragEnd: {
                        onDragSelectionEnd?()
                    }
                )
                .frame(width: 26, alignment: .center)
            } else if let trackNumber {
                Text("\(trackNumber)")
                    .font(ATMusicFont.appFont(14, isCurrent ? .bold : .medium, .monospaced))
                    .foregroundStyle(isCurrent ? Color.atmusicAmber : Color.atmusicComment)
                    .frame(width: 26, alignment: .center)
            }
            if showCover {
                CoverImage(url: displayedSong.coverURL, size: coverSize, cornerRadius: coverRadius)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(displayedSong.name)
                        .font(ATMusicFont.appFont(15, isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? Color.atmusicAmber : Color.atmusicLabel)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                Text(resolvedSubtitle)
                    .font(ATMusicFont.appFont(subtitleFontSize))
                    .foregroundStyle(Color.atmusicComment)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            if isCurrent && player.isPlaying {
                NowPlayingIndicator()
            }
            if showSongVIPBadge, displayedSong.isVIP {
                SongVIPBadgeView()
            }
            downloadIndicatorView
            SourceBadgeView(source: displayedSong.source, compact: true)
            if let favoriteToggle {
                Button(action: favoriteToggle) {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.red)
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .frame(minWidth: 32, alignment: .trailing)
            } else {
                Text(displayedSong.formattedDuration)
                    .font(ATMusicFont.appFont(12, .regular, .monospaced))
                    .foregroundStyle(Color.atmusicComment)
                    .frame(minWidth: 36, alignment: .trailing)
            }

            if !isMultiSelecting {
                Menu {
                    songActionMenuItems
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.atmusicComment.opacity(0.85))
                        .frame(width: 24, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showAddToPlaylist) {
            AddToPlaylistSheet(song: displayedSong)
                .environmentObject(theme)
        }
        .sheet(item: $shareFile) { item in
            ShareSheet(items: [item.url])
        }
        .confirmationDialog("已离线歌曲：\(displayedSong.name)", isPresented: $showDownloadedActionSheet, titleVisibility: .visible) {
            Button("编辑歌曲信息与封面") {
                showLocalMetadataEditor = true
            }
            Button("重新下载 (更换音质)") {
                showDownloadPicker = true
            }
            if displayedSong.source != .synology {
                Button("转档到群晖 NAS") {
                    DownloadManager.shared.startUploadToNAS(song: displayedSong)
                }
            }
            Button("查看本地音频参数") {
                showAudioParameters()
            }
            if let url = DownloadManager.shared.localAudioURL(for: displayedSong) {
                Button("隔空投送 / 导出") {
                    shareFile = ShareFileItem(url: url)
                }
            }
            Button("从本地移除下载", role: .destructive) {
                DownloadManager.shared.removeDownloaded(song: displayedSong)
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("选择离线下载音质", isPresented: $showDownloadPicker, titleVisibility: .visible) {
            ForEach(ThirdPartyAudioQuality.supported(for: displayedSong.source)) { quality in
                Button(quality.displayName) {
                    DownloadManager.shared.startDownload(song: displayedSong, quality: quality, forceRedownload: true)
                }
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showLocalMetadataEditor) {
            let targetSong = displayedSong.source == .local ? displayedSong : (DownloadManager.shared.downloadedSongs.first(where: { LocalLibraryStore.isMatchingSong($0, displayedSong) }) ?? displayedSong)
            LocalSongMetadataEditorSheet(song: targetSong) { updated in
                let saved = LocalLibraryStore.shared.updateImportedSong(updated)
                if saved {
                    overrideSong = updated
                    player.replaceSong(updated)
                    ToastCenter.shared.show("歌曲信息已更新")
                }
                return saved
            }
            .environmentObject(theme)
            .environmentObject(player)
        }
        .sheet(isPresented: $showSynologyMetadataEditor) {
            if displayedSong.source == .synology {
                SynologyMetadataEditorSheet(song: displayedSong) { updated in
                    overrideSong = updated
                }
                .environmentObject(theme)
                .environmentObject(player)
            }
        }
    }

    @ViewBuilder
    private var songActionMenuItems: some View {
        Button {
            player.playNext(displayedSong)
        } label: {
            Label("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        Button {
            showAddToPlaylist = true
        } label: {
            Label("添加到歌单", systemImage: "text.badge.plus")
        }
        if downloadFeatureUnlocked {
            if DownloadManager.shared.isDownloaded(song: displayedSong) {
                Button {
                    showDownloadPicker = true
                } label: {
                    Label("重新下载 (更换音质)", systemImage: "arrow.clockwise.circle")
                }
                if displayedSong.source != .synology {
                    Button {
                        DownloadManager.shared.startUploadToNAS(song: displayedSong)
                    } label: {
                        Label("转档到群晖 NAS", systemImage: "externaldrive.badge.plus")
                    }
                }
                if let url = DownloadManager.shared.localAudioURL(for: displayedSong) {
                    Button {
                        shareFile = ShareFileItem(url: url)
                    } label: {
                        Label("分享 / 导出音频文件", systemImage: "square.and.arrow.up")
                    }
                }
                Button(role: .destructive) {
                    DownloadManager.shared.removeDownloaded(song: displayedSong)
                } label: {
                    Label("从本地移除下载", systemImage: "trash")
                }
            } else {
                Button {
                    downloadSong()
                } label: {
                    Label(displayedSong.source == .synology ? "离线下载到本机" : "离线下载歌曲", systemImage: "arrow.down.circle")
                }
                if displayedSong.source != .synology {
                    Button {
                        DownloadManager.shared.startUploadToNAS(song: displayedSong)
                    } label: {
                        Label("转档到群晖 NAS", systemImage: "externaldrive.badge.plus")
                    }
                }
            }
        }
        if displayedSong.source == .synology {
            Button {
                showSynologyMetadataEditor = true
            } label: {
                Label("编辑 NAS 标签与封面", systemImage: "pencil")
            }
        } else if displayedSong.source == .local || DownloadManager.shared.isDownloaded(song: displayedSong) {
            Button {
                showLocalMetadataEditor = true
            } label: {
                Label("编辑歌曲信息与封面", systemImage: "pencil")
            }
        }
        if !isCurrent {
            Button {
                handleRowTap()
            } label: {
                Label("立即播放", systemImage: "play.fill")
            }
        }
    }

    @ViewBuilder
    private var downloadIndicatorView: some View {
        if DownloadManager.shared.isDownloaded(song: displayedSong) {
            Button {
                showDownloadedActionSheet = true
                ATMusicHaptics.tap()
            } label: {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.atmusicAmber)
            }
            .buttonStyle(.plain)
        } else if DownloadManager.shared.isDownloading(song: displayedSong) {
            let task = DownloadManager.shared.activeDownloads.first(where: { $0.song.identityKey == displayedSong.identityKey })
            if let task, task.status == .downloading {
                Button {
                    DownloadManager.shared.pauseDownload(id: task.id)
                    ATMusicHaptics.select()
                } label: {
                    ZStack {
                        Circle()
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1.5)
                            .frame(width: 15, height: 15)
                        Circle()
                            .trim(from: 0, to: CGFloat(max(0.08, task.progress)))
                            .stroke(Color.atmusicAmber, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                            .frame(width: 15, height: 15)
                            .rotationEffect(.degrees(-90))
                        Image(systemName: "pause.fill")
                            .font(.system(size: 5, weight: .bold))
                            .foregroundStyle(Color.atmusicAmber)
                    }
                }
                .buttonStyle(.plain)
            } else if let task, task.status == .paused {
                Button {
                    DownloadManager.shared.resumeDownload(id: task.id)
                    ATMusicHaptics.select()
                } label: {
                    ZStack {
                        Circle()
                            .stroke(Color.atmusicAmber.opacity(0.35), lineWidth: 1.5)
                            .frame(width: 15, height: 15)
                        Image(systemName: "play.fill")
                            .font(.system(size: 5, weight: .bold))
                            .foregroundStyle(Color.atmusicAmber)
                    }
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "clock.arrow.2.circlepath")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.atmusicComment)
            }
        }
    }

    private func showAudioParameters() {
        if let url = DownloadManager.shared.localAudioURL(for: displayedSong) {
            let ext = url.pathExtension.uppercased()
            var sizeStr = "未知大小"
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? NSNumber {
                sizeStr = ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .file)
            }
            ToastCenter.shared.show("本地音轨：\(ext) · \(sizeStr)")
        } else {
            ToastCenter.shared.show("未找到本地音轨文件")
        }
    }

    @MainActor
    private func downloadSong() {
        let quality: DownloadQuality
        if UserDefaults.standard.object(forKey: ThirdPartyAudioQuality.downloadStorageKey) == nil {
            quality = ThirdPartyAudioQuality.current
        } else {
            quality = DownloadQuality(sourceValue: downloadQualityRaw) ?? ThirdPartyAudioQuality.current
        }
        ATMusicHaptics.medium()
        DownloadManager.shared.startDownload(song: displayedSong, quality: quality)
    }

    /// 若通知携带的歌曲对象与本行歌曲身份匹配，返回该最新对象；否则返回 nil。
    private func matchedSong(from note: Notification) -> Song? {
        guard let updated = note.object as? Song else { return nil }
        if updated.identityKey == song.identityKey
            || LocalLibraryStore.isMatchingSong(updated, song)
            || (updated.source == song.source && updated.id == song.id && updated.id != 0) {
            return updated
        }
        return nil
    }

    /// 通知未携带歌曲对象时，按来源重新查询最新缓存/本地数据。
    private func fallbackRefreshedSong(includeLocal: Bool) -> Song? {
        if song.source == .synology {
            return SynologyAPI.shared.cachedSong(for: song)
        } else if includeLocal && song.source == .local {
            return LocalLibraryStore.shared.localSong(for: song.identityKey)
        }
        return nil
    }

    private func handleRowTap() {
        ATMusicHaptics.tap()
        if let onTap {
            onTap()
        } else if let playbackIndex, !playbackContext.isEmpty, playbackIndex >= 0, playbackIndex < playbackContext.count {
            player.play(songs: playbackContext, startAt: playbackIndex)
        } else if !playbackContext.isEmpty {
            if let idx = playbackContext.firstIndex(where: { $0.identityKey == displayedSong.identityKey }) {
                player.play(songs: playbackContext, startAt: idx)
            } else {
                player.play(songs: playbackContext, startAt: 0)
            }
        } else if let index = player.queue.firstIndex(where: { $0.identityKey == displayedSong.identityKey }) {
            player.playQueueIndex(index)
        } else {
            player.play(songs: [displayedSong], startAt: 0)
        }
    }

    @ViewBuilder
    private var baseRowContent: some View {
        rowContent
            .frame(height: rowMinHeight)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.atmusicComment.opacity(0.18))
                    .frame(height: 0.5)
                    .padding(.leading, dividerLeading)
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    var body: some View {
        let _ = theme.accent
        Group {
            if isMultiSelecting {
                baseRowContent
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onToggleSelection?()
                        ATMusicHaptics.tap()
                    }
            } else {
                baseRowContent
                    .contentShape(Rectangle())
                    .onTapGesture {
                        handleRowTap()
                    }
                    .contextMenu {
                        songActionMenuItems
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            player.playNext(displayedSong)
                            ATMusicHaptics.tap()
                        } label: {
                            Label("下一首", systemImage: "text.line.first.and.arrowtriangle.forward")
                        }
                        .tint(Color.atmusicAmber)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button {
                            showAddToPlaylist = true
                        } label: {
                            Label("添加到歌单", systemImage: "text.badge.plus")
                        }
                        .tint(.purple)

                        if downloadFeatureUnlocked {
                            if DownloadManager.shared.isDownloaded(song: displayedSong) {
                                Button(role: .destructive) {
                                    DownloadManager.shared.removeDownloaded(song: displayedSong)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            } else {
                                Button {
                                    downloadSong()
                                } label: {
                                    Label("下载", systemImage: "arrow.down.circle")
                                }
                                .tint(.blue)
                            }
                        }
                    }
            }
        }
        .onAppear {
            if overrideSong == nil, let refreshed = fallbackRefreshedSong(includeLocal: true) {
                overrideSong = refreshed
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .atmusicSongMetadataDidUpdate)) { note in
            if let matched = matchedSong(from: note) {
                overrideSong = matched
            } else if let refreshed = fallbackRefreshedSong(includeLocal: true) {
                overrideSong = refreshed
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .atmusicSynologyMetadataDidUpdate)) { note in
            if let matched = matchedSong(from: note) {
                overrideSong = matched
            } else if let refreshed = fallbackRefreshedSong(includeLocal: false) {
                overrideSong = refreshed
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .atmusicCoverDidUpdate)) { note in
            if let matched = matchedSong(from: note) {
                overrideSong = matched
            } else if let refreshed = fallbackRefreshedSong(includeLocal: true) {
                overrideSong = refreshed
            }
        }
        .onChange(of: song) { _ in
            overrideSong = nil
        }
    }
}
