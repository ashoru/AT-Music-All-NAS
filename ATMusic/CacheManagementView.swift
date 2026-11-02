import SwiftUI
import Foundation

// MARK: - 全局缓存协调器

@MainActor
final class ATMusicCacheCoordinator: ObservableObject {
    static let shared = ATMusicCacheCoordinator()

    @Published private(set) var audioUsageBytes: Int64 = 0
    @Published private(set) var audioSongCount: Int = 0

    @Published private(set) var imageUsageBytes: Int64 = 0

    @Published private(set) var lyricUsageBytes: Int64 = 0
    @Published private(set) var lyricCount: Int = 0

    @Published private(set) var logUsageBytes: Int64 = 0
    @Published private(set) var logFileCount: Int = 0

    private let fm = FileManager.default

    private var lyricsDirectory: URL {
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("ATMusicLyricsCache", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var logDirectory: URL {
        let dir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ATMusicLogs", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {
        refreshAll()
    }

    var totalUsageBytes: Int64 {
        audioUsageBytes + imageUsageBytes + lyricUsageBytes + logUsageBytes
    }

    func refreshAll() {
        refreshAudio()
        refreshImage()
        refreshLyrics()
        refreshLogs()
    }

    // MARK: - 音频缓存

    func refreshAudio() {
        audioUsageBytes = MusicCacheManager.shared.usageBytes
        audioSongCount = MusicCacheManager.shared.cachedSongCount
    }

    @discardableResult
    func clearAudioCache() -> Int {
        let removed = MusicCacheManager.shared.clearPlaybackCache()
        refreshAudio()
        return removed
    }

    // MARK: - 封面与图片缓存

    func refreshImage() {
        var bytes = Int64(URLCache.shared.currentDiskUsage)
        // 扫描应用 Caches 下可能存在的其它图片临时目录
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let candidateDirs = ["ImageCache", "ATMusicImageCache", "fsCachedData"]
        for sub in candidateDirs {
            let dir = caches.appendingPathComponent(sub)
            if let total = calculateDirectorySize(dir) {
                bytes += total
            }
        }
        imageUsageBytes = bytes
    }

    func clearImageCache() {
        URLCache.shared.removeAllCachedResponses()
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let candidateDirs = ["ImageCache", "ATMusicImageCache"]
        for sub in candidateDirs {
            let dir = caches.appendingPathComponent(sub)
            try? fm.removeItem(at: dir)
        }
        refreshImage()
    }

    // MARK: - 歌词缓存

    func refreshLyrics() {
        let dir = lyricsDirectory
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else {
            lyricUsageBytes = 0
            lyricCount = 0
            return
        }
        var total: Int64 = 0
        var count = 0
        for file in files where file.pathExtension.lowercased() == "lrc" {
            count += 1
            if let values = try? file.resourceValues(forKeys: [.fileSizeKey]),
               let size = values.fileSize {
                total += Int64(size)
            }
        }
        lyricUsageBytes = total
        lyricCount = count
    }

    func cacheLyric(for song: Song, content: String) {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let filename = "\(song.identityKey.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? song.identityKey).lrc"
        let fileURL = lyricsDirectory.appendingPathComponent(filename)
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
        refreshLyrics()
    }

    /// 删除单曲歌词缓存（重搜/清空歌词后必须调用，否则下次播放仍命中旧缓存）。
    func removeCachedLyric(for song: Song) {
        let filename = "\(song.identityKey.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? song.identityKey).lrc"
        let fileURL = lyricsDirectory.appendingPathComponent(filename)
        try? fm.removeItem(at: fileURL)
        let transURL = lyricsDirectory.appendingPathComponent(
            "\(song.identityKey.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? song.identityKey).tlrc"
        )
        try? fm.removeItem(at: transURL)
        refreshLyrics()
    }

    func cachedLyric(for song: Song) -> String? {
        let filename = "\(song.identityKey.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? song.identityKey).lrc"
        let fileURL = lyricsDirectory.appendingPathComponent(filename)
        guard fm.fileExists(atPath: fileURL.path) else { return nil }
        return try? String(contentsOf: fileURL, encoding: .utf8)
    }

    /// 翻译歌词与原文分开存（.tlrc），避免混进原文文件后被当成歌词正文解析；
    /// 清理歌词缓存时 clearLyricCache 按目录全清，会一并清掉。
    func cacheLyricTranslation(for song: Song, content: String) {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let filename = "\(song.identityKey.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? song.identityKey).tlrc"
        let fileURL = lyricsDirectory.appendingPathComponent(filename)
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func cachedLyricTranslation(for song: Song) -> String? {
        let filename = "\(song.identityKey.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? song.identityKey).tlrc"
        let fileURL = lyricsDirectory.appendingPathComponent(filename)
        guard fm.fileExists(atPath: fileURL.path) else { return nil }
        return try? String(contentsOf: fileURL, encoding: .utf8)
    }

    @discardableResult
    func clearLyricCache() -> Int {
        let dir = lyricsDirectory
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            refreshLyrics()
            return 0
        }
        var removed = 0
        for file in files {
            try? fm.removeItem(at: file)
            removed += 1
        }
        refreshLyrics()
        return removed
    }

    // MARK: - 运行日志

    func refreshLogs() {
        let dir = logDirectory
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else {
            logUsageBytes = 0
            logFileCount = 0
            return
        }
        var total: Int64 = 0
        var count = 0
        for file in files where file.pathExtension.lowercased() == "log" {
            count += 1
            if let values = try? file.resourceValues(forKeys: [.fileSizeKey]),
               let size = values.fileSize {
                total += Int64(size)
            }
        }
        logUsageBytes = total
        logFileCount = count
    }

    func clearLogCache() {
        ATMusicLogger.shared.clear()
        refreshLogs()
    }

    // MARK: - 全部清理

    func clearAll() {
        clearAudioCache()
        clearImageCache()
        clearLyricCache()
        clearLogCache()
        refreshAll()
    }

    private func calculateDirectorySize(_ url: URL) -> Int64? {
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else {
            return nil
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
               let size = values.fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}

// MARK: - 缓存二级管理界面

struct CacheManagementView: View {
    @EnvironmentObject private var theme: ThemeStore
    @ObservedObject private var coordinator = ATMusicCacheCoordinator.shared
    @ObservedObject private var musicCache = MusicCacheManager.shared
    @AppStorage(MusicCacheManager.prefetchEnabledKey) private var prefetchNextSong = true
    @AppStorage(MusicCacheManager.limitMBKey) private var musicCacheLimitMB = MusicCacheManager.defaultLimitMB
    @State private var showConfirmClearAll = false
    @State private var showLogViewer = false

    private func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var musicCacheLimitText: String {
        ByteCountFormatter.string(fromByteCount: Int64(musicCacheLimitMB) * 1_048_576, countStyle: .file)
    }

    private func musicCacheOptionTitle(_ value: Int) -> String {
        if value < 1024 { return "\(value) MB" }
        return value % 1024 == 0 ? "\(value / 1024) GB" : String(format: "%.1f GB", Double(value) / 1024.0)
    }

    var body: some View {
        ZStack {
            GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
            ScrollView {
                VStack(spacing: 16) {
                    summaryCard
                    audioCacheSection
                    imageCacheSection
                    lyricCacheSection
                    logCacheSection
                    clearAllButton
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 40)
                .frame(maxWidth: 860)
            }
            .atmusicScrollIndicatorsHidden()
        }
        .navigationTitle("存储与缓存管理")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            coordinator.refreshAll()
        }
        .sheet(isPresented: $showLogViewer) {
            LogViewerSheet(importedText: nil)
                .environmentObject(theme)
        }
        .confirmationDialog(
            "确定清理所有缓存数据？（包含音频播放缓存、封面图片、已下载歌词与运行日志）",
            isPresented: $showConfirmClearAll,
            titleVisibility: .visible
        ) {
            Button("全部清理", role: .destructive) {
                coordinator.clearAll()
                ATMusicHaptics.success()
                ToastCenter.shared.show("已清空全部缓存")
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - 顶部汇总卡片

    private var summaryCard: some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("当前缓存占用")
                        .font(ATMusicFont.appFont(13, .medium))
                        .foregroundStyle(Color.atmusicComment)
                    Text(sizeText(coordinator.totalUsageBytes))
                        .font(ATMusicFont.appFont(32, .bold))
                        .foregroundStyle(Color.atmusicLabel)
                }
                Spacer()
                Button {
                    coordinator.refreshAll()
                    ATMusicHaptics.tap()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.atmusicAmber)
                        .padding(8)
                        .background(Color.atmusicAmber.opacity(0.12), in: Circle())
                }
            }

            // 分类分布指示
            HStack(spacing: 8) {
                categoryTag(title: "音频", size: coordinator.audioUsageBytes, color: .orange)
                categoryTag(title: "封面图片", size: coordinator.imageUsageBytes, color: .blue)
                categoryTag(title: "歌词", size: coordinator.lyricUsageBytes, color: .purple)
                categoryTag(title: "日志", size: coordinator.logUsageBytes, color: .green)
            }
        }
        .padding(16)
        .background {
            ATMusicGlass(shape: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private func categoryTag(title: String, size: Int64, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(title)
                    .font(ATMusicFont.appFont(11, .medium))
                    .foregroundStyle(Color.atmusicComment)
            }
            Text(sizeText(size))
                .font(ATMusicFont.appFont(12, .semibold))
                .foregroundStyle(Color.atmusicLabel)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - 1. 音频缓存分区

    private var audioCacheSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(
                title: "音频播放缓存",
                icon: "waveform.badge.magnifyingglass",
                badgeText: "\(sizeText(coordinator.audioUsageBytes)) · \(coordinator.audioSongCount) 首"
            )

            Text("为提升连续播放流畅度预加载的歌曲音频。切歌时优先读取本地缓存，不消耗额外流量。")
                .font(ATMusicFont.appFont(12))
                .foregroundStyle(Color.atmusicComment)

            Divider().overlay(Color.atmusicComment.opacity(0.15))

            Toggle(isOn: $prefetchNextSong) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("下一首提前缓存")
                        .font(ATMusicFont.appFont(14, .medium))
                        .foregroundStyle(Color.atmusicLabel)
                    Text("当前歌曲稳定播放后自动预加载下一首")
                        .font(ATMusicFont.appFont(11))
                        .foregroundStyle(Color.atmusicComment)
                }
            }
            .toggleStyle(.switch)
            .tint(Color.atmusicAmber)
            .onChange(of: prefetchNextSong) { value in
                musicCache.setPrefetchEnabled(value)
            }

            HStack {
                Text("缓存空间上限")
                    .font(ATMusicFont.appFont(14, .medium))
                    .foregroundStyle(Color.atmusicLabel)
                Spacer()
                Menu {
                    ForEach(MusicCacheManager.limitOptionsMB, id: \.self) { value in
                        Button {
                            musicCacheLimitMB = value
                            musicCache.setLimitMB(value)
                            ATMusicHaptics.select()
                        } label: {
                            if musicCacheLimitMB == value {
                                Label(musicCacheOptionTitle(value), systemImage: "checkmark")
                            } else {
                                Text(musicCacheOptionTitle(value))
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(musicCacheOptionTitle(musicCacheLimitMB))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(ATMusicFont.appFont(13, .semibold))
                    .foregroundStyle(Color.atmusicAmber)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.atmusicAmber.opacity(0.12), in: Capsule())
                }
            }

            Button(role: .destructive) {
                let removed = coordinator.clearAudioCache()
                ATMusicHaptics.tap()
                ToastCenter.shared.show("已清除 \(removed) 首音乐缓存")
            } label: {
                HStack {
                    Image(systemName: "trash")
                    Text("清除音频缓存")
                    Spacer()
                    Text(sizeText(coordinator.audioUsageBytes))
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(Color.atmusicComment)
                }
                .font(ATMusicFont.appFont(14, .semibold))
                .foregroundStyle(coordinator.audioUsageBytes > 0 ? Color.red : Color.atmusicComment)
            }
            .disabled(coordinator.audioUsageBytes == 0)
        }
        .padding(16)
        .background {
            ATMusicGlass(shape: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    // MARK: - 2. 封面与图片缓存分区

    private var imageCacheSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(
                title: "封面与图片缓存",
                icon: "photo.on.rectangle.angled",
                badgeText: sizeText(coordinator.imageUsageBytes)
            )

            Text("包含歌曲大封面、歌单缩略图、歌手头像和背景壁纸的高清网络缓存。清理后重新浏览时会自动按需加载。")
                .font(ATMusicFont.appFont(12))
                .foregroundStyle(Color.atmusicComment)

            Divider().overlay(Color.atmusicComment.opacity(0.15))

            Button(role: .destructive) {
                coordinator.clearImageCache()
                ATMusicHaptics.tap()
                ToastCenter.shared.show("已清除封面与图片缓存")
            } label: {
                HStack {
                    Image(systemName: "trash")
                    Text("清除封面与图片缓存")
                    Spacer()
                    Text(sizeText(coordinator.imageUsageBytes))
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(Color.atmusicComment)
                }
                .font(ATMusicFont.appFont(14, .semibold))
                .foregroundStyle(coordinator.imageUsageBytes > 0 ? Color.red : Color.atmusicComment)
            }
            .disabled(coordinator.imageUsageBytes == 0)
        }
        .padding(16)
        .background {
            ATMusicGlass(shape: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    // MARK: - 3. 歌词缓存分区

    private var lyricCacheSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(
                title: "歌词缓存",
                icon: "quote.bubble.fill",
                badgeText: "\(sizeText(coordinator.lyricUsageBytes)) · \(coordinator.lyricCount) 首"
            )

            Text("已匹配和下载的网络同步歌词（.lrc）文件。保留歌词缓存可在无网环境下秒级展示歌词。")
                .font(ATMusicFont.appFont(12))
                .foregroundStyle(Color.atmusicComment)

            Divider().overlay(Color.atmusicComment.opacity(0.15))

            Button(role: .destructive) {
                let count = coordinator.clearLyricCache()
                ATMusicHaptics.tap()
                ToastCenter.shared.show("已清空 \(count) 个歌词缓存文件")
            } label: {
                HStack {
                    Image(systemName: "trash")
                    Text("清除歌词缓存")
                    Spacer()
                    Text(sizeText(coordinator.lyricUsageBytes))
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(Color.atmusicComment)
                }
                .font(ATMusicFont.appFont(14, .semibold))
                .foregroundStyle(coordinator.lyricUsageBytes > 0 ? Color.red : Color.atmusicComment)
            }
            .disabled(coordinator.lyricUsageBytes == 0)
        }
        .padding(16)
        .background {
            ATMusicGlass(shape: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    // MARK: - 4. 运行日志分区

    private var logCacheSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(
                title: "系统运行日志",
                icon: "doc.text.magnifyingglass",
                badgeText: "\(sizeText(coordinator.logUsageBytes)) · \(coordinator.logFileCount) 个文件"
            )

            Text("记录应用运行诊断、网络请求状态与异常信息。可用于排查播放异常或导出给开发者。")
                .font(ATMusicFont.appFont(12))
                .foregroundStyle(Color.atmusicComment)

            Divider().overlay(Color.atmusicComment.opacity(0.15))

            HStack(spacing: 12) {
                Button {
                    showLogViewer = true
                    ATMusicHaptics.tap()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "eye.fill")
                        Text("查看运行日志")
                    }
                    .font(ATMusicFont.appFont(13, .semibold))
                    .foregroundStyle(Color.atmusicLabel)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.atmusicAmber.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)

                Button(role: .destructive) {
                    coordinator.clearLogCache()
                    ATMusicHaptics.tap()
                    ToastCenter.shared.show("日志已清空")
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                        Text("清空日志")
                    }
                    .font(ATMusicFont.appFont(13, .semibold))
                    .foregroundStyle(Color.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background {
            ATMusicGlass(shape: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    // MARK: - 5. 一键清理全部

    private var clearAllButton: some View {
        Button(role: .destructive) {
            showConfirmClearAll = true
            ATMusicHaptics.tap()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 16, weight: .bold))
                Text("一键清理全部缓存")
                    .font(ATMusicFont.appFont(15, .bold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.red.opacity(0.88), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(GlassPressButtonStyle(scale: 0.98))
        .disabled(coordinator.totalUsageBytes == 0)
        .padding(.top, 4)
    }

    private func sectionHeader(title: String, icon: String, badgeText: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.atmusicAmber)
                .frame(width: 28, height: 28)
                .background(Color.atmusicAmber.opacity(0.12), in: Circle())
            Text(title)
                .font(ATMusicFont.appFont(15, .semibold))
                .foregroundStyle(Color.atmusicLabel)
            Spacer()
            Text(badgeText)
                .font(ATMusicFont.appFont(12, .medium))
                .foregroundStyle(Color.atmusicComment)
        }
    }
}
