import SwiftUI

struct QueueView: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage("atmusic.showSongVIPBadge") private var showSongVIPBadge = true
    @State private var editMode: EditMode = .inactive

    private struct QueueDisplayItem: Identifiable {
        let id: String
        let index: Int
        let song: Song
    }

    private var isEditing: Bool {
        editMode.isEditing
    }

    /// List 编辑模式不能用 offset 当稳定身份。
    /// 播放进度每 0.2 秒会触发 PlayerManager objectWillChange；如果行 id 是 offset，
    /// 编辑控件会在每次刷新时重新参与布局，看起来就像歌名持续抖动。
    /// 这里改成“歌曲 identityKey + 同曲出现序号”，普通队列移动时身份保持稳定。
    private var queueDisplayItems: [QueueDisplayItem] {
        var occurrences: [String: Int] = [:]
        return player.queue.enumerated().map { index, song in
            let key = song.identityKey
            let occurrence = occurrences[key, default: 0]
            occurrences[key] = occurrence + 1
            return QueueDisplayItem(
                id: "\(key)#\(occurrence)",
                index: index,
                song: song
            )
        }
    }

    var body: some View {
        let _ = theme.accent
        ATMusicNavigationStack {
            ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
                if player.queue.isEmpty {
                    EmptyStateView(icon: "music.note.list", text: "播放队列为空")
                } else {
                    List {
                        Section {
                            playbackModePicker
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        } header: {
                            Text("播放顺序")
                                .font(ATMusicFont.appFont(13, .semibold))
                                .foregroundStyle(Color.atmusicComment)
                        }

                        Section(String(format: NSLocalizedString("接下来 (%d 首)", comment: ""), player.queue.count)) {
                            ForEach(queueDisplayItems) { item in
                                row(item.song, index: item.index)
                                    .atmusicCompactSongListRow()
                            }
                            .onDelete { offsets in
                                let indices = offsets.map { $0 }
                                for index in indices.sorted(by: >) where player.queue.indices.contains(index) {
                                    player.removeFromQueue(at: index)
                                }
                            }
                            .onMove { offsets, destination in
                                player.moveQueue(from: offsets, to: destination)
                            }
                        }
                    }
                    .environment(\.editMode, $editMode)
                    .transaction { transaction in
                        if isEditing {
                            transaction.animation = nil
                        }
                    }
                    .atmusicScrollContentBackgroundHidden()
                    .listStyle(.plain)
                }
            }
            .navigationTitle("播放队列")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(isEditing ? "完成" : "编辑") {
                        ATMusicHaptics.select()
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            editMode = isEditing ? .inactive : .active
                        }
                    }
                    .font(ATMusicFont.appFont(14, .semibold))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Menu {
                            Button(role: .destructive) {
                                ATMusicHaptics.medium()
                                player.clearQueue()
                            } label: {
                                Label("清空队列", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 16))
                        }

                        Button("完成") {
                            dismiss()
                        }
                        .font(ATMusicFont.appFont(14, .semibold))
                        .foregroundStyle(Color.atmusicAmber)
                    }
                }
            }
        }
    }

    private var playbackModePicker: some View {
        HStack(spacing: 8) {
            ForEach(PlayMode.allCases) { mode in
                let selected = player.playMode == mode
                Button {
                    ATMusicHaptics.select()
                    player.setPlayMode(mode)
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: mode == .sequential ? "arrow.right" : mode.icon)
                            .font(.system(size: 15, weight: .semibold))
                        Text(mode.title)
                            .font(ATMusicFont.appFont(11, .medium))
                            .lineLimit(1)
                    }
                    .atmusicSelectionForeground(selected: selected, accent: .atmusicAmber)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background {
                        ATMusicSelectableSurface(
                            selected: selected,
                            shape: RoundedRectangle(cornerRadius: 14, style: .continuous),
                            accent: .atmusicAmber
                        )
                    }
                }
                .buttonStyle(GlassPressButtonStyle(scale: 0.97))
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func row(_ song: Song, index: Int) -> some View {
        let isCurrent = index == player.currentIndex
        HStack(spacing: 12) {
            CoverImage(url: song.coverURL, size: 46, cornerRadius: 10)

            VStack(alignment: .leading, spacing: 3) {
                Text(song.name)
                    .font(ATMusicFont.appFont(15, isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.atmusicAmber : Color.atmusicLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                Text(song.artists)
                    .font(ATMusicFont.appFont(12))
                    .foregroundStyle(Color.atmusicComment)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            if isCurrent {
                if isEditing {
                    Image(systemName: "waveform")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.atmusicAmber)
                        .frame(width: 18, height: 16)
                } else if player.isPlaying {
                    NowPlayingIndicator()
                } else {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.atmusicAmber)
                        .frame(width: 18, height: 16)
                }
            }

            if showSongVIPBadge, song.isVIP {
                SongVIPBadgeView()
            }
            SourceBadgeView(source: song.source, compact: true)
            Text(song.formattedDuration)
                .font(ATMusicFont.appFont(12, .regular, .monospaced))
                .foregroundStyle(Color.atmusicComment)
                .frame(minWidth: 42, alignment: .trailing)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 64)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.atmusicComment.opacity(0.18))
                .frame(height: 0.5)
                .padding(.leading, 58)
        }
        .transaction { transaction in
            if isEditing {
                transaction.animation = nil
            }
        }
        .onTapGesture {
            guard !isEditing else { return }
            if player.queue.indices.contains(index) {
                ATMusicHaptics.tap()
                player.playQueueIndex(index)
            }
        }
    }
}

private extension View {
    func atmusicCompactSongListRow() -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

