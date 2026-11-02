import SwiftUI
import MediaPlayer

private struct ReferenceLyricCenterKey: PreferenceKey {
    static var defaultValue: [UUID: CGFloat] = [:]

    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private struct ReferencePlaybackPresentationMetrics {
    static let headerTopSpacing: CGFloat = 20
}

struct ReferencePlaybackView: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var clock: PlaybackClock
    @EnvironmentObject private var favorites: FavoritesStore
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var localLibrary = LocalLibraryStore.shared
    @ObservedObject private var appleLayout = AppleMusicLayoutStore.shared

    let song: Song?
    let lyrics: [LyricLine]
    @Binding var showLyrics: Bool
    let onFavorite: () -> Void
    let onQueue: () -> Void
    let onComments: () -> Void
    let onSleepTimer: () -> Void
    let onAddToLocalPlaylist: () -> Void
    let onDownload: () -> Void
    let onPlayerSettings: () -> Void
    let onSearchLyrics: () -> Void
    let onSongInfo: () -> Void
    let onLyricsSync: () -> Void

    /// 全局默认偏移（布局编辑器里的那根滑杆）；逐曲校准值优先，见 activeLyricOffset。
    @AppStorage("atmusic.lyricOffset") private var lyricOffset = 0.0
    @ObservedObject private var lyricOffsets = LyricOffsetStore.shared

    private var activeLyricOffset: Double {
        _ = lyricOffsets.revision
        return lyricOffsets.offset(for: song?.identityKey)
    }
    @AppStorage("atmusic.lyricFontSize") private var lyricFontSize = 17
    @AppStorage("atmusic.lyricSpacing") private var lyricLineSpacing = 24
    @AppStorage("atmusic.appleMusic.showVolume") private var showVolumeControl = false
    @AppStorage("atmusic.appleMusic.primaryHex") private var primaryHex = ""
    @AppStorage("atmusic.appleMusic.secondaryHex") private var secondaryHex = ""
    @AppStorage("atmusic.appleMusic.accentHex") private var accentHex = ""
    @AppStorage("atmusic.appleMusic.volumeHex") private var volumeHex = ""
    @AppStorage("atmusic.appleMusic.syncWallpaper") private var syncWallpaper = false
    @AppStorage("atmusic.appleMusic.wallpaperBlur") private var wallpaperBlur = 14.0
    @AppStorage("atmusic.showSongVIPBadge") private var showSongVIPBadge = true
    @AppStorage("atmusic.appleMusic.showLyricPreview") private var showLyricPreview = true
    @AppStorage("atmusic.lyricTranslation") private var lyricTranslation = true
    @AppStorage("atmusic.lyricGradMode") private var lyricGradMode = 0
    @AppStorage("atmusic.lyricColor") private var lyricColorRaw = "accent"
    @AppStorage("atmusic.lyricDimColor") private var lyricDimColorRaw = "dim"
    @AppStorage("atmusic.lyricGlow") private var lyricGlowLevel = 1
    @AppStorage("atmusic.lyricGlowColorRaw") private var lyricGlowColorRaw = ""
    @AppStorage("atmusic.lyricBlurAmount") private var lyricBlurAmount = 1.1
    @AppStorage("atmusic.lyricTilt") private var lyricTilt = 0
    @AppStorage("atmusic.lyricAlignRaw") private var lyricAlignRaw = "left"
    private let downloadFeatureUnlocked = true
    @State private var lyricCenters: [UUID: CGFloat] = [:]
    @State private var focusedLyricID: UUID?
    @State private var lyricScrollTarget: UUID?
    @State private var lyricsViewportHeight: CGFloat = 0
    @State private var isDraggingLyrics = false
    @State private var showArtistHome = false
    @State private var pickedArtistName: String = ""
    @State private var selectedAlbum: Album?
    @State private var showSignalPath = false
    @State private var resumeTask: Task<Void, Never>?
    @State private var coverDominantColor: RGBColor?

