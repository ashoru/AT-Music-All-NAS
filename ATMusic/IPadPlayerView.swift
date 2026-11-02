import SwiftUI
import MediaPlayer
import AVKit

/// iPad 专属 Apple Music 官方级侧边分栏播放器
/// 宽屏（>= 750pt）：左侧大封面中控台 + 右侧动态滚动歌词/待播清单双栏并排；
/// 半分屏/窄屏（< 750pt）：自适应收缩为全尺寸单栏分段式呈现，兼容所有 iPadOS 分屏状态；
/// 完整支持软件 4 套 UI 调节（liquid、clear、compact、nativeClean）。
struct IPadPlayerView: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var clock: PlaybackClock
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var favorites: FavoritesStore
    @ObservedObject private var localLibrary = LocalLibraryStore.shared
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("atmusic.uiStyle") private var uiStyleRaw = ATMusicUIStyle.liquid.rawValue

    let song: Song?
    let lyrics: [LyricLine]
    let onFavorite: () -> Void
    let onQueue: () -> Void
    let onComments: () -> Void
    let onSleepTimer: () -> Void
    let onAddToLocalPlaylist: () -> Void
    let onDownload: () -> Void
    let onPlayerSettings: () -> Void
    let onSearchLyrics: () -> Void
    let onLyricsSync: () -> Void
    let onDismiss: () -> Void

    @ObservedObject private var lyricOffsets = LyricOffsetStore.shared

    /// 逐曲歌词偏移优先，未校准则回落到布局编辑器里的全局默认值。
    private var activeLyricOffset: Double {
        _ = lyricOffsets.revision
        return lyricOffsets.offset(for: song?.identityKey)
    }

    @State private var rightPaneMode: RightPaneMode = .lyrics
    @State private var narrowSegment: Int = 0 // 0: 封面控制, 1: 歌词, 2: 待播清单
    @State private var isDraggingScrubber = false
    @State private var scrubProgress: Double = 0
    @State private var autoScrollEnabled = true
    /// 当前高亮歌词行索引（事件驱动缓存：只在换行时更新，避免每行重复判断）
    @State private var activeLyricLineIndex: Int? = nil
    @State private var pickedArtistName = ""
    @State private var selectedAlbum: Album?
    @State private var showArtistHome = false
    @State private var showSignalPath = false

    private var uiStyle: ATMusicUIStyle {
        uiStyleRaw == "outline" ? .clear : (ATMusicUIStyle(rawValue: uiStyleRaw) ?? .liquid)
    }

    private var isNativeClean: Bool { uiStyle == .nativeClean }
    private var isCompact: Bool { uiStyle == .compact }

    enum RightPaneMode: String, CaseIterable, Identifiable {
        case lyrics = "实时歌词"
        case queue = "待播清单"

        public var id: String { rawValue }
        public var icon: String {
            switch self {
            case .lyrics: return "quote.bubble.fill"
            case .queue: return "list.bullet"
            }
        }
    }

    init(
        song: Song?,
        lyrics: [LyricLine],
        onFavorite: @escaping () -> Void,
        onQueue: @escaping () -> Void,
        onComments: @escaping () -> Void,
        onSleepTimer: @escaping () -> Void,
        onAddToLocalPlaylist: @escaping () -> Void,
        onDownload: @escaping () -> Void,
        onPlayerSettings: @escaping () -> Void,
        onSearchLyrics: @escaping () -> Void,
        onLyricsSync: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.song = song
        self.lyrics = lyrics
        self.onFavorite = onFavorite
        self.onQueue = onQueue
        self.onComments = onComments
        self.onSleepTimer = onSleepTimer
        self.onAddToLocalPlaylist = onAddToLocalPlaylist
        self.onDownload = onDownload
        self.onPlayerSettings = onPlayerSettings
        self.onSearchLyrics = onSearchLyrics
        self.onLyricsSync = onLyricsSync
        self.onDismiss = onDismiss
    }

    var body: some View {
        GeometryReader { proxy in
            let isWide = proxy.size.width >= 750

            ZStack {
                // 流体背景（Apple Music 风格动态封面全屏渐变）
                CoverBlurBackground(url: song?.coverURL, scheme: colorScheme)
                    .overlay(Color.black.opacity(colorScheme == .dark ? 0.46 : 0.22))
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    topNavigationBar(isWide: isWide)
                        .padding(.horizontal, isCompact ? 18 : 28)
                        .padding(.top, 14)
                        .padding(.bottom, 8)

                    if isWide {
                        // 宽屏模式：Apple Music 官方左右双栏
                        HStack(spacing: isCompact ? 24 : 36) {
                            leftPlaybackColumn(containerWidth: proxy.size.width)
                                .frame(width: min(max(proxy.size.width * 0.43, 360), 520))

                            rightContentColumn
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .padding(.horizontal, isCompact ? 20 : 32)
                        .padding(.bottom, 24)
                    } else {
                        // 1/2 半分屏 / 窄屏分屏：自适应单栏
                        narrowLayoutView(width: proxy.size.width)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 16)
                    }
                }
            }
        }
        .sheet(isPresented: $showArtistHome) {
            if !pickedArtistName.isEmpty {
                AllSourcesArtistHomeSheet(
                    artistName: pickedArtistName,
                    initialSongs: song.map { [$0] } ?? []
                )
                .environmentObject(player)
                .environmentObject(theme)
            }
        }
        .sheet(item: $selectedAlbum) { album in
            if album.source == .synology {
                ATMusicNavigationStack {
                    SynologyAlbumView(
                        albumName: album.name,
                        artistName: album.artistName,
                        coverURL: album.coverURL
                    )
                }
                .environmentObject(player)
                .environmentObject(theme)
            } else {
                ATMusicNavigationStack {
                    AlbumDetailView(album: album, isModal: true)
                }
                .environmentObject(player)
                .environmentObject(theme)
            }
        }
        .sheet(isPresented: $showSignalPath) {
            AudioSignalPathSheet(song: song)
                .presentationDetents([.large])
                .environmentObject(player)
                .environmentObject(theme)
        }
    }

    // MARK: - 顶栏

    private func topNavigationBar(isWide: Bool) -> some View {
        HStack(spacing: 14) {
            Button(action: onDismiss) {
                Image(systemName: "chevron.down.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)

            if let song {
                HStack(spacing: 6) {
                    Text(song.source.displayName)
                        .font(ATMusicFont.appFont(11, .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.white.opacity(0.2)))
                        .foregroundStyle(.white.opacity(0.9))

                    if song.isVIP {
                        Text("VIP")
                            .font(ATMusicFont.appFont(10, .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.atmusicAmber))
                            .foregroundStyle(.black)
                    }

                    AudioQualityCapsule(song: song)
                }
            }

            Spacer()

            // 隔空播放
            AirPlayRoutePicker(tintColor: .white.withAlphaComponent(0.85))
                .frame(width: 32, height: 32)

            // 定时关闭
            Button(action: onSleepTimer) {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(player.sleepTimerRemaining > 0 ? Color.atmusicAmber : .white.opacity(0.85))
            }
            .buttonStyle(.plain)

            // 收藏状态
            Button(action: onFavorite) {
                Image(systemName: isCurrentFavorited ? "heart.fill" : "heart")
                    .font(.system(size: 19))
                    .foregroundStyle(isCurrentFavorited ? .red : .white.opacity(0.85))
            }
            .buttonStyle(.plain)

            // 更多操作菜单
            Menu {
                Button(action: onAddToLocalPlaylist) {
                    Label("添加到自建歌单", systemImage: "text.badge.plus")
                }
                Button(action: onDownload) {
                    Label("下载本曲", systemImage: "arrow.down.circle")
                }
                Button(action: onSearchLyrics) {
                    Label("手动检索歌词", systemImage: "text.magnifyingglass")
                }
                Button(action: onLyricsSync) {
                    Label("歌词同步校准", systemImage: "metronome")
                }
                Button(action: onComments) {
                    Label("查看歌曲评论", systemImage: "text.bubble")
                }
                Button {
                    showSignalPath = true
                } label: {
                    Label("音频信号通路", systemImage: "waveform.path.ecg")
                }
                Divider()
                Button(action: onPlayerSettings) {
                    Label("播放器视觉设置", systemImage: "slider.horizontal.3")
                }
            } label: {
                Image(systemName: "ellipsis.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    private var isCurrentFavorited: Bool {
        guard let song else { return false }
        return favorites.isSongLiked(song)
    }

    // MARK: - 左栏（大封面与核心中控台）

    private func leftPlaybackColumn(containerWidth: CGFloat) -> some View {
        VStack(spacing: isCompact ? 14 : 20) {
            Spacer(minLength: 0)

            // 大尺寸专辑封面（带播放呼吸动效）
            CoverImage(url: song?.coverURL, size: 360, cornerRadius: 22)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.50 : 0.28), radius: 24, x: 0, y: 12)
                .scaleEffect(player.isPlaying ? 1.0 : 0.94)
                .animation(.spring(response: 0.45, dampingFraction: 0.75), value: player.isPlaying)
                .padding(.horizontal, isCompact ? 6 : 14)

            // 歌曲信息排版
            VStack(alignment: .leading, spacing: 6) {
                // 歌名超长时横向滚动（与 iPhone 播放页一致）；徽章本就在顶栏与信息行，不与歌名抢位
                // iPad 右侧歌词同屏滚动，歌名滚动刻意放慢、延迟起滚，降低双滚动的视觉干扰
                MarqueeText(
                    text: song?.title ?? "未在播放",
                    font: ATMusicFont.appFont(isCompact ? 20 : 25, .bold),
                    height: isCompact ? 25 : 31,
                    isPaused: isDraggingScrubber,
                    speed: 26,
                    startDelay: 2.2
                )

                SongSubtitleMenu(
                    song: song,
                    font: ATMusicFont.appFont(isCompact ? 15 : 17, .medium),
                    color: .white.opacity(0.78),
                    alignment: .leading,
                    onSelectArtist: { artist in
                        pickedArtistName = artist
                        showArtistHome = true
                    },
                    onSelectAlbum: { album in
                        selectedAlbum = album
                    }
                )

                HStack(spacing: 8) {
                    if let source = song?.source {
                        SourceBadgeView(source: source, compact: true)
                    }
                    AudioQualityCapsule(song: song)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)

            // 进度条
            playbackScrubber
                .padding(.horizontal, 14)

            // 核心播控按键行
            transportControlsRow

            // 硬件音量控制条
            volumeControlRow
                .padding(.horizontal, 14)

            Spacer(minLength: 0)
        }
    }

    // MARK: - 进度条组件

    private var playbackScrubber: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let current = isDraggingScrubber ? scrubProgress * max(clock.duration, 1) : clock.currentTime
                let total = max(clock.duration, 1)
                let pct = min(max(current / total, 0), 1)

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.22))
                        .frame(height: 6)

                    Capsule()
                        .fill(Color.atmusicAmber)
                        .frame(width: geo.size.width * CGFloat(pct), height: 6)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { val in
                            isDraggingScrubber = true
                            let progress = min(max(val.location.x / geo.size.width, 0), 1)
                            scrubProgress = Double(progress)
                        }
                        .onEnded { val in
                            let progress = min(max(val.location.x / geo.size.width, 0), 1)
                            let target = Double(progress) * clock.duration
                            player.seek(to: target)
                            isDraggingScrubber = false
                        }
                )
            }
            .frame(height: 14)

            HStack {
                let current = isDraggingScrubber ? scrubProgress * clock.duration : clock.currentTime
                Text(formatTime(current))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))

                Spacer()

                Text("-\(formatTime(max(clock.duration - current, 0)))")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
    }

    // MARK: - 播放控制按键行 (Apple Music 标志性大圆形中控)

    private var transportControlsRow: some View {
        HStack(spacing: isCompact ? 22 : 32) {
            // 随机播放切换
            Button {
                ATMusicHaptics.tap()
                player.toggleShuffle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(player.isShuffled ? Color.atmusicAmber : .white.opacity(0.65))
            }
            .buttonStyle(.plain)

            // 上一曲
            Button {
                ATMusicHaptics.tap()
                player.previousTrack()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            // 播放 / 暂停 大按钮（Apple 经典醒目白色高反差圆底）
            Button {
                ATMusicHaptics.medium()
                player.togglePlayPause()
            } label: {
                ZStack {
                    Circle()
                        .fill(.white)
                        .frame(width: 66, height: 66)
                        .shadow(color: .black.opacity(0.30), radius: 10, y: 4)

                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.black)
                        .offset(x: player.isPlaying ? 0 : 2)
                }
            }
            .buttonStyle(.plain)

            // 下一曲
            Button {
                ATMusicHaptics.tap()
                player.nextTrack()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            // 循环模式切换
            Button {
                ATMusicHaptics.tap()
                player.toggleLoopMode()
            } label: {
                Image(systemName: loopModeIcon)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(player.loopMode != .off ? Color.atmusicAmber : .white.opacity(0.65))
            }
            .buttonStyle(.plain)
        }
    }

    private var loopModeIcon: String {
        switch player.loopMode {
        case .single: return "repeat.1"
        case .all: return "repeat"
        case .off: return "repeat"
        }
    }

    // MARK: - 快捷音量控制条

    private var volumeControlRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.6))

            Slider(value: Binding(
                get: { player.volume },
                set: { player.volume = $0 }
            ), in: 0...1)
            .tint(Color.atmusicAmber)

            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    // MARK: - 右栏（实时歌词 / 待播列表切换）

    private var rightContentColumn: some View {
        VStack(spacing: 16) {
            // 顶部切换分段器
            HStack(spacing: 12) {
                ForEach(RightPaneMode.allCases) { mode in
                    Button {
                        ATMusicHaptics.select()
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                            rightPaneMode = mode
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: mode.icon)
                            Text(mode.rawValue)
                        }
                        .font(ATMusicFont.appFont(14, .semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background {
                            if rightPaneMode == mode {
                                Capsule().fill(.white.opacity(0.24))
                            } else {
                                Capsule().fill(.clear)
                            }
                        }
                        .foregroundStyle(rightPaneMode == mode ? .white : .white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                if rightPaneMode == .lyrics {
                    Button {
                        autoScrollEnabled.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: autoScrollEnabled ? "arrow.up.and.down.circle.fill" : "circle")
                            Text(autoScrollEnabled ? "自动居中" : "自由滚动")
                        }
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(.white.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)

            // 内容展示
            ZStack {
                if rightPaneMode == .lyrics {
                    liveLyricsScrollView
                } else {
                    inlineQueueListView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                rightPaneBackground
            }
        }
    }

    @ViewBuilder
    private var rightPaneBackground: some View {
        switch uiStyle {
        case .liquid:
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.white.opacity(0.06))
                .background(.ultraThinMaterial.opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                }
        case .clear:
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        case .compact:
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.05))
        case .nativeClean:
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(colorScheme == .dark ? 0.35 : 0.15))
        }
    }

    // MARK: - 1/2 半分屏自适应单栏

    @ViewBuilder
    private func narrowLayoutView(width: CGFloat) -> some View {
        VStack(spacing: 12) {
            Picker("", selection: $narrowSegment) {
                Text("播控").tag(0)
                Text("歌词").tag(1)
                Text("待播").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 10)

            TabView(selection: $narrowSegment) {
                ScrollView {
                    leftPlaybackColumn(containerWidth: width)
                        .padding(.top, 10)
                }
                .tag(0)

                liveLyricsScrollView
                    .background(rightPaneBackground)
                    .tag(1)

                inlineQueueListView
                    .background(rightPaneBackground)
                    .tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
    }

    // MARK: - 实时同步滚动歌词

    private var liveLyricsScrollView: some View {
        ScrollViewReader { scrollProxy in
            ScrollView(.vertical, showsIndicators: false) {
                if lyrics.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "music.note")
                            .font(.system(size: 40))
                            .foregroundStyle(.white.opacity(0.4))
                        Text("纯音乐，请欣赏")
                            .font(ATMusicFont.appFont(16))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity, minHeight: 380)
                } else {
                    LazyVStack(alignment: .leading, spacing: isCompact ? 16 : 22) {
                        Color.clear.frame(height: 100)

                        ForEach(Array(lyrics.enumerated()), id: \.element.id) { item in
                            let index = item.offset
                            let line = item.element
                            let isCurrent = index == activeLyricLineIndex

                            VStack(alignment: .leading, spacing: 6) {
                                Text(line.text)
                                    .font(ATMusicFont.appFont(isCurrent ? (isCompact ? 24 : 28) : (isCompact ? 18 : 20), isCurrent ? .bold : .medium))
                                    .foregroundStyle(isCurrent ? .white : .white.opacity(0.40))
                                    .blur(radius: isCurrent ? 0 : 0.3)
                                    .scaleEffect(isCurrent ? 1.02 : 1.0, anchor: .leading)
                                    .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isCurrent)

                                if let translation = line.translation, !translation.isEmpty {
                                    Text(translation)
                                        .font(ATMusicFont.appFont(isCurrent ? 15 : 13))
                                        .foregroundStyle(isCurrent ? Color.atmusicAmber.opacity(0.9) : .white.opacity(0.28))
                                }
                            }
                            .id(line.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                player.seek(to: line.time)
                            }
                        }

                        Color.clear.frame(height: 140)
                    }
                    .padding(.horizontal, isCompact ? 20 : 32)
                }
            }
            .onAppear {
                activeLyricLineIndex = findCurrentLineIndex(at: max(0, clock.currentTime + activeLyricOffset))
            }
            .onChange(of: clock.currentTime) { currentTime in
                guard !lyrics.isEmpty else { return }
                let newIndex = findCurrentLineIndex(at: max(0, currentTime + activeLyricOffset))
                guard newIndex != activeLyricLineIndex else { return }
                activeLyricLineIndex = newIndex
                guard autoScrollEnabled, let currentLineID = newIndex.map({ lyrics[$0].id }) else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    scrollProxy.scrollTo(currentLineID, anchor: .center)
                }
            }
        }
    }

    /// 二分查找当前播放时间对应的歌词行索引（歌词按时间戳升序排列）。
    private func findCurrentLineIndex(at time: Double) -> Int? {
        guard !lyrics.isEmpty else { return nil }
        var low = 0
        var high = lyrics.count - 1
        var answer: Int?
        while low <= high {
            let mid = (low + high) / 2
            if lyrics[mid].time <= time {
                answer = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return answer ?? 0
    }

    // MARK: - 实时待播列表（Queue）

    /// 待播行身份：同一首歌在队列里出现多次时用出现序号区分，避免 ForEach 身份重复。
    private struct InlineQueueEntry: Identifiable {
        let id: String
        let index: Int
        let song: Song
    }

    private func inlineQueueEntries(_ songs: [Song]) -> [InlineQueueEntry] {
        var occurrences: [String: Int] = [:]
        return songs.enumerated().map { index, song in
            let key = song.identityKey
            let occurrence = occurrences[key, default: 0]
            occurrences[key] = occurrence + 1
            return InlineQueueEntry(id: "\(key)#\(occurrence)", index: index, song: song)
        }
    }

    private var inlineQueueListView: some View {
        let queuedSongs = player.queue
        return ScrollView(.vertical, showsIndicators: false) {
            // 必须是 LazyVStack：普通 VStack 会一次性实例化全部待播行（每行带一个
            // 封面加载器），队列上千首时光建行就卡死（手机端 QueueView 用 List 无此问题）。
            LazyVStack(spacing: 8) {
                if queuedSongs.isEmpty {
                    Text("当前待播列表为空")
                        .font(ATMusicFont.appFont(15))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.top, 100)
                } else {
                    HStack {
                        Text("即将播放 · \(queuedSongs.count) 首")
                            .font(ATMusicFont.appFont(13, .semibold))
                            .foregroundStyle(.white.opacity(0.6))
                        Spacer()
                        Button("清空列表") {
                            player.clearQueue()
                        }
                        .font(ATMusicFont.appFont(13))
                        .foregroundStyle(Color.atmusicAmber)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .padding(.bottom, 8)

                    ForEach(inlineQueueEntries(queuedSongs)) { entry in
                        let item = entry.song
                        let index = entry.index
                        let isPlayingThis = (item.identityKey == player.currentSong?.identityKey)

                        HStack(spacing: 14) {
                            CoverImage(url: item.coverURL, size: 44, cornerRadius: 8)
                                .frame(width: 44, height: 44)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title)
                                    .font(ATMusicFont.appFont(15, isPlayingThis ? .bold : .medium))
                                    .foregroundStyle(isPlayingThis ? Color.atmusicAmber : .white)
                                    .lineLimit(1)

                                Text(item.artist)
                                    .font(ATMusicFont.appFont(12))
                                    .foregroundStyle(.white.opacity(0.6))
                                    .lineLimit(1)
                            }

                            Spacer()

                            if isPlayingThis {
                                Image(systemName: "waveform")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(Color.atmusicAmber)
                                    .modifier(ATMusicWaveformEffect())
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background {
                            if isPlayingThis {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(.white.opacity(0.12))
                            } else {
                                Color.clear
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            player.play(songs: queuedSongs, startAt: index)
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite && seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}
