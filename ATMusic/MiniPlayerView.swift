import SwiftUI

struct MiniPlayerView: View {
    enum Presentation {
        case dock
        case accessory

        var showsCardSurface: Bool { self == .dock }
    }

    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var clock: PlaybackClock
    @Binding var showPlayer: Bool
    var presentation: Presentation = .dock
    var transitionNamespace: Namespace.ID?
    /// 底部导航联动时使用的紧凑模式：隐藏上一首/下一首，让播放器气泡和分页栏保持一行。
    var compact = false
    @State private var miniLyrics: [LyricLine] = []
    /// 全局默认偏移；逐曲校准值优先（见 activeLyricOffset）
    @AppStorage("atmusic.lyricOffset") private var lyricOffset = 0.0
    @ObservedObject private var lyricOffsets = LyricOffsetStore.shared

    private var activeLyricOffset: Double {
        _ = lyricOffsets.revision
        return lyricOffsets.offset(for: player.currentSong?.identityKey)
    }
    @AppStorage("atmusic.uiStyle") private var uiStyleRaw = ATMusicUIStyle.liquid.rawValue
    @AppStorage("atmusic.showSongVIPBadge") private var showSongVIPBadge = true

    private var coverSize: CGFloat { compact ? 30 : 36 }
    private var controlSize: CGFloat { compact ? 30 : 32 }
    private var containerRadius: CGFloat { 18 }
    private var verticalPadding: CGFloat { 4 }

    /// 二分查找当前播放到的歌词行（歌词按时间升序）
    private var currentLyricLine: LyricLine? {
        guard !miniLyrics.isEmpty else { return nil }
        var low = 0
        var high = miniLyrics.count - 1
        var answer: LyricLine?
        while low <= high {
            let mid = (low + high) / 2
            if miniLyrics[mid].time <= LyricTiming.effectiveProgress(clock.progress, userOffset: activeLyricOffset) {
                answer = miniLyrics[mid]
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return answer
    }

    var body: some View {
        let _ = theme.accent
        Button {
            ATMusicHaptics.tap()
            showPlayer = true
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(theme.accent.highlight.opacity(0.32))
                        .frame(width: 42, height: 42)
                        .blur(radius: 9)
                    CoverImage(url: player.currentSong?.coverURL, size: coverSize, cornerRadius: 7)
                }
                .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(player.currentSong?.name ?? "")
                            .font(ATMusicFont.appFont(12, .semibold))
                            .foregroundStyle(Color.atmusicLabel)
                            .lineLimit(1)
                        if showSongVIPBadge, player.currentSong?.isVIP == true {
                            SongVIPBadgeView()
                        }
                        if let source = player.currentSong?.source {
                            SourceBadgeView(source: source, compact: true)
                        }
                    }
                    Text(currentLyricLine?.text ?? player.currentSong?.artists ?? "")
                        .font(ATMusicFont.appFont(10))
                        .foregroundStyle(Color.atmusicComment)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .modifier(ATMusicContentFade())
                        .animation(.default, value: currentLyricLine?.text)
                }
                Spacer(minLength: 8)
                if !compact {
                    Button {
                        ATMusicHaptics.tap()
                        player.previous()
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.atmusicLabel)
                            .frame(width: controlSize, height: controlSize)
                            .contentShape(Circle())
                    }
                    .buttonStyle(GlassPressButtonStyle())
                }
                Button {
                    ATMusicHaptics.tap()
                    player.togglePlayPause()
                } label: {
                    PlayPauseMorphIcon(isPlaying: player.isPlaying, size: 16)
                        .foregroundStyle(Color.atmusicLabel)
                        .frame(width: controlSize, height: controlSize)
                        .contentShape(Circle())
                }
                .buttonStyle(GlassPressButtonStyle())
                if !compact {
                    Button {
                        ATMusicHaptics.tap()
                        player.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.atmusicLabel)
                            .frame(width: controlSize, height: controlSize)
                            .contentShape(Circle())
                    }
                    .buttonStyle(GlassPressButtonStyle())
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .padding(.vertical, verticalPadding)
            .background {
                if presentation.showsCardSurface {
                    // 普通底部浮层：保留卡片质感与阴影。
                    ATMusicGlass(
                        shape: RoundedRectangle(cornerRadius: containerRadius, style: .continuous),
                        forceLiquid: false
                    )
                    .overlay {
                        LinearGradient(
                            colors: [.white.opacity(0.25), .clear, .white.opacity(0.05)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: containerRadius, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [.white.opacity(0.45), .white.opacity(0.08)],
                                    startPoint: .top, endPoint: .bottom
                                ),
                                lineWidth: 0.8
                            )
                    }
                } else {
                    // 进入底栏 accessory 时不再叠一层卡片，交给系统/底栏容器去承载。
                    RoundedRectangle(cornerRadius: containerRadius, style: .continuous)
                        .fill(.clear)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: containerRadius, style: .continuous))
            .shadow(color: presentation.showsCardSurface ? .black.opacity(0.16) : .clear, radius: 12, y: 6)
        }
        .buttonStyle(GlassPressButtonStyle(scale: 0.97))
        .transitionSource(in: transitionNamespace)
        .padding(.horizontal, presentation.showsCardSurface ? 12 : 0)
        .task(id: player.currentSong?.identityKey) {
            await loadMiniLyrics()
        }
    }

    private func loadMiniLyrics() async {
        miniLyrics = []
        guard let song = player.currentSong else { return }
        let identity = song.identityKey
        if player.currentLyricsSongIdentity == identity && !player.currentLyrics.isEmpty {
            miniLyrics = player.currentLyrics
            return
        }
        let parsed = await SongLyricsLoader.loadLyrics(for: song)
        guard player.currentSong?.identityKey == identity else { return }
        miniLyrics = parsed
        player.updateCurrentLyrics(parsed, for: identity)
    }
}

enum ATMusicNowPlayingTransitionID {
    static let surface = "atmusic-now-playing-surface"
}

private struct ATMusicTransitionSourceModifier: ViewModifier {
    let namespace: Namespace.ID?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let namespace, #available(iOS 18.0, *) {
            content.matchedTransitionSource(
                id: ATMusicNowPlayingTransitionID.surface,
                in: namespace
            )
        } else {
            content
        }
    }
}

private extension View {
    @ViewBuilder
    func transitionSource(in namespace: Namespace.ID?) -> some View {
        modifier(ATMusicTransitionSourceModifier(namespace: namespace))
    }
}