    private func layoutEntry(_ part: AppleMusicLayoutPart) -> PlayerLayoutEntry {
        appleLayout.entry(for: part)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                playerBackground

                VStack(spacing: 0) {
                    // 顶部小横条已按需求隐藏，仅保留顶部留白。
                    Color.clear.frame(height: ReferencePlaybackPresentationMetrics.headerTopSpacing)

                    ZStack {
                        if showLyrics {
                            lyricsPage
                                .transition(.opacity)
                        } else {
                            coverPage(size: geometry.size)
                                .transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .animation(.default, value: showLyrics)

                    playbackControls(bottomInset: geometry.safeAreaInsets.bottom)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .onDisappear { resumeTask?.cancel() }
        .sheet(isPresented: $showArtistHome) {
            if !pickedArtistName.isEmpty {
                AllSourcesArtistHomeSheet(artistName: pickedArtistName, initialSongs: song.map { [$0] } ?? [])
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
                .presentationDetents([.medium, .large])
                .environmentObject(player)
                .environmentObject(theme)
        }
    }

    @ViewBuilder
    private var playerBackground: some View {
        ZStack {
            // Full-screen covers need an opaque base so the home page cannot show through
            // while the cover image is loading or when a presentation uses a clear surface.
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            if syncWallpaper, let image = theme.customBackgroundImage(for: colorScheme) {
                WallpaperImage(image: image)
                    .blur(radius: CGFloat(wallpaperBlur))
                    .scaleEffect(wallpaperBlur > 0 ? 1.08 : 1)
                    .overlay(Color.black.opacity(colorScheme == .dark ? 0.44 : 0.16))
                    .ignoresSafeArea()
            } else if syncWallpaper, let color = theme.customBackground(for: colorScheme) {
                LinearGradient(
                    colors: [color.opacity(0.92), color.opacity(0.58), colorScheme == .dark ? .black.opacity(0.88) : .white.opacity(0.70)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .blur(radius: CGFloat(wallpaperBlur * 0.35))
                .ignoresSafeArea()
            } else {
                CoverBlurBackground(url: song?.coverURL, scheme: colorScheme)
                    .overlay(Color.black.opacity(colorScheme == .dark ? 0.48 : 0.14))
                    .ignoresSafeArea()
            }
        }
        .task(id: song?.identityKey) {
            await extractCoverPalette()
        }
    }

    private func extractCoverPalette() async {
        guard let url = song?.coverURL else {
            coverDominantColor = nil
            return
        }
        let resolved = ManagedAudioPath.resolveFileURL(url) ?? url
        do {
            let image: UIImage?
            if resolved.isFileURL {
                image = UIImage(contentsOfFile: resolved.path)
            } else {
                var req = URLRequest(url: resolved)
                req.timeoutInterval = 12
                req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
                let (data, _) = try await URLSession.shared.data(for: req)
                image = UIImage(data: data)
            }
            guard let image else { return }
            let dominant = PaletteExtractor.dominantColor(in: image)
            withAnimation {
                coverDominantColor = dominant
            }
        } catch {}
    }

    private func coverPage(size: CGSize) -> some View {
        let contentWidth = max(size.width - 64, 0)
        let artworkSize = min(contentWidth, min(size.height * 0.50, 390))

        return VStack(spacing: 0) {
            Spacer(minLength: 8)

            CoverImage(
                url: song?.coverURL,
                size: artworkSize,
                cornerRadius: 18,
                emptyHint: player.isBuffering ? "等待开始播放…" : nil
            )
            .frame(width: artworkSize, height: artworkSize)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.46), radius: 36, y: 18)
            .scaleEffect(player.isPlaying ? 1 : 0.965)
            .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.cover)))
            .animation(.default, value: player.isPlaying)

            if showLyricPreview {
            VStack(spacing: 5) {
                Text(song?.name ?? "未在播放")
                    .font(ATMusicFont.appFont(22, .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                HStack(spacing: 7) {
                    if showSongVIPBadge, song?.isVIP == true {
                        SongVIPBadgeView()
                    }
                    if let source = song?.source {
                        SourceBadgeView(source: source, compact: true)
                    }
                    AudioQualityCapsule(song: song)
                }
                .frame(maxWidth: .infinity)
                subtitleMenu(font: ATMusicFont.appFont(13.5, .medium), color: .white.opacity(0.68))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 420)
            .padding(.top, 22)
            .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.title)))

            MiniLyricsPreview(lines: previewLyrics, primary: lyricHighlightColor, secondary: lyricDimmedColor) {
                ATMusicHaptics.tap()
                showLyrics = true
            }
            .padding(.top, 18)
            .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.previewLyric)))
            } else {
                compactTrackHeader
                    .padding(.top, 22)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
    }

    private var compactTrackHeader: some View {
        VStack(spacing: 4) {
            Text(song?.name ?? "未在播放")
                .font(ATMusicFont.appFont(16, .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
            HStack(spacing: 7) {
                if let source = song?.source {
                    SourceBadgeView(source: source, compact: true)
                }
                AudioQualityCapsule(song: song)
            }
            subtitleMenu(font: ATMusicFont.appFont(12, .medium), color: .white.opacity(0.68))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 420)
    }

    private var lyricsPage: some View {
        VStack(spacing: 0) {
            lyricsHeader
                .padding(.horizontal, 24)
                .padding(.bottom, 10)

            if lyrics.isEmpty {
                emptyLyricsView
            } else if #available(iOS 18.0, *) {
                GeometryReader { viewport in
                    let edgeSpacer = max(72, viewport.size.height * 0.50 - lyricRowHeight * 0.50)
                    let stackAlignment: HorizontalAlignment = (lyricAlignRaw == "center") ? .center : .leading
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: stackAlignment, spacing: CGFloat(lyricLineSpacing)) {
                            Color.clear.frame(height: edgeSpacer)
                            ForEach(lyrics) { line in
                                lyricLine(line, isFocused: line.id == currentVisualLyricID)
                                    .id(line.id)
                                    .scrollTransition(.interactive, axis: .vertical) { content, phase in
                                        content
                                            .scaleEffect(phase.isIdentity ? 1.0 : 0.94, anchor: stackAlignment == .center ? .center : .leading)
                                            .opacity(phase.isIdentity ? 1.0 : 0.58)
                                    }
                            }
                            Color.clear.frame(height: edgeSpacer)
                        }
                        .scrollTargetLayout()
                        .padding(.horizontal, 28)
                    }
                    .rotation3DEffect(.degrees(Double(lyricTilt)), axis: (x: 1, y: 0, z: 0))
                    .scrollPosition(id: $lyricScrollTarget, anchor: .center)
                    .mask(referenceLyricsMask)
                    .onScrollPhaseChange { _, phase in
                        switch phase {
                        case .tracking, .interacting, .decelerating:
                            isDraggingLyrics = true
                            resumeTask?.cancel()
                            if let target = lyricScrollTarget { focusedLyricID = target }
                        case .idle:
                            if let target = lyricScrollTarget { focusedLyricID = target }
                            scheduleNativeLyricsResume()
                        case .animating:
                            break
                        @unknown default:
                            break
                        }
                    }
                    .onAppear {
                        lyricScrollTarget = currentPlaybackLyricID
                        focusedLyricID = currentPlaybackLyricID
                    }
                    .onChange(of: lyricScrollTarget) { target in
                        guard isDraggingLyrics, let target else { return }
                        focusedLyricID = target
                    }
                    .onChange(of: currentPlaybackLyricID) { newID in
                        guard let newID, !isDraggingLyrics else { return }
                        withAnimation { lyricScrollTarget = newID }
                        focusedLyricID = newID
                    }
                    .onChange(of: lyricFontSize) { _ in
                        recenterNativeLyricsAfterStyleChange()
                    }
                    .onChange(of: lyricLineSpacing) { _ in
                        recenterNativeLyricsAfterStyleChange()
                    }
                }
            } else {
                let fallbackAlignment: HorizontalAlignment = (lyricAlignRaw == "center") ? .center : .leading
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: fallbackAlignment, spacing: CGFloat(lyricLineSpacing)) {
                            Color.clear.frame(height: max(72, lyricsViewportHeight * 0.50 - lyricRowHeight * 0.50))
                            ForEach(lyrics) { line in
                                lyricLine(line, isFocused: line.id == currentVisualLyricID)
                                    .id(line.id)
                                    .background {
                                        GeometryReader { rowGeometry in
                                            Color.clear.preference(
                                                key: ReferenceLyricCenterKey.self,
                                                value: [line.id: rowGeometry.frame(in: .named("referenceLyricsViewport")).midY]
                                            )
                                        }
                                    }
                            }
                            Color.clear.frame(height: max(72, lyricsViewportHeight * 0.50 - lyricRowHeight * 0.50))
                        }
                        .padding(.horizontal, 28)
                    }
                    .rotation3DEffect(.degrees(Double(lyricTilt)), axis: (x: 1, y: 0, z: 0))
                    .coordinateSpace(name: "referenceLyricsViewport")
                    .mask(referenceLyricsMask)
                    .background {
                        GeometryReader { viewport in
                            Color.clear
                                .onAppear { lyricsViewportHeight = viewport.size.height }
                                .onChange(of: viewport.size.height) { newHeight in lyricsViewportHeight = newHeight }
                        }
                    }
                    .onPreferenceChange(ReferenceLyricCenterKey.self) { centers in
                        lyricCenters = centers
                        updateFocusedLyric(from: centers)
                    }
                    .simultaneousGesture(lyricsDragGesture(proxy: proxy))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                            scrollToPlaybackLyric(proxy: proxy, animated: false)
                        }
                    }
                    .onChange(of: currentPlaybackLyricID) { _ in
                        guard !isDraggingLyrics else { return }
                        scrollToPlaybackLyric(proxy: proxy, animated: true)
                    }
                    .onChange(of: lyricFontSize) { _ in
                        recenterLegacyLyricsAfterStyleChange(proxy: proxy)
                    }
                    .onChange(of: lyricLineSpacing) { _ in
                        recenterLegacyLyricsAfterStyleChange(proxy: proxy)
                    }
                }
            }
        }
    }

    private var referenceLyricsMask: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.0),
                .init(color: .black, location: 0.12),
                .init(color: .black, location: 0.84),
                .init(color: .clear, location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func scheduleNativeLyricsResume() {
        resumeTask?.cancel()
        resumeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            isDraggingLyrics = false
            guard let current = currentPlaybackLyricID else { return }
            withAnimation { lyricScrollTarget = current }
            focusedLyricID = current
        }
    }

    private var lyricsHeader: some View {
        HStack(spacing: 12) {
            Button {
                ATMusicHaptics.tap()
                showLyrics = false
            } label: {
                CoverImage(url: song?.coverURL, size: 48, cornerRadius: 10)
                    .shadow(color: .black.opacity(0.26), radius: 9, y: 4)
            }
            .buttonStyle(GlassPressButtonStyle(scale: 0.94))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(song?.name ?? "未在播放")
                        .font(ATMusicFont.appFont(15, .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let source = song?.source {
                        SourceBadgeView(source: source, compact: true)
                    }
                    AudioQualityCapsule(song: song)
                }
                subtitleMenu(font: ATMusicFont.appFont(12, .medium), color: .white.opacity(0.68), alignment: .leading)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                let liked = favorites.isSongLiked(song)
                compactActionButton(
                    icon: liked ? "heart.fill" : "heart",
                    active: liked
                ) {
                    onFavorite()
                }
                playerDownloadActionButton
                songActionsMenu
            }
        }
    }

    private func playbackControls(bottomInset: CGFloat) -> some View {
        VStack(spacing: 15) {
            ReferenceScrubber()
                .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.progress)))
            HStack(spacing: 28) {
                Button {
                    ATMusicHaptics.tap()
                    player.previous()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 25, weight: .semibold))
                }
                .buttonStyle(.plain)
                .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.previous)))

                Button {
                    ATMusicHaptics.tap()
                    player.togglePlayPause()
                } label: {
                    PlayPauseMorphIcon(isPlaying: player.isPlaying, size: 24)
                        .frame(width: 66, height: 66)
                        .foregroundStyle(.white)
                }
                .buttonStyle(GlassPressButtonStyle(scale: 0.92))
                .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.play)))

                Button {
                    ATMusicHaptics.tap()
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 25, weight: .semibold))
                }
                .buttonStyle(.plain)
                .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.next)))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: 320)

            if showVolumeControl {
                ReferenceVolumeControl(accent: Color.atmusicHighlight, secondary: .white.opacity(0.68))
                    .frame(maxWidth: 420)
                    .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.volume)))
                    .transition(.opacity)
            }

            // 播放栏底部只保留歌词、评论、播放队列三个入口。
            HStack(spacing: 68) {
                referenceActionButton(icon: "quote.bubble", active: showLyrics) {
                    showLyrics.toggle()
                }
                referenceActionButton(icon: "text.bubble") {
                    onComments()
                }
                referenceActionButton(icon: "list.bullet") {
                    onQueue()
                }
            }
            .frame(maxWidth: 320)
            .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.actions)))
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, max(14, bottomInset + 4))
        .gesture(commentsGesture)
    }

    private func referenceActionButton(icon: String, active: Bool = false, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button {
            ATMusicHaptics.tap()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(active ? Color.atmusicHighlight : .white.opacity(0.85))
                .frame(width: 42, height: 42)
                .background {
                    if active {
                        ATMusicLiquidSelectionSurface(shape: Circle(), accent: Color.atmusicHighlight)
                    } else {
                        ATMusicGlass(shape: Circle())
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(GlassPressButtonStyle())
    }

    private func compactActionButton(icon: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            ATMusicHaptics.tap()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(active ? Color.atmusicHighlight : .white.opacity(0.85))
                .frame(width: 38, height: 38)
                .background {
                    if active {
                        ATMusicLiquidSelectionSurface(shape: Circle(), accent: Color.atmusicHighlight)
                    } else {
                        ATMusicGlass(shape: Circle())
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(GlassPressButtonStyle())
    }

    @ViewBuilder
    private var playerDownloadActionButton: some View {
        if let song {
            let isDownloaded = DownloadManager.shared.isDownloaded(song: song)
            let isDownloading = DownloadManager.shared.isDownloading(song: song)
            if isDownloaded {
                compactActionButton(
                    icon: "arrow.down.circle.fill",
                    active: true
                ) {
                    onDownload()
                }
            } else if isDownloading {
                let task = DownloadManager.shared.activeDownloads.first(where: { $0.song.identityKey == song.identityKey })
                Button {
                    ATMusicHaptics.tap()
                    if let task {
                        if task.status == .downloading {
                            DownloadManager.shared.pauseDownload(id: task.id)
                        } else if task.status == .paused {
                            DownloadManager.shared.resumeDownload(id: task.id)
                        }
                    }
                } label: {
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.18), lineWidth: 2)
                            .frame(width: 28, height: 28)
                        Circle()
                            .trim(from: 0, to: CGFloat(max(0.08, task?.progress ?? 0)))
                            .stroke(Color.atmusicAmber, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .frame(width: 28, height: 28)
                            .rotationEffect(.degrees(-90))
                        Image(systemName: task?.status == .paused ? "play.fill" : "pause.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.atmusicAmber)
                    }
                    .frame(width: 38, height: 38)
                    .background(ATMusicGlass(shape: Circle()))
                    .contentShape(Circle())
                }
                .buttonStyle(GlassPressButtonStyle())
            } else {
                compactActionButton(
                    icon: "arrow.down.circle",
                    active: false
                ) {
                    onDownload()
                }
            }
        }
    }

    private var songActionsMenu: some View {
        Menu {
            Button("音频信号通路") { showSignalPath = true }
            Button("定时关闭", action: onSleepTimer)
            Button("歌曲信息", action: onSongInfo)
            Button("搜索歌词", action: onSearchLyrics)
            Button("歌词同步校准") { onLyricsSync() }
            Button("添加到歌单", action: onAddToLocalPlaylist)
            if downloadFeatureUnlocked {
                if let song, DownloadManager.shared.isDownloaded(song: song) {
                    if SynologyAPI.shared.isLoggedIn {
                        Button("上传到群晖 NAS") {
                            DownloadManager.shared.startUploadToNAS(song: song)
                        }
                    }
                    Button("从本地移除下载", role: .destructive) {
                        DownloadManager.shared.removeDownloaded(song: song)
                    }
                    Button("重新下载 (更换音质)", action: onDownload)
                } else {
                    Button(song?.source == .synology ? "离线下载到本机" : "离线下载歌曲", action: onDownload)
                }
            }
            Button("播放器设置", action: onPlayerSettings)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 38, height: 38)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("播放器更多")
        .accessibilityHint("打开播放器更多操作，包括播放器设置")
        .menuStyle(.borderlessButton)
    }

    private var emptyLyricsView: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "quote.bubble")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.white.opacity(0.42))
            Text("暂无歌词")
                .font(ATMusicFont.appFont(15, .semibold))
                .foregroundStyle(.white.opacity(0.86))
            Button {
                ATMusicHaptics.tap()
                onSearchLyrics()
            } label: {
                Label("搜索歌词", systemImage: "magnifyingglass")
                    .font(ATMusicFont.appFont(13, .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(.white.opacity(0.16), in: Capsule())
            }
            .buttonStyle(.plain)
            Text("点击封面区域返回歌曲页面")
                .font(ATMusicFont.appFont(12))
                .foregroundStyle(.white.opacity(0.46))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            ATMusicHaptics.tap()
            showLyrics = false
        }
    }

    private var previewLyrics: [LyricLine] {
        guard !lyrics.isEmpty else { return [] }
        let current = currentPlaybackLyricIndex ?? 0
        let start = max(current - 1, 0)
        let end = min(start + 3, lyrics.count)
        return Array(lyrics[start..<end])
    }

    private var currentPlaybackLyricIndex: Int? {
        guard !lyrics.isEmpty else { return nil }
        let progress = LyricTiming.effectiveProgress(clock.progress, userOffset: activeLyricOffset)
        var low = 0
        var high = lyrics.count - 1
        var answer: Int?
        while low <= high {
            let mid = (low + high) / 2
            if lyrics[mid].time <= progress {
                answer = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return answer
    }

    private var currentPlaybackLyricID: UUID? {
        guard let index = currentPlaybackLyricIndex, lyrics.indices.contains(index) else { return nil }
        return lyrics[index].id
    }

    private var currentVisualLyricID: UUID? {
        isDraggingLyrics ? focusedLyricID : (focusedLyricID ?? currentPlaybackLyricID)
    }

    /// “歌手 · 专辑”处点击弹出小方块菜单，分别链接专辑与各个歌手页面
    @ViewBuilder
    private func subtitleMenu(font: Font, color: Color, alignment: TextAlignment = .center) -> some View {
        SongSubtitleMenu(
            song: song,
            font: font,
            color: color,
            alignment: alignment,
            onSelectArtist: { artist in
                pickedArtistName = artist
                showArtistHome = true
            },
            onSelectAlbum: { album in
                selectedAlbum = album
            }
        )
    }

    /// 行高跟随实际内容自然撑开（正文最多两行 + 有译文才加译文行），无固定下限。
    /// 该值仅用于首尾留白（edgeSpacer）估算；每行自身中心即内容中心，
    /// 高亮行由 scrollPosition(.center) 按自身中心对齐，文字始终居中。
    private var lyricRowHeight: CGFloat {
        let primary = CGFloat(lyricFontSize)
        let primaryLineHeight = primary * 1.30
        return primaryLineHeight * 2 + 5
    }

    private func lyricLine(_ line: LyricLine, isFocused: Bool) -> some View {
        // 行高跟随实际内容自然撑开（正文最多两行 + 有译文才加译文行），无固定槽位下限：
        // 无译文时高度为 0，行距可真正压小；每行自身中心即内容中心，
        // scrollPosition(.center) 将高亮行（含多行/带翻译）滚到视口中心，始终居中。
        let translation = (lyricTranslation && line.translation?.isEmpty == false) ? line.translation : nil
        let primarySize = CGFloat(lyricFontSize)
        let translationSize = max(11, primarySize * 0.68)
        let textAlignment: HorizontalAlignment = (lyricAlignRaw == "center") ? .center : .leading

        return Button {
            ATMusicHaptics.tap()
            player.seek(to: LyricTiming.seekTime(for: line, userOffset: activeLyricOffset))
        } label: {
            VStack(alignment: textAlignment, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if textAlignment == .center { Spacer(minLength: 0) }

                    Text(line.text.isEmpty ? " " : line.text)
                        .font(ATMusicFont.appFont(primarySize, .semibold))
                        .foregroundStyle(lyricHighlightColor.opacity(isFocused ? 1 : 0.36))
                        .shadow(
                            color: isFocused ? glowColor.opacity(lyricGlowRadius > 0 ? 0.9 : 0) : .clear,
                            radius: isFocused ? lyricGlowRadius * 0.45 : 0
                        )
                        .shadow(
                            color: isFocused ? glowColor.opacity(lyricGlowRadius > 0 ? 0.55 : 0) : .clear,
                            radius: isFocused ? lyricGlowRadius : 0
                        )
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)

                    if textAlignment != .center {
                        Spacer(minLength: 8)
                        // 始终占用同样的宽度；只有手动拖动且当前行聚焦时才显示。
                        Text(atmusicTimeString(line.time))
                            .font(ATMusicFont.appFont(11, .semibold, .monospaced))
                            .foregroundStyle(lyricDimmedColor.opacity(isFocused && isDraggingLyrics ? 0.82 : 0))
                            .frame(width: 42, alignment: .trailing)
                            .accessibilityHidden(!(isFocused && isDraggingLyrics))
                    } else {
                        Spacer(minLength: 0)
                    }
                }

                // 翻译区域仅在“显示翻译且该行有译文”时渲染；无译文时高度为 0，行距可真正压小。
                if let translation {
                    Text(translation)
                        .font(ATMusicFont.appFont(translationSize, .medium))
                        .foregroundStyle(lyricDimmedColor.opacity(isFocused ? 0.72 : 0))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .accessibilityHidden(!isFocused)
                }
            }
            .multilineTextAlignment(textAlignment == .center ? .center : .leading)
            .frame(maxWidth: .infinity, alignment: textAlignment == .center ? .center : .leading)
            .contentShape(Rectangle())
            // 视觉缩放不会参与 SwiftUI 布局计算，因此不会改变滚动目标的中心点。
            .scaleEffect(isFocused ? 1.06 : 0.84, anchor: textAlignment == .center ? .center : .leading)
            .blur(radius: isFocused ? 0 : CGFloat(lyricBlurAmount) * 0.7)
        }
        .buttonStyle(.plain)
    }

    private func updateFocusedLyric(from centers: [UUID: CGFloat]) {
        guard lyricsViewportHeight > 0, !centers.isEmpty else { return }
        let center = lyricsViewportHeight / 2
        focusedLyricID = centers.min { abs($0.value - center) < abs($1.value - center) }?.key
    }

    private func scrollToPlaybackLyric(proxy: ScrollViewProxy, animated: Bool) {
        guard let id = currentPlaybackLyricID else { return }
        let action = { proxy.scrollTo(id, anchor: .center) }
        if animated {
            withAnimation { action() }
        } else {
            action()
        }
    }

    private func recenterNativeLyricsAfterStyleChange() {
        guard !isDraggingLyrics, let current = currentPlaybackLyricID else { return }
        DispatchQueue.main.async {
            guard !self.isDraggingLyrics else { return }
            self.lyricScrollTarget = current
            self.focusedLyricID = current
        }
    }

    private func recenterLegacyLyricsAfterStyleChange(proxy: ScrollViewProxy) {
        guard !isDraggingLyrics else { return }
        DispatchQueue.main.async {
            guard !self.isDraggingLyrics else { return }
            self.scrollToPlaybackLyric(proxy: proxy, animated: false)
        }
    }

    private func lyricsDragGesture(proxy: ScrollViewProxy) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { _ in
                isDraggingLyrics = true
                resumeTask?.cancel()
                updateFocusedLyric(from: lyricCenters)
            }
            .onEnded { _ in
                resumeTask?.cancel()
                if let id = focusedLyricID {
                    withAnimation {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
                resumeTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    guard !Task.isCancelled else { return }
                    isDraggingLyrics = false
                }
            }
    }

    private var commentsGesture: some Gesture {
        DragGesture(minimumDistance: 25)
            .onEnded { value in
                guard value.translation.height < -54, abs(value.translation.height) > abs(value.translation.width) else { return }
                ATMusicHaptics.medium()
                onComments()
            }
    }

    private var coverAccentColor: Color {
        if let coverDominantColor {
            return CoverPalette.make(dominant: coverDominantColor, colorScheme: .dark).accent
        }
        return Color.atmusicHighlight
    }

    private var lyricHighlightColor: Color {
        if lyricGradMode == 1 {
            switch lyricColorRaw {
            case "white": return .white
            case "amber": return Color.atmusicAmber
            case "cyan": return Color(red: 0.35, green: 0.85, blue: 0.96)
            case "pink": return Color(red: 1.0, green: 0.62, blue: 0.82)
            case "green": return Color(red: 0.42, green: 0.90, blue: 0.62)
            default:
                if let color = Color(hex: lyricColorRaw) { return color }
                return Color.atmusicAmber
            }
        }
        // 模式 0：跟随封面提取主色！
        return coverAccentColor
    }

    private var lyricDimmedColor: Color {
        if lyricGradMode == 1 {
            switch lyricDimColorRaw {
            case "white": return .white.opacity(0.78)
            case "bluegray": return Color(red: 0.72, green: 0.78, blue: 0.86)
            case "gray": return Color.gray.opacity(0.85)
            case "dark": return Color.black.opacity(0.55)
            default:
                if let color = Color(hex: lyricDimColorRaw) { return color }
                return .white.opacity(0.55)
            }
        }
        // 模式 0：柔和半透明未播色
        return .white.opacity(0.55)
    }

    private var glowColor: Color {
        if let color = Color(hex: lyricGlowColorRaw) { return color }
        return lyricHighlightColor
    }

    private var lyricGlowRadius: CGFloat {
        switch lyricGlowLevel {
        case 0: return 0
        case 1: return 6
        case 2: return 12
        case 3: return 18
        case 4: return 25
        default: return 32
        }
    }

    private var accentColor: Color {
        if accentHex.hasPrefix("#"), let color = Color(hex: accentHex) { return color }
        return Color(red: 1.0, green: 0.28, blue: 0.36)
    }

    private var primaryColor: Color {
        if primaryHex.hasPrefix("#"), let color = Color(hex: primaryHex) { return color }
        return Color(red: 1.0, green: 0.28, blue: 0.36)
    }

    private var volumeColor: Color {
        if volumeHex.hasPrefix("#"), let color = Color(hex: volumeHex) { return color }
        return primaryColor
    }
}

private struct ReferenceScrubber: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var clock: PlaybackClock
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                let total = max(max(clock.duration, player.currentSong?.duration ?? 0), 1)
                let progress = min(max((scrubbing ? scrubValue : clock.progress) / total, 0), 1)
                let width = geometry.size.width

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.18))
                        .frame(height: 4)
                    Capsule()
                        .fill(.white.opacity(0.88))
                        .frame(width: width * progress, height: 4)
                    Circle()
                        .fill(.white)
                        .frame(width: scrubbing ? 18 : 12, height: scrubbing ? 18 : 12)
                        .shadow(color: .white.opacity(scrubbing ? 0.55 : 0.28), radius: scrubbing ? 10 : 3)
                        .offset(x: max(0, min(width - (scrubbing ? 18 : 12), width * progress - (scrubbing ? 9 : 6))))
                }
                .frame(height: 30)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !scrubbing {
                                scrubValue = clock.progress
                                ATMusicHaptics.medium()
                            }
                            scrubbing = true
                            scrubValue = min(max(value.location.x / max(width, 1), 0), 1) * total
                        }
                        .onEnded { _ in
                            player.seek(to: scrubValue)
                            scrubbing = false
                            ATMusicHaptics.tap()
                        }
                )
                .overlay(alignment: .topLeading) {
                    if scrubbing {
                        Text(atmusicTimeString(scrubValue))
                            .font(ATMusicFont.appFont(11, .semibold, .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(.black.opacity(0.44), in: Capsule())
                            .offset(x: max(0, min(width - 62, width * progress - 31)), y: -28)
                            .transition(.opacity)
                    }
                }
            }
            .frame(height: 30)

            HStack {
                Text(atmusicTimeString(scrubbing ? scrubValue : clock.progress))
                Spacer()
                Text(atmusicTimeString(max(clock.duration, player.currentSong?.duration ?? 0)))
            }
            .font(ATMusicFont.appFont(11, .regular, .monospaced))
            .foregroundStyle(.white.opacity(0.52))
        }
        .frame(maxWidth: 420)
        .animation(.default, value: scrubbing)
    }
}

