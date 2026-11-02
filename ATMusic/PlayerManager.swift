import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

enum PlayMode: String, CaseIterable, Identifiable {
    case sequential
    case repeatOne
    case shuffle

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .sequential: return "repeat"
        case .repeatOne: return "repeat.1"
        case .shuffle: return "shuffle"
        }
    }

    var title: String {
        switch self {
        case .sequential: return "顺序播放"
        case .repeatOne: return "单曲循环"
        case .shuffle: return "随机播放"
        }
    }
}

enum PlayerLoopMode {
    case off
    case single
    case all
}

final class PlaybackClock: ObservableObject {
    @Published private(set) var progress: Double = 0
    @Published private(set) var duration: Double = 0

    var currentTime: Double { progress }

    func update(progress: Double? = nil, duration: Double? = nil) {
        let apply = {
            if let progress, abs(progress - self.progress) > 0.01 {
                self.progress = progress
            }
            if let duration, abs(duration - self.duration) > 0.01 {
                self.duration = duration
            }
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }
}

final class PlayerManager: NSObject, ObservableObject {
    @Published var queue: [Song] = []
    @Published var currentIndex = 0
    @Published var isPlaying = false
    @Published var isBuffering = false
    @Published var loadFailed = false
    /// 切歌代次：防止旧歌的 URL 解析任务覆盖新歌（快速切歌时）
    private var loadGeneration = 0
    let clock = PlaybackClock()
    var progress: Double = 0 {
        didSet { clock.update(progress: progress) }
    }
    var duration: Double = 0 {
        didSet { clock.update(duration: duration) }
    }

    private var targetVolume: Float = 1.0

    var volume: Float {
        get { targetVolume }
        set {
            targetVolume = newValue
            player?.volume = newValue
            objectWillChange.send()
        }
    }

    var isShuffled: Bool { playMode == .shuffle }

    var loopMode: PlayerLoopMode {
        switch playMode {
        case .repeatOne: return .single
        case .sequential, .shuffle: return .off
        }
    }

    func toggleShuffle() {
        setPlayMode(playMode == .shuffle ? .sequential : .shuffle)
    }

    func toggleLoopMode() {
        switch playMode {
        case .repeatOne: setPlayMode(.sequential)
        default: setPlayMode(.repeatOne)
        }
    }

    func nextTrack() { next() }
    func previousTrack() { previous() }
    @Published var playMode: PlayMode = .sequential {
        didSet {
            guard oldValue != playMode else { return }
            defaults.set(playMode.rawValue, forKey: playModeKey)
        }
    }
    @Published var rate: Double = 1.0
    @Published var sleepTimerEndsAt: Date?
    var sleepTimerRemaining: Int {
        guard let end = sleepTimerEndsAt else { return 0 }
        return max(0, Int(end.timeIntervalSinceNow))
    }
    @Published var history: [Song] = []
    @Published var playCounts: [String: Int] = [:]
    private(set) var listeningSeconds = 0
    @Published private(set) var isInBackground: Bool = false

    // MARK: - 双播放器实例热备池（Dual-Player Warm-Standby Pipeline）
    private struct StandbyPlayback {
        let player: AVPlayer
        let item: AVPlayerItem
        let song: Song
        let url: URL
        let isThirdParty: Bool
        let playbackHeaders: [String: String]
        let fromPlaybackCache: Bool
        let resourceLoader: AudioHeadBlockResourceLoader?
        var statusObserver: NSKeyValueObservation?
    }
    /// 热置换候选播放器宿主：必须由属性强引用持有，否则 hotSwap 函数返回后候选被释放、
    /// 所有状态回调因弱引用为空而静默失效（2026-10-21 日志实证：全天 3 次置换、成功 0 次）。
    private final class HotSwapCandidate {
        let player: AVPlayer
        let item: AVPlayerItem
        let songKey: String
        let generation: Int
        let loader: AudioHeadBlockResourceLoader?
        var statusObservation: NSKeyValueObservation?
        var playerStatusObservation: NSKeyValueObservation?
        var bufferObservation: NSKeyValueObservation?
        var executeHandover: (() -> Void)?
        var didHandover = false
        var itemFailed = false
        var trialEnded = false

        init(player: AVPlayer, item: AVPlayerItem, songKey: String, generation: Int, loader: AudioHeadBlockResourceLoader?) {
            self.player = player
            self.item = item
            self.songKey = songKey
            self.generation = generation
            self.loader = loader
        }
    }

    private var standbyPlayback: StandbyPlayback?
    private var currentResourceLoader: AudioHeadBlockResourceLoader?
    @Published var isHotSwapTrialActive: Bool = false

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var backgroundBoundaryObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var itemStatusObserver: NSKeyValueObservation?
    private var timeControlStatusObserver: NSKeyValueObservation?
    private var equalizerSettingsObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    private var favoritesObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?
    private var backgroundPlayDate: Date?
    private var currentIsThirdParty = false
    private var currentFromPlaybackCache = false
    private var currentPlaybackURL: URL?
    private var playbackConfirmed = false
    private var pendingThirdPartyVIPNotice: ThirdPartyVIPNotice?
    private var sessionConfigured = false
    private var systemPlaybackPrepared = false
    private var routeObserverInstalled = false
    private var interruptionObserverInstalled = false
    private var remoteCommandsInstalled = false
    private var playOrder: [Int] = []
    private var orderPosition = 0
    /// 每个来源最多尝试一次，避免备用来源失败后在来源之间来回循环。
    private var attemptedSourceFallbacks: Set<String> = []
    private var sleepTimer: Timer?
    private var lastCountedSongID: String?
    private var lastListeningProgress: Double?
    private var pendingListeningSeconds = 0.0
    private var wasPlayingBeforeInterruption = false
    private var lastPublishedProgress: Double = -1
    private var lastPersistedProgress: Double = -1
    private var lastNowPlayingArtworkKey: String?
    /// 酷狗高音质地址在部分账号/系统上会返回但无法由 AVPlayer 打开；每首歌只自动降级一次。
    private var kugouStandardFallbackSongKey: String?
    /// 第三方地址偶发过期或节点不可用时，按失败域名重试，避免同一节点反复进入播放器。
    private var thirdPartyRetryExcludedHostsBySong: [String: Set<String>] = [:]
    /// 记录已经交给 AVPlayer 的第三方音质，失败后选择下一个更低档位。
    private var attemptedThirdPartyQualitiesBySong: [String: Set<String>] = [:]
    private var activeThirdPartyQuality: ThirdPartyAudioQuality?
    /// 记录 QQ 官方 vkey 已经尝试过的 BR，官方地址实际打不开时继续换档位。
    private var attemptedQQOfficialBRsBySong: [String: Set<String>] = [:]
    private var activeQQOfficialBR: String?
    /// 正在按 ID 补拉详情的空壳歌（仅 ID、无歌名/封面），避免重复补拉。
    private var metadataEnrichInFlightSongKeys: Set<String> = []
    /// KVO 与 AVPlayerItemFailedToPlayToEndTime 可能同时报告同一次失败。
    private var playbackRecoveryInFlightSongKey: String?
    /// 同一首歌的多个 AVFoundation 失败回调只允许弹一次提示并自动切歌一次。
    private var finalizedFailureSongKey: String?
    /// 播放失败后延迟自动切歌，避免失败回调刚到就立刻跳过歌曲。
    private var failureAutoSkipWorkItem: DispatchWorkItem?
    /// QQ 官方地址返回成功但实际不可播放时，只切换到第三方一次，避免官方/第三方之间循环。
    private var qqThirdPartyFallbackSongKey: String?
    private var playbackConfirmationWorkItem: DispatchWorkItem?
    private var playbackStallWorkItem: DispatchWorkItem?
    /// 某些第三方直链在文件末尾不稳定发送 AVPlayerItemDidPlayToEndTime。
    /// 用一个延迟校验作为兜底，且每个 loadGeneration 只允许推进一次。
    private var playbackEndFallbackWorkItem: DispatchWorkItem?
    private var completedPlaybackGeneration: Int?
    /// 热置换候选（强持有，见 HotSwapCandidate 注释）
    private var hotSwapCandidate: HotSwapCandidate?
    /// 试听已播完、置换未到时的限时等待任务
    private var hotSwapTrialEndWaitWorkItem: DispatchWorkItem?
    /// 后台解析未命中全曲的代际标记（试听结束后据此立即切歌，不再等超时）
    private var hotSwapResolveFailedGeneration: Int?
    private var trialEndedGeneration: Int?
    /// 当前 AVPlayer 中实际装载的歌曲 key，用于恢复播放时校验界面与音源一致性
    private var activeItemSongKey: String?
    /// 缓存坏源自愈去重：同一代际内同一首歌只自愈一次，防死循环
    private var corruptCacheHealGeneration: [String: Int] = [:]
    /// 当前播放项是否来自热备池提升（截断拦截与短播自愈需要这个标记）
    private var currentFromStandby = false
    private static let nowPlayingArtworkCache = NSCache<NSURL, UIImage>()

    private let historyKey = "atmusic.history"
    private let countsKey = "atmusic.playcounts"
    private let listeningSecondsKey = "atmusic.listeningSeconds"
    private let playbackStateKey = "atmusic.player.playbackState.v1"
    private let audioMixKey = "atmusic.audio.mixothers.v1"
    private let playModeKey = "atmusic.player.playMode"
    private let autoSkipOnFailureKey = "atmusic.playback.autoSkipOnFailure"
    private let autoResumeLastPlaybackKey = "atmusic.playback.autoResumeLast"
    private let thirdPartyVIPNoticeKey = "atmusic.showThirdPartyVIPNotice"
    private let defaults = UserDefaults.standard
    private var didAttemptAutoResume = false

    /// 只要全局启用了第三方音源且存在启用的自定义音源，才允许兜底解析。
    private var externalSourcesEnabled: Bool {
        UnblockSourceStore.shared.isEffectivelyEnabled
    }

    private struct ThirdPartyVIPNotice {
        let songKey: String
        let message: String
    }

    private struct PersistedPlaybackState: Codable {
        let queue: [Song]
        let currentIndex: Int
        let progress: Double
        let duration: Double
        let savedAt: Date
    }

    var currentSong: Song? {
        queue.indices.contains(currentIndex) ? queue[currentIndex] : nil
    }

    /// 当前播放歌曲的解析后歌词，供主界面、微播放器与布局编辑器实时联动
    @Published var currentLyrics: [LyricLine] = []
    @Published var currentLyricsSongIdentity: String? = nil

    func updateCurrentLyrics(_ lyrics: [LyricLine], for identityKey: String? = nil) {
        self.currentLyrics = lyrics
        self.currentLyricsSongIdentity = identityKey ?? currentSong?.identityKey
    }

    /// 磁盘播放缓存跟随“播放音质”，避免设置为无损/Hi-Res 时误命中旧的 320k 缓存。
    private func playbackCacheQuality() -> ThirdPartyAudioQuality {
        switch ATMusicAudioQuality.current {
        case .standard: return .kb128
        case .higher, .exhigh: return .kb320
        case .lossless: return .flac
        case .auto, .hires: return .hires
        case .master: return .master
        }
    }

    private func nextSongForPrefetch() -> Song? {
        guard queue.count > 1, playMode != .repeatOne else { return nil }
        if playMode == .shuffle {
            guard !playOrder.isEmpty else { return nil }
            let nextPosition = (orderPosition + 1) % playOrder.count
            let index = playOrder[nextPosition]
            return queue.indices.contains(index) ? queue[index] : nil
        }
        let index = (currentIndex + 1) % queue.count
        return queue.indices.contains(index) ? queue[index] : nil
    }

    private func refreshPrefetchTarget() {
        let song = nextSongForPrefetch()
        let quality = playbackCacheQuality()
        Task { @MainActor in
            MusicCacheManager.shared.requestPrefetch(song: song, quality: quality)
            self.preResolveNextTrackURL()
        }
    }


    private func advanceAfterPlaybackEnd(
        expectedSongKey: String,
        generation: Int,
        reason: String
    ) {
        guard playMode != .repeatOne,
              queue.count > 1,
              loadGeneration == generation,
              currentSong?.identityKey == expectedSongKey,
              completedPlaybackGeneration != generation else { return }

        completedPlaybackGeneration = generation
        playbackEndFallbackWorkItem?.cancel()
        playbackEndFallbackWorkItem = nil
        ATMusicLogger.shared.log("自动下一首：\(currentSong?.name ?? "?")｜触发=\(reason)", level: .debug)
        recordBackgroundPlaybackDurationIfNeeded()
        flushListeningSeconds()
        savePersistedPlaybackState()
        advance()
        loadCurrent()
    }

