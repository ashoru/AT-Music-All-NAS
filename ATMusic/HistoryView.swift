import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isMultiSelecting = false
    @State private var selectedSongKeys: Set<String> = []
    @State private var dragStartIndex: Int? = nil
    @State private var initialSelectedKeysOnDrag: Set<String>? = nil
    @State private var dragTargetSelected = true
    @State private var lastDragIndex: Int? = nil
    @State private var showBatchAddToPlaylist = false

    private var selectedSongs: [Song] {
        player.history.filter { selectedSongKeys.contains($0.identityKey) }
    }

    private func toggleSelection(_ song: Song) {
        if selectedSongKeys.contains(song.identityKey) {
            selectedSongKeys.remove(song.identityKey)
        } else {
            selectedSongKeys.insert(song.identityKey)
        }
    }

    private func handleDragChange(startIndex: Int, deltaRows: Int) {
        let keys = player.history.map(\.identityKey)
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
    private func historySongRow(song: Song, index: Int) -> some View {
        SongCell(
            song: song,
            glassRow: false,
            playbackContext: player.history,
            playbackIndex: index,
            onTap: {
                player.play(songs: player.history, startAt: index)
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

    var body: some View {
        ATMusicNavigationStack {
            ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
                if player.history.isEmpty {
                    EmptyStateView(icon: "clock.arrow.circlepath", text: "暂无播放历史")
                } else if DeviceLayoutHelper.isIPadRegular(horizontalSizeClass) {
                    ScrollView {
                        LazyVGrid(columns: DeviceLayoutHelper.songListColumns(for: horizontalSizeClass, spacing: 16), spacing: 8) {
                            ForEach(Array(player.history.enumerated()), id: \.element.identityKey) { index, song in
                                historySongRow(song: song, index: index)
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
                            historySongRow(song: song, index: index)
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

                if isMultiSelecting && !selectedSongKeys.isEmpty {
                    VStack {
                        Spacer()
                        UniversalBatchActionBar(
                            selectedCount: selectedSongKeys.count,
                            totalCount: player.history.count,
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
                                BatchActionItem(id: "delete", title: "移除记录", systemImage: "trash", tint: Color.red) {
                                    let songs = selectedSongs
                                    player.removeHistory(songs: songs)
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
            .navigationTitle(isMultiSelecting ? (selectedSongKeys.isEmpty ? "选择歌曲" : "已选 \(selectedSongKeys.count) 首") : "最近播放")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if isMultiSelecting {
                        HStack(spacing: 12) {
                            Button(selectedSongKeys.count == player.history.count && !player.history.isEmpty ? "取消全选" : "全选") {
                                ATMusicHaptics.tap()
                                if selectedSongKeys.count == player.history.count {
                                    selectedSongKeys.removeAll()
                                } else {
                                    selectedSongKeys = Set(player.history.map(\.identityKey))
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
                        if !player.history.isEmpty {
                            Menu {
                                Button {
                                    ATMusicHaptics.select()
                                    isMultiSelecting = true
                                } label: {
                                    Label("多选歌曲", systemImage: "checklist")
                                }

                                Button {
                                    DownloadManager.shared.startBatchDownload(songs: player.history)
                                    ToastCenter.shared.show("已将 \(player.history.count) 首历史歌曲加入下载")
                                } label: {
                                    Label("下载全部历史", systemImage: "arrow.down.circle")
                                }

                                if SynologyAPI.shared.isLoggedIn {
                                    Button {
                                        DownloadManager.shared.startBatchUploadToNAS(songs: player.history)
                                        ToastCenter.shared.show("已将 \(player.history.count) 首历史歌曲加入归档")
                                    } label: {
                                        Label("全部归档至群晖 NAS", systemImage: "externaldrive.badge.plus")
                                    }
                                }

                                Divider()

                                Button(role: .destructive) {
                                    player.clearHistory()
                                    ToastCenter.shared.show("已清空播放历史")
                                } label: {
                                    Label("清空最近播放", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .accessibilityLabel("更多操作")
                        }
                    }
                }
            }
            .sheet(isPresented: $showBatchAddToPlaylist) {
                AddToPlaylistSheet(songs: selectedSongs)
                    .environmentObject(theme)
            }
        }
    }
}