private struct ReferenceVolumeControl: View {
    let accent: Color
    let secondary: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(secondary.opacity(0.84))
            ReferenceSystemVolumeView(accent: accent, secondary: secondary)
                .frame(height: 32)
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(secondary.opacity(0.84))
        }
        .frame(height: 34)
    }
}

private struct ReferenceSystemVolumeView: UIViewRepresentable {
    let accent: Color
    let secondary: Color

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        styleVolumeSlider(in: view)
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        styleVolumeSlider(in: uiView)
    }

    private func styleVolumeSlider(in view: MPVolumeView) {
        let applyStyle = {
            let sliders = allSubviews(in: view).compactMap { $0 as? UISlider }
            sliders.forEach { slider in
                slider.minimumTrackTintColor = UIColor(accent.opacity(0.88))
                slider.maximumTrackTintColor = UIColor(secondary.opacity(0.32))
                slider.thumbTintColor = UIColor(accent)
            }
        }

        // MPVolumeView creates its internal slider during layout, so apply the tint once more after it settles.
        applyStyle()
        DispatchQueue.main.async {
            applyStyle()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                applyStyle()
            }
        }
    }

    private func allSubviews(in view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap { allSubviews(in: $0) }
    }
}

private struct MiniLyricsPreview: View {
    let lines: [LyricLine]
    let primary: Color
    let secondary: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                if lines.isEmpty {
                    Text("暂无歌词")
                        .font(ATMusicFont.appFont(15, .semibold))
                        .foregroundStyle(secondary.opacity(0.54))
                } else {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(ATMusicFont.appFont(index == 1 ? 17 : 15, index == 1 ? .semibold : .medium))
                            .foregroundStyle((index == 1 ? primary : secondary).opacity(index == 1 ? 0.86 : 0.5))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                }
            }
            .frame(maxWidth: 420, minHeight: 92)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