    private func schedulePlaybackEndFallback(
        player: AVPlayer,
        item: AVPlayerItem,
        songKey: String,
        generation: Int
    ) {
        guard playbackEndFallbackWorkItem == nil,
              playMode != .repeatOne,
              queue.count > 1 else { return }

        let work = DispatchWorkItem { [weak self, weak player, weak item] in
            guard let self,
                  let player,
                  let item,
                  self.player === player,
                  player.currentItem === item,
                  self.loadGeneration == generation,
                  self.currentSong?.identityKey == songKey,
                  self.completedPlaybackGeneration != generation else { return }

            let current = player.currentTime().seconds
            let itemDuration = item.duration
            guard current.isFinite,
                  itemDuration.isNumeric,
                  itemDuration.seconds.isFinite,
                  itemDuration.seconds > 1,
                  current >= itemDuration.seconds - 0.45 else {
                self.playbackEndFallbackWorkItem = nil
                return
            }
            self.playbackEndFallbackWorkItem = nil
            self.advanceAfterPlaybackEnd(
                expectedSongKey: songKey,
                generation: generation,
                reason: "第三方音源末尾兜底"
            )
        }
        playbackEndFallbackWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    override init() {
        super.init()
        AudioURLCache.shared.clear()
        listeningSeconds = defaults.integer(forKey: listeningSecondsKey)
        if let raw = defaults.string(forKey: playModeKey),
           let saved = PlayMode(rawValue: raw) {
            playMode = saved
        }
        loadHistory()
        loadPlayCounts()
        restorePersistedPlaybackState()
        equalizerSettingsObserver = NotificationCenter.default.addObserver(
            forName: ATMusicEqualizer.settingsDidChange,
            object: ATMusicEqualizer.shared,
            queue: .main
        ) { [weak self] _ in
            self?.applyEqualizerToCurrentItem()
        }
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleDidEnterBackground()
        }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleWillEnterForeground()
        }
        terminateObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleWillTerminate()
        }
        favoritesObserver = NotificationCenter.default.addObserver(
            forName: FavoritesStore.favoritesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.syncRemoteLikeCommandState()
        }
    }

    deinit {
        if let equalizerSettingsObserver {
            NotificationCenter.default.removeObserver(equalizerSettingsObserver)
        }
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
        }
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
        }
        if let favoritesObserver {
            NotificationCenter.default.removeObserver(favoritesObserver)
        }
        flushListeningSeconds()
    }

    /// 在首帧之后恢复轻量播放偏好，避免安装后启动阶段触碰系统媒体服务。
    func restorePersistedPlayMode() {
        guard let raw = defaults.string(forKey: playModeKey),
              let saved = PlayMode(rawValue: raw) else { return }
        guard playMode != saved else { return }
        playMode = saved
        if !queue.isEmpty {
            buildPlayOrder()
        }
    }

    // MARK: - 播放控制

    func play(songs: [Song], startAt index: Int = 0) {
        guard !songs.isEmpty else { return }
        guard ensurePlaybackAllowed() else { return }
        queue = songs
        attemptedSourceFallbacks.removeAll()
        currentIndex = min(max(index, 0), songs.count - 1)
        if playMode == .shuffle {
            shuffleVisibleQueueKeepingCurrent()
        } else {
            buildPlayOrder()
        }
        loadCurrent()
    }

    func playSong(_ song: Song, in context: [Song]) {
        play(songs: context, startAt: context.firstIndex(of: song) ?? 0)
    }

    /// 元数据写回后替换队列中的同一首歌曲，让当前播放页和播放队列立即显示新标签。
    /// 不重新加载音频，避免编辑歌曲信息时打断播放。
    func replaceSong(_ updated: Song) {
        let key = updated.identityKey
        var queueChanged = false
        for index in queue.indices {
            let item = queue[index]
            if item.identityKey == key || LocalLibraryStore.isMatchingSong(item, updated) || (item.source == updated.source && item.id == updated.id && item.id != 0) {
                queue[index] = updated
                queueChanged = true
            }
        }
        for index in history.indices {
            let item = history[index]
            if item.identityKey == key || LocalLibraryStore.isMatchingSong(item, updated) || (item.source == updated.source && item.id == updated.id && item.id != 0) {
                history[index] = updated
                queueChanged = true
            }
        }
        if queueChanged {
            objectWillChange.send()
        }
        DetailSongsCache.shared.updateSong(updated)
        lastNowPlayingArtworkKey = nil
        updateNowPlaying()
        savePersistedPlaybackState()
    }

    /// 插队播放：把单首歌曲放到当前歌曲之后，不打断当前播放
    func playNext(_ song: Song) {
        playNext(songs: [song])
    }

    /// 批量插队播放：把一组歌曲按顺序放到当前歌曲之后，不打断当前播放
    func playNext(songs: [Song]) {
        guard !songs.isEmpty else { return }
        guard !queue.isEmpty else {
            play(songs: songs, startAt: 0)
            return
        }
        let insertAt = currentIndex + 1
        let validInsertAt = min(insertAt, queue.count)
        queue.insert(contentsOf: songs, at: validInsertAt)
        switch playMode {
        case .shuffle:
            let count = songs.count
            playOrder = playOrder.map { $0 >= validInsertAt ? $0 + count : $0 }
            let nextOrderPosition = min(orderPosition + 1, playOrder.count)
            let insertedIndices = Array(validInsertAt..<(validInsertAt + count))
            playOrder.insert(contentsOf: insertedIndices, at: nextOrderPosition)
        default:
            buildPlayOrder()
        }
        savePersistedPlaybackState()
        refreshPrefetchTarget()
        Task { @MainActor in
            ToastCenter.shared.show(songs.count == 1 ? "已加入下一首播放" : "已将 \(songs.count) 首歌曲加入下一首播放")
        }
    }

    /// 批量追加到播放队列末尾：不打断当前播放
    func appendToQueue(songs: [Song]) {
        guard !songs.isEmpty else { return }
        guard !queue.isEmpty else {
            play(songs: songs, startAt: 0)
            return
        }
        let startIdx = queue.count
        queue.append(contentsOf: songs)
        switch playMode {
        case .shuffle:
            let count = songs.count
            let insertedIndices = Array(startIdx..<(startIdx + count)).shuffled()
            playOrder.append(contentsOf: insertedIndices)
        default:
            buildPlayOrder()
        }
        savePersistedPlaybackState()
        refreshPrefetchTarget()
        Task { @MainActor in
            ToastCenter.shared.show(songs.count == 1 ? "已加入播放队列末尾" : "已将 \(songs.count) 首歌曲加入播放队列末尾")
        }
    }

    /// 可选地恢复上次退出时的歌曲并立即播放，只在每次应用启动时执行一次。
    func resumePersistedPlaybackIfEnabled() {
        guard !didAttemptAutoResume else { return }
        didAttemptAutoResume = true
        guard defaults.object(forKey: autoResumeLastPlaybackKey) as? Bool ?? false,
              currentSong != nil else { return }
        loadCurrent(resumeAt: progress)
    }

    func togglePlayPause() {
        guard ensurePlaybackAllowed() else { return }
        guard let player else {
            guard currentSong != nil else { return }
            loadCurrent(resumeAt: progress)
            return
        }
        if let activeItemSongKey, activeItemSongKey != currentSong?.identityKey {
            // 播放器里残留的是上一首的 item（新歌还在解析或已解析失败），
            // 直接 play 会把旧歌唤醒而界面显示新歌，改为重新加载当前歌曲
            ATMusicLogger.shared.log("恢复播放时发现播放器曲目与界面不一致，重新加载当前歌曲", level: .warn)
            loadCurrent(resumeAt: progress)
            return
        }
        if player.timeControlStatus == .playing {
            player.pause()
            isPlaying = false
            recordBackgroundPlaybackDurationIfNeeded()
            flushListeningSeconds()
        } else {
            player.playImmediately(atRate: Float(rate))
            isPlaying = true
            if isInBackground {
                backgroundPlayDate = Date()
            }
        }
        savePersistedPlaybackState()
        updateNowPlaying()
    }

    func next(manual: Bool = true) {
        guard ensurePlaybackAllowed() else { return }
        guard !queue.isEmpty else { return }
        recordBackgroundPlaybackDurationIfNeeded()
        flushListeningSeconds()
        advance()
        loadCurrent()
    }

    func previous() {
        guard ensurePlaybackAllowed() else { return }
        guard !queue.isEmpty else { return }
        recordBackgroundPlaybackDurationIfNeeded()
        flushListeningSeconds()
        cleanStandbyPlayer()
        // 直接切换到上一首（不再做“播放超过 3 秒先重头播放”的判断）
        if playMode == .shuffle {
            orderPosition = (orderPosition - 1 + playOrder.count) % playOrder.count
            currentIndex = playOrder[orderPosition]
        } else {
            currentIndex = (currentIndex - 1 + queue.count) % queue.count
        }
        loadCurrent()
    }

    func seek(to seconds: Double) {
        let clamped = max(0, min(seconds, max(duration, 0)))
        progress = clamped
        // 用 seek 完成回调同步真实进度：避免暂停状态下拖动进度后，歌词定位与实际播放位置不一致
        player?.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] finished in
            guard let self, finished else { return }
            self.performOnMain { [weak self] in
                guard let self else { return }
                let actual = self.player?.currentTime().seconds ?? clamped
                if abs(actual - self.progress) > 0.25 {
                    self.progress = actual
                }
            }
        }
        updateNowPlaying()
        savePersistedPlaybackState()
    }

    func seekBy(_ delta: Double) {
        seek(to: progress + delta)
    }

    func togglePlayMode() {
        let nextMode: PlayMode
        switch playMode {
        case .sequential: nextMode = .repeatOne
        case .repeatOne: nextMode = .shuffle
        case .shuffle: nextMode = .sequential
        }
        setPlayMode(nextMode)
    }

    /// 由播放列表弹框直接选择播放顺序。进入随机播放时不仅改变“下一首”索引，
    /// 也真实重排可见 queue，因此播放队列页面会立即显示新的随机顺序。
    func setPlayMode(_ mode: PlayMode) {
        guard playMode != mode else {
            // 已经处于随机模式时再次选择随机，主动再洗牌一次（当前歌保持不变）。
            if mode == .shuffle {
                shuffleVisibleQueueKeepingCurrent()
                savePersistedPlaybackState()
                refreshPrefetchTarget()
            }
            return
        }
        playMode = mode
        if mode == .shuffle {
            shuffleVisibleQueueKeepingCurrent()
        } else {
            buildPlayOrder()
        }
        savePersistedPlaybackState()
        refreshPrefetchTarget()
    }

    func setRate(_ newRate: Double) {
        rate = newRate
        if isPlaying {
            player?.playImmediately(atRate: Float(newRate))
        }
        updateNowPlaying()
    }

    func playQueueIndex(_ index: Int) {
        guard ensurePlaybackAllowed() else { return }
        guard queue.indices.contains(index) else { return }
        jumpToOrderPosition(index)
    }

    func removeFromQueue(at index: Int) {
        guard queue.indices.contains(index), queue.count > 1 else { return }
        let removedID = queue[index].id
        queue.remove(at: index)
        if index < currentIndex {
            currentIndex -= 1
        } else if index == currentIndex {
            currentIndex = min(currentIndex, queue.count - 1)
            loadCurrent()
        }
        buildPlayOrder(avoiding: removedID)
        savePersistedPlaybackState()
        refreshPrefetchTarget()
    }

    /// 调整队列顺序并保持当前歌曲不变。
    func moveQueue(from offsets: IndexSet, to destination: Int) {
        guard !offsets.isEmpty, queue.count > 1 else { return }
        let currentKey = currentSong?.identityKey
        var reordered = queue
        reordered.move(fromOffsets: offsets, toOffset: destination)
        queue = reordered
        if let currentKey, let newIndex = reordered.firstIndex(where: { $0.identityKey == currentKey }) {
            currentIndex = newIndex
        }
        buildPlayOrder()
        savePersistedPlaybackState()
        refreshPrefetchTarget()
    }

    func retryCurrent() {
        guard ensurePlaybackAllowed() else { return }
        loadFailed = false
        loadCurrent()
    }

    /// 删除单条播放历史（含持久化）
    func removeHistory(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            guard history.indices.contains(index) else { continue }
            history.remove(at: index)
        }
        if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: historyKey)
        }
    }

    /// 批量删除指定歌曲的播放历史（含持久化）
    func removeHistory(songs: [Song]) {
        guard !songs.isEmpty else { return }
        let keys = Set(songs.map(\.identityKey))
        history.removeAll { keys.contains($0.identityKey) }
        if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: historyKey)
        }
        objectWillChange.send()
    }

    /// 清空播放历史（含持久化）
    func clearHistory() {
        history.removeAll()
        defaults.removeObject(forKey: historyKey)
    }

    /// 跨设备云端同步：合并播放历史记录
    func mergeRemoteHistory(_ remoteHistory: [Song]) {
        var map: [String: Song] = [:]
        var orderedKeys: [String] = []
        for s in history {
            if map[s.identityKey] == nil {
                map[s.identityKey] = s
                orderedKeys.append(s.identityKey)
            }
        }
        for s in remoteHistory {
            if map[s.identityKey] == nil {
                map[s.identityKey] = s
                orderedKeys.append(s.identityKey)
            }
        }
        let merged = orderedKeys.prefix(50).compactMap { map[$0] }
        history = Array(merged)
        if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: historyKey)
        }
    }

    /// 清空队列，仅保留当前歌曲
    func clearQueue() {
        guard !queue.isEmpty else { return }
        if let current = currentSong {
            queue = [current]
            currentIndex = 0
        } else {
            queue = []
            currentIndex = 0
        }
        cleanStandbyPlayer()
        buildPlayOrder()
        savePersistedPlaybackState()
        refreshPrefetchTarget()
    }


    // MARK: - 队列轻量后台预解析与双播放器热备管线（Apple Music 级无感切歌保障）

    private var preResolveTask: Task<Void, Never>?
    private var preResolvingSongKey: String?

    private func prepareStandbyPlayer(
        for nextSong: Song,
        url: URL,
        isThirdParty: Bool,
        fromPlaybackCache: Bool = false
    ) {
        guard !UnblockService.isCorruptOrAntiLeechURL(url) else {
            ATMusicLogger.shared.log("🚫 热备池拒绝预载防盗链/损坏音频：\(url.absoluteString)", level: .debug)
            return
        }
        if let existing = standbyPlayback,
           existing.song.identityKey == nextSong.identityKey,
           existing.item.status != .failed {
            return
        }
        if url.isFileURL,
           MusicCacheManager.isSuspiciouslyTruncated(fileURL: url, nominalDuration: Double(nextSong.duration)) {
            ATMusicLogger.shared.log("🚫 热备池拒绝时长异常的本地文件：\(nextSong.name) 标称=\(nextSong.duration)s", level: .warn)
            return
        }
        cleanStandbyPlayer()

        var playbackHeaders: [String: String] = [:]
        if isQQAudioHost(url.host) {
            playbackHeaders["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:80.0) Gecko/20100101 Firefox/80.0"
            playbackHeaders["Referer"] = "https://y.qq.com/"
            let cookie = QQMusicAuth.shared.cookieHeader
            if !cookie.isEmpty { playbackHeaders["Cookie"] = cookie }
        } else if url.host?.contains("kugou.com") == true || url.host?.contains("kgimg.com") == true {
            playbackHeaders["User-Agent"] = "Android15-1070-11440-46-0-DiscoveryDRADProtocol-wifi"
            playbackHeaders["Referer"] = "https://www.kugou.com/"
            let cookie = KugouMusicAuth.shared.cookieHeader
            if !cookie.isEmpty { playbackHeaders["Cookie"] = cookie }
        }

        // 方案 3：优先通过 128KB 首包资源加载器创建 Item
        let (item, loader) = AudioHeadBlockPreloader.shared.makePlayerItem(
            url: url,
            headers: playbackHeaders,
            key: nextSong.identityKey
        )
        item.preferredForwardBufferDuration = nextSong.source == .synology ? 4.0 : 8.0
        let standby = AVPlayer(playerItem: item)
        standby.automaticallyWaitsToMinimizeStalling = false
        standby.volume = 0
        standby.rate = 0

        // 方案 2：强力预热硬件解码器与前置缓冲区 (preroll 安全调用：必须在 status == .readyToPlay 时触发)
        var statusObserver: NSKeyValueObservation?
        statusObserver = standby.observe(\.status, options: [.new, .initial]) { [weak standby] observedPlayer, _ in
            guard observedPlayer.status == .readyToPlay else { return }
            observedPlayer.preroll(atRate: 1.0) { [weak standby] finished in
                if finished {
                    ATMusicLogger.shared.log("⚡️ [Dual-Player] Player B 硬件解码预热(preroll)就绪 -> \(nextSong.name)", level: .debug)
                }
            }
        }

        self.standbyPlayback = StandbyPlayback(
            player: standby,
            item: item,
            song: nextSong,
            url: url,
            isThirdParty: isThirdParty,
            playbackHeaders: playbackHeaders,
            fromPlaybackCache: fromPlaybackCache,
            resourceLoader: loader,
            statusObserver: statusObserver
        )
        ATMusicLogger.shared.log("🚀 [Dual-Player] 双播放器热备池就绪：Player B 预缓冲完成 -> \(nextSong.name)", level: .info)
    }

    private func cleanStandbyPlayer() {
        preResolveTask?.cancel()
        preResolveTask = nil
        preResolvingSongKey = nil
        guard let standby = standbyPlayback else { return }
        standbyPlayback = nil
        standby.statusObserver?.invalidate()
        standby.player.pause()
        standby.player.replaceCurrentItem(with: nil)
    }

    private func preResolveNextTrackURL() {
        guard let nextSong = nextSongForPrefetch() else {
            cleanStandbyPlayer()
            return
        }
        let quality = playbackCacheQuality()
        let qualityKey = quality.rawValue

        if let existing = standbyPlayback, existing.song.identityKey == nextSong.identityKey, existing.item.status != .failed {
            return
        }

        if nextSong.source == .local, let relativePath = nextSong.localRelativePath,
           let localURL = try? ManagedAudioPath.resolve(relativePath) {
            prepareStandbyPlayer(for: nextSong, url: localURL, isThirdParty: false)
            return
        }

        if let localURL = DownloadManager.shared.localAudioURL(for: nextSong) {
            prepareStandbyPlayer(for: nextSong, url: localURL, isThirdParty: false)
            return
        }

        if let entry = AudioURLCache.shared.get(songKey: nextSong.identityKey, quality: qualityKey), !entry.isPreview {
            prepareStandbyPlayer(for: nextSong, url: entry.url, isThirdParty: false)
            return
        }

        if preResolvingSongKey == nextSong.identityKey && preResolveTask != nil {
            return
        }

        preResolveTask?.cancel()
        preResolvingSongKey = nextSong.identityKey
        preResolveTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor in
                    if self.preResolvingSongKey == nextSong.identityKey {
                        self.preResolvingSongKey = nil
                    }
                }
            }
            let cachedURL = await MainActor.run {
                MusicCacheManager.shared.cachedURL(for: nextSong, quality: quality)
            }
            if let cachedURL, !Task.isCancelled {
                await MainActor.run {
                    self.prepareStandbyPlayer(
                        for: nextSong,
                        url: cachedURL,
                        isThirdParty: false,
                        fromPlaybackCache: true
                    )
                }
                return
            }

            // 轻微延迟 1.5 秒，让当前歌曲起播网络吞吐完全优先
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }

            let enableUnblock = await MainActor.run { self.externalSourcesEnabled }
            let strictUnlock = await MainActor.run { self.shouldLockOfficialOnly(nextSong) }
            let targetQuality = ATMusicAudioQuality.current
            let thirdPartyQuality = ThirdPartyAudioQuality.current

            var resolvedURL: URL?
            var isThirdParty = false

            if nextSong.source == .synology {
                if let urlStr = await MainActor.run(body: { SynologyAPI.shared.songURL(song: nextSong) }) {
                    resolvedURL = URL(string: urlStr)
                }
            } else if nextSong.source == .subsonic {
                if let urlStr = await MainActor.run(body: { SubsonicAPI.shared.songURL(song: nextSong) }) {
                    resolvedURL = URL(string: urlStr)
                }
            } else if nextSong.source == .jellyfin {
                if let urlStr = await MainActor.run(body: { JellyfinAPI.shared.songURL(song: nextSong) }) {
                    resolvedURL = URL(string: urlStr)
                }
            } else if nextSong.source == .webdav {
                if let urlStr = await MainActor.run(body: { WebDAVAPI.shared.songURL(song: nextSong) }) {
                    resolvedURL = URL(string: urlStr)
                }
            } else if nextSong.source == .kugou {
                // 酷狗官方原生优先
                if let urlStr = try? await KugouMusicAPI.shared.songURL(song: nextSong, quality: targetQuality) {
                    resolvedURL = URL(string: urlStr)
                }
                if resolvedURL == nil && enableUnblock {
                    let res = await self.kugouFallback(song: nextSong, thirdPartyQuality: thirdPartyQuality, enableUnblock: enableUnblock)
                    if let res { resolvedURL = res.url; isThirdParty = true }
                }
            } else if nextSong.source == .qq, let mid = nextSong.qqMid {
                // QQ 音乐官方原生优先
                let official = try? await QQMusicAPI.shared.songURLResult(songmid: mid, mediaMid: nextSong.qqMediaMid, quality: targetQuality, songid: nextSong.id)
                if let u = official?.url {
                    resolvedURL = URL(string: u)
                } else if enableUnblock {
                    let (_, res) = await self.qqFallback(song: nextSong, quality: targetQuality, thirdPartyQuality: thirdPartyQuality, enableUnblock: enableUnblock, strict: strictUnlock)
                    if let res { resolvedURL = res.url; isThirdParty = true }
                }
            } else {
                // 网易云官方原生优先
                let neteaseRes = await self.neteaseResolve(song: nextSong, quality: targetQuality, thirdPartyQuality: thirdPartyQuality, enableUnblock: enableUnblock, strict: strictUnlock)
                if !neteaseRes.isHotSwapTrial, let urlStr = neteaseRes.urlString {
                    resolvedURL = URL(string: urlStr)
                } else if let res = neteaseRes.resolvedThirdParty {
                    resolvedURL = res.url
                    isThirdParty = true
                }
            }

            if let resolvedURL, !Task.isCancelled, !UnblockService.isCorruptOrAntiLeechURL(resolvedURL) {
                // 方案 3：立即向 CDN 发起轻量 128KB 首包预抓取（仅需 20~40ms）
                var prefetchHeaders: [String: String] = [:]
                if isQQAudioHost(resolvedURL.host) {
                    prefetchHeaders["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:80.0) Gecko/20100101 Firefox/80.0"
                    prefetchHeaders["Referer"] = "https://y.qq.com/"
                    let cookie = await MainActor.run { QQMusicAuth.shared.cookieHeader }
                    if !cookie.isEmpty { prefetchHeaders["Cookie"] = cookie }
                }
                AudioHeadBlockPreloader.shared.preloadHeadBlock(
                    for: resolvedURL,
                    headers: prefetchHeaders,
                    key: nextSong.identityKey
                )

                AudioURLCache.shared.set(
                    songKey: nextSong.identityKey,
                    quality: qualityKey,
                    url: resolvedURL,
                    isPreview: false
                )
                ATMusicLogger.shared.log("🚀 下一首队列预解析完成并写入内存池：\(nextSong.name)", level: .debug)
                await MainActor.run {
                    self.prepareStandbyPlayer(
                        for: nextSong,
                        url: resolvedURL,
                        isThirdParty: isThirdParty
                    )
                }
            }
        }
    }

    // MARK: - 睡眠定时

    func startSleepTimer(minutes: Int) {
        stopSleepTimer()
        let endsAt = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepTimerEndsAt = endsAt
        let timer = Timer(timeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
            guard let self else { return }
            self.stopSleepTimer()
            self.pausePlayback()
        }
        RunLoop.main.add(timer, forMode: .common)
        sleepTimer = timer
    }

    func stopSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepTimerEndsAt = nil
    }

    var sleepTimerFormatted: String? {
        guard sleepTimerRemaining > 0 else { return nil }
        return String(format: "%d:%02d", sleepTimerRemaining / 60, sleepTimerRemaining % 60)
    }

    private func pausePlayback() {
        player?.pause()
        isPlaying = false
        recordBackgroundPlaybackDurationIfNeeded()
        flushListeningSeconds()
        savePersistedPlaybackState()
        updateNowPlaying()
    }

    // MARK: - 播放顺序

    private func buildPlayOrder(avoiding removedID: Int? = nil) {
        // 随机模式现在会直接重排 queue，playOrder 始终跟可见列表一致，
        // 避免“界面是 A 顺序、实际下一首却按另一套隐藏索引”的割裂。
        playOrder = Array(queue.indices)
        orderPosition = min(max(currentIndex, 0), max(playOrder.count - 1, 0))
    }

    /// 真实洗牌队列，但保持当前正在播放的歌曲和音频流不变。
    /// 当前歌曲固定到队首，后续歌曲随机排列；这样用户打开播放队列即可看到实际播放顺序。
    private func shuffleVisibleQueueKeepingCurrent() {
        guard queue.count > 1, queue.indices.contains(currentIndex) else {
            buildPlayOrder()
            return
        }
        let current = queue[currentIndex]
        var remaining = queue
        remaining.remove(at: currentIndex)
        remaining.shuffle()
        queue = [current] + remaining
        currentIndex = 0
        playOrder = Array(queue.indices)
        orderPosition = 0
    }

    private func advance() {
        switch playMode {
        case .shuffle:
            guard !playOrder.isEmpty else { return }
            orderPosition = (orderPosition + 1) % playOrder.count
            currentIndex = playOrder[orderPosition]
        default:
            currentIndex = (currentIndex + 1) % queue.count
            orderPosition = currentIndex
        }
    }

    private func jumpToOrderPosition(_ index: Int) {
        currentIndex = index
        if playMode == .shuffle {
            orderPosition = 0
            if let pos = playOrder.firstIndex(of: index) {
                orderPosition = pos
            }
        } else {
            orderPosition = index
        }
        loadCurrent()
    }

    // MARK: - 播放

    private func restartCurrent() {
        guard ensurePlaybackAllowed() else { return }
        seek(to: 0)
        player?.playImmediately(atRate: Float(rate))
        isPlaying = true
        updateNowPlaying()
    }

    /// 队列里个别网易云歌曲可能只有 ID、歌名/歌手/封面全空（例如心动模式接口
    /// 只下发推荐条目），播放地址只靠 ID 仍可播、但信息永远显示不出来。
    /// 播放时按 ID 补拉一次官方详情并回填队列，同一首只补一次。
    private func enrichSongMetadataIfNeeded(_ song: Song) {
        guard song.source == .netease, song.name.isEmpty else { return }
        let key = song.identityKey
        guard metadataEnrichInFlightSongKeys.insert(key).inserted else { return }
        Task {
            let details = try? await NetEaseAPI.shared.songDetails(ids: [song.id])
            await MainActor.run {
                self.metadataEnrichInFlightSongKeys.remove(key)
                guard let full = details?.first, !full.name.isEmpty,
                      let idx = self.queue.firstIndex(where: { $0.identityKey == key }),
                      self.queue[idx].name.isEmpty else { return }
                self.queue[idx] = full
                ATMusicLogger.shared.log("🔎 已补全歌曲信息：\(full.name) - \(full.artists)", level: .info)
                if idx == self.currentIndex {
                    self.updateNowPlaying()
                    self.savePersistedPlaybackState()
                }
            }
        }
    }

    private func loadCurrent(resumeAt: Double? = nil, forceKugouStandard: Bool = false) {
        guard ensurePlaybackAllowed() else { return }
        guard let song = currentSong else { return }
        enrichSongMetadataIfNeeded(song)
        currentLyrics = []
        currentLyricsSongIdentity = nil
        let cacheQuality = playbackCacheQuality()
        loadGeneration += 1
        let generation = loadGeneration
        cleanHotSwapCandidate()
        hotSwapTrialEndWaitWorkItem?.cancel()
        hotSwapTrialEndWaitWorkItem = nil
        hotSwapResolveFailedGeneration = nil
        trialEndedGeneration = nil
        playbackEndFallbackWorkItem?.cancel()
        playbackEndFallbackWorkItem = nil
        thirdPartyRetryExcludedHostsBySong.removeValue(forKey: song.identityKey)
        attemptedThirdPartyQualitiesBySong.removeValue(forKey: song.identityKey)
        attemptedQQOfficialBRsBySong.removeValue(forKey: song.identityKey)
        activeThirdPartyQuality = nil
        activeQQOfficialBR = nil
        playbackRecoveryInFlightSongKey = nil
        finalizedFailureSongKey = nil
        failureAutoSkipWorkItem?.cancel()
        failureAutoSkipWorkItem = nil
        playbackStallWorkItem?.cancel()
        playbackStallWorkItem = nil
        qqThirdPartyFallbackSongKey = nil
        let initialProgress = max(0, min(resumeAt ?? 0, max(song.duration, 0)))

        // 🚀 双播放器热备池瞬间提升（Player B -> Player A，物理级 0 延迟秒播）
        if let standby = self.standbyPlayback,
           standby.song.identityKey == song.identityKey,
           standby.item.status != .failed,
           initialProgress <= 0.05 {
            standby.statusObserver?.invalidate()
            self.standbyPlayback = nil
            duration = song.duration
            progress = 0
            pushHistory(song)
            savePersistedPlaybackState()
            ATMusicLogger.shared.log("⚡️ 双播放器热备池瞬间提升(Player B 0ms秒播)：\(song.name)", level: .info)
            self.setupPlayer(
                url: standby.url,
                resumeAt: 0,
                isThirdParty: standby.isThirdParty,
                customHeaders: standby.playbackHeaders,
                fromPlaybackCache: standby.fromPlaybackCache,
                isHotSwapTrial: false,
                prewarmedPlayer: standby.player,
                prewarmedItem: standby.item,
                resourceLoader: standby.resourceLoader
            )
            return
        }

        // 若未命中热备或指定进度起播，清理失效热备
        cleanStandbyPlayer()

        // 切歌立即暂停旧音频，避免新歌加载期间旧歌继续播放造成“切歌卡住”感
        player?.pause()
        // 界面已切到另一首歌时清掉旧 item：杜绝新歌解析期间点播放把上一首重新唤醒
        if activeItemSongKey != song.identityKey {
            player?.replaceCurrentItem(with: nil)
            activeItemSongKey = nil
        }
        duration = song.duration
        progress = initialProgress
        isPlaying = false
        isBuffering = true
        loadFailed = false
        pushHistory(song)
        savePersistedPlaybackState()
        Task {
            await MainActor.run {
                MusicCacheManager.shared.cancelPrefetch()
                MusicCacheManager.shared.markCurrentPlayback(song: song, quality: cacheQuality)
            }
            // 0. AudioURLCache 内存级极速直通（0ms 秒播，免网络往返）
            let cacheQualityKey = cacheQuality.rawValue
            if let cachedResolved = AudioURLCache.shared.get(songKey: song.identityKey, quality: cacheQualityKey),
               !cachedResolved.isPreview {
                await MainActor.run {
                    guard generation == self.loadGeneration,
                          self.currentSong?.identityKey == song.identityKey else { return }
                    ATMusicLogger.shared.log(
                        "⚡️ AudioURLCache 内存直通命中：\(song.name)｜0ms秒播",
                        level: .info
                    )
                    self.setupPlayer(
                        url: cachedResolved.url,
                        resumeAt: initialProgress,
                        isThirdParty: false
                    )
                    self.preResolveNextTrackURL()
                }
                return
            }

            if song.source != .local {
                let cachedURL = await MainActor.run {
                    MusicCacheManager.shared.cachedURL(for: song, quality: cacheQuality)
                }
                if let cachedURL {
                    await MainActor.run {
                        guard generation == self.loadGeneration,
                              self.currentSong?.identityKey == song.identityKey else { return }
                        ATMusicLogger.shared.log(
                            "播放缓存命中：\(song.name)｜音质=\(cacheQuality.rawValue)",
                            level: .info
                        )
                        self.setupPlayer(url: cachedURL, resumeAt: initialProgress, fromPlaybackCache: true)
                    }
                    return
                }
            }

            var urlString: String?
            var resolvedThirdParty: UnblockService.Resolved?
            var qqOfficialBR: String?
            var attemptedQQOfficialBRs: [String] = []
            var isHotSwapTrial = false
            // 官方地址失败后，使用已启用的自定义音源兜底。
            let enableUnblock = externalSourcesEnabled
            let strictUnlock = shouldLockOfficialOnly(song)
            let quality = (forceKugouStandard && song.source == .kugou) ? .standard : ATMusicAudioQuality.current
            let thirdPartyQuality = ThirdPartyAudioQuality.current
            // 核心准则：官方原生绝对第一优先级！只要账号登录过，官方接口自带鉴权Cookie，直接直出正版满血音轨，绝不提前短路到第三方劣质源
            ATMusicLogger.shared.log("▶ 开始播放：\(song.name) - \(song.artists)｜平台=\(song.source.rawValue) id=\(song.id) 音质=\(quality.level) 第三方音质=\(thirdPartyQuality.rawValue) 自定义音源=\(enableUnblock ? "开" : "关") 官方优先=是", level: .info)
            if song.source == .local, let relativePath = song.localRelativePath,
               let localURL = try? ManagedAudioPath.resolve(relativePath) {
                urlString = localURL.absoluteString
            } else if let localURL = DownloadManager.shared.localAudioURL(for: song) {
                ATMusicLogger.shared.log("⚡ 命中本地离线文件，0ms 启动离线播放：\(song.name) -> \(localURL.lastPathComponent)", level: .info)
                urlString = localURL.absoluteString
            } else if song.source == .synology {
                urlString = SynologyAPI.shared.songURL(song: song)
            } else if song.source == .subsonic {
                urlString = SubsonicAPI.shared.songURL(song: song)
            } else if song.source == .jellyfin {
                urlString = JellyfinAPI.shared.songURL(song: song)
            } else if song.source == .webdav {
                urlString = WebDAVAPI.shared.songURL(song: song)
            } else if song.source == .kugou {
                // 酷狗音乐：100% 优先请求官方原生接口（带 VIP 登录态）
                urlString = try? await KugouMusicAPI.shared.songURL(song: song, quality: quality)
                if urlString == nil, enableUnblock {
                    ATMusicLogger.shared.log("酷狗官方不可用，降级走第三方音源兜底：\(song.name)", level: .warn)
                    resolvedThirdParty = await kugouFallback(
                        song: song,
                        thirdPartyQuality: thirdPartyQuality,
                        enableUnblock: enableUnblock
                    )
                }
            } else if song.source == .qq, let mid = song.qqMid {
                // QQ 音乐：100% 优先请求官方原生 vkey 接口（带绿钻 VIP 登录态）
                let officialResult = try? await QQMusicAPI.shared.songURLResult(
                    songmid: mid,
                    mediaMid: song.qqMediaMid,
                    quality: quality,
                    songid: song.id
                )
                if let official = officialResult {
                    urlString = official.url
                    qqOfficialBR = official.br
                    attemptedQQOfficialBRs = official.attemptedBRs
                    if official.isTrial && enableUnblock {
                        ATMusicLogger.shared.log("QQ 官方为试听片段，秒起试听并准备第三方热置换：\(song.name)", level: .info)
                        isHotSwapTrial = true
                    }
                }
                if urlString == nil, enableUnblock {
                    ATMusicLogger.shared.log("QQ官方全档位无版权/不可播，降级走第三方音源兜底：\(song.name)", level: .warn)
                    (urlString, resolvedThirdParty) = await qqFallback(
                        song: song,
                        quality: quality,
                        thirdPartyQuality: thirdPartyQuality,
                        enableUnblock: enableUnblock,
                        strict: strictUnlock
                    )
                }
            } else {
                let neteaseRes = await neteaseResolve(
                    song: song,
                    quality: quality,
                    thirdPartyQuality: thirdPartyQuality,
                    enableUnblock: enableUnblock,
                    strict: strictUnlock
                )
                urlString = neteaseRes.urlString
                resolvedThirdParty = neteaseRes.resolvedThirdParty
                if neteaseRes.isHotSwapTrial {
                    isHotSwapTrial = true
                }
            }

            // 方案 1：官方试听片段 150ms 瞬时发声 + 第三方完整音轨静默无缝热置换
            if isHotSwapTrial, let trialStr = urlString, let trialURL = URL(string: trialStr) {
                await MainActor.run {
                    guard generation == self.loadGeneration else { return }
                    self.setupPlayer(
                        url: trialURL,
                        resumeAt: initialProgress,
                        fromPlaybackCache: false,
                        isHotSwapTrial: true
                    )
                }
                // 后台并行静默解析第三方完整音轨并进行无感热置换
                Task.detached(priority: .userInitiated) { [generation, weak self] in
                    guard let self else { return }
                    let isEnabled = await MainActor.run { self.externalSourcesEnabled }
                    guard isEnabled else { return }
                    let fullTrack = await UnblockService.resolve(
                        name: song.name,
                        artists: song.artists,
                        neteaseID: song.id,
                        songSource: song.source,
                        qqMid: song.qqMid,
                        qqMediaMid: song.qqMediaMid,
                        kugouID: song.kugouHash,
                        quality: thirdPartyQuality,
                        strict: strictUnlock
                    )
                    if let fullTrack {
                        await MainActor.run {
                            guard generation == self.loadGeneration, self.currentSong?.identityKey == song.identityKey else { return }
                            self.hotSwapAudioTrack(with: fullTrack, for: song, generation: generation)
                        }
                    } else {
                        ATMusicLogger.shared.log("⚠️ 试听热置换后台解析全曲未命中：\(song.name)", level: .warn)
                        await MainActor.run {
                            guard generation == self.loadGeneration else { return }
                            self.hotSwapResolveFailedGeneration = generation
                            if self.trialEndedGeneration == generation {
                                self.advanceAfterPlaybackEnd(
                                    expectedSongKey: song.identityKey,
                                    generation: generation,
                                    reason: "试听结束且热置换解析未命中"
                                )
                            }
                        }
                    }
                }
                return
            }
            if let resolved = resolvedThirdParty {
                let notice = self.thirdPartyVIPNotice(for: song, sourceTitle: resolved.sourceTitle)
                await MainActor.run {
                    guard generation == self.loadGeneration else { return }
                    self.setupPlayer(
                        url: resolved.url,
                        thirdPartyVIPNotice: notice,
                        resumeAt: initialProgress,
                        isThirdParty: true,
                        thirdPartyQuality: resolved.quality,
                        customHeaders: resolved.headers
                    )
                }
                return
            }
            guard let urlString, let url = URL(string: urlString) else {
                await MainActor.run {
                    guard generation == self.loadGeneration else { return }
                    self.isBuffering = false
                    self.loadFailed = true
                    let failureMessage = atmusicLocalized(
                        "播放失败，当前音源暂时无法响应，请稍后重试或切换其他歌曲",
                        "Playback failed. The current source did not respond. Please try again or switch songs."
                    )
                    ATMusicLogger.shared.log("播放失败：\(song.name) - \(failureMessage)｜音质=\(quality.level)", level: .error)
                    self.finishUnrecoverablePlaybackFailure(
                        song: song,
                        reason: "解析播放地址失败",
                        message: failureMessage
                    )
                }
                return
            }
            await MainActor.run {
                guard generation == self.loadGeneration else { return }
                self.setupPlayer(
                    url: url,
                    resumeAt: initialProgress,
                    qqOfficialBR: qqOfficialBR,
                    attemptedQQOfficialBRs: attemptedQQOfficialBRs
                )
            }
        }
    }

    private enum TimeoutRaceResult<T: Sendable>: Sendable {
        case value(T)
        case timedOut
    }

    private func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async -> T?) async -> T? {
        await withTaskGroup(of: TimeoutRaceResult<T?>.self) { group in
            group.addTask {
                let val = await operation()
                return .value(val)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return .timedOut
            }
            while let first = await group.next() {
                switch first {
                case .value(let val):
                    if let val {
                        group.cancelAll()
                        return val
                    }
                case .timedOut:
                    group.cancelAll()
                    return nil
                }
            }
            return nil
        }
    }

    /// 网易云播放地址解析：按设置音质取 URL，VIP 歌曲官方试听前奏秒出(150ms) + 第三方完整音轨静默热置换。
    private func neteaseResolve(
        song: Song,
        quality: ATMusicAudioQuality,
        thirdPartyQuality: ThirdPartyAudioQuality = .current,
        enableUnblock: Bool,
        strict: Bool = false
    ) async -> (urlString: String?, resolvedThirdParty: UnblockService.Resolved?, isHotSwapTrial: Bool) {
        var resolved: UnblockService.Resolved?

        // 1. 官方原生闭环阶梯探测（100% 优先官方原生无损/高品质，会员 Cookie 鉴权自动生效）
        var levelCandidates: [String] = []
        switch quality {
        case .master:
            levelCandidates = ["jymaster", "hires", "lossless", "exhigh", "standard"]
        case .hires, .auto:
            levelCandidates = ["hires", "lossless", "exhigh", "standard"]
        case .lossless:
            levelCandidates = ["lossless", "exhigh", "standard"]
        case .exhigh:
            levelCandidates = ["exhigh", "standard"]
        case .higher:
            levelCandidates = ["higher", "standard"]
        case .standard:
            levelCandidates = ["standard"]
        }

        var trialURL: String? = nil

        // 逐级探测官方可播完整音轨，绝不因为母带不可用而直接跌入第三方
        for lvl in levelCandidates {
            if let infos = try? await NetEaseAPI.shared.songURLInfo(ids: [song.id], level: lvl),
               let info = infos[song.id],
               let u = info.url, !u.isEmpty {
                if info.freeTrial != true {
                    ATMusicLogger.shared.log("网易云官方原生命中(级别=\(lvl))：\(song.name)", level: .info)
                    return (urlString: u, resolvedThirdParty: nil, isHotSwapTrial: false)
                }
                // 全长媒体覆盖：被标试听但服务端并未给出试听区间、且返回时长已达
                // 歌曲全长的 90%——返回的分明是完整音轨，元数据标记不可信，
                // 按官方完整命中处理（VIP 先官方的硬规则，媒体证据优先于标记）。
                if !info.trialByBounds,
                   song.duration > 0,
                   info.timeMs >= Int(song.duration * 900) {
                    ATMusicLogger.shared.log("网易云官方返回全长媒体(级别=\(lvl) 时长=\(info.timeMs)ms/全长=\(Int(song.duration * 1000))ms)，忽略试听误判：\(song.name)", level: .info)
                    return (urlString: u, resolvedThirdParty: nil, isHotSwapTrial: false)
                }
                ATMusicLogger.shared.log("网易云该级别判试听(级别=\(lvl) 时长=\(info.timeMs)ms 区间证据=\(info.trialByBounds))：\(song.name)", level: .debug)
                if trialURL == nil {
                    trialURL = u
                }
            }
        }

        // 2. 若官方提供了试听片段且开启了解封，采用官方试听前奏秒出(150ms) + 第三方完整音轨静默热置换
        if let trial = trialURL, enableUnblock {
            ATMusicLogger.shared.log("网易云官方为试听片段，秒起试听并准备第三方热置换：\(song.name)", level: .info)
            return (urlString: trial, resolvedThirdParty: nil, isHotSwapTrial: true)
        }

        // 3. 只有当官方全档位均无版权，且用户开启了第三方解封，方才触发第三方兜底
        if enableUnblock {
            ATMusicLogger.shared.log("网易云官方全档位无完整音轨，触发第三方音源兜底：\(song.name)", level: .warn)
            resolved = await UnblockService.resolve(
                name: song.name,
                artists: song.artists,
                neteaseID: song.id,
                songSource: .netease,
                quality: thirdPartyQuality,
                strict: strict
            )
        }

        return (urlString: trialURL, resolvedThirdParty: resolved, isHotSwapTrial: false)
    }

    /// QQ 歌曲兜底：官方失败后只走 QQ 第三方接口，不跨平台匹配同名歌曲。
    private func qqFallback(
        song: Song,
        quality _: ATMusicAudioQuality,
        thirdPartyQuality: ThirdPartyAudioQuality = .current,
        enableUnblock: Bool,
        strict: Bool = false,
        excludedHosts: Set<String> = []
    ) async -> (String?, UnblockService.Resolved?) {
        guard enableUnblock else {
            ATMusicLogger.shared.log("QQ兜底：\(song.name) 第三方=未启用", level: .debug)
            return (nil, nil)
        }
        var resolved = await UnblockService.resolve(
            name: song.name,
            artists: song.artists,
            neteaseID: song.id,
            songSource: .qq,
            qqMid: song.qqMid,
            qqMediaMid: song.qqMediaMid,
            quality: thirdPartyQuality,
            strict: strict,
            excludedHosts: excludedHosts
        )
        if resolved == nil {
            if let matched = await matchNetEaseSong(
                name: song.name,
                artists: song.artists,
                durationMS: Int(song.duration * 1000),
                strict: strict
            ) {
                resolved = await UnblockService.resolve(
                    name: matched.name,
                    artists: matched.artists,
                    neteaseID: matched.id,
                    songSource: .netease,
                    quality: thirdPartyQuality,
                    strict: strict
                )
                if resolved != nil {
                    ATMusicLogger.shared.log("QQ兜底跨平台匹配网易云命中：\(song.name) -> \(matched.name)", level: .info)
                }
            }
        }
        ATMusicLogger.shared.log("QQ兜底：\(song.name) QQ第三方=\(resolved != nil ? "命中" : "未命中")", level: .debug)
        return (nil, resolved)
    }

    /// 酷狗兜底：官方播放失败后使用内置音源作为备选。
    private func kugouFallback(
        song: Song,
        thirdPartyQuality: ThirdPartyAudioQuality = .current,
        enableUnblock: Bool
    ) async -> UnblockService.Resolved? {
        guard enableUnblock else { return nil }
        let kugouID = song.kugouHash ?? song.kugouAlbumAudioId ?? ""
        if kugouID.isEmpty {
            ATMusicLogger.shared.log("酷狗兜底跳过：缺少 album_audio_id/hash", level: .debug)
        } else {
            let resolved = await UnblockService.resolve(
                name: song.name,
                artists: song.artists,
                neteaseID: 0,
                songSource: .kugou,
                kugouID: kugouID,
                quality: thirdPartyQuality
            )
            if let resolved {
                ATMusicLogger.shared.log("酷狗兜底：\(song.name) 酷狗音源=命中", level: .debug)
                return resolved
            }
        }

        let strict = shouldLockOfficialOnly(song)
        if let matched = await matchNetEaseSong(
            name: song.name,
            artists: song.artists,
            durationMS: Int(song.duration * 1000),
            strict: strict
        ) {
            let resolved = await UnblockService.resolve(
                name: matched.name,
                artists: matched.artists,
                neteaseID: matched.id,
                songSource: .netease,
                quality: thirdPartyQuality,
                strict: strict
            )
            ATMusicLogger.shared.log("酷狗兜底转网易云音源：\(song.name) -> \(matched.name) 第三方=\(resolved != nil ? "命中" : "未命中")", level: .debug)
            return resolved
        }

        ATMusicLogger.shared.log("酷狗兜底：\(song.name) 第三方=未命中", level: .debug)
        return nil
    }

    /// 不再按歌手硬拦截跨平台兜底，避免 QQ 官方失败后把可播的网易云链路一并阻断。
    private func shouldLockOfficialOnly(_ song: Song) -> Bool {
        false
    }

    /// 在网易云按 歌名+歌手 匹配同名歌曲（QQ vkey 失败时的免费播放兜底）
    private func matchNetEaseSong(name: String, artists: String, durationMS: Int, strict: Bool = false) async -> Song? {
        let keyword = ([name, artists].filter { !$0.isEmpty }).joined(separator: " ")
        guard !keyword.isEmpty,
              let results = try? await NetEaseAPI.shared.search(keyword: keyword, limit: 8),
              !results.isEmpty else { return nil }
        let target = Double(durationMS) / 1000.0
        let artistTokens = artists.lowercased().split(whereSeparator: { $0 == " " || $0 == "/" || $0 == "&" }).map(String.init)
        // 优先：歌手匹配 + 时长接近（兼容 Jay Chou 别名）
        if let hit = results.first(where: { song in
            let durOK = abs(song.duration - target) < 12
            let songArtists = song.artists.lowercased()
            let artistOK = artistTokens.contains { !$0.isEmpty && songArtists.contains($0) }
                || (songArtists.contains("周杰伦") && artists.lowercased().contains("jay chou"))
            return durOK && artistOK
        }) { return hit }
        // 严格模式（周杰伦等版权歌手）：找不到原唱直接放弃，绝不返回翻唱
        if strict { return nil }
        // 其次：仅时长接近（必须足够接近才用，避免张冠李戴）
        if let hit = results.min(by: { abs($0.duration - target) < abs($1.duration - target) }),
           abs(hit.duration - target) < 20 {
            return hit
        }
        // 找不到可靠匹配：宁可播放失败，也不播放错误歌曲
        return nil
    }

    /// 仅在高音质地址已经交给 AVPlayer 但实际无法打开时回退标准音质。
    /// 这样正常账号仍优先使用高音质，兼容部分旧系统或账号返回的不可解码资源。
    @discardableResult
    private func retryKugouAtStandardIfNeeded(error: Error?) -> Bool {
        guard let song = currentSong,
              song.source == .kugou,
              ATMusicAudioQuality.current != .standard,
              kugouStandardFallbackSongKey != song.identityKey else { return false }
        kugouStandardFallbackSongKey = song.identityKey
        let resume = progress
        ATMusicLogger.shared.log("酷狗高音质地址无法打开，自动回退标准音质：歌曲=\(song.name) 系统=\(UIDevice.current.systemVersion) 错误=\(error?.localizedDescription ?? "未知错误")", level: .debug)
        loadCurrent(resumeAt: resume, forceKugouStandard: true)
        return true
    }

    @discardableResult
    private func retryThirdPartyIfNeeded(excludingHost: String? = nil) -> Bool {
        guard let song = currentSong,
              externalSourcesEnabled else { return false }
        if playbackRecoveryInFlightSongKey == song.identityKey {
            return true
        }

        let generation = loadGeneration
        let resume = progress
        let strict = shouldLockOfficialOnly(song)
        let currentQuality = activeThirdPartyQuality ?? ThirdPartyAudioQuality.current
        let attempted = attemptedThirdPartyQualitiesBySong[song.identityKey] ?? []
        guard let thirdPartyQuality = currentQuality.fallbackChain.first(where: {
            !attempted.contains($0.rawValue)
        }) else {
            ATMusicLogger.shared.log(
                "第三方播放地址重试停止：歌曲=\(song.name)｜已无更低可用音质｜当前=\(currentQuality.rawValue)",
                level: .debug
            )
            return false
        }
        attemptedThirdPartyQualitiesBySong[song.identityKey, default: []].insert(thirdPartyQuality.rawValue)
        var excludedHosts = thirdPartyRetryExcludedHostsBySong[song.identityKey] ?? []
        if let excludingHost, !excludingHost.isEmpty {
            excludedHosts.insert(excludingHost.lowercased())
        }
        guard excludedHosts.count <= 6 else {
            ATMusicLogger.shared.log(
                "第三方播放地址重试停止：歌曲=\(song.name)｜已排除域名=\(excludedHosts.sorted().joined(separator: ","))",
                level: .debug
            )
            return false
        }
        thirdPartyRetryExcludedHostsBySong[song.identityKey] = excludedHosts
        playbackRecoveryInFlightSongKey = song.identityKey
        ATMusicLogger.shared.log(
            "第三方播放地址失效，自动降级重试：歌曲=\(song.name)｜音质=\(thirdPartyQuality.rawValue)｜系统=\(UIDevice.current.systemVersion)｜排除域名=\(excludedHosts.sorted().joined(separator: ","))",
            level: .debug
        )
        Task {
            let resolved = await self.resolveThirdParty(
                song: song,
                quality: thirdPartyQuality,
                strict: strict,
                excludedHosts: excludedHosts
            )
            await MainActor.run {
                guard generation == self.loadGeneration,
                      self.currentSong?.identityKey == song.identityKey else {
                    if self.playbackRecoveryInFlightSongKey == song.identityKey {
                        self.playbackRecoveryInFlightSongKey = nil
                    }
                    return
                }
                self.playbackRecoveryInFlightSongKey = nil
                if let resolved {
                    let notice = self.thirdPartyVIPNotice(for: song, sourceTitle: resolved.sourceTitle)
                    self.setupPlayer(
                        url: resolved.url,
                        thirdPartyVIPNotice: notice,
                        resumeAt: resume,
                        isThirdParty: true,
                        thirdPartyQuality: resolved.quality
                    )
                    ATMusicLogger.shared.log(
                        "第三方播放地址重试成功：\(song.name)｜音质=\(resolved.quality.rawValue)｜域名=\(resolved.url.host ?? "?")",
                        level: .info
                    )
                } else {
                    ATMusicLogger.shared.log(
                        "第三方播放地址重试未命中：歌曲=\(song.name)｜已排除域名=\(excludedHosts.sorted().joined(separator: ","))",
                        level: .debug
                    )
                    if self.retryThirdPartyIfNeeded() { return }
                    self.finishUnrecoverablePlaybackFailure(song: song, reason: "第三方播放地址重试失败")
                }
            }
        }
        return true
    }

    @discardableResult
    private func retryQQOfficialIfNeeded() -> Bool {
        guard let song = currentSong,
              song.source == .qq,
              let qqMid = song.qqMid,
              !qqMid.isEmpty else { return false }
        if playbackRecoveryInFlightSongKey == song.identityKey {
            return true
        }

        let officialBRs = ["F000", "M800", "M500", "C400"]
        let attempted = attemptedQQOfficialBRsBySong[song.identityKey] ?? []
        guard let nextBR = officialBRs.first(where: { !attempted.contains($0) }) else {
            return false
        }
        attemptedQQOfficialBRsBySong[song.identityKey, default: []].insert(nextBR)
        playbackRecoveryInFlightSongKey = song.identityKey
        let generation = loadGeneration
        let resume = progress
        ATMusicLogger.shared.log(
            "QQ 官方地址实际不可播放，继续切换官方音质：歌曲=\(song.name)｜BR=\(nextBR)",
            level: .debug
        )
        Task {
            let urlString = try? await QQMusicAPI.shared.songURL(
                songmid: qqMid,
                mediaMid: song.qqMediaMid,
                br: nextBR,
                songid: song.id
            )
            await MainActor.run {
                guard generation == self.loadGeneration,
                      self.currentSong?.identityKey == song.identityKey else {
                    if self.playbackRecoveryInFlightSongKey == song.identityKey {
                        self.playbackRecoveryInFlightSongKey = nil
                    }
                    return
                }
                self.playbackRecoveryInFlightSongKey = nil
                if let urlString, let url = URL(string: urlString) {
                    self.setupPlayer(
                        url: url,
                        resumeAt: resume,
                        qqOfficialBR: nextBR
                    )
                    return
                }
                if self.retryQQOfficialIfNeeded() { return }
                if self.fallbackQQToThirdPartyIfNeeded() { return }
                self.finishUnrecoverablePlaybackFailure(song: song, reason: "QQ 官方音质均不可播放")
            }
        }
        return true
    }

    @discardableResult
    private func fallbackQQToThirdPartyIfNeeded() -> Bool {
        guard let song = currentSong,
              song.source == .qq,
              let qqMid = song.qqMid,
              !qqMid.isEmpty,
              qqThirdPartyFallbackSongKey != song.identityKey,
              externalSourcesEnabled else { return false }
        if playbackRecoveryInFlightSongKey == song.identityKey {
            return true
        }

        qqThirdPartyFallbackSongKey = song.identityKey
        playbackRecoveryInFlightSongKey = song.identityKey
        let generation = loadGeneration
        let resume = progress
        let strict = shouldLockOfficialOnly(song)
        let thirdPartyQuality = ThirdPartyAudioQuality.current
        ATMusicLogger.shared.log(
            "QQ 官方地址实际不可播放，切换第三方解析：歌曲=\(song.name)｜系统=\(UIDevice.current.systemVersion)",
            level: .debug
        )
        Task {
            let (_, resolved) = await self.qqFallback(
                song: song,
                quality: ATMusicAudioQuality.current,
                thirdPartyQuality: thirdPartyQuality,
                enableUnblock: self.externalSourcesEnabled,
                strict: strict
            )
            await MainActor.run {
                guard generation == self.loadGeneration,
                      self.currentSong?.identityKey == song.identityKey else {
                    if self.playbackRecoveryInFlightSongKey == song.identityKey {
                        self.playbackRecoveryInFlightSongKey = nil
                    }
                    return
                }
                self.playbackRecoveryInFlightSongKey = nil
                if let resolved {
                    let notice = self.thirdPartyVIPNotice(for: song, sourceTitle: resolved.sourceTitle)
                    self.setupPlayer(
                        url: resolved.url,
                        thirdPartyVIPNotice: notice,
                        resumeAt: resume,
                        isThirdParty: true,
                        thirdPartyQuality: resolved.quality
                    )
                    ATMusicLogger.shared.log(
                        "QQ 官方失败后第三方切换成功：\(song.name)｜域名=\(resolved.url.host ?? "?")",
                        level: .info
                    )
                } else {
                    ATMusicLogger.shared.log("QQ 官方失败后 QQ 第三方仍未命中：\(song.name)", level: .debug)
                    self.finishUnrecoverablePlaybackFailure(song: song, reason: "QQ 第三方解析失败")
                }
            }
        }
        return true
    }

    /// 清理未完成的热置换候选（新一轮加载、交接失败、歌曲切换时调用）
    private func cleanHotSwapCandidate() {
        guard let candidate = hotSwapCandidate else { return }
        hotSwapCandidate = nil
        candidate.statusObservation?.invalidate()
        candidate.playerStatusObservation?.invalidate()
        candidate.bufferObservation?.invalidate()
        candidate.executeHandover = nil
        if !candidate.didHandover {
            candidate.player.pause()
            candidate.player.replaceCurrentItem(with: nil)
        }
    }

    /// 置换明确失败且试听已经播完：不再等待，直接推进下一首
    private func advanceAfterFailedHotSwap(candidate: HotSwapCandidate, reason: String) {
        guard hotSwapCandidate === candidate else { return }
        let songKey = candidate.songKey
        let generation = candidate.generation
        cleanHotSwapCandidate()
        isHotSwapTrialActive = false
        advanceAfterPlaybackEnd(expectedSongKey: songKey, generation: generation, reason: reason)
    }

    /// 试听播完时的收尾：置换已失败→立即切歌；置换还在路上→最多等 5 秒，超时切歌。
    /// 此前这里只打日志无限等待，置换一旦失败/丢失就永久卡住（2026-10-21 实证卡死 2 小时 19 分）。
    private func handleTrialPlaybackEnded(loadedSong: Song, generation: Int) {
        trialEndedGeneration = generation
        if playMode == .repeatOne {
            // 单曲循环：试听重头播，置换完成会自动切到全曲
            restartCurrent()
            return
        }
        if let candidate = hotSwapCandidate, candidate.generation == generation {
            candidate.trialEnded = true
            if candidate.itemFailed {
                advanceAfterFailedHotSwap(candidate: candidate, reason: "试听结束且热置换音轨加载失败")
                return
            }
        }
        if hotSwapResolveFailedGeneration == generation {
            advanceAfterPlaybackEnd(
                expectedSongKey: loadedSong.identityKey,
                generation: generation,
                reason: "试听结束且热置换解析未命中"
            )
            return
        }
        hotSwapTrialEndWaitWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.isHotSwapTrialActive,
                  self.loadGeneration == generation,
                  self.currentSong?.identityKey == loadedSong.identityKey else { return }
            self.advanceAfterPlaybackEnd(
                expectedSongKey: loadedSong.identityKey,
                generation: generation,
                reason: "试听结束热置换超时"
            )
        }
        hotSwapTrialEndWaitWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    @MainActor
    func hotSwapAudioTrack(with resolved: UnblockService.Resolved, for song: Song, generation: Int) {
        guard generation == self.loadGeneration,
              self.currentSong?.identityKey == song.identityKey,
              !UnblockService.isCorruptOrAntiLeechURL(resolved.url),
              let currentActivePlayer = self.player else { return }

        // 清理上一轮未完成的置换候选，避免多个候选并存
        cleanHotSwapCandidate()

        let currentSeconds = currentActivePlayer.currentTime().seconds
        let resumeAt = (currentSeconds.isFinite && currentSeconds > 0) ? currentSeconds : 0
        ATMusicLogger.shared.log("⚡️ [Hot-Swap] 开始准备无缝热置换：\(song.name) 当前进度=\(String(format: "%.1f", resumeAt))s -> 完整音轨(\(resolved.sourceTitle))", level: .info)

        // 1. 创建完整音轨的 PlayerItem 与候选 Player，交由 hotSwapCandidate 强引用持有，
        //    函数返回后依然存活，状态回调才有机会触发交接
        let (nextItem, loader) = AudioHeadBlockPreloader.shared.makePlayerItem(
            url: resolved.url,
            headers: resolved.headers,
            key: song.identityKey
        )
        nextItem.preferredForwardBufferDuration = 8.0
        let nextPlayer = AVPlayer(playerItem: nextItem)
        nextPlayer.automaticallyWaitsToMinimizeStalling = false
        nextPlayer.volume = 0 // 静音缓冲，当前 trial player 仍在发声

        let candidate = HotSwapCandidate(
            player: nextPlayer,
            item: nextItem,
            songKey: song.identityKey,
            generation: generation,
            loader: loader
        )
        self.hotSwapCandidate = candidate

        // 2. 预定位到当前播放时间并预热解码器
        if resumeAt > 0.05 {
            let seekTime = CMTime(seconds: resumeAt, preferredTimescale: 600)
            nextPlayer.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        let executeHandover = { [weak self, weak currentActivePlayer, candidate] in
            guard let self else { return }
            guard self.hotSwapCandidate === candidate, !candidate.didHandover else { return }
            guard generation == self.loadGeneration, self.currentSong?.identityKey == song.identityKey else {
                self.cleanHotSwapCandidate()
                return
            }
            candidate.didHandover = true
            candidate.executeHandover = nil
            candidate.statusObservation?.invalidate()
            candidate.playerStatusObservation?.invalidate()
            candidate.bufferObservation?.invalidate()
            self.hotSwapCandidate = nil
            self.hotSwapTrialEndWaitWorkItem?.cancel()
            self.hotSwapTrialEndWaitWorkItem = nil

            let nextPlayer = candidate.player
            let nextItem = candidate.item
            let latestSeconds = currentActivePlayer?.currentTime().seconds ?? resumeAt
            let finalResume = (latestSeconds.isFinite && latestSeconds > 0) ? latestSeconds : resumeAt
            // 精确对齐交接（build 124）：交接点必定位于候选已缓冲区间之内（下方判据
            // 与追锚逻辑保证），区间内零容差 seek 不丢缓冲、瞬时完成——旧做法拿准备
            // 时刻冻结的锚点起播（漂移 ≤1.5s 不 seek）、或 ±2s 宽容差 seek，用户实测
            // 有 1~2 秒错位；冷拉流的真因是 seek 到未缓冲位置，而非精确 seek 本身。
            // seek 完成回调里才翻转播放，回调前试听持续发声，听感同点接续。
            nextPlayer.seek(to: CMTime(seconds: finalResume, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak currentActivePlayer, candidate] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    // 平滑热切：Player B 播放并恢复音量，Player A 暂停
                    nextPlayer.volume = self.targetVolume
                    nextPlayer.playImmediately(atRate: Float(self.rate))
                    currentActivePlayer?.pause()
                    currentActivePlayer?.replaceCurrentItem(with: nil)

                    self.isHotSwapTrialActive = false
                    let notice = self.thirdPartyVIPNotice(for: song, sourceTitle: resolved.sourceTitle)
                    self.setupPlayer(
                        url: resolved.url,
                        thirdPartyVIPNotice: notice,
                        resumeAt: finalResume,
                        isThirdParty: true,
                        thirdPartyQuality: resolved.quality,
                        customHeaders: resolved.headers,
                        fromPlaybackCache: false,
                        isHotSwapTrial: false,
                        prewarmedPlayer: nextPlayer,
                        prewarmedItem: nextItem,
                        resourceLoader: candidate.loader
                    )
                    ATMusicLogger.shared.log("🚀 [Hot-Swap] 无缝热置换彻底完成！0ms中断平滑过渡至全曲：\(song.name)", level: .info)
                }
            }
        }
        candidate.executeHandover = executeHandover

        // 交接判据（build 124 改为动态对齐）：以交接瞬间试听的实时进度为目标点，
        // 候选的已缓冲区间必须覆盖目标点、且其后至少留 1.2s 余量。候选锚在准备
        // 时刻的位置、缓冲只向前生长，目标点天然落在区间内；若候选落下太多
        // （目标点已越过缓冲前沿），把静音候选重新锚定到试听实时位置继续追，
        // 而不是拿冻结锚点或宽容差硬交接（旧逻辑造成 1~2 秒错位，用户实测）。
        var candidateAnchor = resumeAt
        var lastReanchorAt = Date.distantPast
        let bufferedCoveringTrialNow: () -> Bool = {
            guard nextItem.status == .readyToPlay else { return false }
            let trialNow = currentActivePlayer.currentTime().seconds
            let target = (trialNow.isFinite && trialNow > 0) ? trialNow : resumeAt
            for range in nextItem.loadedTimeRanges {
                let timeRange = range.timeRangeValue
                let start = timeRange.start.seconds
                guard start.isFinite, timeRange.duration.seconds.isFinite else { continue }
                if start <= target + 0.25, start + timeRange.duration.seconds >= target + 1.2 { return true }
            }
            return false
        }
        let handoverIfBuffered = {
            if bufferedCoveringTrialNow() {
                DispatchQueue.main.async { candidate.executeHandover?() }
                return
            }
            // 候选落后于试听进度：静音重锚到实时位置，让缓冲在前沿重建（节流 0.8s）
            let trialNow = currentActivePlayer.currentTime().seconds
            if trialNow.isFinite, trialNow - candidateAnchor > 1.0, Date().timeIntervalSince(lastReanchorAt) > 0.8 {
                lastReanchorAt = Date()
                candidateAnchor = trialNow
                nextPlayer.seek(to: CMTime(seconds: trialNow, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
        candidate.bufferObservation = nextItem.observe(\.loadedTimeRanges, options: [.new]) { [candidate] _, _ in
            handoverIfBuffered()
        }

        candidate.statusObservation = nextItem.observe(\.status, options: [.new, .initial]) { [weak self, candidate] item, _ in
            if item.status == .readyToPlay {
                handoverIfBuffered()
            } else if item.status == .failed {
                candidate.statusObservation?.invalidate()
                candidate.itemFailed = true
                ATMusicLogger.shared.log("⚠️ [Hot-Swap] 完整音轨预热加载失败，保留当前试听播放：\(song.name)", level: .warn)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.hotSwapCandidate === candidate, candidate.trialEnded else { return }
                    self.advanceAfterFailedHotSwap(candidate: candidate, reason: "热置换音轨加载失败")
                }
            }
        }

        let targetRate = Float(self.rate)
        candidate.playerStatusObservation = nextPlayer.observe(\.status, options: [.new, .initial]) { [candidate] observedPlayer, _ in
            guard observedPlayer.status == .readyToPlay else { return }
            candidate.playerStatusObservation?.invalidate()
            observedPlayer.preroll(atRate: targetRate) { finished in
                if finished {
                    handoverIfBuffered()
                }
            }
        }

        // 兜底：观察链路万一没触发，6 秒后只要 item 已就绪就强制交接
        // （交接后的缓冲预算已单独放宽，不会立刻被判失败）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self, candidate] in
            guard let self, self.hotSwapCandidate === candidate, !candidate.didHandover, candidate.item.status == .readyToPlay else { return }
            candidate.executeHandover?()
        }
    }


    private func setupPlayer(
        url: URL,
        thirdPartyVIPNotice: ThirdPartyVIPNotice? = nil,
        resumeAt: Double = 0,
        isThirdParty: Bool = false,
        thirdPartyQuality: ThirdPartyAudioQuality? = nil,
        customHeaders: [String: String] = [:],
        qqOfficialBR: String? = nil,
        attemptedQQOfficialBRs: [String] = [],
        fromPlaybackCache: Bool = false,
        isHotSwapTrial: Bool = false,
        prewarmedPlayer: AVPlayer? = nil,
        prewarmedItem: AVPlayerItem? = nil,
        resourceLoader: AudioHeadBlockResourceLoader? = nil
    ) {
        guard ensurePlaybackAllowed(), let loadedSong = currentSong else { return }
        guard !UnblockService.isCorruptOrAntiLeechURL(url) else {
            ATMusicLogger.shared.log("🚫 setupPlayer 拒绝载入已被标记的防盗链/损坏音频 URL：\(self.playbackURLSummary(url))", level: .warn)
            AudioURLCache.shared.remove(songKey: loadedSong.identityKey)
            if fromPlaybackCache {
                MainActor.assumeIsolated { MusicCacheManager.shared.remove(song: loadedSong) }
                self.loadCurrent()
                return
            }
            if isThirdParty && self.retryThirdPartyIfNeeded(excludingHost: url.host) { return }
            self.finishUnrecoverablePlaybackFailure(song: loadedSong, reason: "解析结果为防盗链或损坏音频")
            return
        }
        let playbackGeneration = loadGeneration
        if isThirdParty {
            let quality = thirdPartyQuality ?? ThirdPartyAudioQuality.current
            activeThirdPartyQuality = quality
            activeQQOfficialBR = nil
            if let songKey = currentSong?.identityKey {
                attemptedThirdPartyQualitiesBySong[songKey, default: []].insert(quality.rawValue)
            }
        } else {
            activeThirdPartyQuality = nil
            activeQQOfficialBR = qqOfficialBR
            if let songKey = currentSong?.identityKey, !attemptedQQOfficialBRs.isEmpty {
                attemptedQQOfficialBRsBySong[songKey, default: []].formUnion(attemptedQQOfficialBRs)
            }
        }
        prepareForSystemPlayback()
        configureAudioSession()
        UIApplication.shared.beginReceivingRemoteControlEvents()
        removeCurrentObservers()
        pendingThirdPartyVIPNotice = thirdPartyVIPNotice

        let item: AVPlayerItem
        let player: AVPlayer
        var playbackHeaders: [String: String] = customHeaders

        self.isHotSwapTrialActive = isHotSwapTrial
        if isHotSwapTrial {
            self.duration = loadedSong.duration
        }

        if let prewarmedPlayer, let prewarmedItem {
            item = prewarmedItem
            player = prewarmedPlayer
            player.volume = targetVolume
            self.currentResourceLoader = resourceLoader
            item.preferredForwardBufferDuration = loadedSong.source == .synology ? 20.0 : 60.0
        } else {
            if isQQAudioHost(url.host) {
                playbackHeaders["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:80.0) Gecko/20100101 Firefox/80.0"
                playbackHeaders["Referer"] = "https://y.qq.com/"
                let cookie = QQMusicAuth.shared.cookieHeader
                if !cookie.isEmpty {
                    playbackHeaders["Cookie"] = cookie
                }
            } else if url.host?.contains("kugou.com") == true || url.host?.contains("kgimg.com") == true {
                playbackHeaders["User-Agent"] = "Android15-1070-11440-46-0-DiscoveryDRADProtocol-wifi"
                playbackHeaders["Referer"] = "https://www.kugou.com/"
                let cookie = KugouMusicAuth.shared.cookieHeader
                if !cookie.isEmpty { playbackHeaders["Cookie"] = cookie }
            }
            let (madeItem, loader) = AudioHeadBlockPreloader.shared.makePlayerItem(
                url: url,
                headers: playbackHeaders,
                key: loadedSong.identityKey
            )
            item = madeItem
            self.currentResourceLoader = loader
            item.preferredForwardBufferDuration = loadedSong.source == .synology ? 20.0 : 60.0
            player = AVPlayer(playerItem: item)
            player.volume = targetVolume
            player.automaticallyWaitsToMinimizeStalling = false
        }

        let headerKeys = playbackHeaders.keys.sorted().joined(separator: ",")
        ATMusicLogger.shared.log(
            "AVPlayer 准备播放：\(currentSong?.name ?? "?")｜URL=\(playbackURLSummary(url))｜第三方=\(isThirdParty ? "是" : "否")｜headers=\(playbackHeaders.isEmpty ? "未添加" : "已添加")｜headerKeys=\(headerKeys.isEmpty ? "无" : headerKeys)｜热备复用=\(prewarmedPlayer != nil ? "是" : "否")",
            level: .debug
        )

        let oldPlayer = self.player
        if let oldPlayer, oldPlayer !== player {
            oldPlayer.pause()
            oldPlayer.replaceCurrentItem(with: nil)
        }

        player.automaticallyWaitsToMinimizeStalling = false
        player.rate = Float(rate)
        self.player = player
        activeItemSongKey = loadedSong.identityKey

        // 写入 AudioURLCache 内存池（试听片段不写入缓存，避免污染后续播放）
        if !isHotSwapTrial {
            AudioURLCache.shared.set(
                songKey: loadedSong.identityKey,
                quality: self.playbackCacheQuality().rawValue,
                url: url,
                isPreview: false
            )
        }
        // 触发下一首静默预解析与热备
        self.preResolveNextTrackURL()
        configureEqualizer(for: item)
        playbackConfirmed = false
        itemStatusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            self.performOnMain { [weak self] in
                guard let self,
                      self.player === player,
                      self.currentSong?.identityKey == loadedSong.identityKey,
                      item.status == .failed else { return }
                self.logPlaybackFailure(
                    reason: "AVPlayerItem.status.failed",
                    item: item,
                    url: url,
                    isThirdParty: isThirdParty,
                    playbackHeaders: playbackHeaders
                )
                if fromPlaybackCache {
                    MainActor.assumeIsolated { MusicCacheManager.shared.removeCachedFile(for: loadedSong, quality: self.playbackCacheQuality()) }
                    AudioURLCache.shared.remove(songKey: loadedSong.identityKey)
                    ATMusicLogger.shared.log("播放缓存损坏，已删除并回退网络：\(loadedSong.name)", level: .debug)
                    self.loadCurrent(resumeAt: self.progress)
                    return
                }
                if isThirdParty && self.retryThirdPartyIfNeeded(excludingHost: url.host) { return }
                if !isThirdParty && self.retryQQOfficialIfNeeded() { return }
                if !isThirdParty && self.fallbackQQToThirdPartyIfNeeded() { return }
                if self.retryKugouAtStandardIfNeeded(error: item.error) { return }
                self.finishUnrecoverablePlaybackFailure(song: loadedSong, reason: "AVPlayerItem 加载失败")
            }
        }
        timeControlStatusObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            guard let self else { return }
            self.performOnMain { [weak self] in
                guard let self, self.player === player else { return }
                if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                    self.isBuffering = true
                    self.playbackStallWorkItem?.cancel()
                    let stall = DispatchWorkItem { [weak self, weak player, weak item] in
                        guard let self,
                              let player,
                              let item,
                              self.player === player,
                              player.currentItem === item,
                              self.currentSong?.identityKey == loadedSong.identityKey,
                              player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
                              !self.playbackConfirmed else { return }
                        ATMusicLogger.shared.log(
                            "播放地址长时间未开始：歌曲=\(self.currentSong?.name ?? "?")｜第三方=\(isThirdParty ? "是" : "否")｜URL=\(self.playbackURLSummary(url))",
                            level: .debug
                        )
                        if fromPlaybackCache {
                            MainActor.assumeIsolated { MusicCacheManager.shared.removeCachedFile(for: loadedSong, quality: self.playbackCacheQuality()) }
                            AudioURLCache.shared.remove(songKey: loadedSong.identityKey)
                            ATMusicLogger.shared.log("播放缓存无响应，已删除并回退网络：\(loadedSong.name)", level: .debug)
                            self.loadCurrent(resumeAt: self.progress)
                            return
                        }
                        if isThirdParty && self.retryThirdPartyIfNeeded(excludingHost: url.host) { return }
                        if !isThirdParty && self.retryQQOfficialIfNeeded() { return }
                        if !isThirdParty && self.fallbackQQToThirdPartyIfNeeded() { return }
                        if self.retryKugouAtStandardIfNeeded(error: item.error) { return }
                        self.finishUnrecoverablePlaybackFailure(
                            song: loadedSong,
                            reason: "播放地址长时间未响应"
                        )
                    }
                    self.playbackStallWorkItem = stall
                    // 热置换后的播放器要在目标位置冷拉流，给更长的缓冲预算，
                    // 避免置换刚完成就被当成“长时间未响应”判失败（2026-10-22 实证）。
                    let stallBudget: TimeInterval = prewarmedPlayer != nil ? 20 : 8
                    DispatchQueue.main.asyncAfter(deadline: .now() + stallBudget, execute: stall)
                    return
                }
                self.playbackStallWorkItem?.cancel()
                self.playbackStallWorkItem = nil
                if player.timeControlStatus == .playing {
                    // 第三方音源也要在真正进入 playing 时立刻预取下一首，
                    // 不再依赖 1.2 秒后的单一确认回调。
                    self.refreshPrefetchTarget()
                }
                guard player.timeControlStatus == .playing, !self.playbackConfirmed else { return }
                self.playbackConfirmationWorkItem?.cancel()
                let confirmation = DispatchWorkItem { [weak self, weak player, weak item] in
                    guard let self,
                          let player,
                          let item,
                          self.player === player,
                          player.currentItem === item,
                          player.timeControlStatus == .playing,
                          item.status == .readyToPlay,
                          !self.playbackConfirmed else { return }
                    if (isThirdParty || fromPlaybackCache || prewarmedPlayer != nil),
                       let itemDuration = item.duration.seconds as Double?,
                       itemDuration.isFinite,
                       itemDuration <= 20,
                       loadedSong.duration >= 45 {
                        ATMusicLogger.shared.log("🚫 拦截到防盗链/严重截断音频（时长仅 \(String(format: "%.1f", itemDuration))s，歌曲原长 \(loadedSong.duration)s），立即终止并熔断重试！", level: .warn)
                        AudioURLCache.shared.remove(songKey: loadedSong.identityKey)
                        MainActor.assumeIsolated { MusicCacheManager.shared.remove(song: loadedSong) }
                        player.pause()
                        if fromPlaybackCache || prewarmedPlayer != nil {
                            self.loadCurrent()
                            return
                        }
                        if isThirdParty && self.retryThirdPartyIfNeeded(excludingHost: url.host) { return }
                        self.finishUnrecoverablePlaybackFailure(song: loadedSong, reason: "音源返回防盗链或截断音频")
                        return
                    }
                    self.playbackConfirmed = true
                    if let song = self.currentSong {
                        ATMusicLogger.shared.log(
                            "▶ 播放成功确认：\(song.name)｜URL=\(self.playbackURLSummary(url))｜第三方=\(isThirdParty ? "是" : "否")｜itemStatus=\(self.playerItemStatusDescription(item.status))",
                            level: .info
                        )
                    }
                    self.showPendingThirdPartyVIPNoticeIfNeeded()
                    self.refreshPrefetchTarget()
                }
                self.playbackConfirmationWorkItem = confirmation
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: confirmation)
            }
        }
        if resumeAt > 0.05 {
            if prewarmedPlayer != nil {
                // 热置换交接已把播放器定位到 resumeAt 附近并起播，这里再做一次
                // 零容差精确 seek 只会打掉刚灌注的缓冲、重新冷拉流（同上实证）。
                progress = resumeAt
            } else {
                let seekTime = CMTime(seconds: resumeAt, preferredTimescale: 600)
                player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
                progress = resumeAt
            }
        }
        player.playImmediately(atRate: Float(rate))
        isPlaying = true
        isBuffering = false
        loadFailed = false
        // 开始当前歌曲后即可后台解析/下载下一首；MusicCacheManager 会自动去重。
        refreshPrefetchTarget()
        // 修复：播放次数原先在 loadCurrent 里预计数，URL 加载失败/手动重试也会 +1，
        // 导致统计异常；改为真正开始播放时计数，且同一首歌同一会话只计一次。
        if let song = currentSong, lastCountedSongID != song.identityKey {
            bumpPlayCount(song)
            lastCountedSongID = song.identityKey
        }
        lastListeningProgress = nil
        currentIsThirdParty = isThirdParty
        currentFromPlaybackCache = fromPlaybackCache
        currentFromStandby = prewarmedPlayer != nil
        currentPlaybackURL = url
        if isInBackground && isPlaying {
            backgroundPlayDate = Date()
            setupBackgroundPrewarmTrigger(for: item)
        }
        attachTimeObserverIfNeeded()
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            guard let self else { return }
            if self.isHotSwapTrialActive {
                ATMusicLogger.shared.log("⚠️ 试听音频播放完毕但全曲热置换仍在进行中，暂时保持等待...", level: .info)
                self.handleTrialPlaybackEnded(loadedSong: loadedSong, generation: playbackGeneration)
                return
            }
            if (fromPlaybackCache || prewarmedPlayer != nil),
               loadedSong.duration >= 45,
               self.corruptCacheHealGeneration[loadedSong.identityKey] != playbackGeneration {
                let playedSeconds = self.player?.currentTime().seconds ?? self.progress
                if playedSeconds.isFinite, playedSeconds < 2 {
                    // 本地缓存/热备的歌开播不到 2 秒就"播完"：文件是残缺的坏源，
                    // 删缓存后把本首歌重新走网络解析，而不是无声跳到下一首
                    self.corruptCacheHealGeneration[loadedSong.identityKey] = playbackGeneration
                    AudioURLCache.shared.remove(songKey: loadedSong.identityKey)
                    MainActor.assumeIsolated { MusicCacheManager.shared.remove(song: loadedSong) }
                    ATMusicLogger.shared.log("🧹 本地音频异常短播（\(String(format: "%.1f", playedSeconds))s 即结束），判定缓存坏源：删缓存并重新解析本首：\(loadedSong.name)", level: .warn)
                    self.loadCurrent()
                    return
                }
            }
            if self.playMode == .repeatOne {
                self.restartCurrent()
            } else {
                self.advanceAfterPlaybackEnd(
                    expectedSongKey: loadedSong.identityKey,
                    generation: playbackGeneration,
                    reason: "AVPlayerItemDidPlayToEndTime"
                )
            }
        }
        failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            guard let self,
                  self.player?.currentItem === item,
                  self.currentSong?.identityKey == loadedSong.identityKey else { return }
            self.logPlaybackFailure(
                reason: "AVPlayerItemFailedToPlayToEndTime",
                item: item,
                url: url,
                isThirdParty: isThirdParty,
                playbackHeaders: playbackHeaders
            )
            if fromPlaybackCache {
                MainActor.assumeIsolated { MusicCacheManager.shared.removeCachedFile(for: loadedSong, quality: self.playbackCacheQuality()) }
                AudioURLCache.shared.remove(songKey: loadedSong.identityKey)
                ATMusicLogger.shared.log("播放缓存中断，已删除并回退网络：\(loadedSong.name)", level: .debug)
                self.loadCurrent(resumeAt: self.progress)
                return
            }
            if !isThirdParty && self.retryQQOfficialIfNeeded() { return }
            if !isThirdParty && self.fallbackQQToThirdPartyIfNeeded() { return }
            if isThirdParty && self.retryThirdPartyIfNeeded(excludingHost: url.host) { return }
            if self.retryKugouAtStandardIfNeeded(error: item.error) { return }
            self.finishUnrecoverablePlaybackFailure(song: loadedSong, reason: "播放中断失败")
        }
        updateNowPlaying()
    }

    /// AVFoundation KVO callbacks are not guaranteed to arrive on the main
    /// thread. Serialize callbacks that touch ObservableObject state before
    /// reading or mutating the player model.
    private func performOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private func finishUnrecoverablePlaybackFailure(
        song: Song?,
        reason: String,
        message: String? = nil
    ) {
        loadFailed = true
        isBuffering = false
        isPlaying = false
        guard let failedSong = song,
              currentSong?.identityKey == failedSong.identityKey,
              finalizedFailureSongKey != failedSong.identityKey else {
            return
        }
        finalizedFailureSongKey = failedSong.identityKey
        if !attemptedSourceFallbacks.contains(failedSong.identityKey) {
            attemptedSourceFallbacks.insert(failedSong.identityKey)
            let occupied = Set(queue.map(\.identityKey))
            if let alternative = UnifiedSongStore.shared.alternateSongs(for: failedSong)
                .first(where: { !occupied.contains($0.identityKey) && !attemptedSourceFallbacks.contains($0.identityKey) }) {
                queue[currentIndex] = alternative
                loadFailed = false
                isBuffering = true
                ATMusicLogger.shared.log("当前来源失败，切换统一库备用来源：\(failedSong.name) -> \(alternative.source.rawValue)", level: .info)
                Task { @MainActor in
                    ToastCenter.shared.show("当前音源不可用，正在切换备用来源", duration: 2)
                }
                loadCurrent()
                return
            }
        }
        let shouldAutoSkip = defaults.object(forKey: autoSkipOnFailureKey) as? Bool ?? true
        let failureMessage: String
        if shouldAutoSkip && queue.count > 1 {
            failureMessage = atmusicLocalized(
                "播放失败，2秒后自动切换到下一首",
                "Playback failed. The next song will start in 2 seconds."
            )
        } else {
            failureMessage = message ?? atmusicLocalized(
                "播放失败，请稍后重试或切换其他歌曲",
                "Playback failed. Please try again later or switch songs."
            )
        }
        Task { @MainActor in
            ToastCenter.shared.show(failureMessage, duration: 3)
        }
        guard shouldAutoSkip, queue.count > 1 else { return }
        ATMusicLogger.shared.log("播放失败自动下一首：\(failedSong.name)｜原因=\(reason)", level: .info)
        let failedSongKey = failedSong.identityKey
        let failedGeneration = loadGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.loadGeneration == failedGeneration,
                  self.currentSong?.identityKey == failedSongKey,
                  self.finalizedFailureSongKey == failedSongKey else {
                return
            }
            self.failureAutoSkipWorkItem = nil
            self.next(manual: false)
        }
        failureAutoSkipWorkItem?.cancel()
        failureAutoSkipWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: workItem)
    }

    private func ensurePlaybackAllowed() -> Bool {
        return true
    }

    /// 统一按当前歌曲平台重新解析第三方地址，失败重试时不跨平台匹配同名歌曲。
    private func resolveThirdParty(
        song: Song,
        quality: ThirdPartyAudioQuality,
        strict: Bool,
        excludedHosts: Set<String> = []
    ) async -> UnblockService.Resolved? {
        guard externalSourcesEnabled else { return nil }
        switch song.source {
        case .netease:
            return await UnblockService.resolve(
                name: song.name,
                artists: song.artists,
                neteaseID: song.id,
                songSource: .netease,
                quality: quality,
                strict: strict,
                excludedHosts: excludedHosts
            )
        case .qq:
            return await qqFallback(
                song: song,
                quality: ATMusicAudioQuality.current,
                thirdPartyQuality: quality,
                enableUnblock: externalSourcesEnabled,
                strict: strict,
                excludedHosts: excludedHosts
            ).1
        case .kugou:
            let kugouID = song.kugouHash ?? song.kugouAlbumAudioId
            guard let kugouID, !kugouID.isEmpty else { return nil }
            return await UnblockService.resolve(
                name: song.name,
                artists: song.artists,
                neteaseID: 0,
                songSource: .kugou,
                kugouID: kugouID,
                quality: quality,
                excludedHosts: excludedHosts
            )
        case .local:
            return nil
        case .synology, .subsonic, .jellyfin, .webdav:
            return nil
        }
    }

    private func isQQAudioHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host.contains("qq.com")
            || host.contains("qqmusic")
            || host.contains("ptqqmusic")
    }

    private func playbackURLSummary(_ url: URL) -> String {
        let host = url.host ?? "?"
        let path = url.path.isEmpty ? "/" : url.path
        let shortPath = path.count > 72 ? String(path.prefix(72)) + "..." : path
        return "\(host)\(shortPath)"
    }

    private func playerItemStatusDescription(_ status: AVPlayerItem.Status) -> String {
        switch status {
        case .unknown: return "unknown"
        case .readyToPlay: return "readyToPlay"
        case .failed: return "failed"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    private func sanitizedLogURI(_ rawURI: String?) -> String {
        guard let rawURI, !rawURI.isEmpty else { return "?" }
        if var components = URLComponents(string: rawURI) {
            components.query = nil
            components.fragment = nil
            if let host = components.host {
                let path = components.path.isEmpty ? "/" : components.path
                let shortPath = path.count > 72 ? String(path.prefix(72)) + "..." : path
                return "\(host)\(shortPath)"
            }
            return components.string.map { String($0.prefix(96)) } ?? String(rawURI.prefix(96))
        }
        return String(rawURI.prefix(96))
    }

    private func logPlaybackFailure(
        reason: String,
        item: AVPlayerItem,
        url: URL,
        isThirdParty: Bool,
        playbackHeaders: [String: String]
    ) {
        let error = item.error
        let nsError = error as NSError?
        let errorDescription = error?.localizedDescription ?? "未知错误"
        let errorCode = nsError.map { "\($0.domain):\($0.code)" } ?? "?"
        let eventDetails = item.errorLog()?.events.map { event in
            [
                "domain=\(event.errorDomain)",
                "code=\(event.errorStatusCode)",
                "uri=\(sanitizedLogURI(event.uri))",
                "comment=\(event.errorComment ?? "?")"
            ].joined(separator: " ")
        }.joined(separator: " | ") ?? ""
        let headerKeys = playbackHeaders.keys.sorted().joined(separator: ",")
        ATMusicLogger.shared.log(
            "播放地址加载失败：原因=\(reason)"
                + "｜错误=\(errorDescription)"
                + "｜URL=\(playbackURLSummary(url))"
                + "｜第三方=\(isThirdParty ? "是" : "否")"
                + "｜headers=\(playbackHeaders.isEmpty ? "未添加" : "已添加")"
                + "｜headerKeys=\(headerKeys.isEmpty ? "无" : headerKeys)"
                + "｜itemStatus=\(playerItemStatusDescription(item.status))"
                + "｜NSError=\(errorCode)"
                + "｜AVErrorLog=\(eventDetails.isEmpty ? "无" : eventDetails)",
            level: .error
        )
    }

    private func removeCurrentObservers() {
        detachTimeObserver()
        removeBackgroundBoundaryObserver()
        currentPlaybackURL = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        if let failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
        }
        failureObserver = nil
        itemStatusObserver = nil
        timeControlStatusObserver = nil
        playbackConfirmationWorkItem?.cancel()
        playbackConfirmationWorkItem = nil
        failureAutoSkipWorkItem?.cancel()
        failureAutoSkipWorkItem = nil
        playbackStallWorkItem?.cancel()
        playbackStallWorkItem = nil
        playbackEndFallbackWorkItem?.cancel()
        playbackEndFallbackWorkItem = nil
        playbackConfirmed = false
        pendingThirdPartyVIPNotice = nil
        lastPublishedProgress = -1
    }

    /// 均衡器通过 AVAudioMix 的音频处理 tap 工作，不改动 URL、队列或播放器状态。
    /// 曲目切换和开关均复用这里的挂载流程，避免让网络请求跑到主线程。
    private func applyEqualizerToCurrentItem() {
        guard let item = player?.currentItem else { return }
        configureEqualizer(for: item)
    }

    private func configureEqualizer(for item: AVPlayerItem) {
        guard ATMusicEqualizer.shared.isEnabled else {
            item.audioMix = nil
            return
        }

        Task { [weak self, weak item] in
            guard let self, let item else { return }
            do {
                let tracks = try await item.asset.load(.tracks)
                guard let track = tracks.first(where: { $0.mediaType == .audio }),
                      let mix = ATMusicEqualizer.shared.makeAudioMix(for: track) else { return }
                self.performOnMain { [weak self, weak item] in
                    guard let self,
                          let item,
                          self.player?.currentItem === item,
                          ATMusicEqualizer.shared.isEnabled else { return }
                    item.audioMix = mix
                }
            } catch {
                ATMusicLogger.shared.log("均衡器音轨加载失败：\(error.localizedDescription)", level: .warn)
            }
        }
    }

    private func thirdPartyVIPNotice(for song: Song, sourceTitle: String) -> ThirdPartyVIPNotice? {
        guard song.isVIP else { return nil }
        guard defaults.object(forKey: thirdPartyVIPNoticeKey) as? Bool ?? true else { return nil }
        guard !hasMembership(for: song.source) else { return nil }
        let sourceName = sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = sourceName.isEmpty ? "第三方音源" : "第三方音源「\(sourceName)」"
        return ThirdPartyVIPNotice(
            songKey: song.identityKey,
            message: "当前账号未识别到对应会员，《\(song.name)》已通过\(suffix)播放"
        )
    }

    private func showPendingThirdPartyVIPNoticeIfNeeded() {
        guard let notice = pendingThirdPartyVIPNotice else { return }
        guard currentSong?.identityKey == notice.songKey else {
            pendingThirdPartyVIPNotice = nil
            return
        }
        guard defaults.object(forKey: thirdPartyVIPNoticeKey) as? Bool ?? true else {
            pendingThirdPartyVIPNotice = nil
            return
        }
        Task { @MainActor in
            ToastCenter.shared.show(notice.message)
        }
        ATMusicLogger.shared.log("第三方音源会员歌提醒：\(notice.message)", level: .info)
        pendingThirdPartyVIPNotice = nil
    }

    private func hasMembership(for source: SongSource) -> Bool {
        switch source {
        case .qq:
            return QQMusicAuth.shared.vipBadge != nil
        case .kugou:
            return KugouMusicAuth.shared.vipBadge != nil
        case .local:
            return true
        case .netease:
            guard let data = defaults.data(forKey: "atmusic.user"),
                  let user = try? JSONDecoder().decode(NetEaseUser.self, from: data) else {
                return false
            }
            return user.vipBadge != nil
        case .synology, .subsonic, .jellyfin, .webdav:
            return true
        }
    }

    private func configureAudioSession() {
        if Self.applyAudioMixPreference(mixesWithOthers) {
            sessionConfigured = true
        } else {
            sessionConfigured = false
        }
    }

    @discardableResult
    static func applyAudioMixPreference(_ mixesWithOthers: Bool) -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            // 「与其他音频同时播放」开关：开启时 mixWithOthers，打开其他音频软件也能继续播放；关闭则自动暂停
            if mixesWithOthers {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            } else {
                try session.setCategory(.playback, mode: .default)
            }
            try session.setActive(true)
            return true
        } catch {
            ATMusicLogger.shared.log("音频会话配置失败：\(error.localizedDescription)", level: .error)
            return false
        }
    }

    /// 延后初始化系统音频服务，降低自签安装后首次启动时的兼容性风险。
    /// 播放真正开始前由 setupPlayer 兜底调用，因此不会影响播放器功能。
    private func prepareForSystemPlayback() {
        guard !systemPlaybackPrepared else { return }
        systemPlaybackPrepared = true
        observeInterruptions()
        observeRouteChanges()
        setupRemoteCommands()
        WatchSyncService.shared.configure(player: self)
    }

    private func observeRouteChanges() {
        guard !routeObserverInstalled else { return }
        routeObserverInstalled = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    /// 输出设备变化（插拔耳机 / 切换扬声器 / 来电路由等）后重新激活会话，避免播放无声
    @objc private func handleRouteChange(_ notification: Notification) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.handleRouteChange(notification)
            }
            return
        }
        sessionConfigured = false
        configureAudioSession()
        if isPlaying, player?.timeControlStatus != .playing {
            player?.playImmediately(atRate: Float(rate))
        }
    }

    // MARK: - 来电/中断处理

    private func observeInterruptions() {
        guard !interruptionObserverInstalled else { return }
        interruptionObserverInstalled = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.handleInterruption(notification)
            }
            return
        }
        guard let info = notification.userInfo,
              let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began:
            wasPlayingBeforeInterruption = isPlaying
            // 开启「与其他音频同时播放」时，不被其他 App 音频中断，保持继续播放
            guard !mixesWithOthers else { return }
            player?.pause()
            isPlaying = false
        case .ended:
            // 中断结束后系统可能停用了音频会话，重新激活避免无声
            sessionConfigured = false
            configureAudioSession()
            wasPlayingBeforeInterruption = false
            isPlaying = false
            updateNowPlaying()
        @unknown default:
            break
        }
    }

    // MARK: - 播放历史与统计

    private func pushHistory(_ song: Song) {
        history.removeAll { $0.identityKey == song.identityKey }
        history.insert(song, at: 0)
        if history.count > 50 {
            history = Array(history.prefix(50))
        }
        if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: historyKey)
        }
    }

    private func loadHistory() {
        guard let data = defaults.data(forKey: historyKey),
              let saved = try? JSONDecoder().decode([Song].self, from: data) else { return }
        history = saved
    }

    private func bumpPlayCount(_ song: Song) {
        playCounts[song.identityKey, default: 0] += 1
        if let data = try? JSONEncoder().encode(playCounts) {
            defaults.set(data, forKey: countsKey)
        }
    }

    private func loadPlayCounts() {
        guard let data = defaults.data(forKey: countsKey),
              let saved = try? JSONDecoder().decode([String: Int].self, from: data) else { return }
        playCounts = saved
    }

    private func savePersistedPlaybackState() {
        guard !queue.isEmpty, queue.indices.contains(currentIndex) else {
            defaults.removeObject(forKey: playbackStateKey)
            return
        }
        let state = PersistedPlaybackState(
            queue: queue,
            currentIndex: currentIndex,
            progress: progress,
            duration: duration,
            savedAt: Date()
        )
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: playbackStateKey)
        }
    }

    private func restorePersistedPlaybackState() {
        guard let data = defaults.data(forKey: playbackStateKey),
              let saved = try? JSONDecoder().decode(PersistedPlaybackState.self, from: data),
              !saved.queue.isEmpty else { return }
        queue = saved.queue
        currentIndex = min(max(saved.currentIndex, 0), saved.queue.count - 1)
        duration = max(saved.duration, currentSong?.duration ?? 0)
        progress = max(0, min(saved.progress, max(duration, currentSong?.duration ?? 0)))
        isPlaying = false
        isBuffering = false
        loadFailed = false
        buildPlayOrder()
    }

    /// 听歌排行：按播放次数排序的前几首
    var topPlayed: [(song: Song, count: Int)] {
        var result: [(song: Song, count: Int)] = []
        for (key, count) in playCounts {
            if let song = history.first(where: { $0.identityKey == key }) {
                result.append((song, count))
            }
        }
        return result.sorted { $0.count > $1.count }.prefix(8).map { $0 }
    }

    // MARK: - 前后台生命周期与功耗优化

    private func handleDidEnterBackground() {
        isInBackground = true
        recordBackgroundPlaybackDurationIfNeeded()
        flushListeningSeconds()
        if isPlaying {
            backgroundPlayDate = Date()
        }
        savePersistedPlaybackState()
        updateNowPlaying()
        detachTimeObserver()
        if let item = player?.currentItem {
            setupBackgroundPrewarmTrigger(for: item)
        }
    }

    private func handleWillEnterForeground() {
        isInBackground = false
        removeBackgroundBoundaryObserver()
        recordBackgroundPlaybackDurationIfNeeded()

        if let player = self.player {
            let currentSec = player.currentTime().seconds
            if currentSec.isFinite {
                progress = currentSec
                lastPublishedProgress = currentSec
                lastListeningProgress = currentSec
            }
            if let itemDuration = player.currentItem?.duration.seconds, itemDuration.isFinite, itemDuration > 0 {
                duration = itemDuration
            }
        }
        attachTimeObserverIfNeeded()
        updateNowPlaying()
    }

    private func handleWillTerminate() {
        recordBackgroundPlaybackDurationIfNeeded()
        flushListeningSeconds()
        savePersistedPlaybackState()
    }

    private func recordBackgroundPlaybackDurationIfNeeded() {
        if let start = backgroundPlayDate {
            let elapsed = Date().timeIntervalSince(start)
            if elapsed > 0 {
                listeningSeconds += Int(elapsed)
                defaults.set(listeningSeconds, forKey: listeningSecondsKey)
            }
            backgroundPlayDate = nil
        }
    }

    func flushListeningSeconds() {
        if pendingListeningSeconds >= 1.0 {
            let wholeSeconds = Int(pendingListeningSeconds)
            pendingListeningSeconds -= Double(wholeSeconds)
            listeningSeconds += wholeSeconds
        }
        defaults.set(listeningSeconds, forKey: listeningSecondsKey)
    }

    private func detachTimeObserver() {
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }

    private func setupBackgroundPrewarmTrigger(for item: AVPlayerItem) {
        removeBackgroundBoundaryObserver()
        guard queue.count > 1, playMode != .repeatOne else { return }
        let durationSec = item.duration.seconds
        guard durationSec.isFinite, durationSec > 20 else { return }
        let triggerSec = max(10, durationSec * 0.7)
        let triggerTime = NSValue(time: CMTime(seconds: triggerSec, preferredTimescale: 600))
        backgroundBoundaryObserver = player?.addBoundaryTimeObserver(forTimes: [triggerTime], queue: .main) { [weak self] in
            guard let self, self.isInBackground, self.standbyPlayback == nil else { return }
            ATMusicLogger.shared.log("🌙 后台节能单次边界触发：提前预热下一首曲目", level: .info)
            self.preResolveNextTrackURL()
            self.removeBackgroundBoundaryObserver()
        }
    }

    private func removeBackgroundBoundaryObserver() {
        if let observer = backgroundBoundaryObserver {
            player?.removeTimeObserver(observer)
            backgroundBoundaryObserver = nil
        }
    }

    private func attachTimeObserverIfNeeded() {
        guard !isInBackground, let player = self.player, timeObserver == nil else { return }
        let isThirdParty = currentIsThirdParty
        let fromPlaybackCache = currentFromPlaybackCache
        let fromStandby = currentFromStandby
        let playbackURL = currentPlaybackURL
        let playbackGeneration = loadGeneration

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self, let player = self.player else { return }
            guard self.loadGeneration == playbackGeneration else { return }
            if time.seconds.isFinite {
                if let previous = self.lastListeningProgress,
                   self.isPlaying,
                   player.timeControlStatus == .playing {
                    let elapsed = time.seconds - previous
                    if elapsed > 0, elapsed < 0.6 {
                        self.pendingListeningSeconds += elapsed
                        if self.pendingListeningSeconds >= 5 {
                            let wholeSeconds = Int(self.pendingListeningSeconds)
                            self.pendingListeningSeconds -= Double(wholeSeconds)
                            self.listeningSeconds += wholeSeconds
                        }
                    }
                }
                self.lastListeningProgress = time.seconds
                if abs(time.seconds - self.lastPublishedProgress) >= 0.25 {
                    self.lastPublishedProgress = time.seconds
                    self.progress = time.seconds
                }
            }
            if let itemDuration = player.currentItem?.duration, itemDuration.isNumeric {
                let seconds = itemDuration.seconds
                if seconds.isFinite {
                    if let loadedSong = self.currentSong,
                       (isThirdParty || fromPlaybackCache || fromStandby),
                       seconds <= 20,
                       loadedSong.duration >= 45 {
                        ATMusicLogger.shared.log("🚫 播放中拦截到防盗链/截断音频（时长仅 \(String(format: "%.1f", seconds))s，原歌曲为 \(loadedSong.duration)s），立即终止并熔断重试！", level: .warn)
                        AudioURLCache.shared.remove(songKey: loadedSong.identityKey)
                        MainActor.assumeIsolated { MusicCacheManager.shared.remove(song: loadedSong) }
                        player.pause()
                        if fromPlaybackCache || fromStandby {
                            self.loadCurrent()
                            return
                        }
                        if isThirdParty, let host = playbackURL?.host, self.retryThirdPartyIfNeeded(excludingHost: host) { return }
                        self.finishUnrecoverablePlaybackFailure(song: loadedSong, reason: "音源返回防盗链或截断音频")
                        return
                    }
                    if !self.isHotSwapTrialActive {
                        if abs(seconds - self.duration) > 0.25 {
                            self.duration = seconds
                        }
                    }
                }
            }
            if isThirdParty,
               self.playMode != .repeatOne,
               self.queue.count > 1,
               let item = player.currentItem,
               let itemDuration = item.duration as CMTime?,
               itemDuration.isNumeric,
               itemDuration.seconds.isFinite,
               itemDuration.seconds > 1,
               time.seconds.isFinite,
               time.seconds >= itemDuration.seconds - 0.65,
               let songKey = self.currentSong?.identityKey {
                self.schedulePlaybackEndFallback(
                    player: player,
                    item: item,
                    songKey: songKey,
                    generation: playbackGeneration
                )
            }

            // 🚀 当前歌曲播放进度超过 70% 时，保障热备播放器 (Player B) 预热完成
            if self.queue.count > 1,
               self.playMode != .repeatOne,
               let itemDuration = player.currentItem?.duration,
               itemDuration.isNumeric,
               itemDuration.seconds.isFinite,
               itemDuration.seconds > 10,
               time.seconds.isFinite,
               time.seconds >= itemDuration.seconds * 0.7,
               self.standbyPlayback == nil,
               self.preResolvingSongKey == nil {
                self.preResolveNextTrackURL()
            }

            let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            if waiting != self.isBuffering {
                self.isBuffering = waiting
            }
        }
    }

    // MARK: - 系统正在播放

    static func makePlayerItem(url: URL, headers: [String: String]) -> AVPlayerItem {
        guard !headers.isEmpty, url.scheme?.hasPrefix("http") == true else {
            return AVPlayerItem(url: url)
        }
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        return AVPlayerItem(asset: asset)
    }

    private func updateNowPlaying() {
        guard let song = currentSong else { return }
        let validDuration: Double
        if duration.isFinite && !duration.isNaN && duration > 0 {
            validDuration = duration
        } else if song.duration.isFinite && !song.duration.isNaN && song.duration > 0 {
            validDuration = song.duration
        } else {
            validDuration = 0
        }
        let validProgress: Double
        if progress.isFinite && !progress.isNaN && progress >= 0 {
            validProgress = progress
        } else {
            validProgress = 0
        }
        let validRate: Double
        if rate.isFinite && !rate.isNaN && rate >= 0 {
            validRate = isPlaying ? rate : 0.0
        } else {
            validRate = isPlaying ? 1.0 : 0.0
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.name,
            MPMediaItemPropertyArtist: song.artists,
            MPMediaItemPropertyAlbumTitle: song.album,
            MPMediaItemPropertyPlaybackDuration: validDuration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: validProgress,
            MPNowPlayingInfoPropertyPlaybackRate: validRate,
        ]
        if let artworkURL = song.coverURL {
            let artworkKey = song.identityKey + "|" + artworkURL.absoluteString
            if let cached = Self.nowPlayingArtworkCache.object(forKey: artworkURL as NSURL),
               let artwork = Self.nowPlayingArtwork(cached) {
                info[MPMediaItemPropertyArtwork] = artwork
            } else if lastNowPlayingArtworkKey != artworkKey {
                lastNowPlayingArtworkKey = artworkKey
                loadNowPlayingArtwork(song: song, key: artworkKey, url: artworkURL)
            } else if let existing = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] {
                // 封面正在后台加载（或刚加载完）：同首歌的进度/状态刷新不清空已设置的封面。
                info[MPMediaItemPropertyArtwork] = existing
            }
        } else {
            lastNowPlayingArtworkKey = nil
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        WatchSyncService.shared.syncCurrentPlaybackState()
        syncRemoteLikeCommandState()
    }

    /// 使用原始封面尺寸响应系统的多个请求，锁屏和控制中心就能拿到足够大的方形 artwork。
    private static func nowPlayingArtwork(_ image: UIImage) -> MPMediaItemArtwork? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        return MPMediaItemArtwork(boundsSize: image.size) { requestedSize in
            guard requestedSize.width > 0, requestedSize.height > 0 else { return image }
            return image
        }
    }

    private func loadNowPlayingArtwork(song: Song, key: String, url: URL) {
        let resolved = ManagedAudioPath.resolveFileURL(url) ?? url
        Task.detached(priority: .utility) { [weak self] in
            var image: UIImage?
            if resolved.isFileURL {
                if let cached = ATMusicImageFileCache.image(at: resolved.path) {
                    image = cached
                } else if let img = UIImage(contentsOfFile: resolved.path) {
                    image = img
                }
            } else {
                for _ in 0..<2 {
                    var request = URLRequest(url: resolved)
                    request.timeoutInterval = 12
                    request.cachePolicy = .returnCacheDataElseLoad
                    request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
                    if let (data, response) = try? await URLSession.shared.data(for: request),
                       let http = response as? HTTPURLResponse,
                       (200..<300).contains(http.statusCode),
                       let img = UIImage(data: data) {
                        image = img
                        break
                    }
                }
            }
            guard let image else {
                await MainActor.run { [weak self] in
                    // 封面加载失败时解除 key 锁定，使得重试或后续状态更新能够再次尝试加载封面
                    if self?.lastNowPlayingArtworkKey == key {
                        self?.lastNowPlayingArtworkKey = nil
                    }
                }
                return
            }

            Self.nowPlayingArtworkCache.setObject(image, forKey: url as NSURL)
            Self.nowPlayingArtworkCache.setObject(image, forKey: resolved as NSURL)
            await MainActor.run {
                guard let self,
                      self.currentSong?.identityKey == song.identityKey,
                      self.lastNowPlayingArtworkKey == key else { return }
                var updated = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                if let art = Self.nowPlayingArtwork(image) {
                    updated[MPMediaItemPropertyArtwork] = art
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = updated
                }
            }
        }
    }

    /// 锁屏/控制中心星标与 App 内红心联动：星标激活态 = 当前歌曲的红心状态（isSongLiked，与红心图标同源）。
    /// 切歌/刷新 NowPlaying、收藏变化通知、锁屏点星后都会走到这里对齐。
    private func syncRemoteLikeCommandState() {
        let center = MPRemoteCommandCenter.shared()
        guard let song = currentSong else {
            center.likeCommand.isActive = false
            return
        }
        center.likeCommand.isActive = FavoritesStore.shared.isSongLiked(song)
    }

    private func setupRemoteCommands() {
        guard !remoteCommandsInstalled else { return }
        remoteCommandsInstalled = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.performOnMain { [weak self] in
                guard let self else { return }
                guard self.ensurePlaybackAllowed() else { return }
                self.player?.playImmediately(atRate: Float(self.rate))
                self.isPlaying = true
                if self.isInBackground {
                    self.backgroundPlayDate = Date()
                }
                self.savePersistedPlaybackState()
                self.updateNowPlaying()
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.performOnMain { [weak self] in
                guard let self else { return }
                self.player?.pause()
                self.isPlaying = false
                self.recordBackgroundPlaybackDurationIfNeeded()
                self.flushListeningSeconds()
                self.savePersistedPlaybackState()
                self.updateNowPlaying()
            }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.performOnMain { [weak self] in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.performOnMain { [weak self] in self?.previous() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.performOnMain { [weak self] in self?.togglePlayPause() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.performOnMain { [weak self] in self?.seek(to: event.positionTime) }
            return .success
        }
        center.likeCommand.isEnabled = true
        center.likeCommand.localizedTitle = "收藏"
        center.likeCommand.addTarget { [weak self] _ in
            self?.performOnMain { [weak self] in
                guard let song = self?.currentSong else { return }
                Task {
                    // 与 App 内红心完全一致的动作（统一收藏入口），状态变化经通知回同步星标激活态。
                    await FavoritesStore.shared.toggleFavorite(song)
                }
            }
            return .success
        }
        // 锁屏/控制中心显示“上一首 / 下一首”，不启用 15 秒快进快退。
        // （skipForwardCommand/skipBackwardCommand 默认关闭；保留 next/previous）
    }

    // MARK: - 与其他音频同时播放

    /// 与其他 App 音频混合播放。默认关闭，让系统把 AT Music 作为主播放 App 显示到锁屏/灵动岛。
    var mixesWithOthers: Bool {
        get { defaults.object(forKey: audioMixKey) as? Bool ?? false }
        set {
            defaults.set(newValue, forKey: audioMixKey)
            sessionConfigured = false
            configureAudioSession()
        }
    }

}


// MARK: - 音频首包数据块（128KB Head-Block）预加载器与自定义资源加载器

final class AudioHeadBlockPreloader: NSObject {
    static let shared = AudioHeadBlockPreloader()

    struct HeadBlockRecord {
        let data: Data
        let totalLength: Int64
        let mimeType: String
        let timestamp: Date
    }

    private let memoryCache = NSCache<NSString, NSData>()
    private var metaCache: [String: (totalLength: Int64, mimeType: String)] = [:]
    private let metaLock = NSLock()

    private let session: URLSession
    private let cacheDirectory: URL
    private let fm = FileManager.default

    private var activeTasks: [String: Task<Void, Never>] = [:]
    private let taskLock = NSLock()

    private override init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 4.0
        config.timeoutIntervalForResource = 6.0
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)

        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.cacheDirectory = caches.appendingPathComponent("ATMusicHeadBlocks", isDirectory: true)
        try? fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        super.init()
    }

    /// 预拉取前 128KB (131,072 字节)
    func preloadHeadBlock(for url: URL, headers: [String: String] = [:], key: String) {
        guard url.scheme?.hasPrefix("http") == true else { return }
        // 群晖 NAS 音频直链与大音频流由 AVPlayer 硬件解码流式缓冲，不进行 HeadBlock 拦截以避免浪费家庭网络上行带宽
        guard !url.absoluteString.contains("/AudioStation/") && !url.absoluteString.contains("stream.cgi") else { return }
        guard !UnblockService.isCorruptOrAntiLeechURL(url) else { return }

        if hasHeadBlock(for: key) { return }

        taskLock.lock()
        if activeTasks[key] != nil {
            taskLock.unlock()
            return
        }
        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            defer {
                self.taskLock.lock()
                self.activeTasks.removeValue(forKey: key)
                self.taskLock.unlock()
            }
            await self.fetchHeadBlock(url: url, headers: headers, key: key)
        }
        activeTasks[key] = task
        taskLock.unlock()
    }

    private func fetchHeadBlock(url: URL, headers: [String: String], key: String) async {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("bytes=0-131071", forHTTPHeaderField: "Range")
        req.timeoutInterval = 3.5
        for (k, v) in headers {
            req.setValue(v, forHTTPHeaderField: k)
        }

        let startTime = Date()
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse,
              (http.statusCode == 200 || http.statusCode == 206),
              data.count >= 4096 else {
            return
        }

        var totalLength: Int64 = -1
        if let rangeHeader = http.value(forHTTPHeaderField: "Content-Range"),
           let slash = rangeHeader.lastIndex(of: "/") {
            let totalStr = rangeHeader[rangeHeader.index(after: slash)...].trimmingCharacters(in: .whitespaces)
            totalLength = Int64(totalStr) ?? -1
        }
        if totalLength <= 0 {
            totalLength = http.expectedContentLength
        }

        let mimeType = http.mimeType ?? "audio/mpeg"
        let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)

        memoryCache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        metaLock.lock()
        metaCache[key] = (totalLength: totalLength, mimeType: mimeType)
        metaLock.unlock()

        let diskURL = cacheDirectory.appendingPathComponent(Self.sanitizeFilename(key) + ".head")
        try? data.write(to: diskURL, options: .atomic)

        ATMusicLogger.shared.log("⚡️ [Head-Block] 128KB 首包预抓取完成：\(key) 大小=\(data.count) 耗时=\(elapsed)ms 格式=\(mimeType)", level: .debug)
    }

    func hasHeadBlock(for key: String) -> Bool {
        if memoryCache.object(forKey: key as NSString) != nil {
            return true
        }
        let diskURL = cacheDirectory.appendingPathComponent(Self.sanitizeFilename(key) + ".head")
        return fm.fileExists(atPath: diskURL.path)
    }

    func getHeadBlock(for key: String) -> HeadBlockRecord? {
        metaLock.lock()
        let meta = metaCache[key]
        metaLock.unlock()

        if let memData = memoryCache.object(forKey: key as NSString) as Data? {
            return HeadBlockRecord(
                data: memData,
                totalLength: meta?.totalLength ?? Int64(memData.count * 80),
                mimeType: meta?.mimeType ?? "audio/mpeg",
                timestamp: Date()
            )
        }

        let diskURL = cacheDirectory.appendingPathComponent(Self.sanitizeFilename(key) + ".head")
        if let diskData = try? Data(contentsOf: diskURL) {
            memoryCache.setObject(diskData as NSData, forKey: key as NSString, cost: diskData.count)
            return HeadBlockRecord(
                data: diskData,
                totalLength: meta?.totalLength ?? Int64(diskData.count * 80),
                mimeType: meta?.mimeType ?? "audio/mpeg",
                timestamp: Date()
            )
        }
        return nil
    }

    func makePlayerItem(
        url: URL,
        headers: [String: String],
        key: String
    ) -> (item: AVPlayerItem, loader: AudioHeadBlockResourceLoader?) {
        guard url.scheme?.hasPrefix("http") == true else {
            return (AVPlayerItem(url: url), nil)
        }
        // AVFoundation 原生 HTTP/HTTPS 流媒体管道性能、低功耗与稳定性最佳，
        // 彻底避免自定义 ResourceLoader 中一次性 dataTask 阻塞导致的 128KB 首包后缓冲卡顿与 NAS 协议冲突。
        return (PlayerManager.makePlayerItem(url: url, headers: headers), nil)
    }

    private static func sanitizeFilename(_ string: String) -> String {
        string.components(separatedBy: CharacterSet.alphanumerics.inverted).joined(separator: "_")
    }
}

final class AudioHeadBlockResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    private let originalURL: URL
    private let headers: [String: String]
    private let headRecord: AudioHeadBlockPreloader.HeadBlockRecord?
    private var pendingRequests = Set<AVAssetResourceLoadingRequest>()
    private let queue = DispatchQueue(label: "com.atmusic.headblock.loader", qos: .userInteractive)

    init(originalURL: URL, headers: [String: String], headRecord: AudioHeadBlockPreloader.HeadBlockRecord?) {
        self.originalURL = originalURL
        self.headers = headers
        self.headRecord = headRecord
        super.init()
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        queue.async {
            self.handle(loadingRequest: loadingRequest)
        }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        queue.async {
            self.pendingRequests.remove(loadingRequest)
        }
    }

    private func handle(loadingRequest: AVAssetResourceLoadingRequest) {
        pendingRequests.insert(loadingRequest)

        // 1. 响应 contentInformationRequest
        if let info = loadingRequest.contentInformationRequest {
            if let head = headRecord {
                info.contentType = Self.uti(for: head.mimeType)
                info.contentLength = head.totalLength
                info.isByteRangeAccessSupported = true
            }
        }

        // 2. 响应 dataRequest
        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            pendingRequests.remove(loadingRequest)
            return
        }

        let requestedOffset = dataRequest.requestedOffset
        let requestedLength = Int64(dataRequest.requestedLength)

        // 若请求落在 128KB 头部缓存内，0ms 立即从本地内存供给！
        if let head = headRecord, requestedOffset < Int64(head.data.count) {
            let start = Int(requestedOffset)
            let end = min(Int(requestedOffset + requestedLength), head.data.count)
            if end > start {
                let chunk = head.data.subdata(in: start..<end)
                dataRequest.respond(with: chunk)
            }
            if requestedOffset + requestedLength <= Int64(head.data.count) {
                loadingRequest.finishLoading()
                pendingRequests.remove(loadingRequest)
                return
            }
        }

        // 3. 超出首包部分，发起 Range 请求流式补全
        let streamOffset = max(requestedOffset, Int64(headRecord?.data.count ?? 0))
        let targetEnd = requestedOffset + requestedLength - 1
        var req = URLRequest(url: originalURL)
        req.setValue("bytes=\(streamOffset)-\(targetEnd)", forHTTPHeaderField: "Range")
        for (k, v) in headers {
            req.setValue(v, forHTTPHeaderField: k)
        }

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            self.queue.async {
                guard self.pendingRequests.contains(loadingRequest) else { return }
                if let data, !data.isEmpty {
                    dataRequest.respond(with: data)
                    loadingRequest.finishLoading()
                } else if let error {
                    loadingRequest.finishLoading(with: error)
                } else {
                    loadingRequest.finishLoading()
                }
                self.pendingRequests.remove(loadingRequest)
            }
        }.resume()
    }

    private static func uti(for mimeType: String) -> String {
        let lower = mimeType.lowercased()
        if lower.contains("flac") {
            return "org.xiph.flac"
        } else if lower.contains("m4a") || lower.contains("mp4") || lower.contains("aac") {
            return "com.apple.m4a-audio"
        } else if lower.contains("wav") {
            return "com.microsoft.waveform-audio"
        } else {
            return "public.mp3"
        }
    }
}
